import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'downloader.dart';
import 'splitter.dart';

/// The server said something other than yes.
class IngestHttpError implements Exception {
  IngestHttpError(this.status, this.body);
  final int status;
  final String body;

  @override
  String toString() {
    try {
      final d = jsonDecode(body);
      if (d is Map && d['detail'] is String) return '$status: ${d['detail']}';
    } catch (_) {}
    return '$status: ${body.length > 200 ? body.substring(0, 200) : body}';
  }
}

/// The server's job queue over HTTP, spoken to with the token a device signs in with.
///
/// Nothing but dart:io and package:http, because two programs use it: the app, and the
/// windowless one that keeps fetching when the app is shut. The token is a getter — the
/// app's changes when somebody signs in again, and a copy taken once would go stale.
class HttpIngestServer implements IngestServer {
  HttpIngestServer(
      {required this.baseUrl, required this.token, this.pool, http.Client? client})
      : _client = client ?? http.Client();

  final String Function() baseUrl;
  final String? Function() token;

  /// What this computer says about itself with every lease (pool.py on the server).
  final Map<String, dynamic> Function()? pool;
  final http.Client _client;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token() != null) 'Authorization': 'Bearer ${token()}',
      };

  Future<dynamic> _post(String path, Map<String, dynamic> body, {Duration? timeout}) async {
    final asked =
        _client.post(Uri.parse('${baseUrl()}$path'), headers: _headers, body: jsonEncode(body));
    final r = await (timeout == null ? asked : asked.timeout(timeout));
    if (r.statusCode >= 300) {
      // Not allowed, or no longer: there is nothing to be gained by asking again.
      if (r.statusCode == 401 || r.statusCode == 403) {
        throw IngestRefused(IngestHttpError(r.statusCode, r.body).toString());
      }
      throw IngestHttpError(r.statusCode, r.body);
    }
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  @override
  Future<List<IngestJob>> lease(
      {required int limit, required int busy, bool urgentOnly = false, int wait = 0}) async {
    final d = await _post(
        '/internal/jobs/lease',
        {
          'kind': 'ingest',
          'limit': limit,
          'busy': busy,
          'wait': wait,
          if (urgentOnly) 'max_priority': 90,
          if (pool != null) 'pool': pool!(),
        },
        timeout: Duration(seconds: wait + 15));
    return [
      for (final j in ((d as Map?)?['jobs'] ?? const []) as List)
        if (IngestJob.fromJson((j as Map).cast<String, dynamic>()) case final job?) job
    ];
  }

  @override
  Future<IngestJob?> claim(int trackId) async {
    final d = await _post('/internal/jobs/claim', {'kind': 'ingest', 'track_id': trackId},
        timeout: const Duration(seconds: 20));
    final j = (d as Map?)?['job'];
    return j is Map ? IngestJob.fromJson(j.cast<String, dynamic>()) : null;
  }

  @override
  Future<void> progress(IngestJob job, String stage, {double? percent, String? speed}) =>
      _post('/internal/jobs/${job.id}/progress',
          {'track_id': job.trackId, 'stage': stage, 'percent': percent, 'speed': speed},
          timeout: const Duration(seconds: 10));

  @override
  Future<void> fail(IngestJob job, String reason, {required bool retryable}) =>
      _post('/internal/jobs/${job.id}/fail', {
        'reason': reason.length > 500 ? reason.substring(0, 500) : reason,
        'retryable': retryable,
        'track_id': job.trackId,
      });

  @override
  Future<void> release(IngestJob job) =>
      _post('/internal/jobs/${job.id}/release', {'track_id': job.trackId},
          timeout: const Duration(seconds: 10));

  @override
  Future<void> complete(IngestJob job, File audio, Map<String, dynamic> meta) async {
    final request =
        http.MultipartRequest('POST', Uri.parse('${baseUrl()}/internal/jobs/${job.id}/complete'))
          ..headers.addAll({if (token() != null) 'Authorization': 'Bearer ${token()}'})
          ..fields['meta'] = jsonEncode(meta)
          // From the file, not from memory: an hour-long set is sixty megabytes.
          ..files.add(await http.MultipartFile.fromPath('audio', audio.path,
              filename: audio.uri.pathSegments.last));
    final response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(minutes: 5)));
    if (response.statusCode >= 300) {
      throw IngestHttpError(response.statusCode, response.body);
    }
  }
}


