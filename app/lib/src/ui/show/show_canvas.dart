// The stage: a feed of frames drawn as the scene the director has on.
//
// Each frame: the scene's layers are drawn with their shaders into one picture at
// the working size (a share of the screen the GPU can carry — see [_Working]),
// the trails are laid over last frame's where the scene asks for them, the bloom
// is blurred at half size, and the finish pass puts it on the screen with the
// fringing, the vignette, the strobe and the blackout, crossfading from the scene
// being left. The words — the record's title, the line being sung — are drawn on
// top at the screen's own size, so they stay sharp.
//
// Everything that varies is read off the frame's dotted names (ShowState.flat), so
// a scene file and a shader are all a new look needs.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../state/show/camera_feed.dart';
import '../../state/show/milk_feed.dart';
import '../../state/show/show_feed.dart';
import '../../state/show/show_pool.dart' show QualityPool;
import '../../state/show/show_rig.dart';
import '../../state/show/show_state.dart';
import '../mag.dart';
import 'scene.dart';
import 'show_common.dart';
import 'show_dance.dart' show DanceSim;
import 'show_particles.dart';
import 'show_sims.dart';

/// Every program the stage draws with, loaded once.
class StagePrograms {
  StagePrograms._(this.scenes, this.sims, this.feedback, this.blur, this.finish, this.under);
  final Map<String, ui.FragmentProgram> scenes;

  /// The simulations' passes (shaders/show/sim/), by file name.
  final SimPrograms sims;
  final ui.FragmentProgram feedback, blur, finish, under;

  static const simShaders = ['fluid_advect', 'fluid_div', 'fluid_jacobi', 'fluid_project', 'fluid_look', 'meme_fx', 'dance_fx', 'flock_fx', 'words_fx', 'type3d'];

  /// Shaders no scene file names: the grounds' own.
  static const groundShaders = ['pulse', 'ghosts'];

  /// Whether the simulations' passes wait until a scene asks for one: on Windows,
  /// where ANGLE hands every shader to Direct3D's compiler on the CPU and the window
  /// draws nothing until it is done (the 3D type's ray march alone is most of a
  /// minute on a runner) — and the native stage draws most of them itself anyway.
  static bool get lazySims => defaultTargetPlatform == TargetPlatform.windows;

  static Future<StagePrograms> load(SceneBook book) async {
    final began = DateTime.now();
    final names = {...book.shaders, ...groundShaders}.toList();
    final eager = lazySims ? const <String>[] : simShaders;
    final loaded = await Future.wait([
      for (final n in names) ui.FragmentProgram.fromAsset('shaders/show/$n.frag'),
      for (final n in eager) ui.FragmentProgram.fromAsset('shaders/show/sim/$n.frag'),
      ui.FragmentProgram.fromAsset('shaders/show/feedback.frag'),
      ui.FragmentProgram.fromAsset('shaders/show/blur.frag'),
      ui.FragmentProgram.fromAsset('shaders/show/finish.frag'),
      ui.FragmentProgram.fromAsset('shaders/show/under.frag'),
    ]);
    final k = names.length + eager.length;
    debugPrint('stage: ${loaded.length} programs loaded in ${DateTime.now().difference(began).inMilliseconds} ms${lazySims ? ' (the sims when asked for)' : ''}');
    return StagePrograms._(
      {for (var i = 0; i < names.length; i++) names[i]: loaded[i]},
      SimPrograms({for (var i = 0; i < eager.length; i++) eager[i]: loaded[names.length + i]}),
      loaded[k],
      loaded[k + 1],
      loaded[k + 2],
      loaded[k + 3],
    );
  }
}

/// The simulations' passes, by file name: loaded with the rest, or — where
/// [StagePrograms.lazySims] — each the first time a scene asks for it (null until it
/// is there; a scene draws without it meanwhile). The fluid's five come together.
class SimPrograms {
  SimPrograms(this._loaded);
  final Map<String, ui.FragmentProgram> _loaded;
  final _asked = <String>{};

  static List<String> _group(String name) =>
      name.startsWith('fluid_') ? [for (final n in StagePrograms.simShaders) if (n.startsWith('fluid_')) n] : [name];

