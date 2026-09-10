import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'source_dot.dart';
import 'dialogs.dart';
import 'mini_player.dart';
import 'track_list.dart';
import 'track_menu.dart';

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
  Future<({List<Track> items, int total})>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(() =>
      _future = context.read<AppState>().api.libraryTracks(sort: _sort));

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
      body: FutureBuilder<({List<Track> items, int total})>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorRetry(error: snap.error!, onRetry: _load);
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          return RefreshIndicator(
            onRefresh: () async => _load(),
            child: TrackList(
              tracks: data.items,
              selectable: 'library',
              header: '${data.total} in your library · ${_sorts[_sort]!.toLowerCase()}',
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
  Future<List<AlbumSummary>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final pending = context.read<AppState>().api.albums();
    setState(() { _future = pending; });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return PlayerScaffold(
      appBar: AppBar(title: const Text('Albums')),
      body: FutureBuilder<List<AlbumSummary>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final albums = snap.data!;
          if (albums.isEmpty) {
            return const EmptyHint(
              icon: Icons.album_outlined,
              title: 'No albums yet',
              body: 'Albums appear as tracks get their metadata.',
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _load(),
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 160),
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
      messenger.showSnackBar(SnackBar(
        content: Text(r.queued == 0
            ? 'Nothing could be matched'
            : '${r.queued} queued'
                '${r.notMatched == 0 ? '' : ' · ${r.notMatched} not matched'}'),
      ));
      _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
          return RefreshIndicator(
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
                    onFetch: detail.complete && row.remoteId != null
                        ? () => _fill(detail, one: row.remoteId)
                        : null,
                  ),
                if (detail.extra.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 20, 16, 6),
                    child: Text('Also in your library under this album'),
                  ),
                  for (final t in detail.extra)
                    ListTile(
                      leading: Artwork(track: t, size: 40),
                      title: Text(t.displayTitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(t.artistLine,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => context
                          .read<AppState>()
                          .playNow(held, startAt: held.indexOf(t)),
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
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Play'),
                onPressed: held.isEmpty
                    ? null
                    : () => app.playNow(held, named: detail.name),
              ),
              TextButton.icon(
                icon: const Icon(Icons.shuffle, size: 18),
                label: const Text('Shuffle'),
                onPressed: held.isEmpty
                    ? null
                    : () => app.playNow(held, shuffle: true, named: detail.name),
              ),
              const Spacer(),
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
  const _ReleaseRow({required this.row, required this.playable, this.onFetch});
  final ReleaseTrack row;
  final List<Track> playable;
  final VoidCallback? onFetch;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final track = row.track;
    final faded = track == null;

    return ListTile(
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
      trailing: track == null
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
      onTap: track == null
          ? onFetch
          : () => app.playNow(playable, startAt: playable.indexOf(track)),
    );
  }
}

class ArtistsPage extends StatefulWidget {
  const ArtistsPage({super.key});

  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<ArtistsPage> {
  Future<List<ArtistSummary>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final pending = context.read<AppState>().api.artists();
    setState(() { _future = pending; });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return PlayerScaffold(
      appBar: AppBar(title: const Text('Artists')),
      body: FutureBuilder<List<ArtistSummary>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final artists = snap.data!;
          return RefreshIndicator(
            onRefresh: () async => _load(),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
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
      messenger.showSnackBar(SnackBar(
        content: Text(d.following
            ? 'No longer following ${d.name}'
            : 'Following ${d.name} — new records show up in your feed'),
      ));
      _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
          return RefreshIndicator(
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
                    _TopRow(row: row, playable: d.tracks),
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
                  for (var i = 0; i < d.tracks.length; i++)
                    ListTile(
                      dense: true,
                      leading: Artwork(track: d.tracks[i], size: 40),
                      title: Text(d.tracks[i].displayTitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(d.tracks[i].albumLine ?? '',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.more_vert, size: 20),
                        tooltip: 'Track actions',
                        onPressed: () => showTrackSheet(context, d.tracks[i]),
                      ),
                      onTap: () => context
                          .read<AppState>()
                          .playNow(d.tracks, startAt: i),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopRow extends StatelessWidget {
  const _TopRow({required this.row, required this.playable});
  final ReleaseTrack row;
  final List<Track> playable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = row.track;
    return ListTile(
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
          : () => context
              .read<AppState>()
              .playNow(playable, startAt: playable.indexOf(track)),
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
