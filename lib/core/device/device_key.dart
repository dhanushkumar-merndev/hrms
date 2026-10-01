import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../auth/secure_session_storage.dart';

class DeviceKeyException implements Exception {
  const DeviceKeyException(this.code, this.message);
  final String code;
  final String message;

  bool get cancelled => code == 'BIOMETRIC_CANCELLED';
  bool get invalidated => code == 'KEY_INVALIDATED' || code == 'KEY_MISSING';

  @override
  String toString() => 'DeviceKeyException($code: $message)';
}

class DeviceKeyStatus {
  const DeviceKeyStatus({
    required this.sdk,
    required this.model,
    required this.hasKey,
    required this.keyUsable,
    required this.keyBiometricBound,
    required this.biometric,
    required this.strongBox,
  });

  factory DeviceKeyStatus.fromMap(Map<dynamic, dynamic> m) => DeviceKeyStatus(
        sdk: (m['sdk'] as num?)?.toInt() ?? 0,
        model: (m['model'] as String?) ?? 'Android phone',
        hasKey: m['hasKey'] == true,
        keyUsable: m['keyUsable'] == true,
        keyBiometricBound: m['keyBiometricBound'] == true,
        biometric: (m['biometric'] as String?) ?? 'unavailable',
        strongBox: m['strongBox'] == true,
      );

  final int sdk;
  final String model;
  final bool hasKey;
  final bool keyUsable;
  final bool keyBiometricBound;

  /// ready | none_enrolled | no_hardware | update_required | unavailable
  final String biometric;
  final bool strongBox;

  bool get biometricReady => biometric == 'ready';
}

/// Hardware-backed punch signing key (Android Keystore via MainActivity).
class DeviceKey {
  const DeviceKey();
  static const _channel = MethodChannel('hrms/device_key');

  static String aliasFor(String employeeId) => 'hrms_punch_$employeeId';

  Future<T> _call<T>(String method, Map<String, Object?> args) async {
    try {
      return (await _channel.invokeMethod<T>(method, args)) as T;
    } on PlatformException catch (e) {
      throw DeviceKeyException(e.code, e.message ?? 'Device security error.');
    } on MissingPluginException {
      throw const DeviceKeyException('UNSUPPORTED', 'Punching is only supported on Android phones right now.');
    }
  }

  Future<DeviceKeyStatus> status(String alias) async =>
      DeviceKeyStatus.fromMap(await _call<Map<dynamic, dynamic>>('status', {'alias': alias}));

  /// Generates a new attested key; returns the certificate chain (base64).
  Future<List<String>> generate(String alias, Uint8List challenge, {required bool requireBiometric}) async {
    final res = await _call<Map<dynamic, dynamic>>('generateKey', {
      'alias': alias,
      'challenge': challenge,
      'requireBiometric': requireBiometric,
    });
    return (res['chain'] as List).cast<String>();
  }

  /// Signs [payload]; shows the biometric prompt when the key requires it.
  Future<String> sign(String alias, Uint8List payload, {required String title, required String subtitle}) =>
      _call<String>('sign', {'alias': alias, 'payload': payload, 'title': title, 'subtitle': subtitle});

  /// Fingerprint first: unlocks ONE signature for [signAuthorized], so the
  /// location can be read after the person confirms.
  Future<void> authorize(String alias, {required String title, required String subtitle}) =>
      _call<bool>('authorize', {'alias': alias, 'title': title, 'subtitle': subtitle});

  Future<String> signAuthorized(Uint8List payload) => _call<String>('signAuthorized', {'payload': payload});

  Future<void> clearAuthorized() async {
    try {
      await _call<bool>('clearAuthorized', const {});
    } on DeviceKeyException {
      // Nothing pending.
    }
  }

  Future<void> delete(String alias) => _call<bool>('deleteKey', {'alias': alias});
}

/// Random per-installation id (not a hardware identifier; no IMEI).
class Installation {
  Installation._();
  static const _key = 'hrms.installation_id';
  static String? _cached;

  static Future<String> id() async {
    if (_cached != null) return _cached!;
    var v = await SecureSessionStorage.storage.read(key: _key);
    if (v == null) {
      v = const Uuid().v4();
      await SecureSessionStorage.storage.write(key: _key, value: v);
    }
    return _cached = v;
  }
}
