import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/player.dart';
import 'artwork.dart';
import 'glass.dart';
import 'record_stage.dart';
import 'swipe.dart';
import 'lyrics_sheet.dart';
import 'track_menu.dart';
import 'song_row.dart';
import 'browse_page.dart';
import 'jam_page.dart';
import 'halftone.dart';
import 'progress.dart';

String formatTime(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// The full player. The bar at the bottom of the app is a handle onto this; every
/// control that needs room — scrubbing, shuffle, repeat, volume — lives here.
class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final player = app.player;
    if (player == null) return const SizedBox.shrink();

    return StreamBuilder<PlayerSnapshot>(
      // Coarse on purpose. The record turning, the disc sliding out and the printed
      // background are animations with their own clocks; rebuilding the screen under
      // them four times a second is what made them stutter. The scrubber keeps its own
      // fine-grained subscription — see _Scrubber.
      stream: player.changes,
      initialData: player.last,
      builder: (context, snap) {
        final s = snap.data;
        final track = s?.current ?? player.current;
        final scheme = Theme.of(context).colorScheme;

        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: 'Close',
            ),
            title: app.jam == null
                ? Text(app.activeQueue?.name ?? 'Now playing',
                    style: Theme.of(context).textTheme.titleSmall)
                : _JamTitle(app: app),
            centerTitle: true,
            // Where these live is a setting: the top corners are furthest from a
            // thumb, which is why they moved, but it is also the arrangement people
            // knew — so it is still here to choose.
            actions: app.playerLayout == PlayerLayout.topBar && track != null
                ? [
                    IconButton(
                      icon: const Icon(Icons.lyrics_outlined),
                      tooltip: 'Lyrics',
                      onPressed: () => showLyrics(context, track),
                    ),
                    IconButton(
                      icon: const Icon(Icons.queue_music),
                      tooltip: 'Queue',
                      onPressed: () => showQueue(context),
                    ),
                    IconButton(
                      icon: Icon(app.sleepAt != null
                          ? Icons.bedtime
                          : Icons.timer_outlined),
                      tooltip: 'Sleep timer and speed',
                      onPressed: () => showPlaybackExtras(context),
                    ),
                    IconButton(
                      icon: const Icon(Icons.more_vert),
                      tooltip: 'Track actions',
                      onPressed: () => showTrackSheet(context, track,
                          onChanged: app.refresh),
                    ),
                  ]
                : const [],
          ),
          body: DragFollow(
            // Drag down to close, the gesture that dismisses a sheet anywhere else.
            // Sideways belongs to the record itself rather than to the page: dragging
            // the whole screen to change track carried the title and the controls
            // along with it, which is not what the gesture is about.
            onSwipeDown: () => Navigator.of(context).maybePop(),
            verticalTravel: 150,
            fadeWithDrag: true,
            child: AmbientBackdrop(
            colour: parseHexColour(track?.coverColor),
            // The album's own colour where it has one, so the page belongs to the
            // record rather than to the app.
            behind: app.halftone
                ? HalftoneBackdrop(
                    colour: parseHexColour(track?.coverColor),
                    playing: s?.playing ?? false,
                    loudnessDb: track?.loudnessLufs,
                  )
                : null,
            child: track == null
              ? const Center(child: Text('Nothing playing'))
              : SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Roomy trades artwork for buttons: the panel below wants
                            // the space more than the record does when the phone is
                            // being held in one hand.
                            Flexible(
                              child: FractionallySizedBox(
                                widthFactor: app.playerLayout == PlayerLayout.roomy
                                    ? 0.82
                                    : 1.0,
                                child: _Artwork(
                                    track: track, snapshot: s, player: player),
                              ),
                            ),
                            SizedBox(
                                height: app.playerLayout == PlayerLayout.roomy
                                    ? 18
                                    : 32),
                            Text(track.displayTitle,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 6),
                            _Credits(track: track),
                            if (_statusLine(s, track) != null) ...[
                              const SizedBox(height: 10),
                              Text(_statusLine(s, track)!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: scheme.error)),
                            ],
                            const SizedBox(height: 26),
                            GlassSurface(
                              borderRadius: BorderRadius.circular(22),
                              topBorder: false,
                              opacity: 0.55,
                              blur: 30,
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _Scrubber(player: player),
                                  const SizedBox(height: 4),
                                  _Controls(
                                      app: app,
                                      player: player,
                                      snapshot: s,
                                      big: app.playerLayout ==
                                          PlayerLayout.roomy),
                                  if (app.playerLayout != PlayerLayout.topBar) ...[
                                    SizedBox(
                                        height: app.playerLayout == PlayerLayout.roomy
                                            ? 8
                                            : 2),
                                    _Extras(
                                        app: app,
                                        track: track,
                                        big: app.playerLayout == PlayerLayout.roomy),
                                  ],
                                  SizedBox(
                                      height: app.playerLayout == PlayerLayout.roomy
                                          ? 8
                                          : 2),
                                  _VolumeRow(player: player),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
          ),
          ),
        );
      },
    );
  }

  static String? _statusLine(PlayerSnapshot? s, Track track) {
    // First: the browser is only waiting to be tapped, which is not a failure.
    if (s?.needsGesture ?? false) return 'Ready — tap play';
    if (s?.error != null) return s!.error;
    if (s?.waitingForDownload ?? false) return 'Waiting for download…';
    if (s?.finished ?? false) return 'End of queue';
    if (track.state == 'failed') return track.failReason ?? 'This track failed';
    if (track.isPending) return 'Downloading…';
    return null;
  }
}

