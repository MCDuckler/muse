import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../api/models.dart';
import '../../../state/app_state.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../../state/booth/dj_set.dart';
import '../../../state/booth/set_planner.dart';
import '../../../state/library_arrangement.dart';
import '../../../worker/parts_jobs.dart';
import '../../../worker/this_computer.dart' show fetchHereNow;
import '../../artwork.dart';
import '../../found_row.dart' show PlaceDot;
import '../../mag.dart';
import '../../snack.dart';
import '../booth_clock.dart';
import 'console.dart';
import 'console_check.dart';
import 'data_marks.dart';
import 'set_planner_page.dart';

/// The crate's pages.
enum CrateTab { queue, fits, library, search, similar, check, parts }

/// From this wide, the crate's pages draw their columns: a playlist's records beside
/// the list of playlists, each record's length, its menu always out.
const crateWide = 560.0;

/// Whether every tab can wear its name in the width the row gives it.
///
/// A tab is one [Pad]: eight pixels of air, the icon at 0.42 of its height, five
/// more, then the word — which a Pad clips rather than shrinking, so a word that
/// does not fit is a word with its end cut off. The tabs share the row equally, so
/// what each has is the row less the gaps and the widen button, divided by how many
/// there are.
@visibleForTesting
bool crateWordsFit(
  BuildContext context, List<(CrateTab, String, IconData)> tabs, double across) {
  const height = 30.0, gap = 6.0, widen = 34.0, air = 8.0 * 2, between = 5.0;
  final each = (across - gap * tabs.length - widen) / tabs.length;
  if (each <= 0) return false;
  final style = Console.label(math.max(8.0, height * 0.3));
  var widest = 0.0;
  for (final tab in tabs) {
    final painter = TextPainter(
        text: TextSpan(text: tab.$2, style: style),
        maxLines: 1,
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: TextDirection.ltr)
      ..layout();
    widest = math.max(widest, painter.width);
  }
  return each >= air + height * 0.42 + between + widest;
}


