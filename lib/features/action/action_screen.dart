import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/session_controller.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/states.dart';
import '../home/home_providers.dart';

/// S05 — Action list (reference 02). Deferred items (YTD, IT statement,
/// quick links) are intentionally absent.
class ActionScreen extends ConsumerWidget {
  const ActionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionContextProvider);
    final pending = (ref.watch(homeSummaryProvider).value?['pending_reviews'] as num?)?.toInt() ?? 0;
    const lav = (AppColors.attendanceCard, AppColors.attendanceAction);
    const cyan = (AppColors.leaveCard, AppColors.leaveAction);
    const peach = (AppColors.salaryCard, AppColors.salaryAction);
    const teal = (AppColors.approvalsCard, AppColors.approvalsAction);

    final rows = <(IconData, String, (Color, Color), String, String?)>[
      (Icons.near_me_outlined, 'Apply Regularization', lav, '/corrections/new', null),
      (Icons.info_outline_rounded, 'Attendance Info', lav, '/attendance', null),
      if (s?.canTeamReports ?? false) (Icons.groups_outlined, 'Who Is In', lav, '/reports/hours', null),
      (Icons.coffee_outlined, 'Apply Leave', cyan, '/leave/apply', null),
      (Icons.view_week_outlined, 'Leave Balance', cyan, '/leave', null),
      (Icons.calendar_month_outlined, 'Holiday Calendar', cyan, '/holidays', null),
      (Icons.receipt_long_outlined, 'Payslips', peach, '/payslips', null),
      (Icons.assignment_outlined, 'My Requests', peach, '/requests', null),
      if (s?.canReview ?? false) (Icons.fact_check_outlined, 'Review Requests', teal, '/approvals', pending > 0 ? '$pending' : null),
    ];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const PageTitle('Actions'),
          const OfflineBanner(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.page),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
              itemBuilder: (context, i) {
                final r = rows[i];
                return ActionRow(
                  icon: r.$1,
                  label: r.$2,
                  tileColor: r.$3.$1,
                  iconColor: r.$3.$2,
                  badge: r.$5,
                  onTap: () => context.push(r.$4),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
