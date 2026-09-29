import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/theme.dart';
import '../../core/auth/session_controller.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/illustration.dart';
import '../../core/widgets/states.dart';
import 'home_providers.dart';

/// S03 — Home, following reference 01.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(homeSummaryProvider);
    final session = ref.watch(sessionContextProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(homeSummaryProvider.future),
              child: AsyncView(
                value: summary,
                onRetry: () => ref.invalidate(homeSummaryProvider),
                loading: const SkeletonList(items: 5, height: 120),
                builder: (data) => _HomeBody(data: data, name: session?.firstName ?? ''),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody({required this.data, required this.name});
  final Map<String, dynamic> data;
  final String name;

  @override
  Widget build(BuildContext context) {
    final org = (data['org'] as Map).cast<String, dynamic>();
    final me = (data['me'] as Map).cast<String, dynamic>();
    final shift = (data['shift'] as Map?)?.cast<String, dynamic>();
    final team = (data['team'] as Map?)?.cast<String, dynamic>();
    final holidays = ((data['upcoming_holidays'] as List?) ?? const []).cast<Map>();
    final extras = ((data['extras'] as Map?) ?? const {}).cast<String, dynamic>();
    final exceptions = (data['exception_days'] as num?)?.toInt() ?? 0;
    final pending = (data['pending_reviews'] as num?)?.toInt() ?? 0;
    final unassigned = (data['unassigned_reviews'] as num?)?.toInt() ?? 0;
    final unread = (data['unread_notifications'] as num?)?.toInt() ?? 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.sm, AppSpacing.page, AppSpacing.xxl),
      children: [
        _TopBar(orgName: org['name'] as String, initials: _initials(me['name'] as String), unread: unread),
        const SizedBox(height: AppSpacing.lg),
        Semantics(
          header: true,
          child: Text('Hello $name 👋', style: Theme.of(context).textTheme.headlineMedium),
        ),
        const SizedBox(height: AppSpacing.lg),
        _ShiftCard(shift: shift, lastPunch: (data['last_punch'] as Map?)?.cast<String, dynamic>(),
            serverTime: data['server_time'] as String?),
        if (exceptions > 0) ...[
          const SizedBox(height: AppSpacing.lg),
          _ExceptionStrip(count: exceptions),
        ],
        if (pending > 0 || unassigned > 0) ...[
          const SizedBox(height: AppSpacing.lg),
          _ReviewsCard(pending: pending, unassigned: unassigned),
        ],
        if (team != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _WhoIsInCard(team: team),
        ],
        const SizedBox(height: AppSpacing.lg),
        _PayslipCard(latest: (extras['latest_payslip'] as Map?)?.cast<String, dynamic>()),
        const SizedBox(height: AppSpacing.lg),
        _HolidaysCard(holidays: holidays),
      ],
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.first.characters.first + (parts.length > 1 ? parts.last.characters.first : '')).toUpperCase();
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.orgName, required this.initials, required this.unread});
  final String orgName;
  final String initials;
  final int unread;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: AppColors.attendanceCard, borderRadius: BorderRadius.circular(8)),
        child: Text(orgName.toUpperCase(),
            style: const TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: AppColors.primary)),
      ),
      const Spacer(),
      IconButton(
        tooltip: unread > 0 ? 'Notifications, $unread unread' : 'Notifications',
        onPressed: () => context.push('/notifications'),
        icon: Badge(
          isLabelVisible: unread > 0,
          label: Text(unread > 99 ? '99+' : '$unread'),
          child: const Icon(Icons.notifications_none_rounded, size: 28),
        ),
      ),
      const SizedBox(width: AppSpacing.xs),
      Semantics(
        button: true,
        label: 'My profile',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => context.push('/profile'),
          child: CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.peopleCard,
            child: Text(initials, style: const TextStyle(color: AppColors.peopleAction, fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    ]);
  }
}

/// Live office-time clock (org time zone, not the device zone).
class _LiveClock extends StatefulWidget {
  const _LiveClock();

  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = OrgTime.local(DateTime.now().toUtc());
    return Container(
      width: 100,
      height: 100,
      decoration: const BoxDecoration(color: AppColors.shiftBadge, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: DateFormat('h:mm').format(now),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: AppColors.text)),
          TextSpan(text: ' ${DateFormat('a').format(now)}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.text)),
        ]),
        semanticsLabel: 'Office time ${DateFormat('h:mm a').format(now)}',
      ),
    );
  }
}

class _ShiftCard extends StatelessWidget {
  const _ShiftCard({required this.shift, required this.lastPunch, required this.serverTime});
  final Map<String, dynamic>? shift;
  final Map<String, dynamic>? lastPunch;
  final String? serverTime;

