import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/player.dart';
import 'artwork.dart';
import 'dialogs.dart';

/// Queues are the product, so this screen shows them all, not just the one playing.
class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final active = app.activeQueue;
    // The rows come from the player, not from the queue object: they used to come
    // from different places, so the highlight could sit on the wrong track after a
    // radio append or a change from another device.
    final rows = app.player?.items ?? const <Track>[];

    return Column(
      children: [
        SizedBox(
          height: 58,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            children: [
              for (final q in app.queues)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${q.name} · ${q.itemCount}'),
                    selected: q.id == active?.id,
                    onSelected: (_) => app.openQueue(q.id),
                  ),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('New queue'),
                onPressed: () => _newQueue(context),
              ),
            ],
          ),
        ),
        if (active != null && rows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              spacing: 8,
              children: [
                IconButton.filledTonal(
                  isSelected: app.player?.shuffle ?? false,
                  icon: const Icon(Icons.shuffle),
                  tooltip: 'Shuffle',
                  onPressed: () => app.setShuffle(!(app.player?.shuffle ?? false)),
                ),
                IconButton.filledTonal(
                  isSelected: (app.player?.repeat ?? QueueRepeat.off) != QueueRepeat.off,
                  icon: Icon(app.player?.repeat == QueueRepeat.one
                      ? Icons.repeat_one
                      : Icons.repeat),
                  tooltip: switch (app.player?.repeat ?? QueueRepeat.off) {
                    QueueRepeat.off => 'Repeat off',
                    QueueRepeat.all => 'Repeat queue',
                    QueueRepeat.one => 'Repeat track',
                  },
                  onPressed: app.cycleRepeat,
                ),
                const Spacer(),
                OutlinedButton.icon(
                  icon: const Icon(Icons.radio, size: 18),
                  label: const Text('Radio'),
                  onPressed: () => app.startRadio(),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Queue actions',
                  onSelected: (v) async {
                    switch (v) {
                      case 'clear-radio':
                        await app.clearQueue(origin: 'radio');
                      case 'clear':
                        await app.clearQueue();
                      case 'save':
                        await _saveAsPlaylist(context, app);
                      case 'delete':
                        await _deleteQueue(context, app);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                        value: 'save', child: Text('Save as playlist')),
                    PopupMenuItem(
                        value: 'clear-radio', child: Text('Clear radio tracks')),
                    PopupMenuItem(value: 'clear', child: Text('Clear queue')),
                    PopupMenuDivider(),
                    PopupMenuItem(value: 'delete', child: Text('Delete this queue')),
                  ],
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: active == null || rows.isEmpty
              ? const _EmptyQueue()
              : ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
                  itemCount: rows.length,
                  buildDefaultDragHandles: false,
                  // onReorderItem, not onReorder: it hands over the index the row
                  // actually lands on, rather than one measured before the row was
                  // lifted out, which is an off-by-one waiting to happen.
                  onReorderItem: (from, to) => app.moveInQueue(from, to),
                  itemBuilder: (context, i) {
                    final t = rows[i];
                    final isCurrent = i == (app.player?.index ?? -1);
                    return Dismissible(
                      key: ValueKey('${t.id}-$i'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.delete_outline,
                            color: Theme.of(context).colorScheme.onErrorContainer),
                      ),
                      onDismissed: (_) => app.removeFromQueue(i),
                      // Long-press to drag rather than a permanent handle: two
                      // trailing controls left the titles with no room, and holding a
                      // row to move it is what every list on a phone already does.
                      child: ReorderableDelayedDragStartListener(
                        index: i,
                        child: ListTile(
                      selected: isCurrent,
                      leading: _leading(t, i, isCurrent),
                      title: Text(t.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: t.state == 'failed'
                                  ? Theme.of(context).colorScheme.error
                                  : null)),
                      subtitle: _subtitle(context, t),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (t.origin == 'radio')
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Chip(
                                  label: Text('radio'),
                                  visualDensity: VisualDensity.compact),
                            ),
                          if (t.state == 'failed')
                            IconButton(
                              icon: const Icon(Icons.refresh),
                              tooltip: 'Try again',
                              onPressed: () => app.retry(t),
                            ),
                          _rowMenu(context, app, t, i),
                        ],
                      ),
                      onTap: t.isReady
                          ? () async {
                              try {
                                await app.player?.playTrack(t.id, indexHint: i);
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('$e')));
                                }
                              }
                            }
                          : null,
                    ),
                    ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Artwork stands in for a track number, with state layered on top: a spinner while
  /// it downloads, an error mark when it failed, and the equalizer badge on whatever
  /// is playing.
  /// Artist normally; while a track is being fetched, what is actually happening —
  /// with a bar when the downloader knows how far along it is.
  Widget _subtitle(BuildContext context, Track t) {
    final scheme = Theme.of(context).colorScheme;
    final failed = t.state == 'failed';
    final line = Text(
      t.statusLine,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: failed ? TextStyle(color: scheme.error) : null,
    );
    final fraction = t.progressFraction;
    if (t.progress == null) return line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        line,
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: fraction,           // null renders as indeterminate, which is honest
            minHeight: 3,
            backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
          ),
        ),
      ],
    );
  }

  Widget _leading(Track t, int i, bool isCurrent) {
    if (t.isPending) {
      final fraction = t.progressFraction;
      return SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, value: fraction),
          ),
        ),
      );
    }
    if (t.state == 'failed') {
      return const SizedBox(width: 40, height: 40, child: Icon(Icons.error_outline));
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        Artwork(track: t, size: 40),
        if (isCurrent)
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.equalizer, color: Colors.white, size: 20),
          ),
      ],
    );
  }

  Widget _rowMenu(BuildContext context, AppState app, Track t, int i) =>
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 20),
        tooltip: 'Track actions',
        onSelected: (v) async {
          switch (v) {
            case 'remove':
              await app.removeFromQueue(i);
            case 'playlist':
              await addToPlaylistSheet(context, app, t);
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'playlist', child: Text('Add to playlist…')),
          PopupMenuItem(value: 'remove', child: Text('Remove from queue')),
        ],
      );

  Future<void> _saveAsPlaylist(BuildContext context, AppState app) async {
    final q = app.activeQueue;
    if (q == null) return;
    final name = await promptForName(context, 'Save queue as playlist', q.name);
    if (name == null) return;
    await app.api.saveQueueAsPlaylist(q.id, name: name);
    await app.refreshPlaylists();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved "$name"')));
    }
  }

  Future<void> _deleteQueue(BuildContext context, AppState app) async {
    final q = app.activeQueue;
    if (q == null) return;
    final ok = await confirm(context, 'Delete "${q.name}"?',
        'The tracks stay in your library.');
    if (!ok) return;
    await app.api.deleteQueue(q.id);
    app.activeQueue = null;
    await app.refresh();
  }

  Future<void> _newQueue(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New queue'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Gym, Sleep, Focus…'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final app = context.read<AppState>();
    final q = await app.ensureQueue(name.trim());
    await app.refresh();
    await app.openQueue(q.id);
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.queue_music, size: 48),
            const SizedBox(height: 12),
            Text('Nothing queued', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Search for something and add it here.',
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
