import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';

/// Light thrown off the mirror ball.
///
/// The logo is a disco ball, and a disco ball's whole job is to scatter small squares
/// of light that drift across a room while the music plays. So while a song plays,
/// they drift across the player: a handful of soft specks moving one way, as a ball
/// turning in one direction throws them, each brightening and dimming as its facet
/// catches the light.
///
/// Quiet on purpose — you should see the record first and the light second — and gone
/// when the music stops, fading rather than vanishing. Held still, not removed, for a
/// phone that has been asked to keep still: the light is still there, it just does not
/// travel.
///
/// Its own layer: the specks repaint every frame while they move, and nothing else on
/// the screen has to.
class MirrorBallLight extends StatefulWidget {
  const MirrorBallLight({super.key, required this.playing, this.tint, this.count = 16});

  final bool playing;

  /// The record's own colour, which the light picks up a little of, the way a room's
  /// light is coloured by what it bounces off.
  final Color? tint;
  final int count;

  @override
  State<MirrorBallLight> createState() => _MirrorBallLightState();
}

class _MirrorBallLightState extends State<MirrorBallLight>
    with SingleTickerProviderStateMixin {
  // A long loop, so the drift never visibly repeats.
  late final AnimationController _clock =
      AnimationController(vsync: this, duration: const Duration(minutes: 4));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _run();
  }

  @override
  void didUpdateWidget(MirrorBallLight old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) _run();
  }

  void _run() {
    if (widget.playing && !stillness(context)) {
      if (!_clock.isAnimating) _clock.repeat();
    } else {
      _clock.stop();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ExcludeSemantics(
          child: AnimatedOpacity(
            opacity: widget.playing ? 1 : 0,
            duration: moving(context, const Duration(milliseconds: 900)),
            curve: Curves.easeOut,
            child: RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: _Specks(
                  clock: _clock,
                  count: widget.count,
                  tint: widget.tint,
                ),
              ),
            ),
          ),
        ),
      );
}

class _Specks extends CustomPainter {
  _Specks({required this.clock, required this.count, this.tint}) : super(repaint: clock);

  final AnimationController clock;
  final int count;
  final Color? tint;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final seconds = clock.value * 240;
    final rng = math.Random(39);
    final light = Color.lerp(Colors.white, tint ?? Colors.white, 0.18)!;
    for (var i = 0; i < count; i++) {
      // Everything about a speck is fixed by its number; only time moves it.
      final x0 = rng.nextDouble();
      final y0 = rng.nextDouble();
      final speed = 0.006 + rng.nextDouble() * 0.012;   // screen widths a second
      final lift = (rng.nextDouble() - 0.5) * 0.004;
      final size0 = 1.6 + rng.nextDouble() * 3.4;
      final phase = rng.nextDouble() * math.pi * 2;
      final twinkle = 0.6 + rng.nextDouble() * 1.4;

      final x = ((x0 + speed * seconds) % 1.2) - 0.1;
      final y = ((y0 + lift * seconds) % 1.1) - 0.05;
      final glint = 0.5 + 0.5 * math.sin(seconds * twinkle + phase);
      final alpha = 0.10 + 0.42 * glint;
      final at = Offset(x * size.width, y * size.height);
      final r = size0 * (0.8 + 0.4 * glint);

      // A soft square of light, the shape a mirror tile throws, turned a little.
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(0.35 + i * 0.2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: r * 2, height: r * 2),
            Radius.circular(r * 0.5)),
        Paint()
          ..color = light.withValues(alpha: alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.7),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Specks old) => old.count != count || old.tint != tint;
}
