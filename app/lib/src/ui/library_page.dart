import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
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
                if (v == 'delete') {
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
                PopupMenuItem(value: 'queue', child: Text('Add all to queue')),
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
            child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: items.length,
            itemBuilder: (context, i) => Dismissible(
              key: ValueKey('pl-${items[i].id}-$i'),
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
              ),
            ),
          ),
          );
        },
      ),
    );
  }
}

class _HistoryPage extends StatelessWidget {
  const _HistoryPage();

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Recently played')),
      body: FutureBuilder<List<Track>>(
        future: app.api.history(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const Center(child: Text('Nothing played yet.'));
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) => ListTile(
              leading: Artwork(track: items[i], size: 40),
              title: Text(items[i].displayTitle,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(items[i].artistLine),
              trailing: IconButton(
                icon: const Icon(Icons.playlist_add),
                onPressed: () => app.addTrack(items[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}
