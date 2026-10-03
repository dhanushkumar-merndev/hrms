import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/session_controller.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/states.dart';

/// S06 — Explore modules (refs 03–07). One card expanded at a time; role
/// workspaces appear only for users who have them. Worklife/Helpdesk and
/// tax items from the references are deferred and not shown.
class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionContextProvider);
    void go(String path) => context.push(path);

    final modules = <_Module>[
      _Module('attendance', 'Attendance', 'Manage your attendance.', AppColors.attendanceCard, AppColors.attendanceAction, 'attendance', [
        ('Check in / out', () => go('/punch')),
        ('Attendance', () => go('/attendance')),
        ('Fix a punch', () => go('/corrections/new')),
      ]),
      _Module('leave', 'Leave', 'Check and apply for leaves.', AppColors.leaveCard, AppColors.leaveAction, 'leave', [
        ('Apply Leave', () => go('/leave/apply')),
        ('Leave Balance', () => go('/leave')),
        ('Holiday Calendar', () => go('/holidays')),
        ('My Requests', () => go('/requests')),
      ]),
      _Module('salary', 'Salary', 'Your published payslips.', AppColors.salaryCard, AppColors.salaryAction, 'salary', [
        ('My salary', () => go('/salary')),
        ('Payslips', () => go('/payslips')),
        if (s?.canManagePayroll ?? false) ('Payroll uploads', () => go('/payroll/uploads')),
      ]),
      _Module('people', 'People', 'A data hub for personal info and workmates', AppColors.peopleCard, AppColors.peopleAction, 'people', [
        ('My Profile', () => go('/profile')),
        ('My Workmates', () => go('/people')),
        if (s?.canViewEmployees ?? false) ('Employees', () => go('/employees')),
        if ((s?.canProvision ?? false) || (s?.canManagePayroll ?? false)) ('Import from Excel', () => go('/employees/import')),
        ('Settings', () => go('/settings')),
      ]),
      if (s?.canReview ?? false)
        _Module('todo', 'To Do', 'Review pending items.', AppColors.approvalsCard, AppColors.approvalsAction, 'todo', [
          ('Review', () => go('/approvals')),
        ]),
      _Module('documents', 'Documents', 'Company policies and your documents.', AppColors.documentsCard, AppColors.documentsAction, 'documents', [
        ('Documents', () => go('/documents')),
        ('Company policies', () => go('/policies')),
      ]),
      if (s?.hasWorkspace ?? false)
        _Module('workspace', 'Workspace', 'Team status, approvals and hours.', AppColors.workspaceCard, AppColors.workspaceAction, 'workspace', [
          ('Workspace', () => go('/workspace')),
          if (s?.canTeamReports ?? false) ('Hours report', () => go('/reports/hours')),
          if (s?.canAudit ?? false) ('Audit history', () => go('/admin/audit')),
          if (s?.canAnnounce ?? false) ('Announcement', () => go('/announcements/new')),
        ]),
      if ((s?.isAdmin ?? false) || (s?.canMasterData ?? false) || (s?.canDraftPolicy ?? false))
        _Module('admin', 'Admin', 'Organisation setup and controls.', AppColors.attendanceCard, AppColors.primary, 'admin', [
          if (s?.isAdmin ?? false) ('Organization', () => go('/admin/organization')),
          if (s?.canMasterData ?? false) ('Teams', () => go('/admin/teams')),
          if (s?.isAdmin ?? false) ('Offices & Wi-Fi', () => go('/admin/offices')),
          if (s?.isAdmin ?? false) ('Outside work', () => go('/admin/outside-work')),
          if ((s?.canMasterData ?? false) || (s?.canDraftPolicy ?? false)) ('Shifts', () => go('/admin/shifts')),
          if (s?.canDraftPolicy ?? false) ('Leave & holidays', () => go('/admin/leave-policies')),
          if (s?.isAdmin ?? false) ('Weekly off (Saturdays)', () => go('/admin/leave-policies?tab=holidays')),
          if (s?.canDraftPolicy ?? false) ('Company policies', () => go('/policies')),
          if (s?.isAdmin ?? false) ('Permissions', () => go('/admin/permissions')),
          if (s?.isAdmin ?? false) ('Annual archive', () => go('/admin/archive')),
          if (s?.isAdmin ?? false) ('Google Sheet', () => go('/admin/google-sheet')),
        ]),
    ];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const PageTitle('Explore'),
          const OfflineBanner(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(AppSpacing.page),
              itemCount: modules.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.lg),
              itemBuilder: (context, i) {
                final m = modules[i];
                return ModuleCard(
                  title: m.title,
                  subtitle: m.subtitle,
                  color: m.color,
                  actionColor: m.action,
                  illustration: m.art,
                  expanded: _open == m.id,
                  onToggle: () => setState(() => _open = _open == m.id ? null : m.id),
                  actions: m.actions,
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _Module {
  const _Module(this.id, this.title, this.subtitle, this.color, this.action, this.art, this.actions);
  final String id;
  final String title;
  final String subtitle;
  final Color color;
  final Color action;
  final String art;
  final List<(String, VoidCallback)> actions;
}
