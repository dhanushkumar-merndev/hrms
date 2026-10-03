import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
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
          icon: AppIcon(_calendar ? Icons.view_list_rounded : Icons.calendar_month_rounded),
          onPressed: () => setState(() => _calendar = !_calendar),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/corrections/new'),
        icon: const AppIcon(Icons.edit_calendar_outlined),
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
              loading: const AttendanceSkeleton(),
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
                        Center(
                          child: TextButton.icon(
                            onPressed: () => setState(() => _showUpcoming = !_showUpcoming),
                            icon: Icon(
                              _showUpcoming ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                              size: 20,
                            ),
                            label: Text(_showUpcoming
                                ? 'Hide upcoming days'
                                : 'Show ${upcoming.length} upcoming ${upcoming.length == 1 ? 'day' : 'days'}'),
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

/// Soft background + strong foreground for a status tone.
(Color, Color) _toneColors(ChipTone tone) => switch (tone) {
      ChipTone.success => (AppColors.successSoft, AppColors.success),
      ChipTone.warning => (AppColors.warningSoft, AppColors.warning),
      ChipTone.error => (AppColors.errorSoft, AppColors.error),
      ChipTone.info => (AppColors.attendanceCard, AppColors.primary),
      ChipTone.neutral => (const Color(0xFFEFF1F4), AppColors.textSecondary),
    };

class _MonthBar extends StatelessWidget {
  const _MonthBar({required this.month, required this.onChange, required this.canNext});
  final DateTime month;
  final ValueChanged<DateTime> onChange;
  final bool canNext;

  @override
  Widget build(BuildContext context) {
    final now = OrgTime.today();
    final isCurrentMonth = month.year == now.year && month.month == now.month;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.sm, AppSpacing.page, AppSpacing.sm),
      child: Row(children: [
        IconButton.filledTonal(
          tooltip: 'Previous month',
          onPressed: () => onChange(DateTime(month.year, month.month - 1)),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: Column(children: [
            Text(DateFormat('MMMM yyyy').format(month),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.text)),
            if (isCurrentMonth)
              const Text('This month', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ]),
        ),
        IconButton.filledTonal(
          tooltip: 'Next month',
          onPressed: canNext ? () => onChange(DateTime(month.year, month.month + 1)) : null,
          icon: const Icon(Icons.chevron_right_rounded),
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

  int _n(String key) => (totals[key] as num? ?? 0).toInt();

  @override
  Widget build(BuildContext context) {
    final required = _n('required_seconds');
    final worked = _n('credited_seconds');
    final short = _n('shortfall_seconds');
    final extra = _n('extra_seconds');
    final progress = required <= 0 ? 0.0 : (worked / required).clamp(0.0, 1.0);
    // Present / Absent / Leave always fill the first row; extras follow.
    final counts = <(int, String, ChipTone)>[
      (_n('present_days'), 'Present', ChipTone.success),
      (_n('absent_days'), 'Absent', _n('absent_days') > 0 ? ChipTone.error : ChipTone.neutral),
      (_n('leave_days'), 'Leave', ChipTone.info),
      if (_n('late_days') > 0) (_n('late_days'), 'Late', ChipTone.warning),
      if (inProgress > 0) (inProgress, 'In progress', ChipTone.info),
      if (needsCorrection > 0) (needsCorrection, 'To fix', ChipTone.error),
    ];

    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          const AppIcon(Icons.timer_outlined, size: 44),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Worked this month', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 2),
              Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: OrgTime.hm(worked),
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.text),
                  ),
                  TextSpan(
                    text: '  of ${OrgTime.hm(required)}',
                    style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: AppSpacing.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: const Color(0xFFEFF1F4),
            color: AppColors.success,
            semanticsLabel: 'Worked ${OrgTime.hm(worked)} of ${OrgTime.hm(required)}',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(children: [
          Expanded(
            child: _Metric(
              label: 'Shortfall',
              value: OrgTime.hm(short),
              tone: short > 0 ? ChipTone.error : ChipTone.neutral,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: _Metric(
              label: 'Extra time',
              value: OrgTime.hm(extra),
              tone: extra > 0 ? ChipTone.info : ChipTone.neutral,
            ),
          ),
        ]),
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < counts.length; i += 3) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          Row(children: [
            for (var j = i; j < i + 3; j++) ...[
              if (j > i) const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: j < counts.length
                    ? _CountTile(count: counts[j].$1, label: counts[j].$2, tone: counts[j].$3)
                    : const SizedBox.shrink(),
              ),
            ],
          ]),
        ],
        const SizedBox(height: AppSpacing.md),
        Text(
          needsCorrection > 0
              ? 'Days to fix are left out of the totals until you send a correction.'
              : inProgress > 0
                  ? 'Today is added to the totals when you check out.'
                  : 'Extra time is shown for information. It is not overtime pay.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ]),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.tone});
  final String label;
  final String value;
  final ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _toneColors(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: tone == ChipTone.neutral ? AppColors.text : fg)),
      ]),
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({required this.count, required this.label, required this.tone});
  final int count;
  final String label;
  final ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _toneColors(tone);
    return Semantics(
      label: '$count $label',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          Text('$count', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: fg)),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
        ]),
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow(this.r);
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final (label, tone, _) = dayStatus(r);
    final (bg, fg) = _toneColors(tone);
    final slots = (r['leave_slots'] as num?)?.toInt() ?? 0;
    final hasPunch = r['effective_in_at'] != null;
    final isToday = r['shift_date'] == OrgTime.ymd(OrgTime.today());
    final source = r['effective_source'] == 'manual'
        ? ' · manual'
        : r['effective_source'] == 'mixed'
            ? ' · corrected'
            : '';
    final detail = [
      if (r['outside_reason'] != null)
        '${r['outside_reason']} · no check-in needed'
      else if (hasPunch)
        '${OrgTime.time(r['effective_in_at'])} – ${r['effective_out_at'] == null ? 'now' : OrgTime.time(r['effective_out_at'])}$source'
      else if (r['is_required'] == true)
        'Shift ${OrgTime.time(r['start_at'])} – ${OrgTime.time(r['end_at'])}',
      if (slots > 0) leaveSlotLabel(slots),
    ].join(' · ');
    final shortfall = (r['shortfall_seconds'] as num? ?? 0) > 0;

    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        side: BorderSide(
          color: isToday ? AppColors.primary.withValues(alpha: 0.5) : AppColors.border,
          width: isToday ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/attendance/day?date=${r['shift_date']}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(children: [
            Container(
              width: 50,
              height: 54,
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(OrgTime.date(r['shift_date'] as String?, pattern: 'd'),
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: fg, height: 1.1)),
                Text(OrgTime.date(r['shift_date'] as String?, pattern: 'EEE'),
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
              ]),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: fg)),
                  ),
                  if (isToday) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(6)),
                      child: const Text('Today',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
                    ),
                  ],
                ]),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                ],
              ]),
            ),
            if (r['status'] == 'present') ...[
              const SizedBox(width: AppSpacing.sm),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(OrgTime.hm(r['credited_seconds']),
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.text)),
                if (shortfall)
                  Text('-${OrgTime.hm(r['shortfall_seconds'])}',
                      style: const TextStyle(color: AppColors.error, fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ],
            const SizedBox(width: 4),
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
    final today = OrgTime.ymd(OrgTime.today());
    return SectionCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(children: [
        Row(children: [
          for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
            Expanded(
              child: Center(
                child: Text(d,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
              ),
            ),
        ]),
        const SizedBox(height: AppSpacing.sm),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var i = 0; i < lead; i++) const SizedBox.shrink(),
            for (var d = 1; d <= days; d++)
              _CalendarCell(
                day: d,
                row: byDate[OrgTime.ymd(DateTime(month.year, month.month, d))],
                date: OrgTime.ymd(DateTime(month.year, month.month, d)),
                isToday: OrgTime.ymd(DateTime(month.year, month.month, d)) == today,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(spacing: AppSpacing.md, runSpacing: 6, children: const [
          _Legend(tone: ChipTone.success, label: 'Present'),
          _Legend(tone: ChipTone.warning, label: 'Late / pending'),
          _Legend(tone: ChipTone.error, label: 'Absent / fix'),
          _Legend(tone: ChipTone.info, label: 'Leave'),
          _Legend(tone: ChipTone.neutral, label: 'Holiday / off'),
        ]),
      ]),
    );
  }
}

class _CalendarCell extends StatelessWidget {
  const _CalendarCell({required this.day, required this.row, required this.date, required this.isToday});
  final int day;
  final Map<String, dynamic>? row;
  final String date;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final r = row;
    final (label, tone, _) = r == null ? ('No schedule', ChipTone.neutral, Icons.remove) : dayStatus(r);
    final upcoming = r?['status'] == 'upcoming';
    final (bg, fg) = r == null || upcoming ? (Colors.transparent, AppColors.textSecondary) : _toneColors(tone);
    return Semantics(
      label: '$day, $label',
      button: r != null,
      excludeSemantics: true,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: isToday ? const BorderSide(color: AppColors.primary, width: 2) : BorderSide.none,
        ),
        child: InkWell(
          onTap: r == null ? null : () => context.push('/attendance/day?date=$date'),
          borderRadius: BorderRadius.circular(10),
          child: Center(
            child: Text('$day',
                style: TextStyle(fontSize: 14, fontWeight: r == null || upcoming ? FontWeight.w500 : FontWeight.w700, color: fg)),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.tone, required this.label});
  final ChipTone tone;
  final String label;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _toneColors(tone);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4), border: Border.all(color: fg, width: 1.5)),
      ),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
