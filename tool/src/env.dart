import 'dart:convert';
import 'dart:io';

/// Minimal `.env` reader for the repository tools. Values are never printed.
Map<String, String> readEnvFile([String path = '.env']) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('$path not found. Copy .env.example to .env and fill it.');
  }
  final values = <String, String>{};
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    var value = line.substring(eq + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).replaceAll(r'\"', '"');
    }
    values[key] = value;
  }
  return values;
}

String requireEnv(Map<String, String> env, String key) {
  final value = env[key] ?? '';
  if (value.isEmpty) throw StateError('$key is empty in .env');
  return value;
}

/// True when [key] is a Supabase key that bypasses Row Level Security and so
/// must never be compiled into the mobile app.
bool isPrivilegedSupabaseKey(String key) {
  if (key.startsWith('sb_secret_')) return true;
  final parts = key.split('.');
  if (parts.length == 3) {
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return payload is Map && payload['role'] == 'service_role';
    } catch (_) {
      return false;
    }
  }
  return false;
}
