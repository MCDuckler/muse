import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'artwork.dart';
import 'dialogs.dart';
import 'track_menu.dart';

/// One way of rendering a list of tracks, used by every browse screen.
///
/// It carries the actions that were previously scattered or missing: play the whole
/// list from here, shuffle it, queue a single track, or put one in a playlist.
class TrackList extends StatelessWidget {
  const TrackList({super.key, required this.tracks, this.header, this.onRemove});

  final List<Track> tracks;
  final String? header;
  final void Function(int index)? onRemove;

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

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 160),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: tracks.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return _Head(tracks: tracks, header: header);
        final t = tracks[i - 1];
        return ListTile(
          leading: Artwork(track: t, size: 40),
          title: Text(t.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [t.artistLine, if (t.albumLine != null) t.albumLine!].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: 'Track actions',
            onPressed: () => showTrackSheet(context, t,
                onRemove: onRemove == null ? null : () => onRemove!(i - 1)),
          ),
          onTap: () => app.playNow(tracks, startAt: i - 1),
        );
      },
    );
  }
}

class _Head extends StatelessWidget {
  const _Head({required this.tracks, this.header});
  final List<Track> tracks;
  final String? header;

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
            onPressed: () => app.playNow(tracks),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            icon: const Icon(Icons.shuffle, size: 18),
            label: const Text('Shuffle'),
            onPressed: () => app.playNow(tracks, shuffle: true),
          ),
        ],
      ),
    );
  }
}