  ui.FragmentProgram? operator [](String name) {
    final p = _loaded[name];
    if (p == null && StagePrograms.simShaders.contains(name)) {
      for (final n in _group(name)) {
        if (!_asked.add(n) || _loaded.containsKey(n)) continue;
        final began = DateTime.now();
        ui.FragmentProgram.fromAsset('shaders/show/sim/$n.frag').then((x) {
          _loaded[n] = x;
          debugPrint('stage: sim/$n loaded in ${DateTime.now().difference(began).inMilliseconds} ms');
        }, onError: (Object e) => debugPrint('stage: sim/$n: $e'));
      }
    }
    return p;
  }

  /// Whether [name] (and the rest of its group) is there to draw with.
  bool containsKey(String name) => _group(name).every((n) => this[n] != null);
}

/// The stage on screen, reading [feed].
class ShowCanvas extends StatefulWidget {
  const ShowCanvas({
    super.key,
    required this.feed,
    required this.book,
    required this.programs,
    this.scale = 0.75,
    this.preview = false,
    this.onFrame,
    this.slow,
    this.covers = const {},
  });

  /// Covers already decoded, by track: a test's, which cannot wait for a fetch.
  final Map<int, ui.Image> covers;

  final ShowFeed feed;
  final SceneBook book;
  final StagePrograms programs;

  /// The working size as a share of the screen's pixels, to start with: the stage
  /// lowers it when frames run long and raises it back when they do not.
  final double scale;

  /// A small picture in the booth, not the show itself: no words, a fixed size.
  final bool preview;

  /// Told each frame's time, for a measurement.
  final void Function(Duration took)? onFrame;

  /// Asked each frame: true for ten frames a second, not sixty. The booth's preview
  /// while a stage in a window of its own is showing the real thing on the same GPU.
  final bool Function()? slow;

  @override
  State<ShowCanvas> createState() => _ShowCanvasState();
}

class _ShowCanvasState extends State<ShowCanvas> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final AppLifecycleListener _life;
  final _tick = ValueNotifier<int>(0);
  Duration _lastTick = Duration.zero;
  late final _StagePainter _painter;
  late final StageCovers _covers;

  @override
  void initState() {
    super.initState();
    _covers = StageCovers(() => _tick.value++, given: widget.covers);
    _painter = _StagePainter(widget.feed, widget.book, widget.programs, _covers, _tick, widget.scale, widget.preview);
    _ticker = createTicker(_frame)..start();
    // Hidden or minimised, nothing is drawn: the stage in its own window kept every
    // pass running for a window nobody could see.
    _life = AppLifecycleListener(onHide: () => _ticker.muted = true, onShow: () => _ticker.muted = false);
  }

  /// At most sixty a second — a 144 Hz screen drew every pass more than twice as
  /// often for a show whose state comes thirty times a second — and, where [ShowCanvas.slow]
  /// says so, ten.
  void _frame(Duration elapsed) {
    final slow = widget.slow?.call() ?? false;
    final gap = slow ? const Duration(milliseconds: 99) : const Duration(microseconds: 15500);
    if (elapsed - _lastTick < gap) return;
    _lastTick = elapsed;
    _tick.value++;
  }

  @override
  void didUpdateWidget(ShowCanvas old) {
    super.didUpdateWidget(old);
    _painter.feed = widget.feed;
  }

  @override
  void dispose() {
    _life.dispose();
    _ticker.dispose();
    _painter.dispose();
    _covers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _painter.dpr = MediaQuery.devicePixelRatioOf(context);
    _painter.onFrame = widget.onFrame;
    return RepaintBoundary(child: CustomPaint(painter: _painter, size: Size.infinite));
  }
}

/// The working size: lowered when frames come late, raised back when they do not.
///
/// Judged by the time *between* frames, not the time a frame takes to paint: under
/// Impeller the GPU's work is queued and the paint returns in a millisecond however
/// long the chain is, so the only thing that shows a chain too long for the GPU is
/// the frames arriving late. Thirty late frames in a row (over 20 ms apart, where
/// sixty a second is 16.7) take the size down a step; three hundred on time take
/// it back up.
class _Working {
  _Working(this.scale);
  double scale;
  double top = 1.0;
  int _late = 0, _onTime = 0;
  int? _lastUs;
  static const _floor = 0.4;

  void frameAt(int nowUs) {
    final last = _lastUs;
    _lastUs = nowUs;
    if (last == null) return;
    final gap = nowUs - last;
    // A gap of a second is a pause, not a slow frame.
    if (gap > 500000) return;
    if (gap > 20000) {
      _onTime = 0;
      if (++_late >= 30) {
        _late = 0;
        scale = math.max(_floor, scale * 0.85);
      }
    } else if (gap < 17500) {
      _late = 0;
      if (++_onTime >= 300 && scale < top) {
        _onTime = 0;
        scale = math.min(top, scale / 0.85);
      }
    } else {
      _late = 0;
    }
  }
}

