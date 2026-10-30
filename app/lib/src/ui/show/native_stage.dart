// The native stage (native/stage/) in the app: the show drawn in OpenGL ES on a
// thread of its own, at the screen's full size and in floating point, into a texture
// this view shows — no copy, no Flutter render passes for the scene at all. See
// ~/.claude/plans/wetowl-show-v2.md, M2.
//
// It draws what its shaders can: a scene of one shader layer, sampling nothing but
// MilkDrop (which it draws in its own context), or the dancers. For any other — a
// simulation, the meme edit, the camera — the Flutter stage (ShowCanvas) draws as
// before, over the native one, which is *parked* meanwhile (a frame every two
// seconds, its shaders and meshes kept): a scene the native stage cannot draw no
// longer tears it down and builds it again, which compiled every shader and opened
// MilkDrop afresh each time the director went to the birds and back.
//
// One stage a process. The booth's small picture has it until the show itself (the
// stage page over the window) asks, which takes it; the window's close is held back
// a moment so a hand-over never stops the stage. Linux only so far, on unless
// WETOWL_STAGE=flutter; a stage that has drawn nothing within a few seconds of its
// open is given up for a while (not for good: a window hidden at the open, a stalled
// desktop) and the Flutter one draws instead. WETOWL_STAGE_SHADERS points it at a
// checkout's app/shaders/show, to change a scene while it plays.
//
// Which one draws, and why, is said in [StageInfo] (the booth's status line, the
// debug words of show_debug.dart) and every change of hands is noted.
import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../state/show/camera_feed.dart';
import '../../state/show/milk_feed.dart';
import '../../state/show/show_feed.dart';
import '../../state/show/show_pool.dart' show QualityPool;
import '../../state/show/mosh_clock.dart';
import '../../state/show/show_rig.dart';
import '../../state/show/show_state.dart';
import '../../state/show/show_tune.dart' show fxKnobs, imageTreatments;
import 'scene.dart';
import 'show_canvas.dart';
import 'show_common.dart';
import 'show_dance.dart';
import 'show_dance_draw.dart';
import 'show_dance_surface.dart';
import 'show_debug.dart';
import 'show_flock.dart' show FlockSim;
import 'show_flock_surface.dart';
import 'show_meme.dart' show MemeEdit;
import 'show_sims.dart';
import 'show_veins.dart';
import 'show_turntable.dart';
import 'show_type3d.dart';
import 'show_words.dart';
import 'stage_camera.dart';

final class _Stats extends Struct {
  @Int64()
  external int frames;
  @Float()
  external double fps;
  @Float()
  external double frameMs;
  @Float()
  external double worstMs;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int workWidth;
  @Int32()
  external int workHeight;
  @Int32()
  external int floatTargets;
  @Float()
  external double autoScale;
}

/// What is drawing a stage surface, and why: for the booth's status line and the
/// debug words (show_debug.dart).
class StageInfo {
  const StageInfo({
    required this.native,
    this.why = '',
    this.scene,
    this.fps = 0,
    this.ms = 0,
    this.worstMs = 0,
    this.width = 0,
    this.height = 0,
    this.workWidth = 0,
    this.workHeight = 0,
    this.autoScale = 1,
    this.float = false,
    this.scale = 1,
    this.parked = false,
  });

  /// The native stage draws this surface now.
  final bool native;

  /// Why the Flutter stage draws instead (empty while the native one does).
  final String why;
  final String? scene;
  final double fps, ms, worstMs, autoScale, scale;
  final int width, height, workWidth, workHeight;
  final bool float;

  /// The native stage is open under a Flutter-drawn scene, waiting (see the top).
  final bool parked;

  String get word => native ? 'native' : 'flutter';

  static const none = StageInfo(native: false, why: 'nothing drawn yet');

  StageInfo copyWith({double? fps, bool? parked, String? why, String? scene}) => StageInfo(
        native: native,
        why: why ?? this.why,
        scene: scene ?? this.scene,
        fps: fps ?? this.fps,
        ms: ms,
        worstMs: worstMs,
        width: width,
        height: height,
        workWidth: workWidth,
        workHeight: workHeight,
        autoScale: autoScale,
        float: float,
        scale: scale,
        parked: parked ?? this.parked,
      );
}

class NativeStage {
  NativeStage._(this._lib);

  static NativeStage? _it;
  static bool _tried = false;

  /// On a desk that can have it, unless WETOWL_STAGE=flutter (and not while it is
  /// given up): [whyNot] says which.
  static bool get wanted => whyNot() == null;

  /// Where the native stage is the only one (Windows, Linux): the Flutter stage is
  /// never drawn there. A scene it cannot draw, or a stage that will not open, is
  /// black until it can — another try every [retryAfter]. WETOWL_STAGE=flutter still
  /// asks for the Flutter stage, for a look at it; the Mac has only that so far.
  static bool get only =>
      !kIsWeb &&
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      (Platform.isWindows || Platform.isLinux) &&
      Platform.environment['WETOWL_STAGE'] != 'flutter';

  /// The stage's picture now (the runner's one texture) and the show it draws, for a
  /// view of the same show that does not have the stage: it shows that picture.
  static final shown = ValueNotifier<(int, Object)?>(null);

  /// Why the native stage is not to be had here now, or null when it is.
  static String? whyNot() {
    if (kIsWeb) return 'the web';
    // Never under a test: no runner, no channel — said first, on any desk.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return 'a test';
    if (!Platform.isLinux && !Platform.isWindows) return 'the native stage is Linux and Windows only so far';
    if (Platform.environment['WETOWL_STAGE'] == 'flutter') return 'WETOWL_STAGE=flutter';
    final until = brokenUntil;
    if (until != null) {
      final left = until.difference(DateTime.now());
      if (left > Duration.zero) return 'given up ($brokenWhy); another try in ${left.inSeconds + 1} s';
      brokenUntil = null;
      ShowDebug.note('the native stage is tried again');
    }
    return null;
  }

  /// It would not open, or drew nothing: the Flutter stage until then, and another
  /// try after — not for the rest of the run, as a window hidden at the open or a
  /// desktop that stalled for ten seconds would have cost the whole evening.
  static DateTime? brokenUntil;
  static String brokenWhy = '';
  static const retryAfter = Duration(seconds: 20);

  /// A view is showing it now (for the booth's word on which stage draws).
  static bool drawing = false;

  // ---------------------------------------------------------------- whose it is
  /// Which view has it: one stage a process. A view of higher [rank] takes it from
  /// one of lower: the booth's small picture (0) yields to the show page's picture
  /// (1), both to the show itself — the stage page over the window (2) — and each
  /// takes it back when the higher one is gone.
  static Object? _owner;
  static int _ownerRank = 0;

  static bool claim(Object who, {int rank = 0}) {
    if (_owner == null || _owner == who) {
      _owner = who;
      _ownerRank = rank;
      return true;
    }
    if (rank > _ownerRank) {
      _owner = who;
      _ownerRank = rank;
      return true;
    }
    return false;
  }

  static bool owns(Object who) => _owner == who;

  static void release(Object who) {
    if (_owner == who) _owner = null;
  }

  /// Who has it, for the one who could not: a word.
  static String get ownerWord => switch (_ownerRank) {
        0 => 'the booth\'s small picture has it',
        1 => 'the show page\'s picture has it',
        _ => 'the stage over the window has it',
      };

