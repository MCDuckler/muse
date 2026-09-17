import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/offline.dart';
import '../state/paged.dart';
import '../state/selection.dart';
import 'artwork.dart';
import 'selection_bar.dart';
import 'song_row.dart';
import 'station.dart';
import 'source_dot.dart';
import 'swipe.dart';
import 'dialogs.dart';
import 'mini_player.dart';
import 'track_list.dart';
import 'track_menu.dart';
import 'snack.dart';

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
  late Paged<Track> _tracks = _pager();

  Paged<Track> _pager() {
    final api = context.read<AppState>().api;
    final sort = _sort;
    return Paged<Track>(
      fetch: (offset, limit) =>
          api.libraryTracks(sort: sort, offset: offset, limit: limit),
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
            return const Center(child: CircularProgressIndicator());
          }
          return RefreshIndicator(
            onRefresh: _tracks.reload,
            child: TrackList(
              tracks: _tracks.items,
              selectable: 'library',
              named: 'All tracks',
              header: '${_tracks.total} in your library · '
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
    return PlayerScaffold(
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
            return const Center(child: CircularProgressIndicator());
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
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 190,
                childAspectRatio: 0.74,
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
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
      messenger.showSnackBar(snack(Text(r.queued == 0
            ? 'Nothing could be matched'
            : '${r.queued} queued'
                '${r.notMatched == 0 ? '' : ' · ${r.notMatched} not matched'}'),
      ));
      _load();
    } catch (e) {
      messenger.showSnackBar(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _filling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlayerScaffold(
      appBar: AppBar(title: Text(widget.album?.name ?? widget.title ?? 'Album')),
      body: FutureBuilder<AlbumDetail>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final detail = snap.data!;
          final held = [
            for (final r in detail.tracks)
              if (r.track != null) r.track!,
            ...detail.extra,
          ];
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

class _AlbumHead extends StatelessWidget {
  const _AlbumHead(
      {required this.detail, required this.held, required this.filling, required this.onFill});
  final AlbumDetail detail;
  final List<Track> held;
  final bool filling;
  final VoidCallback onFill;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final text = Theme.of(context).textTheme;
    final line = [
      if (detail.artist != null && detail.artist!.isNotEmpty) detail.artist!,
      if (detail.year != null) detail.year!,
      if (detail.complete)
        '${detail.have} of ${detail.tracks.length}'
      else
        '${detail.tracks.length} tracks',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Artwork(
                url: detail.cover ??
                    (held.isEmpty ? null : app.api.coverUrl(held.first, small: false)),
                size: 96,
                radius: 8,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(detail.name, style: text.titleMedium),
                    const SizedBox(height: 4),
                    Text(line, style: text.bodySmall),
                    if (detail.unavailable != null) ...[
                      const SizedBox(height: 4),
                      Text('Only what you have — ${detail.unavailable}',
                          style: text.bodySmall),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // A Wrap, not a Row: five buttons and "Get 12 missing" do not fit across a
          // phone, and a Row that does not fit is a strip of yellow and black.
          Wrap(
            spacing: 2,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Play'),
                onPressed: held.isEmpty
                    ? null
                    : () => app.playNow(held, named: detail.name),
              ),
              // Everything that belongs next to this record, seeded from the record
              // itself rather than from its first track.
              TextButton.icon(
                icon: const Icon(Icons.radio, size: 18),
                label: const Text('Station'),
                onPressed: held.isEmpty
                    ? null
                    : () => startStation(context,
                        album: detail.name, artist: detail.artist),
              ),
              if (OfflineStore.supported)
                Builder(builder: (context) {
                  final offline = context.watch<AppState>().offline;
                  final here = held.isNotEmpty &&
                      held.every((t) => offline.has(t.id));
                  return TextButton.icon(
                    icon: Icon(
                        here ? Icons.download_done : Icons.download_outlined,
                        size: 18),
                    label: Text(here ? 'Kept' : 'Keep'),
                    onPressed: held.isEmpty
                        ? null
                        : () async {
                            if (here) {
                              for (final t in held) {
                                await offline.forget(t.id);
                              }
                              return;
                            }
                            await offline.keep(held);
                          },
                  );
                }),
              TextButton.icon(
                icon: const Icon(Icons.shuffle, size: 18),
                label: const Text('Shuffle'),
                onPressed: held.isEmpty
                    ? null
                    : () => app.playNow(held, shuffle: true, named: detail.name),
              ),
              if (detail.missing > 0)
                FilledButton.tonalIcon(
                  icon: filling
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download, size: 18),
                  label: Text('Get ${detail.missing} missing'),
                  onPressed: filling ? null : onFill,
                ),
            ],
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
            Text('${row.pos}',
                textAlign: TextAlign.end,
                style: TextStyle(
                    color: faded ? scheme.outline : scheme.onSurfaceVariant)),
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
            return const Center(child: CircularProgressIndicator());
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

  void _load() => setState(() =>
      _future = context.read<AppState>().api.artistDetail(widget.artist.name));

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
      messenger.showSnackBar(snack(Text(d.following
            ? 'No longer following ${d.name}'
            : 'Following ${d.name} — new records show up in your feed'),
      ));
      _load();
    } catch (e) {
      messenger.showSnackBar(snack(Text('$e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlayerScaffold(
      appBar: AppBar(title: Text(widget.artist.name)),
      body: FutureBuilder<ArtistDetail>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final d = snap.data!;
          final text = Theme.of(context).textTheme;
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('Best known', style: text.titleSmall),
                  ),
                  for (final row in d.top.take(8))
                    _TopRow(row: row, playable: d.tracks, named: d.name),
                ],
                if (d.albums.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: Text('Records', style: text.titleSmall),
                  ),
                  _AlbumStrip(albums: d.albums, artist: d.name),
                ],
                if (d.tracks.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                    child: Text('In your library (${d.tracks.length})',
                        style: text.titleSmall),
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

class _ArtistHead extends StatelessWidget {
  const _ArtistHead(
      {required this.detail, required this.working, required this.onFollow});
  final ArtistDetail detail;
  final bool working;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final line = [
      if (detail.albums.isNotEmpty) '${detail.albums.length} records',
      '${detail.tracks.length} in your library',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(child: Artwork(url: detail.image, size: 84, radius: 42)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(detail.name, style: text.titleMedium),
                const SizedBox(height: 4),
                Text(line, style: text.bodySmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (detail.remoteId != null)
                      FilledButton.tonalIcon(
                        icon: working
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(detail.following
                                ? Icons.notifications_active
                                : Icons.notifications_none),
                        label: Text(detail.following ? 'Following' : 'Follow'),
                        onPressed: working ? null : onFollow,
                      )
                    else if (detail.unavailable != null)
                      Text('Only your library — ${detail.unavailable}',
                          style: text.bodySmall),
                    // Their songs and everything that belongs next to them, seeded
                    // from what of theirs is already here.
                    if (detail.tracks.isNotEmpty)
                      TextButton.icon(
                        icon: const Icon(Icons.radio, size: 18),
                        label: const Text('Station'),
                        onPressed: () =>
                            startStation(context, artist: detail.name),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
    return SizedBox(
      height: 186,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: albums.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
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
                    children: [
                      Artwork(url: a.cover, size: 124, radius: 8),
                      if (a.have > 0)
                        Positioned(
                          right: 4,
                          top: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('${a.have}',
                                style: text.labelSmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(a.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall),
                  Text([a.year, a.recordType].whereType<String>().join(' · '),
                      style: text.labelSmall),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