/// Which pixels of [scene]'s picture are its figure, for the blend (under.frag's
/// uCoverage): 1 the alpha — the words' shader writes it, and the native stage's
/// dancers carry it in theirs (unless a treatment pass went over them); 0 the bodies
/// marked at 254/255 — the plain dancers and the silhouettes on a canvas; 2 the
/// light — everything else (a shader's picture, a simulation on a canvas).
int coverageOf(Scene scene, ShowRig rig, {required bool native}) {
  final layer = scene.layers.length == 1 ? scene.layers.first : null;
  if (layer?.sim == 'words' || layer?.sim == 'type3d') return 1;
  final dance = layer?.sim?.startsWith('dance.') ?? false;
  if (!dance) return 2;
  if (native) return 1;
  final style = rig.figure.style;
  return style == 'plain' || style == 'mono' ? 0 : 2;
}

/// The figure's picture each frame, before the blend (the scene's layers, through
/// its treatment, with the bodies' coverage marks): the rules' grid's stills are
/// baked from it (test/shots/rule_stills_bake_test.dart). Kept only for the call.
@visibleForTesting
void Function(Scene scene, ShowState st, ui.Image figure)? stageFigureTap;

/// The working size held where it is asked for, however late the frames (a bake
/// under a test's slow clock).
@visibleForTesting
bool stageSizeHeld = false;

class _StagePainter extends CustomPainter {
  _StagePainter(this.feed, this.book, this.p, this.covers, Listenable tick, double scale, this.preview)
      : working = _Working(scale),
        super(repaint: tick) {
    _feedback = p.feedback.fragmentShader();
    _blurH = p.blur.fragmentShader();
    _blurV = p.blur.fragmentShader();
    _finish = p.finish.fragmentShader();
    _under = p.under.fragmentShader();
  }

  ShowFeed feed;
  final SceneBook book;
  final StagePrograms p;
  final StageCovers covers;
  final bool preview;
  final _Working working;
  double dpr = 1;
  void Function(Duration took)? onFrame;

  /// The most pixels a working pass is drawn at: about 1600 × 900.
  static const maxWorkingPixels = 1600 * 900;

  late final ui.FragmentShader _feedback, _blurH, _blurV, _finish, _under;
  final _layerShaders = <String, ui.FragmentShader>{};
  ui.Image? _history;
  String? _historyScene;
  ui.Image? _black;
  ShowState? _frozen;
  final _clock = Stopwatch()..start();
  final _rng = math.Random(7);

  ui.FragmentShader _shaderFor(String name) =>
      _layerShaders.putIfAbsent(name, () => p.scenes[name]!.fragmentShader());

  /// A pass: [draw] into a [w]×[h] picture, kept as an image.
  ui.Image _pass(int w, int h, void Function(Canvas c) draw) {
    final r = ui.PictureRecorder();
    draw(Canvas(r));
    final pic = r.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    return img;
  }

