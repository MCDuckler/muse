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

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../state/show/camera_feed.dart';
import '../../state/show/show_feed.dart';
import '../../state/show/show_state.dart';
import '../mag.dart';
import 'scene.dart';
import 'show_particles.dart';
import 'show_sims.dart';

/// Every program the stage draws with, loaded once.
class StagePrograms {
  StagePrograms._(this.scenes, this.sims, this.feedback, this.blur, this.finish);
  final Map<String, ui.FragmentProgram> scenes;

  /// The simulations' passes (shaders/show/sim/), by file name.
  final Map<String, ui.FragmentProgram> sims;
  final ui.FragmentProgram feedback, blur, finish;

  static const simShaders = ['fluid_advect', 'fluid_div', 'fluid_jacobi', 'fluid_project', 'fluid_look'];

  static Future<StagePrograms> load(SceneBook book) async {
    final names = book.shaders.toList();
    final loaded = await Future.wait([
      for (final n in names) ui.FragmentProgram.fromAsset('shaders/show/$n.frag'),
      for (final n in simShaders) ui.FragmentProgram.fromAsset('shaders/show/sim/$n.frag'),
      ui.FragmentProgram.fromAsset('shaders/show/feedback.frag'),
      ui.FragmentProgram.fromAsset('shaders/show/blur.frag'),
      ui.FragmentProgram.fromAsset('shaders/show/finish.frag'),
    ]);
    final k = names.length + simShaders.length;
    return StagePrograms._(
      {for (var i = 0; i < names.length; i++) names[i]: loaded[i]},
      {for (var i = 0; i < simShaders.length; i++) simShaders[i]: loaded[names.length + i]},
      loaded[k],
      loaded[k + 1],
      loaded[k + 2],
    );
  }
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

  @override
  State<ShowCanvas> createState() => _ShowCanvasState();
}

