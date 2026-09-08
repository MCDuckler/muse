import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/player.dart';
import 'artwork.dart';

/// What is playing next.
///
/// The now-playing screen exists to answer "what is this", and could not answer "what
/// comes after it" — the most conspicuous omission in the app. This is the queue in
/// context: the current track pinned at the top, everything after it in order, tap to
/// jump, drag to reorder, swipe to remove.
Future<void> showUpNext(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _UpNextSheet(),
  );
}

class _UpNextSheet extends StatelessWidget {
  const _UpNextSheet();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = app.player;
    if (player == null) return const SizedBox.shrink();

    return StreamBuilder<PlayerSnapshot>(
      stream: player.snapshots,
      initialData: player.last,
      builder: (context, _) {
        final items = player.items;
        final current = player.index;
        // Only what is still to come: a list of everything already played is a
        // history, and there is a screen for that.
        final upcoming = <int>[
          for (var i = current + 1; i < items.length; i++) i,
        ];

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (context, controller) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(app.activeQueue?.name ?? 'Queue',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    Text(
                      upcoming.isEmpty
                          ? 'Nothing after this'
                          : '${upcoming.length} to come',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (current >= 0 && current < items.length)
                _Row(track: items[current], index: current, isCurrent: true),
              const Divider(height: 12),
              Expanded(
                child: upcoming.isEmpty
                    ? _Empty(onSearch: () => Navigator.of(context).pop())
                    : ReorderableListView.builder(
                        scrollController: controller,
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: upcoming.length,
                        buildDefaultDragHandles: false,
                        onReorderItem: (from, to) => app.moveInQueue(
                            upcoming[from], upcoming[to.clamp(0, upcoming.length - 1)]),
                        itemBuilder: (context, i) => _Row(
                          key: ValueKey('up-${items[upcoming[i]].id}-${upcoming[i]}'),
                          track: items[upcoming[i]],
                          index: upcoming[i],
                          reorderIndex: i,
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.track,
    required this.index,
    this.isCurrent = false,
    this.reorderIndex,
  });

  final Track track;
  final int index;
  final bool isCurrent;
  final int? reorderIndex;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;

    final tile = ListTile(
      selected: isCurrent,
      leading: Artwork(track: track, size: 40),
      title: Text(track.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: isCurrent ? TextStyle(color: scheme.primary) : null),
      subtitle: Text(track.statusLine,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: track.state == 'failed' ? TextStyle(color: scheme.error) : null),
      trailing: isCurrent
          ? Icon(Icons.equalizer, size: 20, color: scheme.primary)
          : (track.origin == 'radio'
              ? const Chip(label: Text('radio'), visualDensity: VisualDensity.compact)
              : null),
      onTap: track.isReady
          ? () => app.player?.playTrack(track.id, indexHint: index)
          : null,
    );

    if (isCurrent || reorderIndex == null) return tile;
    return ReorderableDelayedDragStartListener(
      index: reorderIndex!,
      child: Dismissible(
        key: ValueKey('dismiss-${track.id}-$index'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          color: scheme.errorContainer,
          child: const Icon(Icons.delete_outline),
        ),
        onDismissed: (_) => app.removeFromQueue(index, context: context),
        child: tile,
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onSearch});
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.playlist_add, size: 40),
              const SizedBox(height: 10),
              Text('Nothing queued after this',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('Start radio, or add something from search.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
}
