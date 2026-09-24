import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../../worker/parts_jobs.dart';
import '../../../worker/this_computer.dart' show fetchHereNow;
import '../../artwork.dart';
import '../../mag.dart';
import '../../snack.dart';
import 'console.dart';
import 'set_planner_page.dart';

/// The crate's pages.
enum CrateTab { queue, library, search, parts }

/// The crate: everything a set is made of, without leaving the booth.
///
/// QUEUE is the queue as it is, in its order — dragged into another, trimmed, added
/// to — and it is what the automix mixes into next (AutoMix.follow); a switch shows
/// it instead by how well each record would mix with the one on now. LIBRARY is every
/// playlist, a record or all of one queued from there. SEARCH is the library, and past
/// it YouTube: a song not in the library yet is added and fetched on this computer at
/// once. PARTS is the records being taken apart.
///
/// A record is dragged onto a deck, sent to one with its A and B, or clicked onto the
/// deck that asked for one. Wide — the room gives it more of the screen — the rows
/// grow columns and the library shows its lists beside their songs.
class ConsoleCrate extends StatefulWidget {
  const ConsoleCrate(
      {super.key,
      required this.booth,
      required this.loadInto,
      this.forDeck,
      this.tab,
      this.wide = false,
      this.onWide});
  final Booth booth;
  final void Function(engine.Deck deck, Track track) loadInto;

  /// A deck that asked for a record: a plain click goes there.
  final engine.Deck? forDeck;

  /// Which page is open, where something outside the crate wants a say in it: the
  /// bar's parts light opens the list of parts.
  final ValueNotifier<CrateTab>? tab;

  /// Whether the room has given the crate the wide half of the screen, and how to ask
  /// for it or give it back.
  final bool wide;
  final VoidCallback? onWide;

  @override
  State<ConsoleCrate> createState() => _ConsoleCrateState();
}

class _ConsoleCrateState extends State<ConsoleCrate> {
  late final ValueNotifier<CrateTab> _tab =
      widget.tab ?? ValueNotifier(CrateTab.queue);
  final _query = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<Track>? _found;
  List<RemoteHit> _elsewhere = const [];
  bool _looking = false;

  /// The queue by how well each would mix with the one on now, rather than in order.
  bool _byMatch = false;

  /// The playlist open in LIBRARY, and its songs once they are here.
  Playlist? _list;
  List<Track>? _listTracks;

  @override
  void initState() {
    super.initState();
    _tab.addListener(_retab);
  }

  void _retab() => setState(() {});

  void _open(CrateTab t) {
    _tab.value = t;
    if (t == CrateTab.search) _focus.requestFocus();
  }

