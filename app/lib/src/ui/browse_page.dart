import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/art_cache.dart';
import '../state/offline.dart';
import '../state/paged.dart';
import '../state/selection.dart';
import 'artwork.dart';
import 'selection_bar.dart';
import 'skeleton.dart';
import 'song_row.dart';
import 'station.dart';
import 'source_dot.dart';
import 'swipe.dart';
import 'dialogs.dart';
import 'glass.dart' show parseHexColour;
import 'mag.dart';
import 'mag_parts.dart';
import 'sleeve_art.dart';
import 'mini_player.dart';
import 'theme.dart';
import 'track_list.dart';
import 'track_menu.dart';
import 'widths.dart';
import 'snack.dart';

/// Getting the audio for everything here.
///
/// Most of this library has never been downloaded: a mirrored collection records the
/// list and leaves the files until something is played, which is right until the
/// moment somebody is about to get on a train. A playlist could already ask for all of
/// it; a record and an artist could not, and doing it by hand meant playing every song
/// for a second each.
class _TakeItWithYou extends StatefulWidget {
  const _TakeItWithYou({this.album, this.artist});
  final String? album;
  final String? artist;

  @override
  State<_TakeItWithYou> createState() => _TakeItWithYouState();
}

class _TakeItWithYouState extends State<_TakeItWithYou> {
  bool _asking = false;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: _asking
          ? const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.download_outlined),
      tooltip: widget.album == null
          ? 'Get everything by this artist'
          : 'Get this record',
      onPressed: _asking ? null : _ask,
    );
  }

  Future<void> _ask() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _asking = true);
    try {
      final got = await app.api
          .fetchAudio(album: widget.album, artist: widget.artist);
      messenger.say(snack(Text(switch (got.queued) {
        0 when got.alreadyHere > 0 => 'All of it is already here',
        0 => 'Nothing here can be fetched',
        // The size is the part somebody about to leave the house needs: a thousand
        // songs is four gigabytes.
        _ => '${got.queued} on the way · about ${got.aboutMb} MB'
            '${got.unfetchable == 0 ? '' : ' · ${got.unfetchable} cannot be fetched'}',
      })));
    } catch (e) {
      messenger.say(problem(e));
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }
}

/// Narrowing a list that is thousands long, and saying what order it is in.
///
/// Ten thousand records and nine thousand artists cannot be scrolled through, and a
/// list that can only be scrolled is a list where finding something means knowing
/// roughly where the alphabet puts it. Typing is asked of the server rather than
/// filtered here, because what is on this device is one page of the list.
class _FilterBar extends StatefulWidget implements PreferredSizeWidget {
  const _FilterBar({
    required this.hint,
    required this.sorts,
    required this.sort,
    required this.onSearch,
    required this.onSort,
  });

  final String hint;
  final Map<String, String> sorts;
  final String sort;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onSort;

  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  State<_FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<_FilterBar> {
  final _text = TextEditingController();
  Timer? _typing;

  @override
  void dispose() {
    _typing?.cancel();
    _text.dispose();
    super.dispose();
  }

  /// A quarter of a second after the last keystroke: a request per letter would be
  /// eight requests for a name somebody is halfway through typing.
  void _changed(String value) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 250), () => widget.onSearch(value));
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 6, 8),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 44,
                child: TextField(
                  controller: _text,
                  onChanged: _changed,
                  textInputAction: TextInputAction.search,
                  onSubmitted: widget.onSearch,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    hintText: widget.hint,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _text.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: 'Clear',
                            onPressed: () {
                              _text.clear();
                              widget.onSearch('');
                              setState(() {});
                            },
                          ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort),
              tooltip: 'Sort',
              initialValue: widget.sort,
              onSelected: widget.onSort,
              itemBuilder: (context) => [
                for (final e in widget.sorts.entries)
                  PopupMenuItem(value: e.key, child: Text(e.value)),
              ],
            ),
          ],
        ),
      );
}

/// All tracks, albums and artists — built from metadata the enrichment pipeline
/// already writes and nothing used to read.
class AllTracksPage extends StatefulWidget {
  const AllTracksPage({super.key});

  @override
  State<AllTracksPage> createState() => _AllTracksPageState();
}

class _AllTracksPageState extends State<AllTracksPage> {
  static const _sorts = {
    'added': 'Recently added',
    'title': 'Title',
    'artist': 'Artist',
    'album': 'Album',
    'duration': 'Longest',
  };

  String _sort = 'added';

