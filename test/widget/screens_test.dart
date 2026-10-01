import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/core/auth/session_controller.dart';
import 'package:hrms/features/approvals/approvals_screen.dart';
import 'package:hrms/features/employees/employee_new_screen.dart';
import 'package:hrms/features/home/home_providers.dart';
import 'package:hrms/features/notifications/notifications_screen.dart';
import 'package:hrms/features/payslips/payslips_screen.dart';

import 'support.dart';

const _structure = {'departments': [], 'teams': [], 'offices': [], 'shifts': []};

void main() {
  testWidgets('S14 lists salary-month slots with honest statuses (FILE-009/010)', (tester) async {
    await pumpScreen(tester, const PayslipsScreen(), session: testSession(), handler: (fn, _) => switch (fn) {
          'list_my_payslips' => {
              'window_start': '2025-10-01',
              'slots': [
                {'salary_month': '2026-09-01', 'status': 'available', 'file_version_id': 'v1',
                  'published_at': '2026-09-30T10:00:00Z', 'replaced': true},
                {'salary_month': '2026-08-01', 'status': 'missing'},
                {'salary_month': '2025-12-01', 'status': 'archived'},
              ],
            },
          _ => null,
        });
    expect(find.text('Sep 2026'), findsOneWidget);
    expect(find.text('Available'), findsOneWidget);
    expect(find.text('Revised'), findsOneWidget);
    // Months without a payslip are summed up, not listed one row each.
    expect(find.text('Aug 2026'), findsNothing);
    expect(find.textContaining('1 month is not uploaded yet'), findsOneWidget);
    expect(find.text('Archived locally — contact HR'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('S22 is hidden from members; the server still authorises every call', (tester) async {
    final api = await pumpScreen(tester, const ApprovalsScreen(), session: testSession(), handler: (fn, _) => const []);
    expect(find.text('No access'), findsOneWidget);
    expect(api.names, isNot(contains('list_review_queue')));
    await unmount(tester);
  });

  testWidgets('REVIEW-001 the reviewer queue lists without opening (locking) any request', (tester) async {
    final api = await pumpScreen(
      tester,
      const ApprovalsScreen(),
      session: testSession(roles: ['manager'], permissions: ['reports.team', 'approvals.review']),
      handler: (fn, _) => switch (fn) {
        'list_review_queue' => [
            {'id': 'r1', 'kind': 'leave', 'state': 'submitted', 'version': 2, 'current_revision': 1, 'edited': false,
              'employee': {'id': 'e2', 'name': 'Ravi Kumar', 'code': 'EMP002'},
              'leave_type': {'id': 't1', 'code': 'CL', 'name': 'Casual Leave'},
              'start_date': '2026-10-05', 'end_date': '2026-10-06', 'units': 4,
              'submitted_at': '2026-09-30T05:00:00Z', 'reviewer_assigned': true},
          ],
        _ => null,
      },
    );
    expect(find.text('Ravi Kumar · EMP002'), findsOneWidget);
    expect(find.textContaining('2 days'), findsOneWidget);
    expect(api.names, contains('list_review_queue'));
    expect(api.names, isNot(contains('open_request_for_review')));
    await unmount(tester);
  });

  testWidgets('AUTH-004 HR can create Members/Managers but is never offered HR or Admin', (tester) async {
    await pumpScreen(tester, const EmployeeNewScreen(),
        session: testSession(roles: ['hr'], permissions: hrPermissions),
        handler: (fn, _) => fn == 'list_org_structure' ? _structure : null);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Manager'), findsWidgets);
    expect(find.text('Admin'), findsNothing);
    expect(find.text('HR'), findsNothing);
    await unmount(tester);
  });

  testWidgets('Admin is offered every role when creating employees', (tester) async {
    await pumpScreen(tester, const EmployeeNewScreen(),
        session: testSession(roles: ['admin'], permissions: ['*']),
        handler: (fn, _) => fn == 'list_org_structure' ? _structure : null);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Admin'), findsWidgets);
    expect(find.text('HR'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('S19 inbox shows unread items and marks all read', (tester) async {
    final api = await pumpScreen(tester, const NotificationsScreen(), session: testSession(), handler: (fn, _) => switch (fn) {
          'list_notifications' => {
              'unread': 1,
              'rows': [
                {'id': 'n1', 'event_id': 'ev1', 'kind': 'payslip.published', 'title': 'Payslip available',
                  'body': 'A payslip has been published. Open the app to view it.', 'deep_link': '/payslips',
                  'read_at': null, 'created_at': '2026-09-30T10:00:00Z'},
              ],
            },
          'mark_notifications_read' => {'marked': 1},
          _ => null,
        });
    expect(find.text('Payslip available'), findsOneWidget);
    await tester.tap(find.text('Mark all read'));
    await tester.pumpAndSettle();
    expect(api.names, contains('mark_notifications_read'));
    await unmount(tester);
  });

  test('CACHE-001 cached data is dropped the moment the signed-in identity changes', () async {
    var loads = 0;
    final cached = FutureProvider.autoDispose<int>((ref) async {
      cacheFor(ref, const Duration(minutes: 5));
      return ++loads;
    });
    final session = FakeSession(testSession(id: 'employee-a'));
    final container = ProviderContainer(overrides: [sessionProvider.overrideWith(() => session)]);
    addTearDown(container.dispose);
    container.read(sessionProvider);

    expect(await container.read(cached.future), 1);
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(cached.future), 1, reason: 'kept for the TTL while the same person is signed in');

    session.switchTo(testSession(id: 'employee-b'));
    await container.pump();
    await container.pump();
    expect(await container.read(cached.future), 2, reason: 'another person never sees the first person\'s cache');

    session.switchTo(null);
    await container.pump();
    await container.pump();
    expect(await container.read(cached.future), 3, reason: 'sign-out drops cached data too');
  });
}
