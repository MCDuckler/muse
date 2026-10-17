// The booth's engine (native/engine/), through dart:ffi: every deck mixed in one
// audio callback off one sample clock, from records decoded whole into memory. See
// native/engine/src/we_engine.h for the calls, and ~/.claude/plans/
// wetowl-native-engine.md for why the booth has its own engine at all — in short:
// two libmpv players have two clocks, and SYNC between them was a controller chasing
// their reports; here a tempo ratio is exact and where a record is heard is known to
// the sample.
//
// Records are decoded by ffmpeg (already needed by the show) to 16-bit PCM at the
// engine's rate and handed over as they come, so a deck can play the start of a
// record while the end of it is still decoding.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../state/playback_log.dart';
import '../worker/tools.dart';

final class EngineDeckState extends Struct {
  @Double()
  external double heard;
  @Double()
  external double at;
  @Double()
  external double rate;
  @Double()
  external double length;
  @Double()
  external double loopA;
  @Double()
  external double loopB;
  @Double()
  external double phaseError;
  @Int64()
  external int moves;
  @Int32()
  external int playing;
  @Int32()
  external int looping;
  @Int32()
  external int synced;
  @Int32()
  external int braking;
  @Int32()
  external int ended;
  @Float()
  external double peakL;
  @Float()
  external double peakR;
}

/// How the audio thread keeps up (we_load_state).
final class EngineLoadState extends Struct {
  @Double()
  external double average;
  @Double()
  external double worst;
  @Int64()
  external int late;
  @Int32()
  external int faster;
  @Int32()
  external int period;
}

/// A deck's state as last read.
class DeckReading {
  const DeckReading({
    required this.heard,
    required this.at,
    required this.rate,
    required this.length,
    required this.loopA,
    required this.loopB,
    required this.phaseError,
    required this.moves,
    required this.playing,
    required this.looping,
    required this.synced,
    required this.braking,
    required this.ended,
    required this.peak,
  });
  final double heard, at, rate, length, loopA, loopB, phaseError;
  final int moves, ended;
  final bool playing, looping, synced, braking;
  final double peak;
}

typedef _VI = Void Function(Int32);
typedef _VII = Void Function(Int32, Int32);
typedef _VID = Void Function(Int32, Double);

class Engine {
  Engine._(this._lib, this.rate);

  static Engine? _it;
  static bool _tried = false;

  /// Turned off for this run (the tests, a desk that asked for the old engine).
  static bool disabled = false;