  @override
  Widget build(BuildContext context) {
    final s = shift;
    final today = OrgTime.today();
    final next = s?['next_action'] as String?;
    final blocked = s?['blocked_reason'] as String?;
    final lunchPaid = s?['lunch_paid'] == true;
    final expected = (s?['required_seconds'] as num?) ?? (s?['expected_seconds'] as num?);
    final title = s == null
        ? 'No shift today'
        : '${DateFormat('EEEE').format(today)} | ${s['kind'] == 'workday' || s['kind'] == 'extra_workday' ? 'Office shift' : _kindLabel(s['kind'] as String?)}';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 64,
          child: ExcludeSemantics(child: SvgPicture.asset('assets/illustrations/skyline.svg', fit: BoxFit.cover)),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const _LiveClock(),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall, textAlign: TextAlign.end),
                  const SizedBox(height: 4),
                  Text(DateFormat('d MMMM yyyy').format(today), style: Theme.of(context).textTheme.bodyMedium),
                  if (s != null && s['is_required'] == true) ...[
                    const SizedBox(height: 6),
                    Text(
                      '${OrgTime.time(s['start_at'])}–${OrgTime.time(s['end_at'])} · ${OrgTime.hm(expected)}'
                      '${lunchPaid ? ' · lunch included' : ''}',
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.end,
                    ),
                  ],
                ]),
              ),
            ]),
            const SizedBox(height: AppSpacing.lg),
            _PunchButton(next: next, blocked: blocked, shift: s),
            const SizedBox(height: AppSpacing.sm),
            _PunchStatus(shift: s, lastPunch: lastPunch, blocked: blocked),
          ]),
        ),
      ]),
    );
  }

  static String _kindLabel(String? kind) => switch (kind) {
        'holiday' => 'Holiday',
        'weekly_off' => 'Weekly off',
        'day_off' => 'Day off',
        _ => 'Shift',
      };
}

class _PunchButton extends StatelessWidget {
  const _PunchButton({required this.next, required this.blocked, required this.shift});
  final String? next;
  final String? blocked;
  final Map<String, dynamic>? shift;

  @override
  Widget build(BuildContext context) {
    final isOut = next == 'OUT';
    final enabled = next != null;
    final label = isOut ? 'Check out' : 'Check in';
    return Semantics(
      button: true,
      enabled: enabled,
      label: enabled ? label : '$label unavailable: ${_reason(blocked, shift)}',
      excludeSemantics: true,
      child: FilledButton.icon(
        onPressed: enabled ? () => context.push('/punch') : null,
        style: FilledButton.styleFrom(
          backgroundColor: isOut ? AppColors.primary : AppColors.success,
          minimumSize: const Size.fromHeight(54),
          shape: const StadiumBorder(),
        ),
        icon: Icon(isOut ? Icons.logout_rounded : Icons.login_rounded),
        label: Text(label, style: const TextStyle(fontSize: 18)),
      ),
    );
  }

  static String _reason(String? blocked, Map<String, dynamic>? shift) => switch (blocked) {
        'on_leave' => 'you are on approved leave today',
        'holiday' => 'today is a holiday',
        'weekly_off' => 'today is your weekly off',
        'day_off' => 'today is a day off',
        'no_office' => 'no office is assigned to you yet',
        'not_open_yet' => 'check-in opens at ${OrgTime.time(shift?['checkin_opens_at'])}',
        'window_closed' => 'the check-in window has closed',
        'completed' => 'you have completed today\'s shift',
        'needs_correction' => 'this shift needs a correction',
        _ => shift == null ? 'no shift is scheduled' : 'not available now',
      };
}

class _PunchStatus extends StatelessWidget {
  const _PunchStatus({required this.shift, required this.lastPunch, required this.blocked});
  final Map<String, dynamic>? shift;
  final Map<String, dynamic>? lastPunch;
  final String? blocked;

  @override
  Widget build(BuildContext context) {
    final s = shift;
    String text;
    if (s == null) {
      text = 'No shift is scheduled for you today.';
    } else if (s['session_state'] == 'open') {
      final inAt = OrgTime.parse(s['effective_in_at']);
      final elapsed = inAt == null ? 0 : DateTime.now().toUtc().difference(inAt).inSeconds;
      text = 'Checked in at ${OrgTime.time(s['effective_in_at'])} · ${OrgTime.hm(elapsed)} so far'
          '${s['is_late'] == true ? ' · late' : ''}';
    } else if (s['session_state'] == 'closed') {
      text = 'Done for today: ${OrgTime.time(s['effective_in_at'])} – ${OrgTime.time(s['effective_out_at'])}'
          ' · ${OrgTime.hm(s['credited_seconds'])} credited';
    } else {
      text = 'Check-in unavailable: ${_PunchButton._reason(blocked, s)}.';
      if (blocked == null) text = 'Ready when you are.';
    }
    return Text(text, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center);
  }
}

