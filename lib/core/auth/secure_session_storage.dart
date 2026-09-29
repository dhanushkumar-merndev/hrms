import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Persists the Supabase session in the platform keystore (Android
/// Keystore-backed encrypted storage / iOS Keychain) instead of plain
/// shared preferences. Excluded from cloud backups by the platform plugin.
class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage();

  static const _key = 'hrms.supabase.session';
  static const storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async => (await storage.read(key: _key)) != null;

  @override
  Future<String?> accessToken() => storage.read(key: _key);

  @override
  Future<void> removePersistedSession() => storage.delete(key: _key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      storage.write(key: _key, value: persistSessionString);
}
