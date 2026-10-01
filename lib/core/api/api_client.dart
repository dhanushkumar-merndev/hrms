import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../app/config.dart';
import 'api_exception.dart';

/// Envelope returned by every HRMS call: {data, version, request_id}.
class ApiResult {
  const ApiResult(this.data, this.version, this.requestId);
  final dynamic data;
  final int? version;
  final String? requestId;

  Map<String, dynamic> get map => (data as Map).cast<String, dynamic>();
  List<Map<String, dynamic>> get list =>
      (data as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
}

/// Thin client over the HRMS API: `public.*` RPCs through PostgREST and Edge
/// Functions over HTTPS. All authorization happens on the server; this layer
/// only normalises transport and error handling.
class ApiClient {
  ApiClient(this._supabase, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final SupabaseClient _supabase;
  final http.Client _http;
  static const _timeout = Duration(seconds: 25);
  static const _uuid = Uuid();

  SupabaseClient get supabase => _supabase;

  static String newOperationKey() => _uuid.v4();

  Future<ApiResult> rpc(String fn, [Map<String, dynamic>? params]) async {
    try {
      final res = await _supabase.rpc(fn, params: params).timeout(_timeout);
      if (res is Map) {
        final m = res.cast<String, dynamic>();
        return ApiResult(m['data'], (m['version'] as num?)?.toInt(), m['request_id'] as String?);
      }
      return ApiResult(res, null, null);
    } on PostgrestException catch (e) {
      throw ApiException.fromPostgrest(e);
    } on AuthException {
      throw const ApiException('AUTH_REQUIRED', 'Please sign in again.');
    } on SocketException {
      throw ApiException.network;
    } on TimeoutException {
      throw ApiException.network;
    } on http.ClientException {
      throw ApiException.network;
    }
  }

  /// Calls an Edge Function with the current user's access token (if any).
  /// New-style publishable keys go on `apikey` only.
  Future<ApiResult> function(String name, Map<String, dynamic> body, {bool authenticated = true}) async {
    final headers = <String, String>{
      'apikey': AppConfig.supabaseKey,
      'Content-Type': 'application/json',
      'x-request-id': _uuid.v4(),
    };
    final token = _supabase.auth.currentSession?.accessToken;
    if (authenticated) {
      if (token == null) throw const ApiException('AUTH_REQUIRED', 'Please sign in again.');
      headers['Authorization'] = 'Bearer $token';
    } else if (!AppConfig.supabaseKey.startsWith('sb_')) {
      headers['Authorization'] = 'Bearer ${AppConfig.supabaseKey}';
    }
    http.Response res;
    try {
      res = await _http
          .post(Uri.parse('${AppConfig.supabaseUrl}/functions/v1/$name'), headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 45));
    } on SocketException {
      throw ApiException.network;
    } on TimeoutException {
      throw ApiException.network;
    } on http.ClientException {
      throw ApiException.network;
    }
    Object? decoded;
    try {
      decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      decoded = null;
    }
    if (res.statusCode >= 300) {
      // Punch rejections come back as {ok:false,error:{...}}.
      throw ApiException.fromEnvelope(decoded, res.statusCode);
    }
    if (decoded is Map) {
      final m = decoded.cast<String, dynamic>();
      if (m.containsKey('ok')) return ApiResult(m, null, m['request_id'] as String?);
      return ApiResult(m['data'], (m['version'] as num?)?.toInt(), m['request_id'] as String?);
    }
    return ApiResult(decoded, null, null);
  }

  /// Streams a short-lived signed URL to [target] while hashing it, without
  /// holding the file in memory. Returns (sha256 hex, byte count). Aborts
  /// past [maxBytes].
  Future<(String, int)> downloadToFile(String url, File target, {int maxBytes = 5000000}) async {
    final sink = _DigestSink();
    final hasher = sha256.startChunkedConversion(sink);
    final out = target.openWrite();
    var size = 0;
    try {
      final res = await _http.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 60));
      if (res.statusCode >= 300) {
        await res.stream.drain<void>();
        throw const ApiException('ACCESS_DENIED', 'The download link expired. Try again.', retryable: true);
      }
      await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
        size += chunk.length;
        if (size > maxBytes) throw const ApiException('FILE_TOO_LARGE', 'A file was larger than recorded.');
        hasher.add(chunk);
        out.add(chunk);
      }
      hasher.close();
      return (sink.value.toString(), size);
    } on SocketException {
      throw ApiException.network;
    } on TimeoutException {
      throw ApiException.network;
    } on http.ClientException {
      throw ApiException.network;
    } finally {
      await out.close();
    }
  }

  /// Downloads bytes from a short-lived signed URL (never cached to disk).
  Future<List<int>> download(String url) async {
    try {
      final res = await _http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
      if (res.statusCode >= 300) {
        throw const ApiException('ACCESS_DENIED', 'The link expired. Open the file again.');
      }
      return res.bodyBytes;
    } on SocketException {
      throw ApiException.network;
    } on TimeoutException {
      throw ApiException.network;
    }
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

final supabaseProvider = Provider<SupabaseClient>((ref) => Supabase.instance.client);

final apiProvider = Provider<ApiClient>((ref) => ApiClient(ref.watch(supabaseProvider)));
