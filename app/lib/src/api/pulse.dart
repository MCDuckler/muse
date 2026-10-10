// The record's sound fifty times a second, as the house measured it (server/muse/
// pulse.py): five bands, the kick drum's onsets, everything's onsets, and each stem's
// level where the record is in parts. Each a byte a frame. The show reads it at the
// needle — see state/show/.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

class Pulse {
  const Pulse({required this.hz, required this.n, required this.channels});

  final int hz, n;

  /// Each channel's frames, 0 to 255, by name: sub low mid high air kick onset, and
  /// drums rest vocals where the stems were read.
  final Map<String, Uint8List> channels;

  static const empty = Pulse(hz: 50, n: 0, channels: {});

  bool has(String name) => channels.containsKey(name);
  bool get withStems => has('drums');
  Duration get length => Duration(microseconds: n * 1000000 ~/ hz);

  /// [name] at [at], 0 to 1, read between the two frames either side; nothing
  /// outside the record or for a channel it does not have.
  double at(String name, Duration at) {
    final c = channels[name];
    if (c == null || c.isEmpty) return 0;
    final x = at.inMicroseconds / 1e6 * hz;
    if (x < 0 || x >= c.length) return 0;
    final i = x.floor();
    final f = x - i;
    final a = c[i] / 255.0;
    final b = i + 1 < c.length ? c[i + 1] / 255.0 : a;
    return a + (b - a) * f;
  }

  /// The loudest of [name] over the [frames] before [at]: a kick that fell between
  /// two reads is still seen.
  double peak(String name, Duration at, {int frames = 2}) {
    final c = channels[name];
    if (c == null || c.isEmpty) return 0;
    final x = (at.inMicroseconds / 1e6 * hz).floor();
    var top = 0;
    for (var i = x - frames; i <= x; i++) {
      if (i >= 0 && i < c.length && c[i] > top) top = c[i];
    }
    return top / 255.0;
  }

  /// A pulse made of the peaks' three bands (peaks.py, 0–255 at [durationMs] over
  /// [low.length] slices): sub and low from the low band, high and air from the
  /// top, the kick as the low band's rise, the onsets as the sum's. For a house
  /// without pulse.py yet.
  factory Pulse.fromBands(List<int> low, List<int> mid, List<int> high, int durationMs) {
    final n = low.length;
    if (n == 0 || durationMs <= 0) return empty;
    final hz = (n * 1000 / durationMs).round().clamp(1, 1000);
    Uint8List rise(List<int> a, List<int>? b) {
      final out = Uint8List(n);
      var top = 1.0;
      final r = List<double>.filled(n, 0);
      for (var i = 1; i < n; i++) {
        final now = a[i] + (b == null ? 0 : b[i]), was = a[i - 1] + (b == null ? 0 : b[i - 1]);
        r[i] = (now - was).clamp(0, 510).toDouble();
        if (r[i] > top) top = r[i];
      }
      for (var i = 0; i < n; i++) {
        out[i] = (255 * math.pow(r[i] / top, 0.7)).round().clamp(0, 255);
      }
      return out;
    }
    Uint8List of(List<int> v) => Uint8List.fromList(v);
    return Pulse(hz: hz, n: n, channels: {
      'sub': of(low), 'low': of(low), 'mid': of(mid), 'high': of(high), 'air': of(high),
      'kick': rise(low, null), 'onset': rise(low, mid),
    });
  }

  /// The house's answer (pulse.pack): the names in order, the bytes channel after
  /// channel in base64.
  factory Pulse.fromJson(Map<String, dynamic> j) {
    final n = (j['n'] as num?)?.toInt() ?? 0;
    final names = [for (final c in (j['channels'] as List? ?? const [])) '$c'];
    final raw = base64Decode('${j['data'] ?? ''}');
    final channels = <String, Uint8List>{};
    for (var i = 0; i < names.length; i++) {
      final from = i * n, to = (i + 1) * n;
      if (to > raw.length) break;
      channels[names[i]] = Uint8List.sublistView(raw, from, to);
    }
    return Pulse(hz: (j['hz'] as num?)?.toInt() ?? 50, n: n, channels: channels);
  }

  /// The bytes of the house's answer, decoded — on an isolate, where the room's
  /// frames are not drawn.
  static Pulse fromBytes(Uint8List bytes) =>
      Pulse.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);

  Map<String, dynamic> toJson() {
    final names = channels.keys.toList();
    final b = BytesBuilder(copy: false);
    for (final name in names) {
      b.add(channels[name]!);
    }
    return {'version': 1, 'hz': hz, 'n': n, 'channels': names, 'data': base64Encode(b.takeBytes())};
  }
}
