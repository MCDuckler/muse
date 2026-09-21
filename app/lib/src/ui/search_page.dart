import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import 'browse_page.dart';
import 'sleeve_art.dart';
import 'mag_parts.dart';
import 'mag.dart';
import 'artwork.dart';
import 'dialogs.dart' show Roomy;
import 'found_row.dart';
import 'library_page.dart' show SmartListPage;
import 'motion.dart';
import 'pane.dart';
import 'selection_bar.dart';
import 'snack.dart';
import 'track_menu.dart';
import 'widths.dart';
import 'skeleton.dart';

/// One search across everything, in one list.
///
/// It used to be four lists one under another — your library, then YouTube Music, then
/// SoundCloud, then Bandcamp — and on a phone the third of those is off the bottom of
/// the screen, which is the same as not being there. The question somebody is actually
/// asking is "where is this song", not "what does SoundCloud have", so the answer is
/// one ranked list where every row is the same shape and a coloured dot says where it
/// came from. Narrowing to one service is still a tap away.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

/// Bumped by anything that means "search now" — the slash key, for one.
///
/// A notifier rather than a flag on the app state: wanting the cursor in the search
/// box is a momentary thing, not a piece of the app's condition, and asking twice in
/// a row has to work, which a boolean cannot do.
final ValueNotifier<int> searchWanted = ValueNotifier<int>(0);

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// The result the arrow keys have got to, on a keyboard. None until one is pressed:
  /// Enter with nothing marked still means "search for this".
  Found? _marked;
  final _results = ScrollController();
  final Map<Found, GlobalKey> _rowKeys = {};

  List<Found> _found = const [];
  Map<String, String> _notes = const {};
  AlbumPreview? _album;
  bool _importing = false;
  bool _busy = false;
  bool _searched = false;
  String? _error;
  String _lastQuery = '';
  Timer? _debounce;

  /// When the last results landed, so only the rows that arrive with them are
  /// animated in. Rows built later — scrolled back into view — used to fade in again
  /// every time they did, which reads as the list blinking.
  DateTime _arrivedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// What was looked for before, newest first. A typo used to mean typing the whole
  /// thing again; and what you looked for last week is a fair guess at what you want.
  List<String> _recent = const [];
  static const _kRecent = 'muse.recentSearches';
  static const _keepRecent = 12;

  /// Which service the list is narrowed to, or 'all'.
  String _where = 'all';

  /// Songs, records, artists — or all three.
  String _kind = 'all';

  /// Asking the other question: not what is this called, but what are the words.
  bool _lyrics = false;

  static const _places = <String, String>{
    'all': 'Everywhere',
    'library': 'Library',
    'ytmusic': 'YouTube Music',
    'youtube': 'YouTube',
    'spotify': 'Spotify',
    'soundcloud': 'SoundCloud',
    'bandcamp': 'Bandcamp',
  };

  static const _kinds = <String, String>{
    'all': 'All',
    'song': 'Songs',
    // Ordinary YouTube videos, kept as their sound: the live set, the bootleg, the
    // thing that was never released anywhere a music service would carry it.
    'video': 'Videos',
    'album': 'Records',
    'artist': 'Artists',
  };

  /// Long enough not to fire on every keystroke, short enough that the results feel
  /// like they are following you. Four services are behind it, so this is also what
  /// keeps them from being hammered.
  static const _debounceDelay = Duration(milliseconds: 350);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
    // On the field's own node: the keys have to be heard before the text field's own
    // shortcuts take up and down to mean "start and end of the line".
    _focus.onKeyEvent = _keys;
    searchWanted.addListener(_wanted);
    unawaited(_loadRecent());
  }

  /// Somebody pressed the slash key. Take the cursor, and select what is already
  /// there so the next thing typed replaces the last search rather than extending it.
  void _wanted() {
    if (!mounted) return;
    _focus.requestFocus();
    _controller.selection =
        TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _recent = prefs.getStringList(_kRecent) ?? const []);
  }

  Future<void> _remember(String q) async {
    final next = [q, ..._recent.where((r) => r.toLowerCase() != q.toLowerCase())]
        .take(_keepRecent)
        .toList();
    if (mounted) setState(() => _recent = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kRecent, next);
  }

  Future<void> _forget(String q) async {
    final next = [..._recent]..remove(q);
    setState(() => _recent = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kRecent, next);
  }

  /// The results in the order they are on the page: the top one, then each kind's in
  /// the order the kinds turned up.
  List<Found> get _inPageOrder {
    if (_found.isEmpty) return const [];
    final rest = _found.skip(1).toList();
    final kinds = <String>[];
    for (final f in rest) {
      if (!kinds.contains(f.kind)) kinds.add(f.kind);
    }
    return [
      _found.first,
      for (final kind in kinds)
        for (final f in rest)
          if (f.kind == kind) f,
    ];
  }

  /// The keyboard, for somebody at a desk: down and up walk the results, Enter plays
  /// or opens the one marked, Shift-Enter puts it on the queue instead, Escape lets go.
  KeyEventResult _keys(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _album != null) return KeyEventResult.ignored;
    final rows = _inPageOrder;
    if (rows.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final at = _marked == null ? -1 : rows.indexOf(_marked!);

    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      final to = key == LogicalKeyboardKey.arrowDown
          ? (at + 1).clamp(0, rows.length - 1)
          : at - 1;
      // Up from the first one is back to the field, with nothing marked.
      setState(() => _marked = to < 0 ? null : rows[to]);
      if (to >= 0) _bringIntoView(rows[to], to, rows.length);
      return KeyEventResult.handled;
    }
    if (_marked == null || at < 0) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _marked = null);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      final queue = HardwareKeyboard.instance.isShiftPressed && _marked!.plays;
      unawaited(_open(_marked!, mode: queue ? 'end' : null));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _bringIntoView(Found f, int index, int of) {
    void show() {
      final there = _rowKeys[f]?.currentContext;
      if (there == null) return;
      Scrollable.ensureVisible(there,
          alignment: 0.5,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
          duration: const Duration(milliseconds: 120));
    }

    if (_rowKeys[f]?.currentContext != null) return show();
    // Not built: the list only makes the rows near the screen. Go to roughly where it
    // is, and settle on it once it exists.
    if (!_results.hasClients) return;
    final p = _results.position;
    _results.jumpTo((p.maxScrollExtent * index / of).clamp(0.0, p.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) => show());
  }

  void _searchAgainFor(String q) {
    _controller.text = q;
    _controller.selection = TextSelection.collapsed(offset: q.length);
    _run(q);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    searchWanted.removeListener(_wanted);
    _controller.dispose();
    _results.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTyped() {
    setState(() {});                       // the clear button appears and disappears
    _debounce?.cancel();
    final q = _controller.text.trim();
    if (q.isEmpty) {
      setState(() {
        _found = const [];
        _notes = const {};
        _album = null;
        _searched = false;
      });
      return;
    }
    if (q == _lastQuery) return;
    _debounce = Timer(_debounceDelay, () => _run(q));
  }

  Future<void> _run([String? query]) async {
    final q = (query ?? _controller.text).trim();
    if (q.isEmpty) return;
    _debounce?.cancel();
    _lastQuery = q;
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<AppState>().api;
    try {
      // A pasted album link is not a search: the page knows what is on the record, so
      // ask it rather than guessing from the words in the URL.
      if (q.startsWith('http') && q.contains('bandcamp.com')) {
        final preview = await api.previewAlbum(q);
        if (!mounted || _lastQuery != q) return;
        setState(() {
          _album = preview;
          _found = const [];
          _searched = true;
        });
        return;
      }

      final res = await api.searchEverything(
        q,
        where: _where,
        kind: _lyrics ? 'song' : _kind,
        lyrics: _lyrics,
        limit: _where == 'all' ? 40 : 50,
      );
      if (!mounted || _lastQuery != q) return;   // a newer query already went out
      setState(() {
        _album = null;
        _found = res.items;
        _marked = null;
        _rowKeys.clear();
        _notes = res.notes;
        _searched = true;
        _arrivedAt = DateTime.now();
      });

    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _look(String where) {
    if (where == _where) return;
    setState(() => _where = where);
    _again();
  }

  void _again() {
    if (_lastQuery.isEmpty) return;
    final q = _lastQuery;
    _lastQuery = '';
    _run(q);
  }

  /// Tapping a row. What that means is the one thing that differs between them: an
  /// artist or a record opens, and anything that plays is played.
  ///
  /// It used to go on the end of the queue, and hearing it meant catching the "Play"
  /// on the toast before it went away. Somebody who searches for a song and taps it
  /// wants to hear it; the plus on the row is for the other thing. With [mode] it is
  /// that other thing: 'end' or 'next', on the queue and nothing else touched.
  Future<void> _open(Found found, {String? mode}) async {
    if (_lastQuery.isNotEmpty) unawaited(_remember(_lastQuery));
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    if (found.kind == 'artist') {
      // Every artist row opens the artist, wherever the row came from.
      //
      // A row from YouTube Music or Spotify used to retype the search and run it
      // again, which from the other side of the screen is a row that does nothing:
      // the same list comes back with the same artist row at the top of it. The
      // artist page is keyed by name and finds their records for itself, so it works
      // just as well for somebody with nothing of theirs in the library yet.
      navigator.push(MaterialPageRoute(
          builder: (_) => ArtistPage(
              artist: ArtistSummary(
                  name: found.title,
                  tracks: found.place == 'library' ? found.tracks ?? 0 : 0))));
      return;
    }

    if (found.kind == 'album') {
      if (found.place == 'library') {
        navigator.push(MaterialPageRoute(
            builder: (_) => AlbumPage(
                album: AlbumSummary(
                    name: found.title,
                    artist: found.subtitle,
                    tracks: found.tracks ?? 0))));
        return;
      }
      await showFoundAlbum(context, found);
      return;
    }

    // A song or a video: either it is here, or it is fetched.
    try {
      if (mode != null) {
        if (found.track != null) {
          await addAndSay(context, found.track!, mode: mode);
          return;
        }
        final track = await app.api.addFound(found);
        await app.addTrack(track, mode: mode);
        if (mounted) saidAdded(context, found);
        return;
      }
      final track = found.track ?? await app.api.addFound(found);
      await app.playTrackNow(track);
      // Something already here simply starts, and the player says so better than a
      // toast would. Something being fetched does not start yet, so that is said.
      if (mounted && !track.isReady) {
        messenger.say(snack(Text(
            'Fetching "${found.title}" from ${placeNames[found.place] ?? found.place}'
            ' — it plays as soon as it is here')));
      }
    } catch (e) {
      // Long enough to read, because this is where the server says it declined to
      // add a song and why — which is a sentence, not a word.
      messenger.say(problem(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    // The rows of chips are a fixed height, because a horizontal list has to be told
    // how tall to be. Forty points was right for the type as designed; with the phone's
    // text made large the chips grew and the row did not, and the bottom half of every
    // label was cut off — four hundred and fifty points of it at twice the size.
    final chipRow = 40 * (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.2);
    final libraryTracks = [
      for (final f in _found)
        if (f.place == 'library' && f.track != null) f.track!,
    ];
    final asking = _controller.text.trim().isNotEmpty ||
        _where != 'all' ||
        _kind != 'all' ||
        _lyrics;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.search,
                  // Remembered when it is meant — sent with the search key, or one of
                  // its results used — rather than on every pause while typing, which
                  // filled the list with "b", "be" and "bea".
                  onSubmitted: (_) {
                    final q = _controller.text.trim();
                    if (q.isNotEmpty) unawaited(_remember(q));
                    _run();
                  },
                  focusNode: _focus,
                  decoration: InputDecoration(
                    hintText: _lyrics
                        ? 'Some of the words'
                        : 'Search, or paste a link',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _busy
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)))
                        : (_controller.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: 'Clear',
                                onPressed: () {
                                  _controller.clear();
                                  _focus.requestFocus();
                                },
                              )),
                  ),
                ),
              ),
              // Where to look. Six chips in a row of their own said this before anything
              // had been typed, and nearly always said "Everywhere"; it is one button
              // now, and when it is set to something it says so in the row below, where
              // it can be taken off again.
              PopupMenuButton<String>(
                tooltip: 'Where to look',
                icon: Badge(
                  isLabelVisible: _where != 'all',
                  smallSize: 8,
                  child: const Icon(Icons.travel_explore),
                ),
                onSelected: _look,
                itemBuilder: (context) => [
                  for (final entry in _places.entries)
                    PopupMenuItem(
                      value: entry.key,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            child: entry.key == 'all'
                                ? null
                                : Center(child: PlaceDot(entry.key, size: 8)),
                          ),
                          Expanded(child: Text(entry.value)),
                          if (_where == entry.key)
                            const Icon(Icons.check, size: 18),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        // What to look for: one row, and only once there is a question to narrow.
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !asking
              ? const SizedBox(width: double.infinity)
              : SizedBox(
                  height: chipRow,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    children: [
                      if (_where != 'all')
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InputChip(
                            avatar: PlaceDot(_where, size: 8),
                            label: Text(_places[_where] ?? _where),
                            deleteButtonTooltipMessage: 'Look everywhere',
                            onDeleted: () => _look('all'),
                            onPressed: () => _look('all'),
                          ),
                        ),
                      // The other question: the words rather than the name. Songs
                      // only — a record has no lyrics. First in the row, because last
                      // in the row is off the side of a phone.
                      Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            avatar: const Icon(Icons.format_quote, size: 16),
                            label: const Text('Lyrics'),
                            visualDensity: VisualDensity.compact,
                            selected: _lyrics,
                            onSelected: (on) {
                              setState(() => _lyrics = on);
                              _again();
                            },
                          )),
                      if (!_lyrics)
                        // No chip for "all": that is what none of them means, and
                        // a second tap on the one that is on takes it off. One chip
                        // fewer is the difference between a row that fits a phone
                        // and one that runs off the side of it.
                        for (final entry in _kinds.entries)
                          if (entry.key != 'all')
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(entry.value),
                                visualDensity: VisualDensity.compact,
                                selected: _kind == entry.key,
                                onSelected: (on) {
                                  setState(() => _kind = on ? entry.key : 'all');
                                  _again();
                                },
                              ),
                            ),
                    ],
                  ),
                ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        // One service being unreachable is not a failed search, and it is not silence
        // either: the difference between "nothing there" and "nobody answered" is the
        // difference between trying another spelling and trying again in a minute.
        for (final note in _notes.entries)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              children: [
                PlaceDot(note.key, size: 8),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(note.value,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline)),
                ),
              ],
            ),
          ),
        Expanded(
          child: SelectionOver(
            bar: SelectionBar(where: 'search', tracks: libraryTracks),
            child: _album != null
                ? ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 160),
                    children: _albumRows(context.read<AppState>()),
                  )
                : _searched && !_busy && _found.isEmpty
                    ? _NothingFound(query: _lastQuery, lyrics: _lyrics)
                    : !_searched && !_busy
                        ? _SearchPrompt(
                            recent: _recent,
                            onPick: _searchAgainFor,
                            onForget: _forget,
                          )
                        // Asked and not answered yet, with nothing from before to
                        // show in the meantime. The index begins with its first
                        // result, and with no results there is no first — which threw,
                        // and for as long as four services took to answer the page was
                        // the blank that a widget which could not be built turns into.
                        : _found.isEmpty
                            ? const SongsComing()
                            : _index(context.read<AppState>()),
          ),
        ),
      ],
    );
  }

  /// The results, set as a magazine's index: the best match on a card of its own,
  /// then the rest under a head for each kind — songs, records, artists — in the order
  /// each kind first turned up, so the kind that matched best still comes first.
  Widget _index(AppState app) {
    final top = _found.first;
    final rest = _found.skip(1).toList();
    final order = <String>[];
    for (final f in rest) {
      if (!order.contains(f.kind)) order.add(f.kind);
    }
    final rows = <Widget>[];
    var n = 0;
    final animate =
        DateTime.now().difference(_arrivedAt) < const Duration(milliseconds: 900);
    Widget arriving(Found f, Widget child) => _Arriving(
          // Keyed on the query as well as the row, so a new search arrives again
          // rather than the old rows silently becoming different songs.
          key: ValueKey('$_lastQuery/${f.place}/${f.id}/${f.kind}'),
          index: n++,
          // Only rows built as the results land: a row scrolled back into view a
          // minute later is not arriving.
          animate: animate,
          child: _Marked(
            key: _rowKeys.putIfAbsent(f, GlobalKey.new),
            on: identical(f, _marked),
            child: child,
          ),
        );

    rows.add(arriving(
      top,
      _TopResult(
        found: top,
        onTap: () => _open(top),
        onAdd: top.plays ? () => _open(top, mode: 'end') : null,
      ),
    ));
    for (final kind in order) {
      final group = [for (final f in rest) if (f.kind == kind) f];
      rows.add(_IndexHead(switch (kind) {
        'song' => 'Songs',
        'video' => 'Videos',
        'album' => 'Records',
        'artist' => 'Artists',
        _ => kind,
      }));
      for (final f in group) {
        rows.add(arriving(
          f,
          FoundRow(
            found: f,
            onTap: () => _open(f),
            onAdd: () => _open(f, mode: 'end'),
            onPlayNext: () => _open(f, mode: 'next'),
          ),
        ));
      }
    }
    return ListView.builder(
      controller: _results,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 160),
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i],
    );
  }

  /// A pasted album link: the whole record, in order, as the artist typed it.
  List<Widget> _albumRows(AppState app) {
    final album = _album!;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text('${album.artist ?? 'Album'} · ${album.album ?? ''}',
            style: Theme.of(context).textTheme.titleSmall),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                [
                  '${album.tracks.length} tracks',
                  if (album.unavailable > 0) '${album.unavailable} sold only',
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            FilledButton.icon(
              icon: _importing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download, size: 18),
              label: const Text('Add the album'),
              onPressed: _importing ? null : () => _importAlbum(app),
            ),
          ],
        ),
      ),
      for (final t in album.tracks)
        ListTile(
          dense: true,
          leading: const Icon(Icons.music_note, size: 20),
          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(t.lengthLine),
          trailing:
              t.known ? const Icon(Icons.check_circle_outline, size: 18) : null,
        ),
    ];
  }

  Future<void> _importAlbum(AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _importing = true);
    try {
      final r = await app.api.importAlbum(_lastQuery);
      await app.refreshPlaylists();
      messenger.say(
          snack(Text('Added "${r['name']}" — ${r['added']} tracks')));
    } catch (e) {
      messenger.say(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }
}

