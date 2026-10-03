import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/session_controller.dart';
import '../../core/files/save_file.dart';
import '../../core/files/xlsx.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/dialogs.dart';
import '../../core/widgets/paged_list.dart';
import '../../core/widgets/permission_gate.dart';
import '../../core/widgets/states.dart';
import '../../core/widgets/pill_tabs.dart';
import '../attendance/attendance_ui.dart';
import '../people/people_screen.dart';

enum RangeMode { day, week, month, custom }

/// Org-local 24 h clock for exports.
String hhmm(Object? iso) {
  final d = OrgTime.parse(iso);
  return d == null ? '' : DateFormat('HH:mm').format(OrgTime.local(d));
}

/// S24 — scoped hours report (manager: own teams by work date; HR/Admin:
/// organisation). Inclusive dates in the UI; the server applies half-open
/// intervals and scope. Admin can export an interim XLSX.
class HoursReportScreen extends ConsumerStatefulWidget {
  const HoursReportScreen({super.key, this.employeeId});
  final String? employeeId;

  @override
  ConsumerState<HoursReportScreen> createState() => _HoursReportScreenState();
}

class _HoursReportScreenState extends ConsumerState<HoursReportScreen> {
  RangeMode _mode = RangeMode.week;
  late DateTime _from;
  late DateTime _to;
  String? _teamId;
  String? _officeId;
  Map<String, dynamic>? _totals;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _setMode(RangeMode.week, OrgTime.today());
  }

  void _setMode(RangeMode mode, DateTime anchor) {
    final a = DateTime(anchor.year, anchor.month, anchor.day);
    _mode = mode;
    switch (mode) {
      case RangeMode.day:
        _from = a;
        _to = a;
      case RangeMode.week:
        _from = a.subtract(Duration(days: a.weekday - 1));
        _to = _from.add(const Duration(days: 6));
      case RangeMode.month:
        _from = DateTime(a.year, a.month);
        _to = DateTime(a.year, a.month + 1, 0);
      case RangeMode.custom:
        break;
    }
    _totals = null;
  }

  void _shift(int direction) {
    setState(() {
      switch (_mode) {
        case RangeMode.day:
          _setMode(_mode, _from.add(Duration(days: direction)));
        case RangeMode.week:
          _setMode(_mode, _from.add(Duration(days: 7 * direction)));
        case RangeMode.month:
          _setMode(_mode, DateTime(_from.year, _from.month + direction));
        case RangeMode.custom:
          break;
      }
    });
  }

  Future<void> _pickCustom() async {
    final today = OrgTime.today();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 5),
      lastDate: today.add(const Duration(days: 31)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
      helpText: 'Report dates (at most 366 days)',
    );
    if (r == null) return;
    if (r.end.difference(r.start).inDays > 365) {
      if (mounted) showMessage(context, 'Choose at most 366 days. Use the annual archive for longer periods.', error: true);
      return;
    }
    setState(() {
      _mode = RangeMode.custom;
      _from = r.start;
      _to = r.end;
      _totals = null;
    });
  }

  String get _rangeLabel {
    final f = DateFormat('d MMM yyyy');
    if (_from == _to) return f.format(_from);
    if (_mode == RangeMode.month) return DateFormat('MMMM yyyy').format(_from);
    return '${DateFormat('d MMM').format(_from)} – ${f.format(_to)}';
  }

  Map<String, dynamic> get _params => {
        'p_from': OrgTime.ymd(_from),
        'p_to': OrgTime.ymd(_to),
        'p_team_id': _teamId,
        'p_office_id': _officeId,
        'p_employee_ids': widget.employeeId == null ? null : [widget.employeeId],
      };

  Future<void> _export() async {
    setState(() => _exporting = true);
    final api = ref.read(apiProvider);
    try {
      final people = <Map<String, dynamic>>[];
      var offset = 0;
      while (true) {
        final page = (await api.rpc('get_hours_report', {..._params, 'p_limit': 100, 'p_offset': offset})).map;
        final rows = ((page['rows'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
        people.addAll(rows);
        offset += rows.length;
        if (rows.isEmpty || offset >= ((page['total'] as num?)?.toInt() ?? 0)) break;
      }
      final summary = XlsxSheet('Summary', columnWidths: const [12, 28, 10, 12, 12, 12, 12, 10, 10, 10, 10, 12])
        ..header(['Employee ID', 'Name', 'Status', 'Expected (min)', 'Worked (min)', 'Short (min)', 'Extra (min)',
          'Present days', 'Absent days', 'Late days', 'Leave days', 'Unresolved days']);
      final days = XlsxSheet('Days', columnWidths: const [12, 28, 12, 18, 8, 8, 8, 8, 12, 12, 10, 10, 10, 10, 8, 10, 8])
        ..header(['Employee ID', 'Name', 'Shift date', 'Status', 'Shift start', 'Shift end', 'In', 'Out', 'Source',
          'Leave', 'Required (min)', 'Worked (min)', 'Short (min)', 'Extra (min)', 'Late', 'Left early', 'Lunch paid']);
      for (final p in people) {
        final e = (p['employee'] as Map).cast<String, dynamic>();
        final t = (p['totals'] as Map).cast<String, dynamic>();
        int m(Object? s) => ((s as num?) ?? 0).toInt() ~/ 60;
        summary.add([e['code'], e['name'], e['status'], m(t['required_seconds']), m(t['credited_seconds']),
          m(t['shortfall_seconds']), m(t['extra_seconds']), t['present_days'], t['absent_days'], t['late_days'],
          t['leave_days'], t['unresolved_days']]);
        final detail = (await api.rpc('get_hours_report_days',
                {'p_employee_id': e['id'], 'p_from': OrgTime.ymd(_from), 'p_to': OrgTime.ymd(_to)}))
            .map;
        final rows = ((detail['rows'] as List?) ?? const []).map((x) => (x as Map).cast<String, dynamic>()).toList()
          ..sort((a, b) => (a['shift_date'] as String).compareTo(b['shift_date'] as String));
        for (final r in rows) {
          days.add([e['code'], e['name'], XlsxDate.parse(r['shift_date'] as String), dayStatus(r).$1,
            hhmm(r['start_at']), hhmm(r['end_at']), hhmm(r['effective_in_at']), hhmm(r['effective_out_at']),
            r['effective_in_at'] == null ? '' : sourceLabel(r['effective_source'] as String?),
            leaveSlotLabel((r['leave_slots'] as num?)?.toInt() ?? 0), m(r['required_seconds']),
            m(r['credited_seconds']), m(r['shortfall_seconds']), m(r['extra_seconds']), r['is_late'] == true,
            r['is_early_departure'] == true, r['lunch_paid'] == true]);
        }
      }
      final about = XlsxSheet('About', columnWidths: const [24, 60])
        ..header(['Field', 'Value'])
        ..add(['Period', '${OrgTime.ymd(_from)} to ${OrgTime.ymd(_to)} (inclusive)'])
        ..add(['Time zone', 'Times are local office time; dates are shift start dates'])
        ..add(['Generated', OrgTime.dateTime(DateTime.now().toUtc().toIso8601String())])
        ..add(['Status', _to.isBefore(OrgTime.today()) ? 'Closed range' : 'Interim — the range includes today or later'])
        ..add(['Note', 'Extra time is informational, not overtime pay. Unresolved days are excluded from worked totals.']);
      final bytes = buildXlsx([summary, days, about]);
      final saved = await saveBytesAs(bytes, 'Hours_${OrgTime.ymd(_from)}_${OrgTime.ymd(_to)}.xlsx', xlsxMime);
      if (mounted && saved) showMessage(context, 'Report saved. It is now your own file on this phone.');
    } on ApiException catch (e) {
      if (mounted) showMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionContextProvider);
    final structure = ref.watch(orgStructureProvider).value;
    final teams = structureList(structure, 'teams');
    final offices = structureList(structure, 'offices');
    final api = ref.read(apiProvider);
    final totals = _totals;
    return Scaffold(
      appBar: AppBar(title: const Text('Hours report'), actions: [
        if (session?.isAdmin ?? false)
          IconButton(
            tooltip: 'Export Excel report',
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const AppIcon(Icons.download_rounded),
          ),
      ]),
      body: PermissionGate(
        allowed: (s) => s.canTeamReports,
        child: Column(children: [
          const OfflineBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.sm, AppSpacing.page, 0),
            child: PillTabs<RangeMode>(
              options: const [
                (RangeMode.day, 'Day'),
                (RangeMode.week, 'Week'),
                (RangeMode.month, 'Month'),
                (RangeMode.custom, 'Custom'),
              ],
              value: _mode,
              onChanged: (v) {
                if (v == RangeMode.custom) {
                  _pickCustom();
                } else {
                  setState(() => _setMode(v, _from));
                }
              },
            ),
          ),
          Row(children: [
            IconButton(
                tooltip: 'Previous', onPressed: _mode == RangeMode.custom ? null : () => _shift(-1),
                icon: const AppIcon(Icons.chevron_left_rounded)),
            Expanded(
              child: TextButton(onPressed: _pickCustom, child: Text(_rangeLabel, style: Theme.of(context).textTheme.titleSmall)),
            ),
            IconButton(
                tooltip: 'Next', onPressed: _mode == RangeMode.custom ? null : () => _shift(1),
                icon: const AppIcon(Icons.chevron_right_rounded)),
          ]),
          if (widget.employeeId == null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: Row(children: [
                FilterMenu(
                  label: 'Team',
                  value: _teamId,
                  options: [for (final t in teams) (t['id'] as String, t['name'] as String)],
                  onChanged: (v) => setState(() {
                    _teamId = v;
                    _totals = null;
                  }),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilterMenu(
                  label: 'Office',
                  value: _officeId,
                  options: [for (final o in offices) (o['id'] as String, o['name'] as String)],
                  onChanged: (v) => setState(() {
                    _officeId = v;
                    _totals = null;
                  }),
                ),
              ]),
            ),
          Expanded(
            child: PagedList<Map<String, dynamic>>(
              key: ValueKey('${OrgTime.ymd(_from)}|${OrgTime.ymd(_to)}|$_teamId|$_officeId'),
              header: totals == null ? null : _TotalsCard(totals: totals),
              fetch: (cursor) async {
                final offset = (cursor as int?) ?? 0;
                final res = (await api.rpc('get_hours_report', {..._params, 'p_limit': 25, 'p_offset': offset})).map;
                if (offset == 0 && mounted) {
                  final t = (res['totals'] as Map?)?.cast<String, dynamic>();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _totals = t);
                  });
                }
                return offsetPage(res, offset);
              },
              empty: const EmptyState(icon: Icons.groups_outlined, title: 'No one in this scope for these dates'),
              itemBuilder: (context, row) => _EmployeeHours(row: row, from: _from, to: _to),
            ),
          ),
        ]),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals});
  final Map<String, dynamic> totals;

  @override
  Widget build(BuildContext context) {
    final unresolved = (totals['unresolved_days'] as num?)?.toInt() ?? 0;
    // 2 x 2 tinted tiles: big company totals never squeeze into one line.
    Widget stat(String label, Object? seconds, Color bg, [Color? color]) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(OrgTime.hm(seconds as num?),
                    maxLines: 1,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color ?? AppColors.text)),
              ),
            ]),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            stat('Expected', totals['required_seconds'], const Color(0xFFEFF1F4)),
            const SizedBox(width: AppSpacing.sm),
            stat('Worked', totals['credited_seconds'], AppColors.successSoft, AppColors.success),
          ]),
          const SizedBox(height: AppSpacing.sm),
          Row(children: [
            stat('Short', totals['shortfall_seconds'], AppColors.errorSoft, AppColors.error),
            const SizedBox(width: AppSpacing.sm),
            stat('Extra', totals['extra_seconds'], AppColors.attendanceCard, AppColors.primary),
          ]),
          if (unresolved > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            StatusChip('$unresolved unresolved day(s) — totals are partial', tone: ChipTone.warning),
          ],
          const SizedBox(height: AppSpacing.xs),
          Text('Extra time is informational and is not overtime pay.', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _EmployeeHours extends ConsumerStatefulWidget {
  const _EmployeeHours({required this.row, required this.from, required this.to});
  final Map<String, dynamic> row;
  final DateTime from;
  final DateTime to;

  @override
  ConsumerState<_EmployeeHours> createState() => _EmployeeHoursState();
}

class _EmployeeHoursState extends ConsumerState<_EmployeeHours> {
  Future<Map<String, dynamic>>? _days;

  @override
  Widget build(BuildContext context) {
    final e = (widget.row['employee'] as Map).cast<String, dynamic>();
    final t = (widget.row['totals'] as Map).cast<String, dynamic>();
    final short = (t['shortfall_seconds'] as num?) ?? 0;
    final unresolved = (t['unresolved_days'] as num?)?.toInt() ?? 0;
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        title: Text('${e['name']}', style: Theme.of(context).textTheme.titleSmall),
        subtitle: Text('${e['code']} · worked ${OrgTime.hm(t['credited_seconds'] as num?)}'
            '${short > 0 ? ' · short ${OrgTime.hm(short)}' : ''}'
            '${unresolved > 0 ? ' · $unresolved unresolved' : ''}'),
        onExpansionChanged: (open) {
          if (open && _days == null) {
            setState(() {
              _days = ref.read(apiProvider).rpc('get_hours_report_days', {
                'p_employee_id': e['id'],
                'p_from': OrgTime.ymd(widget.from),
                'p_to': OrgTime.ymd(widget.to),
              }).then((r) => r.map);
            });
          }
        },
        children: [
          FutureBuilder<Map<String, dynamic>>(
            future: _days,
            builder: (context, snap) {
              if (snap.hasError) return ErrorState(error: snap.error!);
              if (!snap.hasData) return const SkeletonList(items: 2, height: 48);
              final rows = ((snap.data!['rows'] as List?) ?? const []).map((x) => (x as Map).cast<String, dynamic>()).toList();
              if (rows.isEmpty) return const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: Text('No scheduled days.'));
              return Column(children: [
                for (final r in rows)
                  ListTile(
                    dense: true,
                    onTap: () => context.push('/attendance/day?date=${r['shift_date']}&employee=${e['id']}'),
                    title: Text(OrgTime.date(r['shift_date'] as String?, pattern: 'EEE d MMM')),
                    subtitle: Text([
                      dayStatus(r).$1,
                      if (r['effective_in_at'] != null)
                        '${OrgTime.time(r['effective_in_at'])}–${r['effective_out_at'] == null ? '…' : OrgTime.time(r['effective_out_at'])}',
                      if (r['effective_source'] == 'manual') 'manual',
                      if (r['lunch_paid'] == true && r['effective_in_at'] != null) 'paid lunch',
                    ].join(' · ')),
                    trailing: Text(OrgTime.hm(r['credited_seconds'] as num?, compact: true)),
                  ),
              ]);
            },
          ),
        ],
      ),
    );
  }
}