/// What the crates of this session remember — the playlist open last, the lists as
/// they came — forgotten, as a new session starts with them.
@visibleForTesting
void forgetCrateMemory() {
  _ConsoleCrateState._lastList = null;
  _ConsoleCrateState._lists.clear();
}

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
  /// What SEARCH found: the library's records and, past them, songs anywhere the
  /// main search looks — YouTube Music, YouTube, SoundCloud, Bandcamp, Spotify.
  List<Found>? _found;
  bool _looking = false;
  String? _searchTrouble;

  /// The queue by how well each would mix with the one on now, rather than in order.
  bool _byMatch = false;

  /// The playlist open in LIBRARY, and its songs once they are here.
  Playlist? _list;
  List<Track>? _listTracks;

  /// Why the open playlist could not be had, when it could not: not the same thing
  /// as a playlist with nothing in it, which is what a failure used to read as.
  String? _listTrouble;

  /// Every playlist opened in a crate this session, as it last came: shown the moment
  /// it is opened again while the house is asked for it afresh.
  static final _lists = <int, Playlist>{};

  /// The playlist open last, in any crate. A phone's crate is a new one each time
  /// its sheet comes up — and each time it opened on the list of playlists, the one
  /// being worked down gone.
  static int? _lastList;

  /// FITS: what goes with the record on the deck, out of the whole library.
  List<({Track track, double fit, String why})>? _fits;

  /// The record they were found for, so they are not fetched again for the same one,
  /// and are thrown away when the deck changes.
  int? _fitsFor;
  bool _fitsBusy = false;
  String? _fitsTrouble;

  @override
  void initState() {
    super.initState();
    final last = _lastList;
    if (last != null) {
      final p = context.read<AppState>().playlists.where((p) => p.id == last).firstOrNull ?? _lists[last];
      if (p != null) unawaited(_openList(p));
    }
    _tab.addListener(_retab);
    // The deck's record changing is what FITS is about, so it is listened to rather
    // than waited for: the list is for whatever is on now.
    widget.booth.addListener(_deckChanged);
  }

  void _retab() {
    setState(() {});
    if (_tab.value == CrateTab.fits) unawaited(_loadFits());
  }

  void _deckChanged() {
    if (!mounted) return;
    if (_tab.value == CrateTab.fits && _fitsSource?.id != _fitsFor) {
      unawaited(_loadFits());
    }
  }

  /// The record the fits are judged against: the deck that leads, or whichever has
  /// one. Null with both decks empty, and then there is nothing to be like.
  Track? get _fitsSource {
    final b = widget.booth;
    for (final d in [b.master, b.a, b.b]) {
      final t = d.track;
      if (t != null) return t;
    }
    return null;
  }

  Future<void> _loadFits() async {
    final from = _fitsSource;
    if (from == null) {
      setState(() {
        _fits = null;
        _fitsFor = null;
        _fitsTrouble = null;
      });
      return;
    }
    if (_fitsBusy && _fitsFor == from.id) return;
    setState(() {
      _fitsBusy = true;
      _fitsFor = from.id;
      _fitsTrouble = null;
      _fits = null;
    });
    try {
      // What is already in the queue is not a suggestion — it is already coming.
      final queued = context.read<AppState>().player?.items ?? const <Track>[];
      // The same judging the Auto DJ picks by: the house's pick from the whole
      // library, judged again here with the moves, the seam and the taste.
      final found = await widget.booth.auto
          .partnersFor(from,
              limit: 16, source: SetSource.wholeLibrary, exclude: [from.id, for (final t in queued) t.id], keyFirst: true)
          .timeout(const Duration(seconds: 40));
      if (!mounted || _fitsFor != from.id) return;
      setState(() {
        _fits = found;
        _fitsBusy = false;
      });
    } catch (e) {
      if (!mounted || _fitsFor != from.id) return;
      setState(() {
        _fitsBusy = false;
        _fitsTrouble = '$e';
      });
    }
  }

  void _open(CrateTab t) {
    _tab.value = t;
    if (t == CrateTab.search) _focus.requestFocus();
  }

  @override
  void dispose() {
    _tab.removeListener(_retab);
    widget.booth.removeListener(_deckChanged);
    if (widget.tab == null) _tab.dispose();
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The same search as the app's own search page, songs only: the crate used one
  /// of its own that reached YouTube alone, and left out every song the house already
  /// had but this library did not — they were neither "in the library" nor offered.
  void _search(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _found = null;
        _searchTrouble = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 320), () async {
      setState(() => _looking = true);
      try {
        final r = await context.read<AppState>().api.searchEverything(q.trim(), kind: 'song', limit: 40);
        if (!mounted || _query.text != q) return;
        setState(() {
          _found = r.items;
          _searchTrouble = null;
        });
      } catch (e) {
        if (mounted && _query.text == q) {
          setState(() {
            _found = const [];
            _searchTrouble = '$e';
          });
        }
      } finally {
        if (mounted) setState(() => _looking = false);
      }
    });
  }

  /// How well [t] follows the record in the room — the set planner's own fit, the
  /// one the Auto DJ and the set go by — as a sort key: lower first.
  double _score(Track t) {
    final m = widget.booth.master;
    final fit = SetPlanner.fit(m.timing, widget.booth.timing.peek(t.id),
        ta: m.track, tb: t, fromPitch: m.pitch, move: m.track == null ? null : widget.booth.auto.moveScoreOf(m.track!, t));
    return fit == Fit.nothing ? 0 : -fit.score;
  }

  Future<void> _openList(Playlist p) async {
    final had = _lists[p.id];
    _lastList = p.id;
    setState(() {
      _list = had ?? p;
      _listTracks = had?.items;
      _listTrouble = null;
    });
    try {
      final full = await context.read<AppState>().api.playlist(p.id);
      _lists[p.id] = full;
      if (mounted && _list?.id == p.id) {
        setState(() {
          _list = full;
          _listTracks = full.items;
        });
      }
    } catch (e) {
      // Only for the list still open: an answer about one left behind is not news
      // about this one.
      if (mounted && _list?.id == p.id) setState(() => _listTrouble = '$e');
    }
  }

  void _closeList() => setState(() {
        _list = null;
        _lastList = null;
      });

  /// What the pages draw of the app's state, taken once a build: only those, so the
  /// crate is not rebuilt with every download's progress and every cover that comes.
  late (List<Track>, Queue?, List<Queue>) _queueNow;
  late List<Playlist> _listsNow;
  late List<PlaylistFolder> _foldersNow;

  @override
  Widget build(BuildContext context) {
    _queueNow = context.select<AppState, (List<Track>, Queue?, List<Queue>)>(
        (a) => (a.player?.items ?? const <Track>[], a.activeQueue, a.queues));
    _listsNow = context.select<AppState, List<Playlist>>((a) => a.playlists);
    _foldersNow = context.select<AppState, List<PlaylistFolder>>((a) => a.folders);
    final tab = _tab.value;
    final partsHere = widget.booth.parts.separatesHere;
    return Plate(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: LayoutBuilder(builder: (context, c) {
        final tabs = [
          (CrateTab.queue, 'QUEUE', Icons.queue_music),
          (CrateTab.fits, 'FITS', Icons.compare_arrows),
          (CrateTab.library, 'LIBRARY', Icons.library_music_outlined),
          (CrateTab.search, 'SEARCH', Icons.search),
          (CrateTab.similar, 'SIMILAR', Icons.auto_awesome_outlined),
          (CrateTab.check, 'CHECK', Icons.fact_check_outlined),
          if (partsHere) (CrateTab.parts, 'PARTS', Icons.call_split),
        ];
        // Whether the words fit, asked rather than guessed.
        //
        // This was a width: past 470 pixels the tabs wore their names. But the tabs
        // share the row equally, so what each one has is the row divided by however
        // many there are — five, or six when a record is being taken apart — and the
        // longest of the words has to fit in that with its icon beside it. At 470 with
        // six tabs it does not, and a Pad clips rather than shrinking: the crate read
        // LIBRAR, SEARO, SIMILA, which is how it looked on screen for anyone whose
        // crate was that wide.
        //
        // Measured instead, against the font the labels are actually drawn in, so it
        // also holds at a larger text size and for however many tabs there are.
        final roomy = crateWordsFit(context, tabs, c.maxWidth);
        // Whether the pages have room for their columns — the lists beside a
        // playlist, a record's length, its menu always out. Not the same question as
        // whether the tabs' words fit: with seven tabs those need some 800 pixels,
        // and a crate widened to half the screen was still drawn as a narrow one.
        final wide = c.maxWidth >= crateWide;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (final (t, label, icon) in tabs) ...[
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
                CrateTab.queue => _queue(wide),
                CrateTab.fits => _fitsPage(wide),
                CrateTab.library => _library(wide),
                CrateTab.search => _searchPage(wide),
                CrateTab.similar => _SimilarList(
                    booth: widget.booth,
                    row: (t, note) => _Row(
                      key: ValueKey('sim-${t.id}'),
                      track: t,
                      booth: widget.booth,
                      loadInto: widget.loadInto,
                      forDeck: widget.forDeck,
                      roomy: wide,
                      ask: true,
                      note: note,
                    )),
                CrateTab.check => CueCheckList(
                    booth: widget.booth,
                    row: (t, note) => _Row(
                      key: ValueKey('chk-${t.id}'),
                      track: t,
                      booth: widget.booth,
                      loadInto: widget.loadInto,
                      forDeck: widget.forDeck,
                      roomy: wide,
                      ask: true,
                      note: note,
                    )),
                CrateTab.parts => _PartsList(
                    booth: widget.booth, loadInto: widget.loadInto, forDeck: widget.forDeck),
              },
            ),
          ],
        );
      }),
    );
  }

  /// [place]: where it is in the list it is drawn in, for its key — a playlist can
  /// hold the same record twice, and two rows with one key are one row to Flutter.
  Widget _row(Track t, bool roomy, {int? queuePos, Widget? handle, int? place, bool played = false, bool ask = false}) => _Row(
        key: ValueKey('${queuePos ?? 'x'}-${place ?? ''}-${t.id}'),
        track: t,
        booth: widget.booth,
        loadInto: widget.loadInto,
        forDeck: widget.forDeck,
        roomy: roomy,
        queuePos: queuePos,
        handle: handle,
        played: played,
        ask: ask,
      );

  // ------------------------------------------------------------------ FITS
  /// Everything in the library that would go with the record on the deck, best first.
  ///
  /// The same judgement the automix makes when it picks what follows — tempo, key,
  /// how loud and how sung, and what a pair of them sounds like — asked of the whole
  /// library at once instead of the next slot in a queue. What it is for is the moment
  /// a DJ has a record playing and wants to know what they have that goes with it,
  /// which up to now meant scrolling a playlist and remembering.
  ///
  /// Only records the house has listened to can be judged, so this is a list of the
  /// scanned ones: the server's side joins on track_traits and the rest simply are not
  /// in it. Anything already in the queue is left out — it is not a suggestion, it is
  /// already coming.
  Widget _fitsPage(bool roomy) {
    final from = _fitsSource;
    if (from == null) {
      return const _Empty(icon: Icons.album_outlined, line: 'PUT A RECORD ON A DECK');
    }
    final found = _fits;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Icon(Icons.compare_arrows, size: 13, color: Console.quiet),
          const SizedBox(width: 5),
          Expanded(
            child: Text('WHAT GOES WITH ${from.displayTitle.toUpperCase()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Console.label(8.5, color: Console.quiet)),
          ),
          if (_fitsBusy)
            const SizedBox(
                width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
          else
            _Toggle(
              label: 'AGAIN',
              tooltip: 'Look through the library again',
              onTap: () {
                _fitsFor = null;
                unawaited(_loadFits());
              },
            ),
        ]),
        const SizedBox(height: 4),
        Expanded(
          child: _fitsTrouble != null
              ? _Empty(icon: Icons.cloud_off, line: 'COULD NOT LOOK')
              : found == null
                  ? const Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 1.5)))
                  : found.isEmpty
                      ? const _Empty(
                          icon: Icons.music_off, line: 'NOTHING SCANNED THAT FITS')
                      : Builder(builder: (context) {
                          // Against the best one found, not against a perfect score.
                          // The judging adds up terms to about 1.85 at its most, and a
                          // record that scores 1.2 is not "65% of a match" — there is
                          // no such thing. What can honestly be shown is how this one
                          // compares to the best the library had, which is the
                          // question somebody scrolling the list is asking.
                          // (The best by score: those in key come first, not always the best.)
                          final best = found.map((f) => f.fit).reduce(math.max);
                          return ListView.builder(
                            itemCount: found.length,
                            itemBuilder: (context, i) => _Row(
                              key: ValueKey('fit-${found[i].track.id}'),
                              track: found[i].track,
                              booth: widget.booth,
                              loadInto: widget.loadInto,
                              forDeck: widget.forDeck,
                              roomy: roomy,
                              note: found[i].why,
                              ask: true,
                              fit: best > 0 ? (found[i].fit / best).clamp(0.0, 1.0) : null,
                            ),
                          );
                        }),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ QUEUE
  Widget _queue(bool roomy) {
    final app = context.read<AppState>();
    final (items, active, queues) = _queueNow;
    // The record the room is on: the rows above it in the queue are played.
    final b = widget.booth;
    final onId = b.auto.running ? b.auto.current?.id : b.master.track?.id;
    final nowAt = onId == null ? -1 : items.indexWhere((t) => t.id == onId);
    final total = items.fold<int>(0, (a, t) => a + (t.durationMs ?? 0));
    final waiting = items.where((t) => !t.isReady).length;
    String clock(int ms) {
      final m = ms ~/ 60000;
      return m >= 60 ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m' : '$m min';
    }

    final others = [for (final q in queues) if (q.id != active?.id) q];
    final bar = Row(
      children: [
        // Which queue this is, and the others to change to: mixing a playlist puts it
        // in a queue of its own, and the one there before is a tap away, not gone.
        if (active != null)
          Flexible(
            child: PopupMenuButton<Queue>(
              tooltip: others.isEmpty ? active.name : 'Change to another queue',
              enabled: others.isNotEmpty,
              color: Console.raised,
              onSelected: (q) => app.openQueue(q.id, autoplay: false),
              itemBuilder: (context) => [
                for (final q in others)
                  PopupMenuItem(
                    value: q,
                    height: 36,
                    child: Row(children: [
                      Icon(Icons.queue_music, size: 15, color: Console.quiet),
                      const SizedBox(width: 10),
                      Expanded(child: Text(q.name, style: Mag.typewriter(12, color: Console.ink))),
                      Text('${q.total}', style: Mag.typewriter(11, color: Console.quiet)),
                    ]),
                  ),
              ],
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text(active.name.toUpperCase(),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: Console.label(8.5, color: Console.ink)),
                ),
                if (others.isNotEmpty) Icon(Icons.arrow_drop_down, size: 16, color: Console.quiet),
              ]),
            ),
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              '${items.length} ${items.length == 1 ? 'RECORD' : 'RECORDS'} · ${clock(total)}'
              '${waiting > 0 ? ' · $waiting ON THE WAY' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
              line: 'THE QUEUE IS EMPTY — MIX A PLAYLIST FROM THE LIBRARY, OR ADD FROM SEARCH'),
        ),
      ]);
    }
    if (_byMatch) {
      // Each record scored once, then sorted: scored inside the comparison it was
      // the planner run twice for every comparison the sort made.
      final sorted = [for (var i = 0; i < items.length; i++) (i, items[i], _score(items[i]))]
        ..sort((a, b) => a.$3.compareTo(b.$3));
      return Column(children: [
        bar,
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            itemCount: sorted.length,
            itemBuilder: (context, i) =>
                _row(sorted[i].$2, roomy, queuePos: sorted[i].$1, played: sorted[i].$1 < nowAt, ask: true),
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
              played: i < nowAt,
              ask: true,
              handle: ReorderableDragStartListener(
                index: i,
                child: MouseRegion(
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
  /// The playlists, as the library files them — pinned, then each folder, then the
  /// rest — each with its cover and a way to mix it at once; and, one picked, its
  /// records, to load, queue, or mix the whole of.
  Widget _library(bool wide) {
    final lists = _listsNow;
    final folders = _foldersNow;
    final open = _list;
    // The open list changed somewhere else — added to from SEARCH, on another
    // device, a fetch finishing: asked for again rather than shown as it was.
    if (open != null && _listTracks != null && _listTrouble == null) {
      final now = lists.where((p) => p.id == open.id).firstOrNull;
      if (now != null && (now.itemCount != _listTracks!.length || now.waiting != open.waiting)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _list?.id == now.id) unawaited(_openList(now));
        });
      }
    }

    Widget listOfLists() {
      if (lists.isEmpty) {
        return const _Empty(icon: Icons.library_music_outlined, line: 'NO PLAYLISTS YET');
      }
      final shelf = LibraryArrangement(lists, folders);
      final rows = <Widget>[
        if (_queueNow.$1.isEmpty)
          const _Hint('PICK ONE AND PRESS ▶ — THE AUTO DJ MIXES IT FROM THE TOP'),
        if (!shelf.flat && shelf.pinned.isNotEmpty) ...[
          const _Head('PINNED'),
          for (final p in shelf.pinned) _ListRow(playlist: p, open: open?.id == p.id, onOpen: () => _openList(p)),
        ],
        for (final f in shelf.shelves)
          if (f.playlists.isNotEmpty) ...[
            _FolderHead(shelf: f),
            for (final p in f.playlists)
              _ListRow(playlist: p, open: open?.id == p.id, indent: true, onOpen: () => _openList(p)),
          ],
        if (!shelf.flat && shelf.loose.isNotEmpty) const _Head('PLAYLISTS'),
        for (final p in shelf.loose)
          if (shelf.flat || !p.pinned) _ListRow(playlist: p, open: open?.id == p.id, onOpen: () => _openList(p)),
      ];
      return ListView(children: rows);
    }

    Widget songs() {
      final p = _list;
      if (p == null) {
        return const _Empty(icon: Icons.arrow_back, line: 'PICK A PLAYLIST');
      }
      final tracks = _listTracks;
      final here = tracks?.where((t) => t.isReady).length ?? 0;
      final away = (tracks?.length ?? 0) - here;
      final app = context.read<AppState>();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 44,
            child: Row(children: [
              if (!wide)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.arrow_back, size: 18, color: Console.quiet),
                  tooltip: 'All playlists',
                  onPressed: _closeList,
                ),
              p.isFavourites
                  ? SizedBox(width: 34, height: 34, child: Icon(Icons.favorite, size: 20, color: Console.ink))
                  : PlaylistArt(playlist: p, size: 34, radius: 4),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(13.5, color: Console.ink)),
                    Text(
                        tracks == null
                            ? '${p.itemCount} ${p.itemCount == 1 ? 'RECORD' : 'RECORDS'}'
                            : '${tracks.length} ${tracks.length == 1 ? 'RECORD' : 'RECORDS'}'
                                '${away > 0 ? ' · $away NOT HERE YET' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Console.label(8, color: Console.quiet)),
                  ],
                ),
              ),
              if (tracks != null && tracks.isNotEmpty) ...[
                Pad(
                  label: 'MIX IT',
                  icon: Icons.play_arrow,
                  colour: Theme.of(context).colorScheme.primary,
                  lit: true,
                  height: 28,
                  tooltip: 'The Auto DJ mixes this playlist from now, in its order —\n'
                      'the record on now first. The queue you had is kept.',
                  onTap: () => mixList(context, name: p.name, tracks: () async => tracks),
                ),
                const SizedBox(width: 4),
                Pad(
                  icon: Icons.playlist_add,
                  height: 28,
                  width: 30,
                  colour: Console.ink,
                  tooltip: 'Add the records that are here to the end of the queue',
                  onTap: () => _queueAll(app, tracks),
                ),
              ],
              const SizedBox(width: 2),
              _Menu(items: [
                if (tracks != null && tracks.isNotEmpty) ...[
                  ('Shuffle it and mix it', Icons.shuffle,
                      () => mixList(context, name: p.name, tracks: () async => tracks, shuffle: true)),
                  ('Queue all next', Icons.playlist_play, () => _queueAll(app, tracks, mode: 'next')),
                ],
                if (away > 0)
                  ('Fetch the $away not here yet', Icons.download_outlined, () async {
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      final n = await app.api.downloadPlaylist(p.id);
                      unawaited(fetchHereNow([for (final t in tracks!) if (!t.isReady) t.id]));
                      messenger.say(snack(Text(n == 0 ? 'Already on their way' : 'Fetching $n')));
                    } catch (e) {
                      messenger.say(problem(e));
                    }
                  }),
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
              ]),
            ]),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _listTrouble != null && tracks == null
                ? _Empty(icon: Icons.cloud_off, line: 'COULD NOT OPEN IT', onAgain: () => _openList(p))
                : tracks == null
                    ? const Center(
                        child: SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.5)))
                    : tracks.isEmpty
                        ? const _Empty(icon: Icons.music_off, line: 'NOTHING IN IT')
                        : ListView.builder(
                            itemCount: tracks.length,
                            itemBuilder: (context, i) => _row(tracks[i], wide, place: i),
                          ),
          ),
        ],
      );
    }

    // Both at once, once there is something to put in the second pane.
    //
    // The split used to be unconditional, so with no playlist picked the crate stood
    // half empty: two hundred pixels of names, a rule, and then four hundred pixels of
    // nothing with an arrow in the middle of it saying PICK A PLAYLIST — while the
    // decks next to it were squeezed to make room for it. The narrow crate has always
    // done the sensible thing here; it does it at every width now, and the names get
    // the whole crate until one of them is chosen.
    if (wide && _list != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 210, child: listOfLists()),
          VerticalDivider(width: 14, color: Console.line),
          Expanded(child: songs()),
        ],
      );
    }
    return _list == null ? listOfLists() : songs();
  }

  /// The records of a list that are here, onto the queue — those not here yet are
  /// left out and said, since the Auto DJ passes over a record it cannot play.
  Future<void> _queueAll(AppState app, List<Track> tracks, {String mode = 'end'}) async {
    final messenger = ScaffoldMessenger.of(context);
    final here = [for (final t in tracks) if (t.isReady) t];
    if (here.isEmpty) {
      messenger.say(snack(const Text('None of them is here yet — fetch them first')));
      return;
    }
    try {
      await app.addTracks(here, mode: mode);
      final left = tracks.length - here.length;
      messenger.say(snack(Text('${here.length} ${mode == 'next' ? 'next in' : 'added to'} the queue'
          '${left > 0 ? ' · $left not here yet, left out' : ''}')));
    } catch (e) {
      messenger.say(problem(e));
    }
  }

  // ------------------------------------------------------------------ SEARCH
  Widget _searchPage(bool roomy) {
    final accent = Theme.of(context).colorScheme.primary;
    final found = _found;
    // A record of the library's that is here goes in as any crate row does; anything
    // else — not fetched yet, the house's, somebody else's service — is offered to be
    // fetched, with its cover and a dot saying where it is from.
    final mine = [for (final f in found ?? const <Found>[]) if (f.track != null && f.track!.isReady && f.place == 'library') f];
    final rest = [for (final f in found ?? const <Found>[]) if (!mine.contains(f)) f];
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
            hintText: 'Title, artist — the library, then everywhere',
            hintStyle: Mag.typewriter(12, color: Console.faint),
            filled: true,
            fillColor: Console.ground,
            prefixIcon: _looking
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  )
                : Icon(Icons.search, size: 18, color: Console.quiet),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: found == null
              ? const _Empty(icon: Icons.search, line: 'TYPE TO SEARCH')
              : found.isEmpty
                  ? _Empty(
                      icon: _searchTrouble == null ? Icons.search_off : Icons.cloud_off,
                      line: _searchTrouble == null ? 'NOTHING FOUND' : 'COULD NOT SEARCH')
                  : ListView(
                      children: [
                        if (mine.isNotEmpty) _Head('IN THE LIBRARY · ${mine.length}'),
                        for (final (i, f) in mine.indexed) _row(f.track!, roomy, place: i),
                        if (rest.isNotEmpty) ...[
                          const _Head('NOT HERE YET — ADDED, IT IS FETCHED'),
                          for (final f in rest) _Elsewhere.found(f, key: ValueKey('f-${f.place}-${f.id}')),
                        ],
                      ],
                    ),
        ),
      ],
    );
  }
}

