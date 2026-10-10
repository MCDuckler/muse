// The stage's first spike: is a multi-pass shader chain fast enough in Flutter on a
// desk? Five passes a frame — a noise field, trails over last frame's picture, a
// bloom in two directions at half size, and the composite onto the screen — with the
// pictures between them made by `toImageSync`, which is the only way a Flutter shader
// gets to read what another one drew.
//
// What it measures is printed every five seconds (`STAGE fps=…`): frames a second,
// and the typical and worst build and raster times. The beat is made up here (128,
// a build and a drop every 64 bars); the real engine replaces `_Clock` later.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The four programs, loaded once.
class ShowPrograms {
  ShowPrograms._(this.field, this.feedback, this.blur, this.composite);
  final ui.FragmentProgram field, feedback, blur, composite;

  static Future<ShowPrograms> load() async {
    final p = await Future.wait([
      ui.FragmentProgram.fromAsset('shaders/show/field.frag'),
      ui.FragmentProgram.fromAsset('shaders/show/feedback.frag'),
      ui.FragmentProgram.fromAsset('shaders/show/blur.frag'),
      ui.FragmentProgram.fromAsset('shaders/show/composite.frag'),
    ]);
    return ShowPrograms._(p[0], p[1], p[2], p[3]);
  }
}

/// A made-up record: 128 BPM, sixteen bars quiet, sixteen building, thirty-two on.
class _Clock {
  static const bpm = 128.0;
  final _start = DateTime.now();

  double get seconds => DateTime.now().difference(_start).inMicroseconds / 1e6;
  double get beat => seconds * bpm / 60;
  double get beatPhase => beat - beat.floorToDouble();
  double get barPhase => (beat / 4) - (beat / 4).floorToDouble();
  double get energy {
    final bar = (beat / 4) % 64;
    if (bar < 16) return 0.25;
    if (bar < 32) return 0.25 + 0.75 * ((bar - 16) / 16);
    return 1.0;
  }

  double get hue => (seconds * 0.01) % 1.0;
  bool get drop => (beat / 4) % 64 >= 32 && (beat / 4) % 64 < 32.5;
}

/// The spike on screen. [scale] is the render size as a share of the device pixels;
/// [flip] is handed to every shader that samples an image (see feedback.frag).
class ShowSpike extends StatefulWidget {
  const ShowSpike({super.key, required this.programs, this.scale = 1.0, this.flip = false, this.passes = 5});
  final ShowPrograms programs;
  final double scale;
  final bool flip;

  /// How much of the chain runs: 0 a flat fill (the control: what the window alone
  /// manages), 1 the field straight onto the screen, 2 with the trails, 5 everything.
  final int passes;

  @override
  State<ShowSpike> createState() => _ShowSpikeState();
}

class _ShowSpikeState extends State<ShowSpike> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _tick = ValueNotifier<int>(0);
  late final _Spike _painter;
  final _clock = _Clock();
  final _stats = _Stats();

  @override
  void initState() {
    super.initState();
    _painter = _Spike(widget.programs, _clock, _tick);
    _ticker = createTicker((_) => _tick.value++)..start();
    _stats.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _stats.stop();
    _painter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _painter.scale = widget.scale;
    _painter.flip = widget.flip;
    _painter.passes = widget.passes;
    _painter.dpr = MediaQuery.devicePixelRatioOf(context);
    _stats.what = () => _painter.lastSize;
    return RepaintBoundary(child: CustomPaint(painter: _painter, size: Size.infinite));
  }
}

class _Spike extends CustomPainter {
  _Spike(this.p, this.clock, Listenable tick) : super(repaint: tick) {
    _field = p.field.fragmentShader();
    _feedback = p.feedback.fragmentShader();
    _blurH = p.blur.fragmentShader();
    _blurV = p.blur.fragmentShader();
    _composite = p.composite.fragmentShader();
  }

  final ShowPrograms p;
  final _Clock clock;
  double scale = 1.0, dpr = 1.0;
  bool flip = false;
  int passes = 5;
  late final ui.FragmentShader _field, _feedback, _blurH, _blurV, _composite;
  ui.Image? _history;
  String lastSize = '';

