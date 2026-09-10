import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/sleeve_board.dart';

/// The felt-pen colours a sleeve gets written on with.
///
/// Five. Enough that two people drawing on the same sleeve are telling apart, few
/// enough that choosing one is not a decision — eight was a paint program's worth on
/// something meant to be found by accident and used with a thumb. None of them are
/// bright: what is being drawn on is brown card, and ink on card is never as saturated
/// as ink on a screen.
const List<Color> sleeveInks = [
  Color(0xFF23201C),   // pencil
  Color(0xFFB23A2E),   // red
  Color(0xFF1F5FA6),   // biro blue
  Color(0xFF2E7D4F),   // green
  Color(0xFFF2EDE3),   // chalk
];

Color inkAt(int i) => sleeveInks[i % sleeveInks.length];

/// Bare board: the back of a sleeve before anybody writes on it.
///
/// Drawn rather than fetched, because there is nothing about it that belongs to any
/// one record — every sleeve in the world has roughly this back until somebody prints
/// on it. Kraft card, the grain of the stock, the fold down the spine, and corners a
/// shade darker from being handled.
class SleeveCard extends CustomPainter {
  /// The fibre in the card. One pattern, made once, tiled — a few hundred marks laid
  /// down per frame would be a lot of work for something nobody is meant to study.
  static final List<Offset> _fibres = () {
    final rng = math.Random(20260910);
    return [for (var i = 0; i < 240; i++) Offset(rng.nextDouble(), rng.nextDouble())];
  }();

  static final List<double> _lengths = () {
    final rng = math.Random(7);
    return [for (var i = 0; i < 240; i++) 0.004 + rng.nextDouble() * 0.02];
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = size.shortestSide * 0.012;
    final board = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    canvas.save();
    canvas.clipRRect(board);
    canvas.drawRect(rect, Paint()..color = const Color(0xFFBFB093));

    // Handled corners, a shade darker.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          radius: 0.78,
          colors: [Color(0x00000000), Color(0x22000000)],
          stops: [0.55, 1.0],
        ).createShader(rect),
    );

    final fibre = Paint()
      ..color = const Color(0x14000000)
      ..strokeWidth = math.max(1.0, size.width / 900);
    for (var i = 0; i < _fibres.length; i++) {
      final at = Offset(_fibres[i].dx * size.width, _fibres[i].dy * size.height);
      final run = _lengths[i] * size.width;
      canvas.drawLine(at, at.translate(run, run * 0.18), fibre);
    }

    // The fold, down the spine edge.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * 0.035, size.height),
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x33000000), Color(0x00000000)],
        ).createShader(Rect.fromLTWH(0, 0, size.width * 0.035, size.height)),
    );
    canvas.restore();
    canvas.drawRRect(
        board,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, size.width / 500)
          ..color = const Color(0x22000000));
  }

  @override
  bool shouldRepaint(SleeveCard old) => false;
}


/// What has been written on the back of this record.
///
/// Painted rather than composed of widgets: a board is a few hundred strokes and a
/// stroke is a few dozen points, and one path per stroke is the difference between a
/// drawing that appears and one that arrives.
class SleeveInk extends CustomPainter {
  SleeveInk({required this.board, required this.size01})
      : super(repaint: board);

  final SleeveBoard board;

