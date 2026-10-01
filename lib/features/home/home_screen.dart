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
import '../people/profile_screen.dart';
import '../workspace/workspace_screen.dart';
import 'home_providers.dart';

/// S03 — Home, following reference 01.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  Timer? _timer;
  DateTime _loadedAt = DateTime.now();
  DateTime _loadedDay = OrgTime.today();

  @override
  void initState() {
    super.initState();
    ref.listenManual(homeSummaryProvider, (_, next) {
      if (next.hasValue && !next.isLoading && !next.hasError) {
        _loadedAt = DateTime.now();
        _loadedDay = OrgTime.today();
      }
    });
    // A Home left open (e.g. overnight, or a refresh that failed while the
    // phone woke up) reloads when the office day changes, when its data is
    // over 5 minutes old, or after an error.
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      final summary = ref.read(homeSummaryProvider);
      if (summary.isLoading) return;
      if (summary.hasError ||
          OrgTime.today() != _loadedDay ||
          DateTime.now().difference(_loadedAt) > const Duration(minutes: 5)) {
        ref.invalidate(homeSummaryProvider);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        _TopBar(orgName: org['name'] as String, name: me['name'] as String, hasAvatar: me['has_avatar'] == true,
            unread: unread),
        const SizedBox(height: AppSpacing.lg),
        Semantics(
          header: true,
          child: Text('Hello $name 👋', style: Theme.of(context).textTheme.headlineMedium),
        ),
        const SizedBox(height: AppSpacing.lg),
        _ShiftCard(shift: shift, lastPunch: (data['last_punch'] as Map?)?.cast<String, dynamic>(),
            serverTime: data['server_time'] as String?),
        const SizedBox(height: AppSpacing.lg),
        const _QuickActions(),
        if (exceptions > 0) ...[
          const SizedBox(height: AppSpacing.lg),
          _ExceptionStrip(count: exceptions),
        ],
        if (pending > 0 || unassigned > 0) ...[
          const SizedBox(height: AppSpacing.lg),
          _ReviewsCard(pending: pending, unassigned: unassigned),
        ],
        for (final t in ((extras['admin_tasks'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>())) ...[
          const SizedBox(height: AppSpacing.md),
          ActionRow(
            icon: t['kind'] == 'archive_due' ? Icons.archive_outlined : Icons.task_alt_rounded,
            label: t['title'] as String? ?? '',
            tileColor: AppColors.warningSoft,
            iconColor: AppColors.warning,
            onTap: () {
              final route = adminTaskRoute(t);
              if (route != null) context.push(route);
            },
          ),
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
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.orgName, required this.name, required this.hasAvatar, required this.unread});
  final String orgName;
  final String name;
  final bool hasAvatar;
  final int unread;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avatarId =
        hasAvatar ? ref.watch(myProfileProvider).value?.map['avatar_file_version_id'] as String? : null;
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
          child: AvatarImage(fileVersionId: avatarId, name: name, radius: 22),
        ),
      ),
    ]);
  }
}

/// One-tap shortcuts to the things people do most, so they don't have to
/// hunt through Action for them.
class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.flight_takeoff_rounded, 'Apply\nleave', AppColors.leaveCard, AppColors.leaveAction, '/leave/apply'),
      (Icons.edit_calendar_outlined, 'Fix a\npunch', AppColors.attendanceCard, AppColors.attendanceAction, '/corrections/new'),
      (Icons.event_available_outlined, 'My\nattendance', AppColors.approvalsCard, AppColors.approvalsAction, '/attendance'),
      (Icons.assignment_outlined, 'My\nrequests', AppColors.salaryCard, AppColors.salaryAction, '/requests'),
    ];
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (icon, label, bg, fg, route) in items)
        Expanded(
          child: Semantics(
            button: true,
            label: label.replaceAll('\n', ' '),
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppSpacing.rowRadius),
              onTap: () => context.push(route),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Column(children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18)),
                    child: Icon(icon, color: fg, size: 26),
                  ),
                  const SizedBox(height: 6),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, height: 1.2, fontWeight: FontWeight.w500, color: AppColors.text)),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}

enum _DayPhase { morning, afternoon, sunset, night }

