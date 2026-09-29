// Creates the organisation and FIRST Admin (operator step, run once).
//
//   dart run tool/bootstrap_admin.dart
//
// Reads HRMS_ORG_* / HRMS_BOOTSTRAP_ADMIN_* from .env, creates the Admin's
// login with a random temporary password and prints that password ONCE.
// The Admin must change it at first sign-in. Safe to re-run: an existing,
// linked Admin is reported instead of recreated. Uses the Management API
// (database owner) and the Auth admin API; prints no keys.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'src/env.dart';

late Map<String, String> env;

Future<List<dynamic>> sql(String query) async {
  final ref = requireEnv(env, 'SUPABASE_PROJECT_REF');
  final res = await http.post(
    Uri.parse('https://api.supabase.com/v1/projects/$ref/database/query'),
    headers: {
      'Authorization': 'Bearer ${requireEnv(env, 'SUPABASE_ACCESS_TOKEN')}',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({'query': query}),
  );
  if (res.statusCode >= 300) {
    throw StateError('Database call failed (${res.statusCode}): ${res.body}');
  }
  return jsonDecode(res.body) as List<dynamic>;
}

String lit(String v) => "'${v.replaceAll("'", "''")}'";

Map<String, String> authHeaders() {
  final key = requireEnv(env, 'SUPABASE_SERVICE_ROLE_KEY');
  return {
    'apikey': key,
    if (!key.startsWith('sb_')) 'Authorization': 'Bearer $key',
    'Content-Type': 'application/json',
  };
}

String temporaryPassword() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  final rnd = Random.secure();
  final body = List.generate(13, (_) => alphabet[rnd.nextInt(alphabet.length)]).join();
  return '${body}K7m';
}

Future<void> main() async {
  env = readEnvFile();
  final url = requireEnv(env, 'APP_SUPABASE_URL');
  final orgCode = env['HRMS_ORG_CODE'] ?? 'MAIN';
  final adminCode = requireEnv(env, 'HRMS_BOOTSTRAP_ADMIN_CODE');

  final rows = await sql('select hrms.bootstrap_org_admin(${lit(orgCode)}, '
      '${lit(env['HRMS_ORG_NAME'] ?? 'Internal HRMS')}, ${lit(env['HRMS_ORG_TIMEZONE'] ?? 'Asia/Kolkata')}, '
      '${lit(adminCode)}, ${lit(env['HRMS_BOOTSTRAP_ADMIN_NAME'] ?? 'Administrator')}, '
      '${lit(env['HRMS_AUTH_ALIAS_DOMAIN'] ?? 'staff.hrms.invalid')}) as r');
  final result = (rows.first as Map<String, dynamic>)['r'] as Map<String, dynamic>;
  if (result['linked'] == true) {
    stdout.writeln('Admin ${adminCode.toUpperCase()} already exists and is linked. Nothing to do.');
    stdout.writeln('Lost the password? Ask another Admin to reset it from the app.');
    return;
  }

  final alias = result['auth_alias'] as String;
  final password = temporaryPassword();
  var res = await http.post(Uri.parse('$url/auth/v1/admin/users'), headers: authHeaders(),
      body: jsonEncode({'email': alias, 'password': password, 'email_confirm': true}));
  String userId;
  if (res.statusCode < 300) {
    userId = (jsonDecode(res.body) as Map<String, dynamic>)['id'] as String;
  } else {
    // Interrupted earlier run: find the identity by alias and reset it.
    final list = await http.get(Uri.parse('$url/auth/v1/admin/users?page=1&per_page=1000'), headers: authHeaders());
    final users = ((jsonDecode(list.body) as Map<String, dynamic>)['users'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final existing = users.where((u) => (u['email'] as String?)?.toLowerCase() == alias.toLowerCase());
    if (existing.isEmpty) {
      stderr.writeln('Could not create the Admin login (Auth said ${res.statusCode}).');
      exit(1);
    }
    userId = existing.first['id'] as String;
    res = await http.put(Uri.parse('$url/auth/v1/admin/users/$userId'), headers: authHeaders(),
        body: jsonEncode({'password': password}));
    if (res.statusCode >= 300) {
      stderr.writeln('Could not set the Admin password (Auth said ${res.statusCode}).');
      exit(1);
    }
  }
  await sql("select hrms.bootstrap_link(${lit(result['employee_id'] as String)}, ${lit(userId)})");

  stdout.writeln('');
  stdout.writeln('First Admin created.');
  stdout.writeln('  Employee ID:        ${adminCode.toUpperCase()}');
  stdout.writeln('  Temporary password: $password');
  stdout.writeln('This password is shown only now. Sign in on the phone; you will be asked to set a new one.');
}
