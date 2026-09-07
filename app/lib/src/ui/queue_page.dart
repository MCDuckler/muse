import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';

/// Queues are the product, so this screen shows them all, not just the one playing.
class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final active = app.activeQueue;

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
          child: active == null || active.items.isEmpty
              ? const _EmptyQueue()
              : ListView.builder(
                  itemCount: active.items.length,
                  itemBuilder: (context, i) {
                    final t = active.items[i];
                    final isCurrent = i == (app.player?.index ?? -1);
                    return ListTile(
                      selected: isCurrent,
                      leading: _leading(t, i, isCurrent),
                      title: Text(t.title,
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
                      onTap: t.isReady ? () => app.player?.playAt(i) : null,
                    );
                  },
                ),
        ),
        if (active != null && active.items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
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
          width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (t.state == 'failed') return const Icon(Icons.error_outline);
    if (isCurrent) return const Icon(Icons.equalizer);
    return SizedBox(width: 24, child: Center(child: Text('${i + 1}')));
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