  /// Whether to show only the songs whose audio is actually here.
  ///
  /// Most of this library has never been downloaded — a mirror records the list and
  /// leaves the files until something is played — so "everything" is mostly things
  /// that need a working connection and a minute. On a train that is the wrong list.
  bool _playable = false;

  late Paged<Track> _tracks = _pager();

  Paged<Track> _pager() {
    final api = context.read<AppState>().api;
    final sort = _sort;
    final ready = _playable;
    return Paged<Track>(
      fetch: (offset, limit) => api.libraryTracks(
          sort: sort, offset: offset, limit: limit, readyOnly: ready),
    )..next();
  }

  @override
  void dispose() {
    _tracks.dispose();
    super.dispose();
  }

  /// A different sort is a different list, so it starts again from the top.
  void _load() => setState(() {
        _tracks.dispose();
        _tracks = _pager();
      });

  @override
  Widget build(BuildContext context) {
    return PlayerScaffold(
      appBar: AppBar(
        title: const Text('All tracks'),
        actions: [
          IconButton(
            icon: Icon(_playable ? Icons.offline_pin : Icons.offline_pin_outlined),
            tooltip: _playable
                ? 'Showing only what can play now'
                : 'Only what can play now',
            onPressed: () {
              _playable = !_playable;
              _load();
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (v) {
              _sort = v;
              _load();
            },
            itemBuilder: (context) => [
              for (final e in _sorts.entries)
                PopupMenuItem(value: e.key, child: Text(e.value)),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _tracks,
        builder: (context, _) {
          if (_tracks.error != null && _tracks.items.isEmpty) {
            return ErrorRetry(error: _tracks.error!, onRetry: _load);
          }
          if (_tracks.items.isEmpty && _tracks.loading) {
            // The shape of the list, rather than a spinner in front of a blank page.
            return const SongsComing(rows: 9);
          }
          return RefreshIndicator(
            onRefresh: _tracks.reload,
            child: TrackList(
              tracks: _tracks.items,
              selectable: 'library',
              named: 'All tracks',
              header: _playable
                  ? '${_tracks.total} ready to play · '
                      '${_sorts[_sort]!.toLowerCase()}'
                  : '${_tracks.total} in your library · '
                      '${_sorts[_sort]!.toLowerCase()}',
              onEndReached: _tracks.next,
              loadingMore: _tracks.loading,
            ),
          );
        },
      ),
    );
  }
}

class AlbumsPage extends StatefulWidget {
  const AlbumsPage({super.key});

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  static const _sorts = {
    'name': 'Album name',
    'artist': 'Artist',
    'year': 'Newest first',
    'tracks': 'Most tracks',
    'added': 'Recently added',
  };

  String _q = '';
  String _sort = 'name';
  late Paged<AlbumSummary> _albums = _pager();

  Paged<AlbumSummary> _pager() {
    final api = context.read<AppState>().api;
    final q = _q, sort = _sort;
    return Paged<AlbumSummary>(
      fetch: (offset, limit) =>
          api.albums(offset: offset, limit: limit, q: q, sort: sort),
    )..next();
  }

  /// A different search or a different order is a different list, so it starts again
  /// from the top rather than appending to what was on screen.
  void _again() => setState(() {
        _albums.dispose();
        _albums = _pager();
      });

  @override
  void dispose() {
    _albums.dispose();
    super.dispose();
  }

  void _load() => _albums.reload();

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final wide = Width.of(context) == Width.expanded;
    return PlayerScaffold(
      // Records are the one page that wants the whole desk: they are tiles, and more
      // of them across is the point of a wider screen.
      measure: 1600,
      appBar: AppBar(
        // How many there are, because "Albums" over a list that stops somewhere
        // says nothing about what you are looking at — and with a search in it, it
        // is the answer to what you typed.
        title: ListenableBuilder(
          listenable: _albums,
          builder: (context, _) => Text(
              _albums.total > 0 ? 'Albums · ${_albums.total}' : 'Albums'),
        ),
        bottom: _FilterBar(
          hint: 'Find a record or an artist',
          sorts: _sorts,
          sort: _sort,
          onSearch: (v) {
            if (v.trim() == _q) return;
            _q = v.trim();
            _again();
          },
          onSort: (v) {
            if (v == _sort) return;
            _sort = v;
            _again();
          },
        ),
      ),
      body: ListenableBuilder(
        listenable: _albums,
        builder: (context, _) {
          if (_albums.error != null && _albums.items.isEmpty) {
            return ErrorRetry(error: _albums.error!, onRetry: _load);
          }
          if (_albums.items.isEmpty && _albums.loading) {
            return RecordsComing(
                extent: Width.of(context) == Width.expanded ? 230 : 190);
          }
          final albums = _albums.items;
          if (albums.isEmpty) {
            return EmptyHint(
              icon: Icons.album_outlined,
              title: _q.isEmpty ? 'No albums yet' : 'Nothing called that',
              body: _q.isEmpty
                  ? 'Albums appear as tracks get their metadata.'
                  : 'No record or artist here matches “$_q”.',
            );
          }
          return RefreshIndicator(
            onRefresh: _albums.reload,
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 900) _albums.next();
                return false;
              },
              child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 160),
              physics: const AlwaysScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                // Bigger tiles and more air between them where there is room: phone
                // sizes on a desk are a page of postage stamps.
                maxCrossAxisExtent: wide ? 230 : 190,
                childAspectRatio: 0.74,
                crossAxisSpacing: wide ? 18 : 12,
                mainAxisSpacing: wide ? 22 : 16,
              ),
              itemCount: albums.length,
              itemBuilder: (context, i) {
                final a = albums[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AlbumPage(album: a),
                  )),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LayoutBuilder(
                        builder: (context, c) => Artwork(
                          url: app.api.coverUrlForPath(a.coverPath, small: false),
                          size: c.maxWidth,
                          radius: 10,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(a.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall),
                      Text(a.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                );
              },
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A record, not the part of one we happen to hold.
///
/// The library used to be the whole page, so a record somebody had added two songs
/// from looked like a two-song record. The release comes from the metadata service and
/// what we hold is matched into it: every song in its place, the ones we have playable,
/// the ones we do not one tap from being fetched.
class AlbumPage extends StatefulWidget {
  const AlbumPage({super.key, this.album, this.remoteId, this.title});

  /// From the library: the album as this library spells it.
  final AlbumSummary? album;

  /// From an artist's discography or the feed: a record we may hold nothing of.
  final String? remoteId;
  final String? title;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  Future<AlbumDetail>? _future;
  bool _filling = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final api = context.read<AppState>().api;
    setState(() {
      _future = api.albumDetail(
        album: widget.album?.name,
        artist: widget.album?.artist,
        remoteId: widget.remoteId,
      );
    });
  }

  Future<void> _fill(AlbumDetail detail, {String? one}) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _filling = true);
    try {
      final r = await context.read<AppState>().api.fillAlbum(
            album: widget.album?.name,
            artist: widget.album?.artist,
            remoteId: widget.remoteId ?? detail.remoteId,
            remoteIds: one == null ? const [] : [one],
          );
      messenger.say(snack(Text(r.queued == 0
            ? 'Nothing could be matched'
            : '${r.queued} queued'
                '${r.notMatched == 0 ? '' : ' · ${r.notMatched} not matched'}'),
      ));
      _load();
    } catch (e) {
      messenger.say(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _filling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlayerScaffold(
      appBar: AppBar(
        title: Text(widget.album?.name ?? widget.title ?? 'Album'),
        actions: [
          if (widget.album != null) ...[
            IconButton(
              icon: const Icon(Icons.link),
              tooltip: 'Copy a link to this record',
              onPressed: () => copyLink(
                  context, '/a/${Uri.encodeComponent(widget.album!.name)}',
                  widget.album!.name),
            ),
            _TakeItWithYou(
                album: widget.album!.name, artist: widget.album!.artist),
          ],
        ],
      ),
      body: FutureBuilder<AlbumDetail>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const SongsComing(rows: 7);
          final detail = snap.data!;
          final held = [
            for (final r in detail.tracks)
              if (r.track != null) r.track!,
            ...detail.extra,
          ];
          // Ask for the artwork of what just arrived, so scrolling it is not a screen
          // of grey squares filling in one at a time.
          context.read<AppState>().keepCoversFor(held);
          // A record is a list like any other: several of its songs can be picked
          // out and queued, kept or put on a playlist together. Only the ones we
          // actually hold — a row for a track nobody has fetched has nothing to pick.
          final where = 'album:${widget.album?.name ?? widget.remoteId ?? ''}';
          return SelectionOver(
            bar: SelectionBar(where: where, tracks: held),
            child: RefreshIndicator(
            onRefresh: () async => _load(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
              children: [
                _AlbumHead(
                  detail: detail,
                  held: held,
                  filling: _filling,
                  onFill: () => _fill(detail),
                ),
                for (final row in detail.tracks)
                  _ReleaseRow(
                    row: row,
                    playable: held,
                    named: detail.name,
                    selectable: where,
                    onFetch: detail.complete && row.remoteId != null
                        ? () => _fill(detail, one: row.remoteId)
                        : null,
                  ),
                if (detail.extra.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 20, 16, 6),
                    child: Text('Also in your library under this album'),
                  ),
                  // The same row as everywhere else: these were plain tiles with no
                  // menu, no swipe and nothing to say whether the song was even here.
                  for (final t in detail.extra)
                    SongRow(
                      track: t,
                      selectable: where,
                      onTap: () => context.read<AppState>().playNow(held,
                          startAt: held.indexOf(t), named: detail.name),
                    ),
                ],
              ],
            ),
            ),
          );
        },
      ),
    );
  }
}

/// The head of a record's page, set as a review.
///
/// The record's own page used to be a small cover beside two lines of grey text over
/// a row of buttons: the same weight as a search result. It is the one page in the app
/// that is about one record, so it is set the way a magazine sets a review — the cover
/// cut out and taped down on a wash of the record's own colour, the title as big as it
/// will go, and the facts in a typewritten box: when, how long, where from, and whether
/// it is here.
class _AlbumHead extends StatelessWidget {
  const _AlbumHead(
      {required this.detail, required this.held, required this.filling, required this.onFill});
  final AlbumDetail detail;
  final List<Track> held;
  final bool filling;
  final VoidCallback onFill;