/// A row that arrives a beat after the one above it.
///
/// Results appearing all at once is a screen that blinks; a short stagger reads as a
/// list being laid down, and it gives the eye somewhere to start. Capped, because
/// nobody should wait a second and a half for the fortieth row, and skipped entirely
/// where the phone has asked for stillness.
class _Arriving extends StatelessWidget {
  const _Arriving(
      {super.key, required this.index, required this.child, this.animate = true});
  final int index;
  final Widget child;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    if (!animate || stillness(context)) return child;
    final wait = Duration(milliseconds: 18 * (index.clamp(0, 10)));
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.base + wait,
      curve: Interval(
        wait.inMilliseconds / (Motion.base.inMilliseconds + wait.inMilliseconds),
        1,
        curve: Motion.enter,
      ),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child),
      ),
      child: child,
    );
  }
}

/// What is on a record found somewhere else, and a way to take it.
Future<void> showFoundAlbum(BuildContext context, Found found) async {
  final app = context.read<AppState>();
  // The one sheet that is a sheet on purpose: a record's tracks are a list somebody
  // drags up to see more of. In a dialog there is nothing to drag, so it gets a plain
  // scroll of its own and the dialog's height.
  await ask<void>(
    context,
    scrollable: true,
    builder: (context) => Width.of(context) == Width.compact
        ? DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.7,
            maxChildSize: 0.95,
            builder: (context, scroll) => _FoundAlbumSheet(
                found: found, app: app, controller: scroll),
          )
        : _FoundAlbumSheet(
            found: found, app: app, controller: ScrollController()),
  );
}

