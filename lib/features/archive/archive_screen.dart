import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';

final archiveOverviewProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return (await ref.read(apiProvider).rpc('get_archive_overview')).map;
});

(String, ChipTone) exportStateLabel(Map<String, dynamic> j) {
  if (j['stale'] == true && j['state'] != 'superseded' && j['state'] != 'cancelled') {
    return ('Records changed — re-export', ChipTone.warning);
  }
  return switch (j['state']) {
    'ready' => ('Ready to build & save', ChipTone.info),
    'acknowledged' => (j['cleanup_consumed'] == true ? 'Saved · used for cleanup' : 'Saved & verified', ChipTone.success),
    'partial' => ('Saved as partial', ChipTone.warning),
    'expired' => ('Expired', ChipTone.neutral),
    'superseded' => ('Replaced by a newer export', ChipTone.neutral),
    'cancelled' => ('Cancelled', ChipTone.neutral),
    final s => (s.toString(), ChipTone.neutral),
  };
}

/// S34 — annual archive. Closed periods can be exported; the Admin builds
/// and saves a verified archive on the phone. Deleting cloud files is a
/// separate, optional, guarded step. Ordinary reports remain available any
/// time from the hours report.
class ArchiveScreen extends ConsumerStatefulWidget {
  const ArchiveScreen({super.key});

  @override
  ConsumerState<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends ConsumerState<ArchiveScreen> {
  bool _busy = false;

  Future<void> _create(Map<String, dynamic> period) async {
    final ok = await confirm(context,
        title: 'Create archive export for ${period['label']}?',
        message: 'This freezes the period\'s attendance, leave and file inventory as of now. You will then download '
            'and save it on this phone. It includes payslips, so your password is needed.',
        confirmLabel: 'Continue');
    if (!ok || !mounted) return;
    if (!await reauthenticate(context, ref, action: 'export.annual', targetId: period['id'] as String)) return;
    setState(() => _busy = true);
    try {
      final job = (await ref.read(apiProvider).rpc('create_archive_export', {'p_period_id': period['id']})).map;
      ref.invalidate(archiveOverviewProvider);
      if (mounted) context.push('/admin/archive/${job['id']}').then((_) => ref.invalidate(archiveOverviewProvider));
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(archiveOverviewProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Annual archive')),
      body: PermissionGate(
        allowed: (s) => s.isAdmin,
        child: RefreshIndicator(
          onRefresh: () => ref.refresh(archiveOverviewProvider.future),
          child: AsyncView(
            value: data,
            onRetry: () => ref.invalidate(archiveOverviewProvider),
            builder: (d) {
              final periods = [for (final p in (d['periods'] as List? ?? const [])) (p as Map).cast<String, dynamic>()];
              final storage = ((d['storage'] as Map?) ?? const {}).cast<String, dynamic>();
              return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
                SectionCard(
                  color: AppColors.attendanceCard,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('How it works', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: AppSpacing.sm),
                    const Text('1. After a period ends, create an archive export.\n'
                        '2. Build it on this phone: every file and spreadsheet is verified.\n'
                        '3. Save a copy somewhere safe and confirm.\n'
                        '4. Optionally delete that period\'s files from the cloud to free space. Records, balances and '
                        'audit history are never deleted.'),
                    const SizedBox(height: AppSpacing.sm),
                    TextButton.icon(
                      onPressed: () => context.push('/reports/hours'),
                      icon: const Icon(Icons.table_chart_outlined),
                      label: const Text('Interim Excel reports (any dates)'),
                    ),
                  ]),
                ),
                const SizedBox(height: AppSpacing.md),
                KeyValueRow('Cloud storage', '${formatBytes(storage['used_bytes'] as num?)} of '
                    '${formatBytes(storage['budget_bytes'] as num?)}'),
                const SizedBox(height: AppSpacing.md),
                for (final p in periods) _PeriodCard(period: p, busy: _busy, onCreate: () => _create(p)),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

class _PeriodCard extends StatelessWidget {
  const _PeriodCard({required this.period, required this.busy, required this.onCreate});
  final Map<String, dynamic> period;
  final bool busy;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final closed = period['closed'] == true;
    final jobs = [for (final j in (period['jobs'] as List? ?? const [])) (j as Map).cast<String, dynamic>()];
    final cleanups = [for (final c in (period['cleanups'] as List? ?? const [])) (c as Map).cast<String, dynamic>()];
    final liveUntil = OrgTime.parse(period['live_until']);
    final live = closed && liveUntil != null && liveUntil.isAfter(DateTime.now().toUtc());
    final deletedSomething = cleanups.any((c) => ((c['deleted_items'] as num?) ?? 0) > 0);
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(period['label'] as String, style: Theme.of(context).textTheme.titleMedium)),
            if (period['kind'] == 'transition') const StatusChip('Transition period', tone: ChipTone.info),
          ]),
          Text('${OrgTime.date(period['period_start'] as String?)} – ${OrgTime.date(period['period_end'] as String?)}',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: AppSpacing.sm),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (!closed)
              StatusChip('Open · can be archived from ${OrgTime.date(period['unlocks_on'] as String?, pattern: 'd MMM yyyy')}',
                  tone: ChipTone.neutral)
            else if (period['due'] == true)
              const StatusChip('Archive due', tone: ChipTone.error, icon: Icons.priority_high_rounded)
            else
              const StatusChip('Archived', tone: ChipTone.success, icon: Icons.verified_outlined),
            if (period['cleanup_running'] == true) const StatusChip('Cleanup in progress', tone: ChipTone.warning),
          ]),
          if (live)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text('A shift from this period can still be checked out until ${OrgTime.dateTime(period['live_until'])}. '
                  'An export now is provisional and cannot be used for cleanup.',
                  style: const TextStyle(color: AppColors.warning)),
            ),
          if (jobs.isNotEmpty) const SizedBox(height: AppSpacing.sm),
          for (final j in jobs.take(4))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text('Export r${j['revision']} · ${exportStateLabel(j).$1}'),
              subtitle: Text('${j['file_count']} files · ${formatBytes(j['total_bytes'] as num?)} · '
                  '${OrgTime.dateTime(j['created_at'])}'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/admin/archive/${j['id']}'),
            ),
          for (final c in cleanups.take(2))
            Text('Cleanup: ${switch (c['state']) {
              'running' => 'running',
              'completed' => 'completed',
              'abandoned_with_partial_deletions' => 'abandoned after partial deletion',
              _ => 'abandoned',
            }} · ${c['deleted_items']} of ${c['total_items']} files removed',
                style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          if (closed && period['cleanup_running'] != true)
            FilledButton.icon(
              onPressed: busy ? null : onCreate,
              icon: const Icon(Icons.archive_outlined),
              label: Text(jobs.isEmpty ? 'Create archive export' : 'Create new export'),
            ),
          if (deletedSomething)
            TextButton.icon(
              onPressed: () => context.push('/admin/archive/restore/${period['id']}'),
              icon: const Icon(Icons.settings_backup_restore_rounded),
              label: const Text('Restore files from a saved archive'),
            ),
        ]),
      ),
    );
  }
}
