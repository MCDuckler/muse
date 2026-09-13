import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// The player growing out of the bar, and shrinking back into it.
class OpenFrom extends StatelessWidget {
  const OpenFrom(
      {super.key, required this.animation, required this.child, this.from});

  final Animation<double> animation;

  /// The bar's rectangle on screen. Null where nothing was tapped.
  final Rect? from;
  final Widget child;

  /// Stands in where there is no navigator to ask — a test, a preview.
  static final ValueNotifier<bool> _noGesture = ValueNotifier<bool>(false);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        // Whether a finger is on it right now. It changes how this is drawn, so it
        // has to be listened to rather than read once.
        valueListenable:
            Navigator.maybeOf(context)?.userGestureInProgressNotifier ?? _noGesture,
        builder: (context, byHand, _) => _build(context, byHand),
      );

  Widget _build(BuildContext context, bool byHand) {
    // Straight through while a finger is on it, and eased when it is playing by
    // itself.
    //
    // A curve is how something moves when nobody is moving it. Applied to a drag it
    // means the window runs ahead of the finger at the start and lags it at the end,
    // which is precisely the feeling of a thing not being held — so while the hand is
    // on it, a millimetre of finger is a millimetre of window.
    final curve = CurvedAnimation(
      parent: animation,
      curve: byHand ? Curves.linear : Curves.easeOutCubic,
      reverseCurve: byHand ? Curves.linear : Curves.easeInCubic,
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
        final corner = BorderRadius.circular(18 * (1 - t));
        // The page arrives over the bar rather than replacing it the instant the
        // window opens: for the first third of the way the bar is still what is in
        // there, showing through, and the page comes up through it. That cross-fade
        // is the difference between a panel being uncovered and the bar becoming the
        // page.
        final arrived = Curves.easeIn.transform((t / 0.55).clamp(0.0, 1.0));
        return Stack(
          children: [
            Positioned.fromRect(
              rect: window,
              // Lifted off what is behind it while it travels, and flat again once it
              // is the whole screen — a window with an edge reads as a thing being
              // opened rather than a hole appearing.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: corner,
                  // A blurred shadow is a filter pass on a screen-sized rectangle,
                  // every frame of the movement. Worth it where it is cheap; in a
                  // browser it is most of a frame's budget for an edge nobody is
                  // looking at while the thing behind it is opening.
                  boxShadow: kIsWeb
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.34 * (1 - t)),
                            blurRadius: 26 * (1 - t) + 6,
                            spreadRadius: 1,
                            offset: Offset(0, 6 * (1 - t)),
                          ),
                        ],
                ),
                child: ClipRRect(
                // Rounded like the bar it comes out of, square by the time it is the
                // screen.
                borderRadius: corner,
                child: Stack(
                  children: [
                  OverflowBox(
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
                  // The page arriving through a veil rather than at half opacity.
                  //
                  // It used to be an Opacity around the whole page, which is a
                  // screen-sized offscreen layer made again for every frame of the
                  // opening — the single most expensive thing in the movement, and on
                  // a phone or in a browser the reason it felt slow. A flat rectangle
                  // of the surface colour fading out looks the same and costs a fill.
                  if (arrived < 1)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          key: const Key('opening-veil'),
                          color: Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 1 - arrived),
                        ),
                      ),
                    ),
                  ],
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
