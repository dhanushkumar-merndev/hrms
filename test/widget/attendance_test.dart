import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/core/time/org_time.dart';
import 'package:hrms/features/attendance/attendance_screen.dart';

import 'support.dart';

Map<String, dynamic> _month() {
  OrgTime.init('Asia/Kolkata');
  final today = OrgTime.today();
  String day(int offset) => OrgTime.ymd(today.add(Duration(days: offset)));
  final last = DateTime(today.year, today.month + 1, 0);
  return {
    'totals': {
      'required_seconds': 36000,
      'credited_seconds': 27000,
      'shortfall_seconds': 3600,
      'extra_seconds': 0,
      'present_days': 3,
      'late_days': 1,
      'absent_days': 1,
      'leave_days': 0,
    },
    'rows': [
      {'shift_date': day(0), 'status': 'present', 'is_required': true, 'credited_seconds': 27000,
       'shortfall_seconds': 3600, 'effective_in_at': '${day(0)}T04:30:00Z',
       'effective_out_at': '${day(0)}T12:00:00Z', 'effective_source': 'device'},
      if (today.day > 1)
        {'shift_date': day(-1), 'status': 'absent', 'is_required': true,
         'start_at': '${day(-1)}T04:30:00Z', 'end_at': '${day(-1)}T13:30:00Z'},
      if (last.day - today.day >= 1)
        {'shift_date': day(1), 'status': 'upcoming', 'is_required': true,
         'start_at': '${day(1)}T04:30:00Z', 'end_at': '${day(1)}T13:30:00Z'},
    ],
  };
}

Finder _tile(String label) =>
    find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label);

void main() {
  testWidgets('ATT-UI-001 month summary shows worked of expected, metrics and counts', (tester) async {
    final data = _month();
    await pumpScreen(tester, const AttendanceScreen(),
        session: testSession(), handler: (fn, _) => fn == 'list_my_attendance' ? data : null);

    expect(find.text('Worked this month'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Shortfall'), findsOneWidget);
    expect(find.text('Extra time'), findsOneWidget);
    // Present / Absent / Leave always show, three in a row; extras only when non-zero.
    expect(_tile('3 Present'), findsOneWidget);
    expect(_tile('1 Absent'), findsOneWidget);
    expect(_tile('0 Leave'), findsOneWidget);
    expect(_tile('1 Late'), findsOneWidget);
    expect(_tile('0 In progress'), findsNothing);
    expect(find.text('Today'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('ATT-UI-002 upcoming days fold away and the calendar shows a legend', (tester) async {
    final data = _month();
    final hasUpcoming = (data['rows'] as List).any((r) => (r as Map)['status'] == 'upcoming');
    final hasPast = (data['rows'] as List).length > 1;
    await pumpScreen(tester, const AttendanceScreen(),
        session: testSession(), handler: (fn, _) => fn == 'list_my_attendance' ? data : null);

    if (hasUpcoming && hasPast) {
      expect(find.text('Upcoming', skipOffstage: false), findsNothing);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show 1 upcoming day'));
      await tester.pumpAndSettle();
      expect(find.text('Hide upcoming days', skipOffstage: false), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Upcoming'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Upcoming'), findsOneWidget);
    }

    await tester.tap(find.byTooltip('Show calendar'));
    await tester.pumpAndSettle();
    expect(find.text('Holiday / off'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^${OrgTime.today().day}, Present')), findsOneWidget);
    await unmount(tester);
  });
}
