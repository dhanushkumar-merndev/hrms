import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/states.dart';
import '../home/home_providers.dart';
import 'attendance_ui.dart';

final myAttendanceProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, (String, String)>((ref, range) async {
  cacheFor(ref, const Duration(minutes: 5));
  return (await ref.read(apiProvider).rpc('list_my_attendance', {'p_from': range.$1, 'p_to': range.$2})).map;
});

/// S07 — own attendance: month, list/calendar toggle, totals, status chips.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key, this.filter});
  final String? filter;

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  late DateTime _month;
  bool _calendar = false;
  bool _showUpcoming = false;
  late String? _filter = widget.filter;

  @override
  void initState() {
    super.initState();
    final t = OrgTime.today();
    _month = DateTime(t.year, t.month);
  }

  (String, String) get _range {
    final last = DateTime(_month.year, _month.month + 1, 0);
    return (OrgTime.ymd(_month), OrgTime.ymd(last));
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(myAttendanceProvider(_range));
    return Scaffold(
      appBar: AppBar(title: const Text('Attendance'), actions: [
        IconButton(
          tooltip: _calendar ? 'Show list' : 'Show calendar',
          icon: Icon(_calendar ? Icons.view_list_rounded : Icons.calendar_month_rounded),
          onPressed: () => setState(() => _calendar = !_calendar),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/corrections/new'),
        icon: const Icon(Icons.edit_calendar_outlined),
        label: const Text('Fix a punch'),
      ),
      body: Column(children: [
        const OfflineBanner(),
        _MonthBar(
          month: _month,
          onChange: (m) => setState(() => _month = m),
          canNext: _month.isBefore(DateTime(OrgTime.today().year, OrgTime.today().month)),
        ),
        if (_filter != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                label: const Text('Needs correction'),
                onDeleted: () => setState(() => _filter = null),
              ),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.refresh(myAttendanceProvider(_range).future),
            child: AsyncView(
              value: data,
              onRetry: () => ref.invalidate(myAttendanceProvider(_range)),
              builder: (d) {
                final all = ((d['rows'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
                final rows = all.where((r) => _filter == null || r['status'] == _filter).toList();
                final totals = (d['totals'] as Map).cast<String, dynamic>();
                final today = OrgTime.ymd(OrgTime.today());
                final past = rows.where((r) => (r['shift_date'] as String).compareTo(today) <= 0).toList()
                  ..sort((a, b) => (b['shift_date'] as String).compareTo(a['shift_date'] as String));
                final upcoming = rows.where((r) => (r['shift_date'] as String).compareTo(today) > 0).toList()
                  ..sort((a, b) => (a['shift_date'] as String).compareTo(b['shift_date'] as String));
                return ListView(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, 96),
                  children: [
                    _Totals(
                      totals: totals,
                      inProgress: all.where((r) => r['status'] == 'in_progress').length,
                      needsCorrection: all.where((r) => r['status'] == 'needs_correction').length,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    if (_calendar)
                      _CalendarGrid(month: _month, rows: rows)
                    else if (rows.isEmpty)
                      const EmptyState(
                        icon: Icons.event_note_outlined,
                        title: 'No attendance days',
                        message: 'There are no scheduled days for this period.',
                      )
                    else ...[
                      // Today first, then earlier days; future days stay folded
                      // away so the days that matter are on top.
                      for (final r in past) ...[_DayRow(r), const SizedBox(height: AppSpacing.sm)],
                      if (upcoming.isNotEmpty && past.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                          child: Material(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              onTap: () => setState(() => _showUpcoming = !_showUpcoming),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 16),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      _showUpcoming ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                                      size: 18,
                                      color: AppColors.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _showUpcoming
                                          ? 'Hide upcoming days'
                                          : 'Show ${upcoming.length} upcoming ${upcoming.length == 1 ? 'day' : 'days'}',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (_showUpcoming || past.isEmpty)
                        for (final r in upcoming) ...[_DayRow(r), const SizedBox(height: AppSpacing.sm)],
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ]),
    );
  }
}

class _MonthBar extends StatelessWidget {
  const _MonthBar({required this.month, required this.onChange, required this.canNext});
  final DateTime month;
  final ValueChanged<DateTime> onChange;
  final bool canNext;

  @override
  Widget build(BuildContext context) {
    final now = OrgTime.today();
    final isCurrentMonth = month.year == now.year && month.month == now.month;

    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.md, AppSpacing.page, AppSpacing.sm),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        IconButton(
          tooltip: 'Previous month',
          onPressed: () => onChange(DateTime(month.year, month.month - 1)),
          icon: const Icon(Icons.chevron_left_rounded, size: 22),
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.calendar_today_rounded, size: 16, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                DateFormat('MMMM yyyy').format(month),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.text),
              ),
              if (isCurrentMonth) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.attendanceCard,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Current',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.primary),
                  ),
                ),
              ],
            ],
          ),
        ),
        IconButton(
          tooltip: 'Next month',
          onPressed: canNext ? () => onChange(DateTime(month.year, month.month + 1)) : null,
          icon: const Icon(Icons.chevron_right_rounded, size: 22),
        ),
      ]),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.totals, required this.inProgress, required this.needsCorrection});
  final Map<String, dynamic> totals;
  final int inProgress;
  final int needsCorrection;

  @override
  Widget build(BuildContext context) {
    final short = (totals['shortfall_seconds'] as num? ?? 0) > 0;
    final extra = (totals['extra_seconds'] as num? ?? 0) > 0;

    Widget metricTile({
      required String label,
      required String value,
      required IconData icon,
      required Color bgColor,
      required Color borderColor,
      required Color iconColor,
      Color? valueColor,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
                  ),
                  Icon(icon, size: 16, color: iconColor),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: valueColor ?? AppColors.text,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final hasSubchips = (totals['late_days'] as num? ?? 0) > 0 ||
        (totals['absent_days'] as num? ?? 0) > 0 ||
        (totals['leave_days'] as num? ?? 0) > 0 ||
        inProgress > 0 ||
        needsCorrection > 0;

    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // 2x2 Bento Metric Grid
        Row(
          children: [
            metricTile(
              label: 'Expected',
              value: OrgTime.hm(totals['required_seconds']),
              icon: Icons.schedule_rounded,
              bgColor: const Color(0xFFF6F8FC),
              borderColor: const Color(0xFFE2E8F0),
              iconColor: AppColors.primary,
            ),
            const SizedBox(width: AppSpacing.sm),
            metricTile(
              label: 'Worked',
              value: OrgTime.hm(totals['credited_seconds']),
              icon: Icons.timer_outlined,
              bgColor: const Color(0xFFF0FDF4),
              borderColor: const Color(0xFFDCFCE7),
              iconColor: AppColors.success,
              valueColor: AppColors.success,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            metricTile(
              label: 'Shortfall',
              value: OrgTime.hm(totals['shortfall_seconds']),
              icon: Icons.arrow_downward_rounded,
              bgColor: short ? const Color(0xFFFEF2F2) : const Color(0xFFF8FAFC),
              borderColor: short ? const Color(0xFFFEE2E2) : const Color(0xFFE2E8F0),
              iconColor: short ? AppColors.error : AppColors.textSecondary,
              valueColor: short ? AppColors.error : AppColors.text,
            ),
            const SizedBox(width: AppSpacing.sm),
            metricTile(
              label: 'Extra Time',
              value: OrgTime.hm(totals['extra_seconds']),
              icon: Icons.bolt_rounded,
              bgColor: extra ? const Color(0xFFFAF5FF) : const Color(0xFFF8FAFC),
              borderColor: extra ? const Color(0xFFF3E8FF) : const Color(0xFFE2E8F0),
              iconColor: extra ? const Color(0xFF8B5CF6) : AppColors.textSecondary,
              valueColor: extra ? const Color(0xFF7C3AED) : AppColors.text,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        // Full width container for attendance status breakdown
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppColors.success,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Monthly Attendance',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.text,
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${totals['present_days']} present',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF15803D),
                      ),
                    ),
                  ),
                ],
              ),
              if (hasSubchips) ...[
                const SizedBox(height: 10),
                Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
                  if ((totals['late_days'] as num? ?? 0) > 0)
                    StatusChip('${totals['late_days']} late', tone: ChipTone.warning),
                  if ((totals['absent_days'] as num? ?? 0) > 0)
                    StatusChip('${totals['absent_days']} absent', tone: ChipTone.error),
                  if ((totals['leave_days'] as num? ?? 0) > 0)
                    StatusChip('${totals['leave_days']} leave', tone: ChipTone.info),
                  if (inProgress > 0) StatusChip('$inProgress in progress', tone: ChipTone.info),
                  if (needsCorrection > 0) StatusChip('$needsCorrection to fix', tone: ChipTone.error),
                ]),
              ],
            ],
          ),
        ),
        if (inProgress > 0 || needsCorrection > 0) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            needsCorrection > 0
                ? 'Days to fix are left out of the totals until you send a correction.'
                : 'Today is added to the totals when you check out.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline_rounded, size: 15, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Extra time is informational and is not overtime pay.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow(this.r);
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final (label, tone, icon) = dayStatus(r);
    final slots = (r['leave_slots'] as num?)?.toInt() ?? 0;
    final hasPunch = r['effective_in_at'] != null;
    final isToday = r['shift_date'] == OrgTime.ymd(OrgTime.today());

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        onTap: () => context.push('/attendance/day?date=${r['shift_date']}'),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
            border: Border.all(
              color: isToday ? AppColors.primary.withValues(alpha: 0.45) : AppColors.border,
              width: isToday ? 1.5 : 1.0,
            ),
          ),
          child: Row(children: [
            Container(
              width: 50,
              height: 52,
              decoration: BoxDecoration(
                color: isToday ? AppColors.attendanceCard : const Color(0xFFF4F6F9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    OrgTime.date(r['shift_date'] as String?, pattern: 'd'),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isToday ? AppColors.primary : AppColors.text,
                    ),
                  ),
                  Text(
                    OrgTime.date(r['shift_date'] as String?, pattern: 'EEE'),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isToday ? AppColors.primary : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(
                  children: [
                    StatusChip(label, tone: tone, icon: icon),
                    if (isToday) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'Today',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.primary),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                if (hasPunch)
                  Row(
                    children: [
                      const Icon(Icons.schedule_rounded, size: 13, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '${OrgTime.time(r['effective_in_at'])} – ${r['effective_out_at'] == null ? '…' : OrgTime.time(r['effective_out_at'])}'
                          '${r['effective_source'] == 'manual' ? ' · manual' : r['effective_source'] == 'mixed' ? ' · corrected' : ''}',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  )
                else if (r['is_required'] == true)
                  Row(
                    children: [
                      const Icon(Icons.schedule_rounded, size: 13, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Shift ${OrgTime.time(r['start_at'])} – ${OrgTime.time(r['end_at'])}',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                if (slots > 0) Text(leaveSlotLabel(slots), style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            if (r['status'] == 'present')
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(OrgTime.hm(r['credited_seconds']), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  if ((r['shortfall_seconds'] as num? ?? 0) > 0)
                    Text('-${OrgTime.hm(r['shortfall_seconds'])}', style: const TextStyle(color: AppColors.error, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFFB0B9C6), size: 20),
          ]),
        ),
      ),
    );
  }
}

class _CalendarGrid extends StatelessWidget {
  const _CalendarGrid({required this.month, required this.rows});
  final DateTime month;
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final byDate = {for (final r in rows) r['shift_date'] as String: r};
    final first = DateTime(month.year, month.month);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final lead = first.weekday - 1; // Monday first
    return SectionCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(children: [
        Row(children: [
          for (final d in const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])
            Expanded(child: Center(child: Text(d, style: Theme.of(context).textTheme.bodySmall))),
        ]),
        const SizedBox(height: AppSpacing.sm),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var i = 0; i < lead; i++) const SizedBox.shrink(),
            for (var d = 1; d <= days; d++)
              _CalendarCell(
                day: d,
                row: byDate[OrgTime.ymd(DateTime(month.year, month.month, d))],
                date: OrgTime.ymd(DateTime(month.year, month.month, d)),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(spacing: AppSpacing.md, runSpacing: 4, children: const [
          _Legend(color: AppColors.success, label: 'Present'),
          _Legend(color: AppColors.warning, label: 'Late / pending'),
          _Legend(color: AppColors.error, label: 'Absent / correction'),
          _Legend(color: AppColors.primary, label: 'Leave'),
          _Legend(color: Color(0xFFA7B1C2), label: 'Holiday / off'),
        ]),
      ]),
    );
  }
}

class _CalendarCell extends StatelessWidget {
  const _CalendarCell({required this.day, required this.row, required this.date});
  final int day;
  final Map<String, dynamic>? row;
  final String date;

  @override
  Widget build(BuildContext context) {
    final r = row;
    final (label, tone, _) = r == null ? ('No schedule', ChipTone.neutral, Icons.remove) : dayStatus(r);
    final color = switch (tone) {
      ChipTone.success => AppColors.success,
      ChipTone.warning => AppColors.warning,
      ChipTone.error => AppColors.error,
      ChipTone.info => AppColors.primary,
      ChipTone.neutral => const Color(0xFFA7B1C2),
    };
    return Semantics(
      label: '$day, $label',
      button: r != null,
      excludeSemantics: true,
      child: InkWell(
        onTap: r == null ? null : () => context.push('/attendance/day?date=$date'),
        borderRadius: BorderRadius.circular(10),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('$day', style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 4),
          Container(width: 8, height: 8, decoration: BoxDecoration(color: r == null ? Colors.transparent : color, shape: BoxShape.circle)),
        ]),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