class _FoundAlbumSheet extends StatefulWidget {
  const _FoundAlbumSheet(
      {required this.found, required this.app, required this.controller});
  final Found found;
  final AppState app;
  final ScrollController controller;

  @override
  State<_FoundAlbumSheet> createState() => _FoundAlbumSheetState();
}

class _FoundAlbumSheetState extends State<_FoundAlbumSheet> {
  FoundAlbum? _album;
  String? _error;
  bool _taking = false;

  @override
  void initState() {
    super.initState();
    widget.app.api
        .foundAlbum(widget.found.place, widget.found.id)
        .then((a) => mounted ? setState(() => _album = a) : null)
        .catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  /// The whole record, in order. One request each, because each one is a download
  /// somewhere else and the server queues them as they arrive.
  Future<void> _takeAll() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _taking = true);
    var added = 0;
    try {
      for (final t in _album!.tracks) {
        try {
          await widget.app.api.addFound(t);
          added++;
        } catch (_) {
          // One song of a record being unavailable is not a failed record.
        }
      }
      messenger.say(snack(
          Text('Added $added of ${_album!.tracks.length} from "${_album!.title}"')));
    } finally {
      if (mounted) setState(() => _taking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    if (_error != null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    if (album == null) {
      return const SongsComing();
    }
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      children: [
        ListTile(
          leading: PlaceDot(widget.found.place, size: 12),
          title: Text(album.title,
              style: Theme.of(context).textTheme.titleMedium),
          subtitle: Text([
            album.artist ?? '',
            if (album.year != null) album.year!,
            '${album.tracks.length} songs',
          ].where((s) => s.isNotEmpty).join(' · ')),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: FilledButton.icon(
            icon: _taking
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download, size: 18),
            label: const Text('Add the record'),
            onPressed: _taking ? null : _takeAll,
          ),
        ),
        for (final t in album.tracks)
          FoundRow(
            found: t,
            onTap: () async {
              try {
                final track = await widget.app.api.addFound(t);
                await widget.app.addTrack(track);
                if (context.mounted) saidAdded(context, t);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .say(snack(Text('$e')));
                }
              }
            },
          ),
      ],
    );
  }
}

