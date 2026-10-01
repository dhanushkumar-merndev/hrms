import 'package:flutter/services.dart';

import 'device_key.dart';

/// "Is this the phone's owner?" (fingerprint/face, screen lock as fallback)
/// before private data is shown, plus screenshot blocking for such screens.
/// Uses the same native channel as the punch key.
class LocalAuth {
  const LocalAuth();
  static const _channel = MethodChannel('hrms/device_key');

  /// True when confirmed; false when the person cancelled. Throws
  /// [DeviceKeyException] when the phone has no lock set up.
  Future<bool> confirm({String title = "Confirm it's you", String subtitle = ''}) async {
    try {
      return await _channel.invokeMethod<bool>('confirmUser', {'title': title, 'subtitle': subtitle}) ?? false;
    } on PlatformException catch (e) {
      if (e.code == 'BIOMETRIC_CANCELLED') return false;
      throw DeviceKeyException(e.code, e.message ?? 'Could not confirm it is you.');
    } on MissingPluginException {
      throw const DeviceKeyException('UNSUPPORTED', 'This needs the Android app.');
    }
  }

  /// Blocks screenshots and the recent-apps preview while [on].
  Future<void> secureScreen(bool on) async {
    try {
      await _channel.invokeMethod<bool>('setSecure', {'on': on});
    } on MissingPluginException {
      // Not on Android (tests): nothing to protect.
    } on PlatformException {
      // Best effort.
    }
  }
}