  @override
  void dispose() {
    _tab.removeListener(_retab);
    if (widget.tab == null) _tab.dispose();
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _found = null;
        _elsewhere = const [];
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 280), () async {
      setState(() => _looking = true);
      try {
        final r = await context.read<AppState>().api.search(q.trim());
        if (!mounted || _query.text != q) return;
        setState(() {
          _found = r.local;
          _elsewhere = [for (final h in r.remote) if (!h.known) h];
        });
      } catch (_) {
        if (mounted) setState(() => _found = const []);
      } finally {
        if (mounted) setState(() => _looking = false);
      }
    });
  }

  int _score(Track t) {
    final tm = widget.booth.timing.peek(t.id);
    final master = widget.booth.master.timing;
    final shown = widget.booth.master.bpm;
    if (tm == null || master == null) return 2;
    final tempoOk = tm.bpm != null && shown != null && Booth.syncRatio(tm.bpm!, shown) != null;
    final keyOk = tm.inKeyWith(master);
    return tempoOk && keyOk
        ? 0
        : tempoOk || keyOk
            ? 1
            : 3;
  }

  Future<void> _openList(Playlist p) async {
    setState(() {
      _list = p;
      _listTracks = null;
    });
    try {
      final full = await context.read<AppState>().api.playlist(p.id);
      if (mounted && _list?.id == p.id) {
        setState(() {
          _list = full;
          _listTracks = full.items;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _listTracks = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tab = _tab.value;
    final partsHere = widget.booth.parts.separatesHere;
    return Plate(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: LayoutBuilder(builder: (context, c) {
        final roomy = c.maxWidth >= 470;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (final (t, label, icon) in [
                  (CrateTab.queue, 'QUEUE', Icons.queue_music),
                  (CrateTab.library, 'LIBRARY', Icons.library_music_outlined),
                  (CrateTab.search, 'SEARCH', Icons.search),
                  if (partsHere) (CrateTab.parts, 'PARTS', Icons.call_split),
                ]) ...[
                  Expanded(
                    child: t == CrateTab.parts
                        ? ListenableBuilder(
                            listenable: partsJobs,
                            builder: (context, _) {
                              final now = partsJobs.running.firstOrNull;
                              return Pad(
                                label: roomy ? label : null,
                                icon: icon,
                                lit: tab == t,
                                colour: Console.ink,
                                height: 30,
                                tooltip: now == null
                                    ? 'Records being taken apart'
                                    : '${now.title} · ${stageLine(now)}',
                                progress: now == null
                                    ? partsJobs.busy
                                        ? 0
                                        : null
                                    : now.progress ?? 0,
                                onTap: () => _open(t),
                              );
                            })
                        : Pad(
                            label: roomy ? label : null,
                            icon: icon,
                            lit: tab == t,
                            colour: Console.ink,
                            height: 30,
                            tooltip: roomy ? null : label[0] + label.substring(1).toLowerCase(),
                            onTap: () => _open(t),
                          ),
                  ),
                  const SizedBox(width: 6),
                ],
                if (widget.onWide != null)
                  Pad(
                    icon: widget.wide ? Icons.close_fullscreen : Icons.open_in_full,
                    width: 34,
                    height: 30,
                    lit: widget.wide,
                    colour: Console.ink,
                    tooltip: widget.wide ? 'Narrow the crate' : 'Widen the crate',
                    onTap: widget.onWide,
                  ),
              ],
            ),
            if (widget.forDeck != null)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 2),
                child: Row(children: [
                  Icon(Icons.arrow_downward, size: 13, color: Console.deck(widget.forDeck!.name)),
                  const SizedBox(width: 4),
                  Text('CLICK A RECORD FOR DECK ${widget.forDeck!.name}',
                      style: Console.label(8.5, color: Console.deck(widget.forDeck!.name))),
                ]),
              ),
            const SizedBox(height: 6),
            Expanded(
              child: switch (tab) {
                CrateTab.queue => _queue(roomy),
                CrateTab.library => _library(roomy),
                CrateTab.search => _searchPage(roomy),
                CrateTab.parts => _PartsList(
                    booth: widget.booth, loadInto: widget.loadInto, forDeck: widget.forDeck),
              },
            ),
          ],
        );
      }),
    );
  }

  Widget _row(Track t, bool roomy, {int? queuePos, Widget? handle}) => _Row(
        key: ValueKey('${queuePos ?? 'x'}-${t.id}'),
        track: t,
        booth: widget.booth,
        loadInto: widget.loadInto,
        forDeck: widget.forDeck,
        roomy: roomy,
        queuePos: queuePos,
        handle: handle,
      );

  // ------------------------------------------------------------------ QUEUE
  Widget _queue(bool roomy) {
    final app = context.watch<AppState>();
    final items = app.player?.items ?? const <Track>[];
    final total = items.fold<int>(0, (a, t) => a + (t.durationMs ?? 0));
    final waiting = items.where((t) => !t.isReady).length;
    String clock(int ms) {
      final m = ms ~/ 60000;
      return m >= 60 ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m' : '$m min';
    }

    final bar = Row(
      children: [
        Expanded(
          child: Text(
              '${items.length} ${items.length == 1 ? 'RECORD' : 'RECORDS'} · ${clock(total)}'
              '${waiting > 0 ? ' · $waiting ON THE WAY' : ''}',
              style: Console.label(8.5, color: Console.quiet)),
        ),
        _Toggle(
          label: _byMatch ? 'BEST MATCH' : 'IN ORDER',
          tooltip: _byMatch
              ? 'Sorted by how well each mixes with the record on now — tap for the queue order'
              : 'The queue in its order — tap to sort by how well each mixes with the record on now',
          onTap: () => setState(() => _byMatch = !_byMatch),
        ),
        const SizedBox(width: 4),
        _Menu(items: [
          ('Plan a set…', Icons.auto_awesome, () => openSetPlanner(context, widget.booth)),
          ('Clear the queue', Icons.clear_all, () => app.clearQueue(context: context)),
        ]),
      ],
    );
    if (items.isEmpty) {
      return Column(children: [
        bar,
        const Expanded(
          child: _Empty(
              icon: Icons.queue_music,
              line: 'THE QUEUE IS EMPTY — ADD FROM LIBRARY OR SEARCH'),
        ),
      ]);
    }
    if (_byMatch) {
      final sorted = [for (var i = 0; i < items.length; i++) (i, items[i])]
        ..sort((a, b) => _score(a.$2).compareTo(_score(b.$2)));
      return Column(children: [
        bar,
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            itemCount: sorted.length,
            itemBuilder: (context, i) => _row(sorted[i].$2, roomy, queuePos: sorted[i].$1),
          ),
        ),
      ]);
    }
    return Column(children: [
      bar,
      const SizedBox(height: 4),
      Expanded(
        child: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          itemCount: items.length,
          onReorderItem: (from, to) {
            if (to != from) unawaited(app.moveInQueue(from, to));
          },
          proxyDecorator: (child, i, a) => Material(color: Colors.transparent, child: child),
          itemBuilder: (context, i) => _row(items[i], roomy,
              queuePos: i,
              handle: ReorderableDragStartListener(
                index: i,
                child: const MouseRegion(
                  cursor: SystemMouseCursors.resizeUpDown,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(0, 8, 6, 8),
                    child: Icon(Icons.drag_indicator, size: 16, color: Console.faint),
                  ),
                ),
              )),
        ),
      ),
    ]);
  }

  // ------------------------------------------------------------------ LIBRARY
  Widget _library(bool roomy) {
    final app = context.watch<AppState>();
    final lists = app.playlists;
    Widget listOfLists() => lists.isEmpty
        ? const _Empty(icon: Icons.library_music_outlined, line: 'NO PLAYLISTS YET')
        : ListView.builder(
            itemCount: lists.length,
            itemBuilder: (context, i) {
              final p = lists[i];
              final open = _list?.id == p.id;
              return _Hover(
                lit: open,
                onTap: () => _openList(p),
                child: Row(children: [
                  Icon(p.kind == 'favourites' ? Icons.favorite : Icons.queue_music,
                      size: 16, color: open ? Console.ink : Console.quiet),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.title(13, color: Console.ink)),
                  ),
                  if (p.autoSplit)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Tooltip(
                          message: 'Every song is taken apart',
                          child: Icon(Icons.call_split, size: 13, color: Console.quiet)),
                    ),
                  const SizedBox(width: 6),
                  Text('${p.itemCount}', style: Console.label(8.5, color: Console.faint)),
                ]),
              );
            },
          );

    Widget songs() {
      final p = _list;
      if (p == null) {
        return const _Empty(icon: Icons.arrow_back, line: 'PICK A PLAYLIST');
      }
      final tracks = _listTracks;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            if (!roomy)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_back, size: 18, color: Console.quiet),
                tooltip: 'All playlists',
                onPressed: () => setState(() => _list = null),
              ),
            Expanded(
              child: Text(p.name.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Console.label(9, color: Console.ink)),
            ),
            if (tracks != null && tracks.isNotEmpty)
              _Toggle(
                label: 'QUEUE ALL',
                tooltip: 'Add every song in it to the end of the queue',
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await app.addTracks(tracks);
                  messenger.say(snack(Text('${tracks.length} added to the queue')));
                },
              ),
            const SizedBox(width: 4),
            _Menu(items: [
              if (p.mine)
                (
                  p.autoSplit ? 'Stop taking every song apart' : 'Take every song apart',
                  Icons.call_split,
                  () async {
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      final n = await app.api.setPlaylistAutoSplit(p.id, !p.autoSplit);
                      await app.refreshPlaylists();
                      await _openList(p);
                      messenger.say(snack(Text(!p.autoSplit
                          ? n == 0
                              ? 'Songs added to it will be taken apart'
                              : 'Taking $n apart, and every one added'
                          : 'Songs added to it are left whole')));
                    } catch (e) {
                      messenger.say(problem(e));
                    }
                  },
                ),
              ('Queue all next', Icons.playlist_play, () => app.addTracks(tracks ?? const [], mode: 'next')),
            ]),
          ]),
          const SizedBox(height: 4),
          Expanded(
            child: tracks == null
                ? const Center(
                    child: SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.5)))
                : tracks.isEmpty
                    ? const _Empty(icon: Icons.music_off, line: 'NOTHING IN IT')
                    : ListView.builder(
                        itemCount: tracks.length,
                        itemBuilder: (context, i) => _row(tracks[i], roomy),
                      ),
          ),
        ],
      );
    }

    if (roomy) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 200, child: listOfLists()),
          const VerticalDivider(width: 14, color: Console.line),
          Expanded(child: songs()),
        ],
      );
    }
    return _list == null ? listOfLists() : songs();
  }

  // ------------------------------------------------------------------ SEARCH
  Widget _searchPage(bool roomy) {
    final accent = Theme.of(context).colorScheme.primary;
    final found = _found;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _query,
          focusNode: _focus,
          onChanged: _search,
          style: Mag.typewriter(13, color: Console.ink),
          cursorColor: accent,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Title, artist — the library, then YouTube',
            hintStyle: Mag.typewriter(12, color: Console.faint),
            filled: true,
            fillColor: Console.ground,
            prefixIcon: _looking
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  )
                : const Icon(Icons.search, size: 18, color: Console.quiet),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: found == null
              ? const _Empty(icon: Icons.search, line: 'TYPE TO SEARCH')
              : found.isEmpty && _elsewhere.isEmpty
                  ? const _Empty(icon: Icons.search_off, line: 'NOTHING FOUND')
                  : ListView(
                      children: [
                        if (found.isNotEmpty) _Head('IN THE LIBRARY · ${found.length}'),
                        for (final t in found) _row(t, roomy),
                        if (_elsewhere.isNotEmpty) ...[
                          const _Head('NOT IN THE LIBRARY YET — ADDED, IT IS FETCHED HERE'),
                          for (final h in _elsewhere) _Elsewhere(hit: h),
                        ],
                      ],
                    ),
        ),
      ],
    );
  }
}

