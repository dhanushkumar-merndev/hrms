import 'package:go_router/go_router.dart';

import '../features/attendance/attendance_day_screen.dart';
import '../features/attendance/attendance_screen.dart';
import '../features/attendance/correction_screen.dart';
import '../features/leave/leave_apply_screen.dart';
import '../features/leave/leave_screen.dart';
import '../features/requests/my_requests_screen.dart';

/// Feature screens beyond the core shell. Unknown routes show the
/// "coming in the next build" page.
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
    builder: (_, s) => CorrectionScreen(date: s.uri.queryParameters['date'], editRequestId: s.uri.queryParameters['edit']),
  ),
  GoRoute(path: '/requests', builder: (_, _) => const MyRequestsScreen()),
  GoRoute(path: '/requests/:id', builder: (_, s) => RequestDetailScreen(id: s.pathParameters['id']!)),
  GoRoute(path: '/leave', builder: (_, _) => const LeaveScreen()),
  GoRoute(path: '/leave/apply', builder: (_, s) => LeaveApplyScreen(editRequestId: s.uri.queryParameters['edit'])),
  GoRoute(path: '/holidays', builder: (_, _) => const HolidaysScreen()),
];
