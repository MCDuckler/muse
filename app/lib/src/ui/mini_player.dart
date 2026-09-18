import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'glass.dart';
import 'home_page.dart';
import 'player_bar.dart';

/// The player, at the bottom of a screen that is not the home shell.
///
/// It used to live only in the tab bar, so every screen you pushed — an album, an
/// artist, the downloads, a playlist — hid what was playing and took the controls with
/// it. Anywhere you can be looking at songs is somewhere you can want to skip one.
///
/// Draws nothing when there is nothing playing, so a screen opened on a fresh install
/// does not carry an empty bar around.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // Whether there is a player at all, not everything about it: this bar is under
    // every screen in the app, and watching the whole of the app state rebuilt it —
    // and the blur behind it — on every report of anything.
    final has = context.select<AppState, bool>((a) => a.player != null);
    if (!has) return const SizedBox.shrink();
    return GlassSurface(
      child: SafeArea(
        top: false,
        child: const PlayerBar(),
      ),
    );
  }
}

/// How much room a scrolling page has to leave at its bottom.
///
/// The player bar floats over the body — that is what makes it blur what is behind it —
/// so a list that ends where the screen ends puts its last row, or its last button,
/// underneath the bar where it cannot be reached. Lists that end in songs already left
/// room; this is the number, so the ones that end in a button leave it too.
///
/// Room for the tabs as well: they are under every screen rather than only under the
/// four at the top of the app, so the last row of any list has a bar and a half
/// beneath it — unless there is no bar there at all, which is the case on a desk with
/// the player folded out down the side. Reserving a phone's worth of nothing under
/// every list is how a desk layout ends up with a hole in it.
double bottomForPlayer(BuildContext context) =>
    InsideShell.bottomInset(context) ?? 168.0;

/// A page with the player under it. Every screen that shows songs uses this instead of
/// a bare Scaffold, so there is one answer to "where are the controls" everywhere.
class PlayerScaffold extends StatelessWidget {
  const PlayerScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.floatingActionButton,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    // Inside a tab the shell is still the screen: it is already carrying the player
    // and the four tabs at its bottom, and a second set under this page would be two
    // players stacked on one screen.
    final inShell = InsideShell.of(context);
    return Scaffold(
      appBar: appBar,
      body: body,
      backgroundColor: inShell ? Colors.transparent : null,
      floatingActionButton: floatingActionButton,
      // extendBody so the blur has something to blur, as in the home shell.
      extendBody: true,
      bottomNavigationBar: inShell
          ? null
          : GlassSurface(
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const PlayerBar(),
                    // A screen opened over the whole app — from the player, say —
                    // keeps the way out that every other screen has: tapping a tab
                    // closes it and goes there.
                    MuseNavigationBar(
                      onLeaving: () => Navigator.of(context, rootNavigator: true)
                          .popUntil((r) => r.isFirst),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
