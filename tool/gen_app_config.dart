// Generates build/app_config.json for `flutter run/build
// --dart-define-from-file=build/app_config.json` from the public subset of
// .env. Server secrets never enter this file: only the allowlisted keys below
// are copied, and a privileged Supabase key aborts the build.
//
// Usage: dart run tool/gen_app_config.dart [--env .env] [--out build/app_config.json]
import 'dart:convert';
import 'dart:io';

import 'src/env.dart';

void main(List<String> args) {
  String argOr(String name, String fallback) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final env = readEnvFile(argOr('--env', '.env'));
  final outPath = argOr('--out', 'build/app_config.json');

  final environment = env['HRMS_ENVIRONMENT'] ?? 'staging';
  if (!const {'local', 'staging', 'production'}.contains(environment)) {
    stderr.writeln('HRMS_ENVIRONMENT must be local, staging or production.');
    exit(2);
  }

  final anonKey = requireEnv(env, 'APP_SUPABASE_ANON_KEY');
  if (isPrivilegedSupabaseKey(anonKey)) {
    stderr.writeln(
      'REFUSED: APP_SUPABASE_ANON_KEY is a secret/service_role key. Use the '
      'publishable (sb_publishable_...) or anon key instead.',
    );
    exit(3);
  }

  final url = requireEnv(env, 'APP_SUPABASE_URL');
  if (!url.startsWith('https://') && environment != 'local') {
    stderr.writeln('APP_SUPABASE_URL must use https.');
    exit(2);
  }

  final config = <String, String>{
    'APP_ENV': environment,
    'APP_SUPABASE_URL': url,
    'APP_SUPABASE_ANON_KEY': anonKey,
    'APP_ORG_CODE': env['HRMS_ORG_CODE'] ?? 'MAIN',
    'APP_FIREBASE_PROJECT_ID': env['APP_FIREBASE_PROJECT_ID'] ?? '',
    'APP_FIREBASE_MESSAGING_SENDER_ID':
        env['APP_FIREBASE_MESSAGING_SENDER_ID'] ?? '',
    'APP_FIREBASE_ANDROID_API_KEY': env['APP_FIREBASE_ANDROID_API_KEY'] ?? '',
    'APP_FIREBASE_ANDROID_APP_ID': env['APP_FIREBASE_ANDROID_APP_ID'] ?? '',
  };

  final out = File(outPath);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config));
  stdout.writeln(
    'Wrote $outPath (${config.length} public keys, environment=$environment, '
    'push=${config['APP_FIREBASE_ANDROID_APP_ID']!.isEmpty ? 'off' : 'on'}).',
  );
}
