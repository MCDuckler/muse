import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'library_page.dart';
import 'player_bar.dart';
import 'queue_page.dart';
import 'search_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    const pages = [QueuePage(), SearchPage(), LibraryPage()];
    const titles = ['Queues', 'Search', 'Library'];

    return _Shortcuts(
      app: app,
      child: Scaffold(
      appBar: AppBar(
        title: Text(titles[_tab]),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: app.refresh,
            tooltip: 'Refresh',
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'logout') app.logout();
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'user', enabled: false, child: Text(app.user ?? '')),
              const PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      // IndexedStack, not pages[_tab]: rebuilding the tab from scratch threw away
      // your search results and scroll position every time you switched away and back.
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: pages,
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PlayerBar(),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.queue_music), label: 'Queues'),
              NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
              NavigationDestination(icon: Icon(Icons.library_music), label: 'Library'),
            ],
          ),
        ],
      ),
      ),
    );
  }
}

/// Keyboard control, because the web build is the client most of the time and a
/// music player you cannot pause from the keyboard is annoying to live with.
class _Shortcuts extends StatelessWidget {
  const _Shortcuts({required this.app, required this.child});
  final AppState app;
  final Widget child;

  KeyEventResult _handle(FocusNode node, KeyEvent event) {
    final player = app.player;
    if (player == null || event is! KeyDownEvent) return KeyEventResult.ignored;

    // Never steal keys from a text field: space belongs to the search box.
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    if (focused is EditableText) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.mediaPlayPause:
        player.playPause();
      case LogicalKeyboardKey.arrowRight:
        player.nudge(const Duration(seconds: 10));
      case LogicalKeyboardKey.arrowLeft:
        player.nudge(const Duration(seconds: -10));
      case LogicalKeyboardKey.keyN:
      case LogicalKeyboardKey.mediaTrackNext:
        player.next();
      case LogicalKeyboardKey.keyP:
      case LogicalKeyboardKey.mediaTrackPrevious:
        player.previous();
      case LogicalKeyboardKey.keyS:
        app.setShuffle(!player.shuffle);
      case LogicalKeyboardKey.keyR:
        app.cycleRepeat();
      case LogicalKeyboardKey.keyM:
        player.setUserVolume(player.userVolume == 0 ? 1.0 : 0.0);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(autofocus: true, onKeyEvent: _handle, child: child);
}
