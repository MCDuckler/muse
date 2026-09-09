import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/player.dart';
import 'dialogs.dart';
import 'song_row.dart';

/// Queues are the product, so this screen shows them all, not just the one playing.
class QueuePage extends StatefulWidget {
  const QueuePage({super.key});

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  final _scroll = ScrollController();
  int? _followed;

  /// Rows are close enough to a fixed height for scrolling maths; a row that is
  /// downloading grows by the progress bar, which is a few pixels of drift at worst.
  /// What one row is worth when scrolling to the song being played. It is the height
  /// SongRow draws at in its dense form — a ListTile's 72 was left behind here when the
  /// rows got shorter, and scrolling to "the current track" quietly landed a screen
  /// further down the longer the queue was.
  static const _rowExtent = 56.0;

  void _scrollToCurrent({bool animate = true}) {
    if (!_scroll.hasClients) return;
    final app = context.read<AppState>();
    final index = app.player?.index ?? 0;
    final target = (index * _rowExtent - 120)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if (animate) {
      _scroll.animateTo(target,
          duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    } else {
      _scroll.jumpTo(target);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final active = app.activeQueue;
    // The rows come from the player, not from the queue object: they used to come
    // from different places, so the highlight could sit on the wrong track after a
    // radio append or a change from another device.
    final rows = app.player?.items ?? const <Track>[];

    // Follow the music: when the track changes on its own, bring it into view rather
    // than leaving the person to hunt for it in an eighteen-track queue.
    final playing = app.player?.index;
    if (playing != null && playing != _followed && rows.isNotEmpty) {
      _followed = playing;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToCurrent();
      });
    }

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
                    // A jam's queue is somebody else's, and saying whose is the
                    // difference between "why is this here" and "that is the one we
                    // are listening to together".
                    avatar: q.sharedFrom == null
                        ? null
                        : const Icon(Icons.people_outline, size: 16),
                    label: Text(q.sharedFrom == null
                        ? '${q.name} · ${q.itemCount}'
                        : "${q.sharedFrom}'s jam · ${q.itemCount}"),
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
                IconButton.filledTonal(
                  icon: const Icon(Icons.my_location),
                  tooltip: 'Jump to what is playing',
                  onPressed: () => _scrollToCurrent(),
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
                        await app.clearQueue(origin: 'radio', context: context);
                      case 'clear':
                        await app.clearQueue(context: context);
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
              : RefreshIndicator(
                  onRefresh: app.refresh,
                  child: ReorderableListView.builder(
                  scrollController: _scroll,
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
                      onDismissed: (_) => app.removeFromQueue(i, context: context),
                      // Hold the row to move it. A permanent handle took the place the
                      // artwork belongs in, and a queue of small grey grips tells you
                      // less at a glance than a queue of records does.
                      child: ReorderableDelayedDragStartListener(
                        index: i,
                        child: SongRow(
                        track: t,
                        selected: isCurrent,
                        dense: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (t.origin == 'radio')
                              Padding(
                                padding: const EdgeInsets.only(right: 2),
                                child: Text('radio',
                                    style: Theme.of(context).textTheme.labelSmall
                                        ?.copyWith(color:
                                            Theme.of(context).colorScheme.outline)),
                              ),
                            if (t.state == 'failed')
                              IconButton(
                                icon: const Icon(Icons.refresh, size: 18),
                                visualDensity: VisualDensity.compact,
                                tooltip: 'Try again',
                                onPressed: () => app.retry(t),
                              ),
                          ],
                        ),
                        onRemove: () => app.removeFromQueue(i, context: context),
                        onChanged: app.refresh,
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
        ),
      ],
    );
  }

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
