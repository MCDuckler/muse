import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'motion.dart';

/// Light thrown off the mirror ball.
///
/// The logo is a disco ball, and what a disco ball does is particular. It is a sphere
/// of small flat mirrors in rings, with a couple of coloured lamps pointed at it, and
/// it turns. So the room fills with *rows* of small bright spots that all swing the
/// same way at once, in arcs, slow in front of you and quickening and stretching as
/// they slide off towards the corners — and each lamp throws its own set, the same
/// pattern over again a hand's width along in another colour.
///
/// That is what this draws, by doing the sum rather than by imitating the look: a ball
/// above the top of the page, rings of tiles on it, a ray off every tile, and where the
/// ray meets the page. What it used to draw was a handful of blurred white specks each
/// wandering on its own, which is what dust in a sunbeam does.
///
/// Quiet on purpose — you should see the record first and the light second — and gone
/// when the music stops, fading rather than vanishing. Held still, not removed, for a
/// phone that has been asked to keep still: the light is still there, it just does not
/// travel.
///
/// Its own layer: the spots repaint every frame while they move, and nothing else on
/// the screen has to.
class MirrorBallLight extends StatefulWidget {
  const MirrorBallLight({super.key, required this.playing, this.tint, this.pulse});

  final bool playing;

  /// The song's beat, one on it and falling to nothing: the light flares with it. A
  /// mirror ball in a room is lit by whatever the lighting desk is doing, and the desk
  /// is doing it in time. Null, or a song with no beats, and it drifts as it always did.
  final ValueListenable<double>? pulse;

  /// The record's own colour, which the light picks up a little of, the way a room's
  /// light is coloured by what it bounces off.
  final Color? tint;

  @override
  State<MirrorBallLight> createState() => _MirrorBallLightState();
}

