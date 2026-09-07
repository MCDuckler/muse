import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/player.dart';
import 'artwork.dart';

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
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
        const Divider(height: 1),
        Expanded(
          child: active == null || rows.isEmpty
              ? const _EmptyQueue()
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final t = rows[i];
                    final isCurrent = i == (app.player?.index ?? -1);
                    return ListTile(
                      selected: isCurrent,
                      leading: _leading(t, i, isCurrent),
                      title: Text(t.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: t.state == 'failed'
                                  ? Theme.of(context).colorScheme.error
                                  : null)),
                      subtitle: Text(
                        t.state == 'failed'
                            ? (t.failReason ?? 'Failed')
                            : t.isPending
                                ? 'Downloading…'
                                : t.artistLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: t.origin == 'radio'
                          ? const Chip(
                              label: Text('radio'),
                              visualDensity: VisualDensity.compact)
                          : null,
                      onTap: t.isReady
                          ? () async {
                              try {
                                await app.player?.playAt(i);
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('$e')));
                                }
                              }
                            }
                          : null,
                    );
                  },
                ),
        ),
        if (active != null && rows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
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
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.radio),
                    label: const Text('Start radio'),
                    onPressed: () => app.startRadio(),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _leading(Track t, int i, bool isCurrent) {
    if (t.isPending) {
      return const SizedBox(
          width: 40, height: 40,
          child: Center(
              child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))));
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