  ui.Image get black => _black ??= _pass(2, 2, (c) => c.drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..color = Colors.black));

  /// The common block (shaders/show/common.glsl), from the frame, for a layer.
  void _bind(ui.FragmentShader s, ShowState st, Map<String, double> f, int w, int h, SceneLayer layer) {
    var i = 0;
    s.setFloat(i++, w.toDouble());
    s.setFloat(i++, h.toDouble());
    for (final v in commonBlock(st, layer, _time)) {
      s.setFloat(i++, v);
    }
    var si = 0;
    for (final name in layer.samplers) {
      s.setImageSampler(si++, _sampler(name, st));
    }
  }

  ui.Image _sampler(String name, ShowState st) {
    final cam = CameraFeed.shared;
    switch (name) {
      case 'cover':
        return covers.of(st.master.trackId, st.master.coverUrl) ?? black;
      // The scene's own last picture (before the trails), where a layer feeds on
      // itself; the trails' where it has none of its own.
      case 'history':
        return _sceneHistory ?? _history ?? black;
      case 'camera':
        return cam.frame ?? black;
      case 'camera_prev':
        return cam.prev ?? cam.frame ?? black;
      case 'motion':
        return cam.motion ?? black;
      case 'milk':
        return MilkFeed.shared.frame ?? black;
      default:
        return black;
    }
  }

  ui.Image? _sceneHistory;
  DateTime? _cameraWantedAt;
  DateTime? _milkWantedAt;

  /// MilkDrop, for a scene that needs it (or a rig with it as the ground): the
  /// helper started when one is on, stopped a while after none has been (unless the
  /// window pinned it).
  void _milk(Scene scene, {bool under = false}) {
    final milk = MilkFeed.shared;
    final wants = under || scene.meta.needs.contains('milk');
    final now = DateTime.now();
    if (wants) {
      _milkWantedAt = now;
      milk.want(whole: !preview);
      if (!milk.running) unawaited(milk.start());
    } else if (milk.running && !milk.pinned) {
      final last = _milkWantedAt;
      if (last == null || now.difference(last) > const Duration(seconds: 30)) milk.stop();
    }
  }

  /// The camera, for a scene that needs it (or a rig with the room as the ground):
  /// started when one is on, stopped a while after none has been (unless the window
  /// pinned it).
  void _camera(Scene scene, {bool ground = false}) {
    final cam = CameraFeed.shared;
    final wants = ground || scene.meta.needs.contains('camera');
    final now = DateTime.now();
    if (wants) {
      _cameraWantedAt = now;
      if (!cam.running) unawaited(cam.start());
    } else if (cam.running && !cam.pinned) {
      final last = _cameraWantedAt;
      if (last == null || now.difference(last) > const Duration(seconds: 20)) cam.stop();
    }
  }

  final _particles = <String, ParticleSystem>{};
  final _sims = <String, SimLayer>{};
  String? _particleScene;

  /// The scene drawn: its layers, one over the other, and its particles over them
  /// (the scene on, not one being left: [live]) — the figure; then the blend of it
  /// with the ground under it, the frame's rig's way (under.frag). Not for a scene
  /// that draws MilkDrop itself, nor where there is nothing to blend.
  ui.Image _scene(Scene scene, ShowState st, int w, int h, {bool live = true}) {
    final rigOf = live ? st.rig : (st.rigFrom ?? st.rig);
    // The figure, transformed (the kaleidoscope), then its style over that: then onto
    // the ground.
    final layers = _treated(_ghosted(_sceneLayers(scene, st, w, h, live: live), rigOf, st, w, h), rigOf, st, w, h);
    if (live) stageFigureTap?.call(scene, st, layers);
    if (!live || scene.layers.any((l) => l.samplers.contains('milk'))) return layers;
    final rig = st.rig;
    final blend = rig.blend;
    // A figure plainly on black is the figure as it is drawn.
    if (blend.strength <= 0 || (rig.ground.kind == Ground.black && blend.plain)) return layers;
    final ground = _ground(rig, st, w, h);
    if (ground == null) return layers;
    _under
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, blend.mix.index.toDouble())
      ..setFloat(3, blend.mask.index.toDouble())
      ..setFloat(4, coverageOf(scene, rig, native: false).toDouble())
      ..setFloat(5, blend.strength)
      ..setFloat(6, ground.fit)
      ..setFloat(7, rig.ground.dim)
      ..setImageSampler(0, layers)
      ..setImageSampler(1, ground.image);
    final out = _pass(w, h, (c) => c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = _under));
    layers.dispose();
    if (ground.own) ground.image.dispose();
    return out;
  }

  ui.FragmentShader? _treat;

  /// The figure's picture through the treatment its rig asks for (an ascii, a
  /// dither, a print, heat, ridgelines, a map: dance_fx.frag's), with the hands'
  /// knobs — for any scene. Not where the figure drew it itself (the dancers' and
  /// the birds' own styles, [RigFigure.style] the treatment's name).
  ui.FragmentShader? _ghosts;

  /// The figure's picture through the kaleidoscope (shaders/show/ghosts.frag;
  /// RigTransform), where the rig asks for one: before its style. (The slit-scan is
  /// the native stage's: here, as drawn.)
  ui.Image _ghosted(ui.Image img, ShowRig rig, ShowState st, int w, int h) {
    final g = rig.transform;
    if (!g.on || rig.figure.kind == Figure.none) return img;
    final program = p.scenes['ghosts'];
    if (program == null) return img;
    final fx = _ghosts ??= program.fragmentShader();
    fx
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, g.count.toDouble())
      ..setFloat(3, g.differ)
      ..setFloat(4, g.turnRadians)
      ..setFloat(5, g.line)
      ..setFloat(6, g.blend.index.toDouble())
      ..setFloat(7, g.amount)
      ..setImageSampler(0, img);
    final out = _pass(w, h, (c) => c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = fx));
    img.dispose();
    return out;
  }

  ui.Image _treated(ui.Image img, ShowRig rig, ShowState st, int w, int h) {
    final q = treatOf(rig, st, h);
    // The slit-scan keeps frames, which only the native stage does: here, as drawn.
    if (q == null || q.t == Treatment.slit) return img;
    final program = p.sims['dance_fx'];
    if (program == null) return img;
    final fx = _treat ??= program.fragmentShader();
    final f = st.flat;
    final (:t, :mode, :ink, :paper, :cell, :tint) = q;
    fx
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, mode.toDouble())
      ..setFloat(3, cell)
      ..setFloat(4, ink.r)
      ..setFloat(5, ink.g)
      ..setFloat(6, ink.b)
      ..setFloat(7, paper.r)
      ..setFloat(8, paper.g)
      ..setFloat(9, paper.b)
      ..setFloat(10, tint)
      ..setFloat(11, DanceSim.glyphCount.toDouble())
      ..setFloat(12, (f['dyn.hit.kick'] ?? 0).clamp(0.0, 1.0))
      ..setFloat(13, 0.5)
      ..setFloat(14, 0.5)
      ..setFloat(15, _clock.elapsedMicroseconds / 1e6)
      ..setFloat(16, 0)
      ..setImageSampler(0, img)
      ..setImageSampler(1, DanceSim.glyphAtlas);
    setFxKnobs(fx, 17, st, t.name);
    final out = _pass(w, h, (c) => c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = fx));
    img.dispose();
    return out;
  }

  /// The ground under the figure, as a picture: MilkDrop's frame or the room's (16:9,
  /// to be fitted), the record's cover (square), a wash of the palette, a field's or
  /// the pulse's shader drawn at the working size, or black. Null while a frame is
  /// not here yet. [fit] its own aspect where it is to be filled and cropped, 0 where
  /// it is the stage's size; [own]: made here, to be disposed.
  ({ui.Image image, double fit, bool own})? _ground(ShowRig rig, ShowState st, int w, int h) {
    final g = rig.ground;
    switch (g.kind) {
      case Ground.milk:
        final m = MilkFeed.shared.frame;
        return m == null ? null : (image: m, fit: 16 / 9, own: false);
      case Ground.camera:
        final m = CameraFeed.shared.frame;
        return m == null ? null : (image: m, fit: CameraFeed.width / CameraFeed.height, own: false);
      case Ground.cover:
        final m = covers.of(st.master.trackId, st.master.coverUrl);
        return m == null ? null : (image: m, fit: m.width / m.height, own: false);
      case Ground.pulse:
        final program = p.scenes['pulse'];
        if (program == null) return (image: black, fit: 0, own: false);
        final shader = _shaderFor('pulse');
        _bind(shader, st, st.flat, w, h, SceneLayer(shader: 'pulse', knobs: {'m1': pulseVariant(g.field).toDouble()}));
        final img = _pass(w, h, (c) => c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = shader));
        return (image: img, fit: 0, own: true);
      case Ground.wash:
        final pal = st.palette;
        final a = pal.primary.toColor(), b = pal.secondary.toColor();
        final img = _pass(w, h, (c) => c.drawRect(
              Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
              Paint()
                ..shader = ui.Gradient.linear(Offset.zero, Offset(0, h.toDouble()), [
                  Color.fromARGB(255, (a.r * 56).round(), (a.g * 56).round(), (a.b * 56).round()),
                  Color.fromARGB(255, (b.r * 31).round(), (b.g * 31).round(), (b.b * 31).round()),
                ]),
            ));
        return (image: img, fit: 0, own: true);
      case Ground.field:
        final name = g.field;
        final program = name == null ? null : p.scenes[name];
        if (program == null) return (image: black, fit: 0, own: false);
        final shader = _shaderFor(name!);
        _bind(shader, st, st.flat, w, h, SceneLayer(shader: name, knobs: g.knobs));
        final img = _pass(w, h, (c) => c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = shader));
        return (image: img, fit: 0, own: true);
      case Ground.white:
        final img = _pass(w, h, (c) => c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white));
        return (image: img, fit: 0, own: true);
      default:
        return (image: black, fit: 0, own: false);
    }
  }

  ui.Image _sceneLayers(Scene scene, ShowState st, int w, int h, {bool live = true}) => _pass(w, h, (c) {
        final f = st.flat;
        var first = true;
        // A new scene starts its particles and its simulations afresh.
        if (live && _particleScene != scene.id) {
          _particles.clear();
          for (final sim in _sims.values) {
            sim.dispose();
          }
          _sims.clear();
          _particleScene = scene.id;
        }
        for (final layer in scene.layers) {
          final simKind = layer.sim;
          if (simKind != null) {
            if (!live) continue;
            final sim = _sims[simKind] ??= (SimLayer.make(simKind) ?? _NoSim(simKind));
            final img = sim.frame(st, st.macros.freeze ? 0 : _dt, w, h, p);
            if (img == null) continue;
            final paint = Paint()..filterQuality = FilterQuality.low;
            if (!first) paint.blendMode = BlendMode.plus;
            if (layer.dim < 1) paint.color = Color.fromRGBO(255, 255, 255, layer.dim);
            c.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
                Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), paint);
            // The fluid's and the trail's pictures are the sim's own (kept, or
            // replaced by it); a fresh pass is disposed here.
            if (sim is FluidSim) img.dispose();
            first = false;
            continue;
          }
          final shaderName = layer.shader;
          if (shaderName == null) continue;
          final program = p.scenes[shaderName];
          if (program == null) continue;
          final s = _shaderFor(shaderName);
          _bind(s, st, f, w, h, layer);
          final paint = Paint()..shader = s;
          if (!first) paint.blendMode = BlendMode.plus;
          if (layer.dim < 1) paint.color = Color.fromRGBO(255, 255, 255, layer.dim);
          c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), paint);
          first = false;
        }
        final particles = finishOf(scene, st).particles;
        if (!live || particles.isEmpty) return;
        final primary = st.palette.primary.toColor();
        final accent = st.palette.accent.toColor();
        final t = _time;
        for (final kind in particles) {
          final sys = _particles.putIfAbsent(kind, () => ParticleSystem(kind));
          sys.step(st, st.macros.freeze ? 0 : _dt, w, h);
          sys.draw(c, primary, accent, t);
        }
      });

  /// Seconds of the show between the frame drawn last and this one, for the
  /// simulations and the particles; and the show's own time for the shaders. Both by
  /// the frames' clock (ShowState.now), not this painter's: a recording played back
  /// draws the same picture, and a frozen frame holds every shader still.
  double _dt = 1 / 60;
  double _time = 0;
  DateTime? _lastNow;

  @override
  void paint(Canvas canvas, Size size) {
    final began = _clock.elapsed;
    var st = feed.state;
    if (st.macros.freeze) {
      st = _frozen ??= st;
    } else {
      _frozen = null;
    }
    final lastNow = _lastNow;
    _dt = lastNow == null ? 1 / 60 : (st.now.difference(lastNow).inMicroseconds / 1e6).clamp(0.0, 0.25);
    _lastNow = st.now;
    _time += _dt;
    final scene = book[st.scene] ?? book.scenes.values.firstOrNull;
    if (scene == null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
      return;
    }
    // The working size in pixels, capped: a 4K television, or a desk at 150 %, put
    // every full-size pass at five to eight million pixels for a picture the bloom
    // and the grain soften anyway. The finish and the words still go out at the
    // screen's own size.
    final px = size.width * dpr * size.height * dpr;
    // The quality tier caps the working size; the stage still goes lower on its own.
    working.top = QualityPool.workScale;
    if (working.scale > working.top) working.scale = working.top;
    // The hands may keep the picture's size whatever the frames (ShowMacros.adapt).
    if (!st.macros.adapt) working.scale = working.top;
    final cap = px <= maxWorkingPixels ? 1.0 : math.sqrt(maxWorkingPixels / px);
    final w = math.max(8, (size.width * dpr * cap * working.scale).round());
    final h = math.max(8, (size.height * dpr * cap * working.scale).round());
    // The bloom at a quarter of the working size: wide and soft, and cheap.
    final hw = math.max(4, w ~/ 4), hh = math.max(4, h ~/ 4);

    _camera(scene, ground: st.rig.ground.kind == Ground.camera);
    _milk(scene, under: st.rig.ground.kind == Ground.milk);

    // 1. the scene — kept as its own history where a layer feeds on itself.
    final drawn = _scene(scene, st, w, h);
    final feedsOnItself = scene.layers.any((l) => l.samplers.contains('history'));
    if (feedsOnItself) {
      _sceneHistory?.dispose();
      _sceneHistory = drawn;
    } else if (_sceneHistory != null) {
      _sceneHistory!.dispose();
      _sceneHistory = null;
    }

    // 2. the trails, where the scene has them, over last frame's — which is not
    //    carried over from another scene.
    final fin = finishOf(scene, st);
    ui.Image current;
    final held = _history;
    if (fin.trails > 0 && st.macros.freeze && held != null && held.width == w && held.height == h && _historyScene == scene.id) {
      // Held still: the trails as they were (fed the same frame again and again, the
      // feedback would brighten a frozen picture).
      if (!feedsOnItself) drawn.dispose();
      current = held;
    } else if (fin.trails > 0) {
      final prev = _history;
      final usable = prev != null && prev.width == w && prev.height == h && _historyScene == scene.id;
      // The record's recipe, as much of it as the scene takes.
      final r = trailRecipe(scene, st);
      _feedback
        ..setFloat(0, w.toDouble())
        ..setFloat(1, h.toDouble());
      for (var i = 0; i < r.length; i++) {
        _feedback.setFloat(2 + i, r[i]);
      }
      _feedback
        ..setFloat(14, _time)
        ..setImageSampler(0, usable ? prev : drawn)
        ..setImageSampler(1, drawn);
      current = _pass(w, h, (c) => c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = _feedback));
      if (!feedsOnItself) drawn.dispose();
      _history?.dispose();
      _history = current;
      _historyScene = scene.id;
    } else {
      _history?.dispose();
      _history = null;
      _historyScene = null;
      current = drawn;
    }

    // 3. the scene being left, under a crossfade.
    ui.Image? leaving;
    final from = book[st.sceneFrom];
    if (from != null && st.sceneK < 1) leaving = _scene(from, st, w, h, live: false);

    // 4. the bloom, at half size.
    _blurH
      ..setFloat(0, hw.toDouble())
      ..setFloat(1, hh.toDouble())
      ..setFloat(2, 1)
      ..setFloat(3, 0)
      ..setFloat(4, 0.5)
      ..setFloat(5, 1.4)
      ..setImageSampler(0, current);
    final bh = _pass(hw, hh, (c) => c.drawRect(Rect.fromLTWH(0, 0, hw.toDouble(), hh.toDouble()), Paint()..shader = _blurH));
    _blurV
      ..setFloat(0, hw.toDouble())
      ..setFloat(1, hh.toDouble())
      ..setFloat(2, 0)
      ..setFloat(3, 1)
      ..setFloat(4, -1)
      ..setFloat(5, 1.4)
      ..setImageSampler(0, bh);
    final bloom = _pass(hw, hh, (c) => c.drawRect(Rect.fromLTWH(0, 0, hw.toDouble(), hh.toDouble()), Paint()..shader = _blurV));

    // 5. onto the screen.
    _finish
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, stageWhite(st))
      ..setFloat(3, st.macros.blackout ? 1 : 0)
      ..setFloat(4, fin.fringe)
      ..setFloat(5, fin.vignette)
      ..setFloat(6, fin.bloom)
      ..setFloat(7, leaving == null ? 0 : st.sceneK)
      ..setFloat(8, _time)
      ..setFloat(9, fin.grain)
      ..setFloat(10, fin.tone)
      ..setImageSampler(0, leaving ?? current)
      ..setImageSampler(1, bloom)
      ..setImageSampler(2, current);
    canvas.drawRect(Offset.zero & size, Paint()..shader = _finish);

    // 6. the words: a sim's own (the meme edit's captions), then the scene's.
    if (!preview && !st.macros.blackout) {
      for (final sim in _sims.values) {
        if (sim is SimOverlay) (sim as SimOverlay).paintOver(canvas, size, st, leaving == null ? 1 : st.sceneK);
      }
      _words(canvas, size, scene, st);
    }

    bh.dispose();
    bloom.dispose();
    leaving?.dispose();
    if (fin.trails <= 0 && !feedsOnItself) current.dispose();

    final took = _clock.elapsed - began;
    if (!stageSizeHeld && st.macros.adapt) working.frameAt(began.inMicroseconds);
    onFrame?.call(took);
  }

  void _words(Canvas canvas, Size size, Scene scene, ShowState st) => paintStageWords(canvas, size, scene, st, _rng);

  @override
  bool shouldRepaint(_StagePainter old) => true;

  void dispose() {
    _history?.dispose();
    _history = null;
    _sceneHistory?.dispose();
    _sceneHistory = null;
    _black?.dispose();
    _feedback.dispose();
    _blurH.dispose();
    _blurV.dispose();
    _finish.dispose();
    _treat?.dispose();
    _ghosts?.dispose();
    for (final s in _layerShaders.values) {
      s.dispose();
    }
    for (final sim in _sims.values) {
      sim.dispose();
    }
  }
}