/// [name]'s records, mixed by the Auto DJ from now (AppState.mixInBooth): a queue of
/// their own, the record on now first, the queue there before kept and offered back.
/// [tracks] is asked for only here, so a playlist not yet opened is fetched on the tap.
Future<void> mixList(BuildContext context,
    {required String name, required Future<List<Track>> Function() tracks, bool shuffle = false}) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final was = app.activeQueue;
  try {
    final list = await tracks();
    if (list.isEmpty) {
      messenger.say(snack(Text('Nothing in $name to mix')));
      return;
    }
    await app.mixInBooth(list, name: name, shuffle: shuffle);
    final away = list.where((t) => !t.isReady).length;
    messenger.say(snack(
      Text('Mixing $name${shuffle ? ', shuffled' : ''}'
          '${away > 0 ? ' · $away not here yet, fetched as they come up' : ''}'),
      action: was == null || was.name == name
          ? null
          : SnackBarAction(label: 'Back to ${was.name}', onPressed: () => app.openQueue(was.id, autoplay: false)),
    ));
  } catch (e) {
    messenger.say(problem(e));
  }
}

/// A song that is not here to play yet — not in the library, or in it but never
/// fetched, or somebody else's service's: its cover, where it is from, and the ways
/// to have it. Added, it is fetched on this computer at once and shared with the house.
class _Elsewhere extends StatefulWidget {
  const _Elsewhere({
    super.key,
    required this.title,
    required this.by,
    required this.resolve,
    this.durationMs,
    this.cover,
    this.track,
    this.place,
  });

