import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Where playback has got to, between the moments the engine says so.
///
/// The player reports a position when it feels like it — a quarter of a second apart at
/// best, and on the web often further — so a bar drawn straight from those reports
/// crawls forward in visible steps, stalls, and occasionally twitches backwards when a
/// report arrives slightly behind the one before it. That is the "unreliable" progress
/// bar: the playback is fine, the drawing of it is not.
///
/// So the last report is treated as a fix, not as the whole truth: from it the clock is
/// carried forward frame by frame at whatever speed the track is playing, and each new
/// report re-anchors it. A report that lands slightly *behind* where the clock has got
/// to is taken as the engine rounding rather than as playback moving backwards, so the
/// bar never goes back on itself while a song is playing forwards.
///
/// The ticker only runs while something is playing, and only this small subtree rebuilds
/// with it.
class SmoothPosition extends StatefulWidget {
  const SmoothPosition({
    super.key,
    required this.position,
    required this.playing,
    required this.duration,
    this.speed = 1.0,
    required this.builder,
  });

  /// The last position the engine (or, in a jam, the host) reported.
  final Duration position;
  final bool playing;

  /// The length of the track, so the clock cannot run past the end.
  final Duration duration;
  final double speed;
  final Widget Function(BuildContext context, Duration position) builder;

  @override
  State<SmoothPosition> createState() => _SmoothPositionState();
}

class _SmoothPositionState extends State<SmoothPosition>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);

  /// The last fix, and when it arrived by this device's clock.
  late Duration _base = widget.position;
  late DateTime _baseAt = DateTime.now();

  /// What is on screen now.
  late Duration _shown = widget.position;

  /// How far behind the running clock a report may land before it is believed. A report
  /// is a moment old by the time it arrives, so a small step back is the engine being
  /// late rather than playback moving.
  static const _tolerateBehind = Duration(milliseconds: 900);

  @override
  void initState() {
    super.initState();
    if (widget.playing) _ticker.start();
  }

  @override
  void didUpdateWidget(SmoothPosition old) {
    super.didUpdateWidget(old);

    if (widget.position != old.position) {
      final behind = _shown - widget.position;
      final drifted = behind > _tolerateBehind || behind < Duration.zero;
      // A seek, a skip, or a report far enough out that it is news: re-anchor. A report
      // a hair behind the running clock while playing: keep the clock.
      _base = (!widget.playing || drifted) ? widget.position : _shown;
      _baseAt = DateTime.now();
      if (!widget.playing) _shown = widget.position;
    }

    if (widget.playing != old.playing) {
      // Stopping freezes where the clock had got to; starting carries on from there.
      _base = widget.playing ? _shown : widget.position;
      _baseAt = DateTime.now();
      if (widget.playing) {
        if (!_ticker.isActive) _ticker.start();
      } else {
        _ticker.stop();
        _shown = _base;
      }
    }
  }

  void _tick(Duration _) {
    final elapsed = DateTime.now().difference(_baseAt) * widget.speed;
    var at = _base + elapsed;
    if (widget.duration > Duration.zero && at > widget.duration) {
      at = widget.duration;
    }
    // Ten times a second, not sixty.
    //
    // What this drives is a bar a few hundred pixels wide across a four-minute song:
    // one pixel of it is most of a second, so sixty updates a second redraw the same
    // pixel forty times over — and each one rebuilds a Slider, or a progress bar and
    // the two times either side of it. A tenth of a second is still a tenth of a pixel
    // per step, which is smooth by any measure anyone can see.
    if ((at.inMilliseconds - _shown.inMilliseconds).abs() < 100) return;
    setState(() => _shown = at);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: widget.builder(context, widget.playing ? _shown : widget.position),
      );
}
