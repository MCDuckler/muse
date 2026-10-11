// MilkDrop, as a picture for the stage: the wetowl-milk helper (native/milk/) run
// as a child, the way the camera runs ffmpeg, fed the records' own sound and the
// show's numbers, read for its frames.
//
// The helper is projectM — the open MilkDrop — with WetOwl's patch, which lets
// preset code read the show by name: wo_kick, wo_drop, wo_bar and the rest of
// [varsOf]. Every engine tick sends those and the PCM at the needle (deck_pcm.dart);
// the helper draws at its own pace and writes raw frames on its stdout, of which
// only the latest is kept. Which preset is on is the director's (milk_director.dart)
// or the hands'; the library (milk_library.dart) knows what there is.
//
// Runs only while something is looking (the milk scene on the stage, the window
// asked for it); nothing is written anywhere but the helper's pipes.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'deck_pcm.dart';
import 'milk_director.dart';
import 'milk_library.dart';
import 'show_state.dart';

class MilkFeed extends ChangeNotifier {
  MilkFeed._();

  /// The one feed of this process.
  static final shared = MilkFeed._();

  static const width = 960, height = 540;
  static const fps = 60;

  final library = MilkLibrary();
  late final director = MilkDirector(this);
  final pcm = DeckPcm();

  Process? _helper;
  Future<void>? _starting;

  /// On, or on its way: a scene asks every frame, and the first start copies the
  /// shipped presets out, which takes a moment — not one helper per frame.
  bool get running => _helper != null || _starting != null;

  /// Kept on whatever is showing: the window was asked for it (`--milk`).
  bool pinned = false;
  String? trouble;

  /// The helper's last word on a preset that would not load: for the maker.
  final presetTrouble = ValueNotifier<String?>(null);

  /// The preset on, by name, as the helper confirmed it.
  String? presetName;

  /// The preset on, as the library knows it (null while one is being edited).
  MilkPreset? preset;

  ui.Image? frame;
  int frames = 0;
  bool _ready = false;

  bool _decoding = false;
  StreamSubscription<List<int>>? _sub;
  IOSink? _in;

