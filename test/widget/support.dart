import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/app/theme.dart';
import 'package:hrms/core/api/api_client.dart';
import 'package:hrms/core/api/api_exception.dart';
import 'package:hrms/core/auth/session_controller.dart';
import 'package:hrms/core/time/org_time.dart';
import 'package:hrms/core/widgets/states.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef Handler = Object? Function(String fn, Map<String, dynamic>? params);

/// In-memory API: every call is recorded; the handler returns the `data`
/// payload (or an ApiException to throw). No network, no Supabase session.
class FakeApi extends ApiClient {
  FakeApi(this.handler)
      : super(SupabaseClient('http://localhost:54321', 'sb_publishable_test',
            authOptions: const AuthClientOptions(autoRefreshToken: false)));
  final Handler handler;
  final calls = <(String, Map<String, dynamic>?)>[];

  Iterable<String> get names => calls.map((c) => c.$1);

  @override
  Future<ApiResult> rpc(String fn, [Map<String, dynamic>? params]) async {
    calls.add((fn, params));
    final res = handler(fn, params);
    if (res is ApiException) throw res;
    if (res is ApiResult) return res;
    return ApiResult(res, 1, 'test-request');
  }

  @override
  Future<ApiResult> function(String name, Map<String, dynamic> body, {bool authenticated = true}) =>
      rpc('fn:$name', body);
}

SessionContext testSession({
  String id = 'e1',
  String name = 'Asha Rao',
  List<String> roles = const [],
  List<String> permissions = const [],
}) =>
    SessionContext(
      employeeId: id,
      code: 'EMP001',
      name: name,
      designation: null,
      orgName: 'Test Org',
      orgCode: 'MAIN',
      timezone: 'Asia/Kolkata',
      supportContact: null,
      roles: roles,
      permissions: permissions,
      mustChangePassword: false,
      credentialHold: false,
    );

const hrPermissions = [
  'hr.directory', 'hr.employees.view', 'hr.employees.provision', 'hr.master_data', 'policy.draft', 'reports.org',
  'audit.scoped', 'announcements.publish', 'approvals.review',
];

class FakeSession extends SessionController {
  FakeSession(this.initial);
  final SessionContext? initial;
  int refreshes = 0;

  @override
  SessionState build() =>
      initial == null ? const SessionState(SessionPhase.signedOut) : SessionState(SessionPhase.ready, context: initial);

  @override
  Future<void> refreshContext() async => refreshes++;

  void switchTo(SessionContext? next) =>
      state = next == null ? const SessionState(SessionPhase.signedOut) : SessionState(SessionPhase.ready, context: next);
}

Future<FakeApi> pumpScreen(WidgetTester tester, Widget screen,
    {required SessionContext session, required Handler handler}) async {
  OrgTime.init('Asia/Kolkata');
  final api = FakeApi(handler);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(() => FakeSession(session)),
      onlineProvider.overrideWith((ref) => Stream.value(true)),
    ],
    child: MaterialApp(theme: buildTheme(), home: screen),
  ));
  await tester.pumpAndSettle();
  return api;
}

/// Disposes the tree so periodic permission refresh timers are cancelled.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}
