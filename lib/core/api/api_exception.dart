import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// A normalised server or network error. [code] is one of the API error codes
/// in architecture.md §9 (or NETWORK / INTERNAL).
class ApiException implements Exception {
  const ApiException(
    this.code,
    this.message, {
    this.fieldErrors = const {},
    this.retryable = false,
    this.requestId,
    this.status,
  });

  final String code;
  final String message;
  final Map<String, String> fieldErrors;
  final bool retryable;
  final String? requestId;
  final int? status;

  bool get isNetwork => code == 'NETWORK';
  bool get isAuth => const {'AUTH_REQUIRED', 'ACCOUNT_INACTIVE', 'PASSWORD_CHANGE_REQUIRED'}.contains(code);
  bool get isAccessDenied => code == 'ACCESS_DENIED';

  static const network = ApiException(
    'NETWORK',
    'You appear to be offline. Check your connection and try again.',
    retryable: true,
  );

  /// Parses the `{error:{code,message,field_errors,retryable},request_id}`
  /// envelope returned by Edge Functions.
  factory ApiException.fromEnvelope(Object? body, int status) {
    if (body is Map && body['error'] is Map) {
      final e = (body['error'] as Map).cast<String, dynamic>();
      return ApiException(
        (e['code'] as String?) ?? 'INTERNAL',
        (e['message'] as String?) ?? 'Something went wrong.',
        fieldErrors: _fields(e['field_errors']),
        retryable: e['retryable'] == true,
        requestId: body['request_id'] as String?,
        status: status,
      );
    }
    return ApiException('INTERNAL', 'Something went wrong. Please try again.', retryable: true, status: status);
  }

  /// Maps PostgREST errors from HRMS RPCs: message = code, details = JSON.
  factory ApiException.fromPostgrest(PostgrestException e) {
    final code = e.message;
    if (e.code == 'P0001' && RegExp(r'^[A-Z_]+$').hasMatch(code)) {
      Map<String, dynamic> detail = const {};
      try {
        detail = (jsonDecode(e.details?.toString() ?? '{}') as Map).cast<String, dynamic>();
      } catch (_) {}
      return ApiException(
        code,
        (detail['message'] as String?) ?? _defaultMessages[code] ?? code,
        fieldErrors: _fields(detail['field_errors']),
        retryable: detail['retryable'] == true || e.hint == 'retryable',
        requestId: detail['request_id'] as String?,
      );
    }
    if (e.code == '42501' || e.code == 'PGRST301' || e.code == '401') {
      return const ApiException('AUTH_REQUIRED', 'Please sign in again.');
    }
    return const ApiException('INTERNAL', 'Something went wrong. Please try again.', retryable: true);
  }

  static Map<String, String> _fields(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries)
        if (e.value != null) e.key.toString(): e.value.toString(),
    };
  }

  static const _defaultMessages = {
    'AUTH_REQUIRED': 'Please sign in again.',
    'ACCESS_DENIED': 'You do not have access to this.',
    'ACCOUNT_INACTIVE': 'This account is not active. Contact HR.',
    'PASSWORD_CHANGE_REQUIRED': 'Please set a new password to continue.',
    'STALE_VERSION': 'This changed since you opened it. Reload and try again.',
    'REQUEST_LOCKED': 'Your approver has opened this request. Contact them for changes.',
    'SELF_APPROVAL_FORBIDDEN': 'You cannot decide your own request.',
    'INSUFFICIENT_BALANCE': 'Not enough leave balance.',
    'OVERLAPPING_LEAVE': 'You already have leave on one of these days.',
    'RATE_LIMITED': 'Too many attempts. Please wait and try again.',
    'REAUTH_REQUIRED': 'Confirm your password to continue.',
  };

  @override
  String toString() => 'ApiException($code: $message)';
}
