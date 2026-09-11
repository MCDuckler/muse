import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/offline.dart';
import '../state/selection.dart';
import 'dialogs.dart';

/// What you can do to the songs you have picked out.
///
/// One bar, wherever a selection is running, so the answer to "how do I add these
/// eleven to a playlist" is the same on the queue, on a record and in a search. It is
/// on screen rather than in a menu, because it is also how you find out that a
/// selection is running at all — and how you end it.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.where,
    required this.tracks,
    this.onRemove,
    this.removeLabel = 'Remove',
  });

  /// Which list this bar belongs to; it draws nothing when the selection is elsewhere.
  final String where;

  /// Everything in the list, so "all" means all of it and the picked ids can be turned
  /// back into songs.
  final List<Track> tracks;

  /// What removing means here — out of the queue, off the playlist. Nothing when the
  /// list is not one you can take things out of.
  final Future<void> Function(List<Track> picked)? onRemove;
  final String removeLabel;

  @override
  Widget build(BuildContext context) {
    final selection = context.watch<Selection>();
    if (!selection.inside(where)) return const SizedBox.shrink();

    final app = context.read<AppState>();
    final byId = {for (final t in tracks) t.id: t};
    final picked = [for (final id in selection.ids) if (byId[id] != null) byId[id]!];
    final scheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);

    Future<void> done(String said) async {
      selection.clear();
      messenger.showSnackBar(SnackBar(content: Text(said)));
    }

    final all = picked.length == tracks.length;
    return Material(
      color: scheme.primaryContainer,
      // Floating, so it can be laid over the list rather than added above it — see
      // SelectionOver for why that matters.
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Stop selecting',
              onPressed: selection.clear,
            ),
            Expanded(
              child: Text('${picked.length} selected',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            IconButton(
              icon: Icon(all ? Icons.deselect : Icons.select_all),
              tooltip: all ? 'Select none' : 'Select all',
              onPressed: () => all
                  ? selection.clear()
                  : selection.selectAll(where, [for (final t in tracks) t.id]),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'Do something with these',
              onSelected: (choice) async {
                switch (choice) {
                  case 'next':
                    // Backwards, so the first one picked ends up first in the queue.
                    for (final t in picked.reversed) {
                      await app.addTrack(t, mode: 'next');
                    }
                    await done('${picked.length} playing next');
                  case 'queue':
                    for (final t in picked) {
                      await app.addTrack(t);
                    }
                    await done('${picked.length} added to the queue');
                  case 'playlist':
                    await addTracksToPlaylistSheet(context, app, picked);
                    selection.clear();
                  case 'favourite':
                    for (final t in picked) {
                      if (!app.isFavourite(t.id)) await app.toggleFavourite(t.id);
                    }
                    await done('${picked.length} in your favourites');
                  case 'unfavourite':
                    for (final t in picked) {
                      if (app.isFavourite(t.id)) await app.toggleFavourite(t.id);
                    }
                    await done('${picked.length} out of your favourites');
                  case 'keep':
                    await app.keepOffline(picked);
                    await done('${picked.length} being kept on this device');
                  case 'forget':
                    for (final t in picked) {
                      await app.forgetOffline(t.id);
                    }
                    await done('${picked.length} no longer kept here');
                  case 'remove':
                    final sure = await confirm(
                        context,
                        '$removeLabel ${picked.length} songs?',
                        'They stay in your library.');
                    if (!sure) return;
                    await onRemove!(picked);
                    await done('${picked.length} removed');
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'next', child: Text('Play next')),
                const PopupMenuItem(value: 'queue', child: Text('Add to queue')),
                const PopupMenuItem(
                    value: 'playlist', child: Text('Add to playlist…')),
                const PopupMenuItem(
                    value: 'favourite', child: Text('Add to favourites')),
                const PopupMenuItem(
                    value: 'unfavourite', child: Text('Remove from favourites')),
                if (OfflineStore.supported) ...[
                  const PopupMenuItem(
                      value: 'keep', child: Text('Keep on this device')),
                  const PopupMenuItem(
                      value: 'forget', child: Text('Stop keeping here')),
                ],
                if (onRemove != null)
                  PopupMenuItem(value: 'remove', child: Text(removeLabel)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A list with the selection bar over the bottom of it.
///
/// Over, not above. Putting the bar in the column pushed the whole list down by its
/// own height the instant a selection started — so holding a row to pick it out moved
/// that row out from under your finger, and everything you were about to pick with it
/// shifted at the same moment. The list is what you are working on; it should not move
/// because a control appeared.
///
/// The bottom of the list is where there is room for it: every one of these already
/// leaves a gap at the end for the player bar, so the bar covers nothing.
class SelectionOver extends StatelessWidget {
  const SelectionOver({super.key, required this.child, required this.bar});

  final Widget child;
  final Widget bar;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          Positioned.fill(child: child),
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: bar,
          ),
        ],
      );
}
