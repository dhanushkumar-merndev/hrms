import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../app/config.dart';
import '../api/api_client.dart';
import '../auth/secure_session_storage.dart';
import '../device/device_key.dart';

/// Optional Firebase push (Android). The in-app inbox is authoritative;
/// push is best effort and may duplicate, so taps only open the inbox or a
/// safe in-app route. Nothing here runs unless the build carries Firebase
/// config (tool/gen_app_config.dart).
class PushService {
  PushService._();

  static const _enabledKey = 'hrms.push_enabled';
  static bool _ready = false;
  static StreamSubscription<String>? _refresh;

  static bool get available => AppConfig.pushConfigured && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> init() async {
    if (!available || _ready) return;
    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: AppConfig.firebaseAndroidApiKey,
          appId: AppConfig.firebaseAndroidAppId,
          messagingSenderId: AppConfig.firebaseSenderId,
          projectId: AppConfig.firebaseProjectId,
        ),
      );
      _ready = true;
    } catch (_) {
      _ready = false; // push stays off; the inbox still works
    }
  }

  static Future<bool> isEnabled() async =>
      _ready && await SecureSessionStorage.storage.read(key: _enabledKey) == 'on';

  /// Asks for notification permission and binds this installation's token to
  /// the signed-in employee. Returns false if refused or unavailable.
  static Future<bool> enable(ApiClient api) async {
    if (!_ready) return false;
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return false;
    final token = await messaging.getToken();
    if (token == null) return false;
    final installation = await Installation.id();
    await api.rpc('register_push_token', {'p_installation_id': installation, 'p_token': token, 'p_platform': 'android'});
    await SecureSessionStorage.storage.write(key: _enabledKey, value: 'on');
    await _refresh?.cancel();
    _refresh = messaging.onTokenRefresh.listen((t) {
      api.rpc('register_push_token', {'p_installation_id': installation, 'p_token': t, 'p_platform': 'android'}).ignore();
    });
    return true;
  }

  static const _askedKey = 'hrms.push_asked';

  /// Re-binds on sign-in when the user had push turned on for this phone.
  /// The first time on a phone it asks once (Android permission prompt), so
  /// approvals and reminders arrive without hunting for the Settings switch.
  static Future<void> restore(ApiClient api) async {
    try {
      if (await isEnabled()) {
        await enable(api);
      } else if (_ready && await SecureSessionStorage.storage.read(key: _askedKey) == null) {
        await SecureSessionStorage.storage.write(key: _askedKey, value: 'yes');
        await enable(api);
      }
    } catch (_) {}
  }

  static Future<void> disable(ApiClient api) async {
    await unregister(api);
    await SecureSessionStorage.storage.delete(key: _enabledKey);
  }

  /// Best effort: server unbinding plus deleting the local token, so a
  /// reused phone never receives the previous employee's notifications.
  static Future<void> unregister(ApiClient api) async {
    await _refresh?.cancel();
    _refresh = null;
    if (!_ready) return;
    try {
      await api.rpc('unregister_push_token', {'p_installation_id': await Installation.id()});
    } catch (_) {}
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  /// Taps on a system notification: the app opens the given in-app route
  /// (only relative app paths are accepted).
  static void onOpen(void Function(String route) open) {
    if (!_ready) return;
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      final link = m.data['deep_link'] as String?;
      open(link != null && link.startsWith('/') && !link.startsWith('//') ? link : '/notifications');
    });
  }

  static void onForeground(void Function() refresh) {
    if (!_ready) return;
    FirebaseMessaging.onMessage.listen((_) => refresh());
  }
}