  /// The stage's library, loaded by the runner the first time the channel opened it;
  /// null where it is not here.
  static NativeStage? get instance {
    if (_it != null || _tried) return _it;
    _tried = true;
    try {
      final exe = File(Platform.resolvedExecutable).parent.path;
      // Beside the app's other libraries: bundle/lib on Linux, the app's own folder
      // on Windows (where the runner loaded it already, by the same name).
      final names = Platform.isWindows ? ['$exe\\wetowl_stage.dll', 'wetowl_stage.dll'] : ['$exe/lib/libwetowl_stage.so', 'libwetowl_stage.so'];
      for (final p in names) {
        try {
          return _it = NativeStage._(DynamicLibrary.open(p));
        } catch (e) {
          openError = '$e';
        }
      }
    } catch (e) {
      openError = '$e';
    }
    return null;
  }

  /// Why the library would not open, where it would not (the debug words, the log).
  static String? openError;

  /// What it can draw: one shader (sampling MilkDrop, the camera and its motion, the
  /// cover, its own last picture); the dancers, the turntable, the words; and, in a
  /// build that has them (ws_features), the 3D type, the meme edit, the birds, the
  /// veins and the fluid — every scene there is.
  static bool canDraw(Scene? scene) =>
      isShader(scene) ||
      isDance(scene) ||
      isTurntable(scene) ||
      isWords(scene) ||
      (isMeme(scene) && (instance?.sims ?? false)) ||
      (isFlock(scene) && (instance?.flock ?? false)) ||
      (isType3d(scene) && (instance?.sims ?? false)) ||
      (isVeins(scene) && (instance?.veins ?? false)) ||
      (isFluid(scene) && (instance?.fluid ?? false));

  /// Why it cannot draw [scene] (null when it can).
  static String? whyNotScene(Scene? scene) {
    if (scene == null) return 'no scene';
    if (canDraw(scene)) return null;
    final sim = scene.layers.firstOrNull?.sim;
    if (sim != null) return '${scene.id} is a simulation ($sim) the native stage does not draw yet';
    if (scene.layers.length != 1) return '${scene.id} has ${scene.layers.length} layers';
    final odd = scene.layers.first.samplers.where((s) => !_samplersHere.contains(s)).toList();
    if (odd.isNotEmpty) return '${scene.id} samples ${odd.join(', ')}';
    return '${scene.id} is not a shader scene';
  }

  /// Why it cannot draw [rig] as asked (null when it can): a treatment over a scene's
  /// picture, where this build of the stage has no pass for one (ws_treat, [treats])
  /// — those frames are the Flutter stage's. The dancers' and the birds' own rendering
  /// of one (RigFigure.style its name) it draws either way.
  static String? whyNotRig(ShowRig rig, {bool? treats, bool? transforms}) {
    final f = rig.figure;
    // The transformation: a build of the stage from before ws_ghosts has no pass for it.
    if (rig.transform.beforeStyle && f.kind != Figure.none && !(transforms ?? (_it?.transformsToo ?? false))) {
      return 'the scene transformed, which this build of the stage cannot draw';
    }
    final t = f.treatment;
    if (f.kind == Figure.none || !imageTreatments.contains(t) || f.style == t.name) return null;
    if (treats ?? (_it?.treats ?? false)) return null;
    return 'the scene through ${t.name}, which this build of the stage cannot draw';
  }

  /// The ascii's glyphs up to the stage, the first time anything wants them.
  void _sendGlyphs() {
    if (_glyphsSent) return;
    _glyphsSent = true;
    unawaited(DanceSim.glyphBytes().then((g) {
      if (g == null) return;
      final (w, h, bytes) = g;
      final p = _copy<Uint8>(bytes);
      _name((n) => _danceTexture(n, w, h, p, 1), 'glyphs');
      calloc.free(p);
    }));
  }

  static bool isShader(Scene? scene) =>
      scene != null &&
      scene.layers.length == 1 &&
      scene.layers.first.shader != null &&
      scene.layers.first.samplers.every(_samplersHere.contains);

  /// What a scene's shader may sample here: MilkDrop (its own, or the helper's), the
  /// room's camera and its motion map (uploaded as they come), the record's cover, and
  /// the scene's own last picture (the stage's).
  static const _samplersHere = {'milk', 'camera', 'motion', 'cover', 'history'};

  /// A scene that samples the room: the camera is started for it, its frames up.
  static bool needsCamera(Scene? scene) =>
      scene != null && scene.layers.any((l) => l.samplers.contains('camera') || l.samplers.contains('motion'));

  /// The fluid (show_sims.dart's FluidSim): its passes the Flutter stage's shaders,
  /// run by the stage on Dart's numbers (ws_words).
  static bool isFluid(Scene? scene) => scene != null && scene.layers.length == 1 && scene.layers.first.sim == 'fluid';

  /// The meme edit: its picture drawn by Dart's canvas (photographs, clips, type) and
  /// sent up, its finish (meme_fx.frag) the stage's (`@sim:meme_fx`), its words over
  /// it here at the screen's size ([_Words]).
  static bool isMeme(Scene? scene) => scene != null && scene.layers.length == 1 && scene.layers.first.sim == 'siebenschlaefer';

  /// The murmuration: its birds a command list as the dancers' are (show_flock.dart's
  /// FlockSim.record, on show_flock_surface.dart's NativeFlockSurface), its finish
  /// the stage's.
  static bool isFlock(Scene? scene) => scene != null && scene.layers.length == 1 && scene.layers.first.sim == 'flock';

  /// The turntable's holograms: its triangles a command list as the dancers' stage
  /// art is (show_turntable.dart), drawn by the dancers' surface.
  static bool isTurntable(Scene? scene) => scene != null && scene.layers.length == 1 && scene.layers.first.sim == 'turntable';

  static bool isDance(Scene? scene) =>
      scene != null && scene.layers.length == 1 && (scene.layers.first.sim?.startsWith('dance.') ?? false);

  /// The words (show_words.dart): the line's pictures go up as textures, the frame is
  /// the sim shader's floats (ws_words).
  static bool isWords(Scene? scene) => scene != null && scene.layers.length == 1 && scene.layers.first.sim == 'words';

  /// The 3D type (show_type3d.dart): its field up as a texture, its frame the sim
  /// shader's floats — the words' way, under the name `@sim:type3d`.
  static bool isType3d(Scene? scene) => scene != null && scene.layers.length == 1 && scene.layers.first.sim == 'type3d';

  /// The veins (the physarum sim): the stage's own slime mould (fx.h's Slime, `@slime`),
  /// its rules a frame from show_veins.dart (ws_words).
  static bool isVeins(Scene? scene) => scene != null && scene.layers.length == 1 && scene.layers.first.sim == 'physarum';

  static const _channel = MethodChannel('wetowl/stage');

