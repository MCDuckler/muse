import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/offline.dart';
import '../state/player.dart';
import 'dialogs.dart';
import 'feel.dart';
import 'mini_player.dart' show PlayerScaffold;
import 'song_row.dart';
import 'station.dart';
import 'track_menu.dart';
import 'swipe.dart';
import '../state/selection.dart';
import 'face.dart';
import 'selection_bar.dart';
import 'artwork.dart';
import 'snack.dart';
import 'widths.dart';
import 'record_refresh.dart';

/// The queue as a page of its own: Up next.
///
/// It was a tab, the first one, which put the machinery at the front of the app and
/// made the queue the thing you opened it onto. It belongs to what is playing — it is
/// what plays after this — so it opens from the player, from the bar in the dock, from
/// the cover's line about the queue you left, and from the palette, and closes back to
/// wherever you were.
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) => const PlayerScaffold(
        appBar: _UpNextBar(),
        body: QueuePage(),
      );
}

class _UpNextBar extends StatelessWidget implements PreferredSizeWidget {
  const _UpNextBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => AppBar(title: const Text('Up next'));
}

/// Open Up next on whichever navigator is nearest: over the player when it is asked
/// for from the player, inside the tab when it is asked for from a page.
Future<void> openQueueScreen(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute(builder: (_) => const QueueScreen()));

/// Queues are the product, so this screen shows them all, not just the one playing.
class QueuePage extends StatefulWidget {
  const QueuePage({super.key});

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  final _scroll = ScrollController();
  int? _followed;

  /// Whether the song playing is somewhere in view, as of the last look. When it is
  /// not, a small pill offers the way back to it.
  bool _playingInView = true;

  /// Which way the playing row is from here, for the pill's arrow.
  bool _playingIsBelow = false;

  /// How many playing rows are on the tree — one or none, except for the moment a
  /// track changes, when the new row is built before the old one is let go of. A
  /// count survives that order; a flag set by the last of the two did not.
  int _playingRowsMounted = 0;

  /// The playing row saying it has arrived on the tree or left it. A lazy list only
  /// holds what is near the viewport, so this is the same as "is it near the screen"
  /// — and unlike a scroll event, it arrives *after* the frame that took it away.
  void _playingRowIs({required bool mounted}) {
    _playingRowsMounted += mounted ? 1 : -1;
    // Told from inside another widget's lifecycle, so the look waits for the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _lookForThePlayingRow());
  }

  void _lookForThePlayingRow() {
    if (!mounted) return;
    final built = _playingRowsMounted > 0;
    var below = _playingIsBelow;
    if (!built && _scroll.hasClients) {
      final index = context.read<AppState>().player?.index ?? 0;
      below = index * _rowExtent > _scroll.offset;
    }
    if (built == _playingInView && below == _playingIsBelow) return;
    setState(() {
      _playingInView = built;
      _playingIsBelow = below;
    });
  }

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

