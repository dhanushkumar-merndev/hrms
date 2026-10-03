import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/app/theme.dart';
import 'package:hrms/core/api/api_client.dart';
import 'package:hrms/core/auth/session_controller.dart';
import 'package:hrms/features/admin/organization_screen.dart';
import 'package:hrms/features/auth/login_screen.dart';
import 'package:hrms/features/auth/support_phone.dart';

import 'support.dart';

Future<void> pumpLogin(
  WidgetTester tester, {
  required Future<SupportPhone?> Function() support,
  Future<bool> Function(Uri)? launch,
  Future<void> Function(String)? copy,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(() => FakeSession(null)),
        apiProvider.overrideWithValue(FakeApi((_, _) => null)),
        loginSupportProvider.overrideWith((ref) => support()),
        if (launch != null)
          supportPhoneLauncherProvider.overrideWithValue(launch),
        if (copy != null) supportPhoneClipboardProvider.overrideWithValue(copy),
      ],
      child: MaterialApp(theme: buildTheme(), home: const LoginScreen()),
    ),
  );
}

void main() {
  testWidgets(
    'SUPPORT-UI-003 loading and missing support never block sign in',
    (tester) async {
      final pending = Completer<SupportPhone?>();
      await pumpLogin(tester, support: () => pending.future);
      await tester.pump();

      expect(find.text('Sign in'), findsOneWidget);
      expect(
        find.text('Forgot your password? Contact HR to reset it.'),
        findsOneWidget,
      );

      pending.complete(null);
      await tester.pumpAndSettle();
      expect(
        find.text('Forgot your password? Contact HR to reset it.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('SUPPORT-UI-004 configured contact opens support action modal', (
    tester,
  ) async {
    final opened = <Uri>[];
    await pumpLogin(
      tester,
      support: () async => SupportPhone.parse('+91 98765 43210'),
      launch: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(TextButton, 'Forgot your password? Contact HR'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Contact HR'), findsOneWidget);
    expect(find.text('+91 98765 43210'), findsOneWidget);
    expect(find.text('Call HR'), findsOneWidget);
    expect(find.text('WhatsApp HR'), findsOneWidget);
    expect(find.text('Copy number'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Call HR'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('tel:+919876543210')]);

    await tester.tap(find.widgetWithText(OutlinedButton, 'WhatsApp HR'));
    await tester.pumpAndSettle();
    expect(opened, [
      Uri.parse('tel:+919876543210'),
      Uri.parse('https://wa.me/919876543210'),
    ]);
  });

  testWidgets('SUPPORT-UI-005 modal copies number and reports launch failure', (
    tester,
  ) async {
    String? copied;
    await pumpLogin(
      tester,
      support: () async => SupportPhone.parse('+91 98765 43210'),
      launch: (_) async => false,
      copy: (value) async => copied = value,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(TextButton, 'Forgot your password? Contact HR'),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'Copy number'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Call HR'));
    await tester.pumpAndSettle();
    expect(find.text('Could not open the phone app.'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Copy number'));
    await tester.pumpAndSettle();
    expect(copied, '+91 98765 43210');
    expect(find.text('Number copied.'), findsOneWidget);
  });

  testWidgets('SUPPORT-UI-006 Admin edits and saves the HR support phone', (
    tester,
  ) async {
    final api = await pumpScreen(
      tester,
      const OrganizationScreen(),
      session: testSession(roles: const ['admin'], permissions: const ['*']),
      handler: (fn, params) {
        if (fn == 'get_org_settings') {
          return ApiResult(
            {
              'name': 'Test Org',
              'timezone': 'Asia/Kolkata',
              'active_employee_cap': 40,
              'active_employees': 20,
              'holiday_target': 12,
              'support_contact': '',
              'support_phone': '+91 90000 00000',
              'storage_budget_bytes': 10000000,
              'storage_used_bytes': 0,
              'storage_reserved_bytes': 0,
              'storage_alert_percents': [80, 90],
              'annual_start_month': 1,
              'leave_year_start_month': 1,
              'strict_geofence': false,
              'require_biometric_punch': true,
              'setup_published_at': '2026-10-01T00:00:00Z',
            },
            4,
            'settings',
          );
        }
        if (fn == 'get_maintenance_health') {
          return {
            'stale': false,
            'last_tick': null,
            'outbox_backlog': 0,
            'outbox_failed': 0,
            'pending_uploads': 0,
          };
        }
        if (fn == 'update_org_settings') {
          return ApiResult(
            {
              'name': 'Test Org',
              'timezone': 'Asia/Kolkata',
              'active_employee_cap': 40,
              'active_employees': 20,
              'holiday_target': 12,
              'support_contact': '',
              'support_phone': (params?['p_patch'] as Map)['support_phone'],
              'storage_budget_bytes': 10000000,
              'storage_used_bytes': 0,
              'storage_reserved_bytes': 0,
              'storage_alert_percents': [80, 90],
              'annual_start_month': 1,
              'leave_year_start_month': 1,
              'strict_geofence': false,
              'require_biometric_punch': true,
              'setup_published_at': '2026-10-01T00:00:00Z',
            },
            5,
            'saved',
          );
        }
        return null;
      },
    );

    final phone = find.widgetWithText(TextField, 'HR support phone');
    expect(phone, findsOneWidget);
    expect(tester.widget<TextField>(phone).controller?.text, '+91 90000 00000');
    await tester.enterText(phone, '+91 98765 43210');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save-org-settings'));
    await tester.tap(save);
    await tester.pumpAndSettle();

    final call = api.calls.lastWhere(
      (call) => call.$1 == 'update_org_settings',
    );
    expect((call.$2?['p_patch'] as Map)['support_phone'], '+91 98765 43210');
  });
}
