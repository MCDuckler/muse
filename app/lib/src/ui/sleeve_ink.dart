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

  void _line(Canvas canvas, Size size, SleeveStroke stroke) {
    final points = stroke.points;
    if (points.length < 4) return;

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

    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..strokeWidth = stroke.width * size.width * 0.019
      ..color = inkAt(stroke.ink)
      // Ink sinks into card rather than sitting on top of it, and multiply is what
      // that looks like: the grain of the board shows through the line.
      ..blendMode = BlendMode.multiply;

    // The mark a pen leaves where it presses hardest, under the line proper. Almost
    // nothing on its own; together they are why it reads as a pen and not a stylus.
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true
          ..strokeWidth = pen.strokeWidth * 1.5
          ..color = inkAt(stroke.ink).withValues(alpha: 0.18)
          ..blendMode = BlendMode.multiply);
    canvas.drawPath(path, pen);
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
