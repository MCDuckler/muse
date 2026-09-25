import 'dart:math' as math;

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

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final plate = radius * 0.88;
    final ring = radius * 0.79;
    final ringWidth = radius * 0.115;
    final disc = radius * 0.655;
    final chamfer = radius * 0.05;
    final on = lit.value;
    final pulse = (beat?.value ?? 0.0) * on;
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
    // Waiting: a brighter length of tube running round.
    final run = running;
    if (busy && run != null) {
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
          Transform.translate(
            offset: const Offset(0, 1),
            child: Opacity(
              opacity: 0.35,
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
                child: child,
              ),
            ),
          ),
          child,
        ],
      );
}