/// A song on YouTube that is not in the library: added to the queue, it is fetched on
/// this computer at once and shared with the house.
class _Elsewhere extends StatefulWidget {
  const _Elsewhere({required this.hit});
  final RemoteHit hit;

  @override
  State<_Elsewhere> createState() => _ElsewhereState();
}

class _ElsewhereState extends State<_Elsewhere> {
  bool _adding = false;
  bool _added = false;

  Future<void> _add(String mode) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _adding = true);
    try {
      final t = await app.api.resolve(videoId: widget.hit.videoId);
      await app.addTrack(t, mode: mode);
      unawaited(fetchHereNow([t.id]));
      if (mounted) setState(() => _added = true);
      messenger.say(snack(Text('${t.displayTitle} — fetching it here')));
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.hit;
    final d = h.durationMs;
    return _Hover(
      child: Row(children: [
        const SizedBox(
            width: 36, height: 36, child: Icon(Icons.cloud_download_outlined, color: Console.faint)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(h.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(13, color: Console.ink)),
              Text(
                  [h.artists.join(', '), if (d != null) '${d ~/ 60000}:${(d ~/ 1000 % 60).toString().padLeft(2, '0')}']
                      .where((x) => x.isNotEmpty)
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Mag.typewriter(10.5, color: Console.quiet)),
            ],
          ),
        ),
        if (_adding)
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5))
        else if (_added)
          const Icon(Icons.check, size: 16, color: Console.ink)
        else ...[
          Pad(
              icon: Icons.playlist_add,
              width: 30,
              height: 26,
              tooltip: 'Add to the end of the queue',
              onTap: () => _add('end')),
          const SizedBox(width: 4),
          Pad(
              icon: Icons.playlist_play,
              width: 30,
              height: 26,
              tooltip: 'Add as the next in the queue',
              onTap: () => _add('next')),
        ],
      ]),
    );
  }
}

