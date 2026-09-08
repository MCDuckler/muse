import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';
import 'track_list.dart';

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
    return Scaffold(
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
    return Scaffold(
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

class AlbumPage extends StatelessWidget {
  const AlbumPage({super.key, required this.album});
  final AlbumSummary album;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(album.name)),
      body: FutureBuilder<List<Track>>(
        future: app.api.albumTracks(album.name, artist: album.artist),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return TrackList(tracks: snap.data!, header: album.subtitle);
        },
      ),
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
    return Scaffold(
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

class ArtistPage extends StatelessWidget {
  const ArtistPage({super.key, required this.artist});
  final ArtistSummary artist;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(artist.name)),
      body: FutureBuilder<List<Track>>(
        future: app.api.artistTracks(artist.name),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return TrackList(tracks: snap.data!, header: artist.subtitle);
        },
      ),
    );
  }
}
