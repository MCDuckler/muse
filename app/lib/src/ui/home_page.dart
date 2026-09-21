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
import 'pane.dart';
import '../../main.dart' show showShortcuts;
import '../api/models.dart';
import 'browse_page.dart';
import '../api/client.dart' show ApiException;
import 'desk_dock.dart';
import 'dropped_files.dart';
import 'snack.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'not_connected.dart';
import 'player_bar.dart';
import 'queue_page.dart';
import 'search_page.dart';
import 'social_page.dart';
import 'split.dart';
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

  /// The pane beside the library's own list, where there is room for one. See
  /// PaneScope: on a desk the library is a column of places to go, and covering it
  /// with whichever one you picked throws away the thing you are picking from.
  final GlobalKey<NavigatorState> _libraryPane = GlobalKey<NavigatorState>();

  /// Which tab is a list with something beside it. Only the library: the queue's
  /// second pane is the dock, and search and people are one thing each.
  static const _splits = 2;

  /// Back goes back inside the tab first, and only then out of the app.
  ///
  /// Innermost first: with the library split in two, what somebody opened beside the
  /// column is the nearest thing to go back from.
  Future<bool> _backWithinTab() async {
    final tab = context.read<AppState>().homeTab;
    if (tab == _splits) {
      final pane = _libraryPane.currentState;
      if (pane != null && pane.canPop() && await pane.maybePop()) return true;
    }
    final navigator = _tabs[tab].currentState;
    return navigator != null && await navigator.maybePop();
  }

  @override
  void initState() {
    super.initState();
    // A link that opened this tab, now that there is something to open it with.
    WidgetsBinding.instance.addPostFrameCallback((_) => _followTheLink());
  }

  /// Open whatever the address bar was pointing at when the app started.
  ///
  /// /p/12 a playlist, /t/34 a song, /a/Low a record, /r/Bicep an artist. Anything
  /// else is somebody's typo or an old link, and the app opens where it always does
  /// rather than saying so: a link that no longer works should not be a wall.
  Future<void> _followTheLink() async {
    final app = context.read<AppState>();
    final link = app.takeTheLink();
    if (link == null || !mounted) return;
    final bits = link.split('/').where((p) => p.isNotEmpty).toList();
    if (bits.length < 2) return;
    final what = bits[0];
    final which = Uri.decodeComponent(bits.sublist(1).join('/'));

    switch (what) {
      case 'p':
        final id = int.tryParse(which);
        if (id == null) return;
        app.setHomeTab(2);
        final name = app.playlists
            .where((p) => p.id == id)
            .map((p) => p.name)
            .firstOrNull;
        _openInTab(2, (_) => PlaylistPage(playlistId: id, name: name ?? 'Playlist'));
      case 't':
        final id = int.tryParse(which);
        if (id == null) return;
        try {
          await app.playNow([await app.api.track(id)]);
        } catch (_) {
          // A song that is gone, or a server that will not say. The app is open and
          // that is enough.
        }
      case 'a':
        app.setHomeTab(2);
        _openInTab(
            2,
            (_) => AlbumPage(
                album: AlbumSummary(name: which, artist: '', tracks: 0)));
      case 'r':
        app.setHomeTab(2);
        _openInTab(2,
            (_) => ArtistPage(artist: ArtistSummary(name: which, tracks: 0)));
    }
  }

  void _openInTab(int tab, WidgetBuilder page) {
    final navigator = _tabs[tab].currentState;
    if (navigator == null) return;
    navigator.push(MaterialPageRoute(builder: page));
  }

  @override
  Widget build(BuildContext context) {
    // Two facts, not the whole of the app's state. The shell was rebuilt by every
    // report the app made — a cover arriving, a download ticking, a listen being
    // recorded — and rebuilding the shell rebuilds the rail, the dock and the frame
    // around all four tabs, several times a second while anything is downloading.
    final app = context.read<AppState>();
    final tab = context.select<AppState, int>((a) => a.homeTab);
    final wantsDock = context.select<AppState, bool>((a) => a.deskDock);
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
    final dock = width.hasDock && wantsDock;

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
      child: DropToAdd(
        onFiles: (files) => _addDropped(context, files),
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
                  on: tab,
                  child: IndexedStack(
                    index: tab,
                    children: [
                      for (var i = 0; i < pages.length; i++)
                        TickerMode(
                          enabled: i == tab,
                          child: Navigator(
                            key: _tabs[i],
                            onGenerateRoute: (_) => MaterialPageRoute(
                              builder: (_) => _TabRoot(
                                title: titles[i],
                                // The library gets a pane beside it on a desk; the
                                // others are one thing each.
                                pane: i == _splits && width == Width.expanded
                                    ? _libraryPane
                                    : null,
                                child: pages[i],
                              ),
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
            // What is playing and what is next, folded out of the right-hand edge,
            // with a line between it and the page that can be taken hold of.
            if (width.hasDock && dock)
              Grabbable(
                width: context.select<AppState, double>((a) => a.dockWidth),
                fromRight: true,
                min: 320,
                // Never more than half the window, whatever was saved on a bigger
                // screen: a dock wider than the page it is beside is a page in a
                // margin.
                max: (MediaQuery.sizeOf(context).width * 0.5).clamp(320.0, 640.0),
                onChanged: (w) => app.setDockWidth(w),
                onSettled: (w) => app.setDockWidth(w, remember: true),
              ),
            if (width.hasDock)
              DeskDock(
                open: dock,
                width: context
                    .select<AppState, double>((a) => a.dockWidth)
                    .clamp(320.0,
                        (MediaQuery.sizeOf(context).width * 0.5)
                            .clamp(320.0, 640.0)),
                onClose: app.toggleDeskDock,
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
              // Above the player rather than over the page: it is a fact about the
              // whole app, and it must not cover the thing somebody was reading.
              const NotConnected(),
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
      ),
    );
  }
}

/// Music dragged onto the window: uploaded, one after another, and said out loud.
///
/// Adding a file the downloader cannot fetch — a bootleg, a friend's mix, a rip of a
/// CD — meant going to Settings and through a file picker. On a desk the file is in a
/// window next to this one and the gesture people try first is to drag it in.
Future<void> _addDropped(
    BuildContext context, List<({String name, List<int> bytes})> files) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  var added = 0;
  String? refused;
  for (final file in files) {
    try {
      await app.api.upload(file.bytes, file.name);
      added++;
    } catch (e) {
      refused = e is ApiException ? e.message : '$e';
    }
  }
  if (added > 0) await app.refresh();
  messenger.say(snack(Text(switch ((added, refused)) {
    (0, final why?) => why,
    (0, _) => 'Nothing there this could add',
    (1, _) => 'Added ${files.first.name}',
    _ => 'Added $added songs',
  })));
}

/// The four places the app goes, down the side.
///
/// The same four destinations as the bar, plus the two things that were hidden in the
/// app bar's overflow — and, at the bottom, the handle that folds the player out of
/// the right-hand edge.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.dockOpen,
    required this.onDock,
    required this.onSameTab,
  });

  final bool dockOpen;
  final VoidCallback? onDock;
  final VoidCallback onSameTab;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final tab = context.select<AppState, int>((a) => a.homeTab);
    final jamming = context.select<AppState, String?>((a) => a.jam?.code);
    final pending = context.select<AppState, int>((a) => a.downloadsPending);
    return NavigationRail(
      selectedIndex: tab,
      // Icons, and the name of the one you are on. Four words down the side of every
      // screen is a column of labels for things whose pictures already say what they
      // are — and it was the widest part of the rail, taking room from the page.
      labelType: NavigationRailLabelType.selected,
      groupAlignment: -0.85,
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
              icon: Icon(jamming == null ? Icons.podcasts_outlined : Icons.podcasts,
                  color:
                      jamming == null ? null : Theme.of(context).colorScheme.primary),
              tooltip: jamming == null ? 'Listen together' : 'Jam · $jamming',
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
                if (pending > 0)
                  IconButton(
                    icon: Badge(
                      label: Text('$pending'),
                      child: const Icon(Icons.downloading),
                    ),
                    tooltip: 'Downloads',
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const DownloadsPage())),
                  ),
                IconButton(
                  icon: const Icon(Icons.keyboard_outlined),
                  tooltip: 'Keys (?)',
                  onPressed: () => showShortcuts(context),
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
      // Named on hover, since the name is not written under the icon any more: a
      // rail of bare pictures is fine once you know it and unkind on the first day.
      destinations: const [
        NavigationRailDestination(
            icon: Tooltip(message: 'Queues', child: Icon(Icons.queue_music_outlined)),
            selectedIcon: Icon(Icons.queue_music),
            label: Text('Queues')),
        NavigationRailDestination(
            icon: Tooltip(message: 'Search', child: Icon(Icons.search)),
            selectedIcon: Icon(Icons.search),
            label: Text('Search')),
        NavigationRailDestination(
            icon: Tooltip(
                message: 'Library', child: Icon(Icons.library_music_outlined)),
            selectedIcon: Icon(Icons.library_music),
            label: Text('Library')),
        NavigationRailDestination(
            icon: Tooltip(message: 'People', child: Icon(Icons.people_outline)),
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
  const _TabRoot({required this.title, required this.child, this.pane});
  final String title;
  final Widget child;

  /// Where what this list opens should go, when there is room beside it.
  final GlobalKey<NavigatorState>? pane;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final jamming = context.select<AppState, String?>((a) => a.jam?.code);
    final pending = context.select<AppState, int>((a) => a.downloadsPending);
    final offline = context.select<AppState, bool>((a) => !a.ingestOnline);
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
              icon: Icon(jamming == null ? Icons.podcasts_outlined : Icons.podcasts,
                  color:
                      jamming == null ? null : Theme.of(context).colorScheme.primary),
              tooltip: jamming == null ? 'Listen together' : 'Jam · $jamming',
              onPressed: () => showJam(context),
            ),
          ],
          if (!Width.of(context).hasRail && pending > 0)
            IconButton(
              icon: Badge(
                label: Text('$pending'),
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
          if (offline && pending > 0)
            InkWell(
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const DownloadsPage())),
              child: _OfflineBanner(pending: pending),
            ),
          Expanded(
            child: pane == null
                ? Readable(child: child)
                : _SideBySide(pane: pane!, list: child),
          ),
        ],
      ),
    );
  }
}

