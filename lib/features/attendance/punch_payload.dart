import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Canonical punch payload v1 — must match the server byte for byte
/// (supabase/functions/_shared/punch.ts and hrms.punch_payload_v1):
/// UTF-8, lines joined by "\n", no trailing newline, UUIDs lowercase,
/// latitude/longitude with exactly 7 decimals, accuracy with 2, sample
/// time as epoch milliseconds. The device key signs exactly these bytes.
class PunchPayload {
  const PunchPayload({
    required this.challengeId,
    required this.nonce,
    required this.operationKey,
    required this.employeeId,
    required this.deviceId,
    required this.action,
    required this.targetId,
    required this.officeId,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.sampleAtMs,
  });

  final String challengeId;
  final String nonce;
  final String operationKey;
  final String employeeId;
  final String deviceId;
  final String action;
  final String targetId;
  final String officeId;
  final String latitude;
  final String longitude;
  final String accuracy;
  final String sampleAtMs;

  static String lat(double v) => v.toStringAsFixed(7);
  static String lng(double v) => v.toStringAsFixed(7);
  static String acc(double v) => v.toStringAsFixed(2);

  String get canonical => [
        'hrms-punch-v1',
        challengeId.toLowerCase(),
        nonce,
        operationKey.toLowerCase(),
        employeeId.toLowerCase(),
        deviceId.toLowerCase(),
        action,
        targetId.toLowerCase(),
        officeId.toLowerCase(),
        latitude,
        longitude,
        accuracy,
        sampleAtMs,
      ].join('\n');

  List<int> get bytes => utf8.encode(canonical);

  String get sha256Hex => sha256.convert(bytes).toString();

  Map<String, Object> toRequest(String signature, {required bool isMocked}) => {
        'operation_key': operationKey,
        'challenge_id': challengeId,
        'nonce': nonce,
        'action': action,
        'target_id': targetId,
        'device_id': deviceId,
        'office_id': officeId,
        'employee_id': employeeId,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'sample_at_ms': sampleAtMs,
        'is_mocked': isMocked,
        'signature': signature,
      };
}
