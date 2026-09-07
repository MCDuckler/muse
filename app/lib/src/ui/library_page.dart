import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListView(
      children: [
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
    );
  }
}

class _PlaylistPage extends StatelessWidget {
  const _PlaylistPage({required this.playlistId, required this.name});
  final int playlistId;
  final String name;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: FutureBuilder<Playlist>(
        future: app.api.playlist(playlistId),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!.items;
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) => ListTile(
              title: Text(items[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
              title: Text(items[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
