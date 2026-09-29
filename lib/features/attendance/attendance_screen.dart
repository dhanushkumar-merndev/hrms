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
        label: const Text('Regularize'),
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
                final rows = ((d['rows'] as List?) ?? const [])
                    .map((e) => (e as Map).cast<String, dynamic>())
                    .where((r) => _filter == null || r['status'] == _filter)
                    .toList();
                final totals = (d['totals'] as Map).cast<String, dynamic>();
                return ListView(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, 96),
                  children: [
                    _Totals(totals: totals),
                    const SizedBox(height: AppSpacing.lg),
                    if (_calendar)
                      _CalendarGrid(month: _month, rows: rows)
                    else if (rows.isEmpty)
                      const EmptyState(
                        icon: Icons.event_note_outlined,
                        title: 'No attendance days',
                        message: 'There are no scheduled days for this period.',
                      )
                    else
                      for (final r in rows) ...[_DayRow(r), const SizedBox(height: AppSpacing.sm)],
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
      child: Row(children: [
        IconButton(
          tooltip: 'Previous month',
          onPressed: () => onChange(DateTime(month.year, month.month - 1)),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: Text(DateFormat('MMMM yyyy').format(month),
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        ),
        IconButton(
          tooltip: 'Next month',
          onPressed: canNext ? () => onChange(DateTime(month.year, month.month + 1)) : null,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ]),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.totals});
  final Map<String, dynamic> totals;

  @override
  Widget build(BuildContext context) {
    final partial = totals['is_partial'] == true;
    final unresolved = (totals['unresolved_days'] as num?)?.toInt() ?? 0;
    Widget stat(String label, String value, [Color? color]) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 2),
            Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: color ?? AppColors.text)),
          ]),
        );
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          stat('Expected', OrgTime.hm(totals['required_seconds'])),
          stat('Worked', OrgTime.hm(totals['credited_seconds'])),
          stat('Short', OrgTime.hm(totals['shortfall_seconds']), AppColors.error),
          stat('Extra', OrgTime.hm(totals['extra_seconds'])),
        ]),
        const SizedBox(height: AppSpacing.md),
        Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
          StatusChip('${totals['present_days']} present', tone: ChipTone.success),
          if ((totals['late_days'] as num? ?? 0) > 0) StatusChip('${totals['late_days']} late', tone: ChipTone.warning),
          if ((totals['absent_days'] as num? ?? 0) > 0) StatusChip('${totals['absent_days']} absent', tone: ChipTone.error),
          if ((totals['leave_days'] as num? ?? 0) > 0) StatusChip('${totals['leave_days']} leave', tone: ChipTone.info),
          if (unresolved > 0) StatusChip('$unresolved unresolved', tone: ChipTone.error),
        ]),
        if (partial) ...[
          const SizedBox(height: AppSpacing.sm),
          Text('Totals are partial: some days are in progress or need a correction.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: AppSpacing.xs),
        Text('Extra time is informational and is not overtime pay.', style: Theme.of(context).textTheme.bodySmall),
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
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        onTap: () => context.push('/attendance/day?date=${r['shift_date']}'),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(children: [
            SizedBox(
              width: 52,
              child: Column(children: [
                Text(OrgTime.date(r['shift_date'] as String?, pattern: 'd'),
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                Text(OrgTime.date(r['shift_date'] as String?, pattern: 'EEE'), style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                StatusChip(label, tone: tone, icon: icon),
                const SizedBox(height: 6),
                if (hasPunch)
                  Text(
                    '${OrgTime.time(r['effective_in_at'])} – ${r['effective_out_at'] == null ? '…' : OrgTime.time(r['effective_out_at'])}'
                    '${r['effective_source'] == 'manual' ? ' · manual' : r['effective_source'] == 'mixed' ? ' · corrected' : ''}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                else if (r['is_required'] == true)
                  Text('Shift ${OrgTime.time(r['start_at'])} – ${OrgTime.time(r['end_at'])}',
                      style: Theme.of(context).textTheme.bodyMedium),
                if (slots > 0) Text(leaveSlotLabel(slots), style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            if (r['status'] == 'present')
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(OrgTime.hm(r['credited_seconds']), style: const TextStyle(fontWeight: FontWeight.w600)),
                if ((r['shortfall_seconds'] as num? ?? 0) > 0)
                  Text('-${OrgTime.hm(r['shortfall_seconds'])}', style: const TextStyle(color: AppColors.error, fontSize: 13)),
              ]),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
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