/// A row that lights under the pointer.
class _Hover extends StatefulWidget {
  const _Hover({required this.child, this.onTap, this.lit = false});
  final Widget child;
  final VoidCallback? onTap;
  final bool lit;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _over = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: widget.lit || _over ? Console.raised : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: widget.child,
          ),
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.line});
  final IconData icon;
  final String line;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 26, color: Console.faint),
          const SizedBox(height: 8),
          Text(line, textAlign: TextAlign.center, style: Console.label(8.5, color: Console.faint)),
        ]),
      );
}

/// A small switch in words, the way the console labels things.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.onTap, this.tooltip});
  final String label;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip ?? '',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.fromLTRB(7, 4, 7, 3),
            decoration: BoxDecoration(
              border: Border.all(color: Console.line),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label, style: Console.label(8, color: Console.ink)),
          ),
        ),
      );
}

/// A "more" menu of (label, icon, action).
class _Menu extends StatelessWidget {
  const _Menu({required this.items});
  final List<(String, IconData, Future<void> Function())> items;

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
        tooltip: 'More',
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: const Icon(Icons.more_horiz, color: Console.quiet),
        color: Console.raised,
        onSelected: (i) => unawaited(items[i].$3()),
        itemBuilder: (context) => [
          for (final (i, (label, icon, _)) in items.indexed)
            PopupMenuItem(
              value: i,
              height: 36,
              child: Row(children: [
                Icon(icon, size: 16, color: Console.quiet),
                const SizedBox(width: 10),
                Text(label, style: Mag.typewriter(12, color: Console.ink)),
              ]),
            ),
        ],
      );
}

