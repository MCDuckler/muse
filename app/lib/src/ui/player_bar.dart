import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/player.dart';
import 'artwork.dart';
import 'feel.dart';
import 'now_playing.dart';
import 'swipe.dart';
import 'progress.dart';
import 'pulse.dart';
import 'mag.dart';

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
      // Not every report: the line across the top moves by itself between them.
      stream: player.changes,
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
        // Two different things, in two different colours. A stream that failed is a
        // problem; a song still on its way, or a queue that has reached its end, is
        // not — and both were drawn in the error red, so the bar cried wolf every
        // time somebody queued a song that was not here yet.
        final problem = s?.error != null && !(s?.needsGesture ?? false);
        final quiet = !problem &&
            ((s?.needsGesture ?? false) ||
                (s?.waitingForDownload ?? false) ||
                (s?.finished ?? false) ||
                track.isPending);
        final buffering = s?.buffering ?? false;
        final scheme = Theme.of(context).colorScheme;

        return PlayerBarMarker(
            child: _OpenByHand(
          child: DragFollow(
          // Gestures live here rather than on list rows: rows already use a
          // horizontal swipe to remove, and two meanings for one drag is how a UI
          // starts feeling unpredictable.
          //
          // Sideways only: up belongs to _OpenByHand around it, which does not swipe
          // so much as drag the player open by however much the finger moved.
          // Through the app, not the player: in a jam these ask the room rather than
          // moving this device on its own.
          onSwipeLeft: app.skipNext,
          onSwipeRight: app.skipPrevious,
          horizontalTravel: 76,
          fadeWithDrag: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Carried forward between the engine's reports, so the line creeps
              // rather than stepping — see SmoothPosition.
              SmoothPosition(
                position: at,
                // What the room is doing, for a guest whose own speaker is off — it is
                // the same song they can hear, and a line that does not move says it
                // has stopped.
                playing: app.musicIsPlaying,
                duration: length,
                speed: player.speed,
                builder: (context, now) => Pulse(
                  // Nothing after this one. The same slow breath as the full player's
                  // bar, so the two are obviously the same thing being said.
                  on: s?.lastInQueue ?? false,
                  // Waiting on the network is shown as the line itself moving: a
                  // stalled bar with a pause button on it looks like a broken app,
                  // and this is the one place everybody looks when nothing is
                  // coming out.
                  child: LinearProgressIndicator(
                    value: buffering
                        ? null
                        : total > 0
                            ? (now.inMilliseconds / total).clamp(0.0, 1.0)
                            : 0.0,
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                  ),
                ),
              ),
              ListTile(
                dense: true,
                onTap: () {
              feel(Feel.tap);
              _openNowPlaying(context);
            },
                leading: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Artwork(track: track, size: 42, radius: 2),
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
                // The song in the headline face, the rest typed under it: the same
                // two voices as every page it sits under.
                title: Text(track.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Mag.title(15.5, color: scheme.onSurface)),
                subtitle: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Mag.typewriter(11.5,
                      color: problem
                          ? scheme.error
                          : quiet
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                        icon: const Icon(Icons.skip_previous),
                        onPressed: felt(Feel.commit, app.skipPrevious)),
                    // Solid red, the one loud thing on the bar: it is the button.
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                        fixedSize: const Size.square(40),
                      ),
                      iconSize: 24,
                      icon: Icon(app.musicIsPlaying ? Icons.pause : Icons.play_arrow),
                      // Never disabled. A track whose file has not landed yet still
                      // answers a tap — the player waits for the download — and a
                      // button that greys out for the moment a state arrives late is
                      // a pale flash in the corner of the eye for no gain.
                      onPressed: felt(Feel.commit, app.playPause),
                    ),
                    IconButton(
                        icon: const Icon(Icons.skip_next), onPressed: felt(Feel.commit, app.skipNext)),
                  ],
                ),
              ),
            ],
        ))));
      },
    );
  }

  /// Open the player, telling it where it is coming from.
  ///
  /// The rectangle is this bar's own, read at the moment it is tapped: the route grows
  /// out of it and shrinks back into it, so the thing that was tapped is the thing
  /// that opens.
  ///
  /// On the app's own navigator, not a tab's: the player covers everything, tabs and
  /// all, and it carries its own copy of the bar out of itself.
  static void _openNowPlaying(BuildContext context) =>
      Navigator.of(context, rootNavigator: true)
          .push(nowPlayingRoute(from: barRect(context)));

  /// Where this bar is on the screen, for the route to come out of.
  static Rect? barRect(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    return box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
  }
}

