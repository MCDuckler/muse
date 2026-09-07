import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => 'ApiException($status): $message';
}

/// Talks to one muse server. The token is per device and revocable; there is no
/// signup, so there is no account flow to build.
class ApiClient {
  ApiClient({required this.baseUrl, this.token});

  String baseUrl;
  String? token;

  Map<String, String> get _headers => {
        if (token != null) 'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  Uri _u(String path, [Map<String, dynamic>? q]) => Uri.parse('$baseUrl$path').replace(
      queryParameters: q?.map((k, v) => MapEntry(k, '$v')));

  Future<dynamic> _decode(http.Response r) async {
    if (r.statusCode >= 400) {
      String detail = r.body;
      try {
        final d = jsonDecode(r.body);
        if (d is Map && d['detail'] != null) {
          final v = d['detail'];
          if (v is List) {
            // FastAPI validation errors arrive as a list of objects; printing them
            // raw put "[{type: missing, loc: [body, user]…}]" in front of the user.
            detail = v
                .map((e) => e is Map ? (e['msg'] ?? '').toString() : '$e')
                .where((s) => s.isNotEmpty)
                .join('. ');
          } else {
            detail = '$v';
          }
        }
      } catch (_) {}
      if (detail.trim().isEmpty) detail = 'Request failed (${r.statusCode})';
      if (detail.startsWith('<!DOCTYPE') || detail.startsWith('<html')) {
        // A proxy served the app shell where the API should be: a routing problem,
        // not an API error. Say so instead of dumping HTML at the user.
        detail = 'Server returned a web page, not data (${r.statusCode})';
      }
      throw ApiException(r.statusCode, detail);
    }
    if (r.body.isEmpty) return null;
    try {
      return jsonDecode(r.body);
    } on FormatException {
      throw ApiException(r.statusCode,
          'Server returned a web page, not data — check the API routing');
    }
  }

  Future<String> login(String user, String password, String device) async {
    final r = await http.post(_u('/auth/login'), body: {
      'user': user,
      'password': password,
      'device': device,
      'platform': _platformName(),
    });
    final d = await _decode(r) as Map<String, dynamic>;
    token = d['token'] as String;
    return token!;
  }

  String? _streamKey;
  int _streamKeyExpiry = 0;

  /// The browser's audio element cannot send an Authorization header, so media URLs
  /// carry a short-lived signed key instead. Fetched once and reused until it ages out.
  Future<void> ensureStreamKey({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!force && _streamKey != null && _streamKeyExpiry - 300 > now) return;
    final d = await _decode(await http.get(_u('/auth/stream-key'), headers: _headers))
        as Map<String, dynamic>;
    _streamKey = d['key'] as String;
    _streamKeyExpiry = d['expires_at'] as int;
  }

  Future<Map<String, dynamic>> me() async =>
      await _decode(await http.get(_u('/me'), headers: _headers)) as Map<String, dynamic>;

  /// Local catalog first, then YouTube Music. Remote hits are flagged `known` when
  /// the library already has them, so the UI never offers to fetch a track twice.
  Future<({List<Track> local, List<RemoteHit> remote})> search(String q) async {
    final d = await _decode(await http.get(_u('/search', {'q': q}), headers: _headers))
        as Map<String, dynamic>;
    return (
      local: ((d['local'] ?? []) as List).map((e) => Track.fromJson(e)).toList(),
      remote: ((d['remote'] ?? []) as List).map((e) => RemoteHit.fromJson(e)).toList(),
    );
  }

  /// 200 when the server already had it, 202 when it just queued a download.
  Future<Track> resolve({String? videoId, String? query}) async {
    final r = await http.post(_u('/tracks/resolve'),
        headers: _headers,
        body: jsonEncode({if (videoId != null) 'video_id': videoId, if (query != null) 'query': query}));
    return Track.fromJson(await _decode(r) as Map<String, dynamic>);
  }

  Future<Track> track(int id) async =>
      Track.fromJson(await _decode(await http.get(_u('/tracks/$id'), headers: _headers))
          as Map<String, dynamic>);

  String streamUrl(Track t) {
    final key = _streamKey;
    return key == null
        ? '$baseUrl${t.streamPath}'
        : '$baseUrl${t.streamPath}?k=${Uri.encodeQueryComponent(key)}';
  }

  /// Same signed-key trick as audio: an <img> cannot send an Authorization header.
  String? coverUrl(Track t, {bool small = false}) {
    if (t.coverPath == null) return null;
    final key = _streamKey;
    final size = small ? 'sm' : 'lg';
    final auth = key == null ? '' : '&k=${Uri.encodeQueryComponent(key)}';
    return '$baseUrl${t.coverPath}?size=$size$auth';
  }

  Map<String, String> get streamHeaders => {'Authorization': 'Bearer $token'};

