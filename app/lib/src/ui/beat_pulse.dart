import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'motion.dart';

/// The song's pulse, as a number anything on the screen can move to.
///
/// One on the beat and falling away to nothing before the next, a little more on the
/// first beat of a bar. It comes from where the beats *are* — the server listened to the
/// song for them — and from where the music is now, so it is in time with what is heard
/// rather than with the loudness of the moment, and it is in time on somebody's phone in
/// a jam even though that phone is making no sound.
///
/// Nothing at all for a song with no steady pulse, before the first beat, after the
/// last, while paused, and where the phone has been asked not to animate: a light that
/// flashes in time with nothing is worse than one that holds still.
class BeatPulse extends StatefulWidget {
  const BeatPulse({super.key, required this.app, required this.track, required this.builder});

  final AppState app;
  final Track? track;
  final Widget Function(BuildContext context, ValueNotifier<double> pulse) builder;

  @override
  State<BeatPulse> createState() => _BeatPulseState();
}

class _BeatPulseState extends State<BeatPulse> with SingleTickerProviderStateMixin {
  final _pulse = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(_tick);
  TrackTiming? _timing;
  int? _askedFor;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(BeatPulse old) {
    super.didUpdateWidget(old);
    if (old.track?.id != widget.track?.id) _ask();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _run();
  }

  void _ask() {
    final track = widget.track;
    final store = widget.app.player?.timing;
    _timing = track == null ? null : store?.peek(track.id);
    _askedFor = track?.id;
    _run();
    if (track == null || store == null || _timing != null) return;
    store.of(track).then((found) {
      if (!mounted || _askedFor != track.id) return;
      _timing = found;
      _run();
    });
  }

  void _run() {
    final worth = (_timing?.hasBeats ?? false) && !stillness(context);
    if (worth && !_ticker.isActive) {
      _ticker.start();
    } else if (!worth && _ticker.isActive) {
      _ticker.stop();
      _pulse.value = 0;
    }
  }

  void _tick(Duration _) {
    final app = widget.app;
    final timing = _timing;
    if (timing == null || !app.musicIsPlaying) {
      if (_pulse.value != 0) _pulse.value = 0;
      return;
    }
    // Wherever the music actually is: this device's engine, the host of a jam, the
    // other device this one is a remote control for.
    final at = (app.isJamGuest && !app.jamListening) || app.controllingAnother
        ? app.positionNow
        : app.player?.livePosition;
    final beat = at == null ? null : timing.beatAt(at);
    if (beat == null) {
      if (_pulse.value != 0) _pulse.value = 0;
      return;
    }
    // Sharp up, quick down: most of it is over in the first third of the beat.
    final fall = math.exp(-beat.phase * 5.5);
    final one = (beat.index - timing.barStartsOn) % 4 == 0;
    _pulse.value = fall * (one ? 1.0 : 0.72);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _pulse);
}