/// The empty search: what was looked for before, and — the first time — what this
/// box can do.
class _SearchPrompt extends StatefulWidget {
  const _SearchPrompt(
      {required this.recent, required this.onPick, required this.onForget});
  final List<String> recent;
  final void Function(String) onPick;
  final void Function(String) onForget;

  @override
  State<_SearchPrompt> createState() => _SearchPromptState();
}

/// The page before anything has been typed: somewhere to start from.
///
/// It used to be a paragraph explaining what a search box is. Half the time somebody
/// opens this tab they do not have a name in mind — they want something to put on —
/// and the library already knows several answers to that which nobody had to file
/// anything under: what has never been played, what was added this month, what came
/// out in the nineties.
class _SearchPromptState extends State<_SearchPrompt> {
  /// Kept between visits to the tab, so the page is not rebuilt from nothing each
  /// time it is come back to; asked for again anyway, because plays change it.
  static List<({String id, String name, String blurb, int count})> _lists = const [];
  static List<({String id, String name, String short, String blurb, int count})>
      _decades = const [];

  @override
  void initState() {
    super.initState();
    _ask();
  }

  Future<void> _ask() async {
    try {
      final got = await context.read<AppState>().api.smartShelves();
      if (!mounted) return;
      setState(() {
        _lists = [for (final l in got.lists) if (l.count > 0) l];
        _decades = got.decades;
      });
    } catch (_) {
      // No connection, or a server from before these existed: the page is the recent
      // searches and nothing else, which is what it always was.
    }
  }

