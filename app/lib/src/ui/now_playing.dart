import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/player.dart';
import 'artwork.dart';
import 'glass.dart';

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
          ),
          body: AmbientBackdrop(
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
                            _Artwork(track: track),
                            const SizedBox(height: 32),
                            Text(track.displayTitle,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 6),
                            Text(
                                [track.artistLine, track.albumLine]
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
        );
      },
    );
  }

  static String? _statusLine(PlayerSnapshot? s, Track track) {
    if (s?.error != null) return s!.error;
    if (s?.waitingForDownload ?? false) return 'Waiting for download…';
    if (s?.finished ?? false) return 'End of queue';
    if (track.state == 'failed') return track.failReason ?? 'This track failed';
    if (track.isPending) return 'Downloading…';
    return null;
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final side = c.maxWidth;
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