  /// Where the helper is: beside the app (the bundle), under its lib/, named by
  /// WETOWL_MILK, or the development build. Null where there is none — a Mac, a
  /// Windows desk, for now.
  static String? helperPath() {
    final env = Platform.environment['WETOWL_MILK'];
    if (env != null && File(env).existsSync()) return env;
    if (kIsWeb) return null;
    final exe = File(Platform.resolvedExecutable).parent.path;
    final name = Platform.isWindows ? 'wetowl-milk.exe' : 'wetowl-milk';
    final sep = Platform.pathSeparator;
    final cwd = Directory.current.path;
    for (final c in [
      '$exe$sep$name',
      '$exe${sep}lib$sep$name',
      '$cwd${sep}native${sep}milk${sep}build$sep$name',
      '$cwd${sep}app${sep}native${sep}milk${sep}build$sep$name',
    ]) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Whether there is a helper to run at all.
  bool get available => helperPath() != null;

  Future<void> start() => _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (_helper != null) return;
    trouble = null;
    // Never under a test: see CameraFeed.start.
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      trouble = 'no MilkDrop in a test';
      return;
    }
    final path = helperPath();
    if (path == null) {
      trouble = 'wetowl-milk is not here';
      notifyListeners();
      return;
    }
    try {
      await library.ready();
      final proc = await Process.start(path, ['--size', '${width}x$height', '--fps', '$fps', '--textures', library.texturesDir]);
      _helper = proc;
      _in = proc.stdin;
      _frameBuf = null;
      _cursor = 0;
      _ready = false;
      _sub = proc.stdout.listen(_arrived, onDone: _ended);
      proc.stderr.transform(const SystemEncoding().decoder).transform(const LineSplitter()).listen(_said);
      unawaited(proc.exitCode.then((code) {
        if (_helper == proc) debugPrint('milk: wetowl-milk left with $code${trouble == null ? '' : ': $trouble'}');
        _ended();
      }));
      pcm.reset();
      director.started();
      notifyListeners();
    } catch (e) {
      trouble = 'wetowl-milk: $e';
      _helper = null;
      notifyListeners();
    }
  }

  void stop() {
    final proc = _helper;
    _helper = null;
    _send('quit');
    unawaited(_sub?.cancel());
    _sub = null;
    _in = null;
    proc?.kill();
    _frameBuf = null;
    _cursor = 0;
    _ready = false;
    notifyListeners();
  }

  void _ended() {
    if (_helper == null) return;
    _helper = null;
    _in = null;
    trouble ??= 'MilkDrop stopped';
    notifyListeners();
  }

  void _said(String line) {
    if (line == 'ready') {
      _ready = true;
      return;
    }
    if (line.startsWith('preset ok ')) {
      presetName = line.substring(10);
      debugPrint('milk: $line');
      presetTrouble.value = null;
      notifyListeners();
    } else if (line.startsWith('preset failed ')) {
      presetTrouble.value = line.substring(14);
      notifyListeners();
    } else if (line.startsWith('egl')) {
      // The renderer, for the log.
      debugPrint('milk: $line');
    } else if (line.trim().isNotEmpty) {
      trouble = line;
    }
  }

  void _send(String line, [List<int>? payload]) {
    final sink = _in;
    if (sink == null) return;
    try {
      sink.write('$line\n');
      if (payload != null) sink.add(payload);
    } catch (_) {
      // The pipe is gone: the exit will say so.
    }
  }

  // ---------------------------------------------------------------- the hands
  /// A preset by file: a cut, or a blend into it.
  void load(MilkPreset preset, {bool soft = false}) {
    this.preset = preset;
    _send('${soft ? 'preset-soft' : 'preset'} ${preset.path}');
    library.noteUsed(preset);
  }

  /// A preset as text (the maker's), held while it is being worked on.
  void loadText(String text, {bool soft = false}) {
    preset = null;
    final bytes = utf8Bytes(text);
    _send('${soft ? 'data-soft' : 'data'} ${bytes.length}', bytes);
  }

  static Uint8List utf8Bytes(String s) => Uint8List.fromList(const SystemEncoding().encode(s));

  void lock(bool on) => _send('lock ${on ? 1 : 0}');

  // ---------------------------------------------------------------- the engine
  /// Every tick of the show's engine: the numbers, the sound.
  void tick(ShowState st) {
    if (_helper == null || !_ready) return;
    final vars = varsOf(st);
    _send('vars ${vars.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(4)}').join(' ')}');
    final samples = pcm.slice(st);
    if (samples != null && samples.isNotEmpty) {
      _send('pcm ${samples.length}', samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes));
    }
  }

  /// What preset code can read, by name. Everything the show knows that a picture
  /// could want, 0..1 unless said; see docs/milk-presets.md.
  static Map<String, double> varsOf(ShowState st) {
    final f = st.flat;
    final m = st.master;
    double g(String k, [double d = 0]) => f[k] ?? d;
    final mk = 'master';
    return {
      'wo_beat': m.beatPhase,
      'wo_bar': m.barPhase,
      'wo_phrase': m.phrasePhase,
      'wo_beat_in_bar': (m.beatInBar ?? 0).toDouble(),
      'wo_bar_index': (m.barIndex ?? 0).toDouble(),
      'wo_bpm': m.bpm ?? 0,
      'wo_playing': m.playing ? 1 : 0,
      'wo_kick': g('$mk.audio.kick'),
      'wo_onset': g('$mk.audio.onset'),
      'wo_sub': g('$mk.audio.sub'),
      'wo_low': g('$mk.audio.low'),
      'wo_mid': g('$mk.audio.mid'),
      'wo_high': g('$mk.audio.high'),
      'wo_air': g('$mk.audio.air'),
      'wo_drums': g('$mk.audio.drums'),
      'wo_vocals': g('$mk.audio.vocals'),
      'wo_hit_kick': g('dyn.hit.kick'),
      'wo_hit_snare': g('dyn.hit.snare'),
      'wo_hit_top': g('dyn.hit.top'),
      'wo_beat_decay': g('dyn.beat.decay'),
      'wo_bar_decay': g('dyn.bar.decay'),
      'wo_downbeat': g('dyn.downbeat'),
      'wo_exposure': g('dyn.exposure', 0.7),
      'wo_loud': g('dyn.loud'),
      'wo_band_low': g('dyn.band.low'),
      'wo_band_mid': g('dyn.band.mid'),
      'wo_band_high': g('dyn.band.high'),
      'wo_energy': m.energy,
      'wo_build': m.buildK,
      'wo_drop': g('$mk.drop.near'),
      'wo_drop_beats': m.dropBeatsAway ?? 999,
      'wo_breakdown': m.breakdown ? 1 : 0,
      'wo_section': _sectionCode(m.section),
      'wo_section_k': m.sectionK,
      'wo_vocal': m.vocal,
      'wo_hook': m.hook ? 1 : 0,
      'wo_hit': st.macros.hit,
      'wo_intensity': st.macros.intensity,
      'wo_hue': st.palette.primary.hue / 360,
      'wo_hue2': st.palette.secondary.hue / 360,
      'wo_hue3': st.palette.accent.hue / 360,
      'wo_mix': st.mix.on ? st.mix.k : 0,
      'wo_level_a': st.a.level,
      'wo_level_b': st.b.level,
      'wo_cam_motion': g('cam.motion'),
      'wo_cam_x': g('cam.x', 0.5),
      'wo_cam_y': g('cam.y', 0.5),
    };
  }

  /// The section as a number: 0 none, 1 intro, 2 verse, 3 build, 4 drop, 5 chorus,
  /// 6 breakdown, 7 outro, 8 other.
  static double _sectionCode(String? s) => switch (s) {
        null => 0,
        'intro' => 1,
        'verse' => 2,
        'build' => 3,
        'drop' => 4,
        'chorus' => 5,
        'breakdown' || 'break' => 6,
        'outro' => 7,
        _ => 8,
      };

  // ---------------------------------------------------------------- the frames
  static const _header = 16;
  final _head = Uint8List(_header);
  Uint8List? _frameBuf;
  int _cursor = 0, _frameW = 0, _frameH = 0;

  /// Each chunk off the pipe copied once, into the frame being gathered: a frame
  /// is two megabytes in thirty-odd reads, and gathering it by appending (and
  /// copying what was there each time) was most of the stage's frame.
  void _arrived(List<int> chunk) {
    final c = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    var off = 0;
    while (off < c.length) {
      final buf = _frameBuf;
      if (buf == null) {
        // The header first: what size the frame is.
        final n = math.min(_header - _cursor, c.length - off);
        _head.setRange(_cursor, _cursor + n, c, off);
        _cursor += n;
        off += n;
        if (_cursor < _header) return;
        final bd = ByteData.sublistView(_head);
        _cursor = 0;
        if (bd.getUint32(0, Endian.little) != 0x4b4c494d) {
          // Out of step: the helper is restarted rather than searched.
          trouble = 'MilkDrop frames out of step';
          stop();
          return;
        }
        _frameW = bd.getUint32(4, Endian.little);
        _frameH = bd.getUint32(8, Endian.little);
        _frameBuf = Uint8List(_frameW * _frameH * 4);
        continue;
      }
      final n = math.min(buf.length - _cursor, c.length - off);
      buf.setRange(_cursor, _cursor + n, c, off);
      _cursor += n;
      off += n;
      if (_cursor < buf.length) return;
      _frameBuf = null;
      _cursor = 0;
      if (_decoding) continue;  // a frame still on its way: this one is dropped
      _decoding = true;
      ui.decodeImageFromPixels(buf, _frameW, _frameH, ui.PixelFormat.rgba8888, (img) {
        frame?.dispose();
        frame = img;
        frames++;
        _decoding = false;
        notifyListeners();
      });
    }
  }

  /// The numbers for the engine, by name.
  Map<String, double> get numbers => {
        'milk.ok': available ? 1 : 0,
        'milk.on': running && frame != null ? 1 : 0,
      };

  @override
  void dispose() {
    stop();
    frame?.dispose();
    presetTrouble.dispose();
    super.dispose();
  }
}