  bool get hasStreamKey => _streamKey != null;

  // ---------------- queues ----------------
  Future<List<Queue>> queues() async {
    final d = await _decode(await http.get(_u('/queues'), headers: _headers)) as List;
    return d.map((e) => Queue.fromJson(e)).toList();
  }

  Future<Queue> queue(int id) async =>
      Queue.fromJson(await _decode(await http.get(_u('/queues/$id'), headers: _headers))
          as Map<String, dynamic>);

  Future<Queue> createQueue(String name) async => Queue.fromJson(await _decode(
      await http.post(_u('/queues'), headers: _headers, body: jsonEncode({'name': name})))
      as Map<String, dynamic>);

  /// Order is versioned. A 409 means someone else reordered it; the caller gets the
  /// live state back so it can merge instead of overwriting.
  Future<Queue> replaceQueue(int id, int rev, List<int> trackIds) async {
    final r = await http.put(_u('/queues/$id'),
        headers: _headers, body: jsonEncode({'rev': rev, 'items': trackIds}));
    if (r.statusCode == 409) {
      final d = jsonDecode(r.body)['detail'] as Map<String, dynamic>;
      throw QueueConflict(Queue.fromJson(d['current'] as Map<String, dynamic>));
    }
    return Queue.fromJson(await _decode(r) as Map<String, dynamic>);
  }

  Future<Queue> addToQueue(int id, List<int> trackIds, {String mode = 'end'}) async =>
      Queue.fromJson(await _decode(await http.post(_u('/queues/$id/items'),
              headers: _headers, body: jsonEncode({'track_ids': trackIds, 'mode': mode})))
          as Map<String, dynamic>);

  /// The cursor is not versioned: the device that is playing is the authority.
  Future<void> setCursor(int id, {int? index, int? positionMs}) async {
    await _decode(await http.patch(_u('/queues/$id/cursor'),
        headers: _headers,
        body: jsonEncode({
          if (index != null) 'cursor_index': index,
          if (positionMs != null) 'position_ms': positionMs,
        })));
  }

  /// Settings only. Deliberately not PUT: that endpoint replaces the item list, and
  /// sending settings through it used to empty the queue.
  Future<Queue> updateQueueSettings(int id,
      {String? name, bool? shuffle, String? repeat}) async {
    final r = await http.patch(_u('/queues/$id'),
        headers: _headers,
        body: jsonEncode({
          if (name != null) 'name': name,
          if (shuffle != null) 'shuffle': shuffle,
          if (repeat != null) 'repeat': repeat,
        }));
    return Queue.fromJson(await _decode(r) as Map<String, dynamic>);
  }

  Future<void> deleteQueue(int id) async {
    await _decode(await http.delete(_u('/queues/$id'), headers: _headers));
  }

  Future<Queue> radio(int queueId, int seedTrackId, {int count = 5}) async =>
      Queue.fromJson(await _decode(await http.post(_u('/queues/$queueId/radio'),
              headers: _headers,
              body: jsonEncode({'seed_track_id': seedTrackId, 'count': count})))
          as Map<String, dynamic>);

  // ---------------- library ----------------
  Future<List<Playlist>> playlists() async {
    final d = await _decode(await http.get(_u('/playlists'), headers: _headers)) as List;
    return d.map((e) => Playlist.fromJson(e)).toList();
  }

  Future<Playlist> playlist(int id) async =>
      Playlist.fromJson(await _decode(await http.get(_u('/playlists/$id'), headers: _headers))
          as Map<String, dynamic>);

  Future<List<Track>> history() async {
    final d = await _decode(await http.get(_u('/history'), headers: _headers)) as List;
    return d.map((e) => Track.fromJson(e)).toList();
  }

  Future<void> recordListen(int trackId, int msPlayed, bool completed) async {
    await _decode(await http.post(_u('/listens'),
        headers: _headers,
        body: jsonEncode(
            {'track_id': trackId, 'ms_played': msPlayed, 'completed': completed})));
  }

  /// Server-sent events: a track finishing its download un-greys it everywhere.
  Stream<({String event, Map<String, dynamic> data})> events() async* {
    final req = http.Request('GET', _u('/events'))..headers.addAll(_headers);
    final res = await req.send();
    String? current;
    await for (final line
        in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('event: ')) {
        current = line.substring(7).trim();
      } else if (line.startsWith('data: ') && current != null) {
        final payload = jsonDecode(line.substring(6)) as Map<String, dynamic>;
        yield (event: current, data: payload);
      }
    }
  }
}

class QueueConflict implements Exception {
  final Queue current;
  QueueConflict(this.current);
}

String _platformName() {
  // Avoids dart:io so the same code compiles for web.
  return const bool.fromEnvironment('dart.library.html') ? 'web' : 'app';
}
