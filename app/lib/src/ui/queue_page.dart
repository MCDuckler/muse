import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/offline.dart';
import '../state/player.dart';
import 'dialogs.dart';
import 'song_row.dart';
import 'station.dart';
import 'swipe.dart';
import '../state/selection.dart';
import 'face.dart';
import 'selection_bar.dart';
import 'artwork.dart';
import 'snack.dart';

/// Queues are the product, so this screen shows them all, not just the one playing.
class QueuePage extends StatefulWidget {
  const QueuePage({super.key});

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  final _scroll = ScrollController();
  int? _followed;

  /// The row being dragged, while one is. Everything else that is selected folds away
  /// behind it for the length of the drag — see the itemBuilder.
  int? _dragging;

  /// Rows are close enough to a fixed height for scrolling maths; a row that is
  /// downloading grows by the progress bar, which is a few pixels of drift at worst.
  /// What one row is worth when scrolling to the song being played. It is the height
  /// SongRow draws at in its dense form — a ListTile's 72 was left behind here when the
  /// rows got shorter, and scrolling to "the current track" quietly landed a screen
  /// further down the longer the queue was.
  static const _rowExtent = 48.0;

  /// The row that is playing, when it happens to be built. A lazy list only builds what
  /// is on screen, so this is null exactly when the estimate below is needed.
  final _currentRow = GlobalKey();