class _ShowCanvasState extends State<ShowCanvas> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _tick = ValueNotifier<int>(0);
  late final _StagePainter _painter;
  late final _Covers _covers;

  @override
  void initState() {
    super.initState();
    _covers = _Covers(() => _tick.value++, given: widget.covers);
    _painter = _StagePainter(widget.feed, widget.book, widget.programs, _covers, _tick, widget.scale, widget.preview);
    _ticker = createTicker((_) => _tick.value++)..start();
  }

  @override
  void didUpdateWidget(ShowCanvas old) {
    super.didUpdateWidget(old);
    _painter.feed = widget.feed;
  }

  @override
  void dispose() {
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

class _StagePainter extends CustomPainter {
  _StagePainter(this.feed, this.book, this.p, this.covers, Listenable tick, double scale, this.preview)
      : working = _Working(scale),
        super(repaint: tick) {
    _feedback = p.feedback.fragmentShader();
    _blurH = p.blur.fragmentShader();
    _blurV = p.blur.fragmentShader();
    _finish = p.finish.fragmentShader();
  }

  ShowFeed feed;
  final SceneBook book;
  final StagePrograms p;
  final _Covers covers;
  final bool preview;
  final _Working working;
  double dpr = 1;
  void Function(Duration took)? onFrame;

  late final ui.FragmentShader _feedback, _blurH, _blurV, _finish;
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
    final master = 'master';
    final beat = f['$master.beat.phase'] ?? 0;
    final bar = f['$master.bar.phase'] ?? 0;
    final phrase = f['$master.phrase.phase'] ?? 0;
    var i = 0;
    void set(double v) => s.setFloat(i++, v);
    set(w.toDouble());
    set(h.toDouble());
    set(_clock.elapsedMicroseconds / 1e6);
    set(beat);
    set(bar);
    set(phrase);
    set(f['$master.energy'] ?? 0);
    set(f['intensity'] ?? 0);
    set(f['audio.kick'] ?? 0);
    set(f['audio.low'] ?? 0);
    set(f['audio.mid'] ?? 0);
    set(f['audio.high'] ?? 0);
    set(f['audio.air'] ?? 0);
    set(f['audio.onset'] ?? 0);
    set(f['palette.primary.h'] ?? 0);
    set(f['palette.secondary.h'] ?? 0);
    set(f['$master.drop.near'] ?? 0);
    set(f['$master.build.k'] ?? 0);
    set(f['show.hit'] ?? 0);
    set(f['$master.vocal'] ?? 0);
    for (var k = 1; k <= 4; k++) {
      set(_knob(layer, k, st));
    }
    // The dynamics.
    set(f['dyn.hit.kick'] ?? 0);
    set(f['dyn.hit.snare'] ?? 0);
    set(f['dyn.hit.top'] ?? 0);
    set(f['dyn.beat.decay'] ?? 0);
    set(f['dyn.bar.decay'] ?? 0);
    set(f['dyn.bar.saw'] ?? 0);
    set(f['dyn.phrase.saw'] ?? 0);
    set(f['dyn.downbeat'] ?? 0);
    set(f['dyn.exposure'] ?? 0.7);
    set(f['dyn.band.low'] ?? 0);
    set(f['dyn.band.mid'] ?? 0);
    set(f['dyn.band.high'] ?? 0);
    set(f['$master.bar.index'] ?? 0);
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
      default:
        return black;
    }
  }

  ui.Image? _sceneHistory;
  DateTime? _cameraWantedAt;

  /// The camera, for a scene that needs it: started when one is on, stopped a
  /// while after none has been (unless the window pinned it).
  void _camera(Scene scene) {
    final cam = CameraFeed.shared;
    final wants = scene.meta.needs.contains('camera');
    final now = DateTime.now();
    if (wants) {
      _cameraWantedAt = now;
      if (!cam.running) unawaited(cam.start());
    } else if (cam.running && !cam.pinned) {
      final last = _cameraWantedAt;
      if (last == null || now.difference(last) > const Duration(seconds: 20)) cam.stop();
    }
  }

  /// A layer's knob: the record's genome where the scene is one of the camera's.
  double _knob(SceneLayer layer, int k, ShowState st) {
    final g = st.genome;
    if (!g.isEmpty) {
      if (layer.shader == 'echo' && k <= 3) return [g['camera.zoom'], g['camera.turn'], g['camera.hue']][k - 1];
      if (layer.shader == 'fold' && k == 1) return g['camera.fold'];
      if (layer.shader == 'blocks' && k == 1) return g['blocks.salt'];
      if (layer.shader == 'kinetic' && k == 1) return g['kinetic.salt'];
    }
    return layer.knob(k);
  }

  final _particles = <String, ParticleSystem>{};
  final _sims = <String, SimLayer>{};
  String? _particleScene;

  /// The scene drawn: its layers, one over the other, and its particles over them
  /// (the scene on, not one being left: [live]).
  ui.Image _scene(Scene scene, ShowState st, int w, int h, {bool live = true}) => _pass(w, h, (c) {
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
        if (!live || scene.particles.isEmpty) return;
        final primary = st.palette.primary.toColor();
        final accent = st.palette.accent.toColor();
        final t = _clock.elapsedMicroseconds / 1e6;
        for (final kind in scene.particles) {
          final sys = _particles.putIfAbsent(kind, () => ParticleSystem(kind));
          sys.step(st, st.macros.freeze ? 0 : _dt, w, h);
          sys.draw(c, primary, accent, t);
        }
      });

  /// Seconds since the last frame drawn here, for the particles.
  double _dt = 1 / 60;
  Duration? _lastFrameAt;

  @override
  void paint(Canvas canvas, Size size) {
    final began = _clock.elapsed;
    final lastAt = _lastFrameAt;
    _dt = lastAt == null ? 1 / 60 : ((began - lastAt).inMicroseconds / 1e6).clamp(0.0, 0.25);
    _lastFrameAt = began;
    var st = feed.state;
    if (st.macros.freeze) {
      st = _frozen ??= st;
    } else {
      _frozen = null;
    }
    final scene = book[st.scene] ?? book.scenes.values.firstOrNull;
    if (scene == null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
      return;
    }
    final w = math.max(8, (size.width * dpr * working.scale).round());
    final h = math.max(8, (size.height * dpr * working.scale).round());
    // The bloom at a quarter of the working size: wide and soft, and cheap.
    final hw = math.max(4, w ~/ 4), hh = math.max(4, h ~/ 4);
    final f = st.flat;
    final secondary = st.palette.secondary.toColor();

    _camera(scene);

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
    ui.Image current;
    if (scene.post.trails > 0) {
      final prev = _history;
      final usable = prev != null && prev.width == w && prev.height == h && _historyScene == scene.id;
      // The record's recipe, as much of it as the scene takes.
      final k = scene.post.recipe;
      final g = st.genome;
      double gene(String name, double or) => g.isEmpty ? or : or + (g[name] - or) * k;
      final decay = gene('feedback.decay', scene.post.trails);
      _feedback
        ..setFloat(0, w.toDouble())
        ..setFloat(1, h.toDouble())
        ..setFloat(2, decay)
        ..setFloat(3, gene('feedback.zoom', 1.0 + 0.010 * (f['master.energy'] ?? 0)))
        ..setFloat(4, gene('feedback.rotate', 0.003))
        ..setFloat(5, 0.12)
        ..setFloat(6, secondary.r)
        ..setFloat(7, secondary.g)
        ..setFloat(8, secondary.b)
        ..setFloat(9, k >= 0.5 && !g.isEmpty ? g['feedback.fold'] : 0)
        ..setFloat(10, gene('feedback.warp', 0))
        ..setFloat(11, gene('feedback.hueTurn', 0))
        ..setFloat(12, gene('feedback.shiftX', 0))
        ..setFloat(13, gene('feedback.shiftY', 0))
        ..setFloat(14, _clock.elapsedMicroseconds / 1e6)
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
    final beat = f['master.beat.phase'] ?? 0;
    final strobe = st.macros.strobe > 0 && ((beat * 4).floor() % 2 == 0) ? st.macros.strobe : 0.0;
    final hit = st.macros.hit;
    _finish
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, math.max(strobe, hit * 0.7))
      ..setFloat(3, st.macros.blackout ? 1 : 0)
      ..setFloat(4, scene.post.fringe)
      ..setFloat(5, scene.post.vignette)
      ..setFloat(6, scene.post.bloom)
      ..setFloat(7, leaving == null ? 0 : st.sceneK)
      ..setFloat(8, _clock.elapsedMicroseconds / 1e6)
      ..setFloat(9, scene.post.grain)
      ..setImageSampler(0, leaving ?? current)
      ..setImageSampler(1, bloom)
      ..setImageSampler(2, current);
    canvas.drawRect(Offset.zero & size, Paint()..shader = _finish);

    // 6. the words.
    if (!preview && !st.macros.blackout) _words(canvas, size, scene, st);

    bh.dispose();
    bloom.dispose();
    leaving?.dispose();
    if (scene.post.trails <= 0 && !feedsOnItself) current.dispose();

    final took = _clock.elapsed - began;
    working.frameAt(began.inMicroseconds);
    onFrame?.call(took);
  }

  void _words(Canvas canvas, Size size, Scene scene, ShowState st) {
    final m = st.master;
    final accent = st.palette.accent.toColor();
    final ink = Colors.white.withValues(alpha: 0.92);
    final big = scene.text.big;
    final margin = size.width * 0.05;
    final jitter = scene.text.jitter ? (st['audio.onset']) * 6 : 0.0;
    Offset shake() => jitter == 0 ? Offset.zero : Offset((_rng.nextDouble() - 0.5) * jitter, (_rng.nextDouble() - 0.5) * jitter);

    if (scene.text.title && m.title != null) {
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
          : Offset(margin, size.height - margin - tp.height - (scene.text.lyrics ? size.height * 0.09 : 0));
      tp.paint(canvas, at);
    }

    if (scene.text.lyrics && m.lyric != null) {
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
class _Covers {
  _Covers(this.onLoaded, {Map<int, ui.Image> given = const {}}) : _images = {...given}, _given = given.keys.toSet();
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
