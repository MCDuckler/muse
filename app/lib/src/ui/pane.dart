import 'package:flutter/material.dart';

/// Where a screen opened from a list should actually appear.
///
/// On a phone, on top of the list: there is one screen and everything takes turns on
/// it. On a desk the library is a column of places to go — all tracks, albums,
/// artists, twenty playlists — and covering it with whichever one you picked throws
/// away the very thing you are picking from. So beside it, in a pane of its own, with
/// the column staying where it is.
///
/// This is how a row says "open this" without having to know which of those two it is
/// in. Where there is a pane, [openPage] pushes into it; where there is not, it pushes
/// the way it always did.
class PaneScope extends InheritedWidget {
  const PaneScope({super.key, required this.pane, required super.child});

  /// The navigator of the pane beside the list.
  final GlobalKey<NavigatorState> pane;

  static NavigatorState? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PaneScope>()
      ?.pane
      .currentState;

  @override
  bool updateShouldNotify(PaneScope old) => old.pane != pane;
}

/// Open a screen from a list: beside it where there is room, over it where there is
/// not.
///
/// Answers what the route answered, so callers that wait for a result — "did they
/// make a playlist" — keep working either way.
Future<T?> openPage<T>(BuildContext context, WidgetBuilder builder) {
  final pane = PaneScope.of(context);
  final route = MaterialPageRoute<T>(builder: builder);
  if (pane == null) return Navigator.of(context).push(route);
  // One deep, not a stack: picking a second thing from the column replaces the first
  // rather than burying it, because the column *is* the way back.
  return pane.pushAndRemoveUntil(route, (r) => r.isFirst);
}
