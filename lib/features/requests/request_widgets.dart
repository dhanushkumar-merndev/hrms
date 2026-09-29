import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';

(String, ChipTone) requestState(String? state) => switch (state) {
      'draft' => ('Draft', ChipTone.neutral),
      'submitted' => ('Submitted', ChipTone.info),
      'under_review' => ('In review', ChipTone.warning),
      'returned' => ('Returned for changes', ChipTone.warning),
      'approved' => ('Approved', ChipTone.success),
      'rejected' => ('Not approved', ChipTone.error),
      'cancelled' => ('Cancelled', ChipTone.neutral),
      'withdrawal_pending' => ('Withdrawal pending', ChipTone.warning),
      'cancellation_pending' => ('Cancellation pending', ChipTone.warning),
      _ => (state ?? '—', ChipTone.neutral),
    };

String unitsLabel(num? units) {
  final u = (units ?? 0).toInt();
  final days = u / 2;
  return days == days.roundToDouble() ? '${days.toInt()} day${days == 1 ? '' : 's'}' : '$days days';
}

String requestTitle(Map<String, dynamic> r) {
  if (r['kind'] == 'correction') return 'Attendance correction';
  final t = (r['leave_type'] as Map?)?['name'] as String?;
  return t ?? 'Leave';
}

String requestDates(Map<String, dynamic> r) {
  if (r['kind'] == 'correction') return OrgTime.date(r['target_shift_date'] as String?);
  final s = r['start_date'] as String?;
  final e = r['end_date'] as String?;
  if (s == e) return OrgTime.date(s);
  return '${OrgTime.date(s, pattern: 'd MMM')} – ${OrgTime.date(e, pattern: 'd MMM yyyy')}';
}

/// List row shared by "My requests" and the reviewer queue.
class RequestTile extends StatelessWidget {
  const RequestTile({super.key, required this.r, required this.onTap, this.showEmployee = false});
  final Map<String, dynamic> r;
  final VoidCallback onTap;
  final bool showEmployee;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = requestState(r['state'] as String?);
    final emp = (r['employee'] as Map?)?.cast<String, dynamic>();
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: r['kind'] == 'leave' ? AppColors.leaveCard : AppColors.attendanceCard,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(r['kind'] == 'leave' ? Icons.beach_access_outlined : Icons.edit_calendar_outlined,
                  color: r['kind'] == 'leave' ? AppColors.leaveAction : AppColors.attendanceAction),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (showEmployee && emp != null)
                  Text('${emp['name']} · ${emp['code']}', style: Theme.of(context).textTheme.titleSmall),
                Text(requestTitle(r), style: showEmployee ? Theme.of(context).textTheme.bodyMedium : Theme.of(context).textTheme.titleSmall),
                Text('${requestDates(r)}${r['kind'] == 'leave' ? ' · ${unitsLabel(r['units'] as num?)}' : ''}',
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  StatusChip(label, tone: tone),
                  if (r['edited'] == true) StatusChip('Edited · v${r['current_revision']}', tone: ChipTone.neutral),
                  if (showEmployee && r['reviewer_assigned'] == false)
                    const StatusChip('No approver', tone: ChipTone.error),
                ]),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
          ]),
        ),
      ),
    );
  }
}

/// Human-readable revision content for leave or correction payloads.
class RevisionView extends StatelessWidget {
  const RevisionView({super.key, required this.kind, required this.payload, this.onViewAttachment});
  final String kind;
  final Map<String, dynamic> payload;
  final VoidCallback? onViewAttachment;

  @override
  Widget build(BuildContext context) {
    if (kind == 'correction') {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        KeyValueRow('Shift date', OrgTime.date(payload['shift_date'] as String?)),
        KeyValueRow('Shift', '${OrgTime.time(payload['shift_start_at'])} – ${OrgTime.time(payload['shift_end_at'])}'),
        KeyValueRow('Proposed in', OrgTime.dateTime(payload['proposed_in_at'])),
        KeyValueRow('Proposed out', OrgTime.dateTime(payload['proposed_out_at'])),
        KeyValueRow('Reason', (payload['reason'] as String?) ?? '—'),
      ]);
    }
    final days = ((payload['days'] as List?) ?? const []).cast<Map>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      KeyValueRow('Type', (payload['leave_type_name'] as String?) ?? '—'),
      KeyValueRow('Dates', '${OrgTime.date(payload['start_date'] as String?)} – ${OrgTime.date(payload['end_date'] as String?)}'),
      KeyValueRow('Working days', unitsLabel(payload['units'] as num?)),
      KeyValueRow('Reason', (payload['reason'] as String?) ?? '—'),
      if (days.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.sm),
        for (final d in days)
          Text(
            '• ${OrgTime.date(d['day'] as String?, pattern: 'EEE d MMM')} — '
            '${switch (d['slot']) {
              'AM' => 'first half (${OrgTime.time(d['start_at'])}–${OrgTime.time(d['split_at'])})',
              'PM' => 'second half (${OrgTime.time(d['split_at'])}–${OrgTime.time(d['end_at'])})',
              _ => 'full day',
            }}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
      ],
      if (payload['attachment_file_version_id'] != null && onViewAttachment != null) ...[
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton.icon(
          onPressed: onViewAttachment,
          icon: const Icon(Icons.attach_file_rounded),
          label: const Text('View attachment'),
        ),
      ],
    ]);
  }
}

class EventTimeline extends StatelessWidget {
  const EventTimeline({super.key, required this.events});
  final List<Map> events;

  static String _label(String? a) => switch (a) {
        'submitted' => 'Submitted',
        'resubmitted' => 'Resubmitted',
        'edited' => 'Edited',
        'opened' => 'Opened for review',
        'approved' => 'Approved',
        'rejected' => 'Not approved',
        'returned' => 'Returned for changes',
        'withdrawn' => 'Withdrawn',
        'withdrawal_requested' => 'Withdrawal requested',
        'withdrawal_accepted' => 'Withdrawal accepted',
        'withdrawal_declined' => 'Withdrawal declined',
        'cancellation_requested' => 'Cancellation requested',
        'cancellation_approved' => 'Cancellation approved',
        'cancellation_declined' => 'Cancellation declined',
        'reassigned' => 'Reassigned',
        'holiday_reconciled' => 'Adjusted for a new holiday',
        _ => a ?? '',
      };

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final e in events)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Icon(Icons.circle, size: 10, color: AppColors.primary),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_label(e['action'] as String?)}${e['revision_no'] != null ? ' · v${e['revision_no']}' : ''}',
                    style: Theme.of(context).textTheme.bodyLarge),
                Text('${(e['actor'] as Map?)?['name'] ?? 'System'} · ${OrgTime.dateTime(e['created_at'])}',
                    style: Theme.of(context).textTheme.bodySmall),
                if (e['reason'] != null) Text('“${e['reason']}”', style: Theme.of(context).textTheme.bodyMedium),
              ]),
            ),
          ]),
        ),
    ]);
  }
}