/// One record in the crate: what it is, whether it is here yet, its tempo and key lit
/// where they sit with the master, and — under the pointer — the decks it can go onto
/// and everything else that can be done with it.
class _Row extends StatefulWidget {
  const _Row(
      {super.key,
      required this.track,
      required this.booth,
      required this.loadInto,
      required this.forDeck,
      this.roomy = false,
      this.queuePos,
      this.handle});
  final Track track;
  final Booth booth;
  final void Function(engine.Deck deck, Track track) loadInto;
  final engine.Deck? forDeck;
  final bool roomy;

  /// Where it is in the queue, when this is the queue.
  final int? queuePos;
  final Widget? handle;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _over = false;

  List<(String, IconData, Future<void> Function())> _actions(AppState app) {
    final t = widget.track;
    final pos = widget.queuePos;
    final liked = app.isFavourite(t.id);
    return [
      if (pos == null) ...[
        ('Add to the queue', Icons.playlist_add, () => app.addTrack(t)),
        ('Add as the next', Icons.playlist_play, () => app.addTrack(t, mode: 'next')),
      ] else ...[
        ('Move to the top', Icons.vertical_align_top, () => app.moveInQueue(pos, 0)),
        ('Take out of the queue', Icons.remove_circle_outline,
            () => app.removeFromQueue(pos, context: context)),
      ],
      (liked ? 'Unlike' : 'Like', liked ? Icons.favorite : Icons.favorite_border,
          () => app.toggleFavourite(t.id)),
      ('Add to a playlist…', Icons.library_add_outlined, () => _toPlaylist(app)),
      if (t.isReady && widget.booth.parts.separatesHere)
        ('Take apart now', Icons.call_split, () async {
          await widget.booth.parts.want(t, 'drums', byHand: true);
        }),
    ];
  }

