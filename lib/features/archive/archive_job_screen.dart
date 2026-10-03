import '../../core/widgets/app_icon.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/files/save_file.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';
import 'archive_builder.dart';
import 'archive_screen.dart';

/// Copies a user-picked file to app storage in a stream (large archives are
/// never loaded into memory) and returns the local path.
Future<String?> pickZipToLocal(String name) async {
  final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['zip']);
  if (picked.isEmpty) return null;
  final file = picked.single;
  final direct = file.path;
  if (direct != null && await File(direct).exists()) return direct;
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/hrms_archive/picked');
  await dir.create(recursive: true);
  final target = File('${dir.path}/$name.zip');
  final sink = target.openWrite();
  await sink.addStream(file.readAsByteStream());
  await sink.close();
  return target.path;
}

/// S35 — one archive export: build, verify, save, acknowledge, and the
/// guarded cleanup of that period's cloud files.
class ArchiveJobScreen extends ConsumerStatefulWidget {
  const ArchiveJobScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ArchiveJobScreen> createState() => _ArchiveJobScreenState();
}

class _ArchiveJobScreenState extends ConsumerState<ArchiveJobScreen> {
  Map<String, dynamic>? _m;
  Object? _loadError;
  BuiltArchive? _built;
  ArchiveBuilder? _builder;
  ArchiveProgress? _progress;
  String? _error;
  String? _baseZip;
  bool _saved = false;
  bool _busy = false;
  Map<String, dynamic>? _cleanup;
  Map<String, dynamic>? _preview;
  bool _deleting = false;
  bool _stop = false;