  /// The engine, started on first use — or null where there is none: not a desk, no
  /// library beside the app, no sound card, or [disabled].
  static Engine? get instance {
    if (_it != null || _tried || disabled) return _it;
    _tried = true;
    if (kIsWeb || !(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) return null;
    // WETOWL_ENGINE=mpv keeps the old engine; =native asks for this one even under a
    // test (the real-output probe).
    final asked = Platform.environment['WETOWL_ENGINE'];
    if (asked == 'mpv') return null;
    if (Platform.environment.containsKey('FLUTTER_TEST') && asked != 'native') return null;
    // It plays what ffmpeg decodes for it: without one, the old engine plays the files.
    if (!Tools.hasFfmpegNow()) {
      PlaybackLog.booth('engine: no ffmpeg here — the booth plays on libmpv');
      return null;
    }
    final lib = _open();
    if (lib == null) return null;
    final start = lib.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('we_start');
    final rc = start(0, 1);
    if (rc != 0) {
      final err = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('we_error')();
      PlaybackLog.booth('engine: would not start (${err.toDartString()}) — the booth plays on libmpv');
      return null;
    }
    final rate = lib.lookupFunction<Int32 Function(), int Function()>('we_rate')();
    _it = Engine._(lib, rate);
    PlaybackLog.booth('engine: running at $rate Hz, ${(_it!.latency * 1000).toStringAsFixed(1)} ms to the ear');
    _it!._watchLoad();
    return _it;
  }

  /// For a test: an engine with no sound card, rendered on demand ([render]).
  @visibleForTesting
  static Engine? offline({int rate = 48000, String? library}) {
    final lib = _open(library);
    if (lib == null) return null;
    final start = lib.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('we_start');
    if (start(rate, 0) != 0) return null;
    return _it = Engine._(lib, rate);
  }

  static DynamicLibrary? _open([String? path]) {
    final name = Platform.isWindows
        ? 'wetowl_engine.dll'
        : Platform.isMacOS
            ? 'libwetowl_engine.dylib'
            : 'libwetowl_engine.so';
    final exe = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    for (final p in [
      if (path != null) path,
      if (Platform.isLinux) '$exe${sep}lib$sep$name',
      if (Platform.isMacOS) '$exe$sep..${sep}Frameworks$sep$name',
      '$exe$sep$name',
      name,
    ]) {
      try {
        return DynamicLibrary.open(p);
      } catch (_) {}
    }
    debugPrint('engine: no $name here');
    return null;
  }

  final DynamicLibrary _lib;
  final int rate;

  late final double latency = _lib.lookupFunction<Double Function(), double Function()>('we_latency')();
  late final _load = _lib.lookupFunction<Void Function(Pointer<EngineLoadState>), void Function(Pointer<EngineLoadState>)>('we_load');
  late final _stretch = _lib.lookupFunction<_VI, void Function(int)>('we_stretch');

  /// Key lock on Rubber Band's faster stretcher (true) or its finer one: from now on,
  /// and no longer chosen by the load.
  void stretchFaster(bool on) => _stretch(on ? 1 : 0);

  /// How the audio thread keeps up: its load (time taken over time there was) on
  /// average and at worst since the last ask, the calls that ran late (each a gap
  /// in the sound), whether key lock was moved to the faster stretcher for it.
  ({double average, double worst, int late, bool faster, int period}) load() {
    final p = calloc<EngineLoadState>();
    try {
      _load(p);
      final r = p.ref;
      return (average: r.average, worst: r.worst, late: r.late, faster: r.faster != 0, period: r.period);
    } finally {
      calloc.free(p);
    }
  }

  /// Every 30 s while it is working, a line in the playback log: what a desk that
  /// stutters is doing, read off the house afterwards. And once, when the engine
  /// gives up the finer stretcher for this machine.
  void _watchLoad() {
    var lastLate = 0;
    var wasFaster = false;
    Timer.periodic(const Duration(seconds: 30), (_) {
      final l = load();
      if (l.faster && !wasFaster) {
        PlaybackLog.booth('engine: too much for this machine with key lock on the finer stretcher — moved to the faster one');
      }
      wasFaster = l.faster;
      final late = l.late - lastLate;
      lastLate = l.late;
      if (l.average < 0.02 && late == 0) return;
      PlaybackLog.booth('ENGINE load ${(l.average * 100).round()}% average, ${(l.worst * 100).round()}% at worst, '
          '$late late in 30 s (${l.late} in all), key lock ${l.faster ? 'faster' : 'finer'}, period ${l.period}');
    });
  }
  late final double Function() now = _lib.lookupFunction<Double Function(), double Function()>('we_now');

  late final _sourceNew = _lib.lookupFunction<Int32 Function(Int32, Int64), int Function(int, int)>('we_source_new');
  late final _sourceAppend =
      _lib.lookupFunction<Int32 Function(Int32, Pointer<Int16>, Int64), int Function(int, Pointer<Int16>, int)>('we_source_append');
  late final _sourceDone = _lib.lookupFunction<_VI, void Function(int)>('we_source_done');
  late final _sourceFrames = _lib.lookupFunction<Int64 Function(Int32), int Function(int)>('we_source_frames');
  late final _sourceFree = _lib.lookupFunction<_VI, void Function(int)>('we_source_free');

  late final _deckSource = _lib.lookupFunction<Void Function(Int32, Int32, Int32), void Function(int, int, int)>('we_deck_source');
  late final _deckSourceGain = _lib.lookupFunction<Void Function(Int32, Int32, Float, Float, Float, Float, Double),
      void Function(int, int, double, double, double, double, double)>('we_deck_source_gain');
  late final _play = _lib.lookupFunction<_VII, void Function(int, int)>('we_deck_play');
  late final _seek = _lib.lookupFunction<_VID, void Function(int, double)>('we_deck_seek');
  late final _rate = _lib.lookupFunction<_VID, void Function(int, double)>('we_deck_rate');
  late final _bend = _lib.lookupFunction<_VID, void Function(int, double)>('we_deck_bend');
  late final _keylock = _lib.lookupFunction<_VII, void Function(int, int)>('we_deck_keylock');
  late final _shift = _lib.lookupFunction<_VID, void Function(int, double)>('we_deck_shift');
  late final _beats =
      _lib.lookupFunction<Void Function(Int32, Pointer<Double>, Int32), void Function(int, Pointer<Double>, int)>('we_deck_beats');
  late final _sync = _lib.lookupFunction<Void Function(Int32, Int32, Int32, Double), void Function(int, int, int, double)>('we_deck_sync');
  late final _barOne = _lib.lookupFunction<_VII, void Function(int, int)>('we_deck_bar_one');
  late final _start = _lib
      .lookupFunction<Void Function(Int32, Int32, Int32, Double, Double), void Function(int, int, int, double, double)>('we_deck_start');
  late final _syncOffset = _lib.lookupFunction<_VID, void Function(int, double)>('we_deck_sync_offset');
  late final _align = _lib.lookupFunction<Void Function(Int32, Int32, Int32, Double), void Function(int, int, int, double)>('we_deck_align');
  late final _loop = _lib.lookupFunction<Void Function(Int32, Double, Double), void Function(int, double, double)>('we_deck_loop');
  late final _level = _lib.lookupFunction<Void Function(Int32, Float, Double), void Function(int, double, double)>('we_deck_level');
  late final _eq = _lib.lookupFunction<Void Function(Int32, Float, Float, Float, Double), void Function(int, double, double, double, double)>(
      'we_deck_eq');
  late final _filter = _lib.lookupFunction<Void Function(Int32, Float), void Function(int, double)>('we_deck_filter');
  late final _gate = _lib.lookupFunction<Void Function(Int32, Float, Double, Double), void Function(int, double, double, double)>('we_deck_gate');
  late final _echo = _lib.lookupFunction<Void Function(Int32, Float, Float, Double), void Function(int, double, double, double)>('we_deck_echo');
  late final _brake = _lib.lookupFunction<_VID, void Function(int, double)>('we_deck_brake');
  late final _read = _lib.lookupFunction<Void Function(Int32, Pointer<EngineDeckState>), void Function(int, Pointer<EngineDeckState>)>('we_deck_read');
  late final _position = _lib.lookupFunction<Double Function(Int32), double Function(int)>('we_deck_position');
  late final _render = _lib.lookupFunction<Void Function(Pointer<Float>, Int32, Pointer<Pointer<Float>>),
      void Function(Pointer<Float>, int, Pointer<Pointer<Float>>)>('we_render');

  final Pointer<EngineDeckState> _state = calloc<EngineDeckState>();

  // ------------------------------------------------------------------ decks
  void source(int deck, int slot, int source) => _deckSource(deck, slot, source);
  void sourceGain(int deck, int slot, double gain, {double drums = 1, double rest = 1, double vocals = 1, Duration ramp = Duration.zero}) =>
      _deckSourceGain(deck, slot, gain, drums, rest, vocals, ramp.inMicroseconds / 1e6);
  void play(int deck, bool on) => _play(deck, on ? 1 : 0);
  void seek(int deck, Duration to) => _seek(deck, to.inMicroseconds / 1e6);
  void setRate(int deck, double rate) => _rate(deck, rate);
  void bend(int deck, double factor) => _bend(deck, factor);
  void keylock(int deck, bool on) => _keylock(deck, on ? 1 : 0);
  void shift(int deck, double semitones) => _shift(deck, semitones);
  void sync(int deck, int? master, {int every = 1, Duration offset = Duration.zero}) =>
      _sync(deck, master ?? -1, every, offset.inMicroseconds / 1e6);
  void syncOffset(int deck, Duration offset) => _syncOffset(deck, offset.inMicroseconds / 1e6);
  void align(int deck, int master, {int every = 1, Duration offset = Duration.zero}) =>
      _align(deck, master, every, offset.inMicroseconds / 1e6);
  void barOne(int deck, int beat) => _barOne(deck, beat);

  /// Start [deck] in step with [master]: now (nearest its beat), or with [at] the
  /// moment the master is heard there.
  void start(int deck, int? master, {int every = 1, Duration? at, Duration offset = Duration.zero}) =>
      _start(deck, master ?? -1, every, at == null ? -1.0 : at.inMicroseconds / 1e6, offset.inMicroseconds / 1e6);
  void loop(int deck, Duration? a, Duration? b) =>
      _loop(deck, a == null ? 0 : a.inMicroseconds / 1e6, b == null ? 0 : b.inMicroseconds / 1e6);
  void level(int deck, double gain, {Duration ramp = Duration.zero}) => _level(deck, gain, ramp.inMicroseconds / 1e6);
  void eq(int deck, double low, double mid, double high, {Duration ramp = const Duration(milliseconds: 60)}) =>
      _eq(deck, low, mid, high, ramp.inMicroseconds / 1e6);
  void filter(int deck, double knob) => _filter(deck, knob);
  void gate(int deck, double depth, Duration period, Duration origin) =>
      _gate(deck, depth, period.inMicroseconds / 1e6, origin.inMicroseconds / 1e6);
  void echo(int deck, double send, double dry, Duration beat) => _echo(deck, send, dry, beat.inMicroseconds / 1e6);
  void brake(int deck, Duration over) => _brake(deck, over.inMicroseconds / 1e6);

  /// The record's beats for [deck]: their times, ascending.
  void beats(int deck, List<double> seconds) {
    if (seconds.length < 2) {
      _beats(deck, nullptr, 0);
      return;
    }
    final p = calloc<Double>(seconds.length);
    try {
      for (var i = 0; i < seconds.length; i++) {
        p[i] = seconds[i];
      }
      _beats(deck, p, seconds.length);
    } finally {
      calloc.free(p);
    }
  }

  DeckReading read(int deck) {
    _read(deck, _state);
    final s = _state.ref;
    return DeckReading(
      heard: s.heard,
      at: s.at,
      rate: s.rate,
      length: s.length,
      loopA: s.loopA,
      loopB: s.loopB,
      phaseError: s.phaseError,
      moves: s.moves,
      playing: s.playing != 0,
      looping: s.looping != 0,
      synced: s.synced != 0,
      braking: s.braking != 0,
      ended: s.ended,
      peak: s.peakL > s.peakR ? s.peakL : s.peakR,
    );
  }

  /// Where [deck] is heard right now, seconds of its record.
  double position(int deck) => _position(deck);

  /// Offline: [frames] of the master, and each deck's own.
  @visibleForTesting
  (Float32List, List<Float32List>) render(int frames, {int decks = 2}) {
    final out = calloc<Float>(frames * 2);
    final ptrs = calloc<Pointer<Float>>(4);
    final each = [for (var i = 0; i < 4; i++) calloc<Float>(frames * 2)];
    for (var i = 0; i < 4; i++) {
      ptrs[i] = each[i];
    }
    try {
      _render(out, frames, ptrs);
      return (
        Float32List.fromList(out.asTypedList(frames * 2)),
        [for (var i = 0; i < decks; i++) Float32List.fromList(each[i].asTypedList(frames * 2))],
      );
    } finally {
      calloc.free(out);
      calloc.free(ptrs);
      for (final p in each) {
        calloc.free(p);
      }
    }
  }

  // ------------------------------------------------------------------ records
  final _sources = <String, EngineSource>{};

  /// A record decoded into the engine — kept while anything holds it, shared between
  /// decks (the same record on both, a record loaded again). [key] says what it is
  /// (a track and a part); [input] is a file or a URL, with [headers] for a URL.
  EngineSource decode(String key, String input, {Map<String, String>? headers, int channels = 2}) {
    final had = _sources[key];
    if (had != null && !had.failed) {
      had._holds++;
      return had;
    }
    final s = EngineSource._(this, key, channels);
    _sources[key] = s;
    unawaited(s._run(input, headers));
    return s;
  }

  void _release(EngineSource s) {
    if (--s._holds > 0) return;
    if (_sources[s.key] == s) _sources.remove(s.key);
    s._kill();
    if (s.id > 0) _sourceFree(s.id);
  }
}

/// A record in the engine's memory, being decoded or decoded.
class EngineSource {
  EngineSource._(this._engine, this.key, this.channels) {
    id = _engine._sourceNew(channels, _engine.rate * 400);
  }