/// The same queue, for taking records apart (splitter.dart).
class HttpSplitServer implements SplitServer {
  HttpSplitServer(
      {required this.baseUrl, required this.token, http.Client? client})
      : _client = client ?? http.Client();

  final String Function() baseUrl;
  final String? Function() token;
  final http.Client _client;

  @override
  String get house => baseUrl();

  Map<String, String> get _auth => {if (token() != null) 'Authorization': 'Bearer ${token()}'};

  Future<dynamic> _post(String path, Map<String, dynamic> body, {Duration? timeout}) async {
    final asked = _client.post(Uri.parse('${baseUrl()}$path'),
        headers: {'Content-Type': 'application/json', ..._auth}, body: jsonEncode(body));
    final r = await (timeout == null ? asked : asked.timeout(timeout));
    if (r.statusCode >= 300) {
      if (r.statusCode == 401 || r.statusCode == 403) {
        throw SplitRefused(IngestHttpError(r.statusCode, r.body).toString());
      }
      throw IngestHttpError(r.statusCode, r.body);
    }
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  @override
  Future<List<SplitJob>> lease({required Map<String, dynamic> pool, int wait = 25}) async {
    final d = await _post('/internal/jobs/lease',
        {'kind': 'split', 'limit': 1, 'busy': 0, 'wait': wait, 'pool': pool},
        timeout: Duration(seconds: wait + 15));
    return [
      for (final j in ((d as Map?)?['jobs'] ?? const []) as List)
        if (SplitJob.fromJson((j as Map).cast<String, dynamic>()) case final job?) job
    ];
  }

  @override
  Future<SplitJob?> claim(int trackId) async {
    final d = await _post('/internal/jobs/claim', {'kind': 'split', 'track_id': trackId},
        timeout: const Duration(seconds: 20));
    final j = (d as Map?)?['job'];
    return j is Map ? SplitJob.fromJson(j.cast<String, dynamic>(), own: true) : null;
  }

  @override
  Future<void> progress(SplitJob job, String stage, double? percent) =>
      _post('/internal/jobs/${job.id}/progress', {
        'kind': 'split', 'track_id': job.trackId, 'stage': stage, 'percent': percent,
      }, timeout: const Duration(seconds: 10));

  @override
  Future<void> fail(SplitJob job, String reason, {required bool retryable}) =>
      _post('/internal/jobs/${job.id}/fail', {
        'reason': reason.length > 500 ? reason.substring(0, 500) : reason,
        'retryable': retryable,
        'track_id': job.trackId,
      });

  @override
  Future<void> release(SplitJob job) =>
      _post('/internal/jobs/${job.id}/release', {'track_id': job.trackId},
          timeout: const Duration(seconds: 10));

  @override
  Future<void> handIn(SplitJob job, Map<String, File> parts, {double? seconds}) async {
    final request =
        http.MultipartRequest('POST', Uri.parse('${baseUrl()}/internal/jobs/${job.id}/parts'))
          ..headers.addAll(_auth)
          ..fields['meta'] = jsonEncode({'seconds': seconds});
    for (final e in parts.entries) {
      request.files.add(await http.MultipartFile.fromPath(e.key, e.value.path,
          filename: e.key == 'beats' ? 'beats.json' : '${e.key}.m4a'));
    }
    final response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(minutes: 5)));
    if (response.statusCode >= 300) {
      throw IngestHttpError(response.statusCode, response.body);
    }
  }

  @override
  Future<void> fetchRecord(int trackId, File into,
      {void Function(int got, int? total)? progress}) async {
    final request = http.Request('GET', Uri.parse('${baseUrl()}/tracks/$trackId/stream'))
      ..headers.addAll(_auth);
    final response = await _client.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw IngestHttpError(response.statusCode, 'could not fetch the record');
    }
    final part = File('${into.path}.part');
    final sink = part.openWrite();
    var got = 0;
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
        got += chunk.length;
        sink.add(chunk);
        progress?.call(got, response.contentLength);
      }
    } finally {
      await sink.close();
    }
    await part.rename(into.path);
  }
}
