import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/session_controller.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/jelly_nav_bar.dart';
import '../../core/widgets/states.dart';
import '../home/home_providers.dart';
import '../leave/leave_screen.dart';
import '../requests/my_requests_screen.dart';

enum _ActionScope { user, teamHr, admin }

/// S05 — Action. Grouped by what people come to do, each item says what it
/// is for in plain words and shows its live number (leave left, pending
/// requests, reviews waiting). Deferred items (YTD, IT statement, quick
/// links) are intentionally absent.
class ActionScreen extends ConsumerStatefulWidget {
  const ActionScreen({super.key});

  @override
  ConsumerState<ActionScreen> createState() => _ActionScreenState();
}

class _ActionScreenState extends ConsumerState<ActionScreen> {
  _ActionScope _selectedScope = _ActionScope.user;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionContextProvider);
    final reviews =
        (ref.watch(homeSummaryProvider).value?['pending_reviews'] as num?)
            ?.toInt() ??
        0;
    final leaveLeft = _paidDaysLeft(
      ref.watch(leaveBalancesProvider(OrgTime.today().year)).value,
    );
    final pending = (ref.watch(myRequestsProvider(null)).value ?? const [])
        .where((r) => r['state'] == 'submitted' || r['state'] == 'under_review')
        .length;

    const lav = (AppColors.attendanceCard, AppColors.attendanceAction);
    const cyan = (AppColors.leaveCard, AppColors.leaveAction);
    const peach = (AppColors.salaryCard, AppColors.salaryAction);
    const teal = (AppColors.approvalsCard, AppColors.approvalsAction);

    final attendanceActions = <_Item>[
      _Item(
        Icons.event_available_outlined,
        'My attendance',
        lav,
        '/attendance',
        'Your days, hours and late marks',
        art: 'tile_my_attendance',
      ),
      _Item(
        Icons.edit_calendar_outlined,
        'Fix a check-in or check-out',
        lav,
        '/corrections/new',
        'Forgot to punch, or the time is wrong',
        art: 'tile_fix_punch',
      ),
    ];

    final leaveActions = <_Item>[
      _Item(
        Icons.flight_takeoff_rounded,
        'Apply for leave',
        cyan,
        '/leave/apply',
        leaveLeft == null
            ? 'Casual, paid or unpaid leave'
            : '${_days(leaveLeft)} of paid leave left',
        art: 'tile_apply_leave',
      ),
      _Item(
        Icons.view_week_outlined,
        'Leave balance & history',
        cyan,
        '/leave',
        'What you have used and have left',
        art: 'tile_leave_balance',
      ),
      _Item(
        Icons.calendar_month_outlined,
        'Holiday calendar',
        cyan,
        '/holidays',
        'Office holidays this year',
        art: 'holiday_calendar',
      ),
    ];

    final salaryActions = <_Item>[
      _Item(
        Icons.credit_card_rounded,
        'My salary',
        peach,
        '/salary',
        'Monthly salary, bank and total received',
        art: 'tile_my_salary',
      ),
      _Item(
        Icons.receipt_long_outlined,
        'Payslips',
        peach,
        '/payslips',
        'Download your monthly payslips',
        art: 'tile_payslips',
      ),
    ];

    final requestActions = <_Item>[
      _Item(
        Icons.assignment_outlined,
        'My requests',
        peach,
        '/requests',
        pending > 0
            ? '$pending waiting for approval'
            : 'Track everything you sent',
        badge: pending > 0 ? '$pending' : null,
        art: 'tile_my_requests',
      ),
    ];

    final teamAndHrActions = <_Item>[
      if (s?.canDraftPolicy ?? false)
        _Item(
          Icons.beach_access_outlined,
          'Leave & holidays',
          teal,
          '/admin/leave-policies',
          'Leave types, balances and holidays',
        ),
      if (s?.canReview ?? false)
        _Item(
          Icons.fact_check_outlined,
          'Review requests',
          teal,
          '/approvals',
          reviews > 0
              ? '$reviews waiting for your decision'
              : 'Nothing waiting right now',
          badge: reviews > 0 ? '$reviews' : null,
          art: 'tile_review_requests',
        ),
      if (s?.canTeamReports ?? false)
        _Item(
          Icons.groups_outlined,
          'Team hours',
          lav,
          '/reports/hours',
          'Who is in and hours worked',
          art: 'tile_team_hours',
        ),
      if (s?.canManagePayroll ?? false)
        _Item(
          Icons.upload_file_outlined,
          'Payroll uploads',
          peach,
          '/payroll/uploads',
          'Publish payslips and paid amounts',
          art: 'tile_payslips',
        ),
      if (s?.canViewEmployees ?? false)
        _Item(
          Icons.badge_outlined,
          'Employees',
          teal,
          '/employees',
          'Directory and employee records',
        ),
    ];

    final adminActions = <_Item>[
      if (s?.isAdmin ?? false)
        _Item(
          Icons.location_city_outlined,
          'Departments',
          teal,
          '/admin/teams?section=departments',
          'Create and manage departments',
        ),
      if (s?.isAdmin ?? false)
        _Item(
          Icons.groups_outlined,
          'Teams',
          teal,
          '/admin/teams',
          'Teams, members and managers',
        ),
      if (s?.isAdmin ?? false)
        _Item(
          Icons.policy_outlined,
          'Company policies',
          const (AppColors.documentsCard, AppColors.documentsAction),
          '/policies',
          'Publish and manage company policies',
        ),
      if (s?.isAdmin ?? false)
        _Item(
          Icons.admin_panel_settings_outlined,
          'Administration',
          lav,
          '/admin/organization',
          'Organisation setup and controls',
        ),
      if (s?.isAdmin ?? false)
        _Item(
          Icons.work_outline_rounded,
          'Outside work',
          peach,
          '/admin/outside-work',
          'Send people out: shoot, WFH, meeting',
        ),
      if (s?.isAdmin ?? false)
        _Item(
          Icons.wifi_rounded,
          'Offices & Wi-Fi',
          lav,
          '/admin/offices',
          'Office location and Wi-Fi for check-in',
        ),
      if (s?.isAdmin ?? false)
        _Item(
          Icons.weekend_outlined,
          'Weekly off',
          teal,
          '/admin/leave-policies?tab=holidays',
          'Sundays and which Saturdays are off',
        ),
      if (s?.isAdmin ?? false)
        _Item(
          Icons.admin_panel_settings_outlined,
          'Roles & permissions',
          lav,
          '/admin/permissions',
          'Who is Manager, HR or Admin',
        ),
    ];

    final userActions = <_Item>[
      ...attendanceActions,
      ...leaveActions,
      ...salaryActions,
      ...requestActions,
    ];
    final scopes = <(_ActionScope, String, IconData, List<_Item>)>[
      (_ActionScope.user, 'User', Icons.person_outline_rounded, userActions),
      if (teamAndHrActions.isNotEmpty)
        (_ActionScope.teamHr, 'HR', Icons.groups_outlined, teamAndHrActions),
      if (adminActions.isNotEmpty)
        (
          _ActionScope.admin,
          'Admin',
          Icons.admin_panel_settings_outlined,
          adminActions,
        ),
    ];
    final activeScope = scopes.any((scope) => scope.$1 == _selectedScope)
        ? _selectedScope
        : _ActionScope.user;
    final scopeIndex = scopes.indexWhere((scope) => scope.$1 == activeScope);
    final selectedActions = scopes[scopeIndex].$4;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const PageTitle('Actions'),
            const OfflineBanner(),
            if (scopes.length > 1) ...[
              Padding(
                key: const Key('action-scope-card-spacing'),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.lg,
                  AppSpacing.page,
                  AppSpacing.lg,
                ),
                child: _CompactCategoryBar(
                  options: [for (final scope in scopes) (scope.$2, scope.$3)],
                  selectedIndex: scopeIndex,
                  onSelected: (index) =>
                      setState(() => _selectedScope = scopes[index].$1),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.page),
                child: Divider(),
              ),
            ],
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(homeSummaryProvider);
                  ref.invalidate(leaveBalancesProvider);
                  ref.invalidate(myRequestsProvider);
                },
                child: ListView(
                  key: const Key('action-list'),
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    AppSpacing.xl,
                    AppSpacing.page,
                    AppSpacing.xl,
                  ),
                  children: [
                    for (final it in selectedActions) _ActionTile(item: it),
                  ],
                ),
              ),
            ),
          ],
        ),
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
    final text = d == d.roundToDouble()
        ? d.toStringAsFixed(0)
        : d.toStringAsFixed(1);
    return '$text ${d == 1 ? 'day' : 'days'}';
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.item});

  final _Item item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: ActionRow(
        icon: item.icon,
        label: item.label,
        subtitle: item.subtitle,
        tileColor: item.colors.$1,
        iconColor: item.colors.$2,
        badge: item.badge,
        art: item.art,
        onTap: () => context.push(item.route),
      ),
    );
  }
}

