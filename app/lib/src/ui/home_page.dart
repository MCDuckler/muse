import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/playback_log.dart';
import 'downloads_page.dart';
import 'jam_page.dart';
import 'feel.dart';
import 'glass.dart';
import 'motion.dart';
import 'desk_dock.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'player_bar.dart';
import 'queue_page.dart';
import 'search_page.dart';
import 'social_page.dart';
import 'widths.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _saidHello = false;

  /// One navigator per tab, so a screen opened from a tab belongs to that tab.
  ///
  /// Pushing onto the app's own navigator put every album, artist and playlist *over*
  /// the shell: the bar with the four tabs in it disappeared, so there was no way
  /// anywhere except back the way you came, and going to another tab and returning
  /// found the library back at its top rather than on the playlist you were reading.
  /// A navigator each fixes both at once — the bars stay where they are because the
  /// shell is still the screen, and each tab keeps its own back stack while you are
  /// somewhere else.
  final List<GlobalKey<NavigatorState>> _tabs =
      [for (var i = 0; i < 4; i++) GlobalKey<NavigatorState>()];

  /// Back goes back inside the tab first, and only then out of the app.
  Future<bool> _backWithinTab() async {
    final navigator = _tabs[context.read<AppState>().homeTab].currentState;
    return navigator != null && await navigator.maybePop();
  }

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

    final width = Width.of(context);
    // A desk gets the two things a phone has to take turns showing: the page, and what
    // is playing beside it. See DeskDock.
    final dock = width.hasDock && app.deskDock;

    return PopScope(
      // The shell itself only leaves once the tab has nothing left to go back to.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final root = Navigator.of(context);
        if (await _backWithinTab()) return;
        // Nothing left to go back to inside the tab: out of the shell if there is
        // anything under it, and out of the app if there is not.
        if (root.canPop()) {
          root.pop();
        } else {
          await SystemNavigator.pop();
        }
      },
      child: Scaffold(
      // IndexedStack, not pages[app.homeTab]: rebuilding the tab from scratch threw away
      // your search results and scroll position every time you switched away and back.
      // Content runs under the bars so the blur has something to blur. Lists add
      // their own bottom padding, otherwise the last row hides behind the glass.
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: Row(
          children: [
            // Down the side on anything wider than a phone. Four destinations spread
            // across fourteen hundred pixels of bottom edge is thumb furniture on a
            // screen nobody is holding.
            if (width.hasRail)
              _Rail(
                extended: width == Width.expanded,
                dockOpen: dock,
                onDock: width.hasDock ? app.toggleDeskDock : null,
                onSameTab: () =>
                    _tabs[context.read<AppState>().homeTab].currentState
                        ?.popUntil((r) => r.isFirst),
              ),
            Expanded(
              child: Column(
          children: [
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
              child: InsideShell(
                // A player bar and a tab bar, less whichever of them this screen is
                // not carrying.
                bottomInsetHere: (dock ? 0.0 : 96.0) +
                    (width.hasRail ? 0.0 : 72.0) +
                    (dock ? 24.0 : 0.0),
                child: _Settling(
                  on: app.homeTab,
                  child: IndexedStack(
                    index: app.homeTab,
                    children: [
                      for (var i = 0; i < pages.length; i++)
                        TickerMode(
                          enabled: i == app.homeTab,
                          child: Navigator(
                            key: _tabs[i],
                            onGenerateRoute: (_) => MaterialPageRoute(
                              builder: (_) => _TabRoot(
                                  title: titles[i], child: pages[i]),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
            ),
            // What is playing and what is next, folded out of the right-hand edge.
            if (width.hasDock)
              DeskDock(open: dock, onClose: app.toggleDeskDock),
          ],
        ),
      ),
      bottomNavigationBar: GlassSurface(
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The dock has the player in it, and two players on one screen is one
              // too many.
              if (!dock) const PlayerBar(),
              if (!width.hasRail)
                MuseNavigationBar(
                  // Tapping the tab you are already on goes back to the top of it,
                  // which is what every app does and what somebody four screens deep
                  // in the library reaches for.
                  onSameTab: () =>
                      _tabs[context.read<AppState>().homeTab].currentState
                          ?.popUntil((r) => r.isFirst),
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// The four places the app goes, down the side.
///
/// The same four destinations as the bar, plus the two things that were hidden in the
/// app bar's overflow — and, at the bottom, the handle that folds the player out of
/// the right-hand edge.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.extended,
    required this.dockOpen,
    required this.onDock,
    required this.onSameTab,
  });

  final bool extended;
  final bool dockOpen;
  final VoidCallback? onDock;
  final VoidCallback onSameTab;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final tab = app.homeTab;
    return NavigationRail(
      extended: extended,
      minExtendedWidth: 190,
      selectedIndex: tab,
      labelType: extended ? null : NavigationRailLabelType.all,
      leading: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Column(
          children: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: app.refresh,
            ),
            IconButton(
              icon: Icon(app.jam == null ? Icons.podcasts_outlined : Icons.podcasts,
                  color:
                      app.jam == null ? null : Theme.of(context).colorScheme.primary),
              tooltip: app.jam == null ? 'Listen together' : 'Jam · ${app.jam!.code}',
              onPressed: () => showJam(context),
            ),
          ],
        ),
      ),
      trailing: Expanded(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                if (onDock != null)
                  IconButton(
                    icon: Icon(dockOpen
                        ? Icons.keyboard_double_arrow_right
                        : Icons.keyboard_double_arrow_left),
                    tooltip: dockOpen ? 'Hide what is playing' : 'Show what is playing',
                    onPressed: onDock,
                  ),
              ],
            ),
          ),
        ),
      ),
      onDestinationSelected: (i) {
        if (i != tab) {
          feel(Feel.pick);
        } else {
          onSameTab();
        }
        app.setHomeTab(i);
      },
      destinations: const [
        NavigationRailDestination(
            icon: Icon(Icons.queue_music_outlined),
            selectedIcon: Icon(Icons.queue_music),
            label: Text('Queues')),
        NavigationRailDestination(
            icon: Icon(Icons.search),
            selectedIcon: Icon(Icons.search),
            label: Text('Search')),
        NavigationRailDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: Text('Library')),
        NavigationRailDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: Text('People')),
      ],
    );
  }
}