  /// A YouTube Music hit, as SIMILAR offers them; [track] where the house knows it.
  factory _Elsewhere.hit(RemoteHit h, {Key? key, Track? track}) => _Elsewhere(
        key: key,
        title: track?.displayTitle ?? h.title,
        by: h.artistLine,
        durationMs: h.durationMs,
        cover: h.coverPath,
        track: track,
        place: 'ytmusic',
        resolve: (app) async =>
            track ?? await app.api.resolve(videoId: h.videoId, title: h.title, artists: h.artists, album: h.album),
      );

  /// A row of the search, from wherever it was found.
  factory _Elsewhere.found(Found f, {Key? key}) => _Elsewhere(
        key: key,
        title: f.title,
        by: f.subtitle,
        durationMs: f.durationMs,
        cover: f.coverUrl,
        track: f.track,
        place: f.place,
        resolve: (app) async => f.track ?? await app.api.addFound(f),
      );

  final String title, by;
  final int? durationMs;

  /// The picture, addressed through the house (a search hit's), when there is no
  /// [track] with a cover of its own.
  final String? cover;
  final Track? track;

  /// Where it was found: library, ytmusic, youtube, soundcloud, bandcamp, spotify.
  final String? place;
  final Future<Track> Function(AppState app) resolve;

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
      final t = await widget.resolve(app);
      // 'library': fetched and kept, and nothing queued — a record for later.
      if (mode != 'library') {
        await app.addTrack(t, mode: mode);
      }
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
    final d = widget.durationMs ?? widget.track?.durationMs;
    final t = widget.track;
    final place = widget.place;
    return _Hover(
      child: Row(children: [
        Stack(clipBehavior: Clip.none, children: [
          Opacity(opacity: 0.85, child: ElsewhereArt(track: t, cover: widget.cover, title: widget.title, by: widget.by, size: 36)),
          if (place != null) Positioned(left: -3, bottom: -3, child: PlaceDot(place, size: 7)),
        ]),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(13, color: Console.ink)),
              Text(
                  [
                    if (t != null && t.state != 'ready' && t.progressFraction != null) t.statusLine else widget.by,
                    if (d != null) '${d ~/ 60000}:${(d ~/ 1000 % 60).toString().padLeft(2, '0')}',
                  ].where((x) => x.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Mag.typewriter(10.5, color: Console.quiet)),
            ],
          ),
        ),
        if (_adding)
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5))
        else if (_added)
          Text('FETCHING', style: Console.label(8, color: Console.ink))
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
          const SizedBox(width: 4),
          Pad(
              icon: Icons.download_outlined,
              width: 30,
              height: 26,
              tooltip: 'Fetch it into the library, nothing queued',
              onTap: () => _add('library')),
        ],
      ]),
    );
  }
}