  ApiClient get _api => ref.read(apiProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _builder?.cancel();
    _stop = true;
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final m = (await _api.rpc('get_export_manifest', {'p_job_id': widget.id})).map;
      final built = await ArchiveBuilder.loadBuilt(widget.id, m['manifest_hash'] as String);
      Map<String, dynamic>? cleanup;
      Map<String, dynamic>? preview;
      final c = (m['cleanup'] as Map?)?.cast<String, dynamic>();
      if (c != null) {
        cleanup = (await _api.rpc('get_cleanup_job', {'p_cleanup_job_id': c['id']})).map;
      } else if (m['state'] == 'acknowledged') {
        preview = (await _api.rpc('preview_cleanup', {'p_job_id': widget.id})).map;
      }
      if (!mounted) return;
      setState(() {
        _m = m;
        _built = built;
        _cleanup = cleanup;
        _preview = preview;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  // ------------------------------------------------------------ build + save

  Future<void> _build({bool partial = false}) async {
    final m = _m!;
    final builder = ArchiveBuilder(_api, m);
    setState(() {
      _builder = builder;
      _error = null;
      _saved = false;
      _progress = const ArchiveProgress('Starting');
    });
    try {
      final built = await builder.build(
        baseZipPath: _baseZip,
        partial: partial,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) setState(() => _built = built);
    } on ArchiveException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FileSystemException {
      if (mounted) setState(() => _error = 'The phone could not write the archive (storage full?). Free space and resume.');
    } finally {
      if (mounted) {
        setState(() {
          _builder = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _pickBase() async {
    try {
      final path = await pickZipToLocal('base-${widget.id}');
      if (path != null && mounted) setState(() => _baseZip = path);
    } catch (_) {
      if (mounted) showMessage(context, 'Could not open that file.', error: true);
    }
  }

  Future<void> _share() async {
    final b = _built!;
    await shareFile(b.path, 'application/zip', subject: b.fileName);
  }

  Future<void> _saveAs() async {
    final b = _built!;
    try {
      final ok = await saveBytesAs(await File(b.path).readAsBytes(), b.fileName, 'application/zip');
      if (ok && mounted) showMessage(context, 'Saved. Keep it somewhere safe, not only on this phone.');
    } catch (_) {
      if (mounted) showMessage(context, 'Could not save here. Use "Share / save to Files" instead.', error: true);
    }
  }

  Future<void> _acknowledge() async {
    final b = _built!;
    setState(() => _busy = true);
    try {
      await _api.rpc('acknowledge_export', {
        'p_job_id': widget.id,
        'p_manifest_hash': b.manifestHash,
        'p_included_files': b.includedFiles,
        'p_included_bytes': b.includedBytes,
        'p_partial': b.partial,
        'p_missing_file_ids': b.partial ? b.missingIds : null,
        'p_saved': true,
      });
      ref.invalidate(archiveOverviewProvider);
      if (mounted) showMessage(context, b.partial ? 'Recorded as a partial archive.' : 'Archive confirmed.');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ cleanup

  Future<void> _beginCleanup() async {
    final p = _preview!;
    final label = p['confirm_label'] as String;
    final visible = ((p['visible_payslips'] as num?) ?? 0).toInt();
    final typed = TextEditingController();
    var acceptVisible = visible == 0;
    var acceptLocal = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
        final canGo = typed.text.trim().toUpperCase() == label.toUpperCase() && acceptVisible && acceptLocal;
        return AlertDialog(
          title: const Text('Delete cloud files?'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${p['item_count']} file(s), ${formatBytes(p['total_bytes'] as num?)}, for ${p['employee_count']} '
                  'employee(s) will be permanently removed from cloud storage. This cannot be undone from the app.'),
              const SizedBox(height: AppSpacing.sm),
              Text('Kept: ${((p['kept'] as List?) ?? const []).join(', ')}.', style: Theme.of(ctx).textTheme.bodySmall),
              if (visible > 0) ...[
                const SizedBox(height: AppSpacing.sm),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: acceptVisible,
                  onChanged: (v) => setState(() => acceptVisible = v ?? false),
                  title: Text('$visible recent payslip(s) will remain listed as archived and cannot be downloaded from the app.'),
                ),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: acceptLocal,
                onChanged: (v) => setState(() => acceptLocal = v ?? false),
                title: const Text('I keep the saved archive safe. Deleted files can only be restored from it.'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: typed,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: 'Type $label to confirm'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.error),
              onPressed: canGo ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Delete files'),
            ),
          ],
        );
      }),
    );
    final text = typed.text.trim();
    typed.dispose();
    if (ok != true || !mounted) return;
    if (!await reauthenticate(context, ref, action: 'archive.cleanup', targetId: widget.id)) return;
    setState(() => _busy = true);
    try {
      final c = (await _api.rpc('begin_cleanup', {
        'p_job_id': widget.id,
        'p_manifest_hash': _m!['manifest_hash'],
        'p_confirm_label': text,
        'p_accept_visible_loss': acceptVisible,
      }))
          .map;
      ref.invalidate(archiveOverviewProvider);
      setState(() => _cleanup = {...c, 'is_driver': true});
      await _runBatches(c['id'] as String);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runBatches(String cleanupId) async {
    setState(() {
      _deleting = true;
      _stop = false;
    });
    try {
      while (mounted && !_stop) {
        final res = (await _api.function('archive', {'action': 'cleanup_batch', 'cleanup_job_id': cleanupId})).map;
        if (res['busy'] == true) {
          await Future<void>.delayed(Duration(seconds: ((res['retry_after_seconds'] as num?)?.toInt() ?? 10).clamp(2, 30)));
          continue;
        }
        final job = (res['job'] as Map?)?.cast<String, dynamic>();
        if (job != null && mounted) setState(() => _cleanup = {...?_cleanup, ...job});
        if (res['done'] == true || res['stalled'] == true) break;
      }
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _deleting = false);
      ref.invalidate(archiveOverviewProvider);
      await _load();
    }
  }

  Future<void> _resume(String cleanupId) async {
    if (!await reauthenticate(context, ref, action: 'archive.cleanup', targetId: cleanupId)) return;
    try {
      await _api.rpc('resume_cleanup', {'p_cleanup_job_id': cleanupId});
      await _runBatches(cleanupId);
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    }
  }

  Future<void> _abandon(Map<String, dynamic> c) async {
    final reason = await askReason(context,
        title: 'Abandon this cleanup?',
        message: '${c['deleted_items']} file(s) already deleted stay deleted; they exist only in your saved archive. '
            'The other ${(c['total_items'] as num) - (c['deleted_items'] as num)} file(s) are kept and the period '
            'is unlocked for changes. Another cleanup will need a new complete archive.',
        confirmLabel: 'Abandon',
        destructive: true);
    if (reason == null) return;
    setState(() => _busy = true);
    try {
      if (c['is_driver'] == true && ((c['in_flight_items'] as num?) ?? 0) > 0) {
        await _api.function('archive', {'action': 'cleanup_batch', 'cleanup_job_id': c['id'], 'reconcile_only': true});
      }
      await _api.rpc('abandon_cleanup', {'p_cleanup_job_id': c['id'], 'p_reason': reason});
      ref.invalidate(archiveOverviewProvider);
      await _load();
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final m = _m;
    return Scaffold(
      appBar: AppBar(title: Text(m == null ? 'Archive export' : '${m['label']} · r${m['revision']}')),
      body: PermissionGate(
        allowed: (s) => s.isAdmin,
        hideOffline: false,
        child: _loadError != null
            ? ErrorState(error: _loadError!, onRetry: _load)
            : m == null
                ? const SkeletonList(items: 3, height: 110)
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
                      _header(context, m),
                      const SizedBox(height: AppSpacing.lg),
                      ..._body(context, m),
                    ]),
                  ),
      ),
    );
  }

  Widget _header(BuildContext context, Map<String, dynamic> m) {
    final (label, tone) = exportStateLabel(m);
    final counts = ((m['row_counts'] as Map?) ?? const {}).cast<String, dynamic>();
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        StatusChip(label, tone: tone),
        const SizedBox(height: AppSpacing.sm),
        KeyValueRow('Period', '${OrgTime.date(m['period_start'] as String?)} – ${OrgTime.date(m['period_end'] as String?)}'),
        KeyValueRow('Records as of', OrgTime.dateTime(m['as_of'])),
        KeyValueRow('Contents', '${counts['employees']} employees · ${counts['attendance_rows']} attendance days · '
            '${counts['leave_rows']} leave requests · ${m['file_count']} files (${formatBytes(m['total_bytes'] as num?)})'),
        if ((m['local_base_count'] as num? ?? 0) > 0)
          KeyValueRow('From saved archive', '${m['local_base_count']} earlier file(s) no longer in the cloud'),
        KeyValueRow('Time zone', m['timezone'] as String? ?? ''),
        if (m['provisional'] == true)
          Text('Provisional: a shift from this period can still be checked out until ${OrgTime.dateTime(m['live_until'])}.',
              style: const TextStyle(color: AppColors.warning)),
        if (m['stale'] == true)
          Text('${m['stale_reason'] ?? 'Records changed'} — create a new export for a complete archive.',
              style: const TextStyle(color: AppColors.warning)),
      ]),
    );
  }

  List<Widget> _body(BuildContext context, Map<String, dynamic> m) {
    final state = m['state'] as String;
    final out = <Widget>[];
    final cleanup = _cleanup;
    if (cleanup != null) {
      out.add(_cleanupPanel(context, cleanup));
      out.add(const SizedBox(height: AppSpacing.lg));
    }
    if (state == 'ready' && m['stale'] != true) {
      out.addAll(_buildPanel(context, m));
    } else if (state == 'acknowledged') {
      out.add(SectionCard(
        color: AppColors.successSoft,
        child: Text('Saved and verified${m['acknowledged_by'] != null ? ' by ${(m['acknowledged_by'] as Map)['name']}' : ''} '
            'on ${OrgTime.dateTime(m['acknowledged_at'])}.'),
      ));
      if (cleanup == null && _preview != null) {
        out.add(const SizedBox(height: AppSpacing.lg));
        out.add(_previewPanel(context, _preview!));
      }
    } else if (state == 'partial') {
      out.add(const SectionCard(
        color: AppColors.warningSoft,
        child: Text('Recorded as a PARTIAL archive: some earlier originals were not available. It is kept for reference '
            'but can never be used to delete cloud files.'),
      ));
    } else {
      out.add(SectionCard(
        child: Text(m['stale'] == true
            ? 'This export no longer matches the records. Create a new export from the archive screen.'
            : 'This export is no longer active. Create a new export from the archive screen.'),
      ));
    }
    if (_built != null && state != 'ready') {
      out.addAll([
        const SizedBox(height: AppSpacing.lg),
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Copy on this phone: ${_built!.fileName} (${formatBytes(_built!.sizeBytes)})'),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(onPressed: _share, icon: const AppIcon(Icons.ios_share_rounded), label: const Text('Share / save another copy')),
            TextButton(
              onPressed: () async {
                await ArchiveBuilder.discard(widget.id);
                if (mounted) setState(() => _built = null);
              },
              child: const Text('Remove the working copy from this phone'),
            ),
          ]),
        ),
      ]);
    }
    if (state == 'ready') {
      out.addAll([
        const SizedBox(height: AppSpacing.xl),
        TextButton(
          onPressed: _busy || _builder != null
              ? null
              : () async {
                  final ok = await confirm(context,
                      title: 'Cancel this export?', message: 'Nothing is deleted. You can create a new export later.',
                      confirmLabel: 'Cancel export');
                  if (!ok) return;
                  try {
                    await _api.rpc('cancel_export', {'p_job_id': widget.id});
                    await ArchiveBuilder.discard(widget.id);
                    ref.invalidate(archiveOverviewProvider);
                    await _load();
                  } on ApiException catch (e) {
                    if (mounted) showMessage(this.context, e.message, error: true);
                  }
                },
          child: const Text('Cancel this export'),
        ),
      ]);
    }
    return out;
  }

  List<Widget> _buildPanel(BuildContext context, Map<String, dynamic> m) {
    final progress = _progress;
    final base = (m['base'] as Map?)?.cast<String, dynamic>();
    final needsBase = m['requires_local_base'] == true;
    final building = _builder != null;
    final built = _built;
    return [
      if (needsBase && built == null)
        SectionCard(
          color: AppColors.warningSoft,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Earlier files were already removed from the cloud', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            Text('Select your saved archive r${base?['revision'] ?? '?'} of this period. Each earlier file is checked '
                'against its recorded fingerprint before it is included.'),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              onPressed: building ? null : _pickBase,
              icon: const AppIcon(Icons.folder_zip_outlined),
              label: Text(_baseZip == null ? 'Select previous archive' : 'Selected ✓ — choose another'),
            ),
            TextButton(
              onPressed: building
                  ? null
                  : () async {
                      final ok = await confirm(context,
                          title: 'Build a partial archive?',
                          message: '${m['local_base_count']} earlier file(s) will be missing and listed in the manifest. '
                              'A partial archive can never be used to delete cloud files.',
                          confirmLabel: 'Build partial');
                      if (ok) _build(partial: true);
                    },
              child: const Text('The previous archive is not available'),
            ),
          ]),
        ),
      if (needsBase && built == null) const SizedBox(height: AppSpacing.lg),
      if (built == null)
        SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Build on this phone', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text('Needs about ${formatBytes(ArchiveBuilder(_api, m).estimatedDiskBytes)} of free space. Keep the app open '
                'on Wi-Fi; if it stops, resume and verified files are reused.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpacing.md),
            if (progress != null) ...[
              Text(progress.total > 0 ? '${progress.label}: ${progress.done} of ${progress.total}' : progress.label),
              const SizedBox(height: AppSpacing.xs),
              LinearProgressIndicator(value: progress.fraction, minHeight: 8, borderRadius: BorderRadius.circular(4)),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton(onPressed: () => _builder?.cancel(), child: const Text('Stop')),
            ] else
              FilledButton.icon(
                onPressed: (needsBase && _baseZip == null) ? null : () => _build(),
                icon: const AppIcon(Icons.build_circle_outlined),
                label: Text(_error == null ? 'Build archive' : 'Resume'),
              ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: const TextStyle(color: AppColors.error)),
            ],
          ]),
        )
      else
        SectionCard(
          color: built.partial ? AppColors.warningSoft : AppColors.successSoft,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const AppIcon(Icons.verified_rounded, color: AppColors.success),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(built.partial ? 'Partial archive built and verified' : 'Archive built and verified',
                  style: Theme.of(context).textTheme.titleSmall)),
            ]),
            const SizedBox(height: AppSpacing.sm),
            Text('${built.fileName} · ${formatBytes(built.sizeBytes)} · ${built.includedFiles} files checked by '
                'fingerprint, spreadsheets and row counts checked.'),
            if (built.partial) Text('${built.missingIds.length} earlier file(s) are missing and listed in manifest.json.'),
            const SizedBox(height: AppSpacing.md),
            FilledButton.tonalIcon(onPressed: _share, icon: const AppIcon(Icons.ios_share_rounded),
                label: const Text('Share / save to Files')),
            if (built.sizeBytes <= maxInMemorySaveBytes) ...[
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(onPressed: _saveAs, icon: const AppIcon(Icons.save_alt_rounded), label: const Text('Save to device')),
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _saved,
              onChanged: (v) => setState(() => _saved = v ?? false),
              title: const Text('I saved a copy somewhere safe (not only on this phone).'),
              subtitle: const Text('The app cannot check your saved copy; this confirmation is recorded.'),
            ),
            FilledButton(
              onPressed: _saved && !_busy ? _acknowledge : null,
              child: Text(built.partial ? 'Record partial archive' : 'Confirm archive saved'),
            ),
          ]),
        ),
    ];
  }

  Widget _previewPanel(BuildContext context, Map<String, dynamic> p) {
    final checks = [for (final c in (p['checks'] as List? ?? const [])) (c as Map).cast<String, dynamic>()];
    final allOk = checks.every((c) => c['ok'] == true);
    final items = [for (final i in (p['items'] as List? ?? const [])) (i as Map).cast<String, dynamic>()];
    final exclusions = [for (final x in (p['exclusions'] as List? ?? const [])) (x as Map).cast<String, dynamic>()];
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Free cloud space (optional)', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text('Deletes only the files listed below from cloud storage. Everything else is kept.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        for (final c in checks)
          Row(children: [
            AppIcon(c['ok'] == true ? Icons.check_circle_rounded : Icons.cancel_rounded,
                size: 18, color: c['ok'] == true ? AppColors.success : AppColors.error),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(c['label'] as String)),
          ]),
        const SizedBox(height: AppSpacing.sm),
        KeyValueRow('Files to delete', '${p['item_count']} (${formatBytes(p['total_bytes'] as num?)})'),
        if (((p['visible_payslips'] as num?) ?? 0) > 0)
          KeyValueRow('Recent payslips', '${p['visible_payslips']} will show as "archived — contact HR"'),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Exact file list'),
          children: [for (final i in items.take(300)) Text('${i['path']} · ${formatBytes(i['size_bytes'] as num?)}',
              style: Theme.of(context).textTheme.bodySmall)],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Never deleted'),
          children: [
            for (final k in (p['kept'] as List? ?? const [])) Align(alignment: Alignment.centerLeft, child: Text('• $k')),
            for (final x in exclusions)
              Align(alignment: Alignment.centerLeft, child: Text('• ${x['label']} (${x['count']})')),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          onPressed: allOk && !_busy && ((p['item_count'] as num?) ?? 0) > 0 ? _beginCleanup : null,
          child: const Text('Delete cloud files…'),
        ),
      ]),
    );
  }

  Widget _cleanupPanel(BuildContext context, Map<String, dynamic> c) {
    final running = c['state'] == 'running';
    final total = ((c['total_items'] as num?) ?? 0).toInt();
    final deleted = ((c['deleted_items'] as num?) ?? 0).toInt();
    final failed = ((c['failed_items'] as num?) ?? 0).toInt();
    final isDriver = c['is_driver'] == true;
    final failures = [for (final f in (c['failed'] as List? ?? const [])) (f as Map).cast<String, dynamic>()];
    return SectionCard(
      color: running ? AppColors.warningSoft : AppColors.surface,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(switch (c['state']) {
          'running' => 'Cleanup in progress',
          'completed' => 'Cleanup completed',
          'abandoned_with_partial_deletions' => 'Cleanup abandoned after partial deletion',
          _ => 'Cleanup abandoned',
        }, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        LinearProgressIndicator(value: total == 0 ? null : deleted / total, minHeight: 8, borderRadius: BorderRadius.circular(4)),
        const SizedBox(height: AppSpacing.xs),
        Text('$deleted of $total files deleted (${formatBytes(c['deleted_bytes'] as num?)})'
            '${failed > 0 ? ' · $failed failed' : ''}'),
        if (c['driver'] != null && running) Text('Run by ${(c['driver'] as Map)['name']}', style: Theme.of(context).textTheme.bodySmall),
        for (final f in failures.take(5))
          Text('• ${f['path']} — ${f['error'] ?? 'error'} (${f['attempts']} attempts)', style: Theme.of(context).textTheme.bodySmall),
        if (c['abandon_reason'] != null) Text('Reason: ${c['abandon_reason']}', style: Theme.of(context).textTheme.bodySmall),
        if (!running && deleted > 0)
          Text('Deleted files are kept only in your saved archive. Records and audit history are unchanged.',
              style: Theme.of(context).textTheme.bodySmall),
        if (running) ...[
          const SizedBox(height: AppSpacing.md),
          if (_deleting) ...[
            const Text('Deleting in small batches… keep the app open.'),
            TextButton(onPressed: () => setState(() => _stop = true), child: const Text('Pause')),
          ] else if (isDriver && failed == 0)
            FilledButton(onPressed: _busy ? null : () => _runBatches(c['id'] as String), child: const Text('Continue'))
          else
            FilledButton(
              onPressed: _busy ? null : () => _resume(c['id'] as String),
              child: Text(failed > 0 ? 'Retry failed files' : 'Take over this cleanup'),
            ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: _busy || _deleting ? null : () => _abandon(c),
            child: const Text('Abandon cleanup'),
          ),
        ],
      ]),
    );
  }
}
