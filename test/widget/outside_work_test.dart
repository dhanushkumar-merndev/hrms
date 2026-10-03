import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/features/admin/outside_work_screen.dart';

import 'support.dart';

void main() {
  testWidgets('OUT-UI-001 Admin sees outside work days and can remove one with a reason', (tester) async {
    final api = await pumpScreen(tester, const OutsideWorkScreen(),
        session: testSession(roles: const ['admin']),
        handler: (fn, _) => switch (fn) {
              'list_outside_work' => [
                  {'id': 'o1', 'work_date': '2026-10-12', 'reason': 'Client visit',
                   'employee': {'id': 'e2', 'code': 'EMP02', 'name': 'Ravi Kumar'}},
                ],
              'revoke_outside_work' => {'id': 'o1'},
              _ => null,
            });
    expect(find.text('Ravi Kumar'), findsOneWidget);
    expect(find.textContaining('Client visit'), findsOneWidget);
    expect(find.text('Send people out'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Visit cancelled');
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(api.names, contains('revoke_outside_work'));
    await unmount(tester);
  });

  testWidgets('OUT-UI-002 100 people: fixed-height list with search and select-all-matches', (tester) async {
    final people = [
      for (var i = 1; i <= 100; i++) {'id': 'e$i', 'code': 'EMP${i.toString().padLeft(3, '0')}', 'name': i == 42 ? 'Zara Video' : 'Person $i'},
    ];
    await pumpScreen(tester, const OutsideWorkScreen(),
        session: testSession(roles: const ['admin']),
        handler: (fn, params) => switch (fn) {
              'list_outside_work' => const [],
              'list_employees' => {'rows': (params?['p_offset'] as int? ?? 0) == 0 ? people : const []},
              _ => null,
            });
    await tester.tap(find.text('Send people out'));
    await tester.pumpAndSettle();

    expect(find.text('Select everyone (100)'), findsOneWidget);
    // Only a screenful is built: the list scrolls inside its box.
    expect(find.text('Person 100'), findsNothing);
    expect(find.text('Mark as outside work'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Search name or ID'), 'zara');
    await tester.pumpAndSettle();
    expect(find.text('Select all matches (1)'), findsOneWidget);
    await tester.tap(find.text('Select all matches (1)'));
    await tester.pumpAndSettle();
    expect(find.text('People · 1 selected'), findsOneWidget);
    expect(find.text('Mark 1 as outside work'), findsOneWidget);
    await unmount(tester);
  });
}
