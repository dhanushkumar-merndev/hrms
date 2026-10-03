import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
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
  return days == days.roundToDouble()
      ? '${days.toInt()} day${days == 1 ? '' : 's'}'
      : '$days days';
}

String requestTitle(Map<String, dynamic> r) {
  if (r['kind'] == 'correction') return 'Attendance correction';
  if (r['kind'] == 'bank_details') {
    return r['request_mode'] == 'change'
        ? 'Bank account change'
        : 'Bank details setup';
  }
  if (r['change_category'] case final String category) return category;
  final t = (r['leave_type'] as Map?)?['name'] as String?;
  return t ?? 'Leave';
}

String requestDates(Map<String, dynamic> r) {
  if (r['kind'] == 'correction') {
    return OrgTime.date(r['target_shift_date'] as String?);
  }
  if (r['kind'] == 'bank_details') {
    return 'Submitted ${OrgTime.date(r['submitted_at'] as String?)}';
  }
  if (r['change_category'] != null) {
    return 'Submitted ${OrgTime.date(r['submitted_at'] as String?)}';
  }
  final s = r['start_date'] as String?;
  final e = r['end_date'] as String?;
  if (s == e) return OrgTime.date(s);
  return '${OrgTime.date(s, pattern: 'd MMM')} – ${OrgTime.date(e, pattern: 'd MMM yyyy')}';
}