/// Marks everything drawn inside the home shell.
///
/// The shell already carries the player and the tabs at its bottom, so a screen opened
/// inside a tab must not put a second player under itself. A screen opened over the
/// whole app — from the player, say — still does. See PlayerScaffold.
class InsideShell extends InheritedWidget {
  const InsideShell({super.key, required this.bottomInsetHere, required super.child});

  /// How much room the shell is taking at the bottom of this screen — a player and a
  /// tab bar on a phone, nothing at all on a desk with the player down the side. Lists
  /// leave this much under their last row.
  final double bottomInsetHere;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InsideShell>() != null;

  /// Null outside the shell, where whoever is drawing has to assume the worst.
  static double? bottomInset(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<InsideShell>()
      ?.bottomInsetHere;

  @override
  bool updateShouldNotify(InsideShell old) =>
      old.bottomInsetHere != bottomInsetHere;
}

/// The first screen in a tab: the tab's own content, under the bar that every screen
/// in the app shares.
///
/// The bar used to belong to the shell, above all four tabs at once. It cannot any
/// more, because what is on top of a tab now is a whole screen with a bar of its own,
/// and two bars stacked is a bar too many.
class _TabRoot extends StatelessWidget {
  const _TabRoot({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      appBar: AppBar(
        title: Text(title),
        actions: [
          // On a desk these live in the rail, which is where the eye already is.
          if (!Width.of(context).hasRail) ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: app.refresh,
              tooltip: 'Refresh',
            ),
            IconButton(
              icon: Icon(app.jam == null ? Icons.podcasts_outlined : Icons.podcasts,
                  color:
                      app.jam == null ? null : Theme.of(context).colorScheme.primary),
              tooltip: app.jam == null ? 'Listen together' : 'Jam · ${app.jam!.code}',
              onPressed: () => showJam(context),
            ),
          ],
          if (!Width.of(context).hasRail && app.downloadsPending > 0)
            IconButton(
              icon: Badge(
                label: Text('${app.downloadsPending}'),
                child: const Icon(Icons.downloading),
              ),
              tooltip: 'Downloads',
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const DownloadsPage())),
            ),
          if (!Width.of(context).hasRail)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
            ),
        ],
      ),
      body: Column(
        children: [
          // Under the bar, above the tab: the same place it has always been, which is
          // now inside the tab because the bar is.
          if (!app.ingestOnline && app.downloadsPending > 0)
            InkWell(
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const DownloadsPage())),
              child: _OfflineBanner(pending: app.downloadsPending),
            ),
          Expanded(child: Readable(child: child)),
        ],
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
  const MuseNavigationBar({super.key, this.onLeaving, this.onSameTab});

  /// Called before the tab changes, for screens that are sitting on top of the app and
  /// have to get out of the way. Nothing on the home screen needs it.
  final VoidCallback? onLeaving;

  /// Called when the tab already showing is tapped again.
  final VoidCallback? onSameTab;

  @override
  Widget build(BuildContext context) {
    // Which tab, and nothing else. The bar sits under every screen and used to be
    // rebuilt by every report the app received.
    final tab = context.select<AppState, int>((a) => a.homeTab);
    return NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (i) {
        if (i != tab) {
          feel(Feel.pick);
        } else {
          onSameTab?.call();
        }
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