/// What goes with what is on: the records on the decks and the next few in the
/// queue, asked of the house (recommend.py) — its lists, what was played around them,
/// how they sound, YouTube Music's radio. What is here is a crate row like any other,
/// ready for a deck; what is not is a tap from the queue, or from the library. The dial
/// says how far past the library to look.
class _SimilarList extends StatefulWidget {
  const _SimilarList({required this.booth, required this.row});
  final Booth booth;
  final Widget Function(Track track, String note) row;

  @override
  State<_SimilarList> createState() => _SimilarListState();
}

class _SimilarListState extends State<_SimilarList> {
  List<Pick>? _found;
  List<Track> _seeds = const [];
  bool _asking = false;
  String? _trouble;
  double _fresh = 0.5;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  List<Track> _seedsNow() {
    final app = context.read<AppState>();
    final b = widget.booth;
    final out = <Track>[];
    for (final t in [b.master.track, b.other(b.master).track]) {
      if (t != null && !out.any((x) => x.id == t.id)) out.add(t);
    }
    for (final t in app.player?.items ?? const <Track>[]) {
      if (out.length >= 4) break;
      if (t.isReady && !out.any((x) => x.id == t.id)) out.add(t);
    }
    return out;
  }

  Future<void> _ask() async {
    final seeds = _seedsNow();
    setState(() {
      _seeds = seeds;
      _asking = true;
      _trouble = null;
    });
    if (seeds.isEmpty) {
      setState(() {
        _found = const [];
        _asking = false;
      });
      return;
    }
    final app = context.read<AppState>();
    try {
      final got = await app.api.recommend(
          seeds: [for (final t in seeds) t.id],
          exclude: [for (final t in app.player?.items ?? const <Track>[]) t.id],
          fresh: _fresh,
          limit: 20);
      if (mounted) setState(() => _found = got);
    } catch (e) {
      if (mounted) {
        setState(() {
          _found = const [];
          _trouble = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  Future<void> _dismiss(Pick p) async {
    setState(() => _found = [for (final o in _found ?? const <Pick>[]) if (o.key != p.key) o]);
    try {
      await context.read<AppState>().api.dismissPick(p);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 2, 2, 4),
          child: Row(children: [
            Expanded(
              child: Text(
                _seeds.isEmpty
                    ? 'LIKE WHAT IS ON: nothing on the decks or in the queue yet'
                    : 'LIKE ${_seeds.map((t) => t.displayTitle.toUpperCase()).take(2).join(' · ')}${_seeds.length > 2 ? ' · …' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Console.label(8.5),
              ),
            ),
            for (final (v, label) in const [(0.0, 'MINE'), (0.5, 'MIX'), (1.0, 'NEW')]) ...[
              _Toggle(
                  label: label,
                  on: (_fresh - v).abs() < 0.01,
                  onTap: _asking
                      ? null
                      : () {
                          setState(() => _fresh = v);
                          _ask();
                        }),
              const SizedBox(width: 3),
            ],
            Pad(icon: Icons.refresh, width: 30, height: 24, tooltip: 'Ask again, for what is on now', onTap: _asking ? null : _ask),
          ]),
        ),
        Expanded(
          child: found == null || _asking
              ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : found.isEmpty
                  ? Center(
                      child: Text(
                          _trouble != null
                              ? 'The house could not answer.'
                              : _seeds.isEmpty
                                  ? 'Put a record on, or something in the queue.'
                                  : _fresh >= 0.99
                                      ? 'Nothing new beside these — the library has it all.'
                                      : 'Nothing else here goes with these yet.',
                          textAlign: TextAlign.center,
                          style: Mag.typewriter(11, color: Console.quiet)))
                  : ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        for (final p in found)
                          GestureDetector(
                            key: ValueKey('sim-${p.key}'),
                            onLongPress: () => _dismiss(p),
                            child: Tooltip(
                              message: '${p.why.isEmpty ? '' : '${p.why}\n'}Hold to wave it away',
                              waitDuration: const Duration(milliseconds: 700),
                              child: p.track != null && p.track!.isReady
                                  ? widget.row(p.track!, [
                                      if (p.where == 'house') 'the house has it',
                                      if (p.why.isNotEmpty) p.why,
                                    ].join(' · '))
                                  : _Elsewhere.hit(
                                      p.hit ??
                                          RemoteHit(
                                            videoId: p.track!.providerId ?? '',
                                            title: p.track!.title,
                                            artists: p.track!.artists,
                                            album: p.track!.album,
                                            durationMs: p.track!.durationMs,
                                          ),
                                      key: ValueKey('else-${p.key}'),
                                      track: p.track),
                            ),
                          ),
                      ],
                    ),
        ),
      ],
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
  const _Empty({required this.icon, required this.line, this.onAgain});
  final IconData icon;
  final String line;

  /// Where something went wrong rather than there being nothing: a way to try again.
  final VoidCallback? onAgain;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 26, color: Console.faint),
          const SizedBox(height: 8),
          Text(line, textAlign: TextAlign.center, style: Console.label(8.5, color: Console.faint)),
          if (onAgain != null) ...[
            const SizedBox(height: 10),
            _Toggle(label: 'TRY AGAIN', onTap: onAgain),
          ],
        ]),
      );
}