  final DynamicLibrary _lib;
  late final _inputs = _lib.lookupFunction<Void Function(Pointer<Float>, Int32), void Function(Pointer<Float>, int)>('ws_inputs');
  late final _scene = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('ws_scene');
  late final _post = _lib.lookupFunction<Void Function(Float, Float, Float, Float, Float, Float),
      void Function(double, double, double, double, double, double)>('ws_post');
  late final _stats = _lib.lookupFunction<Void Function(Pointer<_Stats>), void Function(Pointer<_Stats>)>('ws_stats');
  late final _rate = _lib.lookupFunction<Void Function(Float), void Function(double)>('ws_rate');
  late final _from = _lib.lookupFunction<Void Function(Pointer<Utf8>, Float, Pointer<Float>), void Function(Pointer<Utf8>, double, Pointer<Float>)>('ws_from');
  late final _flash = _lib.lookupFunction<Void Function(Float, Float, Int32), void Function(double, double, int)>('ws_flash');
  late final _palette = _lib.lookupFunction<Void Function(Pointer<Float>), void Function(Pointer<Float>)>('ws_palette');
  late final _particles = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('ws_particles');
  late final _trails = _lib.lookupFunction<Void Function(Pointer<Float>, Int32), void Function(Pointer<Float>, int)>('ws_trails');
  late final _ground = _lib.lookupFunction<Void Function(Int32, Pointer<Utf8>, Float, Pointer<Float>), void Function(int, Pointer<Utf8>, double, Pointer<Float>)>('ws_ground');
  late final _blend = _lib.lookupFunction<Void Function(Int32, Int32, Int32, Float), void Function(int, int, int, double)>('ws_blend');
  late final _errorFn = _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('ws_error');

  /// What the stage last said went wrong (a context, a shader, MilkDrop), or ''.
  String get error {
    try {
      return _errorFn().toDartString();
    } catch (_) {
      return '';
    }
  }
  (RigGround, String, int?)? _groundOn;
  (RigBlend, int)? _blendOn;
  final Pointer<Float> _scratch = calloc<Float>(16);
  late final _danceMesh = _lib.lookupFunction<
      Int32 Function(Int32, Pointer<Float>, Pointer<Float>, Pointer<Uint8>, Pointer<Uint8>, Int32, Pointer<Float>, Pointer<Uint16>, Int32, Pointer<Uint16>),
      int Function(int, Pointer<Float>, Pointer<Float>, Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Float>, Pointer<Uint16>, int, Pointer<Uint16>)>('ws_dance_mesh');
  late final _danceSkin =
      _lib.lookupFunction<Void Function(Int32, Int32, Int32, Pointer<Uint8>), void Function(int, int, int, Pointer<Uint8>)>('ws_dance_skin');
  late final _danceTexture = _lib.lookupFunction<Void Function(Pointer<Utf8>, Int32, Int32, Pointer<Uint8>, Int32),
      void Function(Pointer<Utf8>, int, int, Pointer<Uint8>, int)>('ws_dance_texture');
  late final _danceFrame = _lib.lookupFunction<Void Function(Pointer<Float>, Int32), void Function(Pointer<Float>, int)>('ws_dance_frame');
  late final _wordsFn = _lib.lookupFunction<Void Function(Pointer<Float>, Int32), void Function(Pointer<Float>, int)>('ws_words');
  final Pointer<Float> _wordsBuf = calloc<Float>(512);
  final _meshIds = Expando<int>();
  final _skinsSent = <int>{};
  bool _glyphsSent = false;

  /// The treatment over the figure (ws_treat; a library from before it has none).
  late final void Function(Pointer<Float>, int)? _treatFn = () {
    try {
      return _lib.lookupFunction<Void Function(Pointer<Float>, Int32), void Function(Pointer<Float>, int)>('ws_treat');
    } catch (_) {
      return null;
    }
  }();
  final Pointer<Float> _treatBuf = calloc<Float>(19);
  bool _treatOn = false;
  static final _treatClock = Stopwatch()..start();

  /// Whether this build of the stage draws a treatment over a scene (ws_treat; what
  /// ws_features says as 8).
  late final bool treats = _treatFn != null;

  /// The kaleidoscope (ws_ghosts), the slit-scan as a transformation (ws_slit), and
  /// whether the working size follows the frames
  /// (ws_adapt): a library from before them has neither.
  late final void Function(int, double, double, double, int, double)? _ghostsFn = () {
    try {
      return _lib.lookupFunction<Void Function(Int32, Float, Float, Float, Int32, Float), void Function(int, double, double, double, int, double)>('ws_ghosts');
    } catch (_) {
      return null;
    }
  }();
  late final void Function(int)? _adaptFn = () {
    try {
      return _lib.lookupFunction<Void Function(Int32), void Function(int)>('ws_adapt');
    } catch (_) {
      return null;
    }
  }();
  late final void Function(Pointer<Float>, int)? _slitFn = () {
    try {
      return _lib.lookupFunction<Void Function(Pointer<Float>, Int32), void Function(Pointer<Float>, int)>('ws_slit');
    } catch (_) {
      return null;
    }
  }();
  late final bool transformsToo = _ghostsFn != null;

  /// The datamosh held (ws_mosh_hold: a library from before it has none), played by
  /// the music (mosh_clock.dart).
  late final void Function(Pointer<Float>, int)? _moshHoldFn = () {
    try {
      return _lib.lookupFunction<Void Function(Pointer<Float>, Int32), void Function(Pointer<Float>, int)>('ws_mosh_hold');
    } catch (_) {
      return null;
    }
  }();
  final Pointer<Float> _moshHoldBuf = calloc<Float>(5);
  final _moshClock = MoshClock();
  bool _moshHeld = false;
  RigTransform? _ghostsSent;
  bool? _adaptSent;
  final Pointer<Float> _slitBuf = calloc<Float>(19);
  bool _slitOn = false;

  /// The frame's transformation and its word on the working size, to the stage.
  void transformAndAdapt(ShowState st) {
    final g = st.rig.figure.kind == Figure.none ? RigTransform.none : st.rig.transform;
    if (g != _ghostsSent && _ghostsFn != null) {
      _ghostsSent = g;
      _ghostsFn(g.on ? g.count : 0, g.differ, g.turnRadians, g.line, g.blend.index, g.amount);
    }
    // The slit-scan as the layer, over whatever style: its shape, the kick, the time and
    // its knobs (reach, slower) — every frame while on.
    final slit = _slitFn;
    if (slit != null) {
      if (g.slit) {
        final s = slitShapeOf(st);
        final k = fxKnobs(st.macros.tune, 'slit');
        final v = [
          9.0, s.shape, 1, 1, 1, 0, 0, 0, s.flip, 0, (st.flat['dyn.hit.kick'] ?? 0).clamp(0.0, 1.0), 0.5, 0.5,
          _treatClock.elapsedMicroseconds / 1e6, k.weight, k.spacing, k.height, k.gain, k.size,
        ];
        for (var i = 0; i < v.length; i++) {
          _slitBuf[i] = v[i].toDouble();
        }
        slit(_slitBuf, 19);
        _slitOn = true;
      } else if (_slitOn) {
        _slitBuf[0] = 0;
        slit(_slitBuf, 19);
        _slitOn = false;
      }
    }
    // The datamosh held over the whole picture, MilkDrop alone too: the clock's
    // numbers every frame while on, off once when it goes.
    final moshHold = _moshHoldFn;
    if (moshHold != null) {
      final d = _moshClock.frame(st, st.rig.transform);
      if (d.on || _moshHeld) {
        final v = [d.on ? 1.0 : 0.0, d.heal, d.strength, d.grain, d.keys.toDouble()];
        for (var i = 0; i < v.length; i++) {
          _moshHoldBuf[i] = v[i];
        }
        moshHold(_moshHoldBuf, v.length);
        _moshHeld = d.on;
      }
    }
    final a = st.macros.adapt;
    if (a != _adaptSent && _adaptFn != null) {
      _adaptSent = a;
      _adaptFn(a ? 1 : 0);
    }
  }