_DayPhase _getDayPhase(DateTime now) {
  final minutes = now.hour * 60 + now.minute;
  if (minutes >= 6 * 60 && minutes < 12 * 60) {
    return _DayPhase.morning;
  } else if (minutes >= 12 * 60 && minutes < 17 * 60) {
    return _DayPhase.afternoon;
  } else if (minutes >= 17 * 60 && minutes < 19 * 60 + 30) {
    return _DayPhase.sunset;
  } else {
    return _DayPhase.night;
  }
}

/// Live office-time clock (org time zone, not the device zone) with dynamic
/// celestial body (Sun during the day, Moon & stars at night).
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
    final phase = _getDayPhase(now);

    final (dialColors, borderColor, shadowColor, textColor, textSecColor) = switch (phase) {
      _DayPhase.morning => (
          [const Color(0xFFFFF9ED), const Color(0xFFFFE8C7)],
          const Color(0xFFFFE3B8),
          const Color(0x1AFFB300),
          AppColors.text,
          AppColors.text,
        ),
      _DayPhase.afternoon => (
          [const Color(0xFFFFF6EB), const Color(0xFFFFE0B8)],
          const Color(0xFFFFE7C7),
          const Color(0x14FF9F2A),
          AppColors.text,
          AppColors.text,
        ),
      _DayPhase.sunset => (
          [const Color(0xFFFFF1EB), const Color(0xFFFDD5C6)],
          const Color(0xFFFBC6B3),
          const Color(0x1AFF7043),
          AppColors.text,
          AppColors.text,
        ),
      _DayPhase.night => (
          [const Color(0xFF242E4C), const Color(0xFF141A2D)],
          const Color(0xFF38466D),
          const Color(0x26141A2D),
          Colors.white,
          const Color(0xFFCBD5E1),
        ),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
      width: 96,
      height: 96,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.2, -0.2),
          radius: 0.9,
          colors: dialColors,
        ),
        border: Border.all(color: borderColor, width: 1.5),
        boxShadow: [
          BoxShadow(color: shadowColor, blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Dynamic Celestial Body touching the outer edge of the dial
          Positioned(
            right: -2,
            top: -2,
            child: SizedBox(
              width: 48,
              height: 48,
              child: switch (phase) {
                _DayPhase.morning => const CustomPaint(painter: _DaySunPainter(isMorning: true)),
                _DayPhase.afternoon => const CustomPaint(painter: _DaySunPainter(isMorning: false)),
                _DayPhase.sunset => const CustomPaint(painter: _SunsetSunPainter()),
                _DayPhase.night => const CustomPaint(painter: _MoonAndStarsPainter()),
              },
            ),
          ),
          // Time text
          Padding(
            padding: const EdgeInsets.only(left: 3),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: DateFormat('h:mm').format(now),
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                    letterSpacing: -0.3,
                  ),
                ),
                TextSpan(
                  text: ' ${DateFormat('a').format(now)}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: textSecColor,
                  ),
                ),
              ]),
              semanticsLabel: 'Office time ${DateFormat('h:mm a').format(now)}, ${phase.name}',
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the daytime radiant sun with atmospheric glow and flare.
class _DaySunPainter extends CustomPainter {
  const _DaySunPainter({required this.isMorning});
  final bool isMorning;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w * 0.5;
    final cy = h * 0.5;
    final r = w * 0.46;

    // Atmospheric warm glow
    final glowColor = isMorning ? const Color(0x40FFA726) : const Color(0x38FF9800);
    final glowPaint = Paint()
      ..color = glowColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(Offset(cx, cy), r, glowPaint);

    // Sun disc
    final colors = isMorning
        ? [const Color(0xFFFFD54F), const Color(0xFFFF9800)]
        : [const Color(0xFFFFB74D), const Color(0xFFF57C00)];
    final sunPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawCircle(Offset(cx, cy), r, sunPaint);

    // Subtle sun flare highlight on top-left
    final highlightPaint = Paint()
      ..color = const Color(0x4DFFFFFF)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    canvas.drawCircle(Offset(cx - r * 0.28, cy - r * 0.28), r * 0.25, highlightPaint);
  }

  @override
  bool shouldRepaint(_DaySunPainter oldDelegate) => oldDelegate.isMorning != isMorning;
}

/// Paints the rich coral sunset sun with dusk cloud accent.
class _SunsetSunPainter extends CustomPainter {
  const _SunsetSunPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w * 0.5;
    final cy = h * 0.5;
    final r = w * 0.46;