/// A simulation the scene file named that does not exist: nothing drawn.
class _NoSim implements SimLayer {
  _NoSim(this.kind);
  @override
  final String kind;
  @override
  ui.Image? frame(ShowState st, double dt, int w, int h, StagePrograms p) => null;
  @override
  void dispose() {}
}

/// The covers, as images the shaders can sample, by track: fetched once each.
class StageCovers {
  StageCovers(this.onLoaded, {Map<int, ui.Image> given = const {}}) : _images = {...given}, _given = given.keys.toSet();
  final void Function() onLoaded;
  final Map<int, ui.Image?> _images;
  final Set<int> _given;
  final _streams = <int, (ImageStream, ImageStreamListener)>{};

  ui.Image? of(int? trackId, String? url) {
    if (trackId == null) return null;
    if (_images.containsKey(trackId)) return _images[trackId];
    if (url == null) return null;
    _images[trackId] = null;
    // `asset:` for a picture shipped with the app (the demo's cover).
    final provider = url.startsWith('asset:') ? AssetImage(url.substring(6)) as ImageProvider : NetworkImage(url);
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      _images[trackId] = info.image;
      onLoaded();
    }, onError: (_, __) {});
    stream.addListener(listener);
    _streams[trackId] = (stream, listener);
    return null;
  }

  void dispose() {
    for (final (s, l) in _streams.values) {
      s.removeListener(l);
    }
    for (final e in _images.entries) {
      if (!_given.contains(e.key)) e.value?.dispose();
    }
  }
}