  final Engine _engine;
  final String key;
  final int channels;
  late final int id;
  int _holds = 1;
  Process? _ffmpeg;
  bool failed = false;
  String? trouble;
  final _done = Completer<void>();
  bool get done => _done.isCompleted;

  /// The decoding finished (or failed: see [failed]).
  Future<void> get finished => _done.future;

  /// Seconds decoded so far.
  double get seconds => _engine._sourceFrames(id) / _engine.rate;

  /// Let go of: freed once no deck plays it and nobody else holds it.
  void release() => _engine._release(this);

  /// Waits until [at] seconds and a little after are decoded, or the whole record is,
  /// or [within] has passed.
  Future<void> ready(double at, {double ahead = 8, Duration within = const Duration(seconds: 20)}) async {
    final until = DateTime.now().add(within);
    while (!done && seconds < at + ahead && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  void _kill() {
    _ffmpeg?.kill();
    _ffmpeg = null;
  }

  Future<void> _run(String input, Map<String, String>? headers) async {
    final began = DateTime.now();
    Pointer<Int16> buf = nullptr;
    var cap = 0;
    try {
      final ffmpeg = await Tools.ffmpegCommand();
      final args = [
        '-v', 'error', '-nostdin',
        if (headers != null && headers.isNotEmpty && input.startsWith('http'))
          ...['-headers', headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join()],
        '-i', input,
        '-f', 's16le', '-acodec', 'pcm_s16le', '-ac', '$channels', '-ar', '${_engine.rate}', 'pipe:1',
      ];
      final p = await Process.start(ffmpeg, args);
      _ffmpeg = p;
      final err = StringBuffer();
      final errs = p.stderr.listen((d) => err.write(String.fromCharCodes(d)));
      final frameBytes = channels * 2;
      final carry = BytesBuilder(copy: false);
      await for (final chunk in p.stdout) {
        carry.add(chunk);
        final all = carry.takeBytes();
        final whole = all.length - all.length % frameBytes;
        if (whole > 0) {
          if (whole > cap) {
            if (buf != nullptr) calloc.free(buf);
            cap = whole * 2;
            buf = calloc<Int16>(cap ~/ 2);
          }
          buf.cast<Uint8>().asTypedList(whole).setAll(0, Uint8List.sublistView(all, 0, whole));
          if (_engine._sourceAppend(id, buf, whole ~/ frameBytes) != 0) {
            throw StateError('the engine is out of memory');
          }
        }
        if (whole < all.length) carry.add(Uint8List.sublistView(all, whole));
      }
      final code = await p.exitCode;
      await errs.cancel();
      _ffmpeg = null;
      if (code != 0 && seconds < 1) {
        failed = true;
        trouble = 'ffmpeg ($code): ${err.toString().trim()}';
      }
      debugPrint('engine: $key decoded, ${seconds.toStringAsFixed(1)} s in '
          '${DateTime.now().difference(began).inMilliseconds} ms');
    } catch (e) {
      failed = true;
      trouble = '$e';
      PlaybackLog.booth('engine: could not decode $key: $e');
    } finally {
      if (buf != nullptr) calloc.free(buf);
      _engine._sourceDone(id);
      if (!_done.isCompleted) _done.complete();
    }
  }
}
