import 'package:flutter/widgets.dart';

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