/// The scene's words over a stage: the record's title, the line being sung, at the
/// screen's own size, so they stay sharp.
void paintStageWords(Canvas canvas, Size size, Scene scene, ShowState st, math.Random rng) {
  final m = st.master;
  final fin = finishOf(scene, st);
  final accent = st.palette.accent.toColor();
  final ink = Colors.white.withValues(alpha: 0.92);
  final big = fin.where == 'big';
  final margin = size.width * 0.05;
  final jitter = fin.jitter ? (st['audio.onset']) * 6 : 0.0;
  Offset shake() => jitter == 0 ? Offset.zero : Offset((rng.nextDouble() - 0.5) * jitter, (rng.nextDouble() - 0.5) * jitter);

  if (fin.title && m.title != null) {
    final title = big ? m.title!.toUpperCase() : m.title!;
    final tp = TextPainter(
      text: TextSpan(children: [
        TextSpan(text: title, style: Mag.headline(big ? size.height * 0.16 : size.height * 0.05, color: ink)),
        if (m.artist != null)
          TextSpan(text: '\n${m.artist}', style: Mag.flag(big ? size.height * 0.035 : size.height * 0.02, color: accent)),
      ]),
      textDirection: TextDirection.ltr,
      maxLines: 3,
      ellipsis: '…',
    )..layout(maxWidth: size.width - 2 * margin);
    final at = big
        ? Offset((size.width - tp.width) / 2, size.height * 0.12) + shake()
        : Offset(margin, size.height - margin - tp.height - (fin.lyrics ? size.height * 0.09 : 0));
    tp.paint(canvas, at);
  }

  if (fin.lyrics && m.lyric != null) {
    final style = Mag.title(big ? size.height * 0.07 : size.height * 0.045, color: ink);
    final tp = TextPainter(
      text: TextSpan(text: m.lyric, style: style),
      textDirection: TextDirection.ltr,
      textAlign: big ? TextAlign.center : TextAlign.left,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: size.width - 2 * margin);
    final at = big
        ? Offset((size.width - tp.width) / 2, size.height * 0.62) + shake()
        : Offset(margin, size.height - margin - tp.height);
    // The line sung so far in the accent, the rest in ink: a reveal.
    tp.paint(canvas, at);
    final sung = (m.lyricK * tp.width).clamp(0.0, tp.width);
    if (sung > 0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(at.dx, at.dy, sung, tp.height));
      TextPainter(
        text: TextSpan(text: m.lyric, style: style.copyWith(color: accent)),
        textDirection: TextDirection.ltr,
        textAlign: big ? TextAlign.center : TextAlign.left,
        maxLines: 2,
        ellipsis: '…',
      )
        ..layout(maxWidth: size.width - 2 * margin)
        ..paint(canvas, at);
      canvas.restore();
    }
  }
}