/// Pulling the player up out of the bar.
///
/// The bar follows the finger — it lifts, it fades, it comes back if the pull is
/// abandoned — and how the pull ends is what opens the player and how fast: a hard
/// flick throws it open, a slow deliberate pull opens at the speed of the pull.
///
/// It cannot be a one-to-one drag across the whole travel, and that is the framework's
/// rule rather than a choice: pushing a route calls NavigatorState._cancelActivePointers,
/// which cancels every finger that is currently down. The moment the player is pushed,
/// the touch that pushed it no longer exists — no gesture recogniser, no raw listener
/// and no pointer-router subscription outlives it, because the framework stops
/// dispatching that pointer altogether. So the drag lives entirely on this side of the
/// push, and the speed it was carrying is handed to the transition.
class _OpenByHand extends StatefulWidget {
  const _OpenByHand({required this.child});
  final Widget child;

  @override
  State<_OpenByHand> createState() => _OpenByHandState();
}

class _OpenByHandState extends State<_OpenByHand>
    with SingleTickerProviderStateMixin {
  /// How far the bar can be pulled before it stops following.
  static const _travel = 110.0;

  /// A pull this far, or a flick this fast, opens on release.
  static const _enough = 34.0;
  static const _flick = 420.0;

  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addListener(() => setState(() {}));

  double _lifted = 0;
  double _springingFrom = 0;

  double get _height => MediaQuery.sizeOf(context).height;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _start(DragStartDetails _) {
    _back.stop();
    _springingFrom = 0;
  }

  void _update(DragUpdateDetails d) {
    final want = _lifted - (d.primaryDelta ?? 0);
    setState(() {
      // Past the travel it keeps coming, grudgingly: the bar stays under the finger
      // without sliding off the top of the screen.
      _lifted = want <= _travel
          ? math.max(want, 0)
          : _travel + (want - _travel) * 0.35;
    });
  }

  void _end(DragEndDetails d) {
    final up = -d.velocity.pixelsPerSecond.dy;
    if (_lifted >= _enough || up >= _flick) {
      _open(up);
    }
    _springBack();
  }

  void _cancel() => _springBack();

  void _springBack() {
    _springingFrom = _lifted;
    _back
      ..value = 0
      ..forward();
    void settle() {
      setState(() => _lifted =
          _springingFrom * (1 - Curves.easeOutCubic.transform(_back.value)));
      if (_back.isCompleted) {
        _back.removeListener(settle);
        _lifted = 0;
      }
    }

    _back.addListener(settle);
  }

  /// Open it, carrying the speed of the pull into the transition.
  ///
  /// Somebody who threw the bar at the top of the screen gets it opening at that
  /// speed; somebody who eased it up gets it easing open. Starting from where the
  /// pull got to, so the window picks up where the bar left off rather than snapping
  /// back to nothing first.
  void _open(double upwardPixelsPerSecond) {
    final route = NowPlayingRoute(from: PlayerBar.barRect(context), byHand: true);
    Navigator.of(context, rootNavigator: true).push(route);
    final hand = route.hand;
    if (hand == null) return;
    hand.value = (_lifted / _height).clamp(0.0, 0.25);
    hand.fling(
        velocity: (upwardPixelsPerSecond / _height).clamp(1.2, 8.0).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final lifted = _lifted;
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onVerticalDragStart: _start,
      onVerticalDragUpdate: _update,
      onVerticalDragEnd: _end,
      onVerticalDragCancel: _cancel,
      child: lifted == 0
          ? widget.child
          : Transform.translate(
              offset: Offset(0, -lifted),
              // Fading as it goes, because what it is turning into is on its way up
              // behind it.
              child: Opacity(
                opacity: (1 - lifted / (_travel * 2)).clamp(0.4, 1.0),
                child: widget.child,
              ),
            ),
    );
  }
}
