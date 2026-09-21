import 'package:flutter/material.dart';

/// One line of text that walks back and forth when it is too long for its row.
///
/// A song called something long used to end in an ellipsis, which is the one thing a
/// player must not do: the name of what is playing is the whole point of the screen.
/// Wrapping it instead moved everything above it, so this keeps to a single line and
/// moves the line rather than the layout.
///
/// It only animates when it has to. Text that fits is a plain [Text] with no ticker
/// behind it at all, which is nearly every song — and a ticker that is not there
/// cannot wake a phone up.
class BackAndForth extends StatefulWidget {
  const BackAndForth(
    this.text, {
    super.key,
    this.style,
    this.align = TextAlign.center,
    this.pace = 34,
    this.wait = const Duration(milliseconds: 1100),
  });

  final String text;
  final TextStyle? style;

  /// How the text sits when it fits. Ignored when it does not: something walking
  /// across its row starts at the left of it.
  final TextAlign align;

  /// How fast it walks, in logical pixels a second. Reading pace, not ticker-tape.
  final double pace;

  /// How long it holds still at each end before turning round.
  final Duration wait;

  @override
  State<BackAndForth> createState() => _BackAndForthState();
}

class _BackAndForthState extends State<BackAndForth>
    with SingleTickerProviderStateMixin {
  late final AnimationController _walk =
      AnimationController(vsync: this, duration: const Duration(seconds: 6));

  /// How much of the text is off the end of the row, in pixels.
  double _over = 0;

  @override
  void dispose() {
    _walk.dispose();
    super.dispose();
  }

  /// Start, stop or re-time the walk to suit what is being shown now.
  ///
  /// Called after layout rather than during it: how far there is to walk is a fact
  /// about the row the text was just given, and starting an animation in the middle of
  /// a build is a rebuild inside a build.
  void _settle(double over, Duration length) {
    if (over <= 0.5) {
      if (_walk.isAnimating) _walk.stop();
      if (_walk.value != 0) _walk.value = 0;
      return;
    }
    if (_walk.duration != length) _walk.duration = length;
    if (!_walk.isAnimating) _walk.repeat(reverse: true);
  }

  @override
  Widget build(BuildContext context) {
    // Merged the way Text merges it, because the height of the row is measured here
    // and drawn there: a style given without a line height picks the ambient one up
    // inside Text, and a painter that did not do the same measured a shorter line than
    // the one that got drawn.
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    // The line is as tall as the type says, whatever is written in it. Left to itself
    // a line is as tall as its tallest glyph, and a name with an emoji in it, or in a
    // script this typeface does not have, borrows those glyphs from another font with
    // a taller line: a pixel or two more for that one song. On the player the record
    // stands on top of this row, so it moved by that much on every such skip.
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
    return LayoutBuilder(
      builder: (context, c) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          // The same scale the Text below is drawn at. Without it, somebody with
          // large text set on their phone had a title measured at the small size and
          // clipped to that height — the bottom of every letter cut off.
          textScaler: MediaQuery.textScalerOf(context),
          strutStyle: strut,
        )..layout();
        final over = painter.width - c.maxWidth;
        // Flat at both ends and easing through the middle: the hold is what makes it
        // readable, and the whole point of walking it is that somebody can read the
        // end of it.
        final walk = (widget.wait.inMilliseconds * 2 +
                (over.clamp(0, 4000) / widget.pace * 1000))
            .round();
        final held = widget.wait.inMilliseconds / walk;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _settle(over, Duration(milliseconds: walk));
        });
        _over = over;

        if (over <= 0.5) {
          return Text(widget.text,
              maxLines: 1, textAlign: widget.align, style: style, strutStyle: strut);
        }
        // As tall as the line, and no taller: the row it is walking in is loosely
        // constrained, and a clip around an overflow box will happily take all the
        // height there is — which puts several hundred pixels of nothing under the
        // song's name.
        return SizedBox(
          height: painter.height,
          child: ClipRect(
          child: AnimatedBuilder(
            animation: _walk,
            builder: (context, child) {
              final t = Interval(held, 1 - held, curve: Curves.easeInOut)
                  .transform(_walk.value);
              return Transform.translate(
                offset: Offset(-_over * t, 0),
                child: child,
              );
            },
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.text,
                    maxLines: 1, softWrap: false, style: style, strutStyle: strut),
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}
