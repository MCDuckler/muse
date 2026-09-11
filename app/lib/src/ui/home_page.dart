import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'downloads_page.dart';
import 'jam_page.dart';
import 'glass.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'player_bar.dart';
import 'queue_page.dart';
import 'search_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    const pages = [QueuePage(), SearchPage(), LibraryPage()];
    const titles = ['Queues', 'Search', 'Library'];

    return _Shortcuts(
      app: app,
      child: Scaffold(
      appBar: AppBar(
        title: Text(titles[app.homeTab]),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: app.refresh,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: Icon(app.jam == null ? Icons.podcasts_outlined : Icons.podcasts,
                color: app.jam == null ? null : Theme.of(context).colorScheme.primary),
            tooltip: app.jam == null ? 'Listen together' : 'Jam · ${app.jam!.code}',
            onPressed: () => showJam(context),
          ),
          if (app.downloadsPending > 0)
            IconButton(
              icon: Badge(
                label: Text('${app.downloadsPending}'),
                child: const Icon(Icons.downloading),
              ),
              tooltip: 'Downloads',
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const DownloadsPage())),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      // IndexedStack, not pages[app.homeTab]: rebuilding the tab from scratch threw away
      // your search results and scroll position every time you switched away and back.
      // Content runs under the bars so the blur has something to blur. Lists add
      // their own bottom padding, otherwise the last row hides behind the glass.
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (!app.ingestOnline && app.downloadsPending > 0)
              InkWell(
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const DownloadsPage())),
                child: _OfflineBanner(pending: app.downloadsPending),
              ),
            Expanded(
              child: IndexedStack(
                index: app.homeTab,
                children: pages,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: GlassSurface(
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const PlayerBar(),
              const MuseNavigationBar(),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// The three places the app goes, wherever you happen to be standing.
///
/// One widget rather than one per screen, because it appears on more than one now: the
/// player used to cover it completely, so opening what is playing meant losing every
/// way of going anywhere until you had closed it again. It is the same bar, in the
/// same place, doing the same thing — the only difference is that from inside the
/// player it has to get you out of the player first.
class MuseNavigationBar extends StatelessWidget {
  const MuseNavigationBar({super.key, this.onLeaving});

  /// Called before the tab changes, for screens that are sitting on top of the app and
  /// have to get out of the way. Nothing on the home screen needs it.
  final VoidCallback? onLeaving;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return NavigationBar(
      selectedIndex: app.homeTab,
      onDestinationSelected: (i) {
        app.setHomeTab(i);
        onLeaving?.call();
      },
      destinations: const [
        NavigationDestination(
            icon: Icon(Icons.queue_music_outlined),
            selectedIcon: Icon(Icons.queue_music),
            label: 'Queues'),
        NavigationDestination(
            icon: Icon(Icons.search),
            selectedIcon: Icon(Icons.search),
            label: 'Search'),
        NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: 'Library'),
      ],
    );
  }
}

/// Says the quiet part out loud: the machine that downloads music is not reachable,
/// so those queued rows are not going to move until it is.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.pending});
  final int pending;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: scheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              pending == 1
                  ? '1 track is waiting — the downloader is offline'
                  : '$pending tracks are waiting — the downloader is offline',
              style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 13.5),
            ),
          ),
        ],
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

  /// True while a text field has focus.
  ///
  /// Checking `primaryFocus.context.widget` is not enough: the node that holds focus
  /// belongs to a Focus widget *inside* EditableText, so the type test never matched
  /// and every letter typed into the search box also triggered a shortcut — S toggled
  /// shuffle, N skipped the track, space paused the music.
  static bool get _isTyping {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    var typing = false;
    ctx.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        typing = true;
        return false;
      }
      return true;
    });
    return typing;
  }

  KeyEventResult _handle(FocusNode node, KeyEvent event) {
    final player = app.player;
    if (player == null || event is! KeyDownEvent) return KeyEventResult.ignored;

    // Never steal keys from a text field: space belongs to the search box.
    if (_isTyping) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.mediaPlayPause:
        app.playPause();
      case LogicalKeyboardKey.arrowRight:
        player.nudge(const Duration(seconds: 10));
      case LogicalKeyboardKey.arrowLeft:
        player.nudge(const Duration(seconds: -10));
      case LogicalKeyboardKey.keyN:
      case LogicalKeyboardKey.mediaTrackNext:
        app.skipNext();
      case LogicalKeyboardKey.keyP:
      case LogicalKeyboardKey.mediaTrackPrevious:
        app.skipPrevious();
      case LogicalKeyboardKey.keyS:
        app.shuffleWhatIsComing();
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