const _tabCardShadow = [
  BoxShadow(
    color: Color(0x1C263342),
    blurRadius: 14,
    offset: Offset(0, 4),
    spreadRadius: -1,
  ),
  BoxShadow(color: Color(0x0D263342), blurRadius: 6, offset: Offset(0, 1)),
];

class _CompactCategoryBar extends StatelessWidget {
  const _CompactCategoryBar({
    required this.options,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<(String, IconData)> options;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    if (options.length == 1) {
      return _SingleCategoryTab(
        option: options.first,
        onTap: () => onSelected(0),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: _tabCardShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: JellyNavigationBar(
          height: 72,
          backgroundColor: Colors.transparent,
          showTopBorder: false,
          selectedIndex: selectedIndex,
          onDestinationSelected: onSelected,
          destinations: [
            for (final option in options)
              JellyNavDestination(
                icon: AppIcon(option.$2, size: 22),
                selectedIcon: AppIcon(option.$2, size: 22),
                label: option.$1,
              ),
          ],
        ),
      ),
    );
  }
}

class _SingleCategoryTab extends StatelessWidget {
  const _SingleCategoryTab({required this.option, required this.onTap});

  final (String, IconData) option;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: true,
      label: option.$1,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border),
            boxShadow: _tabCardShadow,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 64,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.attendanceCard,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: AppIcon(option.$2, size: 22),
              ),
              const SizedBox(height: 4),
              Text(
                option.$1,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Item {
  const _Item(
    this.icon,
    this.label,
    this.colors,
    this.route,
    this.subtitle, {
    this.badge,
    this.art,
  });
  final IconData icon;
  final String? art;
  final String label;
  final (Color, Color) colors;
  final String route;
  final String subtitle;
  final String? badge;
}
