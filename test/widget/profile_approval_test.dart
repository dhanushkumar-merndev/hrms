import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/core/api/api_client.dart';
import 'package:hrms/features/people/profile_screen.dart';

import 'support.dart';

const _profile = {
  'id': 'e1',
  'code': 'EMP001',
  'name': 'Asha Rao',
  'roles': <String>[],
  'join_date': '2026-01-01',
  'private': {
    'personal_email': null,
    'personal_phone': null,
    'address': null,
    'emergency_contact_name': null,
    'emergency_contact_phone': null,
    'date_of_birth': null,
    'version': 1,
  },
};

void main() {
  testWidgets(
    'PROFILE-UI-001 Member submits personal details for verification',
    (tester) async {
      final api = await pumpScreen(
        tester,
        const ProfileScreen(),
        session: testSession(),
        handler: (fn, _) => switch (fn) {
          'get_my_profile' => _profile,
          'save_profile_details_request' => {
            'id': 'request-1',
            'state': 'submitted',
          },
          _ => null,
        },
      );

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      final submit = find.text('Submit for verification', skipOffstage: false);
      expect(submit, findsOneWidget);
      expect(
        find.textContaining('remain active until HR or Admin verifies'),
        findsOneWidget,
      );
      await tester.drag(find.byType(ListView).last, const Offset(0, -500));
      await tester.pumpAndSettle();
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      final call = api.calls.lastWhere(
        (entry) => entry.$1 == 'save_profile_details_request',
      );
      expect(call.$2?['p_request_id'], isNull);
      expect(call.$2?['p_expected_private_version'], 1);
      expect(call.$2?['p_operation_key'], isNotNull);
      expect(api.names, isNot(contains('update_my_profile')));
      await unmount(tester);
    },
  );

  testWidgets('PROFILE-UI-002 Admin sees immediate audited save copy', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const ProfileScreen(),
      session: testSession(roles: const ['admin'], permissions: const ['*']),
      handler: (fn, _) => fn == 'get_my_profile' ? _profile : null,
    );

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Save now', skipOffstage: false), findsOneWidget);
    expect(
      find.textContaining('apply immediately and are audited'),
      findsOneWidget,
    );
    expect(
      find.text('Submit for verification', skipOffstage: false),
      findsNothing,
    );
    await unmount(tester);
  });

  testWidgets(
    'PROFILE-UI-003 pending proposal does not replace approved profile values',
    (tester) async {
      final pending = {
        ..._profile,
        'private': {
          ...(_profile['private'] as Map<String, Object?>),
          'personal_phone': '+91 90000 00000',
        },
        'profile_request': {
          'id': 'request-1',
          'state': 'submitted',
          'version': 1,
        },
      };
      await pumpScreen(
        tester,
        const ProfileScreen(),
        session: testSession(),
        handler: (fn, _) => fn == 'get_my_profile' ? pending : null,
      );

      expect(find.text('+91 90000 00000'), findsOneWidget);
      expect(find.text('View request'), findsOneWidget);
      expect(
        find.textContaining('approved details below stay active'),
        findsOneWidget,
      );
      expect(find.text('Edit'), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets('PROFILE-UI-004 returned revision is loaded for resubmission', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const ProfileScreen(editRequestId: 'request-1'),
      session: testSession(),
      handler: (fn, _) => switch (fn) {
        'get_my_profile' => _profile,
        'get_my_request' => const ApiResult(
          {
            'id': 'request-1',
            'state': 'returned',
            'revisions': [
              {
                'payload': {
                  'target_version': 1,
                  'patch': {'address': 'Returned proposed address'},
                },
              },
            ],
          },
          7,
          'test-request',
        ),
        _ => null,
      },
    );
    await tester.pumpAndSettle();

    expect(find.text('Fix personal details'), findsOneWidget);
    expect(
      find.text('Resubmit for verification', skipOffstage: false),
      findsOneWidget,
    );
    final address = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Address'),
    );
    expect(address.controller?.text, 'Returned proposed address');
    await unmount(tester);
  });
}
