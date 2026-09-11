import 'dart:async';

import 'package:flutter/material.dart';

/// The wait, as a field of them.
///
/// One spinner in the middle of an empty screen says "something is happening" and
/// nothing else. The same spinner repeated across a diamond lattice says it for as long
/// as it takes, and the lattice is built outwards from the centre so the one in the
/// middle is exactly where a single one would have been — it does not shift when the
/// rest arrive, because it was never anywhere else.
///
/// They are offset in time rather than drawn in step: each ring starts a little after
/// the one inside it, so the field ripples outwards instead of pulsing as one slab.
class LoadingField extends StatelessWidget {
  const LoadingField({
    super.key,
    this.rings = 3,
    this.step = 34,
    this.stagger = const Duration(milliseconds: 110),
  });

  /// How far out the lattice goes. Rings that do not fit the screen are left off.
  final int rings;

  /// The lattice step. Neighbours sit a diagonal apart — step × √2 — which is what
  /// makes it a diamond rather than a grid of squares.
  final double step;

  /// How much later each ring starts than the one inside it.
  final Duration stagger;

  /// What a CircularProgressIndicator takes when nothing constrains it.
  static const spinner = 36.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final middle = Offset(box.maxWidth / 2, box.maxHeight / 2);
          final spots = <({Offset at, int ring})>[];
          for (var i = -2 * rings; i <= 2 * rings; i++) {
            for (var j = -2 * rings; j <= 2 * rings; j++) {
              // Half the cells of a square lattice — the ones whose coordinates sum
              // to an even number — is a square lattice turned by 45 degrees.
              if ((i + j).isOdd) continue;
              final ring = (i.abs() + j.abs()) ~/ 2;
              if (ring > rings) continue;
              final at = Offset(middle.dx + i * step, middle.dy + j * step);
              // Nothing half off the screen: a cut spinner reads as a mistake.
              if (at.dx - spinner / 2 < 0 || at.dx + spinner / 2 > box.maxWidth) {
                continue;
              }
              if (at.dy - spinner / 2 < 0 || at.dy + spinner / 2 > box.maxHeight) {
                continue;
              }
              spots.add((at: at, ring: ring));
            }
          }

          return Stack(
            children: [
              for (final spot in spots)
                Positioned(
                  left: spot.at.dx - spinner / 2,
                  top: spot.at.dy - spinner / 2,
                  width: spinner,
                  height: spinner,
                  child: _Later(
                    // The middle one is there from the first frame; it is the one the
                    // screen had before this existed.
                    after: stagger * spot.ring,
                    child: const CircularProgressIndicator(),
                  ),
                ),
            ],
          );
        },
      );
}

/// A thing that starts a moment from now.
///
/// The delay is what puts each ring out of step with the last: an indeterminate
/// spinner's animation starts when it does, so one built a beat later stays a beat
/// behind for as long as it is on screen.
class _Later extends StatefulWidget {
  const _Later({required this.after, required this.child});

  final Duration after;
  final Widget child;

  @override
  State<_Later> createState() => _LaterState();
}

class _LaterState extends State<_Later> {
  late bool _here = widget.after == Duration.zero;
  Timer? _waiting;

  @override
  void initState() {
    super.initState();
    if (!_here) {
      _waiting = Timer(widget.after, () {
        if (mounted) setState(() => _here = true);
      });
    }
  }

  @override
  void dispose() {
    _waiting?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: _here ? 1 : 0,
        duration: const Duration(milliseconds: 260),
        child: _here ? widget.child : const SizedBox.shrink(),
      );
}
