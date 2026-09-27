import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/booth/booth.dart';
import '../feel.dart';
import 'desk/console.dart';

/// One band handed across between the decks, on one press.
///
/// The move is two hands at once — one record's bottom out as the other's comes up —
/// and done with two knobs it happens over however long two hands take. This does the
/// pair on the same beat.
///
/// Lit only when the band is lopsided (Booth.bandLopsided): with both decks' lows up,
/// swapping them is a shuffle rather than a move, so the button says so by being dark
/// and its tooltip says what to do about it.
class BandSwapButton extends StatelessWidget {
  const BandSwapButton({
    super.key,
    required this.booth,
    required this.band,
    required this.label,
    this.width = 32,
    this.height = 22,
  });

  final Booth booth;

  /// 0 low, 1 mid, 2 high.
  final int band;
  final String label;
  final double width, height;

  @override
  Widget build(BuildContext context) {
    final on = booth.mixer.canKill && booth.bandLopsided(band);
    return Tooltip(
      message: on
          ? 'Hand the $label over: what A has, B gets'
          : 'Take one deck\'s $label down to hand it over',
      child: Semantics(
        button: true,
        enabled: on,
        label: 'Swap the $label between the decks',
        child: InkWell(
          onTap: on
              ? () {
                  feel(Feel.pick);
                  unawaited(booth.swapBand(band));
                }
              : null,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: width,
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? Console.raised : null,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: on ? Console.ink : Console.line),
            ),
            // One line, always: "LOW" in a narrow box wrapped to "LO / W".
            child: Text(label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: Console.label(8, color: on ? Console.ink : Console.quiet)),
          ),
        ),
      ),
    );
  }
}