  Future<void> _open(String id, String name, String blurb) async {
    await openPage(context, (_) => SmartListPage(id: id, name: name, blurb: blurb));
    if (mounted) unawaited(_ask());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recent = widget.recent;
    final quiet = Mag.typewriter(11, color: scheme.onSurfaceVariant);

    if (recent.isEmpty && _lists.isEmpty && _decades.isEmpty) {
      final style =
          Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.outline);
      return Roomy(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search, size: 40),
            const SizedBox(height: 12),
            Text(
              'Songs, records, artists and videos, from your library and from every '
              'service this server can reach — in one list. Tap to play, + to queue.',
              textAlign: TextAlign.center,
              style: style,
            ),
            const SizedBox(height: 10),
            Text(
              'Or paste a YouTube or Bandcamp link. Or turn on Lyrics and type some '
              'of the words.',
              textAlign: TextAlign.center,
              style: style,
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(builder: (context, box) {
      // Two cards to a row on a phone, more where there is the room for them.
      final across = (box.maxWidth / 230).floor().clamp(2, 4);
      final gap = 8.0;
      final card = (box.maxWidth - 32 - gap * (across - 1)) / across;
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 160),
        children: [
          if (recent.isNotEmpty) ...[
            const _IndexHead('Recent', flush: true),
            const SizedBox(height: 6),
            // Chips rather than a row each: they are a few words, there are a dozen
            // of them, and as a list they pushed everything else off the page.
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                for (final q in recent)
                  InputChip(
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Text(q, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => widget.onPick(q),
                    deleteButtonTooltipMessage: 'Forget',
                    onDeleted: () => widget.onForget(q),
                  ),
              ],
            ),
          ],
          if (_lists.isNotEmpty) ...[
            const _IndexHead('Or start from', flush: true),
            const SizedBox(height: 8),
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final l in _lists)
                  _BrowseCard(
                    width: card,
                    name: l.name,
                    blurb: l.blurb,
                    count: l.count,
                    onTap: () => _open(l.id, l.name, l.blurb),
                  ),
              ],
            ),
          ],
          if (_decades.isNotEmpty) ...[
            const _IndexHead('By decade', flush: true),
            const SizedBox(height: 8),
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final d in _decades)
                  _DecadeTile(
                    short: d.short,
                    count: d.count,
                    label: d.name,
                    onTap: () => _open(d.id, d.name, d.blurb),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 22),
          Text('A pasted YouTube or Bandcamp link works too. Lyrics looks for the words.',
              style: quiet),
        ],
      );
    });
  }
}