  /// How wide the sleeve is, so a pen that is one unit wide is the same thickness
  /// whatever size the record is being drawn at.
  final double size01;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in board.strokes) {
      _line(canvas, size, stroke);
    }
    final live = board.drawing;
    if (live != null) _line(canvas, size, live);
  }

  /// One pass of the can.
  ///
  /// Three layers and it needs all three. A halo of overspray, wide and soft, which is
  /// what a nozzle actually puts on a wall; a denser core inside it; and a scatter of
  /// separate droplets along the way, because the edge of a sprayed line is never a
  /// line, it is where the dots run out.
  ///
  /// Painted over rather than into. It used to multiply, which is how ink sinks into
  /// paper — and it meant a pale colour laid over a dark one could not lighten it, so
  /// everything drifted towards the darkest thing on the board and black won every
  /// argument. Paint covers what it lands on.
  void _line(Canvas canvas, Size size, SleeveStroke stroke) {
    final points = stroke.points;
    if (points.length < 4) return;
    final colour = inkAt(stroke.ink);
    final w = stroke.width * size.width * 0.019;

    final path = Path()
      ..moveTo(points[0] * size.width, points[1] * size.height);
    // Through the middle of each pair rather than corner to corner: a line drawn by a
    // finger is sampled, and joining the samples straight gives it visible elbows.
    for (var i = 2; i + 3 < points.length; i += 2) {
      final cx = points[i] * size.width, cy = points[i + 1] * size.height;
      final nx = points[i + 2] * size.width, ny = points[i + 3] * size.height;
      path.quadraticBezierTo(cx, cy, (cx + nx) / 2, (cy + ny) / 2);
    }
    path.lineTo(points[points.length - 2] * size.width,
        points[points.length - 1] * size.height);

    Paint pass(double width, double alpha, double blur) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..strokeWidth = width
      ..color = colour.withValues(alpha: alpha)
      ..maskFilter = blur <= 0
          ? null
          : MaskFilter.blur(BlurStyle.normal, blur);

    canvas.drawPath(path, pass(w * 2.1, 0.16, w * 0.52));   // overspray
    canvas.drawPath(path, pass(w * 1.15, 0.55, w * 0.24));  // the edge of the cone
    canvas.drawPath(path, pass(w * 0.62, 0.95, w * 0.08));  // the middle of it

    _speckle(canvas, size, stroke, colour, w);
    _runs(canvas, size, stroke, colour, w);
  }

  /// The droplets that miss.
  void _speckle(Canvas canvas, Size size, SleeveStroke stroke, Color colour,
      double w) {
    final rng = math.Random(_seedOf(stroke.id));
    final points = stroke.points;
    final dot = Paint()..isAntiAlias = true;
    // Along the line rather than around the whole of it: spray lands where the can was
    // pointed, and thins out with distance from it.
    for (var i = 0; i + 1 < points.length; i += 2) {
      if (rng.nextDouble() > 0.55) continue;
      final x = points[i] * size.width, y = points[i + 1] * size.height;
      for (var n = 0; n < 3; n++) {
        final away = w * (0.6 + rng.nextDouble() * 1.5);
        final angle = rng.nextDouble() * math.pi * 2;
        dot.color = colour.withValues(alpha: 0.10 + rng.nextDouble() * 0.30);
        canvas.drawCircle(
            Offset(x + math.cos(angle) * away, y + math.sin(angle) * away),
            w * (0.045 + rng.nextDouble() * 0.10),
            dot);
      }
    }
  }

  /// Paint that has been laid on too thick, running down the board.
  ///
  /// Worked out from the stroke itself rather than recorded with it: the same id gives
  /// the same runs on every device that draws it, which is what makes a drip somebody
  /// else is watching appear in the same place as it does here — and it means a board
  /// carries no more over the wire than the lines that were drawn on it.
  void _runs(Canvas canvas, Size size, SleeveStroke stroke, Color colour, double w) {
    final rng = math.Random(_seedOf(stroke.id) ^ 0x5eed);
    final points = stroke.points;
    // More paint, more runs: a fat nib held over one spot is what makes them.
    final count = ((points.length / 24) * stroke.width).round().clamp(0, 4);
    if (count == 0) return;

    // How far the runs have got. One while the paint is wet, and they stop where they
    // stopped — a drip does not climb back up when it dries.
    final wet = board.wetness(stroke.id);
    final grown = wet <= 0 ? 1.0 : Curves.easeOutCubic.transform(1 - wet);

    for (var n = 0; n < count; n++) {
      final at = rng.nextInt(points.length ~/ 2) * 2;
      final x = points[at] * size.width;
      final y = points[at + 1] * size.height;
      // Never off the board: paint runs down a sleeve, not off the bottom of it.
      final room = size.height - y;
      final full = math.min(room, size.height * (0.04 + rng.nextDouble() * 0.13));
      if (full < w) continue;
      final length = full * grown;
      final thin = w * (0.16 + rng.nextDouble() * 0.16);

      // A tapering tail with a bead on the end, which is what a run actually looks
      // like: it carries the paint down with it and leaves less behind as it goes.
      final tail = Path()
        ..moveTo(x - thin, y)
        ..quadraticBezierTo(x - thin * 0.7, y + length * 0.6, x, y + length)
        ..quadraticBezierTo(x + thin * 0.7, y + length * 0.6, x + thin, y)
        ..close();
      canvas.drawPath(tail, Paint()
        ..isAntiAlias = true
        ..color = colour.withValues(alpha: 0.72));
      canvas.drawCircle(Offset(x, y + length), thin * 1.35,
          Paint()
            ..isAntiAlias = true
            ..color = colour.withValues(alpha: 0.9));
    }
  }

  /// A number from the stroke's own id, so every device draws the same spray.
  static int _seedOf(String id) {
    var h = 0x811c9dc5;
    for (final code in id.codeUnits) {
      h = ((h ^ code) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  @override
  bool shouldRepaint(SleeveInk old) => old.board != board;
}

/// Which pen, and how thick.
///
/// Sits under the record while it is turned over and nowhere else. Small on purpose:
/// this is the back of a sleeve, not an art program, and the whole of the pleasure is
/// that it is hardly there. No labels — a row of coloured dots under a record somebody
/// has just turned over does not need to be told what it is for.
class SleevePalette extends StatelessWidget {
  const SleevePalette({
    super.key,
    required this.ink,
    required this.width,
    required this.onInk,
    required this.onWidth,
    this.onWipe,
  });

  final int ink;
  final double width;
  final ValueChanged<int> onInk;
  final ValueChanged<double> onWidth;

  /// Clearing is the board owner's alone — in a jam, the host's.
  final VoidCallback? onWipe;

  /// Fat. This is a felt pen on cardboard and it is being used with a thumb, not a
  /// stylus: the thin end of the old range drew a line you had to look for.
  static const List<double> nibs = [1.2, 2.4, 4.0];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          for (var i = 0; i < sleeveInks.length; i++)
            _Dot(
              colour: sleeveInks[i],
              chosen: i == ink,
              onTap: () => onInk(i),
            ),
          const SizedBox(width: 4),
          for (final nib in nibs)
            _Nib(
              size: nib,
              chosen: (width - nib).abs() < 0.01,
              colour: scheme.onSurfaceVariant,
              onTap: () => onWidth(nib),
            ),
          if (onWipe != null)
            IconButton(
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              tooltip: 'Clear the sleeve',
              visualDensity: VisualDensity.compact,
              onPressed: onWipe,
            ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.colour, required this.chosen, required this.onTap});
  final Color colour;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: chosen ? 26 : 20,
          height: chosen ? 26 : 20,
          decoration: BoxDecoration(
            color: colour,
            shape: BoxShape.circle,
            border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: chosen ? 0.85 : 0.18),
              width: chosen ? 2 : 1,
            ),
          ),
        ),
      );
}