/// A line of advice over a list, where the list is the answer to "now what?".
class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
        child: Row(children: [
          Icon(Icons.play_circle_outline, size: 14, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: Console.label(8, color: Console.quiet))),
        ]),
      );
}

/// A playlist in the crate: its cover, its name, how many records and how many of
/// them are not here yet — and ▶, which has the Auto DJ mix it from now.
class _ListRow extends StatelessWidget {
  const _ListRow({required this.playlist, required this.open, required this.onOpen, this.indent = false});
  final Playlist playlist;
  final bool open;
  final VoidCallback onOpen;

  /// Filed in a folder: set in under its name.
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final p = playlist;
    final app = context.read<AppState>();
    return Padding(
      padding: EdgeInsets.only(left: indent ? 10 : 0),
      child: _Hover(
        lit: open,
        onTap: onOpen,
        child: Row(children: [
          p.isFavourites
              ? SizedBox(width: 32, height: 32, child: Icon(Icons.favorite, size: 18, color: open ? Console.ink : Console.quiet))
              : PlaylistArt(playlist: p, size: 32, radius: 4),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(13, color: Console.ink)),
                Text(
                    [
                      '${p.itemCount}',
                      if (p.waiting > 0) '${p.waiting} not here yet',
                      if (p.saved && p.ownerName != null) p.ownerName!,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.typewriter(10, color: Console.faint)),
              ],
            ),
          ),
          if (p.autoSplit)
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 4),
              child: Tooltip(
                  message: 'Every song is taken apart', child: Icon(Icons.call_split, size: 13, color: Console.quiet)),
            ),
          if (p.itemCount > 0)
            Pad(
              icon: Icons.play_arrow,
              width: 30,
              height: 26,
              colour: Theme.of(context).colorScheme.primary,
              tooltip: 'Mix ${p.name} — the Auto DJ plays it from now',
              onTap: () => mixList(context, name: p.name, tracks: () async {
                final full = await app.api.playlist(p.id);
                _ConsoleCrateState._lists[p.id] = full;
                return full.items;
              }),
            ),
        ]),
      ),
    );
  }
}

/// A folder's divider over its playlists: its name, how many, and ▶ for the lot of
/// them as one list — every song in the folder once, list by list.
class _FolderHead extends StatelessWidget {
  const _FolderHead({required this.shelf});
  final FolderShelf shelf;

  @override
  Widget build(BuildContext context) {
    final f = shelf.folder;
    final app = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 10, 0, 2),
      child: Row(children: [
        Icon(Icons.folder_outlined, size: 13, color: Console.quiet),
        const SizedBox(width: 6),
        Expanded(
          child: Text('${f.name.toUpperCase()} · ${shelf.playlists.length}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: Console.label(8.5, color: Console.quiet)),
        ),
        Pad(
          icon: Icons.play_arrow,
          width: 30,
          height: 22,
          colour: Console.quiet,
          tooltip: 'Mix the whole folder — every song in it once',
          onTap: () => mixList(context, name: f.name, tracks: () => app.api.folderTracks(f.id)),
        ),
      ]),
    );
  }
}

