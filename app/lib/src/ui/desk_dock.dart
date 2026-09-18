import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/player.dart';
import 'artwork.dart';
import 'now_playing.dart';

/// The column beside the page: what is playing, and what is next.
///
/// A phone has one screen and everything takes turns on it; a desk has room for the
/// record to stay visible while you are reading a playlist, which is the whole reason
/// to use the app on a desk at all. So the two things that were behind a full-screen
/// route — the player, and the queue — fold out down the right-hand side, and fold
/// away again when the page wants the width.
class DeskDock extends StatelessWidget {
  const DeskDock({super.key, required this.open, required this.onClose});

  final bool open;
  final VoidCallback onClose;

  /// How wide it is when it is out. Narrow enough that the page keeps the screen and
  /// wide enough for a record, a title that is not cut in half, and a row of buttons.
  static const width = 340.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Animated by width rather than slid over the page: the page should end where the
    // dock begins, not disappear under it — a list half-covered by a panel is a list
    // with its right-hand column missing.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: open ? width : 0,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerRight,
          minWidth: width,
          maxWidth: width,
          child: SafeArea(
            left: false,
            // Two cards rather than one wall: what is playing and what is next are two
            // different things, and a panel with a corner on it reads as something
            // laid on the page rather than as the page having run out.
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 10, 10),
              child: Column(
                children: [
                  // What is playing, which is the thing people keep an eye on.
                  Expanded(
                    flex: 3,
                    child: _Panel(
                      colour: scheme.surfaceContainerLow,
                      child: SingleChildScrollView(
                        child: DeskNowPlaying(onClose: onClose),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // And what is coming, which is the thing they keep checking.
                  Expanded(
                    flex: 2,
                    child: _Panel(
                      colour: scheme.surfaceContainerLow,
                      child: const _NextUp(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One of the two cards in the column.
class _Panel extends StatelessWidget {
  const _Panel({required this.child, required this.colour});
  final Widget child;
  final Color colour;

  @override
  Widget build(BuildContext context) => Material(
        color: colour,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(18),
        child: child,
      );
}

/// The next few songs, in the space under the record.
///
/// Not the queue screen: that one is for rearranging a few hundred rows, and this is
/// for answering "what is after this" without leaving the page you are on. Five or six
/// rows, the one playing at the top, and a way through to the real thing.
class _NextUp extends StatelessWidget {
  const _NextUp();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = app.player;
    final queue = app.activeQueue;
    final text = Theme.of(context).textTheme;
    if (player == null || queue == null || queue.items.isEmpty) {
      return Center(child: Text('Nothing queued', style: text.bodySmall));
    }

    return StreamBuilder<PlayerSnapshot>(
      stream: player.changes,
      initialData: player.last,
      builder: (context, snap) {
        final at = snap.data?.index ?? 0;
        final rest = <({Track track, int index, bool playing})>[
          for (var i = at; i < queue.items.length && i < at + 40; i++)
            (track: queue.items[i], index: i, playing: i == at),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 6, 2),
              child: Row(
                children: [
                  Expanded(child: Text('Next up', style: text.titleSmall)),
                  Text('${queue.items.length - at - 1} to come',
                      style: text.bodySmall),
                  IconButton(
                    icon: const Icon(Icons.queue_music, size: 18),
                    tooltip: 'Open the queue',
                    onPressed: () => app.setHomeTab(0),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: rest.length,
                itemBuilder: (context, i) {
                  final row = rest[i];
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    leading: Artwork(track: row.track, size: 32, radius: 4),
                    title: Text(row.track.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: row.playing
                            ? text.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.primary)
                            : text.bodyMedium),
                    subtitle: Text(row.track.artistLine,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => player.playTrack(row.track.id,
                        indexHint: row.index - player.windowFrom),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
