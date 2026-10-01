import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/files/xlsx.dart';
import '../../core/time/org_time.dart';
import '../attendance/attendance_ui.dart';
import '../reports/hours_report_screen.dart' show hhmm;

class ArchiveException implements Exception {
  const ArchiveException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Canonical manifest text; mirrors create_archive_export byte for byte so
/// the app can prove it received the exact server inventory.
String canonicalManifest(Map<String, dynamic> m) {
  final items = [for (final i in (m['items'] as List? ?? const [])) (i as Map).cast<String, dynamic>()]
    ..sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
  final employees = [for (final e in (m['employees'] as List? ?? const [])) (e as Map).cast<String, dynamic>()]
    ..sort((a, b) => (a['employee_id'] as String).compareTo(b['employee_id'] as String));
  return [
    'hrms-archive-v1',
    'job:${m['id']}',
    'period:${m['period_start']}..${m['period_end']}',
    'revision:${m['revision']}',
    for (final i in items) 'file:${i['path']}|${i['size_bytes']}|${i['sha256']}|${i['file_version_id']}|${i['source']}',
    for (final e in employees) 'employee:${e['employee_id']}|${e['attendance_count']}|${e['leave_count']}',
  ].join('\n');
}

String canonicalManifestHash(Map<String, dynamic> m) => sha256.convert(utf8.encode(canonicalManifest(m))).toString();

final _reservedName = RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$', caseSensitive: false);

/// Relative, forward-slash ZIP path with no traversal, drive letters,
/// control characters or reserved device names (EXP-008).
bool isSafeZipPath(String p) {
  if (p.isEmpty || p.length > 400 || p.startsWith('/') || p.contains('\\') || p.contains(':')) return false;
  for (final part in p.split('/')) {
    if (part.isEmpty || part == '.' || part == '..' || part.endsWith('.') || part.endsWith(' ')) return false;
    if (_reservedName.hasMatch(part)) return false;
    if (part.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return false;
  }
  return true;
}

/// Decompression sink that refuses to grow beyond [limit] bytes, so a
/// crafted ZIP entry cannot expand without bound (EXP-017).
class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.limit);
  final int limit;