  /// The record's length, from whatever lengths are known.
  String? _length() {
    var ms = 0;
    for (final row in detail.tracks) {
      ms += row.durationMs ?? row.track?.durationMs ?? 0;
    }
    if (ms == 0) {
      for (final t in held) {
        ms += t.durationMs ?? 0;
      }
    }
    if (ms == 0) return null;
    final minutes = (ms / 60000).round();
    return minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h ${minutes % 60} min';
  }

  static String _source(String s) => switch (s) {
        'youtube' => 'YouTube Music',
        'bandcamp' => 'Bandcamp',
        'soundcloud' => 'SoundCloud',
        'custom' => 'Uploaded',
        _ => s,
      };

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final offline = context.watch<AppState>().offline;
    final kept = OfflineStore.supported &&
        held.isNotEmpty &&
        held.every((t) => offline.has(t.id));
    // The record's own colour, where the server has read one off its cover.
    final tint = parseHexColour(held.firstOrNull?.coverColor);
    final type = (detail.recordType ?? 'record').toUpperCase();
    final total = detail.tracks.isNotEmpty ? detail.tracks.length : held.length;
    final length = _length();
    final cover = detail.cover ??
        (held.isEmpty ? null : app.api.coverUrl(held.first, small: false));

    final facts = <(String, String)>[
      if (detail.year != null) ('Year', detail.year!),
      ('Tracks', detail.complete ? '${detail.have} of $total' : '$total'),
      if (length != null) ('Length', length),
      if (held.isNotEmpty) ('From', _source(held.first.source)),
      (
        'Here',
        kept
            ? 'Kept on this device'
            : detail.missing > 0
                ? '${detail.missing} still to get'
                : 'On the server'
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Row(
            children: [
              Container(
                color: scheme.primary,
                padding: const EdgeInsets.fromLTRB(8, 3, 8, 2),
                child: Text('REVIEWS', style: Mag.flag(10, color: scheme.onPrimary)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text('WETOWL · $type',
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant, bold: true)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          // A wash of the record's colour behind the cut-out, faint enough that the
          // page is still paper.
          color: (tint ?? scheme.primary).withValues(alpha: 0.14),
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: LayoutBuilder(builder: (context, box) {
            final art = (box.maxWidth * 0.42).clamp(110.0, 220.0);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: CutOut(
                    turn: 0.04,
                    taped: true,
                    child: cover == null
                        // A record with no cover gets a sleeve printed with its own
                        // name, not its first song's.
                        ? PrintedSleeve(
                            seed: PrintedSleeve.seedOf('${detail.artist}·${detail.name}'),
                            title: detail.name,
                            size: art)
                        : Artwork(url: cover, size: art, radius: 0, small: false),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(detail.name.toUpperCase(),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: Mag.headline(34, color: scheme.onSurface)),
                      if (detail.artist != null && detail.artist!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(detail.artist!.toUpperCase(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Mag.flag(10.5, color: scheme.onSurface)),
                      ],
                      if (detail.unavailable != null) ...[
                        const SizedBox(height: 8),
                        Text('Only what you have: ${detail.unavailable}',
                            style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ),
              ],
            );
          }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: _FactFile(facts: facts),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          // A Wrap, not a Row: every button and "Get 12 missing" do not fit across a
          // phone, and a Row that does not fit is a strip of yellow and black.
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PressButton(
                label: 'Play',
                loud: true,
                onTap: held.isEmpty ? null : () => app.playNow(held, named: detail.name),
              ),
              PressButton(
                label: 'Shuffle',
                onTap: held.isEmpty
                    ? null
                    : () => app.playNow(held, shuffle: true, named: detail.name),
              ),
              // Everything that belongs next to this record, seeded from the record
              // itself rather than from its first track.
              PressButton(
                label: 'Station',
                onTap: held.isEmpty
                    ? null
                    : () => startStation(context, album: detail.name, artist: detail.artist),
              ),
              if (OfflineStore.supported)
                PressButton(
                  label: kept ? 'Kept' : 'Keep',
                  onTap: held.isEmpty
                      ? null
                      : () async {
                          if (kept) {
                            for (final t in held) {
                              await offline.forget(t.id);
                            }
                            return;
                          }
                          await offline.keep(held);
                        },
                ),
              if (detail.missing > 0)
                PressButton(
                  label: filling ? 'Getting…' : 'Get ${detail.missing} missing',
                  onTap: filling ? null : onFill,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The facts, typed in a ruled box the way a review's panel is.
class _FactFile extends StatelessWidget {
  const _FactFile({required this.facts});

  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(border: Border.all(color: scheme.onSurface, width: 1.5)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: scheme.onSurface,
            padding: const EdgeInsets.fromLTRB(8, 3, 8, 2),
            child: Text('FACT FILE', style: Mag.flag(10, color: scheme.surface)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Column(
              children: [
                for (final (k, v) in facts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 70,
                          child: Text(k,
                              style: Mag.typewriter(12, color: scheme.onSurface, bold: true)),
                        ),
                        Expanded(
                          child: Text(v, style: Mag.typewriter(12, color: scheme.onSurface)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// One line of the record. A song we hold plays; one we do not is offered.
class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow(
      {required this.row,
      required this.playable,
      this.named,
      this.onFetch,
      this.selectable});
  final ReleaseTrack row;
  final List<Track> playable;

  /// The record's name, so tapping a row plays into the record's own queue — the same
  /// one the Play button makes — rather than writing over whatever was on. The two
  /// used to differ: the button kept your queue, the row emptied it.
  final String? named;
  final VoidCallback? onFetch;

  /// Which list this row belongs to when songs are being picked out of it. Only rows
  /// for songs we hold take part; the rest are a track listing, not a library.
  final String? selectable;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final track = row.track;
    final faded = track == null;
    final selection =
        selectable == null || track == null ? null : context.watch<Selection>();
    final picking = selection?.inside(selectable!) ?? false;
    final picked = picking && selection!.has(track!.id);

    // A row for a song we hold swipes to put it on next, like every other list. One we
    // do not hold has nothing to queue yet, so it does not.
    return _maybeSwipe(
      context,
      picking ? null : track,
      Material(
      color: picked ? scheme.primary.withValues(alpha: 0.26) : Colors.transparent,
      shape: picked
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: scheme.primary.withValues(alpha: 0.85), width: 1.6),
            )
          : null,
      child: ListTile(
      dense: true,
      leading: SizedBox(
        width: 40,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            // The slot is fixed and the type is not: a two-digit numeral at twice
            // the size shrinks to fit rather than pushing the row off the edge.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text('${row.pos}',
                    textAlign: TextAlign.end,
                    style: Mag.numerals(16,
                        color: faded ? scheme.outline : scheme.onSurfaceVariant)),
              ),
            ),
            // No artwork on this row to put the mark on, so it sits beside the
            // number instead — and a track we do not have gets no mark at all.
            const SizedBox(width: 8),
            SizedBox(
              width: 7,
              child: track == null
                  ? null
                  : SourceDot(source: track.source),
            ),
          ],
        ),
      ),
      title: Text(
        track?.displayTitle ?? row.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: faded ? TextStyle(color: scheme.outline) : null,
      ),
      subtitle: track == null
          ? Text('Not in your library',
              style: TextStyle(color: scheme.outline))
          : (track.isReady
              ? null
              : Text(track.state == 'failed'
                  ? (track.failReason ?? 'Download failed')
                  : 'Downloading…')),
      trailing: picking
          ? null
          : track == null
              ? IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 20),
                  tooltip: 'Fetch this one',
                  onPressed: onFetch,
                )
              : IconButton(
                  icon: const Icon(Icons.more_vert, size: 20),
                  tooltip: 'Track actions',
                  onPressed: () => showTrackSheet(context, track),
                ),
      onLongPress: track == null || selectable == null
          ? null
          : () => selection!.start(selectable!, track.id),
      onTap: picking
          ? () => selection!.toggle(selectable!, track!.id)
          : track == null
              ? onFetch
              : () => app.playNow(playable,
                  startAt: playable.indexOf(track), named: named),
    ),
    ),
    );
  }
}

/// Wrap a row that is not a SongRow in the same play-next gesture SongRow has, so a
/// record and an artist behave like the lists everywhere else.
Widget _maybeSwipe(BuildContext context, Track? track, Widget row) {
  if (track == null) return row;
  return SwipeAction(
    onSwipe: () => addAndSay(context, track, mode: 'next'),
    child: row,
  );
}

class ArtistsPage extends StatefulWidget {
  const ArtistsPage({super.key});

  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<ArtistsPage> {
  static const _sorts = {
    'name': 'Name',
    'tracks': 'Most songs',
    'albums': 'Most records',
  };

  String _q = '';
  String _sort = 'name';
  late Paged<ArtistSummary> _artists = _pager();

  Paged<ArtistSummary> _pager() {
    final api = context.read<AppState>().api;
    final q = _q, sort = _sort;
    return Paged<ArtistSummary>(
      pageSize: 300,
      fetch: (offset, limit) =>
          api.artists(offset: offset, limit: limit, q: q, sort: sort),
    )..next();
  }

  void _again() => setState(() {
        _artists.dispose();
        _artists = _pager();
      });

  @override
  void dispose() {
    _artists.dispose();
    super.dispose();
  }

  void _load() => _artists.reload();

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return PlayerScaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: _artists,
          builder: (context, _) => Text(
              _artists.total > 0 ? 'Artists · ${_artists.total}' : 'Artists'),
        ),
        bottom: _FilterBar(
          hint: 'Find an artist',
          sorts: _sorts,
          sort: _sort,
          onSearch: (v) {
            if (v.trim() == _q) return;
            _q = v.trim();
            _again();
          },
          onSort: (v) {
            if (v == _sort) return;
            _sort = v;
            _again();
          },
        ),
      ),
      body: ListenableBuilder(
        listenable: _artists,
        builder: (context, _) {
          if (_artists.error != null && _artists.items.isEmpty) {
            return ErrorRetry(error: _artists.error!, onRetry: _load);
          }
          if (_artists.items.isEmpty && _artists.loading) {
            return const SongsComing(rows: 10);
          }
          final artists = _artists.items;
          if (artists.isEmpty) {
            return EmptyHint(
              icon: Icons.person_outline,
              title: _q.isEmpty ? 'No artists yet' : 'Nobody called that',
              body: _q.isEmpty
                  ? 'Artists appear as tracks get their metadata.'
                  : 'No artist here matches “$_q”.',
            );
          }
          return RefreshIndicator(
            onRefresh: _artists.reload,
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.extentAfter < 900) _artists.next();
                return false;
              },
              child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: artists.length,
              itemBuilder: (context, i) => ListTile(
                leading: ClipOval(
                  child: Artwork(
                      url: app.api.coverUrlForPath(artists[i].coverPath),
                      size: 44,
                      radius: 22),
                ),
                title: Text(artists[i].name),
                subtitle: Text(artists[i].subtitle),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ArtistPage(artist: artists[i]),
                )),
              ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// An artist, not just the four songs of theirs somebody once added.
///
/// Their records — all of them, with how much of each we hold — their best-known
/// songs, and the follow button that puts new releases in the feed.
class ArtistPage extends StatefulWidget {
  const ArtistPage({super.key, required this.artist});
  final ArtistSummary artist;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  Future<ArtistDetail>? _future;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(() {
        _future = context.read<AppState>().api.artistDetail(widget.artist.name);
      });

  Future<void> _toggleFollow(ArtistDetail d) async {
    if (d.remoteId == null) return;
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _working = true);
    try {
      if (d.following) {
        await api.unfollow(d.remoteId!);
      } else {
        await api.follow(remoteId: d.remoteId, name: d.name, image: d.image);
      }
      messenger.say(snack(Text(d.following
            ? 'No longer following ${d.name}'
            : 'Following ${d.name} — new records show up in your feed'),
      ));
      _load();
    } catch (e) {
      messenger.say(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlayerScaffold(
      appBar: AppBar(
        title: Text(widget.artist.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: 'Copy a link to this artist',
            onPressed: () => copyLink(context,
                '/r/${Uri.encodeComponent(widget.artist.name)}', widget.artist.name),
          ),
          _TakeItWithYou(artist: widget.artist.name),
        ],
      ),
      body: FutureBuilder<ArtistDetail>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const SongsComing(rows: 7);
          final d = snap.data!;
          context.read<AppState>().keepCoversFor(d.tracks);
          final where = 'artist:${d.name}';
          return SelectionOver(
            bar: SelectionBar(where: where, tracks: d.tracks),
            child: RefreshIndicator(
            onRefresh: () async => _load(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
              children: [
                _ArtistHead(
                  detail: d,
                  working: _working,
                  onFollow: () => _toggleFollow(d),
                ),
                if (d.top.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 18, 16, 6),
                    child: SectionFlag('Best known'),
                  ),
                  for (final row in d.top.take(8))
                    _TopRow(row: row, playable: d.tracks, named: d.name),
                ],
                if (d.albums.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 22, 16, 10),
                    child: SectionFlag('Discography'),
                  ),
                  _AlbumStrip(albums: d.albums, artist: d.name),
                ],
                if (d.tracks.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
                    child: SectionFlag('In your library · ${d.tracks.length}'),
                  ),
                  // Was a tile of its own with a menu button and nothing else: no
                  // swipe to play next, no source, no sign of what is on the device,
                  // and no way to pick several out. It is the same song as in every
                  // other list, so it is the same row.
                  for (var i = 0; i < d.tracks.length; i++)
                    SongRow(
                      track: d.tracks[i],
                      selectable: where,
                      dense: true,
                      onTap: () => context
                          .read<AppState>()
                          .playNow(d.tracks, startAt: i, named: d.name),
                    ),
                ],
              ],
            ),
            ),
          );
        },
      ),
    );
  }
}