  /// The treatment [st]'s rig asks of the stage (show_common.dart treatOf: the same
  /// pass, colours, cell and knobs as the Flutter stage's), on a working picture [h]
  /// pixels high; none where it asks for none.
  void treat(ShowState st, double h) {
    final fn = _treatFn;
    if (fn == null) return;
    final q = treatOf(st.rig, st, h.round().clamp(8, 8192));
    if (q == null) {
      if (_treatOn) {
        _treatBuf[0] = 0;
        fn(_treatBuf, 19);
        _treatOn = false;
      }
      return;
    }
    _sendGlyphs();
    final k = fxKnobs(st.macros.tune, q.t.name);
    final v = [
      // The slit-scan's cell is its shape, not a size.
      q.mode.toDouble(), q.t == Treatment.slit ? q.cell : q.cell / h, q.ink.r, q.ink.g, q.ink.b, q.paper.r, q.paper.g, q.paper.b, q.tint,
      DanceSim.glyphCount.toDouble(), (st.flat['dyn.hit.kick'] ?? 0).clamp(0.0, 1.0), 0.5, 0.5,
      _treatClock.elapsedMicroseconds / 1e6, k.weight, k.spacing, k.height, k.gain, k.size,
    ];
    for (var i = 0; i < v.length; i++) {
      _treatBuf[i] = v[i];
    }
    fn(_treatBuf, 19);
    _treatOn = true;
  }
  Pointer<Float> _cmds = nullptr;
  int _cmdsCap = 0;

  static Pointer<T> _copy<T extends NativeType>(TypedData data) {
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final p = calloc<Uint8>(bytes.length);
    p.asTypedList(bytes.length).setAll(0, bytes);
    return p.cast<T>();
  }

  /// The native stage's id for [b]'s mesh: registered (and its skin sent, when it
  /// has been read out) the first time.
  int danceMesh(DanceBody b) {
    final m = b.mesh;
    var id = _meshIds[m];
    if (id == null) {
      final pos = _copy<Float>(m.pos), nrm = _copy<Float>(m.nrm), bone = _copy<Uint8>(m.bone), weight = _copy<Uint8>(m.weight);
      final uv = _copy<Float>(m.uv), src = _copy<Uint16>(m.src), tris = _copy<Uint16>(m.tris);
      id = _danceMesh(m.positions, pos, nrm, bone, weight, m.verts, uv, src, m.triangles, tris);
      for (final p in [pos, nrm, bone, weight, uv, src, tris]) {
        calloc.free(p);
      }
      _meshIds[m] = id;
    }
    final skin = b.skinImage;
    if (skin != null && _skinsSent.add(id)) {
      final meshId = id;
      unawaited(skin.toByteData(format: ui.ImageByteFormat.rawRgba).then((data) {
        if (data == null) return;
        final p = _copy<Uint8>(data);
        _danceSkin(meshId, skin.width, skin.height, p);
        calloc.free(p);
      }));
    }
    return id;
  }

  /// A named texture the stage draws with (the room's frame, the cover): RGBA, top
  /// row first, flipped on the way up so GL reads it the right way round.
  void texture(String name, int w, int h, Uint8List rgba) {
    final p = calloc<Uint8>(rgba.length);
    p.asTypedList(rgba.length).setAll(0, rgba);
    _name((n) => _danceTexture(n, w, h, p, 1), name);
    calloc.free(p);
  }

  /// The dancers' frame: [cmds] (NativeDanceSurface's), and the ascii's glyphs the
  /// first time.
  void dance(Float32List cmds) {
    _sendGlyphs();
    if (cmds.length > _cmdsCap) {
      if (_cmds != nullptr) calloc.free(_cmds);
      _cmdsCap = cmds.length * 2;
      _cmds = calloc<Float>(_cmdsCap);
    }
    _cmds.asTypedList(cmds.length).setAll(0, cmds);
    _danceFrame(_cmds, cmds.length);
  }
  /// The words' frame: the sim shader's floats in the file's order (WordsParams).
  void wordsFrame(Float32List v) {
    final n = math.min(v.length, 512);
    _wordsBuf.asTypedList(n).setAll(0, v.sublist(0, n));
    _wordsFn(_wordsBuf, n);
  }

  String? _fromOn, _particlesOn;

  /// The datamosh (ws_mosh; a library from before it has none), and the count of
  /// them last seen (ShowState.mosh), and when a frame was last sent: a mosh starts
  /// from the stage's last picture, which is no use after the stage was parked.
  late final void Function(double, double)? _moshFn = () {
    try {
      return _lib.lookupFunction<Void Function(Float, Float), void Function(double, double)>('ws_mosh');
    } catch (_) {
      return null;
    }
  }();
  int? _moshOn;
  final _sinceFrame = Stopwatch();

  /// The next frame's layers written out (ws_dump: `<path>.fig/.ground/.out/.json`),
  /// for the combination audit; false where this library has no dump.
  bool dump(String path) {
    final f = _dumpFn;
    if (f == null) return false;
    final p = path.toNativeUtf8();
    try {
      f(p);
    } finally {
      malloc.free(p);
    }
    return true;
  }

  late final void Function(Pointer<Utf8>)? _dumpFn = () {
    try {
      return _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('ws_dump');
    } catch (_) {
      return null;
    }
  }();
  double? _rateOn;

  /// Frames a second it draws.
  void rate(double fps) {
    if (fps == _rateOn) return;
    _rateOn = fps;
    _rate(fps);
  }

  /// Parked: a frame every two seconds, everything kept, while a scene the stage
  /// cannot draw is drawn over it by the Flutter stage.
  static const parkedRate = 0.5;
  late final _milk = _lib.lookupFunction<Void Function(Pointer<Utf8>, Pointer<Uint8>, Int32), void Function(Pointer<Utf8>, Pointer<Uint8>, int)>('ws_milk');
  late final _milkSaidFn = _lib.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>('ws_milk_said');
  final Pointer<Utf8> _saidBuf = calloc<Uint8>(8192).cast<Utf8>();

  void _milkSend(String line, Uint8List? payload) {
    final l = line.toNativeUtf8();
    Pointer<Uint8> p = nullptr;
    if (payload != null && payload.isNotEmpty) {
      p = calloc<Uint8>(payload.length);
      p.asTypedList(payload.length).setAll(0, payload);
    }
    _milk(l, p, payload?.length ?? 0);
    calloc.free(l);
    if (p != nullptr) calloc.free(p);
  }

  String _milkSaid() => _milkSaidFn(_saidBuf, 8192) > 0 ? _saidBuf.toDartString() : '';

  /// MilkDrop drawn here, in the stage's context (MilkFeed.want).
  late final milk = MilkInStage(send: _milkSend, said: _milkSaid);

  /// What this build of the stage has (ws_features): 1 MilkDrop in its own
  /// context, 2 frames shared by Direct3D handle, 4 frames as pixels. A library
  /// from before the call: MilkDrop, as every Linux build had.
  int get features {
    try {
      return _lib.lookupFunction<Int32 Function(), int Function()>('ws_features')();
    } catch (_) {
      return 1;
    }
  }

