import 'package:flutter/material.dart';

/// What kind of screen this is.
///
/// Until now there was no such question anywhere in the app: one layout, a phone's,
/// and a desk got it stretched — a tab bar fourteen hundred pixels wide with its four
/// destinations a foot apart, and song rows so wide that the artwork and the menu
/// button at the end of the same row are nowhere near each other.
///
/// Three names, used everywhere, so "phone" stays exactly what ships today and the
/// wider screens are the ones that change.
enum Width {
  /// A phone, and the installed web app on one.
  compact,

  /// A tablet, a small window, half a screen.
  medium,

  /// A desk.
  expanded;

  static Width of(BuildContext context) =>
      forWidth(MediaQuery.sizeOf(context).width);

  static Width forWidth(double width) => width < 700
      ? Width.compact
      : width < 1100
          ? Width.medium
          : Width.expanded;

  /// Navigation down the side rather than across the bottom.
  bool get hasRail => this != Width.compact;

  /// Room beside the page for what is playing and what is next.
  bool get hasDock => this == Width.expanded;
}

/// A page, no wider than a page wants to be.
///
/// A list row on a desk ran the whole width of the window: forty pixels of artwork on
/// the left and the menu button for the same row a thousand pixels away, with the eye
/// having to travel the distance to read one song. Books settled this centuries ago —
/// past a certain measure a line stops being easier to read and starts being harder.
///
/// Grids are the exception and get the width, because more tiles across is what the
/// extra room is *for*.
class Readable extends StatelessWidget {
  const Readable({super.key, required this.child, this.maxWidth = 1100});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      );
}

/// Ask something in the way this screen asks things.
///
/// A bottom sheet is a phone idiom: it comes up from the bottom edge because that is
/// where the hand is. In a browser window nine hundred pixels tall it is a panel that
/// slides up from somewhere far below what anybody is looking at, and the thing it is
/// about — the row that was clicked — is at the top of the screen. On a desk the same
/// content belongs in a dialog, in the middle, where the eye already is.
///
/// Same builder either way, so there is one menu, one set of rows, and one place that
/// knows which shape a screen wants.
Future<T?> ask<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool scrollable = false,
  double dialogWidth = 520,
}) {
  if (Width.of(context) == Width.compact) {
    return showModalBottomSheet<T>(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      isScrollControlled: scrollable,
      builder: builder,
    );
  }
  return showDialog<T>(
    context: context,
    useRootNavigator: true,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          // Tall enough for a lyric, never taller than the window.
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: builder(context),
      ),
    ),
  );
}