    // Sunset glow
    final glowPaint = Paint()
      ..color = const Color(0x40FF6E40)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(Offset(cx, cy), r, glowPaint);

    // Sun disc
    final sunPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFF8A65), Color(0xFFFF5722)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawCircle(Offset(cx, cy), r, sunPaint);

    // Soft dusk cloud layer across the lower third of the sun
    final cloudPaint = Paint()
      ..color = const Color(0x59FFF1EB)
      ..style = PaintingStyle.fill;
    final cloudRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy + r * 0.45), width: r * 1.5, height: r * 0.35),
      Radius.circular(r * 0.18),
    );
    canvas.drawRRect(cloudRect, cloudPaint);
  }

  @override
  bool shouldRepaint(_SunsetSunPainter oldDelegate) => false;
}

/// Paints the glowing golden crescent moon with moonlight aura and diamond star sparkles.
class _MoonAndStarsPainter extends CustomPainter {
  const _MoonAndStarsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w * 0.52;
    final cy = h * 0.48;
    final r = w * 0.44;

    // Soft moonlight aura
    final auraPaint = Paint()
      ..color = const Color(0x4DFFD54F)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(Offset(cx, cy), r * 0.9, auraPaint);

    // Crescent moon shape
    final fullMoon = Path()
      ..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    final cutout = Path()
      ..addOval(Rect.fromCircle(center: Offset(cx - r * 0.48, cy - r * 0.28), radius: r * 0.86));
    final crescent = Path.combine(PathOperation.difference, fullMoon, cutout);

    final moonPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [Color(0xFFFFF9C4), Color(0xFFFFCA28)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawPath(crescent, moonPaint);

    // Subtle star sparkles
    final starPaint = Paint()..color = const Color(0xF2FFFFFF);
    _drawDiamondStar(canvas, Offset(w * 0.16, h * 0.72), 2.2, starPaint);
    _drawDiamondStar(canvas, Offset(w * 0.82, h * 0.82), 1.8, starPaint);
    _drawDiamondStar(canvas, Offset(w * 0.28, h * 0.18), 1.4, starPaint);
  }

  void _drawDiamondStar(Canvas canvas, Offset center, double size, Paint paint) {
    final path = Path()
      ..moveTo(center.dx, center.dy - size * 1.3)
      ..quadraticBezierTo(center.dx, center.dy, center.dx + size, center.dy)
      ..quadraticBezierTo(center.dx, center.dy, center.dx, center.dy + size * 1.3)
      ..quadraticBezierTo(center.dx, center.dy, center.dx - size, center.dy)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_MoonAndStarsPainter oldDelegate) => false;
}

class _ShiftCard extends StatelessWidget {
  const _ShiftCard({required this.shift, required this.lastPunch, required this.serverTime});
  final Map<String, dynamic>? shift;
  final Map<String, dynamic>? lastPunch;
  final String? serverTime;