  Future<void> _toPlaylist(AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    final lists = [for (final p in app.playlists) if (p.editable) p];
    final picked = await showDialog<Playlist>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: Console.panel,
        title: Text('ADD TO', style: Console.label(10, color: Console.ink)),
        children: [
          for (final p in lists)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(p),
              child: Text(p.name, style: Mag.typewriter(13, color: Console.ink)),
            ),
        ],
      ),
    );
    if (picked == null) return;
    try {
      await app.api.addToPlaylist(picked.id, [widget.track.id]);
      unawaited(app.refreshPlaylists());
      messenger.say(snack(Text('Added to ${picked.name}')));
    } catch (e) {
      messenger.say(problem(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final t = widget.track;
    final b = widget.booth;
    final ready = t.isReady;
    final target = widget.forDeck ?? b.other(b.master);
    final onDeck = b.decks.where((d) => d.track?.id == t.id).firstOrNull;
    final d = t.durationMs;
    final length = d == null ? '' : '${d ~/ 60000}:${(d ~/ 1000 % 60).toString().padLeft(2, '0')}';
    final row = MouseRegion(
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      cursor: ready ? SystemMouseCursors.grab : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: ready ? () => widget.loadInto(target, t) : null,
        child: Container(
          height: 50,
          padding: const EdgeInsets.only(left: 2, right: 2),
          decoration: BoxDecoration(
            color: _over ? Console.raised : null,
            borderRadius: BorderRadius.circular(6),
            border: onDeck == null
                ? null
                : Border(left: BorderSide(color: Console.deck(onDeck.name), width: 3)),
          ),
          child: Row(
            children: [
              if (widget.handle != null) widget.handle! else const SizedBox(width: 4),
              Opacity(opacity: ready ? 1 : 0.5, child: Artwork(track: t, size: 36, radius: 3)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.title(13.5, color: ready ? Console.ink : Console.quiet)),
                    Text(ready ? t.artistLine : t.statusLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.typewriter(10.5,
                            color: t.state == 'failed' ? Console.a : Console.quiet)),
                    if (!ready && t.progressFraction != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3, right: 8),
                        child: LinearProgressIndicator(
                            value: t.progressFraction, minHeight: 2, backgroundColor: Console.line),
                      ),
                  ],
                ),
              ),
              if (onDeck != null && !_over)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text('ON ${onDeck.name}',
                      style: Console.label(8, color: Console.deck(onDeck.name))),
                ),
              if (_over && ready) ...[
                for (final dk in [b.a, b.b]) ...[
                  Pad(
                    label: dk.name,
                    colour: Console.deck(dk.name),
                    dim: true,
                    width: 28,
                    height: 26,
                    tooltip: 'Onto deck ${dk.name}',
                    onTap: () => widget.loadInto(dk, t),
                  ),
                  const SizedBox(width: 4),
                ],
              ] else if (ready) ...[
                _PartsGlyph(trackId: t.id),
                _Facts(booth: b, track: t, roomy: widget.roomy),
              ],
              if (widget.roomy && !_over)
                SizedBox(
                  width: 44,
                  child: Text(length,
                      textAlign: TextAlign.right,
                      style: Mag.typewriter(10.5, color: Console.faint)),
                ),
              if (_over || widget.roomy) _Menu(items: _actions(app)),
            ],
          ),
        ),
      ),
    );
    if (!ready) return row;
    return Draggable<Track>(
      data: t,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Console.raised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Console.line),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 18)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Artwork(track: t, size: 34, radius: 3),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(t.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.title(13, color: Console.ink)),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: row,
    );
  }
}