class _Nib extends StatelessWidget {
  const _Nib(
      {required this.size,
      required this.chosen,
      required this.colour,
      required this.onTap});
  final double size;
  final bool chosen;
  final Color colour;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 26,
          height: 26,
          child: Center(
            child: Container(
              width: 3 + size * 3.4,
              height: 3 + size * 3.4,
              decoration: BoxDecoration(
                color: colour.withValues(alpha: chosen ? 1 : 0.4),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      );
}

/// A magnifying glass over the point the pen is actually touching.
///
/// Drawing on a sleeve with a finger has one problem and it is the finger: the tip
/// covers exactly the part of the board you are trying to aim at, so you are always
/// drawing a centimetre behind where you are looking. Two answers together — the pen
/// draws a little above the fingertip rather than under it, and this shows that spot
/// enlarged, in a window held clear of the hand, with a crosshair on the exact point.
///
/// The board is painted again inside the glass rather than copied out of the screen:
/// the card and the ink are both drawings we make ourselves, so magnifying them means
/// scaling the canvas rather than blowing up pixels, and the enlarged line has the same
/// clean edge as the small one.
class SleeveLoupe extends CustomPainter {
  SleeveLoupe({
    required this.board,
    required this.card,
    required this.sleeve,
    required this.at,
    required this.centre,
    required this.radius,
    required this.nib,
    this.zoom = 2.4,
  }) : super(repaint: board);

  final SleeveBoard board;

  /// The bare card, so what is under the ink is the same board.
  final SleeveCard card;

  /// Where the sleeve is and how big it is, in the coordinates this paints in.
  final Rect sleeve;

  /// The point being drawn at, 0 to 1 across the sleeve.
  final Offset at;

  /// Where the glass itself sits.
  final Offset centre;
  final double radius;

  /// The pen's width, so the ring shows what the line will actually be.
  final double nib;

  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final glass = Rect.fromCircle(center: centre, radius: radius);
    final point = Offset(sleeve.left + at.dx * sleeve.width,
        sleeve.top + at.dy * sleeve.height);

    // The shadow the glass casts, so it reads as held above the record rather than
    // cut out of it.
    canvas.drawCircle(centre.translate(0, radius * 0.07),
        radius, Paint()
          ..color = const Color(0x44000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));

    canvas.save();
    canvas.clipPath(Path()..addOval(glass));
    // Everything under the glass, drawn again at size rather than sampled: move the
    // point of interest to the middle of the glass, scale about it, and paint the
    // board where it really is.
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(zoom);
    canvas.translate(-point.dx, -point.dy);
    canvas.translate(sleeve.left, sleeve.top);
    card.paint(canvas, sleeve.size);
    SleeveInk(board: board, size01: sleeve.width).paint(canvas, sleeve.size);
    canvas.restore();

    // The crosshair, on the exact spot the pen is on. Broken in the middle, so the
    // one place it matters is the one place nothing is drawn over.
    final hair = Paint()
      ..color = const Color(0xCC1A1714)
      ..strokeWidth = 1
      ..isAntiAlias = true;
    const gap = 5.0;
    final reach = radius * 0.42;
    canvas.drawLine(centre.translate(-reach, 0), centre.translate(-gap, 0), hair);
    canvas.drawLine(centre.translate(gap, 0), centre.translate(reach, 0), hair);
    canvas.drawLine(centre.translate(0, -reach), centre.translate(0, -gap), hair);
    canvas.drawLine(centre.translate(0, gap), centre.translate(0, reach), hair);

    // What the can will lay down, at the size it will lay it down: the whole cone,
    // not the dense middle of it, because the overspray is part of the mark.
    canvas.drawCircle(
        centre,
        nib * sleeve.width * 0.019 * 1.05 * zoom,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = inkAt(board.ink).withValues(alpha: 0.85));

    // The rim of the glass.
    canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0x55FFFFFF));
    canvas.drawCircle(
        centre,
        radius - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0x33000000));
  }

  @override
  bool shouldRepaint(SleeveLoupe old) =>
      old.at != at || old.centre != centre || old.sleeve != sleeve ||
      old.nib != nib || old.board != board;
}