  /// A pass: draw [shader] over a [w]×[h] picture and keep it as an image.
  ui.Image _pass(int w, int h, ui.FragmentShader shader) {
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = shader);
    final pic = r.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    return img;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = math.max(8, (size.width * dpr * scale).round());
    final h = math.max(8, (size.height * dpr * scale).round());
    // Three passes = no bloom to speak of: the blur runs over four pixels.
    final hw = passes <= 3 ? 4 : math.max(4, w ~/ 2), hh = passes <= 3 ? 4 : math.max(4, h ~/ 2);
    lastSize = '${w}x$h p$passes';
    final f = flip ? 1.0 : 0.0;

    if (passes <= 0) {
      // The control: a colour that changes, and nothing else.
      canvas.drawRect(Offset.zero & size, Paint()..color = Color.lerp(Colors.indigo, Colors.orange, clock.beatPhase)!);
      return;
    }

    // 1. the field
    _field
      ..setFloat(0, passes == 1 ? size.width : w.toDouble())
      ..setFloat(1, passes == 1 ? size.height : h.toDouble())
      ..setFloat(2, clock.seconds)
      ..setFloat(3, clock.beatPhase)
      ..setFloat(4, clock.barPhase)
      ..setFloat(5, clock.energy)
      ..setFloat(6, clock.hue);
    if (passes == 1) {
      canvas.drawRect(Offset.zero & size, Paint()..shader = _field);
      return;
    }
    final field = _pass(w, h, _field);

    // 2. trails over last frame (the first frame trails over itself)
    final prev = _history;
    if (prev != null && (prev.width != w || prev.height != h)) {
      prev.dispose();
      _history = null;
    }
    _feedback
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, 0.88)
      ..setFloat(3, 1.012)
      ..setFloat(4, 0.004)
      ..setFloat(5, f)
      ..setImageSampler(0, _history ?? field)
      ..setImageSampler(1, field);
    final trails = _pass(w, h, _feedback);
    if (passes == 2) {
      canvas.drawImageRect(trails, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Offset.zero & size, Paint());
      field.dispose();
      _history?.dispose();
      _history = trails;
      return;
    }

    // 3+4. bloom at half size
    _blurH
      ..setFloat(0, hw.toDouble())
      ..setFloat(1, hh.toDouble())
      ..setFloat(2, 1.0)
      ..setFloat(3, 0.0)
      ..setFloat(4, 0.55)
      ..setFloat(5, f)
      ..setImageSampler(0, trails);
    final bh = _pass(hw, hh, _blurH);
    _blurV
      ..setFloat(0, hw.toDouble())
      ..setFloat(1, hh.toDouble())
      ..setFloat(2, 0.0)
      ..setFloat(3, 1.0)
      ..setFloat(4, 0.0)
      ..setFloat(5, f)
      ..setImageSampler(0, bh);
    final bloom = _pass(hw, hh, _blurV);

    // 5. onto the screen
    _composite
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, clock.drop ? 0.8 * (1 - clock.beatPhase) : 0.0)
      ..setFloat(3, 0.012)
      ..setFloat(4, f)
      ..setImageSampler(0, trails)
      ..setImageSampler(1, bloom);
    canvas.drawRect(Offset.zero & size, Paint()..shader = _composite);

    field.dispose();
    bh.dispose();
    bloom.dispose();
    _history?.dispose();
    _history = trails;
  }

  void dispose() {
    _history?.dispose();
    _history = null;
    _field.dispose();
    _feedback.dispose();
    _blurH.dispose();
    _blurV.dispose();
    _composite.dispose();
  }

  @override
  bool shouldRepaint(_Spike old) => true;
}

/// The numbers, every five seconds, on stdout.
class _Stats {
  int _frames = 0, _build = 0, _raster = 0, _worstBuild = 0, _worstRaster = 0;
  Timer? _timer;
  String Function()? what;
  late final TimingsCallback _cb;

  void start() {
    _cb = (frames) {
      for (final f in frames) {
        _frames++;
        final b = f.buildDuration.inMicroseconds, r = f.rasterDuration.inMicroseconds;
        _build += b;
        _raster += r;
        if (b > _worstBuild) _worstBuild = b;
        if (r > _worstRaster) _worstRaster = r;
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_cb);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _say());
  }

  void _say() {
    final n = _frames;
    if (n == 0) return;
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    final line = 'STAGE fps=${(n / 5).toStringAsFixed(1)} size=${what?.call() ?? '?'} '
        'build ${ms(_build ~/ n)}/${ms(_worstBuild)} ms raster ${ms(_raster ~/ n)}/${ms(_worstRaster)} ms';
    // ignore: avoid_print
    print(line);
    _frames = _build = _raster = _worstBuild = _worstRaster = 0;
  }

  void stop() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_cb);
  }
}
