import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'glass.dart';
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
    final app = context.watch<AppState>();
    if (app.player == null) return const SizedBox.shrink();
    return GlassSurface(
      child: SafeArea(
        top: false,
        child: const PlayerBar(),
      ),
    );
  }
}

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
    return Scaffold(
      appBar: appBar,
      body: body,
      floatingActionButton: floatingActionButton,
      // extendBody so the blur has something to blur, as in the home shell.
      extendBody: true,
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}
