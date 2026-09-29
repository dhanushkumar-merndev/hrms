import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/config.dart';
import '../api/api_client.dart';
import '../api/api_exception.dart';
import 'secure_session_storage.dart';

/// Server-owned identity and permissions for the signed-in employee.
class SessionContext {
  const SessionContext({
    required this.employeeId,
    required this.code,
    required this.name,
    required this.designation,
    required this.orgName,
    required this.orgCode,
    required this.timezone,
    required this.supportContact,
    required this.roles,
    required this.permissions,
    required this.mustChangePassword,
    required this.credentialHold,
  });

  factory SessionContext.fromJson(Map<String, dynamic> j) {
    final emp = (j['employee'] as Map).cast<String, dynamic>();
    final org = (j['org'] as Map).cast<String, dynamic>();
    return SessionContext(
      employeeId: emp['id'] as String,
      code: emp['code'] as String,
      name: emp['name'] as String,
      designation: emp['designation'] as String?,
      orgName: org['name'] as String,
      orgCode: org['code'] as String,
      timezone: (org['timezone'] as String?) ?? 'Asia/Kolkata',
      supportContact: org['support_contact'] as String?,
      roles: ((j['roles'] as List?) ?? const []).cast<String>(),
      permissions: ((j['permissions'] as List?) ?? const []).cast<String>(),
      mustChangePassword: j['must_change_password'] == true,
      credentialHold: j['credential_hold'] == true,
    );
  }

  final String employeeId;
  final String code;
  final String name;
  final String? designation;
  final String orgName;
  final String orgCode;
  final String timezone;
  final String? supportContact;
  final List<String> roles;
  final List<String> permissions;
  final bool mustChangePassword;
  final bool credentialHold;

  String get firstName => name.trim().split(RegExp(r'\s+')).first;
  bool has(String p) => permissions.contains('*') || permissions.contains(p);
  bool get isAdmin => roles.contains('admin');
  bool get isHr => roles.contains('hr');
  bool get isManager => roles.contains('manager');
  bool get canReview => isAdmin || has('approvals.review');
  bool get canTeamReports => has('reports.team') || has('reports.org');
  bool get canOrgReports => has('reports.org');
  bool get canViewEmployees => isAdmin || has('hr.employees.view');
  bool get canProvision => isAdmin || has('hr.employees.provision');
  bool get canMasterData => isAdmin || has('hr.master_data');
  bool get canDraftPolicy => isAdmin || has('policy.draft');
  bool get canManagePayroll => isAdmin || has('payroll.manage');
  bool get canAudit => isAdmin || has('audit.scoped');
  bool get canAnnounce => isAdmin || has('announcements.publish');
  bool get hasWorkspace => canTeamReports || canReview || isAdmin || canViewEmployees;
}

enum SessionPhase { loading, signedOut, mustChangePassword, credentialHold, ready, unreachable }

class SessionState {
  const SessionState(this.phase, {this.context, this.message});
  final SessionPhase phase;
  final SessionContext? context;
  final String? message;
}

class SessionController extends Notifier<SessionState> {
  ApiClient get _api => ref.read(apiProvider);
  SupabaseClient get _sb => ref.read(supabaseProvider);
  static const _pendingPasswordOp = 'hrms.pending_password_op';

  @override
  SessionState build() {
    final sub = _sb.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.signedOut && state.phase != SessionPhase.signedOut) {
        state = const SessionState(SessionPhase.signedOut);
      }
    });
    ref.onDispose(sub.cancel);
    scheduleMicrotask(restore);
    return const SessionState(SessionPhase.loading);
  }

  Future<void> restore() async {
    if (_sb.auth.currentSession == null) {
      state = const SessionState(SessionPhase.signedOut);
      return;
    }
    await refreshContext();
  }

  /// Re-reads identity + permissions from the server (authoritative).
  Future<void> refreshContext() async {
    try {
      final res = await _api.rpc('get_session_context');
      final ctx = SessionContext.fromJson(res.map);
      state = SessionState(
        ctx.credentialHold
            ? SessionPhase.credentialHold
            : ctx.mustChangePassword
                ? SessionPhase.mustChangePassword
                : SessionPhase.ready,
        context: ctx,
      );
    } on ApiException catch (e) {
      if (e.isNetwork) {
        state = SessionState(
          state.context == null ? SessionPhase.unreachable : state.phase,
          context: state.context,
          message: e.message,
        );
      } else {
        await _localSignOut(e.code == 'ACCOUNT_INACTIVE'
            ? 'This account is not active. Contact HR.'
            : 'Your session ended. Please sign in again.');
      }
    }
  }

  /// Employee ID + password through the auth-login function (rate limited,
  /// generic errors). The returned session is adopted by the Supabase client.
  Future<void> login(String employeeCode, String password) async {
    final res = await _api.function('auth-login', {
      'org_code': AppConfig.orgCode,
      'employee_code': employeeCode,
      'password': password,
    }, authenticated: false);
    final session = (res.map['session'] as Map).cast<String, dynamic>();
    await _sb.auth.setSession(session['refresh_token'] as String);
    await refreshContext();
  }

  /// Fail-closed password change. A lost response is retried with the same
  /// operation id, which the server reconciles. On success every session is
  /// invalid, so we sign in again with the new password automatically.
  Future<void> changePassword(String current, String next) async {
    final code = state.context?.code;
    var op = await SecureSessionStorage.storage.read(key: _pendingPasswordOp);
    if (op == null) {
      op = ApiClient.newOperationKey();
      await SecureSessionStorage.storage.write(key: _pendingPasswordOp, value: op);
    }
    await _api.function('auth-password', {
      'operation_id': op,
      'current_password': current,
      'new_password': next,
    });
    await SecureSessionStorage.storage.delete(key: _pendingPasswordOp);
    await _sb.auth.signOut(scope: SignOutScope.local).catchError((_) {});
    if (code != null) {
      await login(code, next);
    } else {
      state = const SessionState(SessionPhase.signedOut, message: 'Password changed. Please sign in.');
    }
  }

  Future<void> logout() async {
    await _localSignOut(null, revoke: true);
  }

  Future<void> _localSignOut(String? message, {bool revoke = false}) async {
    try {
      await _sb.auth.signOut(scope: revoke ? SignOutScope.local : SignOutScope.local);
    } catch (_) {
      await SecureSessionStorage().removePersistedSession();
    }
    await clearSensitiveTemp();
    state = SessionState(SessionPhase.signedOut, message: message);
  }

  /// Removes previews/exports cached in the app temp directory (logout,
  /// account switch, startup).
  static Future<void> clearSensitiveTemp() async {
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/hrms');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

/// The signed-in context; throws if used outside a ready session.
final sessionContextProvider = Provider<SessionContext?>((ref) => ref.watch(sessionProvider).context);
