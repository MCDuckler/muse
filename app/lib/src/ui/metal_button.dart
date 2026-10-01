import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A round button made of metal and light: the play button, and the deck buttons in
/// the booth.
///
/// From the outside in. A dark plate it is set into, with its shadow under it. A
/// ring of light in the button's colour — a neon tube, thick, with a hot thread down
/// its middle and its bloom spilling onto the plate either side; lit while the thing
/// it does is happening, glass with a little colour in it while it is not, and with
/// a brighter length running round it while something is being waited for. A dark
/// gap. Then the disc: steel turned on a lathe, so its face is brushed in circles —
/// fine rings a hair lighter and darker in turn, and the two bright lobes opposite
/// each other that circular brushing throws back from a lamp at the top left, with the
/// metal's own grey between — with a machined chamfer round its edge, lit above and
/// dark below, and a soft sheen where the lamp catches its crown. Held down, the disc
/// sinks and the ring dims; on the beat, the bloom breathes.
class MetalFace extends CustomPainter {
  MetalFace({
    required this.colour,
    required this.pressed,
    required this.dark,
    required this.lit,
    this.running,
    this.busy = false,
    this.beat,
  }) : super(repaint: Listenable.merge([lit, if (running != null) running, if (beat != null) beat]));

  /// The ring's colour.
  final Color colour;
  final bool pressed;

  /// A dark plate (the player in the late edition, the booth) or a light one.
  final bool dark;

  /// How lit the ring is, 0 to 1.
  final Animation<double> lit;

  /// Where the running length of tube is, 0 to 1 round the ring, while [busy].
  final Animation<double>? running;
  final bool busy;

  /// The song's beat, one on it and falling to nothing: the bloom breathes with it.
  final ValueListenable<double>? beat;

  /// Faces already drawn, as pictures of themselves. See [paint].
  static final _baked = <Object, ui.Image>{};

  /// How finely the light is told apart in the baked faces: a fade of the ring is
  /// drawn in this many steps, which at a few hundred milliseconds is more steps than
  /// frames.
  static const _steps = 24;