  /// Whether MilkDrop draws in the stage's own context; without it (Windows) the
  /// helper's frames go up as the texture named "milk" (NativeStageView).
  bool get hasMilk => features & 1 != 0;

  /// A sim drawn by name (`@sim:name`: its shader sim/name, its textures
  /// `name.x`), ws_features' 16.
  bool get sims => features & 16 != 0;

  /// The slime mould of its own (`@slime`): the veins.
  bool get veins => features & 32 != 0;

  /// The fluid of its own (`@fluid`).
  bool get fluid => features & 512 != 0;

  /// The dancers' list with meshes and any finish (kMesh, kPostFx): the birds.
  bool get flock => features & 2048 != 0;

  /// What it has, in words, for the debug words and the log.
  String words() {
    final f = features;
    return [
      f & 1 != 0 ? 'MilkDrop of its own' : 'MilkDrop from the helper',
      if (f & 2 != 0) 'frames shared by Direct3D handle',
      if (f & 4 != 0) 'frames as pixels',
      if (f & 8 != 0) 'treatments of its own',
      if (f & 256 != 0) 'transformations of its own',
    ].join(', ');
  }

  final Pointer<Float> _block = calloc<Float>(64);
  final Pointer<_Stats> _st = calloc<_Stats>();
  String? _sceneOn;

  // ---------------------------------------------------------------- the texture
  /// The views with the texture open: the runner keeps one texture (and one stage)
  /// and hands every open the same id, so it is closed only when the last of them
  /// has gone — and a moment after, in case another opens meanwhile (the stage page
  /// taking over from the booth's picture): a stage stopped between the two would
  /// compile every shader and open MilkDrop again for nothing.
  static final _views = <Object>{};
  static Timer? _closing;
  static const closeGrace = Duration(milliseconds: 400);

