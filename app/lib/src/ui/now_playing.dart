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
import 'up_next.dart';

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
      stream: player.snapshots,
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
            title: Text(app.activeQueue?.name ?? 'Now playing',
                style: Theme.of(context).textTheme.titleSmall),
            centerTitle: true,
            actions: [
              if (track != null)
                IconButton(
                  icon: const Icon(Icons.lyrics_outlined),
                  tooltip: 'Lyrics',
                  onPressed: () => showLyrics(context, track),
                ),
              IconButton(
                icon: const Icon(Icons.queue_music),
                tooltip: 'Up next',
                onPressed: () => showUpNext(context),
              ),
              IconButton(
                icon: Icon(app.sleepAt != null ? Icons.bedtime : Icons.timer_outlined),
                tooltip: 'Sleep timer and speed',
                onPressed: () => showPlaybackExtras(context),
              ),
              if (track != null)
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'Track actions',
                  onPressed: () => showTrackSheet(context, track,
                      onChanged: app.refresh),
                ),
            ],
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
                            _Artwork(track: track, snapshot: s, player: player),
                            const SizedBox(height: 32),
                            Text(track.displayTitle,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 6),
                            Text(
                                [track.artistLine, track.albumLine, track.sourceLabel]
                                    .whereType<String>()
                                    .join(' · '),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyLarge
                                    ?.copyWith(color: scheme.onSurfaceVariant)),
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
                                  _Scrubber(player: player, snapshot: s),
                                  const SizedBox(height: 4),
                                  _Controls(app: app, player: player, snapshot: s),
                                  const SizedBox(height: 6),
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
              onPrevious: player.previous,
              onNext: player.next,
            ),
          ),
        );
      },
    );
  }
}

class _Scrubber extends StatefulWidget {
  const _Scrubber({required this.player, required this.snapshot});
  final PlayerService player;
  final PlayerSnapshot? snapshot;

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  double? _dragging;   // while the thumb is held, the UI follows the finger

  @override
  Widget build(BuildContext context) {
    final s = widget.snapshot;
    final duration = s?.duration ?? Duration.zero;
    final position = s?.position ?? Duration.zero;
    final max = duration.inMilliseconds.toDouble();
    final value = (_dragging ?? position.inMilliseconds.toDouble()).clamp(0.0, max);
    final enabled = max > 0;

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            value: enabled ? value : 0,
            max: enabled ? max : 1,
            onChanged: enabled ? (v) => setState(() => _dragging = v) : null,
            onChangeEnd: (v) {
              widget.player.seek(Duration(milliseconds: v.round()));
              setState(() => _dragging = null);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatTime(Duration(milliseconds: value.round())),
                  style: Theme.of(context).textTheme.labelMedium),
              Text(enabled ? formatTime(duration) : '--:--',
                  style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.app, required this.player, required this.snapshot});
  final AppState app;
  final PlayerService player;
  final PlayerSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final playing = snapshot?.playing ?? false;
    final repeat = snapshot?.repeat ?? QueueRepeat.off;
    final shuffle = snapshot?.shuffle ?? false;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: const Icon(Icons.shuffle),
          isSelected: shuffle,
          color: shuffle ? Theme.of(context).colorScheme.primary : null,
          tooltip: shuffle ? 'Shuffle on' : 'Shuffle off',
          onPressed: () => app.setShuffle(!shuffle),
        ),
        IconButton(
          iconSize: 34,
          icon: const Icon(Icons.skip_previous),
          onPressed: player.previous,
        ),
        IconButton.filled(
          iconSize: 42,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          onPressed: player.playPause,
        ),
        if (app.jam != null && !app.jam!.isHost)
          // A guest's device is not the one making sound, so skipping is asking the
          // room rather than reaching over and pressing the button.
          IconButton(
            iconSize: 34,
            icon: const Icon(Icons.how_to_vote_outlined),
            tooltip: 'Vote to skip',
            onPressed: app.jam!.guestsCanSkip
                ? () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final r = await app.api.voteSkip(app.jam!.id);
                    messenger.showSnackBar(SnackBar(
                        content: Text(r['passed'] == true
                            ? 'Skipped'
                            : 'Asked to skip · ${r['votes']} of ${r['needed']}')));
                  }
                : null,
          )
        else
          IconButton(
            iconSize: 34,
            icon: const Icon(Icons.skip_next),
            onPressed: player.next,
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
