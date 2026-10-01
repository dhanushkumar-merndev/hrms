import 'package:go_router/go_router.dart';

import '../features/admin/audit_screen.dart';
import '../features/admin/leave_policies_screen.dart';
import '../features/admin/offices_screen.dart';
import '../features/admin/organization_screen.dart';
import '../features/admin/permissions_screen.dart';
import '../features/admin/shifts_screen.dart';
import '../features/admin/teams_screen.dart';
import '../features/announcements/announcement_screen.dart';
import '../features/approvals/approval_detail_screen.dart';
import '../features/approvals/approvals_screen.dart';
import '../features/archive/archive_job_screen.dart';
import '../features/archive/archive_restore_screen.dart';
import '../features/archive/archive_screen.dart';
import '../features/attendance/attendance_day_screen.dart';
import '../features/attendance/attendance_screen.dart';
import '../features/attendance/correction_screen.dart';
import '../features/documents/documents_screen.dart';
import '../features/employees/employee_detail_screen.dart';
import '../features/employees/employee_new_screen.dart';
import '../features/employees/employees_screen.dart';
import '../features/leave/leave_apply_screen.dart';
import '../features/leave/leave_screen.dart';
import '../features/notifications/notifications_screen.dart';
import '../features/payroll/payroll_uploads_screen.dart';
import '../features/admin/sheet_sync_screen.dart';
import '../features/employees/employee_import_screen.dart';
import '../features/payslips/payslips_screen.dart';
import '../features/salary/my_salary_screen.dart';
import '../features/people/people_screen.dart';
import '../features/people/profile_screen.dart';
import '../features/reports/hours_report_screen.dart';
import '../features/requests/my_requests_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/workspace/workspace_screen.dart';
import 'material_route.dart';

/// Feature screens beyond the core shell (S07–S38). Route guards are UX only:
/// every screen re-reads permissions and the server authorises each call.
/// Deep links carry ids only; details are re-fetched with current access.
final List<RouteBase> featureRoutes = [
  AppRoute(
    path: '/attendance',
    builder: (_, s) => AttendanceScreen(filter: s.uri.queryParameters['filter']),
    routes: [
      AppRoute(
        path: 'day',
        builder: (_, s) => AttendanceDayScreen(
          date: s.uri.queryParameters['date'] ?? '',
          employeeId: s.uri.queryParameters['employee'],
        ),
      ),
    ],
  ),
  AppRoute(
    path: '/corrections/new',
    builder: (_, s) =>
        CorrectionScreen(date: s.uri.queryParameters['date'], editRequestId: s.uri.queryParameters['edit']),
  ),
  AppRoute(path: '/requests', builder: (_, _) => const MyRequestsScreen()),
  AppRoute(
    path: '/requests/:id',
    builder: (_, s) => RequestDetailScreen(id: s.pathParameters['id']!),
  ),
  AppRoute(path: '/leave', builder: (_, _) => const LeaveScreen()),
  AppRoute(
    path: '/leave/apply',
    builder: (_, s) => LeaveApplyScreen(editRequestId: s.uri.queryParameters['edit']),
  ),
  AppRoute(path: '/holidays', builder: (_, _) => const HolidaysScreen()),
  AppRoute(path: '/payslips', builder: (_, _) => const PayslipsScreen()),
  AppRoute(path: '/salary', builder: (_, _) => const MySalaryScreen()),
  AppRoute(path: '/profile', builder: (_, _) => const ProfileScreen()),
  AppRoute(path: '/people', builder: (_, _) => const PeopleScreen()),
  AppRoute(path: '/documents', builder: (_, _) => const DocumentsScreen()),
  AppRoute(path: '/notifications', builder: (_, _) => const NotificationsScreen()),
  AppRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
  AppRoute(path: '/workspace', builder: (_, _) => const WorkspaceScreen()),
  AppRoute(path: '/approvals', builder: (_, _) => const ApprovalsScreen()),
  AppRoute(
    path: '/approvals/:id',
    builder: (_, s) => ApprovalDetailScreen(id: s.pathParameters['id']!),
  ),
  AppRoute(
    path: '/reports/hours',
    builder: (_, s) => HoursReportScreen(employeeId: s.uri.queryParameters['employee']),
  ),
  AppRoute(
    path: '/employees',
    builder: (_, _) => const EmployeesScreen(),
    routes: [
      AppRoute(path: 'new', builder: (_, _) => const EmployeeNewScreen()),
      AppRoute(path: 'import', builder: (_, _) => const EmployeeImportScreen()),
      AppRoute(
        path: ':id',
        builder: (_, s) => EmployeeDetailScreen(id: s.pathParameters['id']!),
      ),
    ],
  ),
  AppRoute(
    path: '/payroll/uploads',
    builder: (_, s) => PayrollUploadsScreen(employeeId: s.uri.queryParameters['employee']),
  ),
  AppRoute(path: '/announcements/new', builder: (_, _) => const AnnouncementScreen()),
  AppRoute(path: '/admin/organization', builder: (_, _) => const OrganizationScreen()),
  AppRoute(path: '/admin/teams', builder: (_, _) => const TeamsScreen()),
  AppRoute(path: '/admin/offices', builder: (_, _) => const OfficesScreen()),
  AppRoute(path: '/admin/shifts', builder: (_, _) => const ShiftsScreen()),
  AppRoute(
    path: '/admin/leave-policies',
    builder: (_, s) => LeavePoliciesScreen(initialTab: s.uri.queryParameters['tab']),
  ),
  AppRoute(path: '/admin/permissions', builder: (_, _) => const PermissionsScreen()),
  AppRoute(path: '/admin/audit', builder: (_, _) => const AuditScreen()),
  AppRoute(path: '/admin/google-sheet', builder: (_, _) => const SheetSyncScreen()),
  AppRoute(
    path: '/admin/archive',
    builder: (_, _) => const ArchiveScreen(),
    routes: [
      AppRoute(
        path: 'restore/:periodId',
        builder: (_, s) => ArchiveRestoreScreen(periodId: s.pathParameters['periodId']!),
      ),
      AppRoute(
        path: ':id',
        builder: (_, s) => ArchiveJobScreen(id: s.pathParameters['id']!),
      ),
    ],
  ),
];
