import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'dialogs.dart';
import 'selection_bar.dart';
import 'song_row.dart';

/// One way of rendering a list of tracks, used by every browse screen.
///
/// It carries the actions that were previously scattered or missing: play the whole
/// list from here, shuffle it, queue a single track, or put one in a playlist.
class TrackList extends StatelessWidget {
  const TrackList({
    super.key,
    required this.tracks,
    this.header,
    this.onRemove,
    this.named,
    this.selectable,
  });

  /// What to call this list when several songs are picked out of it — "playlist:3",
  /// "album:Low". Lists that pass nothing cannot be selected in.
  final String? selectable;

  final List<Track> tracks;
  final String? header;
  final void Function(int index)? onRemove;

  /// The name of the thing being listed — an album, a playlist. Given one, playing it
  /// makes a queue of its own instead of writing over whatever you were listening to.
  final String? named;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    if (tracks.isEmpty) {
      return const EmptyHint(
        icon: Icons.music_note,
        title: 'Nothing here yet',
        body: 'Tracks appear once they are in your library.',
      );
    }

    return Column(
      children: [
        if (selectable != null)
          SelectionBar(
            where: selectable!,
            tracks: tracks,
            removeLabel: onRemove == null ? 'Remove' : 'Remove from this list',
            onRemove: onRemove == null
                ? null
                : (picked) async {
                    // Backwards through the positions, so removing one does not shift
                    // the next one out from under the index about to be used.
                    final at = [
                      for (var i = 0; i < tracks.length; i++)
                        if (picked.any((p) => p.id == tracks[i].id)) i
                    ];
                    for (final i in at.reversed) {
                      onRemove!(i);
                    }
                  },
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: tracks.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) return _Head(tracks: tracks, header: header, named: named);
              final t = tracks[i - 1];
              return SongRow(
                track: t,
                selectable: selectable,
                onTap: () => app.playNow(tracks, startAt: i - 1, named: named),
                onRemove: onRemove == null ? null : () => onRemove!(i - 1),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Head extends StatelessWidget {
  const _Head({required this.tracks, this.header, this.named});
  final List<Track> tracks;
  final String? header;
  final String? named;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(header ?? '${tracks.length} tracks',
                style: Theme.of(context).textTheme.bodySmall),
          ),
          TextButton.icon(
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Play'),
            onPressed: () => app.playNow(tracks, named: named),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            icon: const Icon(Icons.shuffle, size: 18),
            label: const Text('Shuffle'),
            onPressed: () => app.playNow(tracks, shuffle: true, named: named),
          ),
        ],
      ),
    );
  }
}
