import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/features/archive/archive_builder.dart';

Map<String, dynamic> _sample() => {
      'id': '5f0c7a1e-2b1d-4c3e-9a8b-0d1e2f3a4b5c',
      'period_start': '2025-04-01',
      'period_end': '2026-03-31',
      'revision': 2,
      'items': [
        {'path': 'Employees/EMP02_Zed/Payslips/2025/2025-04.pdf', 'size_bytes': 1200, 'sha256': 'aa',
          'file_version_id': '0000000a-0000-0000-0000-000000000001', 'source': 'cloud'},
        {'path': 'Employees/EMP01_A b/Payslips/2025/Revisions/2025-04_v1.pdf', 'size_bytes': 5000000, 'sha256': 'bb',
          'file_version_id': '0000000b-0000-0000-0000-000000000002', 'source': 'local_base'},
        {'path': 'Employees/EMP01_A b/Payslips/2025/2025-04.pdf', 'size_bytes': 1, 'sha256': 'cc',
          'file_version_id': '0000000c-0000-0000-0000-000000000003', 'source': 'cloud'},
        {'path': 'Employees/EMP01_A b/Documents/2025/abc123_v1_Offer (1).pdf', 'size_bytes': 77, 'sha256': 'dd',
          'file_version_id': '0000000d-0000-0000-0000-000000000004', 'source': 'cloud'},
      ],
      'employees': [
        {'employee_id': 'f0000000-0000-0000-0000-000000000001', 'attendance_count': 365, 'leave_count': 3},
        {'employee_id': 'a0000000-0000-0000-0000-000000000002', 'attendance_count': 12, 'leave_count': 0},
      ],
    };

void main() {
  test('canonical manifest hash equals the server (PostgreSQL) implementation', () {
    // Computed with the exact SQL canonicalisation used by create_archive_export
    // on this same sample (see supabase/tests/database/06_archive.sql).
    expect(canonicalManifestHash(_sample()), '88443987fe74b042ec67f7de28abffb76cd20b015e8526cac1396acb9bed1484');
  });

  test('canonical form sorts files by path and employees by id', () {
    final lines = canonicalManifest(_sample()).split('\n');
    expect(lines.take(4), [
      'hrms-archive-v1',
      'job:5f0c7a1e-2b1d-4c3e-9a8b-0d1e2f3a4b5c',
      'period:2025-04-01..2026-03-31',
      'revision:2',
    ]);
    expect(lines[4], startsWith('file:Employees/EMP01_A b/Documents/'));
    expect(lines[5], startsWith('file:Employees/EMP01_A b/Payslips/2025/2025-04.pdf|1|cc|'));
    expect(lines[6], startsWith('file:Employees/EMP01_A b/Payslips/2025/Revisions/'));
    expect(lines[8], startsWith('employee:a0000000'));
    expect(lines.length, 10);
  });

  test('an empty inventory adds no file or employee lines', () {
    final m = {..._sample(), 'items': const [], 'employees': const []};
    expect(canonicalManifest(m).split('\n').length, 4);
  });

  test('EXP-008 unsafe ZIP paths are refused', () {
    for (final bad in [
      '../etc/passwd', '/abs/file.pdf', 'Employees/../../x.pdf', r'Employees\x.pdf', 'C:/x.pdf',
      'Employees/CON/x.pdf', 'Employees/nul.pdf', 'Employees/a./x.pdf', 'Employees/ a /x.pdf', 'a//b.pdf',
      'Employees/x\u0001.pdf', '',
    ]) {
      expect(isSafeZipPath(bad), isFalse, reason: bad);
    }
    for (final good in [
      'Summary.xlsx', 'manifest.json', 'Employees/EMP001_Asha Rao/Payslips/2026/2026-09.pdf',
      'Employees/EMP001_A_B/Documents/2026/0a1b2c3d4e5f_v2_Offer letter (signed).pdf', 'Employees/CONRAD_Lee/Leave.xlsx',
    ]) {
      expect(isSafeZipPath(good), isTrue, reason: good);
    }
  });

  group('extractOriginals (EXP-016/017, DEL-010)', () {
    late Directory tmp;
    final pdf = utf8.encode('%PDF-1.4 test payslip bytes %%EOF');
    final sha = sha256.convert(pdf).toString();

    setUp(() => tmp = Directory.systemTemp.createTempSync('hrms_archive_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String zipWith(Map<String, List<int>> files) {
      final a = Archive();
      files.forEach((name, bytes) => a.addFile(ArchiveFile.bytes(name, bytes)));
      final path = '${tmp.path}/in.zip';
      File(path).writeAsBytesSync(ZipEncoder().encodeBytes(a));
      return path;
    }

    List<int> manifestFor(String jobId, String hash, String path) => utf8.encode(jsonEncode({
          'job': {'id': jobId, 'manifest_hash': hash},
          'items': [
            {'file_version_id': 'v1', 'path': path, 'included': true},
          ],
        }));

    test('matching original is extracted and marked verified', () {
      final zip = zipWith({'manifest.json': manifestFor('job1', 'h1', 'Employees/E_A/Payslips/2025/2025-04.pdf'),
        'Employees/E_A/Payslips/2025/2025-04.pdf': pdf});
      final out = Directory('${tmp.path}/out')..createSync();
      final res = extractOriginals(zip, 'job1', 'h1', [<Object>['v1', sha, pdf.length]], out.path);
      expect(res['error'], isNull);
      expect(res['missing'], isEmpty);
      expect(File('${out.path}/v1').readAsBytesSync(), pdf);
      expect(File('${out.path}/v1.ok').readAsStringSync(), sha);
    });

    test('a different archive (wrong job or manifest hash) is refused', () {
      final zip = zipWith({'manifest.json': manifestFor('other', 'h1', 'a.pdf'), 'a.pdf': pdf});
      final res = extractOriginals(zip, 'job1', 'h1', [<Object>['v1', sha, pdf.length]], tmp.path);
      expect(res['error'], contains('different archive'));
    });

    test('changed bytes are reported missing, never accepted', () {
      final tampered = [...pdf]..[3] = 0x41;
      final zip = zipWith({'manifest.json': manifestFor('job1', 'h1', 'a.pdf'), 'a.pdf': tampered});
      final res = extractOriginals(zip, 'job1', 'h1', [<Object>['v1', sha, pdf.length]], tmp.path);
      expect(res['missing'], ['v1']);
      expect(File('${tmp.path}/v1').existsSync(), isFalse);
    });

    test('traversal entry names make the whole archive unusable', () {
      final zip = zipWith({'manifest.json': manifestFor('job1', 'h1', 'a.pdf'), '../evil.pdf': pdf, 'a.pdf': pdf});
      final res = extractOriginals(zip, 'job1', 'h1', [<Object>['v1', sha, pdf.length]], tmp.path);
      expect(res['error'], contains('unsafe'));
    });

    test('not a ZIP or no manifest gives a clear error', () {
      final junk = '${tmp.path}/junk.zip';
      File(junk).writeAsStringSync('not a zip');
      expect(extractOriginals(junk, null, null, const [], tmp.path)['error'], isNotNull);
      final noManifest = zipWith({'a.pdf': pdf});
      expect(extractOriginals(noManifest, null, null, const [], tmp.path)['error'], contains('manifest.json'));
    });

    test('restore mode accepts any archive that contains the exact bytes', () {
      final zip = zipWith({'manifest.json': manifestFor('any', 'x', 'a.pdf'), 'a.pdf': pdf});
      final res = extractOriginals(zip, null, null, [<Object>['v1', sha, pdf.length]], tmp.path);
      expect(res['missing'], isEmpty);
    });
  });
}
