// Dummy data for the QATEST company only (never MAIN), with timings.
//   dart run tool/seed_qatest.dart
// 1. Runs tool/seed_qatest.sql (staff, a year of attendance, leave, salary).
// 2. Uploads one real PDF payslip per person per month (last 12 months) to
//    Storage and publishes it with the paid amount, timing every upload.
// 3. Times the main read paths the app uses against the seeded volume.
// Idempotent: existing payslips are skipped. Never prints secrets.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'src/env.dart';

late final String _ref;
late final String _token;
late final String _url;
late final String _serviceKey;
final _http = HttpClient();

Future<List<dynamic>> sql(String query) async {
  final req = await _http.postUrl(Uri.parse('https://api.supabase.com/v1/projects/$_ref/database/query'));
  req.headers.set('Authorization', 'Bearer $_token');
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode({'query': query}));
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  final decoded = jsonDecode(body);
  if (res.statusCode >= 300 || decoded is! List) throw StateError('SQL failed (${res.statusCode}): $body');
  return decoded;
}

Future<void> upload(String key, List<int> bytes) async {
  final req = await _http.postUrl(Uri.parse('$_url/storage/v1/object/hrms-files/$key'));
  req.headers.set('Authorization', 'Bearer $_serviceKey');
  req.headers.set('apikey', _serviceKey);
  req.headers.contentType = ContentType('application', 'pdf');
  req.add(bytes);
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  if (res.statusCode >= 300) throw StateError('Upload failed (${res.statusCode}): $body');
}

/// A small, valid one-page PDF payslip.
List<int> payslipPdf(String name, String code, String month, int gross, int net) {
  String esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');
  final lines = [
    'Internal HRMS - QATEST (dummy data)',
    'Payslip for $month',
    'Employee: ${esc(name)} ($code)',
    'Gross pay: INR $gross',
    'Deductions: INR ${gross - net}',
    'Net pay: INR $net',
  ];
  final text = StringBuffer('BT /F1 14 Tf 60 780 Td 20 TL\n');
  for (final l in lines) {
    text.write('(${esc(l)}) Tj T*\n');
  }
  text.write('ET');
  final stream = text.toString();
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return latin1.encode(out.toString());
}

String q(String s) => "'${s.replaceAll("'", "''")}'";