  @override
  Widget build(BuildContext context) {
    final s = shift;
    final today = DateTime.tryParse((s?['shift_date'] as String?) ?? '') ?? OrgTime.today();
    final next = s?['next_action'] as String?;
    final blocked = s?['blocked_reason'] as String?;
    final lunchPaid = s?['lunch_paid'] == true;
    final expected = (s?['required_seconds'] as num?) ?? (s?['expected_seconds'] as num?);
    final isDone = s != null && s['session_state'] == 'closed';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 72,
          child: ExcludeSemantics(
            child: SvgPicture.asset(
              'assets/illustrations/skyline.svg',
              fit: BoxFit.cover,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const _LiveClock(),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              DateFormat('EEEE').format(today),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: AppColors.text,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                            decoration: BoxDecoration(
                              color: AppColors.attendanceCard,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              s == null
                                  ? 'No shift'
                                  : (s['kind'] == 'workday' || s['kind'] == 'extra_workday'
                                      ? 'Office shift'
                                      : _kindLabel(s['kind'] as String?)),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        DateFormat('d MMMM yyyy').format(today),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      if (s != null && s['is_required'] == true) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Icons.schedule_rounded, size: 14, color: AppColors.textSecondary),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '${OrgTime.time(s['start_at'])}–${OrgTime.time(s['end_at'])} · ${OrgTime.hm(expected)}'
                                '${lunchPaid ? ' · lunch included' : ''}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            if (isDone)
              _CompletedShiftBanner(shift: s)
            else ...[
              _PunchActionArea(next: next, blocked: blocked, shift: s),
            ],
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

/// A dedicated celebratory status card shown when today's shift is completed.
class _CompletedShiftBanner extends StatelessWidget {
  const _CompletedShiftBanner({required this.shift});
  final Map<String, dynamic> shift;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Done for today: ${OrgTime.time(shift['effective_in_at'])} to ${OrgTime.time(shift['effective_out_at'])}, ${OrgTime.hm(shift['credited_seconds'])} credited',
      child: InkWell(
        onTap: () => context.push('/attendance'),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFFF0FDF4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFBBF7D0)),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Done for today',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF14532D),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${OrgTime.time(shift['effective_in_at'])} – ${OrgTime.time(shift['effective_out_at'])} · ${OrgTime.hm(shift['credited_seconds'])} credited',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF166534),
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text(
                    'Log',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.primary),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Action area for Check In, Check Out, or informative blocked state.
class _PunchActionArea extends StatelessWidget {
  const _PunchActionArea({required this.next, required this.blocked, required this.shift});
  final String? next;
  final String? blocked;
  final Map<String, dynamic>? shift;

  @override
  Widget build(BuildContext context) {
    if (next != null) {
      final isOut = next == 'OUT';
      final label = isOut ? 'Check out' : 'Check in';
      final s = shift;

      return Column(
        children: [
          FilledButton.icon(
            onPressed: () => context.push('/punch'),
            style: FilledButton.styleFrom(
              backgroundColor: isOut ? AppColors.primary : AppColors.success,
              minimumSize: const Size.fromHeight(52),
              shape: const StadiumBorder(),
              elevation: 1,
            ),
            icon: Icon(isOut ? Icons.logout_rounded : Icons.login_rounded),
            label: Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (isOut && s != null) ...[
            Builder(builder: (context) {
              final inAt = OrgTime.parse(s['effective_in_at']);
              final elapsed = inAt == null ? 0 : DateTime.now().toUtc().difference(inAt).inSeconds;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFEBF5FF),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
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
                    Text(
                      'Checked in at ${OrgTime.time(s['effective_in_at'])} · ${OrgTime.hm(elapsed)} so far'
                      '${s['is_late'] == true ? ' · late' : ''}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ] else ...[
            Text(
              'Ready when you are.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      );
    }

    // Blocked or not open yet: show a clean informative banner rather than a dead disabled button
    final reason = _reason(blocked, shift);
    final iconData = switch (blocked) {
      'not_open_yet' => Icons.schedule_rounded,
      'on_leave' => Icons.beach_access_rounded,
      'holiday' => Icons.celebration_rounded,
      'weekly_off' => Icons.weekend_rounded,
      'day_off' => Icons.wb_sunny_rounded,
      _ => Icons.info_outline_rounded,
    };
    final isWarning = blocked == 'not_open_yet';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isWarning ? const Color(0xFFFFFBEB) : const Color(0xFFF4F6F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isWarning ? const Color(0xFFFDE68A) : AppColors.border),
      ),
      child: Row(
        children: [
          Icon(iconData, color: isWarning ? AppColors.warning : AppColors.textSecondary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              reason,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isWarning ? FontWeight.w600 : FontWeight.w500,
                color: isWarning ? AppColors.warning : AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _reason(String? blocked, Map<String, dynamic>? shift) => switch (blocked) {
        'on_leave' => 'You are on approved leave today.',
        'holiday' => 'Today is an official holiday.',
        'weekly_off' => 'Today is your weekly off.',
        'day_off' => 'Today is a day off.',
        'no_office' => 'No office is assigned to you yet.',
        'not_open_yet' => 'Check-in opens at ${OrgTime.time(shift?['checkin_opens_at'])}.',
        'window_closed' => 'The check-in window has closed for today.',
        'completed' => 'You have completed today\'s shift.',
        'needs_correction' => 'This shift needs a punch correction.',
        _ => shift == null ? 'No shift is scheduled for you today.' : 'Check-in is currently unavailable.',
      };
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
            const Text('Fix a punch',
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
      onTap: () => context.push('/reports/hours'),
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
      onTap: () => context.push('/payslips'),
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
      onTap: () => context.push('/holidays'),
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
