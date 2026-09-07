import 'package:flutter/material.dart';

import '../api/models.dart';
import 'artwork.dart';
import '../state/app_state.dart';

/// Ask for a name. Returns null when the user backs out, so callers can tell "cancel"
/// apart from "empty".
Future<String?> promptForName(BuildContext context, String title,
    [String initial = '']) async {
  final controller = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (v) => Navigator.pop(context, v),
        decoration: const InputDecoration(hintText: 'Name'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save')),
      ],
    ),
  );
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

Future<bool> confirm(BuildContext context, String title, String body) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
      ],
    ),
  );
  return ok ?? false;
}

/// Pick a playlist to add a track to, or make one on the spot — the common case is
/// "this song belongs somewhere I have not created yet".
Future<void> addToPlaylistSheet(
    BuildContext context, AppState app, Track track) async {
  await app.refreshPlaylists();
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                Artwork(track: track, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(track.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall),
                      Text(track.artistLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New playlist…'),
            onTap: () async {
              final name = await promptForName(sheetContext, 'New playlist');
              if (name == null) return;
              final made = await app.api.createPlaylist(name);
              await app.api.addToPlaylist(made.id, [track.id]);
              await app.refreshPlaylists();
              if (sheetContext.mounted) Navigator.pop(sheetContext);
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('Added to "$name"')));
              }
            },
          ),
          for (final p in app.playlists)
            ListTile(
              leading: const Icon(Icons.playlist_play),
              title: Text(p.name),
              subtitle: Text('${p.itemCount} tracks'),
              onTap: () async {
                await app.api.addToPlaylist(p.id, [track.id]);
                await app.refreshPlaylists();
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('Added to "${p.name}"')));
                }
              },
            ),
        ],
      ),
    ),
  );
}