  /// Drawn once and kept as a picture, then put down whole each frame.
  ///
  /// A face is a dozen soft-edged strokes — the bloom, the tube's thread, the shadow
  /// it stands in, the colour caught on the steel — and a stroke blurred is a pass of
  /// its own for the GPU. Impeller, which draws the desk, keeps nothing between
  /// frames: everything on screen is drawn again from its instructions every frame,
  /// still or not. With a dozen of these on the deck and the mixer, that was a large
  /// part of the time every frame took to draw while the booth stood still. As a
  /// picture it is one image drawn — and it only changes with the light, which is
  /// told apart in [_steps] steps.
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final on = lit.value;
    final pulse = (beat?.value ?? 0.0) * on;
    final dpr = ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0;
    // What spills past the button: its shadow and the ring's bloom.
    final margin = size.shortestSide * 0.45 + 8;
    final key = (
      size.width,
      size.height,
      dpr,
      colour,
      pressed,
      dark,
      (on * _steps).round(),
      (pulse * _steps).round(),
    );
    var image = _baked.remove(key);
    if (image == null) {
      final r = ui.PictureRecorder();
      final c = Canvas(r);
      c.scale(dpr);
      c.translate(margin, margin);
      _face(c, size, (key.$7) / _steps, (key.$8) / _steps);
      final picture = r.endRecording();
      image = picture.toImageSync(
          ((size.width + 2 * margin) * dpr).ceil(), ((size.height + 2 * margin) * dpr).ceil());
      picture.dispose();
      if (_baked.length >= 64) {
        final oldest = _baked.keys.first;
        _baked.remove(oldest)?.dispose();
      }
    }
    // Most recently used last, so the oldest is the first to go.
    _baked[key] = image;
    canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(-margin, -margin, image.width / dpr, image.height / dpr),
        Paint()..filterQuality = FilterQuality.medium);

    // Waiting: a brighter length of tube running round. Live, because it moves.
    final run = running;
    if (busy && run != null) {
      final c = size.center(Offset.zero);
      final radius = size.shortestSide / 2;
      final ring = radius * 0.79;
      final ringWidth = radius * 0.115;
      final at = run.value * 2 * math.pi;
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: ring),
          at,
          math.pi * 0.55,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = ringWidth * 1.1
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: 0.8)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, ringWidth * 0.4));
    }
  }

  void _face(Canvas canvas, Size size, double on, double pulse) {
    final c = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final plate = radius * 0.88;
    final ring = radius * 0.79;
    final ringWidth = radius * 0.115;
    final disc = radius * 0.655;
    final chamfer = radius * 0.05;
    final glow = (0.18 + 0.82 * on) * (pressed ? 0.6 : 1.0);
    final lamp = const Alignment(-0.7, -0.75);

    // What it stands on: a shadow it sinks into when pressed.
    final lift = pressed ? 0.4 : 1.0;
    canvas.drawCircle(
        c.translate(0, 3 * lift),
        plate,
        Paint()
          ..color = Colors.black.withValues(alpha: (dark ? 0.65 : 0.30) * (0.6 + 0.4 * lift))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * lift + 2));

    // The plate: near black, a shade lighter towards its middle; lighter metal in the
    // light edition. Its own turned edge, bright above and dark below.
    final body = Rect.fromCircle(center: c, radius: plate);
    canvas.drawCircle(
        c,
        plate,
        Paint()
          ..shader = RadialGradient(
            colors: dark
                ? const [Color(0xFF232327), Color(0xFF121215), Color(0xFF09090B)]
                : const [Color(0xFFE4E2DE), Color(0xFFC6C3BE), Color(0xFFA6A29C)],
            stops: const [0.0, 0.7, 1.0],
          ).createShader(body));
    canvas.drawCircle(
        c,
        plate - 0.6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: dark ? 0.22 : 0.9),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: dark ? 0.6 : 0.3),
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(body));

    // The ring of light. Its bloom first, either side of it on the plate and into the
    // gap; then the tube's dark edges, the tube, and the hot thread down its middle.
    final tube = Color.lerp(colour, Colors.white, 0.06)!;
    final hot = Color.lerp(colour, Colors.white, 0.62)!;
    final bloom = glow * (0.6 + 0.14 * pulse);
    canvas.drawCircle(
        c,
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth * 4.0
          ..color = colour.withValues(alpha: 0.75 * bloom)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.2));
    canvas.drawCircle(
        c,
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth * 1.9
          ..color = colour.withValues(alpha: 0.55 * bloom)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.07));
    canvas.drawCircle(
        c,
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth + 2.2
          ..color = Colors.black.withValues(alpha: dark ? 0.7 : 0.35));
    canvas.drawCircle(
        c,
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth
          ..color = Color.lerp(tube.withValues(alpha: 0.32), tube, glow)!);
    canvas.drawCircle(
        c,
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth * 0.40
          ..color = hot.withValues(alpha: 0.95 * glow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, ringWidth * 0.22));

    // The gap between the ring and the disc: dark, and the disc's seat in it — a
    // hairline of shadow the disc sits down into.
    canvas.drawCircle(
        c,
        disc + 2.0,
        Paint()
          ..color = Colors.black.withValues(alpha: dark ? 0.85 : 0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.8));

    // The chamfer: the disc's machined edge, a bright bevel above and to the left,
    // dark below and to the right.
    final face = Rect.fromCircle(center: c, radius: disc);
    Color grey(double v) => Color.fromRGBO((255 * v).round(), (255 * v).round(), (255 * (v * 0.98)).round(), 1);
    canvas.drawCircle(
        c,
        disc,
        Paint()
          ..shader = LinearGradient(
            begin: const Alignment(-0.9, -0.9),
            end: const Alignment(0.9, 0.9),
            colors: dark
                ? [grey(0.92), grey(0.55), grey(0.22), grey(0.40)]
                : [grey(1.0), grey(0.82), grey(0.55), grey(0.7)],
            stops: const [0.0, 0.4, 0.8, 1.0],
          ).createShader(face));

    // The face: brushed in circles. Circular brushing throws a lamp back in two lobes
    // opposite each other — bright top-left and bottom-right under a lamp at the top
    // left — with the metal's own grey between.
    final inner = disc - chamfer;
    final faceRect = Rect.fromCircle(center: c, radius: inner);
    final hi = dark ? 0.84 : 0.95, lo = dark ? 0.34 : 0.60;
    canvas.drawCircle(
        c,
        inner,
        Paint()
          ..shader = SweepGradient(
            center: Alignment.center,
            transform: const GradientRotation(-math.pi * 0.25),
            colors: [grey(hi), grey(lo), grey(hi * 0.9), grey(lo * 1.15), grey(hi)],
            stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
          ).createShader(faceRect));
    canvas.save();
    canvas.clipPath(Path()..addOval(faceRect));
    // The brushing: rings a hair lighter and darker in turn, each a little off in
    // width and weight — a lathe, not a printer.
    final brush = Paint()..style = PaintingStyle.stroke;
    var r = inner * 0.10;
    var i = 0;
    while (r < inner) {
      final h = ((i * 2654435761) & 0xFFFF) / 65535.0;
      final h2 = ((i * 40503 + 977) & 0xFFFF) / 65535.0;
      brush
        ..strokeWidth = 0.55 + 0.5 * h2
        ..color = (i.isEven ? Colors.white : Colors.black).withValues(alpha: 0.04 + 0.12 * h);
      canvas.drawCircle(c, r, brush);
      r += 0.9 + 1.0 * h;
      i++;
    }
    // The crown: a soft sheen where the lamp catches it, and the face turning away
    // towards its edge. Held down, the lamp catches it less.
    canvas.drawCircle(
        c,
        inner,
        Paint()
          ..shader = RadialGradient(
            center: lamp,
            radius: 1.1,
            colors: [
              Colors.white.withValues(alpha: pressed ? 0.04 : (dark ? 0.20 : 0.28)),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: pressed ? 0.32 : 0.22),
            ],
            stops: const [0.0, 0.5, 1.0],
          ).createShader(faceRect));
    // The ring's colour, caught faintly on the steel nearest it.
    canvas.drawCircle(
        c,
        inner - 0.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = inner * 0.18
          ..color = colour.withValues(alpha: 0.12 * glow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, inner * 0.09));
    canvas.restore();
    // Where the chamfer meets the face: a hairline.
    canvas.drawCircle(
        c,
        inner,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = Colors.black.withValues(alpha: dark ? 0.35 : 0.18));
  }

  @override
  bool shouldRepaint(MetalFace old) =>
      old.colour != colour || old.pressed != pressed || old.dark != dark || old.busy != busy || old.beat != beat;
}

/// The icon on a metal button: white, with the least shadow that lifts it off the
/// steel.
class MetalIcon extends StatelessWidget {
  const MetalIcon({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        alignment: Alignment.center,
        children: [
          // The shadow's own translucency is in its colour, not an Opacity over it:
          // the same picture, and one layer drawn off-screen instead of two.
          Transform.translate(
            offset: const Offset(0, 1),
            child: ColorFiltered(
              colorFilter: const ColorFilter.mode(Color(0x59000000), BlendMode.srcIn),
              child: child,
            ),
          ),
          child,
        ],
      );
}
