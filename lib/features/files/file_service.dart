import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';

class DownloadedFile {
  const DownloadedFile(this.bytes, this.mime, this.filename, this.grantId);
  final Uint8List bytes;
  final String mime;
  final String filename;
  final String? grantId;
}

/// Private file transfer. Uploads: begin (quota + signed staging URL) ->
/// upload bytes -> finish (server copies to an immutable object, validates
/// and hashes it). Downloads: audited authorisation -> <=60 s signed URL ->
/// bytes kept in memory only (no persistent cache for pay documents).
class FileService {
  FileService(this._api);
  final ApiClient _api;
  static const maxBytes = 5000000;

  static String? mimeFor(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => 'application/pdf',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => null,
    };
  }

  /// Returns the validated file version id.
  Future<String> upload({
    required String fileClass,
    required Uint8List bytes,
    required String filename,
    String? ownerEmployeeId,
    String? salaryMonth,
    String? documentDate,
    String? title,
  }) async {
    if (bytes.isEmpty) throw const ApiException('INVALID_FILE_TYPE', 'The file is empty.');
    if (bytes.length > maxBytes) {
      throw const ApiException('FILE_TOO_LARGE', 'Files must be at most 5 MB (5,000,000 bytes).');
    }
    final mime = mimeFor(filename);
    if (mime == null) throw const ApiException('INVALID_FILE_TYPE', 'Use a PDF, JPG or PNG file.');
    final begin = (await _api.function('files', {
      'action': 'begin',
      'class': fileClass,
      'owner_employee_id': ?ownerEmployeeId,
      'salary_month': ?salaryMonth,
      'document_date': ?documentDate,
      'title': ?title,
      'filename': filename,
      'size': bytes.length,
      'mime': mime,
    }))
        .map;
    try {
      await _api.supabase.storage.from(begin['bucket'] as String).uploadBinaryToSignedUrl(
            begin['path'] as String,
            begin['upload_token'] as String,
            bytes,
            FileOptions(contentType: mime, upsert: false),
          );
    } on StorageException {
      throw const ApiException('NETWORK', 'Upload failed. Check your connection and try again.', retryable: true);
    }
    await _api.function('files', {'action': 'finish', 'file_version_id': begin['file_version_id']});
    return begin['file_version_id'] as String;
  }

  Future<DownloadedFile> fetch(String fileVersionId, {String purpose = 'view'}) async {
    final res = (await _api.function('files', {
      'action': 'access',
      'file_version_id': fileVersionId,
      'purpose': purpose,
    }))
        .map;
    if (res['available'] != true) {
      throw ApiException('ARCHIVED', (res['message'] as String?) ?? 'This file is not available in the app.');
    }
    final bytes = Uint8List.fromList(await _api.download(res['url'] as String));
    final grant = res['grant_id'] as String?;
    if (grant != null) {
      // Opening is reported separately from link issuance (AUDIT-003).
      _api.rpc('report_file_opened', {'p_grant_id': grant}).ignore();
    }
    return DownloadedFile(bytes, (res['mime'] as String?) ?? 'application/pdf',
        (res['filename'] as String?) ?? 'document', grant);
  }
}

final fileServiceProvider = Provider<FileService>((ref) => FileService(ref.watch(apiProvider)));
