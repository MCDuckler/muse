import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A printed halftone behind the record.
///
/// The idea is a magazine page rather than a visualiser: a screen of ink dots, the kind
/// a colour press lays down in rows at an angle, breathing slowly while the song plays.
/// It is meant to be noticed second — you should see the record, and then realise the
/// background is moving.
///
/// It does not pretend to be a spectrum. Nothing in the player gives us the audio
/// itself, and a bar chart invented from a timer would be a lie told sixty times a
/// second. What it does have is real: it moves while the song plays and settles when it
/// stops, and how much it moves comes from the track's own measured loudness, so a
/// quiet record breathes quietly.
///
/// Colour comes from the album and the theme together — the album's own tone for the
/// dots, the screen's ground behind them — so it belongs to whatever is on screen
/// rather than sitting on top of it.
class HalftoneBackdrop extends StatefulWidget {
  const HalftoneBackdrop({
    super.key,
    required this.colour,
    required this.playing,
    this.loudnessDb,
  });

  /// The album's colour, if it has one. The theme's accent stands in when it does not.
  final Color? colour;
  final bool playing;

  /// The track's measured loudness in LUFS, roughly -30 (quiet) to -5 (loud).
  final double? loudnessDb;

  @override
  State<HalftoneBackdrop> createState() => _HalftoneBackdropState();
}

class _HalftoneBackdropState extends State<HalftoneBackdrop>
    // Two clocks, so not the single-ticker mixin: it throws on the second one, the
    // widget never builds, and the whole screen it is behind comes up empty.
    with TickerProviderStateMixin {
  /// One slow pass every twelve seconds. The pattern is a field that drifts through
  /// itself; this is only the clock that moves it.
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  /// How awake the pattern is, 0 to 1. Eased rather than switched, so pausing settles
  /// the page instead of freezing a frame of it.
  late final AnimationController _life = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
    reverseDuration: const Duration(milliseconds: 2200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) {
      _clock.repeat();
      _life.forward();
    }
  }

  @override
  void didUpdateWidget(HalftoneBackdrop old) {
    super.didUpdateWidget(old);
    if (widget.playing) {
      if (!_clock.isAnimating) _clock.repeat();
      _life.forward();
    } else {
      _life.reverse();
      // The clock keeps turning while the pattern settles, then stops — stopping it
      // outright leaves the dots mid-breath.
      _life.addStatusListener(_stopWhenSettled);
    }
  }

  void _stopWhenSettled(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) {
      _clock.stop();
      _life.removeStatusListener(_stopWhenSettled);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = widget.colour ?? scheme.primary;

    // Loudness decides how far the dots swell. A track mastered quiet gets a quiet
    // page; -14 LUFS is about where streaming normalises, so that is the middle.
    final loud = widget.loudnessDb == null
        ? 0.5
        : ((widget.loudnessDb! + 26) / 18).clamp(0.0, 1.0);

    // A layer, not a wrapper. Wrapping the page changed the constraints it was laid
    // out with and the whole screen shrank to nothing; the backdrop takes this as a
    // fill behind its content instead, so the content is laid out exactly as before.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([_clock, _life]),
        builder: (context, _) => CustomPaint(
          painter: _HalftonePainter(
            phase: _clock.value,
            life: Curves.easeInOut.transform(_life.value),
            swell: 0.35 + 0.65 * loud,
            ink: ink,
            ground: scheme.surface,
          ),
        ),
      ),
    );
  }
}

class _HalftonePainter extends CustomPainter {
  _HalftonePainter({
    required this.phase,
    required this.life,
    required this.swell,
    required this.ink,
    required this.ground,
  });

  /// 0 to 1, wrapping. The field drifts by this much each pass.
  final double phase;

  /// How awake the pattern is.
  final double life;

  /// How far the dots are allowed to swell, from the track's loudness.
  final double swell;

  final Color ink;
  final Color ground;

  /// The press angle. Fifteen degrees is the screen angle a printer gives the lightest
  /// plate; square-on rows read as a grid, and a grid reads as a mistake.
  static const double _angle = 0.26;

  /// Distance between dot centres. Coarse on purpose: a fine screen at this size is
  /// grey, and the point is that you can see it is made of dots.
  static const double _pitch = 26.0;

  /// Smooth value noise from a hash — one field, sampled twice at different scales so
  /// the pattern has both a slow swell and some grain in it.
  double _noise(double x, double y) {
    final xi = x.floorToDouble(), yi = y.floorToDouble();
    final xf = x - xi, yf = y - yi;

    // Kept inside 32 bits at every step. On the web an int is a double underneath, so
    // a hash that overflows stops being an integer and the bitwise operations that
    // follow are no longer doing what they read as — which is a whole screen that
    // silently fails to paint, on one platform only.
    const mask = 0xFFFFFFFF;
    int at32(int v) => v & mask;
    double at(double px, double py) {
      var h = at32(px.toInt() * 374761393 + py.toInt() * 668265263);
      h = at32((h ^ (h >>> 13)) * 1274126177);
      return ((h ^ (h >>> 16)) & 0xFFFF) / 65535.0;
    }

    // Smoothstep between the four corners: cheap, and continuous where it matters.
    double fade(double t) => t * t * (3 - 2 * t);
    final u = fade(xf), v = fade(yf);
    final a = at(xi, yi), b = at(xi + 1, yi);
    final c = at(xi, yi + 1), d = at(xi + 1, yi + 1);
    return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (life <= 0.01) return;

    final paint = Paint()..isAntiAlias = true;
    final drift = phase * 2 * math.pi;

    // Rows run at the press angle, and the field is sampled in the rotated frame so
    // the whole screen moves as one sheet rather than as rows sliding past each other.
    final cos = math.cos(_angle), sin = math.sin(_angle);
    final reach = size.width + size.height;
    final rows = (reach / _pitch).ceil();

    for (var j = -rows; j <= rows; j++) {
      for (var i = -rows; i <= rows; i++) {
        final x = i * _pitch * cos - j * _pitch * sin;
        final y = i * _pitch * sin + j * _pitch * cos;
        if (x < -_pitch || y < -_pitch || x > size.width + _pitch ||
            y > size.height + _pitch) {
          continue;
        }

        // Two scales: a slow swell across the page, and a finer grain that keeps
        // neighbouring dots from moving in lockstep.
        final slow = _noise(i * 0.16 + phase * 2.0, j * 0.16 - phase * 1.2);
        final fine = _noise(i * 0.52 - phase * 3.0, j * 0.52 + phase * 2.4);
        final wave = 0.5 + 0.5 * math.sin(drift + (i + j) * 0.18);

        // A dot is mostly its own noise, nudged by the wave so the page has a
        // direction to it. Never bigger than the gap: touching dots are a smear.
        final amount = (0.34 * slow + 0.30 * fine + 0.36 * wave) * swell * life;
        final radius = amount * _pitch * 0.46;
        if (radius < 0.35) continue;

        // Denser dots are more opaque as well as larger, which is what ink does.
        paint.color = ink.withValues(alpha: 0.05 + 0.16 * amount * life);
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_HalftonePainter old) =>
      old.phase != phase ||
      old.life != life ||
      old.swell != swell ||
      old.ink != ink ||
      old.ground != ground;
}
