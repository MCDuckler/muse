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

  /// How many cells across the board is. Coarse enough that a pixel is plainly a
  /// pixel and fine enough to write a legible word with.
  static const int grid = 72;

  /// One pass of the can, as pixels.
  ///
  /// Not an airbrush. A soft cone of colour with speckle round it is trying to be a
  /// photograph of spray paint and lands somewhere between the two — what it wanted
  /// to be was a *drawing* of spray paint, so it is one: a fixed grid, whole cells
  /// filled or not filled, and nothing in between. Everything else follows from that.
  /// The overspray is single stray cells rather than a blur, the runs are columns of
  /// cells rather than tapering tails, and the magnifying glass over it enlarges
  /// perfectly because there is nothing to enlarge but rectangles.
  void _line(Canvas canvas, Size size, SleeveStroke stroke) {
    final points = stroke.points;
    if (points.length < 4) return;

    final cell = size.width / grid;
    final colour = inkAt(stroke.ink);
    // The nib, in cells. A fat pen is a fat brush, not a blurrier one.
    final nib = stroke.width <= 1.5
        ? 1
        : stroke.width <= 3.0
            ? 2
            : 3;

    final filled = <int>{};
    void stamp(int cx, int cy) {
      // The brush is a square of cells centred on the point, so a thick line has
      // square ends, which is what a pixel brush does.
      final half = nib ~/ 2;
      for (var dy = 0; dy < nib; dy++) {
        for (var dx = 0; dx < nib; dx++) {
          final x = cx - half + dx, y = cy - half + dy;
          if (x < 0 || y < 0 || x >= grid || y >= grid) continue;
          filled.add(y * grid + x);
        }
      }
    }

    // Straight lines between the samples, on the grid. A finger is sampled every few
    // milliseconds and the gaps between samples are wider than a cell, so without this
    // a quick stroke is a dotted line.
    var px = (points[0] * grid).floor();
    var py = (points[1] * grid).floor();
    stamp(px, py);
    for (var i = 2; i + 1 < points.length; i += 2) {
      final nx = (points[i] * grid).floor();
      final ny = (points[i + 1] * grid).floor();
      _between(px, py, nx, ny, stamp);
      px = nx;
      py = ny;
    }

    final paint = Paint()
      ..isAntiAlias = false
      ..color = colour;
    for (final at in filled) {
      final x = at % grid, y = at ~/ grid;
      canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), paint);
    }

    _speckle(canvas, cell, stroke, colour, filled, nib);
    _runs(canvas, cell, stroke, colour, filled, nib);
  }

  /// Bresenham, so a line between two samples is a line and not a row of dots.
  static void _between(int x0, int y0, int x1, int y1, void Function(int, int) at) {
    var x = x0, y = y0;
    final dx = (x1 - x).abs(), dy = -(y1 - y).abs();
    final sx = x < x1 ? 1 : -1, sy = y < y1 ? 1 : -1;
    var err = dx + dy;
    // A stroke is bounded by the board, so this cannot run away — but a cap costs
    // nothing and a runaway loop inside a painter freezes the screen.
    for (var guard = 0; guard < grid * 4; guard++) {
      at(x, y);
      if (x == x1 && y == y1) return;
      final twice = err * 2;
      if (twice >= dy) {
        err += dy;
        x += sx;
      }
      if (twice <= dx) {
        err += dx;
        y += sy;
      }
    }
  }

  /// The cells that missed: single pixels beside the line, never touching it.
  void _speckle(Canvas canvas, double cell, SleeveStroke stroke, Color colour,
      Set<int> filled, int nib) {
    final rng = math.Random(_seedOf(stroke.id));
    final paint = Paint()..isAntiAlias = false;
    final line = filled.toList(growable: false);
    if (line.isEmpty) return;
    final count = (line.length * 0.22).round().clamp(0, 160);
    for (var n = 0; n < count; n++) {
      final from = line[rng.nextInt(line.length)];
      final x = from % grid + rng.nextInt(nib * 2 + 3) - (nib + 1);
      final y = from ~/ grid + rng.nextInt(nib * 2 + 3) - (nib + 1);
      if (x < 0 || y < 0 || x >= grid || y >= grid) continue;
      if (filled.contains(y * grid + x)) continue;
      // Fainter than the line itself, and never more than one cell: overspray is
      // where the paint ran out, not a softer edge of where it did not.
      paint.color = colour.withValues(alpha: 0.22 + rng.nextDouble() * 0.4);
      canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), paint);
    }
  }

  /// Paint laid on too thick, running down the board a cell at a time.
  ///
  /// Worked out from the stroke's own id rather than recorded with it, so the same line
  /// drips the same way on every device that draws it — and a board carries no more
  /// over the wire than the lines that were drawn on it.
  void _runs(Canvas canvas, double cell, SleeveStroke stroke, Color colour,
      Set<int> filled, int nib) {
    if (filled.isEmpty) return;
    final rng = math.Random(_seedOf(stroke.id) ^ 0x5eed);
    final count = ((filled.length / 90) * nib).round().clamp(0, 4);
    if (count == 0) return;

    // How far the runs have got. They stop where they stopped: a drip does not climb
    // back up when it dries.
    final wet = board.wetness(stroke.id);
    final grown = wet <= 0 ? 1.0 : Curves.easeOutCubic.transform(1 - wet);

    // The lowest cell in each column of the stroke — paint runs off the bottom edge of
    // what was painted, not out of the middle of it.
    final lowest = <int, int>{};
    for (final at in filled) {
      final x = at % grid, y = at ~/ grid;
      if ((lowest[x] ?? -1) < y) lowest[x] = y;
    }
    final columns = lowest.keys.toList(growable: false)..sort();

    final paint = Paint()
      ..isAntiAlias = false
      ..color = colour;
    for (var n = 0; n < count; n++) {
      final x = columns[rng.nextInt(columns.length)];
      final top = lowest[x]! + 1;
      final full = (3 + rng.nextInt(10)).clamp(0, grid - top);
      final length = (full * grown).round();
      if (length <= 0) continue;

      for (var i = 0; i < length; i++) {
        final y = top + i;
        if (y >= grid) break;
        // Thins as it goes, and the last cell sits one below a gap: a bead of paint
        // that has run ahead of the rest of it.
        final wide = i < length * 0.35 && nib > 1 ? 2 : 1;
        if (i == length - 1 && length > 3) continue;       // the gap
        for (var w = 0; w < wide; w++) {
          canvas.drawRect(
              Rect.fromLTWH((x + w) * cell, y * cell, cell + 0.5, cell + 0.5),
              paint);
        }
      }
      final bead = top + length;
      if (length > 3 && bead < grid) {
        canvas.drawRect(
            Rect.fromLTWH(x * cell, bead * cell, cell + 0.5, cell + 0.5), paint);
      }
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
    this.onTurnBack,
  });

  final int ink;
  final double width;
  final ValueChanged<int> onInk;
  final ValueChanged<double> onWidth;

  /// Clearing is the board owner's alone — in a jam, the host's.
  final VoidCallback? onWipe;

  /// Back to the front of the record. A gesture that only works one way is a gesture
  /// somebody is stuck inside: the way in was a swipe, and it is still there, but
  /// there has to be a way out you can see.
  final VoidCallback? onTurnBack;

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
          if (onTurnBack != null)
            IconButton(
              icon: const Icon(Icons.flip_camera_android_outlined, size: 20),
              tooltip: 'Turn the record back over',
              visualDensity: VisualDensity.compact,
              onPressed: onTurnBack,
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
/// covers exactly the part of the board you are trying to aim at. The pen stays under
/// the finger, where a pen belongs — what moves is the *view*: this shows the covered
/// spot enlarged, in a window held above the hand.
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

    // No crosshair. It was there to say which point of the enlarged board the pen was
    // on, back when the pen was somewhere the finger was not; with the nib under the
    // finger the middle of the glass is the middle of the glass, and four little lines
    // over the drawing are four little lines over the drawing.
    //
    // The cells the brush will fill, at the size it will fill them. A square, because
    // that is the shape of the mark — a circle here would be promising something the
    // pen cannot draw.
    final cellSize = sleeve.width / SleeveInk.grid * zoom;
    final wide = (board.nib <= 1.5 ? 1 : (board.nib <= 3.0 ? 2 : 3)) * cellSize;
    canvas.drawRect(
        Rect.fromCenter(center: centre, width: wide, height: wide),
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
