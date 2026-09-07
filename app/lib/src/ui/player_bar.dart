import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/player.dart';
import 'artwork.dart';
import 'now_playing.dart';

/// The bar that is always there. It shows what is playing, and it shows when what
/// you queued is still downloading instead of pretending nothing happened.
/// A named wrapper so tests can address the bar without guessing at list positions.
class PlayerBarMarker extends StatelessWidget {
  const PlayerBarMarker({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

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

        final progress = s?.progress ?? 0.0;
        final subtitle = switch (s) {
          _ when s?.error != null => s!.error!,
          _ when (s?.waitingForDownload ?? false) => 'Waiting for download…',
          _ when (s?.finished ?? false) => 'End of queue',
          _ when track.isPending => 'Downloading…',
          _ => track.artistLine,
        };
        final muted = (s?.error != null) ||
            (s?.waitingForDownload ?? false) ||
            (s?.finished ?? false);

        return PlayerBarMarker(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor: Colors.transparent,
              ),
              ListTile(
                dense: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const NowPlayingScreen(),
                  fullscreenDialog: true,
                )),
                leading: Artwork(track: track, size: 42),
                title: Text(track.displayTitle,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted
                      ? TextStyle(color: Theme.of(context).colorScheme.error)
                      : null,
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
        ));
      },
    );
  }
}
