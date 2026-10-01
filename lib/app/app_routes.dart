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

/// Feature screens beyond the core shell (S07–S38). Route guards are UX only:
/// every screen re-reads permissions and the server authorises each call.
/// Deep links carry ids only; details are re-fetched with current access.
final List<RouteBase> featureRoutes = [
  GoRoute(
    path: '/attendance',
    builder: (_, s) => AttendanceScreen(filter: s.uri.queryParameters['filter']),
    routes: [
      GoRoute(
        path: 'day',
        builder: (_, s) => AttendanceDayScreen(
          date: s.uri.queryParameters['date'] ?? '',
          employeeId: s.uri.queryParameters['employee'],
        ),
      ),
    ],
  ),
  GoRoute(
    path: '/corrections/new',
    builder: (_, s) =>
        CorrectionScreen(date: s.uri.queryParameters['date'], editRequestId: s.uri.queryParameters['edit']),
  ),
  GoRoute(path: '/requests', builder: (_, _) => const MyRequestsScreen()),
  GoRoute(
    path: '/requests/:id',
    builder: (_, s) => RequestDetailScreen(id: s.pathParameters['id']!),
  ),
  GoRoute(path: '/leave', builder: (_, _) => const LeaveScreen()),
  GoRoute(
    path: '/leave/apply',
    builder: (_, s) => LeaveApplyScreen(editRequestId: s.uri.queryParameters['edit']),
  ),
  GoRoute(path: '/holidays', builder: (_, _) => const HolidaysScreen()),
  GoRoute(path: '/payslips', builder: (_, _) => const PayslipsScreen()),
  GoRoute(path: '/salary', builder: (_, _) => const MySalaryScreen()),
  GoRoute(path: '/profile', builder: (_, _) => const ProfileScreen()),
  GoRoute(path: '/people', builder: (_, _) => const PeopleScreen()),
  GoRoute(path: '/documents', builder: (_, _) => const DocumentsScreen()),
  GoRoute(path: '/notifications', builder: (_, _) => const NotificationsScreen()),
  GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
  GoRoute(path: '/workspace', builder: (_, _) => const WorkspaceScreen()),
  GoRoute(path: '/approvals', builder: (_, _) => const ApprovalsScreen()),
  GoRoute(
    path: '/approvals/:id',
    builder: (_, s) => ApprovalDetailScreen(id: s.pathParameters['id']!),
  ),
  GoRoute(
    path: '/reports/hours',
    builder: (_, s) => HoursReportScreen(employeeId: s.uri.queryParameters['employee']),
  ),
  GoRoute(
    path: '/employees',
    builder: (_, _) => const EmployeesScreen(),
    routes: [
      GoRoute(path: 'new', builder: (_, _) => const EmployeeNewScreen()),
      GoRoute(path: 'import', builder: (_, _) => const EmployeeImportScreen()),
      GoRoute(
        path: ':id',
        builder: (_, s) => EmployeeDetailScreen(id: s.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: '/payroll/uploads',
    builder: (_, s) => PayrollUploadsScreen(employeeId: s.uri.queryParameters['employee']),
  ),
  GoRoute(path: '/announcements/new', builder: (_, _) => const AnnouncementScreen()),
  GoRoute(path: '/admin/organization', builder: (_, _) => const OrganizationScreen()),
  GoRoute(path: '/admin/teams', builder: (_, _) => const TeamsScreen()),
  GoRoute(path: '/admin/offices', builder: (_, _) => const OfficesScreen()),
  GoRoute(path: '/admin/shifts', builder: (_, _) => const ShiftsScreen()),
  GoRoute(
    path: '/admin/leave-policies',
    builder: (_, s) => LeavePoliciesScreen(initialTab: s.uri.queryParameters['tab']),
  ),
  GoRoute(path: '/admin/permissions', builder: (_, _) => const PermissionsScreen()),
  GoRoute(path: '/admin/audit', builder: (_, _) => const AuditScreen()),
  GoRoute(path: '/admin/google-sheet', builder: (_, _) => const SheetSyncScreen()),
  GoRoute(
    path: '/admin/archive',
    builder: (_, _) => const ArchiveScreen(),
    routes: [
      GoRoute(
        path: 'restore/:periodId',
        builder: (_, s) => ArchiveRestoreScreen(periodId: s.pathParameters['periodId']!),
      ),
      GoRoute(
        path: ':id',
        builder: (_, s) => ArchiveJobScreen(id: s.pathParameters['id']!),
      ),
    ],
  ),
];