/// A small switch in words, the way the console labels things.
class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.onTap, this.tooltip, this.on = false});
  final String label;
  final VoidCallback? onTap;
  final String? tooltip;

  /// Lit: the one of a set that is chosen.
  final bool on;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip ?? '',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.fromLTRB(7, 4, 7, 3),
            decoration: BoxDecoration(
              color: on ? Console.ink : null,
              border: Border.all(color: on ? Console.ink : Console.line),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label, style: Console.label(8, color: on ? Console.panel : Console.ink)),
          ),
        ),
      );
}

/// A "more" menu of (label, icon, action). [onOpen] and [onClose] say when its menu
/// is up: a row that shows this only under the pointer must keep it on while the
/// pointer is over the menu, or the button is gone before the choice comes back and
/// Flutter drops the choice on the floor.
class _Menu extends StatelessWidget {
  const _Menu({required this.items, this.onOpen, this.onClose});
  final List<(String, IconData, Future<void> Function())> items;
  final VoidCallback? onOpen, onClose;

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
        tooltip: 'More',
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: Icon(Icons.more_horiz, color: Console.quiet),
        color: Console.raised,
        onOpened: onOpen,
        onCanceled: onClose,
        onSelected: (i) {
          onClose?.call();
          unawaited(items[i].$3());
        },
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
      this.handle,
      this.note,
      this.fit,
      this.played = false,
      this.ask = false});
  final Track track;
  final Booth booth;
  final void Function(engine.Deck deck, Track track) loadInto;
  final engine.Deck? forDeck;
  final bool roomy;

  /// Played already, in the queue: above the record the room is on.
  final bool played;

  /// Whether to ask the house for the record's whole analysis for its marks. Lists a
  /// DJ is about to play from (the queue, FITS) do; a playlist or a search being
  /// scrolled through does not — asked of a record the house had not measured, that
  /// is seconds of its work, for every row scrolled past.
  final bool ask;

  /// Where it is in the queue, when this is the queue.
  final int? queuePos;
  final Widget? handle;

  /// Why this one was put here, said in the row's second line in place of the artist:
  /// the words the judging came back with. Null everywhere but FITS.
  final String? note;

  /// How well it goes with what is on, 0 to 1.
  final double? fit;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _over = false;

  /// The row's menu is up: it stays mounted though the pointer has left the row.
  bool _menuOpen = false;

  List<(String, IconData, Future<void> Function())> _actions(AppState app) {
    final t = widget.track;
    final pos = widget.queuePos;
    final liked = app.isFavourite(t.id);
    return [
      if (widget.booth.auto.running && t.isReady && widget.booth.auto.next?.id != t.id)
        ('Mix in next', Icons.queue_play_next, () => widget.booth.auto.swapNext(t)),
      if (pos == null) ...[
        ('Add to the queue', Icons.playlist_add, () => _toQueue(app)),
        ('Add as the next', Icons.playlist_play, () => _toQueue(app, mode: 'next')),
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

  /// Onto a queue: the one playing when it is the only one, else a choice of them
  /// (the one playing first and marked), at the end or as the next.
  Future<void> _toQueue(AppState app, {String mode = 'end'}) async {
    final t = widget.track;
    final messenger = ScaffoldMessenger.of(context);
    final queues = [
      ...app.queues.where((q) => q.id == app.activeQueue?.id),
      ...app.queues.where((q) => q.id != app.activeQueue?.id),
    ];
    Queue? picked;
    if (queues.length <= 1) {
      picked = queues.firstOrNull;
    } else {
      picked = await showDialog<Queue>(
        context: context,
        builder: (context) => SimpleDialog(
          backgroundColor: Console.panel,
          title: Text(mode == 'next' ? 'NEXT IN' : 'ADD TO', style: Console.label(10, color: Console.ink)),
          children: [
            for (final q in queues)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(q),
                child: Row(children: [
                  Icon(q.id == app.activeQueue?.id ? Icons.play_arrow : Icons.queue_music, size: 15, color: Console.quiet),
                  const SizedBox(width: 10),
                  Expanded(child: Text(q.name, style: Mag.typewriter(13, color: Console.ink))),
                  Text('${q.total}', style: Mag.typewriter(11, color: Console.quiet)),
                ]),
              ),
          ],
        ),
      );
      if (picked == null || !mounted) return;
    }
    try {
      if (picked == null) {
        await app.addTrack(t, mode: mode);
      } else {
        await app.addTracksTo(picked, [t], mode: mode);
      }
      messenger.say(snack(Text(mode == 'next' ? 'Next in ${picked?.name ?? 'the queue'}' : 'Added to ${picked?.name ?? 'the queue'}')));
    } catch (e) {
      messenger.say(problem(e));
    }
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
    // On its way to a deck, or the Auto DJ's next: said on the row, in the colour of
    // the deck it is going to — the row clicked is the row that says LOADING.
    final loadingOn = b.decks.where((d) => d.coming?.id == t.id).firstOrNull;
    final isNext = onDeck == null && loadingOn == null && b.auto.running && b.auto.next?.id == t.id;
    final edge = loadingOn ?? onDeck ?? (isNext ? b.other(b.master) : null);
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
            border: edge == null
                ? null
                : Border(
                    left: BorderSide(
                        color: Console.deck(edge.name).withValues(alpha: onDeck != null ? 1 : 0.6), width: 3)),
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
                    // In FITS the second line is why it is here rather than who it is
                    // by: the artist is the one thing you can already see on the
                    // sleeve, and what you cannot see is what it has in common with
                    // what is playing.
                    Text(!ready
                        ? t.statusLine
                        : widget.note != null && widget.note!.isNotEmpty
                            ? widget.note!
                            : t.artistLine,
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
              // How well it goes, against the best the library had: a list sorted by
              // something invisible is a list you have to take on trust. A bar rather
              // than a figure, because the thing being shown is a comparison and a
              // figure would read as a measurement.
              if (widget.fit != null && !_over)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 26,
                    height: 4,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: widget.fit!.clamp(0.06, 1.0),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: widget.fit! >= 0.9 ? Console.ink : Console.quiet,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (!_over)
                if (loadingOn != null)
                  _Status.loading(loadingOn)
                else if (onDeck != null)
                  _Status.on(onDeck, playing: onDeck.playing)
                else if (isNext)
                  _NextChip(booth: b, colour: Console.deck(b.other(b.master).name))
                else if (widget.queuePos != null && t.origin == 'booth')
                  const _Status.auto(),
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
                _Facts(booth: b, track: t, roomy: widget.roomy, ask: widget.ask),
              ],
              if (widget.roomy && !_over)
                SizedBox(
                  width: 44,
                  child: Text(length,
                      textAlign: TextAlign.right,
                      style: Mag.typewriter(10.5, color: Console.faint)),
                ),
              if (_over || _menuOpen || widget.roomy)
                _Menu(
                  items: _actions(app),
                  onOpen: () => setState(() => _menuOpen = true),
                  onClose: () {
                    if (mounted) setState(() => _menuOpen = false);
                  },
                ),
            ],
          ),
        ),
      ),
    );
    if (!ready) return widget.played ? Opacity(opacity: 0.45, child: row) : row;
    // A record is dragged onto a deck — with a mouse. On a touch screen a plain
    // Draggable takes the gesture the moment a finger moves at all, whichever way it
    // moved, so it beat the list to every swipe and the crate could not be scrolled:
    // every attempt picked a record up instead. A finger has no scroll wheel to fall
    // back on, so there it has to be asked for — held, then dragged, the way a phone
    // asks for anything it is going to pick up.
    final feedback = Material(
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
    );
    final faded = Opacity(opacity: 0.4, child: row);
    final shown = widget.played ? Opacity(opacity: 0.45, child: row) : row;
    return _touchPointer
        ? LongPressDraggable<Track>(
            data: t,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: feedback,
            childWhenDragging: faded,
            child: shown,
          )
        : Draggable<Track>(
            data: t,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: feedback,
            childWhenDragging: faded,
            child: shown,
          );
  }

}