/// A list on the left, whatever it opens on the right.
class _SideBySide extends StatelessWidget {
  const _SideBySide({required this.pane, required this.list});
  final GlobalKey<NavigatorState> pane;
  final Widget list;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    // Wide enough for a playlist's name and the menu at the end of its row, narrow
    // enough that what you opened is the bigger half — and then whatever the person
    // using it decides, because that is a matter of their screen and their playlists.
    final room = MediaQuery.sizeOf(context).width;
    final listWidth = context
        .select<AppState, double>((a) => a.paneWidth)
        .clamp(240.0, (room * 0.5).clamp(240.0, 560.0));
    return PaneScope(
      pane: pane,
      child: Row(
        children: [
          SizedBox(width: listWidth, child: list),
          Grabbable(
            width: listWidth,
            min: 240,
            max: (room * 0.5).clamp(240.0, 560.0),
            onChanged: (w) => app.setPaneWidth(w),
            onSettled: (w) => app.setPaneWidth(w, remember: true),
          ),
          Expanded(
            child: Navigator(
              key: pane,
              onGenerateRoute: (_) =>
                  MaterialPageRoute(builder: (_) => const _NothingPicked()),
            ),
          ),
        ],
      ),
    );
  }
}

/// What is beside the library before anything has been picked.
class _NothingPicked extends StatelessWidget {
  const _NothingPicked();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_music_outlined,
                size: 40, color: scheme.outlineVariant),
            const SizedBox(height: 10),
            Text('Pick something from the library',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
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
