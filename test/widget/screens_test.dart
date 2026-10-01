import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/core/auth/session_controller.dart';
import 'package:hrms/features/action/action_screen.dart';
import 'package:hrms/features/approvals/approvals_screen.dart';
import 'package:hrms/features/employees/employee_new_screen.dart';
import 'package:hrms/features/home/home_providers.dart';
import 'package:hrms/features/home/home_screen.dart';
import 'package:hrms/features/leave/leave_screen.dart';
import 'package:hrms/features/notifications/notifications_screen.dart';
import 'package:hrms/features/payslips/payslips_screen.dart';
import 'package:hrms/features/requests/my_requests_screen.dart';

import 'support.dart';

const _structure = {
  'departments': [],
  'teams': [],
  'offices': [],
  'shifts': [],
};

void main() {
  testWidgets(
    'home live clock renders every day phase at a compact 88px size',
    (tester) async {
      final cases = [
        (DateTime(2026, 10, 1, 8, 15), 'Office time 8:15 AM, morning'),
        (DateTime(2026, 10, 1, 14, 30), 'Office time 2:30 PM, afternoon'),
        (DateTime(2026, 10, 1, 18, 15), 'Office time 6:15 PM, sunset'),
        (DateTime(2026, 10, 1, 22, 7), 'Office time 10:07 PM, night'),
      ];

      for (final (now, semantics) in cases) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(child: HomeLiveClock(now: now)),
            ),
          ),
        );
        expect(find.bySemanticsLabel(semantics), findsOneWidget);
        expect(
          tester.getSize(find.byType(HomeLiveClock)),
          const Size.square(88),
        );
        expect(tester.takeException(), isNull);
      }

      await unmount(tester);
    },
  );

  testWidgets('home skyline renders all four office-time SVG phases', (
    tester,
  ) async {
    for (final now in [
      DateTime(2026, 10, 2, 8),
      DateTime(2026, 10, 2, 14),
      DateTime(2026, 10, 2, 18),
      DateTime(2026, 10, 2, 22),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(height: 72, child: HomeSkyline(now: now)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await unmount(tester);
  });

  testWidgets('home shift details stay readable on a narrow phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpScreen(
      tester,
      const HomeScreen(),
      session: testSession(),
      handler: (fn, _) => {
        'org': {'name': 'Test Org', 'timezone': 'Asia/Kolkata'},
        'me': {'name': 'Asha Rao', 'has_avatar': false},
        'shift': {
          'shift_date': '2026-10-01',
          'kind': 'workday',
          'is_required': true,
          'start_at': '2026-10-01T04:30:00Z',
          'end_at': '2026-10-01T13:30:00Z',
          'required_seconds': 32400,
          'lunch_paid': true,
          'blocked_reason': 'window_closed',
          'session_state': 'not_started',
        },
        'team': null,
        'upcoming_holidays': [],
        'extras': {},
        'exception_days': 0,
        'pending_reviews': 0,
        'unassigned_reviews': 0,
        'unread_notifications': 0,
      },
    );

    expect(find.text('10:00 AM–7:00 PM'), findsOneWidget);
    expect(find.textContaining('Lunch included'), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets(
    'published holiday replaces attendance action with a happy holiday message',
    (tester) async {
      await pumpScreen(
        tester,
        const HomeScreen(),
        session: testSession(),
        handler: (fn, _) => {
          'org': {'name': 'Test Org', 'timezone': 'Asia/Kolkata'},
          'me': {'name': 'Asha Rao', 'has_avatar': false},
          'today': '2026-10-02',
          'shift': {
            'shift_date': '2026-10-02',
            'kind': 'holiday',
            'is_required': false,
            'blocked_reason': 'holiday',
            'next_action': null,
          },
          'team': null,
          'upcoming_holidays': [
            {'id': 'h1', 'date': '2026-10-02', 'name': 'Gandhi Jayanti'},
          ],
          'extras': {},
          'exception_days': 0,
          'pending_reviews': 0,
          'unassigned_reviews': 0,
          'unread_notifications': 0,
        },
      );

      expect(find.text('Happy holiday!'), findsOneWidget);
      expect(find.textContaining('Gandhi Jayanti'), findsOneWidget);
      expect(find.text('Check in'), findsNothing);
      expect(find.text('Check out'), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets(
    'finished holidays are grayscale while upcoming holidays stay colorful',
    (tester) async {
      String day(DateTime value) => value.toIso8601String().substring(0, 10);
      final now = DateTime.now();
      await pumpScreen(
        tester,
        const HolidaysScreen(),
        session: testSession(),
        handler: (fn, _) => fn == 'list_holidays'
            ? {
                'can_manage': false,
                'holidays': [
                  {
                    'id': 'past1',
                    'name': 'Finished holiday',
                    'date': day(now.subtract(const Duration(days: 2))),
                    'state': 'published',
                  },
                  {
                    'id': 'next1',
                    'name': 'Upcoming holiday',
                    'date': day(now.add(const Duration(days: 2))),
                    'state': 'published',
                  },
                ],
              }
            : null,
      );
      expect(find.byKey(const ValueKey('past-holiday-past1')), findsOneWidget);
      expect(find.byKey(const ValueKey('past-holiday-next1')), findsNothing);
      expect(find.textContaining('Past'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    'S14 lists salary-month slots with honest statuses (FILE-009/010)',
    (tester) async {
      await pumpScreen(
        tester,
        const PayslipsScreen(),
        session: testSession(),
        handler: (fn, _) => switch (fn) {
          'list_my_payslips' => {
            'window_start': '2025-10-01',
            'slots': [
              {
                'salary_month': '2026-09-01',
                'status': 'available',
                'file_version_id': 'v1',
                'published_at': '2026-09-30T10:00:00Z',
                'replaced': true,
              },
              {'salary_month': '2026-08-01', 'status': 'missing'},
              {'salary_month': '2025-12-01', 'status': 'archived'},
            ],
          },
          _ => null,
        },
      );
      expect(find.text('Sep 2026'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      expect(find.text('Revised'), findsOneWidget);
      // Months without a payslip are summed up, not listed one row each.
      expect(find.text('Aug 2026'), findsNothing);
      expect(
        find.textContaining('1 month is not uploaded yet'),
        findsOneWidget,
      );
      expect(find.text('Archived locally — contact HR'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    'S22 is hidden from members; the server still authorises every call',
    (tester) async {
      final api = await pumpScreen(
        tester,
        const ApprovalsScreen(),
        session: testSession(),
        handler: (fn, _) => const [],
      );
      expect(find.text('No access'), findsOneWidget);
      expect(api.names, isNot(contains('list_review_queue')));
      await unmount(tester);
    },
  );

  testWidgets(
    'REVIEW-001 the reviewer queue lists without opening (locking) any request',
    (tester) async {
      final api = await pumpScreen(
        tester,
        const ApprovalsScreen(),
        session: testSession(
          roles: ['manager'],
          permissions: ['reports.team', 'approvals.review'],
        ),
        handler: (fn, _) => switch (fn) {
          'list_review_queue' => [
            {
              'id': 'r1',
              'kind': 'leave',
              'state': 'submitted',
              'version': 2,
              'current_revision': 1,
              'edited': false,
              'employee': {'id': 'e2', 'name': 'Ravi Kumar', 'code': 'EMP002'},
              'leave_type': {'id': 't1', 'code': 'CL', 'name': 'Casual Leave'},
              'start_date': '2026-10-05',
              'end_date': '2026-10-06',
              'units': 4,
              'submitted_at': '2026-09-30T05:00:00Z',
              'reviewer_assigned': true,
            },
          ],
          _ => null,
        },
      );
      expect(find.text('Ravi Kumar · EMP002'), findsOneWidget);
      expect(find.textContaining('2 days'), findsOneWidget);
      expect(api.names, contains('list_review_queue'));
      expect(api.names, isNot(contains('open_request_for_review')));
      await unmount(tester);
    },
  );

  testWidgets(
    'request history filters expose completed owner and reviewer records',
    (tester) async {
      final ownApi = await pumpScreen(
        tester,
        const MyRequestsScreen(),
        session: testSession(),
        handler: (fn, _) => fn == 'list_my_requests' ? const [] : null,
      );
      await tester.tap(find.byTooltip('Filter'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Completed'));
      await tester.tap(find.text('Show results'));
      await tester.pumpAndSettle();
      expect(
        ownApi.calls
            .lastWhere((call) => call.$1 == 'list_my_requests')
            .$2?['p_state'],
        'completed',
      );
      expect(find.text('No completed requests'), findsOneWidget);
      await unmount(tester);

      final reviewApi = await pumpScreen(
        tester,
        const ApprovalsScreen(),
        session: testSession(
          roles: ['manager'],
          permissions: ['approvals.review'],
        ),
        handler: (fn, _) => fn == 'list_review_queue' ? const [] : null,
      );
      await tester.tap(find.byTooltip('Filter'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Completed'));
      await tester.tap(find.text('Show results'));
      await tester.pumpAndSettle();
      expect(
        reviewApi.calls
            .lastWhere((call) => call.$1 == 'list_review_queue')
            .$2?['p_state'],
        'completed',
      );
      expect(find.text('No completed requests'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets('Action separates user, team and HR, and admin tools', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const ActionScreen(),
      session: testSession(roles: ['admin'], permissions: ['*']),
      handler: (fn, _) => switch (fn) {
        'get_home_summary' => {'pending_reviews': 2},
        'get_leave_balances' => {'balances': []},
        'list_my_requests' => const [],
        _ => null,
      },
    );

    expect(find.text('User'), findsOneWidget);
    expect(find.text('Team & HR'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Attendance'), findsOneWidget);
    expect(find.text('My attendance'), findsOneWidget);
    expect(find.text('Apply for leave'), findsNothing);
    await tester.tap(find.text('Leave'));
    await tester.pump();
    expect(find.text('Apply for leave'), findsOneWidget);
    await tester.tap(find.text('Salary'));
    await tester.pump();
    expect(find.text('My salary'), findsOneWidget);
    await tester.tap(find.text('Requests'));
    await tester.pump();
    expect(find.text('My requests'), findsOneWidget);
    expect(find.text('Requests'), findsOneWidget);
    await tester.tap(find.text('Team & HR'));
    await tester.pump();
    expect(find.text('Reviews'), findsOneWidget);
    expect(find.text('Review requests'), findsOneWidget);
    await tester.tap(find.text('Team'));
    await tester.pump();
    expect(find.text('Team hours'), findsOneWidget);
    await tester.tap(find.text('Payroll'));
    await tester.pump();
    expect(find.text('Payroll uploads'), findsOneWidget);
    await tester.tap(find.text('Admin'));
    await tester.pump();
    expect(find.text('Administration'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets(
    'AUTH-004 HR can create Members/Managers but is never offered HR or Admin',
    (tester) async {
      await pumpScreen(
        tester,
        const EmployeeNewScreen(),
        session: testSession(roles: ['hr'], permissions: hrPermissions),
        handler: (fn, _) => fn == 'list_org_structure' ? _structure : null,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      expect(find.text('Manager'), findsWidgets);
      expect(find.text('Admin'), findsNothing);
      expect(find.text('HR'), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets('Admin is offered every role when creating employees', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const EmployeeNewScreen(),
      session: testSession(roles: ['admin'], permissions: ['*']),
      handler: (fn, _) => fn == 'list_org_structure' ? _structure : null,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('Admin'), findsWidgets);
    expect(find.text('HR'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('S19 inbox shows unread items and marks all read', (
    tester,
  ) async {
    final api = await pumpScreen(
      tester,
      const NotificationsScreen(),
      session: testSession(),
      handler: (fn, _) => switch (fn) {
        'list_notifications' => {
          'unread': 1,
          'rows': [
            {
              'id': 'n1',
              'event_id': 'ev1',
              'kind': 'payslip.published',
              'title': 'Payslip available',
              'body': 'A payslip has been published. Open the app to view it.',
              'deep_link': '/payslips',
              'read_at': null,
              'created_at': '2026-09-30T10:00:00Z',
            },
          ],
        },
        'mark_notifications_read' => {'marked': 1},
        _ => null,
      },
    );
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
    final container = ProviderContainer(
      overrides: [sessionProvider.overrideWith(() => session)],
    );
    addTearDown(container.dispose);
    container.read(sessionProvider);

    expect(await container.read(cached.future), 1);
    await Future<void>.delayed(Duration.zero);
    expect(
      await container.read(cached.future),
      1,
      reason: 'kept for the TTL while the same person is signed in',
    );

    session.switchTo(testSession(id: 'employee-b'));
    await container.pump();
    await container.pump();
    expect(
      await container.read(cached.future),
      2,
      reason: 'another person never sees the first person\'s cache',
    );

    session.switchTo(null);
    await container.pump();
    await container.pump();
    expect(
      await container.read(cached.future),
      3,
      reason: 'sign-out drops cached data too',
    );
  });
}
