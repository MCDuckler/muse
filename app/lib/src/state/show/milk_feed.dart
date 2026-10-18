// MilkDrop, as a picture for the stage: the wetowl-milk helper (native/milk/) run
// as a child, the way the camera runs ffmpeg, fed the records' own sound and the
// show's numbers, read for its frames.
//
// The helper is projectM — the open MilkDrop — with WetOwl's patch, which lets
// preset code read the show by name: wo_kick, wo_drop, wo_bar and the rest of
// [varsOf]. Every engine tick sends those and the PCM at the needle (deck_pcm.dart);
// the helper draws at its own pace and writes raw frames on its stdout, read on an
// isolate of their own (milk_pipe.dart), the newest handed over as the last is
// taken. Which preset is on is the director's (milk_director.dart) or the hands';
// the library (milk_library.dart) knows what there is.
//
// Listeners hear what changes by the moment — on, off, the preset, trouble; the
// frames have [shown] of their own, for a painter, not a widget tree.
//
// Runs only while something is looking (the milk scene on the stage, the window
// asked for it); nothing is written anywhere but the helper's pipes.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'deck_pcm.dart';
import 'milk_director.dart';
import 'milk_library.dart';
import 'milk_pipe.dart';
import 'show_state.dart';

/// Where MilkDrop draws when it is not a helper of its own: the native stage's GL
/// context (ui/show/native_stage.dart), told the helper's commands in-process.
class MilkInStage {
  const MilkInStage({required this.send, required this.said});
  final void Function(String line, Uint8List? payload) send;

  /// What it said since the last ask, a line each.
  final String Function() said;
}

class MilkFeed extends ChangeNotifier {
  MilkFeed._();

  /// Where MilkDrop is drawn while the native stage draws a scene of it: there, in
  /// its context, and no helper. Its frames are the stage's own — [frame] stays
  /// empty meanwhile. Chosen by who asks ([want]): the native stage, while it has
  /// asked within two seconds; the helper otherwise.
  MilkInStage? inStage;
  bool _staged = false;
  DateTime _stageWanted = DateTime.fromMillisecondsSinceEpoch(0);

  /// The one feed of this process.
  static final shared = MilkFeed._();

  static const width = 960, height = 540;
  static const fps = 60;

  /// What the booth's small preview of the stage gets by on, where nothing here
  /// wants more: a quarter of the picture at half the rate. The stage in a window
  /// of its own runs a helper of its own, and two at full size was the GPU's
  /// whole evening.
  static const smallWidth = 480, smallHeight = 270, smallFps = 30;

  final library = MilkLibrary();
  late final director = MilkDirector(this);
  final pcm = DeckPcm();

  MilkPipe? _helper;
  Future<void>? _starting;

  /// On, or on its way: a scene asks every frame, and the first start copies the
  /// shipped presets out, which takes a moment — not one helper per frame.
  bool get running => _helper != null || _starting != null || _staged;

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

  /// The frames come, by count: for a painter of them ([frame] is the latest).
  final shown = ValueNotifier<int>(0);
  int get frames => shown.value;

  final _att = [1.0, 1.0, 1.0];
  bool _ready = false;

  /// A stage, the browser or the maker looked last at this time; the booth's
  /// preview does not count.
  DateTime _wholeWanted = DateTime.fromMillisecondsSinceEpoch(0);
  bool _whole = true;

  /// Anything at all looked last at this time: the preview counts here.
  DateTime _anyWanted = DateTime.now();
  bool _idle = false;

  /// What the helper renders at while nothing draws it — a minimised stage, a
  /// hidden window: a frame now and then, so it is warm when it is looked at again,
  /// not sixty a second for nobody.
  static const idleFps = 2;

  /// Called by whatever draws MilkDrop, each time it does; [stage] where that is
  /// the native stage, which draws it in its own context.
  void want({required bool whole, MilkInStage? stage}) {
    final now = DateTime.now();
    if (stage != null) _stageWanted = now;
    final where = stage ?? (now.difference(_stageWanted) < const Duration(seconds: 2) ? inStage : null);
    if (where != inStage) {
      // Moved between the helper and the stage: the one on is stopped, and the next
      // start is the other's.
      stop();
      inStage = where;
    }
    _anyWanted = now;
    if (whole) _wholeWanted = now;
    // Looked at again: back to its rate now, not at the next tick.
    if (_idle && (_helper != null || _staged) && _ready) _size();
  }

  /// The helper told its size and rate, where who is looking changed.
  void _size() {
    final now = DateTime.now();
    final idle = now.difference(_anyWanted) > const Duration(seconds: 2);
    final whole = now.difference(_wholeWanted) < const Duration(seconds: 2);
    if (whole == _whole && idle == _idle) return;
    if (whole != _whole) _send(whole ? 'size $width $height' : 'size $smallWidth $smallHeight');
    _whole = whole;
    _idle = idle;
    _send('fps ${idle ? idleFps : whole ? fps : smallFps}');
  }

  /// Where the helper is, looked for once: the engine asks every tick whether there
  /// is one, and on a Windows desk every look on disk passes the virus scanner.
  static String? helperPath() => _path ??= _find();
  static String? _path;