/// Tempo and key, lit where they sit with the master.
class _Facts extends StatelessWidget {
  const _Facts({required this.booth, required this.track, this.roomy = false});
  final Booth booth;
  final Track track;
  final bool roomy;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<TrackTiming?>(
      future: booth.timing.of(track),
      initialData: booth.timing.peek(track.id),
      builder: (context, snap) {
        final tm = snap.data;
        if (tm == null) return SizedBox(width: roomy ? 76 : 40);
        final master = booth.master.timing;
        final shown = booth.master.bpm;
        final tempoOk = tm.bpm != null && shown != null && Booth.syncRatio(tm.bpm!, shown) != null;
        final keyOk = master != null && tm.inKeyWith(master);
        final good = Console.deck(booth.master.name);
        return SizedBox(
          width: roomy ? 76 : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (tm.bpm != null)
                Text(tm.bpm!.toStringAsFixed(0),
                    style: Mag.numerals(14, color: tempoOk ? good : Console.quiet)),
              if (tm.camelot != null) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 28,
                  child: Text(tm.camelot!,
                      textAlign: TextAlign.right,
                      style: Mag.typewriter(10.5, color: keyOk ? good : Console.faint, bold: true)),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// How taking a queued record apart is going, as a small mark beside its tempo: an
/// hourglass in the line, a ring while it happens, the split sign once it is in parts.
class _PartsGlyph extends StatelessWidget {
  const _PartsGlyph({required this.trackId});
  final int trackId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: partsJobs,
        builder: (context, _) {
          final j = partsJobs.of(trackId);
          if (j == null || j.stage == PartsStage.cancelled) {
            return const SizedBox.shrink();
          }
          final accent = Theme.of(context).colorScheme.primary;
          final Widget mark = switch (j.stage) {
            PartsStage.waiting =>
              const Icon(Icons.hourglass_empty, size: 12, color: Console.faint),
            PartsStage.ready =>
              const Icon(Icons.call_split, size: 13, color: Console.ink),
            PartsStage.failed =>
              const Icon(Icons.error_outline, size: 13, color: Console.a),
            _ => SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  value: j.stage == PartsStage.separating ? j.progress : null,
                  strokeWidth: 1.6,
                  color: accent,
                  backgroundColor: Console.line,
                ),
              ),
          };
          return Tooltip(
            message: stageLine(j),
            child:
                Padding(padding: const EdgeInsets.only(right: 8), child: mark),
          );
        },
      );
}

/// Records being taken apart on this computer, the way downloads are shown: the one
/// being done now, the line behind it, what is ready and when, and what failed and why.
class _PartsList extends StatelessWidget {
  const _PartsList(
      {required this.booth, required this.loadInto, required this.forDeck});
  final Booth booth;
  final void Function(engine.Deck deck, Track track) loadInto;
  final engine.Deck? forDeck;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: partsJobs,
        builder: (context, _) {
          final now = partsJobs.running;
          final waiting = partsJobs.waiting;
          final ready = partsJobs.ready;
          final failed = partsJobs.failed;
          if (now.isEmpty &&
              waiting.isEmpty &&
              ready.isEmpty &&
              failed.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.call_split, size: 28, color: Console.faint),
                  const SizedBox(height: 8),
                  Text('NOTHING BEING TAKEN APART',
                      style: Console.label(8.5, color: Console.faint)),
                ],
              ),
            );
          }
          Widget row(PartsJob j) => _JobRow(
              job: j, booth: booth, loadInto: loadInto, forDeck: forDeck);
          return ListView(
            children: [
              if (now.isNotEmpty) ...[
                const _Head('NOW'),
                for (final j in now) row(j)
              ],
              if (waiting.isNotEmpty) ...[
                _Head('WAITING · ${waiting.length}'),
                for (final j in waiting) row(j)
              ],
              if (ready.isNotEmpty) ...[
                _Head('READY · ${ready.length}'),
                for (final j in ready) row(j)
              ],
              if (failed.isNotEmpty) ...[
                _Head('FAILED · ${failed.length}'),
                for (final j in failed) row(j)
              ],
            ],
          );
        },
      );
}

