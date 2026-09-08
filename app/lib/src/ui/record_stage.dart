import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'swipe.dart';

/// The player's artwork, as a record you can watch being played.
///
/// At rest the jacket lies flat, the way a record sits on a table with the disc still
/// inside it. Press play and it stands up, the disc slides a third of the way out and
/// turns at 33⅓. Skip, and it all goes back in before the next one comes out.
///
/// What it costs: two cached images per record and one turning texture. The jacket and
/// the neighbours never repaint — only the disc's rotation does, inside its own
/// [RepaintBoundary]. The ticker is muted by the framework whenever this route is not
/// the one on screen, so a player in the background animates nothing at all.
class RecordStage extends StatefulWidget {
  const RecordStage({
    super.key,
    required this.track,
    required this.playing,
    this.previous,
    this.next,
    this.onPrevious,
    this.onNext,
  });

  final Track track;
  final bool playing;
  final Track? previous;
  final Track? next;
  /// Dragging the record sideways moves through the queue. Only the record moves:
  /// the title and the controls stay where they are.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<RecordStage> createState() => _RecordStageState();
}

class _RecordStageState extends State<RecordStage> with TickerProviderStateMixin {
  /// 0 = flat on the table with the disc inside, 1 = standing with the disc out.
  late final AnimationController _stand = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
    reverseDuration: const Duration(milliseconds: 380),
  );

  /// One turn every 1.8 s, which is 33⅓ rpm — the speed the record would actually run.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) {
      _stand.value = 1;
      _spin.repeat();
    }
  }

  @override
  void didUpdateWidget(RecordStage old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id) {
      // A different record: this one has not been taken out of its sleeve yet.
      _stand.value = 0;
    }
    if (widget.playing) {
      _stand.forward();
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _stand.reverse();
      _spin.stop();          // stops where it is, like a turntable winding down
    }
  }

  @override
  void dispose() {
    _stand.dispose();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final api = context.read<AppState>().api;
    return LayoutBuilder(
      builder: (context, c) {
        final side = math.min(c.maxWidth, c.maxHeight.isFinite ? c.maxHeight : c.maxWidth);
        final jacket = side * 0.60;
        final disc = jacket * 0.92;

        return SizedBox(
          width: side,
          height: side,
          child: DragFollow(
            onSwipeLeft: widget.onNext,
            onSwipeRight: widget.onPrevious,
            horizontalTravel: side * 0.22,
            child: AnimatedBuilder(
            animation: _stand,
            builder: (context, _) {
              final t = Curves.easeOutCubic.transform(_stand.value);
              return Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  _Floor(side: side, jacket: jacket, stand: t),
                  if (widget.previous != null)
                    _Neighbour(
                        url: api.jacketUrl(widget.previous!, small: true),
                        side: side * 0.30,
                        dx: -side * 0.45,
                        turn: 0.78,
                        lean: _laidBack * (1 - t) * 0.6,
                        settle: t),
                  if (widget.next != null)
                    _Neighbour(
                        url: api.jacketUrl(widget.next!, small: true),
                        side: side * 0.30,
                        dx: side * 0.45,
                        turn: -0.78,
                        lean: _laidBack * (1 - t) * 0.6,
                        settle: t),
                  // Jacket and disc share one transform because they are one object:
                  // the record is inside the sleeve, and tips with it. Sliding out is
                  // a move along the sleeve's own plane, not across the screen.
                  Transform.translate(
                    offset: Offset(-side * 0.09 * t, 0),
                    child: Transform(
                      alignment: Alignment.bottomCenter,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.0011)
                        ..rotateX(_laidBack * (1 - t)),
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          _Disc(spin: _spin, url: api.discUrl(widget.track),
                              size: disc, out: t, jacket: jacket),
                          _Jacket(url: api.jacketUrl(widget.track), size: jacket),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
            ),
          ),
        );
      },
    );
  }
}

/// The ground the record stands on: a soft shadow that spreads as it lies down and
/// tightens under the sleeve as it stands up. Drawn, not an image — one gradient.
class _Floor extends StatelessWidget {
  const _Floor({required this.side, required this.jacket, required this.stand});

  final double side;
  final double jacket;
  final double stand;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(-side * 0.09 * stand, jacket * (0.52 - 0.10 * stand)),
      child: Container(
        width: jacket * (1.15 - 0.25 * stand),
        height: jacket * (0.30 - 0.16 * stand),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.all(Radius.elliptical(jacket, jacket * 0.2)),
          gradient: RadialGradient(
            colors: [
              Colors.black.withValues(alpha: 0.40 - 0.10 * stand),
              Colors.black.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// How far the record lies back at rest. Not quite the full ninety degrees: past about
/// seventy the artwork stops being artwork and becomes a stripe, and this is still the
/// picture of the song you are listening to.
const double _laidBack = 1.20;                 // radians, ≈69°

/// The cardboard. Its pose comes from the stage; here it is just the picture.
class _Jacket extends StatelessWidget {
  const _Jacket({required this.url, required this.size});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: url == null
            ? const SizedBox.shrink()
            : Image.network(url!, fit: BoxFit.contain, gaplessPlayback: true),
      );
}

/// The disc: slides out from behind the jacket and turns while it plays.
class _Disc extends StatelessWidget {
  const _Disc({
    required this.spin,
    required this.url,
    required this.size,
    required this.out,
    required this.jacket,
  });

  final Animation<double> spin;
  final String? url;
  final double size;
  final double out;
  final double jacket;

  @override
  Widget build(BuildContext context) {
    if (url == null) return const SizedBox.shrink();
    // A third of the way out of the sleeve, along the sleeve's own plane.
    final dx = jacket * 0.34 * out;
    const dy = 0.0;

    return Transform.translate(
      offset: Offset(dx, dy),
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: spin,
          builder: (context, child) => Transform.rotate(
            angle: spin.value * 2 * math.pi,
            child: child,
          ),
          // Built once and turned, rather than rebuilt every frame.
          child: SizedBox(
            width: size,
            height: size,
            child: Image.network(url!, fit: BoxFit.contain, gaplessPlayback: true),
          ),
        ),
      ),
    );
  }
}

/// What is coming next, and what just played: turned away at the edges of the stage,
/// so the queue is something you can see rather than something you have to remember.
class _Neighbour extends StatelessWidget {
  const _Neighbour({
    required this.url,
    required this.side,
    required this.dx,
    required this.turn,
    required this.lean,
    required this.settle,
  });

  final String? url;
  final double side;
  final double dx;
  final double turn;
  /// They lean with the record in front of them, so the three read as one crate
  /// rather than as a record with two posters behind it.
  final double lean;
  final double settle;

  @override
  Widget build(BuildContext context) {
    if (url == null) return const SizedBox.shrink();
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0011)
        ..translateByDouble(dx, 0.0, 0.0, 1.0)
        ..rotateY(turn)
        ..rotateX(lean),
      child: Opacity(
        // They fade back a little as the current record stands up and takes over.
        opacity: 0.34 - 0.10 * settle,
        child: SizedBox(
          width: side,
          height: side,
          child: Image.network(url!, fit: BoxFit.contain, gaplessPlayback: true),
        ),
      ),
    );
  }
}