  /// Beside the app (the bundle), under its lib/, named by WETOWL_MILK, or the
  /// development build. Null where there is none — a Mac, for now.
  static String? _find() {
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
  bool get available => inStage != null || helperPath() != null;

  static const _numbersOff = {'milk.ok': 0.0, 'milk.on': 0.0};

  Future<void> start() => _starting ??= _start().whenComplete(() => _starting = null);

  /// The presets the helper died on, this run: not put on again (the director
  /// starts on the last one, and a preset that crashes it crashes it every time).
  final crashed = <String>{};

  /// After a crash, not started again before this: a second, then longer, up to
  /// half a minute, while it keeps crashing soon after it starts.
  DateTime? _notBefore;
  DateTime? _startedAt;
  int _crashes = 0;

  Future<void> _start() async {
    if (_helper != null) return;
    final wait = _notBefore;
    if (wait != null && DateTime.now().isBefore(wait)) return;
    trouble = null;
    // Never under a test: see CameraFeed.start.
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      trouble = 'no MilkDrop in a test';
      return;
    }
    final stage = inStage;
    if (stage != null) {
      if (_staged) return;
      await library.ready();
      stage.send('open $width $height $fps ${library.texturesDir}', null);
      _staged = true;
      _ready = true;
      _whole = true;
      _idle = false;
      _anyWanted = DateTime.now();
      pcm.reset();
      director.started();
      notifyListeners();
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
      _ready = false;
      late final MilkPipe pipe;
      pipe = await MilkPipe.start(
        path,
        ['--size', '${width}x$height', '--fps', '$fps', '--textures', library.texturesDir],
        frame: (rgba, w, h) => _arrived(pipe, rgba, w, h),
        said: _said,
        ended: (code) {
          if (_helper != pipe) return;
          debugPrint('milk: wetowl-milk left with $code${trouble == null ? '' : ': $trouble'}');
          _ended();
        },
      );
      _helper = pipe;
      _whole = true;
      _startedAt = DateTime.now();
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
    if (_staged) {
      inStage?.send('quit', null);
      _staged = false;
    }
    final pipe = _helper;
    _helper = null;
    pipe?.stop();
    _ready = false;
    notifyListeners();
  }

  /// The helper gone on its own: the preset it was on is let go of, and the next
  /// start waits a little longer each time it does so again soon.
  void _ended() {
    if (_helper == null) return;
    _helper = null;
    _ready = false;
    trouble ??= 'MilkDrop stopped';
    final on = preset;
    if (on != null && crashed.add(on.path)) debugPrint('milk: not again this run: ${on.fullName}');
    final now = DateTime.now();
    final started = _startedAt;
    _crashes = started != null && now.difference(started) < const Duration(seconds: 30) ? _crashes + 1 : 1;
    _notBefore = now.add(Duration(seconds: math.min(30, 1 << (_crashes - 1))));
    notifyListeners();
  }

  void _said(String line) {
    if (line == 'ready') {
      _ready = true;
      // A helper starts whole and at full rate (--size, --fps): what is sent from
      // here is measured against that.
      _whole = true;
      _idle = false;
      _anyWanted = DateTime.now();
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
    } else if (RegExp(r'^(egl|wgl|gl|projectm|frames):').hasMatch(line)) {
      // The helper's own word on why it cannot draw.
      debugPrint('milk: $line');
      trouble = line;
    } else if (line.trim().isNotEmpty) {
      // The renderer ("egl surfaceless ..."), and projectM on a preset's code
      // (its shader translator's complaints): for the log.
      debugPrint('milk: $line');
    }
  }

  void _send(String line, [Uint8List? payload]) {
    if (_staged) {
      inStage?.send(line, payload);
    } else {
      _helper?.send(line, payload);
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
    if ((_helper == null && !_staged) || !_ready) return;
    if (_staged) {
      for (final line in inStage?.said().split('\n') ?? const <String>[]) {
        if (line.isNotEmpty) _said(line);
      }
    }
    _size();
    final vars = varsOf(st);
    _send('vars ${vars.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(4)}').join(' ')}');
    // MilkDrop's bass/mid/treb from the show's own hits and bands rather than
    // its FFT: 1 is its "average"; a hit lands at 2 to 3, where presets' thresholds
    // (bass_att > 1.3 and the like) are. The followers ease over a sixth of a second.
    final f = st.flat;
    final lv = [
      0.55 + 1.0 * (f['dyn.band.low'] ?? 0) + 1.7 * (f['dyn.hit.kick'] ?? 0),
      0.55 + 1.0 * (f['dyn.band.mid'] ?? 0) + 1.5 * (f['dyn.hit.snare'] ?? 0),
      0.55 + 1.0 * (f['dyn.band.high'] ?? 0) + 1.5 * (f['dyn.hit.top'] ?? 0),
    ];
    for (var i = 0; i < 3; i++) {
      _att[i] += (lv[i] - _att[i]) * 0.12;
    }
    _send('audio ${lv.map((v) => v.toStringAsFixed(3)).join(' ')} ${_att.map((v) => v.toStringAsFixed(3)).join(' ')}');
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
  /// A frame off the pipe, made a picture; the pipe told when it is, for the next.
  void _arrived(MilkPipe pipe, Uint8List rgba, int w, int h) {
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, (img) {
      pipe.took();
      if (_helper != pipe) {
        img.dispose();
        return;
      }
      final first = frame == null;
      frame?.dispose();
      frame = img;
      shown.value++;
      if (first) notifyListeners();
    });
  }

  /// The numbers for the engine, by name.
  Map<String, double> get numbers => !available
      ? _numbersOff
      : {
          'milk.ok': 1,
          'milk.on': running && (frame != null || _staged) ? 1 : 0,
        };

  @override
  void dispose() {
    stop();
    frame?.dispose();
    presetTrouble.dispose();
    shown.dispose();
    super.dispose();
  }
}