/// Leave the player and land on the queue.
///
/// This used to open a small sheet with its own list of what was coming: a second
/// queue screen, with none of the things the real one has — reordering, the other
/// queues, removing a track, the menu on every row. One queue, one screen.
void showQueue(BuildContext context) {
  context.read<AppState>().setHomeTab(0);
  // All the way back, not one step: the player can be opened from an album or an
  // artist, and popping once would land there instead of on the queue.
  Navigator.of(context).popUntil((route) => route.isFirst);
}

/// Listening together, said where you are looking.
///
/// A jam changes what the buttons on this screen mean — anyone can add, a skip is a
/// vote — so it has to be visible from the screen those buttons are on, not only from
/// the jam page. Tapping it goes there.
class _JamTitle extends StatelessWidget {
  const _JamTitle({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final jam = app.jam!;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const JamPage())),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                jam.isHost
                    ? 'Your jam · ${jam.listening} listening'
                    : "${jam.host ?? 'Someone'}'s jam",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: scheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Artist and album, and the way to each of their pages.
///
/// They were a line of grey text saying where a song came from. They are the two most
/// obvious things to want next — everything else by them, the rest of the record — and
/// a name that leads nowhere when you press it is a name you learn not to press.
class _Credits extends StatelessWidget {
  const _Credits({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyLarge
        ?.copyWith(color: scheme.onSurfaceVariant);

    Widget link(String label, VoidCallback onTap) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(decoration: TextDecoration.underline,
                    decorationColor: scheme.onSurfaceVariant.withValues(alpha: 0.4))),
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: link(
                track.artistLine,
                () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ArtistPage(
                    artist: ArtistSummary(
                        name: track.artists.isEmpty ? track.artistLine
                                                    : track.artists.first,
                        tracks: 0),
                  ),
                )),
              ),
            ),
            if (track.albumLine != null) ...[
              Text(' · ', style: style),
              Flexible(
                child: link(
                  track.albumLine!,
                  () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AlbumPage(
                      album: AlbumSummary(
                        name: track.albumLine!,
                        artist: track.artists.isEmpty ? '' : track.artists.first,
                        tracks: 0,
                      ),
                    ),
                  )),
                ),
              ),
            ],
          ],
        ),
        if (track.sourceLabel != null)
          Text(track.sourceLabel!,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: scheme.outline)),
      ],
    );
  }
}

