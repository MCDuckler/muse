// The sounds a pad can hold, and where each one's file is.
//
// A sample is a short sound with an id. The kit's are made by the booth itself
// (fx_sounds.dart) and have negative ids, so they exist on every device without a
// server; the user's own are files — dropped on a pad, picked, or cut from a record —
// and later the server's, by its id.

import 'package:flutter/foundation.dart';

import '../fx_sink_none.dart' if (dart.library.io) '../fx_sink_io.dart' as disk;
import '../fx_sink_none.dart' if (dart.library.js_interop) '../fx_sink_web.dart' as web;
import '../fx_sounds.dart';

/// Where a sample's sound comes from.
sealed class SampleSource {
  const SampleSource();
}

/// Rendered by the booth: one of its own sounds, so many seconds of it.
class KitSource extends SampleSource {
  const KitSource(this.sound, {required this.seconds, this.beat = 0.5});
  final FxSound sound;
  final double seconds;

  /// The beat the sound's gating is counted in, seconds. The kit's are made at 120.
  final double beat;
}

/// A file on this device.
class FileSource extends SampleSource {
  const FileSource(this.path);
  final String path;
}

/// A sample the server has, by its id — fetched to a file before it can play.
class ServerSource extends SampleSource {
  const ServerSource(this.id);
  final int id;
}

/// A sound with a name and a length.
class Sample {
  const Sample({required this.id, required this.name, required this.length, required this.source});

  final int id;
  final String name;
  final Duration length;
  final SampleSource source;

  @override
  String toString() => 'Sample #$id $name ${length.inMilliseconds} ms';
}

/// The sounds every board has: the booth's own, rendered on the device.
abstract final class SampleKit {
  static const riser = -1, sweepUp = -2, sweepDown = -3, hydrant = -4, impact = -5;

  static final all = <Sample>[
    const Sample(
        id: riser,
        name: 'Riser · 4 bars',
        length: Duration(seconds: 8),
        source: KitSource(FxSound.riser, seconds: 8)),
    const Sample(
        id: sweepUp,
        name: 'Sweep up',
        length: Duration(milliseconds: 1000),
        source: KitSource(FxSound.sweepUp, seconds: 1)),
    const Sample(
        id: sweepDown,
        name: 'Sweep down',
        length: Duration(milliseconds: 1500),
        source: KitSource(FxSound.sweepDown, seconds: 1.5)),
    const Sample(
        id: hydrant,
        name: 'Hydrant',
        length: Duration(seconds: 2),
        source: KitSource(FxSound.hydrant, seconds: 2)),
    const Sample(
        id: impact,
        name: 'Impact',
        length: Duration(milliseconds: 1000),
        source: KitSource(FxSound.impact, seconds: 1)),
  ];

  static Sample? byId(int id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// Finds samples by id, and puts each one's sound where a player can take it.
///
/// The kit's are rendered on first use and kept as files for the session; the
/// user's own are looked up in [known]. A sampler asks this for a path and nothing
/// else.
class SampleLibrary {
  SampleLibrary({
    Future<String?> Function(Uint8List wav, String key)? sink,
    this.fetch,
  }) : _sink = sink;

  final Future<String?> Function(Uint8List wav, String key)? _sink;

  /// Brings a server sample's sound to this device, as a file path. Null where
  /// there is no server, or no disk.
  final Future<String?> Function(int id)? fetch;

  /// A sample as the server lists it.
  static Sample fromServer(Map<String, dynamic> j) => Sample(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? 'Sample',
        length: Duration(milliseconds: (j['duration_ms'] as num?)?.toInt() ?? 0),
        source: ServerSource((j['id'] as num).toInt()),
      );

  /// The user's own, as the server lists them, with their shapes.
  void takeServerList(List<Map<String, dynamic>> list) {
    known.clear();
    for (final j in list) {
      final s = fromServer(j);
      known[s.id] = s;
      final shape = j['shape'];
      if (shape is List && shape.isNotEmpty) {
        peaks[s.id] = Float32List.fromList([for (final v in shape) ((v as num).toDouble() / 255).clamp(0.0, 1.0)]);
      }
    }
  }

  /// The user's own samples, by id, as this device knows them.
  final known = <int, Sample>{};

  /// Each sample's shape, once it has been seen: 128 bins, 0..1.
  final peaks = <int, Float32List>{};

  Sample? byId(int id) => id < 0 ? SampleKit.byId(id) : known[id];

  /// Every sample there is to pick from, the kit first.
  List<Sample> get all => [...SampleKit.all, ...known.values];

  /// A file (or, in a browser, a URL) for [sample], or null where this device can
  /// put it nowhere.
  Future<String?> pathFor(Sample sample) async {
    switch (sample.source) {
      case FileSource(:final path):
        return path;
      case KitSource(:final sound, :final seconds, :final beat):
        final key = 'kit-${sound.name}-${(seconds * 1000).round()}ms-${(beat * 1000).round()}';
        final floats = renderFx(sound, seconds: seconds, beat: beat);
        peaks[sample.id] ??= shapeOf(floats);
        return (_sink ?? _defaultSink)(fxWav(floats), key);
      case ServerSource(:final id):
        return fetch?.call(id);
    }
  }

  static Future<String?> _defaultSink(Uint8List wav, String key) =>
      kIsWeb ? web.fxSource(wav, key) : disk.fxSource(wav, key);

  /// The shape of interleaved stereo [floats] in [bins] bins: each bin's peak, with
  /// the loudest at 1.
  static Float32List shapeOf(Float32List floats, {int bins = 128}) {
    final out = Float32List(bins);
    final frames = floats.length ~/ 2;
    if (frames == 0) return out;
    var loudest = 0.0;
    for (var b = 0; b < bins; b++) {
      final from = (b * frames / bins).floor(), to = ((b + 1) * frames / bins).floor();
      var peak = 0.0;
      for (var i = from; i < to; i++) {
        final l = floats[i * 2].abs(), r = floats[i * 2 + 1].abs();
        if (l > peak) peak = l;
        if (r > peak) peak = r;
      }
      out[b] = peak;
      if (peak > loudest) loudest = peak;
    }
    if (loudest > 0) {
      for (var b = 0; b < bins; b++) {
        out[b] /= loudest;
      }
    }
    return out;
  }
}
