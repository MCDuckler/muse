import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'artwork.dart';
import '../state/app_state.dart';

/// Ask for a name. Returns null when the user backs out, so callers can tell "cancel"
/// apart from "empty".
Future<String?> promptForName(BuildContext context, String title,
    [String initial = '',
    // Some answers are a name and some are a paste: a link, or the block of request
    // headers YouTube Music needs. One line is right for the first and useless for
    // the second.
    String hint = 'Name',
    String? help,
    bool multiline = false]) async {
  final controller = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (help != null) ...[
            Text(help, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: multiline ? 6 : 1,
            minLines: multiline ? 4 : 1,
            textInputAction:
                multiline ? TextInputAction.newline : TextInputAction.done,
            onSubmitted:
                multiline ? null : (v) => Navigator.pop(context, v),
            decoration: InputDecoration(hintText: hint),
          ),
        ],
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
              leading: PlaylistArt(playlist: p, size: 40),
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


/// A failure with a way out. A blank area and a spinner that never resolves is the
/// worst of the three things a failed load can look like.
class ErrorRetry extends StatelessWidget {
  const ErrorRetry({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is ApiException
        ? (error as ApiException).message
        : 'Could not load that';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off,
                size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint(
      {super.key, required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(body,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
}