/// List row shared by "My requests" and the reviewer queue.
class RequestTile extends StatelessWidget {
  const RequestTile({
    super.key,
    required this.r,
    required this.onTap,
    this.showEmployee = false,
  });
  final Map<String, dynamic> r;
  final VoidCallback onTap;
  final bool showEmployee;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = requestState(r['state'] as String?);
    final emp = (r['employee'] as Map?)?.cast<String, dynamic>();
    final isLeave = r['kind'] == 'leave';
    final isBank = r['kind'] == 'bank_details';
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isLeave
                      ? AppColors.leaveCard
                      : isBank
                      ? AppColors.salaryCard
                      : AppColors.attendanceCard,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AppIcon(
                  isLeave
                      ? Icons.beach_access_outlined
                      : isBank
                      ? Icons.account_balance_outlined
                      : Icons.edit_calendar_outlined,
                  color: isLeave
                      ? AppColors.leaveAction
                      : isBank
                      ? AppColors.salaryAction
                      : AppColors.attendanceAction,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showEmployee && emp != null)
                      Text(
                        '${emp['name']} · ${emp['code']}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    Text(
                      requestTitle(r),
                      style: showEmployee
                          ? Theme.of(context).textTheme.bodyMedium
                          : Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${requestDates(r)}${isLeave ? ' · ${unitsLabel(r['units'] as num?)}' : ''}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        StatusChip(label, tone: tone),
                        if (r['edited'] == true)
                          StatusChip(
                            'Edited · v${r['current_revision']}',
                            tone: ChipTone.neutral,
                          ),
                        if (showEmployee && r['reviewer_assigned'] == false)
                          const StatusChip('No approver', tone: ChipTone.error),
                      ],
                    ),
                  ],
                ),
              ),
              const AppIcon(
                Icons.chevron_right_rounded,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Human-readable revision content for leave or correction payloads.
class RevisionView extends StatelessWidget {
  const RevisionView({
    super.key,
    required this.kind,
    required this.payload,
    this.onViewAttachment,
  });
  final String kind;
  final Map<String, dynamic> payload;
  final VoidCallback? onViewAttachment;

  @override
  Widget build(BuildContext context) {
    if (kind == 'bank_details') {
      final change = payload['mode'] == 'change';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyValueRow(
            'Request',
            change ? 'Change approved account' : 'Set up salary account',
          ),
          KeyValueRow('Bank', (payload['bank_name'] as String?) ?? '—'),
          KeyValueRow(
            'Account holder',
            (payload['account_holder'] as String?) ?? '—',
          ),
          KeyValueRow(
            'Account',
            payload['account_last4'] == null
                ? '—'
                : '•••• ${payload['account_last4']}',
          ),
          KeyValueRow('IFSC', (payload['ifsc'] as String?) ?? '—'),
          KeyValueRow(
            'Reason',
            (payload['reason'] as String?) ?? (change ? '—' : 'Initial setup'),
          ),
          if (payload['attachment_file_version_id'] != null &&
              onViewAttachment != null) ...[
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              onPressed: onViewAttachment,
              icon: const AppIcon(Icons.verified_user_outlined),
              label: const Text('View bank proof'),
            ),
          ],
        ],
      );
    }
    if (kind == 'profile_details') {
      final patch = ((payload['patch'] as Map?) ?? const {})
          .cast<String, dynamic>();
      const labels = {
        'personal_email': 'Personal email',
        'personal_phone': 'Personal phone',
        'address': 'Address',
        'emergency_contact_name': 'Emergency contact name',
        'emergency_contact_phone': 'Emergency contact phone',
        'date_of_birth': 'Date of birth',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in patch.entries)
            KeyValueRow(
              labels[entry.key] ?? entry.key,
              entry.value == null ? 'Cleared' : '${entry.value}',
            ),
        ],
      );
    }
    if (kind == 'correction') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyValueRow(
            'Shift date',
            OrgTime.date(payload['shift_date'] as String?),
          ),
          KeyValueRow(
            'Shift',
            '${OrgTime.time(payload['shift_start_at'])} – ${OrgTime.time(payload['shift_end_at'])}',
          ),
          KeyValueRow(
            'Proposed in',
            OrgTime.dateTime(payload['proposed_in_at']),
          ),
          KeyValueRow(
            'Proposed out',
            OrgTime.dateTime(payload['proposed_out_at']),
          ),
          KeyValueRow('Reason', (payload['reason'] as String?) ?? '—'),
        ],
      );
    }
    final days = ((payload['days'] as List?) ?? const []).cast<Map>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KeyValueRow('Type', (payload['leave_type_name'] as String?) ?? '—'),
        KeyValueRow(
          payload['start_date'] == payload['end_date'] ? 'Date' : 'Dates',
          payload['start_date'] == payload['end_date']
              ? OrgTime.date(payload['start_date'] as String?)
              : '${OrgTime.date(payload['start_date'] as String?)} – ${OrgTime.date(payload['end_date'] as String?)}',
        ),
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
        if (payload['attachment_file_version_id'] != null &&
            onViewAttachment != null) ...[
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: onViewAttachment,
            icon: const AppIcon(Icons.attach_file_rounded),
            label: const Text('View attachment'),
          ),
        ],
      ],
    );
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
    'auto_approved' => 'Approved (Admin, no approver needed)',
    'revoked' => 'Revoked',
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

  /// Illustration + soft tint for each step, so the history reads at a glance.
  static (IconData, Color) _art(String? a) => switch (a) {
    'submitted' => (Icons.upload_file_rounded, AppColors.attendanceCard),
    'resubmitted' => (Icons.event_repeat_rounded, AppColors.attendanceCard),
    'edited' => (Icons.edit_note_rounded, AppColors.salaryCard),
    'opened' => (Icons.preview_outlined, AppColors.leaveCard),
    'approved' || 'withdrawal_accepted' || 'cancellation_approved' => (
      Icons.check_circle_rounded,
      AppColors.successSoft,
    ),
    'auto_approved' => (Icons.verified_rounded, AppColors.successSoft),
    'rejected' ||
    'withdrawal_declined' ||
    'cancellation_declined' => (Icons.cancel_rounded, AppColors.errorSoft),
    'returned' => (Icons.history_rounded, AppColors.warningSoft),
    'revoked' => (Icons.settings_backup_restore_rounded, AppColors.errorSoft),
    'withdrawn' || 'withdrawal_requested' || 'cancellation_requested' => (
      Icons.event_busy_rounded,
      AppColors.warningSoft,
    ),
    'reassigned' => (Icons.person_search_outlined, AppColors.workspaceCard),
    'holiday_reconciled' => (Icons.celebration_rounded, AppColors.holidayCard),
    _ => (Icons.task_alt_rounded, AppColors.attendanceCard),
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < events.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Rail: illustration bubble with a line joining the next step.
                SizedBox(
                  width: 44,
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _art(events[i]['action'] as String?).$2,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.surface,
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: AppIcon(
                          _art(events[i]['action'] as String?).$1,
                          size: 24,
                        ),
                      ),
                      if (i < events.length - 1)
                        Expanded(
                          child: Container(
                            width: 2,
                            margin: const EdgeInsets.symmetric(vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.border,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: 2,
                      bottom: i < events.length - 1 ? AppSpacing.lg : 0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_label(events[i]['action'] as String?)}'
                          '${events[i]['revision_no'] != null ? ' · v${events[i]['revision_no']}' : ''}',
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${(events[i]['actor'] as Map?)?['name'] ?? 'System'} · ${OrgTime.dateTime(events[i]['created_at'])}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (events[i]['reason'] != null) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '“${events[i]['reason']}”',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