/// The things that act on the song, where a thumb already is.
class _Extras extends StatelessWidget {
  const _Extras({required this.app, required this.track, this.big = false});
  final AppState app;
  final Track track;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final size = big ? 28.0 : 22.0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        FavouriteButton(trackId: track.id, size: size),
        IconButton(
          iconSize: size,
          icon: const Icon(Icons.lyrics_outlined),
          tooltip: 'Lyrics',
          onPressed: () => showLyrics(context, track),
        ),
        IconButton(
          iconSize: size,
          icon: const Icon(Icons.queue_music),
          tooltip: 'Queue',
          onPressed: () => showQueue(context),
        ),
        IconButton(
          iconSize: size,
          icon: Icon(app.sleepAt != null ? Icons.bedtime : Icons.timer_outlined),
          tooltip: 'Sleep timer and speed',
          onPressed: () => showPlaybackExtras(context),
        ),
        IconButton(
          iconSize: size,
          icon: const Icon(Icons.more_vert),
          tooltip: 'Track actions',
          onPressed: () => showTrackSheet(context, track, onChanged: app.refresh),
        ),
      ],
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.track, this.snapshot, required this.player});
  final Track track;
  final PlayerSnapshot? snapshot;
  final PlayerService player;

  /// The record either side of this one, so the queue is something you can see rather
  /// than something you have to remember. Read from the player's own list.
  Track? _at(int offset) {
    final items = player.items;
    final i = (snapshot?.index ?? 0) + offset;
    return i >= 0 && i < items.length ? items[i] : null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final side = c.maxWidth;
        if (context.watch<AppState>().coverStyle == CoverStyle.flat) {
          // Just the cover: still, square, and the whole width of the stage.
          return Center(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Artwork(track: track, size: side, radius: 16, small: false),
            ),
          );
        }

        // No clip and no shadow of our own: the pieces carry their own, and a rounded
        // rectangle around them would cut the disc off as it slides out.
        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: RecordStage(
              track: track,
              playing: snapshot?.playing ?? false,
              previous: _at(-1),
              next: _at(1),
              // Through the app: a swipe in a jam asks the room, like every other
              // way of changing track.
              onPrevious: context.read<AppState>().skipPrevious,
              onNext: context.read<AppState>().skipNext,
            ),
          ),
        );
      },
    );
  }
}

/// The bar and the two times, with its own line to the player.
///
/// Everything else on this screen is drawn from the coarse stream; the clock is the
/// one thing that genuinely changes several times a second, so it listens for itself
/// and repaints nothing but itself.
class _Scrubber extends StatelessWidget {
  const _Scrubber({required this.player});
  final PlayerService player;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: StreamBuilder<PlayerSnapshot>(
          stream: player.snapshots,
          initialData: player.last,
          builder: (context, snap) =>
              _ScrubberBar(player: player, snapshot: snap.data),
        ),
      );
}

class _ScrubberBar extends StatefulWidget {
  const _ScrubberBar({required this.player, required this.snapshot});
  final PlayerService player;
  final PlayerSnapshot? snapshot;

  @override
  State<_ScrubberBar> createState() => _ScrubberState();
}

class _ScrubberState extends State<_ScrubberBar> {
  double? _dragging;   // while the thumb is held, the UI follows the finger

  /// Where a seek was aimed, until the engine reports having got there.
  ///
  /// Letting go used to drop straight back to whatever the last snapshot said, which
  /// for a stream is the *old* position for as long as the seek takes — so the thumb
  /// sprang back to where it started and then jumped forward a moment later. Holding
  /// the target keeps the bar where the finger left it.
  double? _seeking;
  DateTime? _seekAt;

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final app = context.watch<AppState>();

    // The engine only knows a duration once it has read the file's header. The track
    // itself has always known, so a bar that is dead for the first second of every
    // song was only ever asking the wrong one of the two.
    var duration = s?.duration ?? Duration.zero;
    if (duration == Duration.zero) duration = s?.current?.duration ?? Duration.zero;

    // A guest plays the same song on its own device now, in step with the host, so
    // its own clock is the one to draw. The host's reported position is the fallback
    // for the moment before the guest's engine has caught up — otherwise the bar sits
    // at zero while the room is halfway through a record.
    final host = app.hostPosition;
    var position = s?.position ?? Duration.zero;
    if (position == Duration.zero && host != null) position = host;

    final max = duration.inMilliseconds.toDouble();

    // A seek is finished when the engine reports somewhere near where we sent it, or
    // when it has had long enough that something must have gone wrong.
    if (_seeking != null) {
      final settled = (position.inMilliseconds - _seeking!).abs() < 1500 ||
          DateTime.now().difference(_seekAt ?? DateTime.now()) >
              const Duration(seconds: 3);
      if (settled) {
        _seeking = null;
        _seekAt = null;
      } else {
        position = Duration(milliseconds: _seeking!.round());
      }
    }

    // Dragging is allowed whenever it will reach the room: the host always, a guest
    // when the host has left the controls open. A guest who cannot control the room
    // would only move their own device out of step with it.
    final enabled = max > 0 && (!app.isJamGuest || app.jamControlsTheRoom);
    // In a jam the host is the one playing, so the clock runs from their reports even
    // though this device's own engine is silent.
    final playing = (s?.playing ?? false) && _dragging == null && _seeking == null;