  /// Opens the stage drawing [width]×[height] pixels for [view]: the texture's id.
  static Future<int?> open(Object view, int width, int height, double scale) async {
    _closing?.cancel();
    _closing = null;
    try {
      final id = await _channel.invokeMethod<int>('open', {'width': width, 'height': height, 'scale': scale});
      ShowDebug.note('the stage is open: texture $id, ${instance?.words() ?? 'no library'}');
      if (id != null) {
        _views.add(view);
        _closing?.cancel();
        _closing = null;
      }
      return id;
    } on PlatformException catch (e) {
      debugPrint('stage: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> resize(int width, int height, double scale) =>
      _channel.invokeMethod('size', {'width': width, 'height': height, 'scale': scale});

  /// [view] is done with it: closed when no view has it, after [closeGrace].
  static void closeFor(Object view) {
    _views.remove(view);
    if (_views.isNotEmpty) return;
    _closing?.cancel();
    _closing = Timer(closeGrace, () {
      _closing = null;
      if (_views.isEmpty) {
        shown.value = null;
        unawaited(_channel.invokeMethod('close'));
      }
    });
  }

  void _name(void Function(Pointer<Utf8>) call, String s) {
    final p = s.toNativeUtf8();
    call(p);
    calloc.free(p);
  }

  /// The frame to draw next: [scene]'s shader, post, particles and trails, the scene
  /// being left ([from], drawable here, else none), the common block, the palette
  /// and the hands, from [st]. Held ([ShowMacros.freeze]): nothing new is sent and
  /// the particles stop.
  void frame(Scene scene, Scene? from, ShowState st, double time, {required StagePrograms programs}) {
    final freeze = st.macros.freeze;
    _flash(stageWhite(st), st.macros.blackout ? 1 : 0, freeze ? 1 : 0);
    if (freeze) return;
    final layer = scene.layers.first;
    final name = isDance(scene) || isTurntable(scene) || isFlock(scene) ? '@dance' : isWords(scene) ? '@words' : isType3d(scene) ? '@sim:type3d' : isMeme(scene) ? '@sim:meme_fx' : isVeins(scene) ? '@slime' : isFluid(scene) ? '@fluid' : layer.shader!;
    if (name != _sceneOn) {
      _name(_scene, name);
      _sceneOn = name;
    }
    // A datamosh from the picture on (a cut the director moshed): over a bar and a half,
    // harder in the loud parts.
    final fresh = _sinceFrame.isRunning && _sinceFrame.elapsedMilliseconds < 250;
    _sinceFrame
      ..reset()
      ..start();
    if (st.mosh != _moshOn) {
      final first = _moshOn == null;
      _moshOn = st.mosh;
      final mosh = _moshFn;
      if (!first && fresh && mosh != null) {
        final bar = 240 / (st.master.bpm ?? 120);
        // Long enough for the old picture to melt through (a bar and a half, two
        // to four seconds).
        mosh((bar * 1.5).clamp(2.0, 4.0), 0.8 + 0.6 * st.master.energy.clamp(0.0, 1.0));
      }
    }
    final fin = finishOf(scene, st);
    _post(fin.trails, fin.bloom, fin.vignette, fin.grain, fin.tone, fin.fringe);
    final kinds = fin.particles.join(',');
    if (kinds != _particlesOn) {
      _name(_particles, kinds);
      _particlesOn = kinds;
    }
    final recipe = trailRecipe(scene, st);
    for (var i = 0; i < recipe.length; i++) {
      _scratch[i] = recipe[i];
    }
    _trails(_scratch, recipe.length);
    // The scene being left, under the director's dissolve: drawn here only if it can
    // be, else the cut is a cut.
    final leaving = from != null && st.sceneK < 1 && isShader(from) ? from.layers.first : null;
    if (leaving == null) {
      if (_fromOn != null) _from(nullptr, 1, nullptr);
      _fromOn = null;
    } else {
      for (var k = 1; k <= 4; k++) {
        _scratch[k - 1] = layerKnob(leaving, k, st);
      }
      final n = leaving.shader!.toNativeUtf8();
      _from(n, st.sceneK, _scratch);
      calloc.free(n);
      _fromOn = leaving.shader;
    }
    // The ground under the figure and the blend of the two: the frame's rig (the look
    // on, with the hands over it). A field that is a simulation is not drawn here
    // yet: black.
    final rig = st.rig;
    final g = rig.ground;
    final field = switch (g.kind) {
      Ground.field => g.field != null && programs.scenes.containsKey(g.field!) ? g.field! : '',
      Ground.pulse => 'pulse',
      _ => '',
    };
    // By value (the record's own knobs come with the record), not a string a tick.
    final groundKey = (g, field, st.master.trackId);
    if (groundKey != _groundOn) {
      _groundOn = groundKey;
      // A field's knobs as the Flutter stage reads them: the record's genome where the
      // shader takes it (the salts), the look's otherwise.
      final fieldLayer = field.isEmpty ? null : SceneLayer(shader: field, knobs: g.knobs);
      for (var k = 1; k <= 4; k++) {
        _scratch[k - 1] = fieldLayer != null ? layerKnob(fieldLayer, k, st) : (g.knobs['m$k'] ?? 0);
      }
      if (g.kind == Ground.pulse) _scratch[0] = pulseVariant(g.field).toDouble();
      final n = field.toNativeUtf8();
      _ground(g.kind.index, n, g.dim, _scratch);
      calloc.free(n);
    }
    // The mask and the blend of the combination on, and which pixels are the figure
    // (show_canvas.dart's coverageOf) — the same numbers the Flutter stage is sent.
    final coverage = coverageOf(scene, rig, native: true);
    final blendKey = (rig.blend, coverage);
    if (blendKey != _blendOn) {
      _blendOn = blendKey;
      _blend(rig.blend.mix.index, rig.blend.mask.index, coverage, rig.blend.strength);
    }
    final pal = st.palette;
    var i = 0;
    for (final c in [pal.primary.toColor(), pal.secondary.toColor(), pal.accent.toColor()]) {
      _scratch[i++] = c.r;
      _scratch[i++] = c.g;
      _scratch[i++] = c.b;
    }
    _palette(_scratch);
    final v = commonBlock(st, layer, time);
    for (var j = 0; j < v.length; j++) {
      _block[j] = v[j];
    }
    _inputs(_block, v.length);
  }

  ({int frames, double fps, double ms, double worstMs, int width, int height, int workWidth, int workHeight, bool float, double autoScale}) stats() {
    _stats(_st);
    final s = _st.ref;
    return (
      frames: s.frames,
      fps: s.fps,
      ms: s.frameMs,
      worstMs: s.worstMs,
      width: s.width,
      height: s.height,
      workWidth: s.workWidth,
      workHeight: s.workHeight,
      float: s.floatTargets != 0,
      autoScale: s.autoScale,
    );
  }
}

/// The stage on screen: native where it can draw the scene on, the Flutter stage
/// where it cannot (or where it is not asked for) — over the native one, parked.
/// Where the native stage is the only one ([NativeStage.only]: Windows, Linux) there
/// is no Flutter stage: black where the native one does not draw this surface, or
/// the picture it draws for another view of the same show (the stage page's, under
/// the booth's glance).
class StageSurface extends StatefulWidget {
  const StageSurface({
    super.key,
    required this.feed,
    required this.book,
    required this.programs,
    this.scale = 0.75,
    this.preview = false,
    this.slow,
    this.info,
    int? rank,
  }) : rank = rank ?? (preview ? 0 : 2);

  final ShowFeed feed;
  final SceneBook book;
  final StagePrograms programs;
  final double scale;
  final bool preview;
  final bool Function()? slow;

  /// Told which stage draws this surface, and why (the booth's status line).
  final ValueNotifier<StageInfo>? info;

  /// Its claim on the native stage against other views (NativeStage.claim).
  final int rank;

  @override
  State<StageSurface> createState() => _StageSurfaceState();
}

class _StageSurfaceState extends State<StageSurface> {
  /// The native stage is this surface's (open or opening); and the scene on is one
  /// it draws (else the Flutter stage draws over it).
  bool _native = false, _drawable = false;
  String _why = StageInfo.none.why;
  late final ValueNotifier<StageInfo> _info = widget.info ?? ValueNotifier(StageInfo.none);

  /// The Flutter stage's frames, counted for its fps.
  int _flutterFrames = 0;
  Timer? _fpsTimer;
  double _flutterFps = 0;

  @override
  void initState() {
    super.initState();
    unawaited(ShowDebug.load());
    widget.feed.addListener(_check);
    _check();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _flutterFps = _flutterFrames.toDouble();
      _flutterFrames = 0;
      if (!_native || !_drawable) _say();
    });
  }

  @override
  void dispose() {
    _fpsTimer?.cancel();
    widget.feed.removeListener(_check);
    NativeStage.release(this);
    if (widget.info == null) _info.dispose();
    super.dispose();
  }

  String get _name => widget.preview ? 'the booth\'s picture' : 'the stage';

  bool _checked = false;

  void _check() {
    final scene = widget.book[widget.feed.state.scene];
    final sceneWhy = NativeStage.whyNotScene(scene) ?? NativeStage.whyNotRig(widget.feed.state.rig) ?? '';
    final drawable = sceneWhy.isEmpty;
    String? why = NativeStage.whyNot();
    var native = false;
    if (why == null) {
      if (NativeStage.instance == null) {
        why = 'no ${Platform.isWindows ? 'wetowl_stage.dll' : 'libwetowl_stage.so'} beside the app'
            '${NativeStage.openError == null ? '' : ' (${NativeStage.openError})'}';
      } else if (NativeStage.claim(this, rank: widget.rank)) {
        native = true;
      } else {
        why = NativeStage.ownerWord;
      }
    }
    if (!native) NativeStage.release(this);
    final whyNow = native ? sceneWhy : (why ?? '');
    final flipped = native != _native;
    // The first time says where it starts, native or not, so a log has it.
    final first = !_checked;
    _checked = true;
    final changed = first || flipped || drawable != _drawable || whyNow != _why;
    if (!changed) return;
    if (first || flipped || (native && drawable != _drawable)) {
      final word = native
          ? (drawable ? 'native' : (NativeStage.only ? 'native, black (it cannot draw this)' : 'native, parked under the Flutter stage'))
          : (NativeStage.only ? 'black, or the stage another view has' : 'flutter');
      ShowDebug.note('$_name: $word${whyNow.isEmpty ? '' : ' — $whyNow'}');
    }
    _native = native;
    _drawable = drawable;
    _why = whyNow;
    _say();
    if (mounted) setState(() {});
  }

  /// The info as this surface knows it (the native view fills in its numbers) —
  /// told after the frame when asked during a build (the first check, in initState).
  void _say() {
    final scene = widget.feed.state.scene;
    if (_native && _drawable) return;
    final v = StageInfo(native: false, why: _why, scene: scene, fps: _flutterFps, scale: widget.scale, parked: _native);
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _info.value = v;
      });
    } else {
      _info.value = v;
    }
  }

  @override
  Widget build(BuildContext context) {
    final nativeDraws = _native && _drawable;
    final only = NativeStage.only;
    final child = Stack(fit: StackFit.expand, children: [
      // The picture, moved by the camera with the music in the 3D scenes.
      StageCameraView(
        feed: widget.feed,
        child: Stack(fit: StackFit.expand, children: [
          if (_native)
            NativeStageView(
              feed: widget.feed,
              book: widget.book,
              programs: widget.programs,
              preview: widget.preview,
              sharpness: widget.preview ? widget.scale.clamp(0.5, 1.0) : 1.0,
              slow: widget.slow,
              drawable: _drawable,
              info: _info,
              onBroken: _check,
            ),
          if (!nativeDraws && only)
            ValueListenableBuilder<(int, Object)?>(
              valueListenable: NativeStage.shown,
              builder: (context, shown, _) => !_native && shown != null && identical(shown.$2, widget.feed)
                  ? Texture(textureId: shown.$1, filterQuality: FilterQuality.low)
                  : const ColoredBox(color: Colors.black),
            ),
          if (!nativeDraws && !only)
            ShowCanvas(
              feed: widget.feed,
              book: widget.book,
              programs: widget.programs,
              scale: widget.scale,
              preview: widget.preview,
              slow: widget.slow,
              onFrame: (_) => _flutterFrames++,
            ),
        ]),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: ShowDebug.on,
        builder: (context, on, _) => on ? StageDebugWords(info: _info) : const SizedBox.shrink(),
      ),
    ]);
    return child;
  }
}

