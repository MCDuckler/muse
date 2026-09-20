import 'package:flutter/material.dart';

/// A line between two areas that can be taken hold of.
///
/// Every width in a desk layout is a guess about somebody else's screen: 330 for the
/// library's column is generous at 1280 and mean at 2560, and the right number also
/// depends on how long their playlists' names are and how much of the page they want.
/// A line you can pull settles all of that without anybody having to be right.
///
/// It reports a width rather than keeping one, because what it is dividing knows where
/// to remember it: a pane and a dock want their own numbers, and both want them on the
/// next launch.
class Grabbable extends StatefulWidget {
  const Grabbable({
    super.key,
    required this.width,
    required this.onChanged,
    required this.min,
    required this.max,
    this.fromRight = false,
    this.onSettled,
  });

  /// What the area beside this line is now.
  final double width;

  /// Where the drag has got to, live, so the layout follows the hand.
  final ValueChanged<double> onChanged;

  /// Where it ended up, once the hand lets go — for whoever writes it down.
  final ValueChanged<double>? onSettled;

  /// How far it can be pulled either way. A pane nobody can read and a pane with no
  /// room left beside it are both worse than a line that stops.
  final double min;
  final double max;

  /// Whether the area being sized is to the right of the line, in which case dragging
  /// right makes it smaller rather than bigger.
  final bool fromRight;

  @override
  State<Grabbable> createState() => _GrabbableState();
}

class _GrabbableState extends State<Grabbable> {
  bool _hovered = false;
  bool _dragging = false;
  double _at = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lit = _hovered || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) {
          _at = widget.width;
          setState(() => _dragging = true);
        },
        onHorizontalDragUpdate: (d) {
          _at = (_at + (widget.fromRight ? -d.delta.dx : d.delta.dx))
              .clamp(widget.min, widget.max);
          widget.onChanged(_at);
        },
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onSettled?.call(_at);
        },
        // A hit area wide enough to catch with a mouse, and a line thin enough to
        // read as a line: eight pixels of reach around one pixel of ink.
        child: SizedBox(
          width: 9,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: lit ? 3 : 1,
              color: lit ? scheme.primary : scheme.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}
