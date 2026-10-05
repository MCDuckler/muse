/// A song this phone fetches itself, on the server's word.
///
/// The server asks YouTube through the phone's door (exit_tunnel.dart) and so learns
/// where the audio is. That address works from the phone's own connection, and usually
/// not from the server's. So for a phone that says it can, the server sends the address
/// instead of carrying the song through the door. The phone fetches it, makes YouTube's
/// pieces one plain m4a (m4a_whole.dart), plays it from its own disk at once, and hands
/// the house its copy. The song crosses the phone's connection once down and once up,
/// instead of down, up, and down again from the house.
///
/// Nothing but dart:io and package:http, like the rest of what fetches.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'exit_tunnel.dart' show exitMayReach;
import 'm4a_whole.dart';

/// What the server sends: which job, which song, where it is, and how to ask for it.
class PullOrder {
  PullOrder({
    required this.job,
    required this.track,
    required this.url,
    this.headers = const {},
    this.bytes,
    this.chunk,
  });

  final int job;
  final int track;
  final Uri url;
  final Map<String, String> headers;
  final int? bytes;
  final int? chunk;

  static PullOrder? fromJson(Object? j) {
    if (j is! Map) return null;
    final job = j['job'], track = j['track'], url = Uri.tryParse('${j['url']}');
    if (job is! int || track is! int || url == null) return null;
    final headers = <String, String>{};
    final h = j['headers'];
    if (h is Map) {
      h.forEach((k, v) => headers['$k'] = '$v');
    }
    final bytes = j['bytes'], chunk = j['chunk'];
    return PullOrder(
      job: job,
      track: track,
      url: url,
      headers: headers,
      bytes: bytes is num ? bytes.toInt() : null,
      chunk: chunk is num ? chunk.toInt() : null,
    );
  }
}

class PullFailed implements Exception {
  PullFailed(this.why);
  final String why;
  @override
  String toString() => why;
}

class DoorPuller {
  DoorPuller({
    required this.baseUrl,
    required this.token,
    required this.keepDir,
    this.onArrived,
    this.onSaid,
    http.Client? client,
    HttpClient Function()? youtube,
  })  : _client = client ?? http.Client(),
        _youtube = youtube;

  final String Function() baseUrl;
  final String? Function() token;

  /// Where fetched songs are kept, to play from.
  final Future<Directory> Function() keepDir;

  /// Told when a song is on this disk, with where: the player starts it.
  final void Function(int track, String path)? onArrived;

  /// A line for the log.
  final void Function(String line)? onSaid;

  final http.Client _client;
  final HttpClient Function()? _youtube;

  /// Songs fetched here, by track: what the player plays from.
  final kept = <int, String>{};
  final _working = <int>{};
  int pulled = 0;
  int failed = 0;
  int bytes = 0;

  int get working => _working.length;

  Map<String, String> get _auth => {
        if (token() != null) 'Authorization': 'Bearer ${token()}',
      };

  /// Fetch, keep, hand in. Never throws: what went wrong is told to the server, which
  /// then has the song come through the door instead, or gives it back.
  Future<void> pull(PullOrder order) async {
    if (!_working.add(order.job)) return;
    try {
      final Uint8List raw;
      try {
        raw = await _fetch(order);
      } catch (e) {
        failed += 1;
        onSaid?.call('could not fetch track ${order.track} myself: $e');
        await _tell(order, '$e');
        return;
      }
      bytes += raw.length;
      // One plain file, which any player plays; as it came when it is not in pieces.
      final song = wholeM4a(raw) ?? raw;
      final dir = await keepDir();
      await dir.create(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}${order.track}.m4a');
      await file.writeAsBytes(song, flush: true);
      kept[order.track] = file.path;
      onArrived?.call(order.track, file.path);
      await _handIn(order, song, raw.length);
      pulled += 1;
    } finally {
      _working.remove(order.job);
    }
  }

