// The records' own sound, for MilkDrop: each deck's record decoded whole (ffmpeg,
// 16-bit mono at 44.1 kHz, in memory), and every tick the stretch from where the
// needle was to where it is, at the channel's level, the two decks summed.
//
// Decoded rather than tapped off the engine: the show's clock is the ear's — the
// deck's position less the stretcher's latency plus the performer's offset — and a
// slice read at that clock lands on the picture where the beat does, on any
// desk, with no audio capture to set up. The stretcher's tempo shows as the slice
// growing and shrinking, which is what the ear hears too.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../worker/tools.dart';

import 'show_state.dart';

/// Where a record's sound is to be read from: a file here, or the stream with its
/// headers.
typedef PcmSource = ({String url, Map<String, String> headers})? Function(int trackId);

class DeckPcm {
  static const rate = 44100;

  /// Set by the engine: how to reach a record. Without one (a stage in another
  /// process) the deck's own stream is read, with [headers].
  PcmSource? source;
  Map<String, String> headers = const {};

  final _records = <int, Int16List>{};
  final _loading = <int>{};

  /// When a record last failed to decode, by track: not asked again for [retryAfter].
  /// Without this a failure was asked again the next frame — a new isolate and a new
  /// ffmpeg sixty times a second, which froze the desk (a desk with no ffmpeg on its
  /// path failed every one of them).
  final _failed = <int, DateTime>{};
  static const retryAfter = Duration(minutes: 1);

  /// No ffmpeg to run at all: nothing is asked until the app is started again.
  bool _noFfmpeg = false;
  bool get noFfmpeg => _noFfmpeg;

  /// How many decodes were started, and whether one is under way: for a test.
  @visibleForTesting
  int decodes = 0;
  @visibleForTesting
  bool get busy => _loading.isNotEmpty;
  final _order = <int>[];

  /// The sample each deck was last read to, by deck name.
  final _at = <String, int>{};

  void reset() => _at.clear();

  /// The samples since the last tick, both decks through their faders; null while
  /// nothing is decoded yet.
  Int16List? slice(ShowState st) {
    Int32List? mix;
    var longest = 0;
    for (final d in [st.a, st.b]) {
      final id = d.trackId;
      if (id == null || !d.playing || d.level <= 0.001) {
        _at.remove(d.name);
        continue;
      }
      final rec = _records[id];
      if (rec == null) {
        _ask(id, d.streamUrl);
        continue;
      }
      final now = (d.position.inMicroseconds * rate / 1e6).round().clamp(0, rec.length);
      var from = _at[d.name];
      // A jump (a seek, a loop, the first read): start a frame back rather than
      // sending the whole leap.
      if (from == null || from > now || now - from > rate ~/ 4) from = (now - rate ~/ 60).clamp(0, now);
      _at[d.name] = now;
      final n = now - from;
      if (n <= 0) continue;
      mix ??= Int32List(n);
      if (n > mix.length) {
        final bigger = Int32List(n);
        bigger.setRange(0, mix.length, mix);
        mix = bigger;
      }
      if (n > longest) longest = n;
      final gain = (d.level * 32767 / 32767).clamp(0.0, 1.0);
      for (var i = 0; i < n; i++) {
        mix[i] += (rec[from + i] * gain).round();
      }
    }
    if (mix == null) return null;
    final out = Int16List(longest);
    for (var i = 0; i < longest; i++) {
      out[i] = mix[i].clamp(-32768, 32767);
    }
    return out;
  }

  void _ask(int id, String? streamUrl) {
    if (_noFfmpeg || _loading.contains(id)) return;
    final failed = _failed[id];
    if (failed != null && DateTime.now().difference(failed) < retryAfter) return;
    final src = source?.call(id) ?? (streamUrl == null ? null : (url: streamUrl, headers: headers));
    if (src == null) return;
    _loading.add(id);
    decodes++;
    unawaited(_decode(id, src.url, src.headers).whenComplete(() => _loading.remove(id)));
  }

  Future<void> _decode(int id, String url, Map<String, String> headers) async {
    try {
      final args = [
        '-hide_banner', '-loglevel', 'error', '-nostdin',
        // The header only where the address does not carry its own key: on ffmpeg's
        // command line the bearer token is readable by anything on this computer that
        // can list processes, and a signed stream address (?k=) needs no token.
        if (url.startsWith('http') && headers.isNotEmpty && !Uri.parse(url).queryParameters.containsKey('k'))
          ...['-headers', headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join()],
        '-i', url,
        '-vn', '-f', 's16le', '-ac', '1', '-ar', '$rate', '-',
      ];
      final ffmpeg = await Tools.ffmpegCommand();
      // Read on an isolate of its own: a record is some 25 MB through ffmpeg's pipe,
      // which on Windows is 1 KB wide and read 64 KB a turn — four hundred turns of
      // the UI isolate's loop, on the stage's time. The bytes come back whole.
      final (code, bytes) = await Isolate.run(() async {
        final proc = await Process.start(ffmpeg, args);
        final chunks = BytesBuilder(copy: false);
        proc.stderr.drain<void>().ignore();
        await for (final c in proc.stdout) {
          chunks.add(c);
        }
        return (await proc.exitCode, chunks.takeBytes());
      }, debugName: 'milk pcm');
      if (code != 0 && bytes.isEmpty) {
        debugPrint('milk pcm: ffmpeg $code for $id');
        _failed[id] = DateTime.now();
        return;
      }
      _failed.remove(id);
      _records[id] = Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 2);
      _order.remove(id);
      _order.add(id);
      // Two records on the decks and one more coming: the rest let go.
      while (_order.length > 3) {
        _records.remove(_order.removeAt(0));
      }
    } on ProcessException catch (e) {
      // Not the exception itself: its words carry the command, and the command
      // carries the stream's bearer token.
      debugPrint('milk pcm: no ffmpeg to run (${e.message}); MilkDrop goes without the records\' sound');
      _noFfmpeg = true;
    } catch (e) {
      debugPrint('milk pcm: ${e.runtimeType} for $id');
      _failed[id] = DateTime.now();
    }
  }
}