/// The head of an artist's page, set as a profile.
///
/// Their picture printed the way a music paper printed a band it could not afford
/// colour for: one ink, the masthead red, over paper, through a halftone screen. Where
/// there is no picture of them, the covers of their records stand in, printed the same
/// way. Their name is pasted over the bottom of it on a slip.
class _ArtistHead extends StatelessWidget {
  const _ArtistHead(
      {required this.detail, required this.working, required this.onFollow});
  final ArtistDetail detail;
  final bool working;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final covers = [
      for (final a in detail.albums)
        if (a.cover != null) a.cover!
    ].take(4).toList();
    final line = [
      if (detail.albums.isNotEmpty)
        '${detail.albums.length} ${detail.albums.length == 1 ? 'record' : 'records'}',
      '${detail.tracks.length} in your library',
      if (detail.fans != null && detail.fans! > 0) '${_count(detail.fans!)} fans',
    ].join(' · ');

    Widget picture(double width) {
      if (detail.image != null) {
        return Image(
          image: artwork(detail.image!, drawnAt: width, ratio: ratio),
          fit: BoxFit.cover,
          alignment: const Alignment(0, -0.3),
          errorBuilder: (_, __, ___) => const SizedBox.expand(),
        );
      }
      if (covers.isEmpty) return const SizedBox.expand();
      return Row(
        children: [
          for (final c in covers)
            Expanded(
              child: Image(
                image: artwork(c, drawnAt: width / covers.length, ratio: ratio),
                fit: BoxFit.cover,
                height: double.infinity,
                errorBuilder: (_, __, ___) => const SizedBox.expand(),
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 230,
          child: LayoutBuilder(builder: (context, box) {
            return Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: MuseTheme.paper),
                // One ink: the picture in greys, then the red multiplied into it,
                // so the lights are red and the darks go to black.
                ColorFiltered(
                  colorFilter: const ColorFilter.matrix(<double>[
                    0.30, 0.59, 0.11, 0, 0,
                    0.30, 0.59, 0.11, 0, 0,
                    0.30, 0.59, 0.11, 0, 0,
                    0, 0, 0, 1, 0,
                  ]),
                  child: picture(box.maxWidth),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    color: MuseTheme.masthead,
                    backgroundBlendMode: BlendMode.multiply,
                  ),
                ),
                // The screen it was printed through.
                IgnorePointer(child: CustomPaint(painter: _Screen())),
                Positioned(
                  left: 14,
                  right: 40,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        color: MuseTheme.paper,
                        padding: const EdgeInsets.fromLTRB(6, 3, 6, 2),
                        child: Text('PROFILE',
                            style: Mag.flag(10, color: MuseTheme.masthead)),
                      ),
                      Container(
                        color: MuseTheme.paper,
                        padding: const EdgeInsets.fromLTRB(6, 4, 8, 0),
                        child: Text(detail.name.toUpperCase(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Mag.headline(44, color: MuseTheme.ink)),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(line.toUpperCase(),
              style: Mag.typewriter(11, color: scheme.onSurfaceVariant, bold: true)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (detail.remoteId != null)
                PressButton(
                  label: working
                      ? '…'
                      : detail.following
                          ? 'Following'
                          : 'Follow',
                  // Loud until you follow: the one thing to do on a page about
                  // somebody you have not followed yet.
                  loud: !detail.following,
                  onTap: working ? null : onFollow,
                ),
              // Their songs and everything that belongs next to them, seeded from
              // what of theirs is already here.
              if (detail.tracks.isNotEmpty)
                PressButton(
                  label: 'Station',
                  onTap: () => startStation(context, artist: detail.name),
                ),
              if (detail.remoteId == null && detail.unavailable != null)
                Text('Only your library: ${detail.unavailable}',
                    style: Mag.typewriter(11, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }

  static String _count(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(1)}M'
      : n >= 1000
          ? '${(n / 1000).round()}K'
          : '$n';
}

/// A halftone screen laid over a picture: rows of paper-coloured dots at an angle,
/// bigger towards the bottom, the way a coarse screen shows on newsprint.
class _Screen extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const step = 7.0;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(0.26);
    // Only as far as the turned grid has to reach to cover the box, and each row as
    // one batch of round points rather than a circle drawn at a time: a few dozen
    // calls instead of several thousand.
    final reach = size.center(Offset.zero).distance + step;
    for (var y = -reach; y < reach; y += step) {
      // Heavier dots lower down, so the name sits on the densest part.
      final t = ((y + size.height / 2) / size.height).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = MuseTheme.paper.withValues(alpha: 0.22)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2 * (0.6 + 1.6 * t);
      canvas.drawPoints(ui.PointMode.points,
          [for (var x = -reach; x < reach; x += step) Offset(x, y)], paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Screen old) => false;
}

class _TopRow extends StatelessWidget {
  const _TopRow({required this.row, required this.playable, this.named});
  final ReleaseTrack row;
  final List<Track> playable;
  final String? named;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = row.track;
    return _maybeSwipe(
      context,
      track,
      ListTile(
      dense: true,
      leading: track == null
          ? Artwork(track: track, size: 36, radius: 4)
          : MarkedArtwork(
              source: track.source,
              child: Artwork(track: track, size: 36, radius: 4),
            ),
      title: Text(track?.displayTitle ?? row.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: track == null ? TextStyle(color: scheme.outline) : null),
      subtitle: track == null
          ? Text('Not in your library', style: TextStyle(color: scheme.outline))
          : null,
      trailing: track == null
          ? null
          : IconButton(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: 'Track actions',
              onPressed: () => showTrackSheet(context, track),
            ),
      onTap: track == null
          ? null
          : () => context.read<AppState>().playNow(playable,
              startAt: playable.indexOf(track), named: named),
    ),
    );
  }
}

/// The discography, as covers you can open. Records we have some of say so.
class _AlbumStrip extends StatelessWidget {
  const _AlbumStrip({required this.albums, required this.artist});
  final List<ArtistAlbum> albums;
  final String artist;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    // The strip is a fixed height because a sideways list has to be told how tall to
    // be; the words under each cover are not, so the height follows the text size.
    final scale = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.4);
    return SizedBox(
      height: 140 + 54 * scale,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
        itemCount: albums.length,
        separatorBuilder: (_, __) => const SizedBox(width: 16),
        itemBuilder: (context, i) {
          final a = albums[i];
          return SizedBox(
            width: 124,
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AlbumPage(remoteId: a.remoteId, title: a.title),
              )),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CutOut(
                        // Pasted a little differently each, as a hand does.
                        turn: (i.isEven ? -1 : 1) * (0.02 + (i % 3) * 0.01),
                        child: a.cover == null
                            ? PrintedSleeve(
                                seed: PrintedSleeve.seedOf('$artist·${a.title}'),
                                title: a.title,
                                size: 112)
                            : Artwork(url: a.cover, size: 112, radius: 0),
                      ),
                      // How many of its songs are already here.
                      if (a.have > 0)
                        Positioned(
                          right: -4,
                          top: -6,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(5, 2, 5, 1),
                            color: scheme.onSurface,
                            child: Text('${a.have} HERE',
                                style: Mag.flag(9, color: scheme.surface)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(a.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelLarge),
                  Text([a.year, a.recordType].whereType<String>().join(' · ').toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Mag.typewriter(10.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
