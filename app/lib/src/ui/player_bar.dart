import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/player.dart';

/// The bar that is always there. It shows what is playing, and it shows when what
/// you queued is still downloading instead of pretending nothing happened.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = app.player;
    if (player == null) return const SizedBox.shrink();

    return StreamBuilder<PlayerSnapshot>(
      stream: player.snapshots,
      builder: (context, snap) {
        final s = snap.data;
        final track = s?.current ?? player.current;
        if (track == null) return const SizedBox.shrink();

        final duration = s?.duration ?? track.duration ?? Duration.zero;
        final position = s?.position ?? Duration.zero;
        final progress = duration.inMilliseconds == 0
            ? 0.0
            : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

        return Material(
          elevation: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress, minHeight: 2),
              ListTile(
                dense: true,
                leading: Icon(track.source == 'custom'
                    ? Icons.folder_outlined
                    : Icons.music_note_outlined),
                title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  track.isPending ? 'Downloading…' : track.artistLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                        icon: const Icon(Icons.skip_previous),
                        onPressed: player.previous),
                    IconButton(
                      iconSize: 34,
                      icon: Icon((s?.playing ?? false)
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill),
                      onPressed: track.isReady ? player.playPause : null,
                    ),
                    IconButton(icon: const Icon(Icons.skip_next), onPressed: player.next),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