/// The native stage's texture, fed the show every frame, the words over it.
class NativeStageView extends StatefulWidget {
  const NativeStageView({
    super.key,
    required this.feed,
    required this.book,
    this.preview = false,
    this.slow,
    this.onBroken,
    this.drawable = true,
    this.info,
    required this.programs,
    this.sharpness = 0.5,
  });
  final ShowFeed feed;
  final SceneBook book;
  final StagePrograms programs;
  final bool preview;
  final bool Function()? slow;

  /// A preview's pixels as a share of the screen's (the stage itself is whole): the
  /// booth's glance at half, the SHOW page's picture whole.
  final double sharpness;

  /// Told when the stage is given up (it drew nothing): the Flutter stage, then.
  final VoidCallback? onBroken;

  /// The scene on is one the stage draws; else it is parked under the Flutter stage.
  final bool drawable;

  /// Told the stage's numbers every so often.
  final ValueNotifier<StageInfo>? info;

  @override
  State<NativeStageView> createState() => _NativeStageViewState();
}

class _NativeStageViewState extends State<NativeStageView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _clock = Stopwatch()..start();
  final _tick = ValueNotifier<int>(0);
  int? _texture;
  Size? _px;
  bool _opening = false;
  DanceSim? _dance;
  TurntableSim? _turntable;
  FlockSim? _flock;
  MemeEdit? _meme;
  FluidSim? _fluid;
  WordsSim? _words;
  Type3dSim? _type3d;
  Duration? _lastTick;
  double _scale = 1;
  bool _parked = false;
  int _framesAtOpen = 0;
  int _ticks = 0;
  int _camSent = -1;
  int? _coverSent;

  /// The helper's MilkDrop frame as the stage's "milk" texture (MilkFeed.rawFrames,
  /// where the stage has no MilkDrop of its own).
  void _milkFrame(Uint8List rgba, int w, int h) => NativeStage.instance?.texture('milk', w, h, rgba);
  DateTime? _cameraWantedAt;
  late final _covers = StageCovers(() {});

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_frame)..start();
  }

  void _frame(Duration elapsed) {
    final last = _lastTick;
    _lastTick = elapsed;
    final dt = last == null ? 1 / 60 : ((elapsed - last).inMicroseconds / 1e6).clamp(0.0, 0.25);
    final stage = NativeStage.instance;
    final st = widget.feed.state;
    final scene = widget.book[st.scene];
    if (stage == null) return;
    // Parked: the Flutter stage draws this scene over it; a frame now and then keeps
    // it warm, nothing else is sent.
    if (!widget.drawable || !NativeStage.canDraw(scene) || NativeStage.whyNotRig(st.rig) != null) {
      if (!_parked) {
        _parked = true;
        NativeStage.drawing = false;
        stage.rate(NativeStage.parkedRate);
      }
      return;
    }
    _parked = false;
    // The dancers: their choreography here, as the Flutter stage's, their frame a list
    // of commands the stage draws with the bodies on the GPU.
    if (NativeStage.isDance(scene)) {
      final kind = scene!.layers.first.sim!;
      if (_dance?.kind != kind) {
        _dance?.dispose();
        _dance = DanceSim(kind, gpu: true);
        SimLayer.warm(kind);
      }
      final px = _px;
      if (px != null) {
        final cmds = _dance!.record(st, st.macros.freeze ? 0 : dt, px.width.round(), px.height.round(), NativeDanceSurface(stage.danceMesh));
        if (cmds != null) stage.dance(cmds);
        // A fisheye magnifies its middle: drawn half again as fine while one is on.
        final scale = (_dance!.wantsDetail && !widget.preview ? 1.5 : 1.0) * QualityPool.workScale;
        if (scale != _scale) {
          _scale = scale;
          unawaited(NativeStage.resize(px.width.round(), px.height.round(), scale));
        }
      }
    } else {
      if (_dance != null) {
        _dance!.dispose();
        _dance = null;
      }
      final px = _px;
      if (NativeStage.isTurntable(scene) && px != null) {
        final tt = _turntable ??= TurntableSim();
        stage.dance(tt.record(st, st.macros.freeze ? 0 : dt, px.width.round(), px.height.round(), NativeDanceSurface(stage.danceMesh)));
      }
      if (!NativeStage.isTurntable(scene) && _turntable != null) {
        _turntable!.dispose();
        _turntable = null;
      }
      if (NativeStage.isFlock(scene) && px != null) {
        final fl = _flock ??= FlockSim(scene!.layers.first.sim!);
        final s = NativeFlockSurface(NativeDanceSurface(stage.danceMesh), (name, w, h, rgba) => NativeStage.instance?.texture(name, w, h, rgba));
        stage.dance(fl.record(st, st.macros.freeze ? 0 : dt, px.width.round(), px.height.round(), s));
      } else if (_flock != null) {
        _flock!.dispose();
        _flock = null;
      }
      final scale = QualityPool.workScale;
      if (_scale != scale && px != null) {
        _scale = scale;
        unawaited(NativeStage.resize(px.width.round(), px.height.round(), scale));
      }
    }
    // The treatment over the figure, where its rig asks for one the figure does not
    // draw as its own style: the Flutter stage's pass, here.
    if (stage.treats) stage.treat(st, (_px?.height ?? 720) * _scale);
    // Its transformation, and whether the working size follows the frames.
    stage.transformAndAdapt(st);
    // The words: the line set here, its picture up to the stage once, the frame's
    // numbers every tick.
    if (NativeStage.isWords(scene)) {
      final px = _px;
      if (px != null) {
        final ws = _words ??= WordsSim(upload: (name, w, h, rgba) => NativeStage.instance?.texture(name, w, h, rgba));
        stage.wordsFrame(ws.native(st, st.macros.freeze ? 0 : dt, px.width.round(), px.height.round()));
      }
    } else if (_words != null) {
      _words!.dispose();
      _words = null;
    }
    // The veins: their rules every tick, by the words' call (one sim at a time is on).
    if (NativeStage.isVeins(scene)) stage.wordsFrame(VeinsParams.native(st));
    // The meme edit: its picture up, its finish's numbers every tick, by the same call.
    if (NativeStage.isMeme(scene) && _px != null) {
      final kind = scene!.layers.first.sim!;
      if (_meme?.kind != kind) {
        _meme?.dispose();
        _meme = MemeEdit(kind);
      }
      final q = _meme!.native(st, st.macros.freeze ? 0 : dt, (_px!.width * _scale).round(), (_px!.height * _scale).round(),
          (name, w, h, rgba) => NativeStage.instance?.texture(name, w, h, rgba));
      if (q != null) stage.wordsFrame(q);
    } else if (_meme != null) {
      _meme!.dispose();
      _meme = null;
    }
    // The fluid: its passes' numbers every tick, by the same call.
    if (NativeStage.isFluid(scene) && _px != null) {
      final fl = _fluid ??= FluidSim();
      stage.wordsFrame(fl.native(st, st.macros.freeze ? 0 : dt, (_px!.width * _scale).round(), (_px!.height * _scale).round()));
    } else if (_fluid != null) {
      _fluid!.dispose();
      _fluid = null;
    }
    // The 3D type: the line's field up once, the frame's numbers every tick (by the
    // words' call: one sim at a time is on).
    if (NativeStage.isType3d(scene)) {
      final px = _px;
      if (px != null) {
        final ts = _type3d ??= Type3dSim(upload: (name, w, h, rgba) => NativeStage.instance?.texture(name, w, h, rgba));
        stage.wordsFrame(ts.native(st, st.macros.freeze ? 0 : dt, (px.width * _scale).round(), (px.height * _scale).round()));
      }
    } else if (_type3d != null) {
      _type3d!.dispose();
      _type3d = null;
    }
    // The room as the ground: the camera on, each new frame up to the stage; the
    // cover as the ground: the record's, once.
    final ground = st.rig.ground.kind;
    final cam = CameraFeed.shared;
    if (ground == Ground.camera || NativeStage.needsCamera(scene)) {
      _cameraWantedAt = DateTime.now();
      if (!cam.running) unawaited(cam.start());
      final rgba = cam.rgba;
      if (rgba != null && cam.taken != _camSent) {
        _camSent = cam.taken;
        stage.texture('camera', CameraFeed.width, CameraFeed.height, rgba);
        // And what moved in it, for a scene that reads that (fold).
        final motion = cam.motionRgba;
        if (motion != null) stage.texture('motion', CameraFeed.motionWidth, CameraFeed.motionHeight, motion);
      }
    } else if (cam.running && !cam.pinned) {
      final last = _cameraWantedAt;
      if (last != null && DateTime.now().difference(last) > const Duration(seconds: 20)) {
        cam.stop();
        _cameraWantedAt = null;
      }
    }
    if (ground == Ground.cover || (scene?.layers.any((l) => l.samplers.contains('cover')) ?? false)) {
      final id = st.master.trackId;
      final img = _covers.of(id, st.master.coverUrl);
      if (img != null && id != _coverSent) {
        _coverSent = id;
        unawaited(img.toByteData(format: ui.ImageByteFormat.rawRgba).then((d) {
          if (d != null && mounted) stage.texture('cover', img.width, img.height, d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes));
        }));
      }
    }
    // MilkDrop, where the scene samples it or the rig has it as the ground: started
    // in the stage, kept awake.
    final milk = MilkFeed.shared;
    if (st.rig.ground.kind == Ground.milk || scene!.layers.first.samplers.contains('milk')) {
      if (stage.hasMilk) {
        milk.want(whole: !widget.preview, stage: stage.milk);
      } else {
        // No MilkDrop in this stage (Windows): the helper draws it, and its frames
        // go up here as the stage's picture of it, by name.
        milk.want(whole: !widget.preview);
        milk.rawFrames = _milkFrame;
      }
      if (!milk.running) unawaited(milk.start());
    } else if (milk.rawFrames == _milkFrame) {
      milk.rawFrames = null;
    }
    // A stage popped out has the real thing: the preview goes slow.
    stage.rate(widget.slow?.call() == true ? 10 : 60);
    NativeStage.drawing = _texture != null;
    stage.frame(scene!, widget.book[st.sceneFrom], st, _clock.elapsedMicroseconds / 1e6, programs: widget.programs);
    _tick.value++;
    // The numbers, four times a second or so.
    if (++_ticks % 15 == 0) _say(stage, scene.id);
  }

  void _say(NativeStage stage, String? scene) {
    final info = widget.info;
    if (info == null) return;
    final s = stage.stats();
    info.value = StageInfo(
      native: true,
      scene: scene,
      fps: s.fps,
      ms: s.ms,
      worstMs: s.worstMs,
      width: s.width,
      height: s.height,
      workWidth: s.workWidth,
      workHeight: s.workHeight,
      autoScale: s.autoScale,
      float: s.float,
      scale: _scale,
    );
  }

  Future<void> _sized(Size px) async {
    if (_px == px) return;
    _px = px;
    final w = px.width.round(), h = px.height.round();
    if (_texture == null) {
      if (_opening) return;
      _opening = true;
      _framesAtOpen = NativeStage.instance?.stats().frames ?? 0;
      final id = await NativeStage.open(this, w, h, 1);
      _opening = false;
      if (!mounted) {
        if (id != null) NativeStage.closeFor(this);
        return;
      }
      if (id == null) return _giveUp('it would not open');
      setState(() => _texture = id);
      NativeStage.shown.value = (id, widget.feed);
      // A stage that draws nothing (no context to share, a driver that will not, a
      // window hidden so the texture is never asked for, a thread that stopped later)
      // is given up for a while rather than left black: its frames must move on every
      // [watchFor], parked or not (parked is half a frame a second).
      var seen = _framesAtOpen;
      _watch = Timer.periodic(watchFor, (t) {
        final stage = NativeStage.instance;
        final s = stage?.stats();
        if (s == null || s.frames == seen) {
          t.cancel();
          final said = stage?.error ?? '';
          _giveUp('no frame in ${watchFor.inSeconds} s${said.isEmpty ? '' : ': $said'}');
          return;
        }
        seen = s.frames;
      });
      final size = _px;
      if (size != null && size != px) unawaited(NativeStage.resize(size.width.round(), size.height.round(), 1));
    } else {
      unawaited(NativeStage.resize(w, h, _scale));
    }
  }

  /// How long a fresh stage may take to show its first frame.
  static const watchFor = Duration(seconds: 4);

  Timer? _watch;

  void _giveUp(String why) {
    NativeStage.brokenUntil = DateTime.now().add(NativeStage.retryAfter);
    NativeStage.brokenWhy = why;
    NativeStage.drawing = false;
    ShowDebug.note('the native stage is given up ($why); the Flutter stage draws, another try in ${NativeStage.retryAfter.inSeconds} s');
    widget.onBroken?.call();
  }

  @override
  void dispose() {
    if (MilkFeed.shared.rawFrames == _milkFrame) MilkFeed.shared.rawFrames = null;
    _dance?.dispose();
    _words?.dispose();
    _type3d?.dispose();
    _covers.dispose();
    NativeStage.drawing = false;
    _watch?.cancel();
    _ticker.dispose();
    if (_texture != null) NativeStage.closeFor(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, c) {
      // A preview at its share of the screen's pixels (the booth's glance at half).
      final k = widget.preview ? dpr * widget.sharpness.clamp(0.25, 1.0) : dpr;
      final px = Size((c.maxWidth * k).clamp(16, 7680), (c.maxHeight * k).clamp(16, 4320));
      WidgetsBinding.instance.addPostFrameCallback((_) => _sized(px));
      final id = _texture;
      return Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: Colors.black),
        if (id != null) Texture(textureId: id, filterQuality: FilterQuality.low),
        if (!widget.preview && widget.drawable)
          CustomPaint(painter: _Words(widget.feed, widget.book, _tick, () => _meme)),
      ]);
    });
  }
}

class _Words extends CustomPainter {
  _Words(this.feed, this.book, Listenable tick, this.overlay) : super(repaint: tick);
  final ShowFeed feed;
  final SceneBook book;

  /// The scene's own words over the whole stage (the meme edit's), where it has them.
  final SimOverlay? Function() overlay;
  final _rng = math.Random(7);

  @override
  void paint(Canvas canvas, Size size) {
    final st = feed.state;
    final scene = book[st.scene];
    if (scene == null || st.macros.blackout) return;
    overlay()?.paintOver(canvas, size, st, 1);
    paintStageWords(canvas, size, scene, st, _rng);
  }

  @override
  bool shouldRepaint(_Words old) => true;
}