    // Follow the music — but only while you are watching it.
    //
    // When the track changes, the list used to scroll to it whatever you were doing:
    // half way down a long queue, looking for something to put on next, and the song
    // ends and the list is somewhere else. So it follows only when the song that just
    // finished was in view — which is what "following" means — and otherwise leaves
    // you where you are and offers the way back on a pill.
    final playing = app.player?.index;
    if (playing != null && playing != _followed && rows.isNotEmpty) {
      // Read before the list rebuilds: the key still sits on the row that was
      // playing a moment ago, so this is whether *that* row was near the screen.
      final wasWatching = _followed == null || _currentRow.currentContext != null;
      _followed = playing;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (wasWatching) _scrollToCurrent(animate: _followed != null);
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
                    // Hold a queue for what can be done to it: a new name, or gone.
                    // Queues accumulate — a name for every evening — and until now
                    // they could be deleted and never renamed.
                    onLongPress: q.sharedFrom != null
                        ? null
                        : () => _queueMenu(context, q),
                    child: ChoiceChip(
                      // A jam's queue is somebody else's, and saying whose is the
                      // difference between "why is this here" and "that is the one we
                      // are listening to together". The one making the sound wears
                      // the bars, so switching queues to look at another one still
                      // shows which is playing.
                      avatar: q.sharedFrom != null
                          ? const Icon(Icons.people_outline, size: 16)
                          : q.id == active?.id && app.musicIsPlaying
                              ? Icon(Icons.graphic_eq,
                                  size: 16,
                                  color: Theme.of(context).colorScheme.primary)
                              : null,
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
                // Plain buttons, with colour kept for the one that is a state. Three
                // tinted discs side by side said "on" about shuffle and "jump to what
                // is playing", which are actions, and made repeat — the only switch
                // among them — look like the one that was disabled.
                IconButton(
                  icon: const Icon(Icons.shuffle),
                  tooltip: 'Shuffle what is coming',
                  onPressed: felt(Feel.tap, app.shuffleWhatIsComing),
                ),
                Builder(builder: (context) {
                  final repeat = app.player?.repeat ?? QueueRepeat.off;
                  final on = repeat != QueueRepeat.off;
                  return IconButton(
                    isSelected: on,
                    style: on
                        ? IconButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.18),
                            foregroundColor:
                                Theme.of(context).colorScheme.primary)
                        : null,
                    icon: Icon(
                        repeat == QueueRepeat.one ? Icons.repeat_one : Icons.repeat),
                    tooltip: switch (repeat) {
                      QueueRepeat.off => 'Repeat off',
                      QueueRepeat.all => 'Repeat queue',
                      QueueRepeat.one => 'Repeat track',
                    },
                    onPressed: felt(Feel.pick, app.cycleRepeat),
                  );
                }),
                IconButton(
                  icon: const Icon(Icons.my_location),
                  tooltip: 'Jump to what is playing',
                  onPressed: () => _scrollToCurrent(),
                ),
                Expanded(
                  child: _TimeLeft(
                    rows: rows,
                    at: app.player?.index ?? 0,
                    queue: active,
                    whereInQueue: app.player?.whereInQueue ?? 0,
                  ),
                ),
                // A station from whatever is playing: the song becomes the seed, and
                // the queue it makes is its own — named, saveable, and topped up as it
                // is listened through. The button this replaces added five songs to
                // the end of the queue you were already on and called it radio.
                //
                // With its word where there is room for one, and as an icon where
                // there is not: three buttons, this and the menu overflowed a phone
                // by twenty pixels, which in a release build is a button cut off.
                if (MediaQuery.sizeOf(context).width >= 430)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.radio, size: 18),
                    label: Text(active.isStation ? 'New station' : 'Station'),
                    onPressed: () =>
                        startStation(context, seed: app.player?.current),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.radio),
                    tooltip: active.isStation
                        ? 'New station from this song'
                        : 'Start a station from this song',
                    onPressed: () =>
                        startStation(context, seed: app.player?.current),
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
                      case 'rename':
                        await _renameQueue(context, active);
                      case 'make-station':
                        await startStation(context,
                            seed: app.player?.current, play: false);
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
                    if (app.player?.current != null)
                      const PopupMenuItem(
                          value: 'make-station',
                          child: Text('Make a station from this song, without playing it')),
                    if (active.isStation)
                      const PopupMenuItem(
                          value: 'keep-station',
                          child: Text('Keep this station')),
                    const PopupMenuItem(value: 'rename', child: Text('Rename…')),
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
                return RecordRefresh(
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
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ReorderableListView.builder(
                  scrollController: _scroll,
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
                  itemCount: rows.length,
                  buildDefaultDragHandles: false,
                  // A row lifting out of a list and dropping back into it: the two
                  // moments a finger is holding something that is not where it was.
                  onReorderStart: (i) {
                    feel(Feel.pick);
                    setState(() => _dragging = i);
                  },
                  onReorderEnd: (_) {
                    feel(Feel.tap);
                    setState(() => _dragging = null);
                  },
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
                        // The same back every other row uncovers, hearing the drag
                        // through the Pushable around it.
                        background: const SwipeBack(
                          away: true,
                          icon: Icons.delete_outline,
                          label: 'Remove',
                        ),
                        onDismissed: (_) => app.removeFromQueue(i, context: context),
                        onUpdate: (d) => report(d.progress),
                        // Hold the row to move it. A permanent handle took the place the
                        // artwork belongs in, and a queue of small grey grips tells you
                        // less at a glance than a queue of records does.
                        child: row,
                        ),
                      child: _Sighted(
                        // Only the playing row reports; the page counts.
                        onSeen: isCurrent ? _playingRowIs : null,
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
                        queuePosition: i,
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
                        // Every row answers a tap. A song still on its way is chosen
                        // and waited for — the player parks on it and starts it the
                        // moment it lands — where before the row was simply dead. A
                        // failed one opens its menu, which is where "try again" is.
                        onTap: t.state == 'failed'
                            ? () => showTrackSheet(context, t,
                                onRemove: () =>
                                    app.removeFromQueue(i, context: context),
                                onChanged: app.refresh,
                                queuePosition: i)
                            : () async {
                                try {
                                  await app.player?.playTrack(t.id, indexHint: i);
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).say(
                                        snack(Text('$e')));
                                  }
                                }
                              },
                      ),
                      ),
                    );
                  },
                ),
                            ),
                            // The way back to what is playing, when it has scrolled
                            // out of sight. Over the list rather than in the row of
                            // buttons above it: it is only worth anything at the
                            // moment the song cannot be seen.
                            if (!_playingInView && app.player?.current != null)
                              Positioned(
                                left: 0,
                                right: 0,
                                // Above whatever is floating over the bottom of the
                                // list — the player and the tabs, on the home screen.
                                bottom: MediaQuery.paddingOf(context).bottom + 14,
                                child: Center(
                                  child: _NowPlayingPill(
                                    track: app.player!.current!,
                                    below: _playingIsBelow,
                                    onTap: () => _scrollToCurrent(),
                                  ),
                                ),
                              ),
                          ],
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

  /// What can be done to a queue from its chip.
  Future<void> _queueMenu(BuildContext context, Queue queue) async {
    feel(Feel.commit);
    final app = context.read<AppState>();
    await ask<void>(
      context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(queue.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheet).textTheme.titleMedium),
              subtitle: Text(
                  '${queue.itemCount} ${queue.itemCount == 1 ? 'song' : 'songs'}'),
            ),
            const Divider(height: 1),
            if (queue.id != app.activeQueue?.id)
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Switch to this queue'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  app.openQueue(queue.id);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename…'),
              onTap: () {
                Navigator.of(sheet).pop();
                _renameQueue(context, queue);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete this queue'),
              onTap: () {
                Navigator.of(sheet).pop();
                _deleteQueue(context, queue);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameQueue(BuildContext context, Queue queue) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final name = await promptForName(context, 'Rename queue', queue.name);
    if (name == null || name == queue.name) return;
    try {
      await app.renameQueue(queue.id, name);
    } catch (e) {
      messenger.say(snack(Text('$e')));
    }
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
          .say(snack(Text('Saved "$name"')));
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
      messenger.say(snack(Text('Deleted "${queue.name}"')));
    } catch (e) {
      messenger.say(snack(Text('$e')));
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
            const SizedBox(height: 16),
            // The sentence above used to be the whole of it: told where to go and
            // left to find the way. This is the way.
            FilledButton.tonalIcon(
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Search for music'),
              onPressed: () {
                // Out of Up next first: it is a page over the tabs now, and a tab
                // changed behind it is a change nobody sees.
                Navigator.of(context).popUntil((r) => r.isFirst);
                context.read<AppState>().setHomeTab(Tabs.search);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// How much of the queue is still to come.
///
/// The one fact about a queue nothing showed: whether it lasts the run, the drive, the
/// evening. Songs whose length is not known yet are left out of the sum rather than
/// guessed at.
class _TimeLeft extends StatelessWidget {
  const _TimeLeft(
      {required this.rows,
      required this.at,
      required this.queue,
      required this.whereInQueue});
  final List<Track> rows;
  final int at;
  final Queue queue;
  final int whereInQueue;

  static String _span(Duration d) {
    final h = d.inHours, m = d.inMinutes.remainder(60);
    if (h == 0) return '${m < 1 ? '<1' : m} min';
    return m == 0 ? '$h h' : '$h h $m min';
  }

  @override
  Widget build(BuildContext context) {
    final String said;
    final String detail;
    if (queue.windowed) {
      // Only a slice is here, so the minutes cannot be added up — the count can.
      final left = (queue.total - whereInQueue - 1).clamp(0, queue.total);
      said = left == 0 ? 'Last song' : '$left to go';
      detail = '$left of ${queue.total} songs still to come';
    } else {
      final after = rows.skip(at + 1);
      final left = after.length;
      final time = after.fold<Duration>(
          Duration.zero, (sum, t) => sum + (t.duration ?? Duration.zero));
      said = left == 0 ? 'Last song' : '${_span(time)} left';
      detail = left == 0
          ? 'Nothing after this one'
          : '$left ${left == 1 ? 'song' : 'songs'} after this one · ${_span(time)}';
    }
    return Tooltip(
      message: detail,
      child: Text(
        said,
        textAlign: TextAlign.end,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// A row that says when it is on the tree and when it has left it.
///
/// Given no [onSeen] it is nothing but its child, so the rows that are not playing
/// cost nothing for it.
class _Sighted extends StatefulWidget {
  const _Sighted({required this.child, this.onSeen});
  final Widget child;
  final void Function({required bool mounted})? onSeen;

  @override
  State<_Sighted> createState() => _SightedState();
}

class _SightedState extends State<_Sighted> {
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    _say(true);
  }

  @override
  void didUpdateWidget(_Sighted old) {
    super.didUpdateWidget(old);
    // The row stopped being the playing one — or started — without leaving the tree.
    if ((old.onSeen == null) != (widget.onSeen == null)) {
      if (widget.onSeen == null) {
        old.onSeen?.call(mounted: false);
        _reported = false;
      } else {
        _say(true);
      }
    }
  }

  void _say(bool mounted) {
    if (widget.onSeen == null || _reported == mounted) return;
    _reported = mounted;
    widget.onSeen!(mounted: mounted);
  }

  @override
  void dispose() {
    if (_reported) widget.onSeen?.call(mounted: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The song playing, offered from wherever the list has been scrolled to.
class _NowPlayingPill extends StatelessWidget {
  const _NowPlayingPill(
      {required this.track, required this.below, required this.onTap});
  final Track track;
  final bool below;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      elevation: 4,
      borderRadius: BorderRadius.circular(100),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: felt(Feel.tap, onTap),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 14, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(below ? Icons.arrow_downward : Icons.arrow_upward,
                  size: 16, color: scheme.onPrimaryContainer),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  track.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: scheme.onPrimaryContainer),
                ),
              ),
            ],
          ),
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
