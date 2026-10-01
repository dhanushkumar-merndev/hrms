import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/auth/session_controller.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/states.dart';
import 'attendance_ui.dart';

final attendanceDayProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, (String?, String)>((ref, key) async {
  return (await ref.read(apiProvider).rpc('get_attendance_day', {
    'p_employee_id': key.$1,
    'p_shift_date': key.$2,
  }))
      .map;
});

/// S08 — one attendance day: policy, original punches, approved adjustments
/// (kept separate), required interval after leave, totals and history.
class AttendanceDayScreen extends ConsumerWidget {
  const AttendanceDayScreen({super.key, required this.date, this.employeeId});
  final String date;
  final String? employeeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (employeeId, date);
    final data = ref.watch(attendanceDayProvider(key));
    final me = ref.watch(sessionContextProvider)?.employeeId;
    final own = employeeId == null || employeeId == me;
    return Scaffold(
      appBar: AppBar(title: Text(OrgTime.date(date))),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(attendanceDayProvider(key)),
        builder: (d) {
          if (d['scheduled'] != true) {
            return const EmptyState(icon: Icons.event_busy_outlined, title: 'No shift scheduled on this day');
          }
          final (label, tone, icon) = dayStatus(d);
          final shift = (d['shift'] as Map?)?.cast<String, dynamic>() ?? const {};
          final events = ((d['events'] as List?) ?? const []).cast<Map>();
          final adjustments = ((d['adjustments'] as List?) ?? const []).cast<Map>();
          final corrections = ((d['correction_requests'] as List?) ?? const []).cast<Map>();
          final slots = (d['leave_slots'] as num?)?.toInt() ?? 0;
          final employee = (d['employee'] as Map?)?.cast<String, dynamic>();
          return ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
            if (!own && employee != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Text('${employee['name']} · ${employee['code']}', style: Theme.of(context).textTheme.titleMedium),
              ),
            SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                StatusChip(label, tone: tone, icon: icon),
                const SizedBox(height: AppSpacing.md),
                KeyValueRow('Shift', '${OrgTime.time(d['start_at'])} – ${OrgTime.time(d['end_at'])}'
                    '${shift['name'] != null ? ' (${shift['name']} v${shift['version_no']})' : ''}'),
                KeyValueRow('Lunch', d['lunch_paid'] == true
                    ? (d['lunch_start_at'] == null
                        ? 'Paid, included in shift'
                        : 'Paid, ${OrgTime.time(d['lunch_start_at'])} – ${OrgTime.time(d['lunch_end_at'])}')
                    : 'Unpaid'),
                if (slots > 0) KeyValueRow('Leave', leaveSlotLabel(slots)),
                if (d['required_start'] != null)
                  KeyValueRow('Required', '${OrgTime.time(d['required_start'])} – ${OrgTime.time(d['required_end'])}'
                      ' · ${OrgTime.hm(d['required_seconds'])}'),
                KeyValueRow('Grace', '${((shift['grace_seconds'] as num?) ?? 0) ~/ 60} min (late label only)'),
              ]),
            ),
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Effective time', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.sm),
                KeyValueRow('In – out', d['effective_in_at'] == null
                    ? 'No punches recorded'
                    : '${OrgTime.time(d['effective_in_at'])} – ${d['effective_out_at'] == null ? '(open)' : OrgTime.time(d['effective_out_at'])}'),
                if (d['effective_in_at'] != null) KeyValueRow('Source', sourceLabel(d['effective_source'] as String?)),
                KeyValueRow('Presence', OrgTime.hm(d['presence_seconds'])),
                KeyValueRow('Credited', OrgTime.hm(d['credited_seconds'])),
                KeyValueRow('Short', OrgTime.hm(d['shortfall_seconds'])),
                KeyValueRow('Extra', '${OrgTime.hm(d['extra_seconds'])} (not overtime pay)'),
                if (d['is_late'] == true) KeyValueRow('Late by', OrgTime.hm(d['late_seconds'])),
                if (d['is_early_departure'] == true) KeyValueRow('Left early by', OrgTime.hm(d['early_seconds'])),
                if ((d['leave_conflict_seconds'] as num? ?? 0) > 0)
                  KeyValueRow('Leave overlap', '${OrgTime.hm(d['leave_conflict_seconds'])} — flagged for HR'),
              ]),
            ),
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Original punches', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.sm),
                if (events.isEmpty)
                  Text('None recorded.', style: Theme.of(context).textTheme.bodyMedium)
                else
                  for (final e in events)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: AppIcon(e['action'] == 'IN' ? Icons.login_rounded : Icons.logout_rounded,
                          color: AppColors.primary),
                      title: Text('${e['action'] == 'IN' ? 'Check in' : 'Check out'} · ${OrgTime.time(e['at'])}'),
                      subtitle: Text('${e['distance_m']} m from office · ±${e['accuracy_m']} m'
                          '${e['integrity_level'] == 'software' ? ' · test device' : ' · verified phone'}'),
                    ),
              ]),
            ),
            if (adjustments.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              SectionCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Approved corrections', style: Theme.of(context).textTheme.titleSmall),
                  for (final a in adjustments)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const AppIcon(Icons.history_edu_rounded, color: AppColors.warning),
                      title: Text('Revision ${a['revision']}: ${OrgTime.time(a['effective_in_at'])} – ${OrgTime.time(a['effective_out_at'])}'),
                      subtitle: Text('Approved by ${a['approved_by'] ?? '—'} · ${a['reason']}'),
                    ),
                ]),
              ),
            ],
            if (corrections.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              SectionCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Correction requests', style: Theme.of(context).textTheme.titleSmall),
                  for (final c in corrections)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Request · ${c['state']}'),
                      trailing: const AppIcon(Icons.chevron_right_rounded),
                      onTap: own ? () => context.push('/requests/${c['id']}') : null,
                    ),
                ]),
              ),
            ],
            if (own) ...[
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: () => context.push('/corrections/new?date=$date'),
                icon: const AppIcon(Icons.edit_calendar_outlined),
                label: const Text('Request correction'),
              ),
            ],
          ]);
        },
      ),
    );
  }
}