class _Head extends StatelessWidget {
  const _Head(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
        child: Text(text, style: Console.label(8.5, color: Console.quiet)),
      );
}

/// One record on the list: what it is, the stage it is at in words, a bar while it
/// moves, and what can be done about it — stop it, put it next, try it again.
class _JobRow extends StatefulWidget {
  const _JobRow(
      {required this.job,
      required this.booth,
      required this.loadInto,
      required this.forDeck});
  final PartsJob job;
  final Booth booth;
  final void Function(engine.Deck deck, Track track) loadInto;
  final engine.Deck? forDeck;

  @override
  State<_JobRow> createState() => _JobRowState();
}

class _JobRowState extends State<_JobRow> {
  bool _over = false;

  Widget _act(IconData icon, String tip, VoidCallback? onTap) => Tooltip(
        message: tip,
        child: InkResponse(
          onTap: onTap,
          radius: 16,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon,
                size: 16, color: onTap == null ? Console.faint : Console.ink),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final j = widget.job;
    final t = j.track;
    final b = widget.booth;
    final accent = Theme.of(context).colorScheme.primary;
    final onDeck = b.decks.where((d) => d.track?.id == j.trackId).firstOrNull;
    final colour = onDeck != null ? Console.deck(onDeck.name) : accent;
    final place = partsJobs.placeOf(j.trackId);
    final actions = <Widget>[
      if (j.active)
        _act(Icons.close, 'Stop', () => partsJobs.onCancel?.call(j.trackId)),
      if (j.stage == PartsStage.waiting) ...[
        if (place != null && place > 1)
          _act(Icons.vertical_align_top, 'Take apart next',
              () => partsJobs.onPromote?.call(j.trackId)),
        _act(Icons.close, 'Cancel', () => partsJobs.onCancel?.call(j.trackId)),
      ],
      if (j.stage == PartsStage.failed)
        _act(Icons.refresh, 'Try again',
            () => partsJobs.onRetry?.call(j.trackId)),
      if (j.stage == PartsStage.ready && t != null && _over)
        for (final d in [b.a, b.b]) ...[
          Pad(
            label: d.name,
            colour: Console.deck(d.name),
            dim: true,
            width: 28,
            height: 26,
            tooltip: 'Onto deck ${d.name}',
            onTap: () => widget.loadInto(d, t),
          ),
          const SizedBox(width: 4),
        ],
    ];
    final line = stageLine(j);
    final p = j.active
        ? j.stage == PartsStage.fetching && j.total == null
            ? null
            : j.progress ?? (j.stage == PartsStage.separating ? 0.0 : null)
        : null;
    final row = MouseRegion(
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      cursor: t != null ? SystemMouseCursors.grab : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: t == null
            ? null
            : () => widget.loadInto(widget.forDeck ?? b.other(b.master), t),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
          decoration: BoxDecoration(
            color: _over ? Console.raised : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              t == null
                  ? const SizedBox(
                      width: 36,
                      height: 36,
                      child: Icon(Icons.album, color: Console.faint))
                  : Artwork(track: t, size: 36, radius: 3),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(j.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.title(13.5, color: Console.ink)),
                    const SizedBox(height: 1),
                    Tooltip(
                      message: j.stage == PartsStage.failed && j.error != null
                          ? j.error!
                          : '',
                      child: Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Mag.typewriter(10.5,
                            color: j.stage == PartsStage.failed
                                ? Console.a
                                : j.stage == PartsStage.ready
                                    ? Console.ink
                                    : Console.quiet),
                      ),
                    ),
                    if (j.active) ...[
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(1),
                        child: LinearProgressIndicator(
                          value: p,
                          minHeight: 2,
                          color: colour,
                          backgroundColor: Console.line,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              ...actions,
            ],
          ),
        ),
      ),
    );
    if (t == null) return row;
    return Draggable<Track>(
      data: t,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Console.raised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Console.line),
          ),
          child: Artwork(track: t, size: 34, radius: 3),
        ),
      ),
      child: row,
    );
  }
}
