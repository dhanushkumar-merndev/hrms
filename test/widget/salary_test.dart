import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/core/device/local_auth.dart';
import 'package:hrms/features/salary/bank_details_request_screen.dart';
import 'package:hrms/features/salary/my_salary_screen.dart';

import 'support.dart';

class _FakeAuth extends LocalAuth {
  _FakeAuth(this.answer);
  final bool answer;
  int asked = 0;
  final secure = <bool>[];

  @override
  Future<bool> confirm({String title = '', String subtitle = ''}) async {
    asked++;
    return answer;
  }

  @override
  Future<void> secureScreen(bool on) async => secure.add(on);
}

const _salary = {
  'profile': {
    'monthly_salary': 45000,
    'currency': 'INR',
    'effective_from': '2026-04-01',
    'bank_name': 'HDFC Bank',
    'account_holder': 'Asha Rao',
    'account_last4': '5678',
    'ifsc': 'HDFC0001234',
    'bank_status': 'approved',
  },
  'lifetime_paid': 94500.5,
  'paid_months': 2,
  'recent': [
    {'salary_month': '2026-09-01', 'net_amount': 49500.5},
  ],
};

void main() {
  testWidgets(
    'BANK-UI-001 Member bank changes are submitted for verification',
    (tester) async {
      await pumpScreen(
        tester,
        const BankDetailsRequestScreen(),
        session: testSession(),
        handler: (_, _) => null,
      );
      expect(
        find.textContaining('HR or Admin verifies each change'),
        findsOneWidget,
      );
      expect(
        find.text('Submit for approval', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('Save now', skipOffstage: false), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets(
    'BANK-UI-002 Admin bank changes apply immediately and are audited',
    (tester) async {
      await pumpScreen(
        tester,
        const BankDetailsRequestScreen(),
        session: testSession(roles: const ['admin'], permissions: const ['*']),
        handler: (_, _) => null,
      );
      expect(
        find.textContaining('apply immediately and are audited'),
        findsOneWidget,
      );
      expect(find.text('Save now', skipOffstage: false), findsOneWidget);
      expect(
        find.text('Submit for approval', skipOffstage: false),
        findsNothing,
      );
      await unmount(tester);
    },
  );

  testWidgets(
    'SAL-UI-001 salary stays masked and is not even fetched until the fingerprint check passes',
    (tester) async {
      final auth = _FakeAuth(false);
      final api = await pumpScreen(
        tester,
        MySalaryScreen(auth: auth),
        session: testSession(),
        handler: (fn, _) => fn == 'get_my_salary' ? _salary : null,
      );
      expect(auth.secure, [true], reason: 'screenshots blocked on open');
      expect(find.textContaining('45,000'), findsNothing);
      await tester.tap(find.bySemanticsLabel(RegExp('Salary card, hidden')));
      await tester.pumpAndSettle();
      expect(auth.asked, 1);
      expect(
        api.names,
        isNot(contains('get_my_salary')),
        reason: 'cancelled check -> nothing loaded',
      );
      expect(find.textContaining('45,000'), findsNothing);
      await unmount(tester);
      expect(auth.secure, [
        true,
        false,
      ], reason: 'screenshot block lifted on leave');
    },
  );

  testWidgets(
    'SAL-UI-002 reveal shows salary, bank and lifetime; Hide and app background mask it again',
    (tester) async {
      final auth = _FakeAuth(true);
      await pumpScreen(
        tester,
        MySalaryScreen(auth: auth),
        session: testSession(),
        handler: (fn, _) => fn == 'get_my_salary' ? _salary : null,
      );
      await tester.tap(find.bySemanticsLabel(RegExp('Salary card, hidden')));
      await tester.pumpAndSettle();
      expect(find.text('₹45,000'), findsOneWidget);
      expect(find.text('₹94,500.50'), findsOneWidget);
      expect(find.text('HDFC Bank'), findsWidgets);
      expect(find.text('••••  ••••  ••••  5678'), findsOneWidget);
      expect(
        find.text('Visible for 60 seconds · tap the card to hide'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.text('Visible for 59 seconds · tap the card to hide'),
        findsOneWidget,
      );

      // App goes to the background -> masked again.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      // (No frames are drawn while hidden; check once the app is back.)
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.text('₹45,000'),
        findsNothing,
        reason: 'masked when the app went to the background',
      );

      // Reveal again, then auto-hide after a minute.
      await tester.tap(find.bySemanticsLabel(RegExp('Salary card, hidden')));
      await tester.pumpAndSettle();
      expect(find.text('₹45,000'), findsOneWidget);
      await tester.pump(const Duration(seconds: 60));
      await tester.pumpAndSettle();
      expect(find.text('₹45,000'), findsNothing);
      await unmount(tester);
    },
  );
}
