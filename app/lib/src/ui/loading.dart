import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The wait, as a field of them.
///
/// One spinner in the middle of an empty screen says "something is happening" and
/// nothing else. The same spinner, repeating across the whole screen on a diamond
/// lattice, says it for as long as it takes.
///
/// The lattice is half the cells of a square grid — the ones whose coordinates sum to
/// an even number — which is a square grid turned by 45 degrees: every circle has the
/// same four nearest neighbours at the same distance, in the same four directions, all
/// the way to the edges. It is laid out from the centre outwards, so the one in the
/// middle is exactly where a single spinner would have been and does not move.
///
/// They are drawn rather than assembled: one animation for the field, read at a
/// different point in its cycle for each ring, so they are permanently out of step
/// with one another and the whole thing ripples outwards. A hundred Material spinners
/// would be a hundred tickers and a hundred widgets to say the same thing.
class LoadingField extends StatefulWidget {
  const LoadingField({
    super.key,
    this.step = 26,
    this.stagger = 0.17,
  });

  /// The lattice step. Neighbours sit a diagonal apart — step × √2 — which is what
  /// makes it a diamond rather than a grid of squares.
  final double step;

  /// How much of a turn each ring is behind the one inside it.
  final double stagger;

  /// How big each one is drawn.
  ///
  /// A shade under the 36 a Material spinner takes when nothing constrains it: the
  /// pattern is the point here, and at 36 with the room to breathe it needs, a phone
  /// screen only fits five or six across — so the rings ran off the top and bottom
  /// with nothing at the sides.
  static const spinner = 30.0;

  /// Every place a spinner goes, in a box this size, and how far out each one is.
  ///
  /// Pure, and public, because "the middle one is where the single one used to be"
  /// and "they are evenly spaced to the edges" are the two things about this worth
  /// being sure of.
  static List<({Offset at, int ring})> spots(Size box, {double step = 26}) {
    final middle = Offset(box.width / 2, box.height / 2);
    final across = (box.width / 2 / step).ceil() + 1;
    final down = (box.height / 2 / step).ceil() + 1;
    final out = <({Offset at, int ring})>[];
    for (var j = -down; j <= down; j++) {
      for (var i = -across; i <= across; i++) {
        if ((i + j).isOdd) continue;
        final at = Offset(middle.dx + i * step, middle.dy + j * step);
        // Nothing half off the screen: a cut spinner reads as a mistake.
        if (at.dx - spinner / 2 < 0 || at.dx + spinner / 2 > box.width) continue;
        if (at.dy - spinner / 2 < 0 || at.dy + spinner / 2 > box.height) continue;
        out.add((at: at, ring: (i.abs() + j.abs()) ~/ 2));
      }
    }
    return out;
  }

  @override
  State<LoadingField> createState() => _LoadingFieldState();
}

class _LoadingFieldState extends State<LoadingField>
    with SingleTickerProviderStateMixin {
  // The same clock Material's own spinner runs on, so the drawing below is the same
  // drawing: one very long cycle containing thousands of turns.
  late final AnimationController _turning = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _Spinners.cycle),
  )..repeat();

  @override
  void dispose() {
    _turning.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _Spinners(
            turning: _turning,
            colour: Theme.of(context).colorScheme.primary,
            step: widget.step,
            stagger: widget.stagger,
          ),
        ),
      );
}

/// Material's indeterminate circle, drawn as many times as there is room for.
///
/// The arithmetic is theirs — the same two sawtooth cycles, the same interval curves,
/// the same arc — because the point is that these are the app's ordinary loading
/// circles and not some other spinner that happens to look similar. What is added is
/// where each one sits and how far through its turn it is.
class _Spinners extends CustomPainter {
  _Spinners({
    required this.turning,
    required this.colour,
    required this.step,
    required this.stagger,
  }) : super(repaint: turning);

  final Animation<double> turning;
  final Color colour;
  final double step;
  final double stagger;

  /// 1333 × 2222 milliseconds, as in the Material implementation: long enough to hold
  /// a whole number of both cycles below.
  static const int cycle = 1333 * 2222;
  static const int _paths = cycle ~/ 1333;
  static const int _rotations = cycle ~/ 2222;

  static const double _start = -math.pi / 2;
  static const double _strokeWidth = 3.5;

  static double _sawTooth(double t, int count) {
    final scaled = t * count;
    return scaled - scaled.truncateToDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;

    const head = Interval(0.0, 0.5, curve: Curves.fastOutSlowIn);
    const tail = Interval(0.5, 1.0, curve: Curves.fastOutSlowIn);

    for (final spot in LoadingField.spots(size, step: step)) {
      // A ring further out is a fraction of a turn behind. Offsetting the clock rather
      // than the drawing keeps every circle identical — it is simply earlier.
      final t = (turning.value + spot.ring * stagger / _paths) % 1.0;
      final along = _sawTooth(t, _paths);
      final headValue = head.transform(along);
      final tailValue = tail.transform(along);
      final rotation = _sawTooth(t, _rotations);

      final from = _start +
          tailValue * 3 / 2 * math.pi +
          rotation * math.pi * 2.0 +
          along * 0.5 * math.pi;
      final sweep =
          math.max(headValue * 3 / 2 * math.pi - tailValue * 3 / 2 * math.pi, 0.001);

      canvas.drawArc(
        Rect.fromCenter(
            center: spot.at,
            width: LoadingField.spinner,
            height: LoadingField.spinner),
        from,
        sweep,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Spinners old) =>
      old.colour != colour || old.step != step || old.stagger != stagger;
}