  /// Bring the song that is playing into view.
  ///
  /// Two steps, because neither alone is right. The row height is an estimate — a row
  /// downloading is taller — so scrolling by arithmetic lands near the track rather
  /// than on it, and in a long queue "near" is off the screen. Once the estimate has
  /// put the row into the tree, the row itself can say where it is, which is exact.
  Future<void> _scrollToCurrent({bool animate = true}) async {
    if (!_scroll.hasClients) return;
    final app = context.read<AppState>();
    final index = app.player?.index ?? 0;

    final exact = _currentRow.currentContext;
    if (exact != null) {
      await Scrollable.ensureVisible(exact,
          alignment: 0.3,
          duration: animate ? const Duration(milliseconds: 320) : Duration.zero,
          curve: Curves.easeOutCubic);
      return;
    }

    final target = (index * _rowExtent - 120)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if (animate) {
      await _scroll.animateTo(target,
          duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    } else {
      _scroll.jumpTo(target);
    }
    // Now that it is built, land on it properly.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final built = _currentRow.currentContext;
    if (built != null && built.mounted) {
      await Scrollable.ensureVisible(built,
          alignment: 0.3, duration: const Duration(milliseconds: 180));
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
                  child: GestureDetector(
                    // Hold a queue to get rid of it. Queues accumulate — a name for
                    // every evening — and until now the only way to lose one was the
                    // terminal.
                    onLongPress: q.sharedFrom != null
                        ? null
                        : () => _deleteQueue(context, q),
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
                  icon: const Icon(Icons.shuffle),
                  tooltip: 'Shuffle what is coming',
                  onPressed: app.shuffleWhatIsComing,
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
                // A station from whatever is playing: the song becomes the seed, and
                // the queue it makes is its own — named, saveable, and topped up as it
                // is listened through. The button this replaces added five songs to
                // the end of the queue you were already on and called it radio.
                OutlinedButton.icon(
                  icon: const Icon(Icons.radio, size: 18),
                  label: Text(active.isStation ? 'New station' : 'Station'),
                  onPressed: () => startStation(context, seed: app.player?.current),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Queue actions',
                  onSelected: (v) async {
                    switch (v) {
                      case 'keep':
                        await app.keepOffline(rows);
                      case 'forget':
                        for (final t in rows) {
                          await app.forgetOffline(t.id);
                        }
                      case 'clear-radio':
                        await app.clearQueue(origin: 'radio', context: context);
                      case 'clear':
                        await app.clearQueue(context: context);
                      case 'save':
                        await _saveAsPlaylist(context, app);
                      case 'keep-station':
                        await keepStation(context);
                      case 'delete':
                        if (app.activeQueue != null) {
                          await _deleteQueue(context, app.activeQueue!);
                        }
                    }
                  },
                  itemBuilder: (context) => [
                    if (OfflineStore.supported) ...const [
                      PopupMenuItem(
                          value: 'keep', child: Text('Keep this queue on the device')),
                      PopupMenuItem(
                          value: 'forget', child: Text('Stop keeping these here')),
                      PopupMenuDivider(),
                    ],
                    if (active.isStation)
                      const PopupMenuItem(
                          value: 'keep-station',
                          child: Text('Keep this station')),
                    const PopupMenuItem(
                        value: 'save', child: Text('Save as playlist')),
                    const PopupMenuItem(
                        value: 'clear-radio', child: Text('Clear radio tracks')),
                    const PopupMenuItem(value: 'clear', child: Text('Clear queue')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                        value: 'delete', child: Text('Delete this queue')),
                  ],
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: SelectionOver(
            bar: active == null
                ? const SizedBox.shrink()
                : SelectionBar(
            where: 'queue:${active.id}',
            tracks: rows,
            removeLabel: 'Remove from queue',
            onRemove: (picked) async {
              // Backwards, so removing one row does not shift the next one out from
              // under the position we are about to remove.
              final byId = {for (var i = 0; i < rows.length; i++) rows[i].id: i};
              final positions = [
                for (final t in picked)
                  if (byId.containsKey(t.id)) byId[t.id]!
              ]..sort();
              for (final pos in positions.reversed) {
                await app.removeFromQueue(pos);
              }
            },
          ),
          child: active == null || rows.isEmpty
              ? const _EmptyQueue()
              : Builder(builder: (context) {
                // Worked out once for the whole list rather than once per row.
                //
                // It is a scan of the queue, and it was being run for every row built
                // and again for every proxy drawn — on a mirrored library of thirteen
                // thousand songs that is a couple of hundred thousand comparisons a
                // frame while a selection is being dragged, to answer the same
                // question a dozen times.
                final picked = _pickedPositions(context, rows, active);
                final pickedSet = picked.toSet();
                return RefreshIndicator(
                  onRefresh: app.refresh,
                  child: Column(
                    children: [
                      // A queue of fourteen thousand songs is carried a few hundred
                      // rows at a time — see Queue.windowed — and saying so is better
                      // than a list that mysteriously stops.
                      if (active.windowed)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
                          child: Row(
                            children: [
                              Icon(Icons.unfold_more,
                                  size: 14,
                                  color: Theme.of(context).colorScheme.outline),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '${rows.length} of ${active.total} songs — the part '
                                  'around where you are',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .outline),
                                ),
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: ReorderableListView.builder(
                  scrollController: _scroll,
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
                  itemCount: rows.length,
                  buildDefaultDragHandles: false,
                  onReorderStart: (i) => setState(() => _dragging = i),
                  onReorderEnd: (_) => setState(() => _dragging = null),
                  // While a selection is being dragged, the rest of it is drawn as one
                  // row: a stack of sleeves with a count on it, rather than a dozen
                  // rows sliding about independently.
                  proxyDecorator: (child, index, animation) {
                    if (picked.length < 2 || !pickedSet.contains(index)) {
                      return Material(color: Colors.transparent, child: child);
                    }
                    return Material(
                      elevation: 6,
                      borderRadius: BorderRadius.circular(10),
                      child: _DraggedBundle(
                          tracks: [for (final p in picked) rows[p]]),
                    );
                  },
                  // onReorderItem, not onReorder: it hands over the index the row
                  // actually lands on, rather than one measured before the row was
                  // lifted out, which is an off-by-one waiting to happen.
                  onReorderItem: (from, to) {
                    if (picked.length > 1 && pickedSet.contains(from)) {
                      app.moveManyInQueue(picked, to);
                    } else {
                      app.moveInQueue(from, to);
                    }
                  },
                  itemBuilder: (context, i) {
                    final t = rows[i];
                    final isCurrent = i == (app.player?.index ?? -1);
                    // Folded away behind the row being dragged.
                    if (_dragging != null &&
                        i != _dragging &&
                        picked.length > 1 &&
                        pickedSet.contains(i) &&
                        pickedSet.contains(_dragging!)) {
                      return SizedBox(key: ValueKey('folded-${t.id}-$i'), height: 0);
                    }
                    // Built once and handed through: pushing the row about does not
                    // rebuild it, only the grip inside it, which fades out of the way
                    // while it moves. See SwipingNow.
                    return Pushable(
                      key: ValueKey('row-${t.id}-$i'),
                      // The key belongs on whatever the list itself is handed:
                      // ReorderableListView reads it off the top of each item, and
                      // without one it throws — which in a release build is a grey
                      // rectangle where the queue should be.
                      builder: (context, row, report) => Dismissible(
                        key: ValueKey('${t.id}-$i'),
                        // The playing row carries a key, so "jump to what is playing"
                        // can ask it where it is instead of guessing from a row height.
                        dragStartBehavior: DragStartBehavior.start,
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
                        onUpdate: (d) => report(d.progress),
                        // Hold the row to move it. A permanent handle took the place the
                        // artwork belongs in, and a queue of small grey grips tells you
                        // less at a glance than a queue of records does.
                        child: row,
                        ),
                      child: SongRow(
                        key: isCurrent ? _currentRow : null,
                        track: t,
                        selected: isCurrent,
                        dense: true,
                        // Whose song this is, but only where that is a question: on
                        // your own queue everything is yours, and a row of identical
                        // faces says nothing.
                        corner: app.jam == null || t.addedBy == null
                            ? null
                            : Tooltip(
                                message: 'Added by ${t.addedBy}',
                                child: Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Theme.of(context).colorScheme.surface,
                                  ),
                                  padding: const EdgeInsets.all(1.5),
                                  child: Face(
                                    name: t.addedBy,
                                    userId: t.addedById,
                                    version: t.addedByAvatar,
                                    size: 18,
                                  ),
                                ),
                              ),
                        // The queue's sideways drag takes a row out; a song already in
                        // the queue has nothing to be added to.
                        swipeToPlayNext: false,
                        selectable: 'queue:${active.id}',
                        handle: ReorderableDragStartListener(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 2, right: 2),
                            child: Icon(Icons.drag_indicator,
                                size: 18,
                                color: Theme.of(context).colorScheme.outline),
                          ),
                        ),
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
                                        snack(Text('$e')));
                                  }
                                }
                              }
                            : null,
                      ),
                    );
                  },
                ),
                      ),
                    ],
                  ),
                );
              }),
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
          .showSnackBar(snack(Text('Saved "$name"')));
    }
  }

  /// Which rows of this queue are picked out, as positions in the list.
  List<int> _pickedPositions(BuildContext context, List<Track> rows, Queue? active) {
    if (active == null) return const [];
    final selection = context.read<Selection>();
    if (!selection.inside('queue:${active.id}')) return const [];
    return [
      for (var i = 0; i < rows.length; i++)
        if (selection.has(rows[i].id)) i
    ];
  }

  Future<void> _deleteQueue(BuildContext context, Queue queue) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final gone = await confirm(context, 'Delete "${queue.name}"?',
        queue.itemCount == 0
            ? 'It is empty, so there is nothing in it to lose.'
            : 'The ${queue.itemCount} songs in it stay in your library; only the '
                'queue goes.');
    if (!gone) return;
    try {
      await app.deleteQueue(queue.id);
      messenger.showSnackBar(snack(Text('Deleted "${queue.name}"')));
    } catch (e) {
      messenger.showSnackBar(snack(Text('$e')));
    }
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


/// Several songs being dragged, drawn as one thing.
///
/// Dragging eleven rows as eleven rows is unreadable and janky; a small stack of their
/// sleeves with the count on it says the same thing and moves as one object.
class _DraggedBundle extends StatelessWidget {
  const _DraggedBundle({required this.tracks});
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = tracks.take(3).toList();
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40 + (shown.length - 1) * 8,
            height: 40,
            child: Stack(
              children: [
                for (var i = shown.length - 1; i >= 0; i--)
                  Positioned(
                    left: i * 8,
                    child: Artwork(track: shown[i], size: 40, radius: 5),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text('${tracks.length} songs',
              style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          Icon(Icons.drag_indicator, color: scheme.outline),
        ],
      ),
    );
  }
}
