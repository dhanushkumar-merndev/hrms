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
  int _selectedUserCategory = 0;
  int _selectedTeamCategory = 0;

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
          Icons.admin_panel_settings_outlined,
          'Administration',
          lav,
          '/admin/organization',
          'Organisation setup and controls',
        ),
    ];

    final userCategories = <_ActionCategory>[
      _ActionCategory('Attendance', Icons.schedule_rounded, attendanceActions),
      _ActionCategory('Leave', Icons.beach_access_rounded, leaveActions),
      _ActionCategory('Salary', Icons.payments_outlined, salaryActions),
      _ActionCategory('Requests', Icons.assignment_outlined, requestActions),
    ];
    final selectedActions = userCategories[_selectedUserCategory].items;
    final scopes = <(_ActionScope, String, IconData)>[
      (_ActionScope.user, 'User', Icons.person_outline_rounded),
      if (teamAndHrActions.isNotEmpty)
        (_ActionScope.teamHr, 'Team & HR', Icons.groups_outlined),
      if (adminActions.isNotEmpty)
        (_ActionScope.admin, 'Admin', Icons.admin_panel_settings_outlined),
    ];
    final activeScope = scopes.any((scope) => scope.$1 == _selectedScope)
        ? _selectedScope
        : _ActionScope.user;
    final scopeIndex = scopes.indexWhere((scope) => scope.$1 == activeScope);
    final teamIndex = teamAndHrActions.isEmpty
        ? 0
        : _selectedTeamCategory.clamp(0, teamAndHrActions.length - 1);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
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
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    AppSpacing.sm,
                    AppSpacing.page,
                    AppSpacing.xl,
                  ),
                  children: [
                    if (scopes.length > 1) ...[
                      const SizedBox(height: AppSpacing.lg),
                      _CompactCategoryBar(
                        options: [
                          for (final scope in scopes) (scope.$2, scope.$3),
                        ],
                        selectedIndex: scopeIndex,
                        onSelected: (index) => setState(() {
                          _selectedScope = scopes[index].$1;
                        }),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    if (activeScope == _ActionScope.user) ...[
                      _CompactCategoryBar(
                        options: [
                          for (final category in userCategories)
                            (category.label, category.icon),
                        ],
                        selectedIndex: _selectedUserCategory,
                        onSelected: (index) =>
                            setState(() => _selectedUserCategory = index),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      for (final it in selectedActions) _ActionTile(item: it),
                    ] else if (activeScope == _ActionScope.teamHr) ...[
                      _CompactCategoryBar(
                        options: [
                          for (final action in teamAndHrActions)
                            (_shortActionLabel(action.label), action.icon),
                        ],
                        selectedIndex: teamIndex,
                        onSelected: (index) =>
                            setState(() => _selectedTeamCategory = index),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      _ActionTile(item: teamAndHrActions[teamIndex]),
                    ] else ...[
                      for (final it in adminActions) _ActionTile(item: it),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _shortActionLabel(String label) => switch (label) {
    'Review requests' => 'Reviews',
    'Team hours' => 'Team',
    'Payroll uploads' => 'Payroll',
    _ => label,
  };

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
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2F6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          for (var index = 0; index < options.length; index++)
            Expanded(
              child: _CompactCategoryButton(
                option: options[index],
                selected: selectedIndex == index,
                onTap: () => onSelected(index),
              ),
            ),
        ],
      ),
    );
  }
}

class _CompactCategoryButton extends StatelessWidget {
  const _CompactCategoryButton({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final (String, IconData) option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        elevation: selected ? 1 : 0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  option.$2,
                  size: 20,
                  color: selected ? AppColors.primary : AppColors.textSecondary,
                ),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    option.$1,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? AppColors.primary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionCategory {
  const _ActionCategory(this.label, this.icon, this.items);

  final String label;
  final IconData icon;
  final List<_Item> items;
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