  void _check(int n) {
    if (length + n > limit) throw const FormatException('entry larger than declared');
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}

Uint8List _readBounded(ArchiveFile f, int limit) {
  final out = _BoundedOutput(limit);
  f.writeContent(out);
  return out.getBytes();
}

/// Extracts verified originals (by file version id + SHA-256) from an
/// earlier archive into [outDir]. With [requireJobId]/[requireHash] the ZIP
/// must be exactly that acknowledged archive. Runs in an isolate.
Map<String, Object?> extractOriginals(
    String zipPath, String? requireJobId, String? requireHash, List<List<Object>> needed, String outDir) {
  final input = InputFileStream(zipPath);
  try {
    final decoder = ZipDecoder();
    final archive = decoder.decodeStream(input);
    final headers = decoder.directory.fileHeaders;
    if (headers.length > 200000) return {'error': 'This file has too many entries to be an HRMS archive.'};
    for (final h in headers) {
      final dir = h.filename.endsWith('/');
      if (!dir && !isSafeZipPath(h.filename)) {
        return {'error': 'The archive contains unsafe file names and was not used.'};
      }
      if (h.uncompressedSize > 60000000 ||
          (h.compressedSize > 0 && h.uncompressedSize > 1000000 && h.uncompressedSize / h.compressedSize > 200)) {
        return {'error': 'The archive contains an oversized or suspicious entry and was not used.'};
      }
    }
    final manifestEntry = archive.find('manifest.json');
    if (manifestEntry == null) return {'error': 'This is not an HRMS archive (manifest.json is missing).'};
    final m = jsonDecode(utf8.decode(_readBounded(manifestEntry, 60000000))) as Map<String, dynamic>;
    final job = (m['job'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (requireJobId != null && (job['id'] != requireJobId || job['manifest_hash'] != requireHash)) {
      return {'error': 'This is a different archive from the one required. Choose the saved archive of the stated revision.'};
    }
    final pathById = <String, String>{
      for (final i in (m['items'] as List? ?? const []))
        if ((i as Map)['included'] != false) i['file_version_id'] as String: i['path'] as String,
    };
    final missing = <String>[];
    for (final n in needed) {
      final id = n[0] as String;
      final sha = n[1] as String;
      final size = n[2] as int;
      final path = pathById[id];
      final entry = path == null ? null : archive.find(path);
      if (entry == null || entry.size != size || size > 5000000) {
        missing.add(id);
        continue;
      }
      final bytes = _readBounded(entry, size);
      if (bytes.length != size || sha256.convert(bytes).toString() != sha) {
        missing.add(id);
        continue;
      }
      File('$outDir/$id').writeAsBytesSync(bytes, flush: true);
      File('$outDir/$id.ok').writeAsStringSync(sha);
    }
    return {'missing': missing};
  } catch (_) {
    return {'error': 'The archive could not be read. Choose the original ZIP file.'};
  } finally {
    input.closeSync();
  }
}

Future<void> _writeZip(String zipPath, List<List<String>> entries) async {
  final encoder = ZipFileEncoder();
  encoder.create(zipPath, level: DeflateLevel.bestSpeed);
  try {
    for (final e in entries) {
      await encoder.addFile(File(e[0]), e[1]);
    }
  } finally {
    await encoder.close();
  }
}

/// Re-reads the finished ZIP: exact entry count, and every entry's size and
/// SHA-256 (one bounded entry in memory at a time). Returns an error or null.
String? _verifyZip(String zipPath, List<List<Object>> expected) {
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final count = archive.files.where((f) => f.isFile).length;
    if (count != expected.length) return 'The ZIP has $count files but ${expected.length} were expected.';
    for (final e in expected) {
      final entry = archive.find(e[0] as String);
      if (entry == null) return 'Missing from the ZIP: ${e[0]}';
      final size = e[1] as int;
      final bytes = _readBounded(entry, size);
      if (bytes.length != size || sha256.convert(bytes).toString() != e[2]) return 'A file did not verify: ${e[0]}';
    }
    return null;
  } catch (_) {
    return 'The ZIP could not be read back for verification.';
  } finally {
    input.closeSync();
  }
}

String _sha256File(String path) => sha256.convert(File(path).readAsBytesSync()).toString();

class ArchiveProgress {
  const ArchiveProgress(this.label, {this.done = 0, this.total = 0});
  final String label;
  final int done;
  final int total;
  double? get fraction => total == 0 ? null : done / total;
}

class BuiltArchive {
  const BuiltArchive({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.includedFiles,
    required this.includedBytes,
    required this.partial,
    required this.missingIds,
    required this.manifestHash,
  });

  factory BuiltArchive.fromJson(Map<String, dynamic> j) => BuiltArchive(
        path: j['path'] as String,
        fileName: j['file_name'] as String,
        sizeBytes: (j['size_bytes'] as num).toInt(),
        includedFiles: (j['included_files'] as num).toInt(),
        includedBytes: (j['included_bytes'] as num).toInt(),
        partial: j['partial'] == true,
        missingIds: ((j['missing_ids'] as List?) ?? const []).cast<String>(),
        manifestHash: j['manifest_hash'] as String,
      );

  final String path;
  final String fileName;
  final int sizeBytes;
  final int includedFiles;
  final int includedBytes;
  final bool partial;
  final List<String> missingIds;
  final String manifestHash;

  Map<String, Object> toJson() => {
        'path': path,
        'file_name': fileName,
        'size_bytes': sizeBytes,
        'included_files': includedFiles,
        'included_bytes': includedBytes,
        'partial': partial,
        'missing_ids': missingIds,
        'manifest_hash': manifestHash,
      };
}

/// Builds the annual archive on the phone: downloads (at most two at a
/// time) through audited <=60 s links, verifies each file's SHA-256 and
/// size, merges earlier originals from the previous local archive when the
/// cloud copies were already cleaned up, writes XLSX + JSON, streams the ZIP
/// to disk in an isolate and verifies it by reading it back. Verified
/// downloads are kept, so a stopped build resumes without re-downloading.
class ArchiveBuilder {
  ArchiveBuilder(this.api, this.manifest);
  final ApiClient api;
  final Map<String, dynamic> manifest;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  String get jobId => manifest['id'] as String;
  List<Map<String, dynamic>> get items =>
      [for (final i in (manifest['items'] as List? ?? const [])) (i as Map).cast<String, dynamic>()];
  List<Map<String, dynamic>> get employees =>
      [for (final e in (manifest['employees'] as List? ?? const [])) (e as Map).cast<String, dynamic>()];

  static Future<Directory> workDir(String jobId) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/hrms_archive/$jobId');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<BuiltArchive?> loadBuilt(String jobId, String manifestHash) async {
    try {
      final f = File('${(await workDir(jobId)).path}/built.json');
      if (!await f.exists()) return null;
      final b = BuiltArchive.fromJson((jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>());
      if (b.manifestHash != manifestHash || !await File(b.path).exists()) return null;
      return b;
    } catch (_) {
      return null;
    }
  }

  static Future<void> discard(String jobId) async {
    final dir = await workDir(jobId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Rough free-space need: downloads + ZIP + temporary spreadsheets.
  int get estimatedDiskBytes => ((manifest['total_bytes'] as num? ?? 0) * 2.1).round() + 20000000;

  String fileName({required bool partial}) =>
      'HRMS_${manifest['period_start']}_${manifest['period_end']}_r${manifest['revision']}${partial ? '_PARTIAL' : ''}.zip';

  void _checkCancel() {
    if (_cancelled) throw const ArchiveException('Stopped. Verified downloads are kept; you can resume any time.');
  }

  Future<void> _download(Map<String, dynamic> item, Directory files) async {
    final id = item['file_version_id'] as String;
    final size = (item['size_bytes'] as num).toInt();
    final sha = item['sha256'] as String;
    final target = File('${files.path}/$id');
    final marker = File('${files.path}/$id.ok');
    if (await marker.exists() && await target.exists() && await target.length() == size &&
        await marker.readAsString() == sha) {
      return; // verified by an earlier run
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      _checkCancel();
      final link = (await api.function('archive', {'action': 'file_url', 'job_id': jobId, 'file_version_id': id})).map;
      if (link['available'] != true) {
        throw ArchiveException('A file is no longer in cloud storage: ${item['path']}. Create a new export.');
      }
      final part = File('${target.path}.part');
      try {
        final (gotSha, gotSize) = await api.downloadToFile(link['url'] as String, part, maxBytes: size);
        if (gotSize == size && gotSha == sha) {
          await part.rename(target.path);
          await marker.writeAsString(sha);
          return;
        }
      } on ApiException catch (e) {
        if (!e.retryable && !e.isNetwork) rethrow;
        if (attempt == 2) rethrow;
      }
      if (await part.exists()) await part.delete();
    }
    throw ArchiveException('A downloaded file did not match its recorded fingerprint: ${item['path']}');
  }

  Future<BuiltArchive> build({
    String? baseZipPath,
    bool partial = false,
    required void Function(ArchiveProgress) onProgress,
  }) async {
    if (canonicalManifestHash(manifest) != manifest['manifest_hash']) {
      throw const ArchiveException('The downloaded manifest did not verify. Reload and try again.');
    }
    for (final i in items) {
      if (!isSafeZipPath(i['path'] as String)) throw const ArchiveException('The manifest contains an unsafe path.');
    }
    for (final e in employees) {
      if (!isSafeZipPath(e['folder'] as String)) throw const ArchiveException('The manifest contains an unsafe folder.');
    }
    final dir = await workDir(jobId);
    final files = Directory('${dir.path}/files');
    await files.create(recursive: true);
    final cloud = items.where((i) => i['source'] == 'cloud').toList();
    final local = items.where((i) => i['source'] == 'local_base').toList();

    // 1. Cloud files.
    var done = 0;
    var next = 0;
    onProgress(ArchiveProgress('Downloading files', total: cloud.length));
    Future<void> worker() async {
      while (true) {
        _checkCancel();
        final i = next++;
        if (i >= cloud.length) return;
        await _download(cloud[i], files);
        done++;
        onProgress(ArchiveProgress('Downloading files', done: done, total: cloud.length));
      }
    }

    await Future.wait([worker(), worker()]);

    // 2. Originals of files already removed from the cloud.
    var missing = <String>[];
    if (local.isNotEmpty) {
      if (partial) {
        missing = [for (final i in local) i['file_version_id'] as String];
      } else {
        final base = (manifest['base'] as Map?)?.cast<String, dynamic>();
        if (baseZipPath == null || base == null) throw const ArchiveException('Select the previous archive first.');
        onProgress(ArchiveProgress('Checking the previous archive', total: local.length));
        final needed = [for (final i in local) <Object>[i['file_version_id'] as String, i['sha256'] as String, (i['size_bytes'] as num).toInt()]];
        final zip = baseZipPath;
        final baseId = base['id'] as String;
        final baseHash = base['manifest_hash'] as String;
        final out = files.path;
        final res = await Isolate.run(() => extractOriginals(zip, baseId, baseHash, needed, out));
        if (res['error'] != null) throw ArchiveException(res['error'] as String);
        final notFound = (res['missing'] as List).length;
        if (notFound > 0) {
          throw ArchiveException('$notFound earlier file(s) were missing or did not match in that archive. Choose the '
              'correct archive, or build a clearly marked partial archive.');
        }
      }
    }

    // 3. Spreadsheets, profiles, summary and manifest.
    final build = Directory('${dir.path}/build');
    if (await build.exists()) await build.delete(recursive: true);
    await build.create(recursive: true);
    final entries = <List<String>>[];
    final generated = <List<String>>[];
    Future<void> writeEntry(String zipPath, List<int> bytes) async {
      final f = File('${build.path}/${generated.length}.bin');
      await f.writeAsBytes(bytes, flush: true);
      entries.add([f.path, zipPath]);
      generated.add([f.path, zipPath]);
    }

    final summary = XlsxSheet('Summary', columnWidths: const [12, 28, 10, 36, 10, 10, 12, 12, 12, 12, 10, 10])
      ..header(['Employee ID', 'Name', 'Status', 'Folder', 'Attendance rows', 'Leave rows', 'Expected (min)',
        'Worked (min)', 'Short (min)', 'Extra (min)', 'Unresolved days', 'Files']);
    onProgress(ArchiveProgress('Preparing spreadsheets', total: employees.length));
    for (var k = 0; k < employees.length; k++) {
      _checkCancel();
      final e = employees[k];
      final d = (await api.rpc('get_export_employee', {'p_job_id': jobId, 'p_employee_id': e['employee_id']})).map;
      final attendance = [for (final r in (d['attendance'] as List? ?? const [])) (r as Map).cast<String, dynamic>()];
      final leave = [for (final r in (d['leave'] as List? ?? const [])) (r as Map).cast<String, dynamic>()];
      if (attendance.length != e['attendance_count'] || leave.length != e['leave_count']) {
        throw ArchiveException('Row counts did not match for ${e['code']}. Reload the export and try again.');
      }
      final folder = e['folder'] as String;
      await writeEntry('$folder/Attendance.xlsx', buildXlsx([_attendanceSheet(attendance)]));
      await writeEntry('$folder/Leave.xlsx', buildXlsx([_leaveSheet(leave)]));
      await writeEntry('$folder/Profile.json', utf8.encode(const JsonEncoder.withIndent('  ').convert(d['profile'])));
      final t = ((e['totals'] as Map?) ?? const {}).cast<String, dynamic>();
      int m(Object? s) => ((s as num?) ?? 0).toInt() ~/ 60;
      summary.add([e['code'], e['name'], e['status'], folder, attendance.length, leave.length, m(t['required_seconds']),
        m(t['credited_seconds']), m(t['shortfall_seconds']), m(t['extra_seconds']), t['unresolved_days'],
        items.where((i) => i['employee_id'] == e['employee_id']).length]);
      onProgress(ArchiveProgress('Preparing spreadsheets', done: k + 1, total: employees.length));
    }
    await writeEntry('Summary.xlsx', buildXlsx([summary]));
    final included = items.where((i) => !missing.contains(i['file_version_id'])).toList();
    await writeEntry('manifest.json', utf8.encode(const JsonEncoder.withIndent('  ').convert(_manifestJson(partial, missing))));
    for (final i in included) {
      entries.add(['${files.path}/${i['file_version_id']}', i['path'] as String]);
    }

    // 4. ZIP (streamed to disk in a background isolate).
    _checkCancel();
    onProgress(const ArchiveProgress('Writing the ZIP file'));
    final name = fileName(partial: partial);
    final zipPath = '${dir.path}/$name';
    final zipFile = File(zipPath);
    if (await zipFile.exists()) await zipFile.delete();
    try {
      await Isolate.run(() => _writeZip(zipPath, entries));
    } on FileSystemException {
      throw const ArchiveException('The phone ran out of space while writing the ZIP. Free some space and resume.');
    }

    // 5. Read back and verify every entry.
    onProgress(const ArchiveProgress('Verifying the archive'));
    final expected = <List<Object>>[
      for (final g in generated) [g[1], await File(g[0]).length(), _sha256File(g[0])],
      for (final i in included) [i['path'] as String, (i['size_bytes'] as num).toInt(), i['sha256'] as String],
    ];
    final problem = await Isolate.run(() => _verifyZip(zipPath, expected));
    if (problem != null) throw ArchiveException(problem);
    await build.delete(recursive: true);

    final built = BuiltArchive(
      path: zipPath,
      fileName: name,
      sizeBytes: await zipFile.length(),
      includedFiles: included.length,
      includedBytes: included.fold<int>(0, (a, i) => a + (i['size_bytes'] as num).toInt()),
      partial: partial,
      missingIds: missing,
      manifestHash: manifest['manifest_hash'] as String,
    );
    await File('${dir.path}/built.json').writeAsString(jsonEncode(built.toJson()));
    onProgress(const ArchiveProgress('Verified'));
    return built;
  }

  Map<String, Object?> _manifestJson(bool partial, List<String> missing) => {
        'format': 'hrms-archive-v1',
        'job': {
          'id': manifest['id'],
          'revision': manifest['revision'],
          'period_start': manifest['period_start'],
          'period_end': manifest['period_end'],
          'label': manifest['label'],
          'timezone': manifest['timezone'],
          'as_of': manifest['as_of'],
          'manifest_hash': manifest['manifest_hash'],
          'provisional': manifest['provisional'],
          'base_export_id': manifest['base_export_id'],
        },
        'organization': manifest['org'],
        'generated_at': DateTime.now().toUtc().toIso8601String(),
        'partial': partial,
        'missing_file_ids': missing,
        'row_counts': manifest['row_counts'],
        'exclusions': manifest['exclusions'],
        'employees': manifest['employees'],
        'items': [
          for (final i in items) {...i, 'included': !missing.contains(i['file_version_id'])},
        ],
        'notes': [
          'Dates are shift start dates; times are local office time (${manifest['timezone']}).',
          'Profile.json files show each profile as of the export time, not historical values.',
          'Pending requests are exported as pending; extra time is not overtime pay.',
          if (partial) 'PARTIAL: earlier originals listed in missing_file_ids are not included.',
        ],
      };

  static XlsxSheet _attendanceSheet(List<Map<String, dynamic>> rows) {
    int m(Object? s) => ((s as num?) ?? 0).toInt() ~/ 60;
    final sheet = XlsxSheet('Attendance', columnWidths: const [12, 18, 8, 8, 8, 8, 12, 12, 10, 10, 10, 10, 6, 8, 8, 8, 8, 8])
      ..header(['Shift date', 'Status', 'Shift start', 'Shift end', 'In', 'Out', 'Source', 'Leave', 'Required (min)',
        'Worked (min)', 'Short (min)', 'Extra (min)', 'Late', 'Late (min)', 'Left early', 'Early (min)', 'Lunch paid',
        'Revision']);
    for (final r in rows) {
      sheet.add([XlsxDate.parse(r['shift_date'] as String), dayStatus(r).$1, hhmm(r['start_at']), hhmm(r['end_at']),
        hhmm(r['effective_in_at']), hhmm(r['effective_out_at']),
        r['effective_in_at'] == null ? '' : sourceLabel(r['effective_source'] as String?),
        leaveSlotLabel((r['leave_slots'] as num?)?.toInt() ?? 0), m(r['required_seconds']), m(r['credited_seconds']),
        m(r['shortfall_seconds']), m(r['extra_seconds']), r['is_late'] == true, m(r['late_seconds']),
        r['is_early_departure'] == true, m(r['early_seconds']), r['lunch_paid'] == true, r['effective_revision']]);
    }
    return sheet;
  }

  static XlsxSheet _leaveSheet(List<Map<String, dynamic>> rows) {
    double days(Object? u) => ((u as num?) ?? 0) / 2;
    final sheet = XlsxSheet('Leave', columnWidths: const [38, 8, 20, 6, 12, 12, 26, 10, 12, 12, 20, 20])
      ..header(['Request ID', 'Code', 'Leave type', 'Paid', 'Start', 'End', 'Status', 'Days total',
        'Booked in period', 'Requested in period', 'Submitted', 'Decided']);
    for (final r in rows) {
      sheet.add([r['request_id'], r['leave_type_code'], r['leave_type'], r['paid'] == true,
        XlsxDate.parse(r['start_date'] as String), XlsxDate.parse(r['end_date'] as String), r['status'],
        days(r['units_total']), days(r['booked_units_in_period']), days(r['requested_units_in_period']),
        r['submitted_at'] == null ? '' : OrgTime.dateTime(r['submitted_at']),
        r['decided_at'] == null ? '' : OrgTime.dateTime(r['decided_at'])]);
    }
    return sheet;
  }
}