class _ExceptionStrip extends StatelessWidget {
  const _ExceptionStrip({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.exceptionStrip,
      borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
        onTap: () => context.push('/attendance?filter=needs_correction'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFF6C4C8)),
            borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
          ),
          child: Row(children: [
            const Icon(Icons.error_outline_rounded, color: AppColors.error),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text('${count.toString().padLeft(2, '0')} Exception day${count == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 16, color: AppColors.text)),
            ),
            const Text('Regularize',
                style: TextStyle(fontSize: 16, color: AppColors.primary, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class _ReviewsCard extends StatelessWidget {
  const _ReviewsCard({required this.pending, required this.unassigned});
  final int pending;
  final int unassigned;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      color: AppColors.approvalsCard,
      onTap: () => context.push('/approvals'),
      child: Row(children: [
        const Icon(Icons.fact_check_outlined, color: AppColors.approvalsAction, size: 30),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pending > 0 ? '$pending request${pending == 1 ? '' : 's'} waiting for you' : 'Approvals',
                style: Theme.of(context).textTheme.titleSmall),
            if (unassigned > 0)
              Text('$unassigned need an approver assigned', style: const TextStyle(color: AppColors.error)),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded),
      ]),
    );
  }
}

class _WhoIsInCard extends StatelessWidget {
  const _WhoIsInCard({required this.team});
  final Map<String, dynamic> team;

  @override
  Widget build(BuildContext context) {
    int n(String k) => (team[k] as num?)?.toInt() ?? 0;
    final segments = [
      ('On Time', n('on_time'), const Color(0xFF2FB5A6)),
      ('Late In', n('late'), const Color(0xFFF2A33A)),
      ('Not Yet In', n('not_yet_in'), const Color(0xFFF26B6B)),
      ('Out Of Office', n('out_of_office'), const Color(0xFFA7B1C2)),
    ];
    final total = n('total');
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionHeader(title: 'Who Is In', onMore: () => context.push('/reports/hours')),
        const SizedBox(height: AppSpacing.md),
        Semantics(
          label: 'Who is in today: ${segments.map((s) => '${s.$1} ${s.$2}').join(', ')}, of $total teammates',
          excludeSemantics: true,
          child: SizedBox(
            height: 200,
            child: CustomPaint(
              painter: _DonutPainter([for (final s in segments) (s.$2.toDouble(), s.$3)]),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$total', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                  Text('Teammates', style: Theme.of(context).textTheme.bodyMedium),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(children: [
          for (final s in segments)
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(width: 22, height: 6, decoration: BoxDecoration(color: s.$3, borderRadius: BorderRadius.circular(3))),
                const SizedBox(height: 6),
                Text(s.$1, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(s.$2 == 0 ? '-' : s.$2.toString().padLeft(2, '0'),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ]),
            ),
        ]),
      ]),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.segments);
  final List<(double, Color)> segments;

  @override
  void paint(Canvas canvas, Size size) {
    final total = segments.fold<double>(0, (a, s) => a + s.$1);
    final radius = math.min(size.width, size.height) / 2 - 16;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 32;
    if (total == 0) {
      canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = const Color(0xFFE9ECF1));
      return;
    }
    var start = -math.pi / 2;
    for (final s in segments) {
      if (s.$1 == 0) continue;
      final sweep = math.pi * 2 * s.$1 / total;
      canvas.drawArc(rect, start, sweep, false, paint..color = s.$2);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.segments != segments;
}

class _PayslipCard extends StatelessWidget {
  const _PayslipCard({required this.latest});
  final Map<String, dynamic>? latest;

  @override
  Widget build(BuildContext context) {
    final month = latest?['salary_month'] as String?;
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionHeader(title: 'Payslip', onMore: () => context.push('/payslips')),
        const SizedBox(height: AppSpacing.sm),
        Row(children: [
          const Illustration('piggy', size: 84),
          const Spacer(),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(month == null ? 'No payslip yet' : OrgTime.date(month, pattern: 'MMM yyyy'),
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(month == null ? 'Published payslips appear here' : 'Payslip available',
                style: Theme.of(context).textTheme.bodyMedium),
          ]),
        ]),
        if (month != null) ...[
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: () => context.push('/payslips'),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('View payslips'),
          ),
        ],
      ]),
    );
  }
}

class _HolidaysCard extends StatelessWidget {
  const _HolidaysCard({required this.holidays});
  final List<Map> holidays;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionHeader(title: 'Upcoming Holidays', onMore: () => context.push('/holidays')),
        const SizedBox(height: AppSpacing.md),
        if (holidays.isEmpty)
          Text('No upcoming holidays published yet.', style: Theme.of(context).textTheme.bodyMedium)
        else
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 0.82,
            children: [
              for (var i = 0; i < holidays.length; i++) _HolidayTile(holidays[i].cast<String, dynamic>(), i),
            ],
          ),
      ]),
    );
  }
}

class _HolidayTile extends StatelessWidget {
  const _HolidayTile(this.h, this.index);
  final Map<String, dynamic> h;
  final int index;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(h['date'] as String? ?? '');
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(color: AppColors.holidayCard, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(date == null ? '' : '${date.day}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(date == null ? '' : DateFormat('MMM').format(date), style: const TextStyle(fontSize: 14)),
          ]),
          const Spacer(),
          Illustration('holiday${index % 4 + 1}', size: 56),
        ]),
        const Spacer(),
        Text(h['name'] as String? ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.holidayText, fontSize: 16, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Text(date == null ? '' : DateFormat('EEEE').format(date), style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
