import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/playback_log.dart';
import 'downloads_page.dart';
import 'jam_page.dart';
import 'feel.dart';
import 'glass.dart';
import 'motion.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'player_bar.dart';
import 'queue_page.dart';
import 'search_page.dart';
import 'social_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _saidHello = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // Once, the first time the shell is built: a browser that dies here leaves a log
    // that stops at "app started", and one that dies later leaves this line in it.
    if (!_saidHello) {
      _saidHello = true;
      PlaybackLog.note('home shell built');
    }
    const pages = [QueuePage(), SearchPage(), LibraryPage(), SocialPage()];
    const titles = ['Queues', 'Search', 'Library', 'People'];

    return Scaffold(
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
              // All three tabs are built and kept — that is what an IndexedStack is
              // for, and it is why coming back to a tab finds it where you left it.
              // What the two you are not looking at have no business doing is
              // *animating*: a spinner, a progress bar or a pulse in a hidden tab is
              // a frame of work and a frame of memory for something nobody can see,
              // which on a phone in a browser is a tab being reloaded out from under
              // somebody.
              // And a tab that changes settles in rather than being cut to: the same
              // stack, faded up from three quarters over a tenth of a second. Not a
              // cross-fade between two tabs — that would mean two of them built and
              // painted at once, which is what the IndexedStack is here to avoid.
              child: _Settling(
                on: app.homeTab,
                child: IndexedStack(
                  index: app.homeTab,
                  children: [
                    for (var i = 0; i < pages.length; i++)
                      TickerMode(enabled: i == app.homeTab, child: pages[i]),
                  ],
                ),
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
    );
  }
}

/// A quick fade up whenever [on] changes, around something that is otherwise cut to.
class _Settling extends StatefulWidget {
  const _Settling({required this.on, required this.child});
  final Object on;
  final Widget child;

  @override
  State<_Settling> createState() => _SettlingState();
}

class _SettlingState extends State<_Settling>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
      vsync: this, duration: Motion.quick, value: 1);

  @override
  void didUpdateWidget(_Settling old) {
    super.didUpdateWidget(old);
    if (old.on != widget.on && !stillness(context)) _in.forward(from: 0.7);
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _in, child: widget.child);
}

/// The four places the app goes, wherever you happen to be standing.
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
    // Which tab, and nothing else. The bar sits under every screen and used to be
    // rebuilt by every report the app received.
    final tab = context.select<AppState, int>((a) => a.homeTab);
    return NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (i) {
        if (i != tab) feel(Feel.pick);
        context.read<AppState>().setHomeTab(i);
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
        // The catalog has always been shared between everybody on the box. This is
        // the part of that you can look at.
        NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'People'),
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