/// One way into the library: what it is called, what it is, how much is in it.
class _BrowseCard extends StatelessWidget {
  const _BrowseCard({
    required this.width,
    required this.name,
    required this.blurb,
    required this.count,
    required this.onTap,
  });

  final double width;
  final String name;
  final String blurb;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Material(
        color: scheme.surfaceContainerHighest,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
                border: Border(top: BorderSide(color: scheme.onSurface, width: 2))),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$count', style: Mag.numerals(26, color: scheme.primary)),
                const SizedBox(height: 2),
                Text(name.toUpperCase(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.headline(18, color: scheme.onSurface)),
                const SizedBox(height: 3),
                Text(blurb,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A decade, the way a magazine would flag one: two figures and an s.
class _DecadeTile extends StatelessWidget {
  const _DecadeTile(
      {required this.short, required this.count, required this.label, required this.onTap});

  final String short;
  final int count;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$label, $count songs',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 76),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            decoration: BoxDecoration(border: Border.all(color: scheme.onSurface)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(short.toUpperCase(), style: Mag.headline(30, color: scheme.onSurface)),
                Text('$count', style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NothingFound extends StatelessWidget {
  const _NothingFound({required this.query, required this.lyrics});
  final String query;
  final bool lyrics;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            lyrics
                ? 'Nothing with those words in it. Try a longer line, or one from '
                    'the chorus.'
                : 'Nothing for "$query" anywhere.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );
}

/// The row the arrow keys are on: a rule down its left edge in the accent, and the
/// faintest tint, over the row so that marking it does not move what is in it.
class _Marked extends StatelessWidget {
  const _Marked({super.key, required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Painted over the row rather than put behind it as a decoration: a row's own ink
    // is drawn on the Material underneath, and a coloured box in between hides it.
    return CustomPaint(
      foregroundPainter: on ? _MarkPainter(scheme.primary) : null,
      child: child,
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.colour);
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colour.withValues(alpha: 0.07));
    canvas.drawRect(Rect.fromLTWH(0, 0, 3, size.height), Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.colour != colour;
}

/// The best match, on a card of its own at the top of the index.
class _TopResult extends StatelessWidget {
  const _TopResult({required this.found, required this.onTap, this.onAdd});

  final Found found;
  final VoidCallback onTap;

  /// On to the queue instead of played. Only for something that plays.
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final f = found;
    final Widget art;
    if (f.track != null) {
      art = Artwork(track: f.track, size: 72, radius: 0, small: true);
    } else {
      final url = f.coverUrl == null
          ? null
          : app.api.remoteCoverUrl(
              f.coverUrl!.contains('?') ? f.coverUrl! : '${f.coverUrl!}?size=sm');
      art = url == null
          ? PrintedSleeve(
              seed: PrintedSleeve.seedOf('${f.title}·${f.subtitle}'), title: f.title, size: 72)
          : Artwork(url: url, size: 72, radius: 0);
    }
    final what = switch (f.kind) {
      'album' => 'Record',
      'artist' => 'Artist',
      'video' => 'Video',
      _ => 'Song',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Material(
        color: scheme.surfaceContainerHighest,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                CutOut(turn: -0.03, child: art),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Kicker('Top result · $what'),
                      const SizedBox(height: 3),
                      Text(f.title.toUpperCase(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Mag.headline(24, color: scheme.onSurface)),
                      if (f.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(f.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Mag.typewriter(11.5, color: scheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ),
                if (onAdd == null)
                  PlaceDot(f.place, size: 8)
                else
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PlaceDot(f.place, size: 8),
                      IconButton(
                        icon: Icon(f.known
                            ? Icons.playlist_add_check
                            : Icons.add_circle_outline),
                        tooltip: 'Add to the queue',
                        onPressed: onAdd,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A head in the index: the kind, in spaced red capitals over a rule.
class _IndexHead extends StatelessWidget {
  const _IndexHead(this.text, {this.flush = false});

  final String text;

  /// On a page that already has its own margins.
  final bool flush;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      header: true,
      child: Container(
        margin: flush
            ? const EdgeInsets.only(top: 18, bottom: 2)
            : const EdgeInsets.fromLTRB(16, 16, 16, 2),
        padding: const EdgeInsets.only(bottom: 3),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.onSurface))),
        child: Text(text.toUpperCase(), style: Mag.flag(10.5, color: scheme.primary)),
      ),
    );
  }
}