  Future<Uint8List> _fetch(PullOrder order) async {
    final url = order.url;
    if (url.scheme != 'https' || !exitMayReach(url.host, 443)) {
      throw PullFailed('not somewhere this phone fetches from: ${url.host}');
    }
    // The phone's own connection, resolving names as the door does when it asks: the
    // address YouTube answered is the one this fetch comes from. Where it is not (a
    // phone that moved networks in between), YouTube says no and the server has the
    // song come through the door instead.
    final client = (_youtube ?? HttpClient.new)();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      // Always a piece at a time, with the piece named in the address as yt-dlp does
      // it. Asked for whole, YouTube hands a song over at the speed it plays: measured
      // 2026-10-05, the same 6 MB in 0.26 s asked by range, and not in a minute without.
      final total = order.bytes;
      final chunk = order.chunk ?? 10 * 1024 * 1024;
      final out = BytesBuilder(copy: false);
      for (var from = 0, n = 0; total == null || from < total; from += chunk, n++) {
        final to = (total != null && from + chunk > total ? total : from + chunk) - 1;
        final piece = await _get(client, url.replace(queryParameters: {
          ...url.queryParameters,
          'range': '$from-$to',
        }), order.headers);
        out.add(piece);
        if (total == null && (piece.length < chunk || n > 100)) break;
        if (total != null && piece.length != to - from + 1) {
          throw PullFailed('got ${out.length} bytes of $total');
        }
      }
      if (out.isEmpty) throw PullFailed('YouTube sent nothing');
      return out.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> _get(HttpClient client, Uri url, Map<String, String> headers) async {
    final req = await client.getUrl(url).timeout(const Duration(seconds: 30));
    headers.forEach((k, v) {
      // Not these: the client sets them itself, and a stale one breaks the request.
      if (const {'host', 'content-length', 'accept-encoding'}.contains(k.toLowerCase())) {
        return;
      }
      req.headers.set(k, v);
    });
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200 && res.statusCode != 206) {
      await res.drain<void>();
      throw PullFailed('YouTube said ${res.statusCode}');
    }
    final out = BytesBuilder(copy: false);
    await res.timeout(const Duration(seconds: 30)).forEach(out.add);
    return out.takeBytes();
  }

  Future<void> _handIn(PullOrder order, Uint8List song, int fetched) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final req = http.MultipartRequest(
            'POST', Uri.parse('${baseUrl()}/internal/exit/jobs/${order.job}/audio'))
          ..headers.addAll(_auth)
          ..fields['meta'] = jsonEncode({'track_id': order.track, 'bytes': fetched})
          ..files.add(http.MultipartFile.fromBytes('audio', song, filename: 'song.m4a'));
        final res = await _client.send(req).timeout(const Duration(minutes: 3));
        final body = await res.stream.bytesToString();
        if (res.statusCode == 200) {
          onSaid?.call('handed in track ${order.track}');
          return;
        }
        // Taken by somebody else, or not a song: asking again changes nothing.
        if (res.statusCode == 409 || res.statusCode == 400 || res.statusCode == 413) {
          onSaid?.call('the house did not take track ${order.track}: $body');
          return;
        }
      } catch (e) {
        onSaid?.call('handing in track ${order.track} failed: $e');
      }
      await Future<void>.delayed(Duration(seconds: 2 << attempt));
    }
  }

  Future<void> _tell(PullOrder order, String why) async {
    try {
      await _client
          .post(Uri.parse('${baseUrl()}/internal/exit/jobs/${order.job}/failed'),
              headers: {..._auth, 'Content-Type': 'application/json'},
              body: jsonEncode({'why': why}))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // The server gives it back by itself after a few minutes.
    }
  }

  /// Songs fetched here more than [age] ago, off the disk: by then the house has them.
  static Future<void> tidy(Directory dir, {Duration age = const Duration(hours: 12)}) async {
    if (!await dir.exists()) return;
    final cutoff = DateTime.now().subtract(age);
    await for (final f in dir.list()) {
      try {
        if (f is File && (await f.stat()).modified.isBefore(cutoff)) await f.delete();
      } catch (_) {}
    }
  }
}
