import 'package:flutter/material.dart';

/// The player growing out of the bar, and shrinking back into it.
class OpenFrom extends StatelessWidget {
  const OpenFrom(
      {super.key, required this.animation, required this.child, this.from});

  final Animation<double> animation;

  /// The bar's rectangle on screen. Null where nothing was tapped.
  final Rect? from;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Decelerating in, accelerating out — thrown open and settling, rather than
    // moving at a constant speed in both directions.
    final curve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final here = from;
    if (here == null) {
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
            .animate(curve),
        child: child,
      );
    }

    final screen = MediaQuery.sizeOf(context);
    final full = Offset.zero & screen;
    return AnimatedBuilder(
      animation: curve,
      // The page is built once and handed through: only the window it is seen
      // through changes, so none of it is rebuilt for any frame of this.
      child: child,
      builder: (context, page) {
        final t = curve.value;
        // Arrived: no clip, no window, nothing left over the page for as long as it
        // is open — and the record on it is the busiest thing the app draws.
        if (t >= 1) return page!;
        final window = Rect.lerp(here, full, t)!;
        return Stack(
          children: [
            Positioned.fromRect(
              rect: window,
              child: ClipRRect(
                // Rounded like the bar it comes out of, square by the time it is the
                // screen.
                borderRadius: BorderRadius.circular(18 * (1 - t)),
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: screen.width,
                  maxWidth: screen.width,
                  minHeight: screen.height,
                  maxHeight: screen.height,
                  // The page is drawn where it will finally sit, from the first frame
                  // to the last, and the window is a porthole opening onto it.
                  //
                  // Nothing inside it moves or changes shape — which matters most at
                  // the bottom of the screen, where the queue/search/library bar is:
                  // anchored to the window instead, it slid down into place over the
                  // identical bar underneath, so the one row of controls that is
                  // supposed to be constant was the thing most obviously in motion.
                  child: Transform.translate(
                    offset: -window.topLeft,
                    child: page,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
