import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/session_controller.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/states.dart';
import '../home/home_providers.dart';
import '../leave/leave_screen.dart';
import '../requests/my_requests_screen.dart';

/// S05 — Action. Grouped by what people come to do, each item says what it
/// is for in plain words and shows its live number (leave left, pending
/// requests, reviews waiting). Deferred items (YTD, IT statement, quick
/// links) are intentionally absent.
class ActionScreen extends ConsumerWidget {
  const ActionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionContextProvider);
    final reviews = (ref.watch(homeSummaryProvider).value?['pending_reviews'] as num?)?.toInt() ?? 0;
    final leaveLeft = _paidDaysLeft(ref.watch(leaveBalancesProvider(OrgTime.today().year)).value);
    final pending = (ref.watch(myRequestsProvider(null)).value ?? const [])
        .where((r) => r['state'] == 'submitted' || r['state'] == 'under_review')
        .length;

    const lav = (AppColors.attendanceCard, AppColors.attendanceAction);
    const cyan = (AppColors.leaveCard, AppColors.leaveAction);
    const peach = (AppColors.salaryCard, AppColors.salaryAction);
    const teal = (AppColors.approvalsCard, AppColors.approvalsAction);

    final sections = <(String, List<_Item>)>[
      if (s?.canReview ?? false)
        ('Needs your attention', [
          _Item(Icons.fact_check_outlined, 'Review requests', teal, '/approvals',
              reviews > 0 ? '$reviews waiting for your decision' : 'Nothing waiting right now',
              badge: reviews > 0 ? '$reviews' : null),
        ]),
      ('Attendance', [
        _Item(Icons.event_available_outlined, 'My attendance', lav, '/attendance',
            'Your days, hours and late marks'),
        _Item(Icons.edit_calendar_outlined, 'Fix a check-in or check-out', lav, '/corrections/new',
            'Forgot to punch, or the time is wrong'),
        if (s?.canTeamReports ?? false)
          _Item(Icons.groups_outlined, 'Team hours', lav, '/reports/hours', 'Who is in and hours worked'),
      ]),
      ('Leave', [
        _Item(Icons.flight_takeoff_rounded, 'Apply for leave', cyan, '/leave/apply',
            leaveLeft == null ? 'Casual, paid or unpaid leave' : '${_days(leaveLeft)} of paid leave left'),
        _Item(Icons.view_week_outlined, 'Leave balance & history', cyan, '/leave', 'What you have used and have left'),
        _Item(Icons.calendar_month_outlined, 'Holiday calendar', cyan, '/holidays', 'Office holidays this year'),
      ]),
      ('Pay & requests', [
        _Item(Icons.credit_card_rounded, 'My salary', peach, '/salary', 'Monthly salary, bank and total received'),
        _Item(Icons.receipt_long_outlined, 'Payslips', peach, '/payslips', 'Download your monthly payslips'),
        _Item(Icons.assignment_outlined, 'My requests', peach, '/requests',
            pending > 0 ? '$pending waiting for approval' : 'Track leave and corrections you sent',
            badge: pending > 0 ? '$pending' : null),
      ]),
    ];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const PageTitle('Actions'),
          const OfflineBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(homeSummaryProvider);
                ref.invalidate(leaveBalancesProvider);
                ref.invalidate(myRequestsProvider);
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.sm, AppSpacing.page, AppSpacing.xl),
                children: [
                  for (final (title, items) in sections) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, AppSpacing.md, 4, AppSpacing.sm),
                      child: Text(title.toUpperCase(),
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: AppColors.textSecondary, letterSpacing: 0.8, fontWeight: FontWeight.w600)),
                    ),
                    for (final it in items) ...[
                      ActionRow(
                        icon: it.icon,
                        label: it.label,
                        subtitle: it.subtitle,
                        tileColor: it.colors.$1,
                        iconColor: it.colors.$2,
                        badge: it.badge,
                        onTap: () => context.push(it.route),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// Sum of available half-day units across paid types, or null when unknown.
  static int? _paidDaysLeft(Map<String, dynamic>? balances) {
    final rows = (balances?['balances'] as List?)?.cast<Map>();
    if (rows == null || rows.isEmpty) return null;
    var units = 0;
    var any = false;
    for (final r in rows) {
      final available = r['available_units'];
      if (available is num) {
        units += available.toInt();
        any = true;
      }
    }
    return any ? units : null;
  }

  static String _days(int units) {
    final d = units / 2;
    final text = d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(1);
    return '$text ${d == 1 ? 'day' : 'days'}';
  }
}

class _Item {
  const _Item(this.icon, this.label, this.colors, this.route, this.subtitle, {this.badge});
  final IconData icon;
  final String label;
  final (Color, Color) colors;
  final String route;
  final String subtitle;
  final String? badge;
}
