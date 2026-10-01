import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';
import '../files/file_service.dart';
import 'archive_builder.dart';
import 'archive_job_screen.dart';

final _archivedFilesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, periodId) async {
  return (await ref.read(apiProvider).rpc('list_archived_files', {'p_period_id': periodId})).list;
});

/// Assisted restore (DEL-010): re-upload originals from a saved archive. The
/// server accepts a file only if its SHA-256 and size equal the tombstone of
/// the deleted version; each restore is a new audited version.
class ArchiveRestoreScreen extends ConsumerStatefulWidget {
  const ArchiveRestoreScreen({super.key, required this.periodId});
  final String periodId;

  @override
  ConsumerState<ArchiveRestoreScreen> createState() => _ArchiveRestoreScreenState();
}

class _ArchiveRestoreScreenState extends ConsumerState<ArchiveRestoreScreen> {
  final _selected = <String>{};
  bool _busy = false;
  String? _status;

  Future<void> _restore(List<Map<String, dynamic>> rows) async {
    final chosen = rows.where((r) => _selected.contains(r['file_version_id'])).toList();
    if (chosen.isEmpty) return;
    final reason = await askReason(context, title: 'Restore ${chosen.length} file(s)?', confirmLabel: 'Choose archive');
    if (reason == null) return;
    final zip = await pickZipToLocal('restore-${widget.periodId}');
    if (zip == null || !mounted) return;
    setState(() {
      _busy = true;
      _status = 'Checking the archive…';
    });
    final out = Directory('${(await getTemporaryDirectory()).path}/hrms/restore');
    await out.create(recursive: true);
    try {
      final needed = [for (final r in chosen) <Object>[r['file_version_id'] as String, r['sha256'] as String, (r['size_bytes'] as num).toInt()]];
      final dir = out.path;
      final res = await Isolate.run(() => extractOriginals(zip, null, null, needed, dir));
      if (res['error'] != null) throw ArchiveException(res['error'] as String);
      final missing = (res['missing'] as List).cast<String>().toSet();
      var restored = 0;
      for (final r in chosen) {
        final id = r['file_version_id'] as String;
        if (missing.contains(id)) continue;
        setState(() => _status = 'Restoring ${restored + 1} of ${chosen.length - missing.length}…');
        final mime = r['mime'] as String? ?? 'application/pdf';
        final ext = switch (mime) { 'image/jpeg' => 'jpg', 'image/png' => 'png', 'image/webp' => 'webp', _ => 'pdf' };
        final employee = (r['employee'] as Map).cast<String, dynamic>();
        final isSlip = r['class'] == 'payslip';
        final newId = await ref.read(fileServiceProvider).upload(
              fileClass: r['class'] as String,
              bytes: await File('$dir/$id').readAsBytes(),
              filename: '${employee['code']}_${isSlip ? r['salary_month'] : r['document_date']}.$ext',
              ownerEmployeeId: r['employee_id'] as String,
              salaryMonth: isSlip ? r['salary_month'] as String : null,
              documentDate: isSlip ? null : r['document_date'] as String?,
              title: isSlip ? null : r['title'] as String?,
            );
        await ref.read(apiProvider).rpc('restore_archived_file',
            {'p_deleted_version_id': id, 'p_new_version_id': newId, 'p_reason': reason});
        restored++;
      }
      ref.invalidate(_archivedFilesProvider(widget.periodId));
      setState(() {
        _selected.clear();
        _status = 'Restored $restored file(s).'
            '${missing.isEmpty ? '' : ' ${missing.length} were not in that archive or did not match.'}';
      });
    } on ArchiveException catch (e) {
      setState(() => _status = e.message);
    } on ApiException catch (e) {
      setState(() => _status = e.message);
    } finally {
      if (await out.exists()) await out.delete(recursive: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_archivedFilesProvider(widget.periodId));
    return Scaffold(
      appBar: AppBar(title: const Text('Restore archived files')),
      body: PermissionGate(
        allowed: (s) => s.isAdmin,
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(_archivedFilesProvider(widget.periodId)),
          builder: (rows) {
            final open = rows.where((r) => r['restored_version_id'] == null).toList();
            return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
              const SectionCard(
                color: AppColors.attendanceCard,
                child: Text('Choose files, then select a saved archive that contains them. Each file is accepted only if '
                    'it matches the fingerprint recorded when it was deleted.'),
              ),
              const SizedBox(height: AppSpacing.md),
              if (_status != null) ...[Text(_status!), const SizedBox(height: AppSpacing.md)],
              if (open.isEmpty) const EmptyState(icon: Icons.inventory_2_outlined, title: 'Nothing to restore'),
              for (final r in open)
                CheckboxListTile(
                  value: _selected.contains(r['file_version_id']),
                  onChanged: _busy
                      ? null
                      : (v) => setState(() =>
                          v == true ? _selected.add(r['file_version_id'] as String) : _selected.remove(r['file_version_id'])),
                  title: Text('${(r['employee'] as Map)['code']} · ${r['class'] == 'payslip' ? 'Payslip ${monthLabel(r['salary_month'])}' : r['title'] ?? 'Document'}'),
                  subtitle: Text('v${r['version_no']} · ${formatBytes(r['size_bytes'] as num?)} · deleted ${OrgTime.dateTime(r['deleted_at'])}'),
                ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: _busy || _selected.isEmpty ? null : () => _restore(open),
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : Text('Restore ${_selected.length} file(s)'),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
