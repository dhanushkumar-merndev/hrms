import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/auth/session_controller.dart';
import '../../core/format.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';

final workspaceProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return (await ref.read(apiProvider).rpc('get_workspace_summary')).map;
});

/// Route for an Admin task card.
String? adminTaskRoute(Map<String, dynamic> t) => switch (t['kind']) {
      'archive_due' || 'cleanup_running' => '/admin/archive',
      'maintenance_stale' || 'storage' => '/admin/organization',
      'reviewer_missing' => '/approvals',
      _ => null,
    };

/// S21 — role workspace: team status today, this week's hours, missed
/// punches, pending reviews and (Admin) storage and archive tasks.
class WorkspaceScreen extends ConsumerWidget {
  const WorkspaceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(workspaceProvider);
    final s = ref.watch(sessionContextProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Workspace')),
      body: PermissionGate(
        allowed: (s) => s.hasWorkspace,
        child: RefreshIndicator(
          onRefresh: () => ref.refresh(workspaceProvider.future),
          child: AsyncView(
            value: data,
            onRetry: () => ref.invalidate(workspaceProvider),
            loading: const SkeletonList(items: 4, height: 110),
            builder: (d) {
              final team = (d['team_today'] as Map?)?.cast<String, dynamic>();
              final week = ((d['week'] as Map?) ?? const {}).cast<String, dynamic>();
              final totals = ((week['totals'] as Map?) ?? const {}).cast<String, dynamic>();
              final storage = (d['storage'] as Map?)?.cast<String, dynamic>();
              final tasks = ((d['admin_tasks'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
              int n(Object? v) => (v as num?)?.toInt() ?? 0;
              return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
                Text(d['scope'] == 'organization' ? 'Whole organisation' : d['scope'] == 'team' ? 'Your teams' : 'Your reviews',
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: AppSpacing.md),
                if (tasks.isNotEmpty) ...[
                  for (final t in tasks) ...[
                    ActionRow(
                      icon: Icons.task_alt_rounded,
                      label: t['title'] as String? ?? '',
                      subtitle: t['count'] != null
                          ? '${t['count']} waiting'
                          : t['percent'] != null
                              ? '${t['percent']}% of the storage budget'
                              : t['since'] != null
                                  ? 'Since ${OrgTime.date(t['since'] as String?)}'
                                  : null,
                      tileColor: AppColors.warningSoft,
                      iconColor: AppColors.warning,
                      onTap: () {
                        final route = adminTaskRoute(t);
                        if (route != null) context.push(route);
                      },
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (team != null)
                  SectionCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Today', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
                        StatusChip('${n(team['on_time'])} on time', tone: ChipTone.success),
                        StatusChip('${n(team['late'])} late', tone: ChipTone.warning),
                        StatusChip('${n(team['not_yet_in'])} not yet in', tone: ChipTone.error),
                        StatusChip('${n(team['out_of_office'])} off / leave', tone: ChipTone.neutral),
                      ]),
                      const SizedBox(height: AppSpacing.xs),
                      Text('${n(team['total'])} people in scope', style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                const SizedBox(height: AppSpacing.lg),
                SectionCard(
                  onTap: (s?.canTeamReports ?? false) ? () => context.push('/reports/hours') : null,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text('This week', style: Theme.of(context).textTheme.titleSmall)),
                      if (s?.canTeamReports ?? false) const Icon(Icons.chevron_right_rounded),
                    ]),
                    const SizedBox(height: AppSpacing.sm),
                    KeyValueRow('Expected', OrgTime.hm(totals['required_seconds'] as num?)),
                    KeyValueRow('Worked', OrgTime.hm(totals['credited_seconds'] as num?)),
                    KeyValueRow('Short', OrgTime.hm(totals['shortfall_seconds'] as num?)),
                    KeyValueRow('Extra', '${OrgTime.hm(totals['extra_seconds'] as num?)} (not overtime pay)'),
                    if (n(totals['unresolved_days']) > 0)
                      Text('${n(totals['unresolved_days'])} day(s) in progress or needing correction — totals are partial.',
                          style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
                const SizedBox(height: AppSpacing.lg),
                ActionRow(
                  icon: Icons.fact_check_outlined,
                  label: 'Pending reviews',
                  subtitle: d['unassigned_reviews'] != null && n(d['unassigned_reviews']) > 0
                      ? '${n(d['unassigned_reviews'])} without an approver'
                      : null,
                  badge: n(d['pending_reviews']) > 0 ? '${n(d['pending_reviews'])}' : null,
                  tileColor: AppColors.approvalsCard,
                  iconColor: AppColors.approvalsAction,
                  onTap: () => context.push('/approvals'),
                ),
                const SizedBox(height: AppSpacing.sm),
                ActionRow(
                  icon: Icons.report_problem_outlined,
                  label: 'Missed punches (7 days)',
                  subtitle: '${n(d['missed_punches_7d'])} shift(s) need a correction',
                  tileColor: AppColors.exceptionStrip,
                  iconColor: AppColors.error,
                  onTap: () => context.push('/reports/hours'),
                ),
                if (storage != null) ...[
                  const SizedBox(height: AppSpacing.lg),
                  _StorageCard(storage: storage),
                ],
              ]);
            },
          ),
        ),
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.storage});
  final Map<String, dynamic> storage;

  @override
  Widget build(BuildContext context) {
    final used = (storage['used_bytes'] as num?) ?? 0;
    final reserved = (storage['reserved_bytes'] as num?) ?? 0;
    final budget = (storage['budget_bytes'] as num?) ?? 1;
    final ratio = ((used + reserved) / budget).clamp(0.0, 1.0).toDouble();
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('File storage', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        Semantics(
          label: 'Storage ${(ratio * 100).round()} percent used',
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 10,
            borderRadius: BorderRadius.circular(6),
            color: ratio >= 0.85 ? AppColors.error : AppColors.primary,
            backgroundColor: AppColors.border,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text('${formatBytes(used)} used${reserved > 0 ? ' + ${formatBytes(reserved)} uploading' : ''} of ${formatBytes(budget)}',
            style: Theme.of(context).textTheme.bodySmall),
        Text('Files are never deleted automatically to save space.', style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