Future<void> main() async {
  final env = readEnvFile();
  _ref = requireEnv(env, 'SUPABASE_PROJECT_REF');
  _token = requireEnv(env, 'SUPABASE_ACCESS_TOKEN');
  _url = (env['SUPABASE_URL'] ?? '').isNotEmpty ? env['SUPABASE_URL']! : 'https://$_ref.supabase.co';
  _serviceKey = requireEnv(env, 'SUPABASE_SERVICE_ROLE_KEY');

  var sw = Stopwatch()..start();
  final seeded = await sql(File('tool/seed_qatest.sql').readAsStringSync());
  stdout.writeln('1. Staff, attendance, leave, salary: ${sw.elapsedMilliseconds} ms  ${seeded.first}');

  // Missing payslips for the last 12 full months.
  final todo = await sql('''
    select o.id::text as org, e.id::text as emp, e.employee_code as code, e.full_name as name,
           m::date::text as month, to_char(m, 'Mon YYYY') as label,
           coalesce(sp.monthly_salary, 25000)::int as gross,
           (select id::text from hrms.employees a where a.org_id = o.id and a.employee_code = 'QADMIN01') as admin
    from hrms.organizations o
    join hrms.employees e on e.org_id = o.id and e.status = 'active'
    left join hrms.salary_profiles sp on sp.employee_id = e.id
    cross join generate_series(date_trunc('month', current_date) - interval '12 months',
                               date_trunc('month', current_date) - interval '1 month', interval '1 month') m
    where o.code = 'QATEST'
      and not exists (select 1 from hrms.payslips p where p.employee_id = e.id and p.salary_month = m::date)
    order by e.employee_code, m''');
  stdout.writeln('2. Payslips to upload: ${todo.length}');
  if (todo.isNotEmpty) {
    final rows = <String>[];
    final times = <int>[];
    var totalBytes = 0;
    sw = Stopwatch()..start();
    // 6 uploads at a time, like several HR uploads in parallel.
    for (var i = 0; i < todo.length; i += 6) {
      await Future.wait(todo.skip(i).take(6).map((r) async {
        final m = r as Map<String, dynamic>;
        final gross = m['gross'] as int;
        final net = gross - (gross * 0.12).round() - 200;
        final bytes = payslipPdf(m['name'] as String, m['code'] as String, m['label'] as String, gross, net);
        final key = '${m['org']}/seed-${m['emp']}-${m['month']}.pdf';
        final t = Stopwatch()..start();
        await upload(key, bytes);
        times.add(t.elapsedMilliseconds);
        totalBytes += bytes.length;
        rows.add('(${q(m['org'] as String)}::uuid, ${q(m['emp'] as String)}::uuid, ${q(m['month'] as String)}::date, '
            '${q(key)}, ${bytes.length}, ${q(sha256.convert(bytes).toString())}, $net, ${q(m['admin'] as String)}::uuid, '
            '${q('${m['code']}-${m['month']}.pdf')})');
      }));
      stdout.write('\r   uploaded ${rows.length}/${todo.length}');
    }
    final uploadMs = sw.elapsedMilliseconds;
    times.sort();
    stdout.writeln('\n   upload total $uploadMs ms, per file avg ${times.reduce((a, b) => a + b) ~/ times.length} ms, '
        'p95 ${times[(times.length * 0.95).floor().clamp(0, times.length - 1)]} ms, ${totalBytes ~/ 1024} KB');

    sw = Stopwatch()..start();
    await sql('''
      with src(org, emp, month, key, size, sha, net, admin, fname) as (values ${rows.join(',\n')}),
      recs as (
        insert into hrms.file_records (org_id, owner_employee_id, class, period_start, period_end, title, created_by)
        select org, emp, 'payslip', month, (month + interval '1 month - 1 day')::date,
               to_char(month, 'Mon YYYY') || ' payslip', admin from src
        returning id, owner_employee_id, period_start
      ),
      vers as (
        insert into hrms.file_versions (org_id, file_record_id, version_no, state, object_key, original_filename,
                                        declared_mime, detected_mime, declared_size_bytes, size_bytes, sha256,
                                        uploaded_by, validated_at, published_at, published_by)
        select s.org, r.id, 1, 'published', s.key, s.fname, 'application/pdf', 'application/pdf', s.size, s.size, s.sha,
               s.admin, now(), now(), s.admin
        from src s join recs r on r.owner_employee_id = s.emp and r.period_start = s.month
        returning id
      )
      insert into hrms.storage_ledger (org_id, used_bytes)
      select (select org from src limit 1), (select sum(size) from src)
      on conflict (org_id) do update set used_bytes = hrms.storage_ledger.used_bytes + excluded.used_bytes,
                                         updated_at = now()''');
    // Separate statements: a CTE cannot update rows another CTE inserted.
    await sql(File('tool/seed_qatest_link.sql').readAsStringSync());
    stdout.writeln('   published ${rows.length} payslips in ${sw.elapsedMilliseconds} ms');
  }

  // 3. Read-path timings at this volume (server execution time).
  final checks = {
    'My attendance, one month': '''select public.list_my_attendance(date_trunc('month', current_date)::date, current_date)''',
    'Hours report, whole company, 1 year': '''select count(*) from hrms.attendance_rows(
        (select id from hrms.organizations where code = 'QATEST'),
        hrms.active_employee_ids((select id from hrms.organizations where code = 'QATEST')),
        current_date - 365, current_date, now())''',
    'Payslip list, one person': '''select count(*) from hrms.payslips p join hrms.employees e on e.id = p.employee_id
        where e.employee_code = 'QAD001' ''',
  };
  stdout.writeln('3. Server timings (EXPLAIN ANALYZE):');
  for (final c in checks.entries) {
    if (c.key.startsWith('My attendance')) continue; // needs a signed-in user; covered on the phone
    final plan = await sql('explain (analyze, format json) ${c.value}');
    final p = ((plan.first as Map)['QUERY PLAN'] as List).first as Map;
    stdout.writeln('   ${c.key}: ${(p['Execution Time'] as num).toStringAsFixed(1)} ms');
  }
  _http.close();
}
