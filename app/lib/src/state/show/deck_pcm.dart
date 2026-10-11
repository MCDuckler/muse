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
    if (_loading.contains(id)) return;
    final src = source?.call(id) ?? (streamUrl == null ? null : (url: streamUrl, headers: headers));
    if (src == null) return;
    _loading.add(id);
    unawaited(_decode(id, src.url, src.headers).whenComplete(() => _loading.remove(id)));
  }

  Future<void> _decode(int id, String url, Map<String, String> headers) async {
    try {
      final args = [
        '-hide_banner', '-loglevel', 'error', '-nostdin',
        if (url.startsWith('http') && headers.isNotEmpty) ...['-headers', headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join()],
        '-i', url,
        '-vn', '-f', 's16le', '-ac', '1', '-ar', '$rate', '-',
      ];
      final proc = await Process.start(await Tools.ffmpegCommand(), args);
      final chunks = BytesBuilder(copy: false);
      proc.stderr.drain<void>().ignore();
      await for (final c in proc.stdout) {
        chunks.add(c);
      }
      final code = await proc.exitCode;
      final bytes = chunks.takeBytes();
      if (code != 0 && bytes.isEmpty) {
        debugPrint('milk pcm: ffmpeg $code for $id');
        return;
      }
      _records[id] = Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 2);
      _order.remove(id);
      _order.add(id);
      // Two records on the decks and one more coming: the rest let go.
      while (_order.length > 3) {
        _records.remove(_order.removeAt(0));
      }
    } catch (e) {
      debugPrint('milk pcm: $e');
    }
  }
}
