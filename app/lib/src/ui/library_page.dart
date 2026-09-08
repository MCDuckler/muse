import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'browse_page.dart';
import 'dialogs.dart';


class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return RefreshIndicator(
      onRefresh: app.refresh,
      child: ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        // The library itself, which until now could not be browsed at all.
        ListTile(
          leading: const Icon(Icons.library_music_outlined),
          title: const Text('All tracks'),
          subtitle: const Text('Everything, sortable'),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const AllTracksPage())),
        ),
        ListTile(
          leading: const Icon(Icons.album_outlined),
          title: const Text('Albums'),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const AlbumsPage())),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('Artists'),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const ArtistsPage())),
        ),
        const Divider(),
        const _SectionLabel('Playlists'),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('New playlist'),
          onTap: () async {
            final name = await promptForName(context, 'New playlist');
            if (name == null) return;
            await app.api.createPlaylist(name);
            await app.refreshPlaylists();
          },
        ),
        for (final p in app.playlists)
          ListTile(
            leading: Icon(switch (p.kind) {
              'spotify' => Icons.sync_alt,
              'ytmusic' => Icons.sync_alt,
              _ => Icons.playlist_play,
            }),
            title: Text(p.name),
            subtitle: Text(p.kind == 'local' ? '${p.itemCount} tracks'
                : '${p.itemCount} tracks · synced from ${p.kind}'),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) async {
                if (v == 'play' || v == 'shuffle') {
                  final full = await app.api.playlist(p.id);
                  await app.playNow(full.items, shuffle: v == 'shuffle');
                } else if (v == 'rename') {
                  final name = await promptForName(context, 'Rename playlist', p.name);
                  if (name == null) return;
                  await app.api.renamePlaylist(p.id, name);
                  await app.refreshPlaylists();
                } else if (v == 'delete') {
                  final ok = await confirm(context, 'Delete "${p.name}"?',
                      'The tracks stay in your library.');
                  if (!ok) return;
                  await app.api.deletePlaylist(p.id);
                  await app.refreshPlaylists();
                } else if (v == 'queue') {
                  final full = await app.api.playlist(p.id);
                  for (final track in full.items) {
                    await app.addTrack(track);
                  }
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'play', child: Text('Play')),
                PopupMenuItem(value: 'shuffle', child: Text('Shuffle')),
                PopupMenuItem(value: 'queue', child: Text('Add all to queue')),
                PopupMenuItem(value: 'rename', child: Text('Rename…')),
                PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
              ],
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => _PlaylistPage(playlistId: p.id, name: p.name),
            )),
          ),
        if (app.playlists.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('No playlists yet.')),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Recently played'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const _HistoryPage(),
          )),
        ),
      ],
      ),
    );
  }
}

class _PlaylistPage extends StatefulWidget {
  const _PlaylistPage({required this.playlistId, required this.name});
  final int playlistId;
  final String name;

  @override
  State<_PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<_PlaylistPage> {
  late Future<Playlist> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().api.playlist(widget.playlistId);
  }

  void _reload() => setState(
      () => _future = context.read<AppState>().api.playlist(widget.playlistId));

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: FutureBuilder<Playlist>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!.items;
          if (items.isEmpty) {
            return const Center(child: Text('Nothing in this playlist yet.'));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
            physics: const AlwaysScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            header: _PlaylistHeader(items: items),
            onReorderItem: (from, to) async {
              await app.api.movePlaylistItem(widget.playlistId, from, to);
              _reload();
            },
            itemCount: items.length,
            itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
              key: ValueKey('pl-${items[i].id}-$i'),
              index: i,
              child: Dismissible(
              key: ValueKey('pl-dismiss-${items[i].id}-$i'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.delete_outline),
              ),
              onDismissed: (_) async {
                await app.api.removePlaylistItem(widget.playlistId, i);
                await app.refreshPlaylists();
                _reload();
              },
              child: ListTile(
                leading: Artwork(track: items[i], size: 40),
                title: Text(items[i].displayTitle,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(items[i].artistLine),
                trailing: IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: 'Add to queue',
                  onPressed: () => app.addTrack(items[i]),
                ),
                onTap: () => app.playNow(items, startAt: i),
              ),
            ),
            ),
          ),
          );
        },
      ),
    );
  }
}

class _HistoryPage extends StatefulWidget {
  const _HistoryPage();

  @override
  State<_HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<_HistoryPage> {
  Future<List<PlayedTrack>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() =>
      setState(() => _future = context.read<AppState>().api.playHistory());

  /// Grouped by day. A flat list with no sense of when is not a history.
  static String _dayLabel(DateTime? when) {
    if (when == null) return 'Earlier';
    final now = DateTime.now();
    final day = DateTime(when.year, when.month, when.day);
    final today = DateTime(now.year, now.month, now.day);
    final difference = today.difference(day).inDays;
    if (difference == 0) return 'Today';
    if (difference == 1) return 'Yesterday';
    if (difference < 7) return '$difference days ago';
    return '${when.year}-${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')}';
  }

  static String _time(DateTime? when) => when == null
      ? ''
      : '${when.hour.toString().padLeft(2, '0')}:'
          '${when.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recently played'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear history',
            onPressed: () async {
              final ok = await confirm(context, 'Clear listening history?',
                  'The tracks stay in your library.');
              if (!ok) return;
              await app.api.clearHistory();
              _load();
            },
          ),
        ],
      ),
      body: FutureBuilder<List<PlayedTrack>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _load);
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const EmptyHint(
              icon: Icons.history,
              title: 'Nothing played yet',
              body: 'What you listen to shows up here.',
            );
          }
          String? lastDay;
          return RefreshIndicator(
            onRefresh: () async => _load(),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final played = items[i];
                final day = _dayLabel(played.playedAt);
                final showDay = day != lastDay;
                if (showDay) lastDay = day;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showDay) _SectionLabel(day),
                    ListTile(
                      leading: Artwork(track: played.track, size: 40),
                      title: Text(played.track.displayTitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [_time(played.playedAt), played.track.artistLine]
                            .where((s) => s.isNotEmpty)
                            .join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.playlist_add),
                        tooltip: 'Add to queue',
                        onPressed: () => app.addTrack(played.track),
                      ),
                      onTap: () => app.playNow([played.track]),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(text.toUpperCase(),
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class _PlaylistHeader extends StatelessWidget {
  const _PlaylistHeader({required this.items});
  final List<Track> items;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text('${items.length} tracks',
                style: Theme.of(context).textTheme.bodySmall),
          ),
          TextButton.icon(
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Play'),
            onPressed: () => app.playNow(items),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            icon: const Icon(Icons.shuffle, size: 18),
            label: const Text('Shuffle'),
            onPressed: () => app.playNow(items, shuffle: true),
          ),
        ],
      ),
    );
  }
}