    return SmoothPosition(
      position: position,
      playing: playing,
      duration: duration,
      speed: widget.player.speed,
      builder: (context, at) {
        final value =
            (_dragging ?? at.inMilliseconds.toDouble()).clamp(0.0, max <= 0 ? 1.0 : max);
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: enabled ? 7 : 4),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                value: max > 0 ? value : 0,
                max: max > 0 ? max : 1,
                onChanged: enabled ? (v) => setState(() => _dragging = v) : null,
                onChangeEnd: enabled
                    ? (v) {
                        app.seekTo(Duration(milliseconds: v.round()));
                        setState(() {
                          _seeking = v;
                          _seekAt = DateTime.now();
                          _dragging = null;
                        });
                      }
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatTime(Duration(milliseconds: value.round())),
                      style: Theme.of(context).textTheme.labelMedium),
                  Text(max > 0 ? formatTime(duration) : '--:--',
                      style: Theme.of(context).textTheme.labelMedium),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls(
      {required this.app,
      required this.player,
      required this.snapshot,
      this.big = false});
  final AppState app;
  final PlayerService player;
  final PlayerSnapshot? snapshot;

  /// The roomy arrangement: same controls, more of them under the thumb.
  final bool big;

  @override
  Widget build(BuildContext context) {
    final playing = snapshot?.playing ?? false;
    final repeat = snapshot?.repeat ?? QueueRepeat.off;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: big ? 10 : 0),
      child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: const Icon(Icons.shuffle),
          tooltip: 'Shuffle what is coming',
          onPressed: app.shuffleWhatIsComing,
        ),
        IconButton(
          iconSize: big ? 42 : 34,
          icon: const Icon(Icons.skip_previous),
          onPressed: app.skipPrevious,
        ),
        IconButton.filled(
          iconSize: big ? 54 : 42,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          onPressed: app.playPause,
        ),
        IconButton(
          iconSize: big ? 42 : 34,
          icon: const Icon(Icons.skip_next),
          onPressed: app.skipNext,
        ),
        IconButton(
          icon: Icon(repeat == QueueRepeat.one ? Icons.repeat_one : Icons.repeat),
          isSelected: repeat != QueueRepeat.off,
          color: repeat != QueueRepeat.off
              ? Theme.of(context).colorScheme.primary
              : null,
          tooltip: switch (repeat) {
            QueueRepeat.off => 'Repeat off',
            QueueRepeat.all => 'Repeat queue',
            QueueRepeat.one => 'Repeat track',
          },
          onPressed: app.cycleRepeat,
        ),
      ],
    ),
    );
  }
}

class _VolumeRow extends StatefulWidget {
  const _VolumeRow({required this.player});
  final PlayerService player;

  @override
  State<_VolumeRow> createState() => _VolumeRowState();
}

class _VolumeRowState extends State<_VolumeRow> {
  double? _value;

  @override
  Widget build(BuildContext context) {
    // The web build has no hardware volume to fall back on, so the app needs its own.
    final v = _value ?? widget.player.userVolume;
    return Row(
      children: [
        Icon(v == 0 ? Icons.volume_off : Icons.volume_down,
            size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        Expanded(
          child: Slider(
            value: v,
            onChanged: (nv) {
              setState(() => _value = nv);
              widget.player.setUserVolume(nv);
            },
          ),
        ),
        Icon(Icons.volume_up,
            size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ],
    );
  }
}

/// Sleep timer and playback speed: the two things you reach for at either end of a
/// listening session, and the two the player was missing.
Future<void> showPlaybackExtras(BuildContext context) async {
  final app = context.read<AppState>();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, refresh) {
        final left = app.sleepIn;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                child: Text('Sleep timer',
                    style: Theme.of(sheet).textTheme.titleSmall),
              ),
              if (left != null && !left.isNegative)
                ListTile(
                  leading: const Icon(Icons.bedtime),
                  title: Text('Stops in ${left.inMinutes + 1} min'),
                  trailing: TextButton(
                    onPressed: () {
                      app.setSleepTimer(null);
                      refresh(() {});
                    },
                    child: const Text('Cancel'),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final minutes in [15, 30, 45, 60, 90])
                        OutlinedButton(
                          onPressed: () {
                            app.setSleepTimer(Duration(minutes: minutes));
                            refresh(() {});
                          },
                          child: Text('$minutes min'),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                child: Text('Playback speed',
                    style: Theme.of(sheet).textTheme.titleSmall),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final rate in [0.75, 1.0, 1.25, 1.5, 2.0])
                      ChoiceChip(
                        selected: (app.player?.speed ?? 1.0) == rate,
                        label: Text(rate == 1.0 ? 'Normal' : '$rate×'),
                        onSelected: (_) async {
                          await app.player?.setSpeed(rate);
                          refresh(() {});
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    ),
  );
}
