import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/player.dart';
import 'artwork.dart';
import 'now_playing.dart';
import 'swipe.dart';
import 'progress.dart';

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

        // The small bar answers to the host in a jam too, for the same reason the big
        // one does: this device is not the one playing.
        final host = app.hostPosition;
        // Same fallback as the big bar: the engine learns the length late, the track
        // has always known it.
        var length = s?.duration ?? Duration.zero;
        if (length == Duration.zero) length = track.duration ?? Duration.zero;
        final total = length.inMilliseconds;
        final at = host ?? s?.position ?? Duration.zero;
        final jam = app.jam;
        final subtitle = switch (s) {
          // Ahead of the error line: this one is answerable, and the raw engine
          // message ("NotAllowedError: The play method is not allowed…") is not
          // something to put in front of someone.
          _ when (s?.needsGesture ?? false) => 'Ready — tap play',
          _ when s?.error != null => s!.error!,
          _ when (s?.waitingForDownload ?? false) => 'Waiting for download…',
          _ when (s?.finished ?? false) => 'End of queue',
          _ when track.isPending => 'Downloading…',
          // Whose room this is, when it is somebody's: what is playing is only half
          // the answer if three people can change it.
          _ when jam != null => jam.isHost
              ? '${track.artistLine} · your jam · ${jam.listening} listening'
              : '${track.artistLine} · ${jam.host ?? 'a'} jam',
          _ => track.artistLine,
        };
        final muted = (s?.error != null && !(s?.needsGesture ?? false)) ||
            (s?.waitingForDownload ?? false) ||
            (s?.finished ?? false);

        return PlayerBarMarker(
            child: DragFollow(
          // Gestures live here rather than on list rows: rows already use a
          // horizontal swipe to remove, and two meanings for one drag is how a UI
          // starts feeling unpredictable.
          onSwipeUp: () => _openNowPlaying(context),
          // Through the app, not the player: in a jam these ask the room rather than
          // moving this device on its own.
          onSwipeLeft: app.skipNext,
          onSwipeRight: app.skipPrevious,
          horizontalTravel: 76,
          verticalTravel: 64,
          fadeWithDrag: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Carried forward between the engine's reports, so the line creeps
              // rather than stepping — see SmoothPosition.
              SmoothPosition(
                position: at,
                playing: host != null || (s?.playing ?? false),
                duration: length,
                speed: player.speed,
                builder: (context, now) => LinearProgressIndicator(
                  value:
                      total > 0 ? (now.inMilliseconds / total).clamp(0.0, 1.0) : 0.0,
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                ),
              ),
              ListTile(
                dense: true,
                onTap: () => _openNowPlaying(context),
                leading: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Artwork(track: track, size: 42),
                    if (jam != null)
                      Positioned(
                        right: -4,
                        bottom: -4,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.people,
                              size: 11,
                              color: Theme.of(context).colorScheme.onPrimary),
                        ),
                      ),
                  ],
                ),
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
                        onPressed: app.skipPrevious),
                    IconButton(
                      iconSize: 34,
                      icon: Icon((s?.playing ?? false)
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill),
                      onPressed: track.isReady ? app.playPause : null,
                    ),
                    IconButton(
                        icon: const Icon(Icons.skip_next), onPressed: app.skipNext),
                  ],
                ),
              ),
            ],
        )));
      },
    );
  }

  static void _openNowPlaying(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const NowPlayingScreen(),
        fullscreenDialog: true,
      ));
}