/// What is happening to a record, in a word on its row: LOADING → A while it goes
/// onto a deck, ON A once it is there, AUTO for a record the Auto DJ queued itself.
class _Status extends StatelessWidget {
  const _Status.loading(engine.Deck this.deck)
      : loading = true,
        playing = false;
  const _Status.on(engine.Deck this.deck, {this.playing = false}) : loading = false;
  const _Status.auto()
      : deck = null,
        loading = false,
        playing = false;

  final engine.Deck? deck;
  final bool loading, playing;

  @override
  Widget build(BuildContext context) {
    final d = deck;
    final colour = d == null ? Console.faint : Console.deck(d.name);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: d == null
            ? 'The Auto DJ queued this itself (KEEP GOING) — it goes again if you queue past it'
            : loading
                ? 'Going onto deck ${d.name}'
                : playing
                    ? 'Playing on deck ${d.name}'
                    : 'On deck ${d.name}',
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (loading) ...[
            SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: colour)),
            const SizedBox(width: 5),
          ],
          Text(
              d == null
                  ? 'AUTO'
                  : loading
                      ? 'LOADING → ${d.name}'
                      : playing
                          ? '▶ ${d.name}'
                          : 'ON ${d.name}',
              style: Console.label(8, color: colour)),
        ]),
      ),
    );
  }
}

/// The Auto DJ's next record, and in how long it comes in, counted down.
class _NextChip extends StatelessWidget {
  const _NextChip({required this.booth, required this.colour});
  final Booth booth;
  final Color colour;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ListenableBuilder(
          listenable: BoothClock.of(context).positionOf(booth.master),
          builder: (context, _) {
            final left = booth.auto.timeToGo;
            final ready = booth.auto.isReady;
            final s = left?.inSeconds;
            return Container(
              padding: const EdgeInsets.fromLTRB(5, 2, 5, 1),
              decoration: BoxDecoration(
                color: ready ? colour : null,
                border: Border.all(color: colour),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                !ready
                    ? 'NEXT · GETTING READY'
                    : booth.inTransition || (left?.isNegative ?? false)
                        ? 'COMING IN'
                        : s == null
                            ? 'NEXT'
                            : 'NEXT ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
                style: Console.label(7.5, color: ready ? Console.ground : colour),
              ),
            );
          },
        ),
      );
}

/// Whether a finger is doing the pointing, in which case the list needs the plain
/// vertical drag for scrolling and anything that picks a record up has to be held
/// first. With a mouse there is a wheel to scroll with, so a drag can mean a drag.
bool get _touchPointer =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Tempo and key, lit where they sit with the master.
class _Facts extends StatelessWidget {
  const _Facts({required this.booth, required this.track, this.roomy = false, this.ask = false});
  final Booth booth;
  final Track track;
  final bool roomy;

  /// The record's whole analysis asked for (its marks), not only looked for: see
  /// [_Row.ask].
  final bool ask;

  @override
  Widget build(BuildContext context) {
    // The tempo and key on file first, for the whole crate in one ask; the record's
    // whole analysis (its marks, and the sort by how well it follows) as it comes,
    // two at a time behind whatever a deck is asking for.
    return FutureBuilder<TrackFacts?>(
      future: booth.facts.of(track),
      initialData: booth.facts.peek(track.id),
      builder: (context, facts) => FutureBuilder<TrackTiming?>(
        future: ask ? booth.timing.later(track) : Future.value(booth.timing.peek(track.id)),
        initialData: booth.timing.peek(track.id),
        builder: (context, snap) {
          final tm = snap.data, f = facts.data;
          final bpm = tm?.bpm ?? f?.bpm, camelot = tm?.camelot ?? f?.camelot;
          if (bpm == null && camelot == null && tm == null) return SizedBox(width: roomy ? 76 : 40);
          final shown = booth.master.bpm;
          final tempoOk = bpm != null && shown != null && Booth.syncRatio(bpm, shown) != null;
          final keyOk = camelotNear(camelot, booth.master.timing?.camelot);
          final good = Console.deck(booth.master.name);
          return SizedBox(
            width: roomy ? 116 : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                DataMarks(booth: booth, track: track, timing: tm, size: 5),
                const SizedBox(width: 6),
                if (bpm != null)
                  Text(bpm.toStringAsFixed(0), style: Mag.numerals(14, color: tempoOk ? good : Console.quiet)),
                if (camelot != null) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 28,
                    child: Text(camelot,
                        textAlign: TextAlign.right,
                        style: Mag.typewriter(10.5, color: keyOk ? good : Console.faint, bold: true)),
                  ),
                ],
              ],
            ),
          );
        },
      ),
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
              Icon(Icons.hourglass_empty, size: 12, color: Console.faint),
            PartsStage.ready =>
              Icon(Icons.call_split, size: 13, color: Console.ink),
            PartsStage.failed =>
              Icon(Icons.error_outline, size: 13, color: Console.a),
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
                  Icon(Icons.call_split, size: 28, color: Console.faint),
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
                  ? SizedBox(
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
    // Held before it is picked up, where a finger is doing the pointing: the list
    // needs the plain vertical drag for scrolling. See _Row.
    final feedback = Material(
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
    );
    return _touchPointer
        ? LongPressDraggable<Track>(
            data: t,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: feedback,
            child: row,
          )
        : Draggable<Track>(
            data: t,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: feedback,
            child: row,
          );
  }
}