class _MirrorBallLightState extends State<MirrorBallLight>
    with SingleTickerProviderStateMixin {
  // Three turns of the ball in four minutes: a whole number of them, so the loop
  // comes round to exactly where it started and there is no frame where every spot
  // jumps.
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onPaper = scheme.brightness == Brightness.light;
    final album = widget.tint ?? scheme.primary;
    // The lamps. A club points two or three at the ball with gels on them; here the
    // gels are the record's own colour, the highlighter off the magazine's pages, and
    // one left clear. On paper a clear lamp is white on white, so there it is the
    // masthead's ink instead, and everything is laid on a little heavier.
    final lamps = [
      onPaper ? scheme.primary : const Color(0xFFFFF4DA),
      _gel(album, onPaper),
      const Color(0xFFFFE14D),
    ];
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedOpacity(
          opacity: widget.playing ? 1 : 0,
          duration: moving(context, const Duration(milliseconds: 900)),
          curve: Curves.easeOut,
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.infinite,
              painter: _Spots(
                clock: _clock,
                lamps: lamps,
                strength: onPaper ? 0.8 : 1.0,
                pulse: widget.pulse,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A cover's colour as a gel: the same hue, but as saturated and as bright as a
  /// light is. A cover that is nearly black still has a hue, and a lamp with a nearly
  /// black gel on it is a lamp that is off.
  static Color _gel(Color from, bool onPaper) {
    final hsl = HSLColor.fromColor(from);
    return hsl
        .withSaturation(math.max(hsl.saturation, 0.75))
        .withLightness(onPaper ? 0.52 : 0.66)
        .toColor();
  }
}

/// One spot of light on the page.
class BallSpot {
  const BallSpot({
    required this.at,
    required this.wide,
    required this.tall,
    required this.lean,
    required this.far,
    required this.lamp,
    required this.tile,
  });

  final Offset at;
  final double wide;
  final double tall;

  /// How far it is turned: a spot lies along the arc it is travelling.
  final double lean;

  /// How much further the light has come than the shortest way to the page, one and
  /// up. Further is dimmer.
  final double far;
  final int lamp;

  /// Which tile threw it, the same number for as long as the ball turns.
  final int tile;
}

/// Where the ball's light lands on a page of [size], with the ball turned by [turn]
/// radians and [lamps] lamps on it.
///
/// The ball hangs above the top of the page and a little in front of it. A tile at
/// azimuth φ and tipped θ below level sends its ray to x = d·tan φ, y = d·tan θ / cos φ
/// on a wall d away — which is the whole of the look: rows that sag into arcs, spots
/// that speed up and smear as φ grows, and nothing at all from the half of the ball
/// that faces away.
List<BallSpot> spotsOnThePage(Size size, double turn, {int lamps = 3}) {
  final spots = <BallSpot>[];
  if (size.isEmpty) return spots;
  // A wide window is a wide room: the wall is further off, so the spots do not all
  // crowd into a fan at the top.
  final d = math.max(size.height * 0.55, size.width * 0.42);
  final cx = size.width / 2, cy = -size.height * 0.06;
  final base = 7.5 * (size.shortestSide / 400).clamp(1.0, 1.6);
  const rings = 6;
  var tile = 0;
  for (var ring = 0; ring < rings; ring++) {
    final tip = 0.16 + ring * 0.17;
    // Fewer tiles round a ring nearer the pole, as on the ball itself.
    final around = (26 * math.cos(tip)).round();
    for (var k = 0; k < around; k++, tile++) {
      // No ball is glued perfectly: every tile is a hair off true, always by the same
      // hair. It is what keeps the rows from reading as a printed grid.
      final h = ((tile * 2654435761) & 0xFFFF) / 65535.0;
      final h2 = ((tile * 40503 + 977) & 0xFFFF) / 65535.0;
      for (var lamp = 0; lamp < lamps; lamp++) {
        var phi = (k / around) * 2 * math.pi +
            turn +
            ring * 0.37 +
            lamp * 0.115 +
            (h - 0.5) * 0.07;
        phi = (phi + math.pi) % (2 * math.pi) - math.pi;
        if (phi.abs() > 1.2) continue;
        final theta = tip + lamp * 0.05 + (h2 - 0.5) * 0.05;
        final cosPhi = math.cos(phi), cosTheta = math.cos(theta);
        final x = cx + d * math.tan(phi);
        final y = cy + d * math.tan(theta) / cosPhi;
        if (x < -40 || x > size.width + 40 || y < -40 || y > size.height + 40) continue;
        spots.add(BallSpot(
          at: Offset(x, y),
          wide: base * math.min(2.6, 1 / (cosPhi * cosPhi)),
          tall: base * math.min(2.2, 1 / (cosPhi * cosTheta)),
          lean: math.atan(math.tan(theta) * math.sin(phi)),
          far: 1 / (cosPhi * cosTheta),
          lamp: lamp,
          tile: tile,
        ));
      }
    }
  }
  return spots;
}

class _Spots extends CustomPainter {
  _Spots({required this.clock, required this.lamps, required this.strength, this.pulse})
      : super(repaint: pulse == null ? clock : Listenable.merge([clock, pulse]));

  final AnimationController clock;
  final List<Color> lamps;
  final double strength;
  final ValueListenable<double>? pulse;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final turn = clock.value * 3 * 2 * math.pi;
    final seconds = clock.value * 240;
    final beat = pulse?.value ?? 0.0;
    final glow = Paint();
    final core = Paint();
    for (final spot in spotsOnThePage(size, turn, lamps: lamps.length)) {
      // A tile catches its lamp a little more and a little less as the ball swings;
      // on the beat the desk pushes every lamp up, and some tiles make more of it
      // than others.
      final glint = 0.5 + 0.5 * math.sin(seconds * 0.9 + spot.tile * 1.7);
      final catches = 0.5 + 0.5 * ((spot.tile * 7) % 5) / 4;
      final reach = 1 / math.pow(spot.far, 1.1);
      final alpha =
          ((0.20 + 0.16 * glint + 0.50 * beat * catches) * reach * strength).clamp(0.0, 0.9);
      if (alpha < 0.02) continue;
      final swell = 1 + 0.22 * beat * catches;
      final colour = lamps[spot.lamp];

      canvas.save();
      canvas.translate(spot.at.dx, spot.at.dy);
      canvas.rotate(spot.lean);
      final shape = RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset.zero, width: spot.wide * swell, height: spot.tall * swell),
          const Radius.circular(1.6));
      // The bloom round it, then the spot itself with only its edge softened: a mirror
      // tile throws a shape, and a blurred blob is what made these look like dust.
      glow
        ..color = colour.withValues(alpha: alpha * 0.45)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, spot.wide * 0.7);
      core
        ..color = colour.withValues(alpha: alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.7);
      canvas.drawRRect(shape.inflate(spot.wide * 0.35), glow);
      canvas.drawRRect(shape, core);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_Spots old) =>
      !listEquals(old.lamps, lamps) || old.strength != strength || old.pulse != pulse;
}
