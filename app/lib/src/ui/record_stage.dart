import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'swipe.dart';

/// The record on the stage, and the two either side of it.
///
/// Three places on a shelf — left, middle, right — and every sleeve is somewhere along
/// the line between them. Skipping does not slide a picture off and drop another one
/// in: the middle record travels out to the left, the right-hand one arrives in the
/// middle it just left, and the next one along comes in from off-stage. One journey,
/// one set of positions, and every sleeve genuinely ends up where the one before it was.
///
/// The disc belongs to whichever record is in the middle: it slides out of the sleeve
/// while the song plays and goes back in when it stops. Its turning is its own
/// animation inside a repaint boundary, so a record spinning does not repaint the two
/// sleeves beside it sixty times a second.
class RecordStage extends StatefulWidget {
  const RecordStage({
    super.key,
    required this.track,
    required this.playing,
    this.previous,
    this.next,
    this.onNext,
    this.onPrevious,
    this.scale = 0.74,
  });

  /// How much of the stage the middle record takes. The rest is where its neighbours
  /// stand, so this trades "how big is the record" against "how much of the next one
  /// can be seen" — which is a matter of taste and is therefore a setting.
  final double scale;

  final Track track;
  final bool playing;
  final Track? previous;
  final Track? next;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;

  @override
  State<RecordStage> createState() => _RecordStageState();
}

/// One sleeve, and where it is on the line. `slot` is -1, 0 or 1 at rest.
class _Card {
  const _Card(this.track, this.slot);
  final Track track;
  final double slot;
}

class _RecordStageState extends State<RecordStage> with TickerProviderStateMixin {
  /// How far along the journey between one arrangement and the next, 0 to 1. The
  /// direction is [_heading]: +1 means everything moves one place to the left.
  late final AnimationController _travel = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  /// The disc, out of the sleeve and back in. Separate from the journey because a
  /// record can start and stop playing without anything moving along the shelf.
  late final AnimationController _out = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
    reverseDuration: const Duration(milliseconds: 340),
  );

  /// One turn every 1.8 s, which is 33⅓ rpm — the speed the record would really run.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  int _heading = 0;

  /// What is on the shelf right now. Held separately from the widget so a skip can be
  /// *travelled to* rather than appearing already finished.
  Track? _left;
  late Track _middle;
  Track? _right;

  /// The sleeve coming in from off-stage during a journey.
  Track? _incoming;

  @override
  void initState() {
    super.initState();
    _left = widget.previous;
    _middle = widget.track;
    _right = widget.next;
    if (widget.playing) {
      _out.value = 1;
      _spin.repeat();
    }
    _travel.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      // Arrived: the arrangement the journey was heading for is now simply the truth.
      setState(() {
        _left = widget.previous;
        _middle = widget.track;
        _right = widget.next;
        _incoming = null;
        _heading = 0;
        _travel.value = 0;
      });
      // And the record that has just come to rest in the middle comes out.
      if (widget.playing) _out.forward();
    });
  }

  /// Decode the neighbours now rather than when they arrive on stage.
  ///
  /// An image that has never been drawn is decoded the first frame it is needed, and
  /// that frame is the one in the middle of the journey — which is a stutter exactly
  /// when the eye is following something.
  void _warmSleeves() {
    final api = context.read<AppState>().api;
    for (final track in [widget.previous, widget.next, widget.track]) {
      if (track == null) continue;
      for (final url in [api.jacketUrl(track, small: false), api.discUrl(track)]) {
        if (url == null) continue;
        precacheImage(NetworkImage(url), context).catchError((_) {});
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _warmSleeves();
  }

  @override
  void didUpdateWidget(RecordStage old) {
    super.didUpdateWidget(old);
    if (old.next?.id != widget.next?.id || old.previous?.id != widget.previous?.id) {
      _warmSleeves();
    }

    if (widget.track.id != _middle.id) {
      final forwards = _right?.id == widget.track.id;
      final backwards = _left?.id == widget.track.id;

      if (forwards || backwards) {
        // A step along the shelf. Everything slides one place; the sleeve that was
        // next is now the one in the middle, in the place the middle one has left.
        _heading = forwards ? 1 : -1;
        _incoming = forwards ? widget.next : widget.previous;
        _travel.forward(from: 0);
        // The record goes back into its sleeve on the way out, rather than blinking
        // off the screen — one movement, the way it happens on a table. The next one
        // slides out when it arrives, which the playing branch below takes care of.
        _out.reverse();
      } else {
        // Somewhere else entirely — a different queue, a tap on a distant row. There
        // is no journey between those, so the shelf is simply restocked.
        _left = widget.previous;
        _middle = widget.track;
        _right = widget.next;
        _incoming = null;
        _heading = 0;
        _travel.value = 0;
        _out.value = 0;
      }
    } else if (old.previous?.id != widget.previous?.id ||
        old.next?.id != widget.next?.id) {
      // The neighbours changed under us — the queue was edited. No journey, just the
      // new company.
      if (!_travel.isAnimating) {
        _left = widget.previous;
        _right = widget.next;
      }
    }

    if (widget.playing) {
      // Not while a sleeve is still travelling: a disc sliding out of something that
      // is halfway across the stage is two movements fighting.
      if (!_travel.isAnimating) _out.forward();
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      // At rest the record goes back in its sleeve and the turntable stops where it
      // is. It does not lie down: a sleeve tipping over every time you pause reads as
      // something going wrong rather than as something stopping.
      _out.reverse();
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _travel.dispose();
    _out.dispose();
    _spin.dispose();
    super.dispose();
  }

  /// Everything on stage, with the slot each one occupies at rest.
  List<_Card> _cards() {
    final out = <_Card>[
      if (_left != null) _Card(_left!, -1),
      _Card(_middle, 0),
      if (_right != null) _Card(_right!, 1),
    ];
    if (_incoming != null && _heading != 0) {
      // Waiting just off-stage, on the side it will come in from.
      out.add(_Card(_incoming!, 2.0 * _heading));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final api = context.read<AppState>().api;

    return LayoutBuilder(
      builder: (context, c) {
        final side =
            math.min(c.maxWidth, c.maxHeight.isFinite ? c.maxHeight : c.maxWidth);
        final jacket = side * widget.scale.clamp(0.5, 1.0);

        return RepaintBoundary(
          child: SizedBox(
          width: side,
          height: side,
          child: DragFollow(
            onSwipeLeft: widget.onNext,
            onSwipeRight: widget.onPrevious,
            horizontalTravel: side * 0.22,
            child: AnimatedBuilder(
              animation: Listenable.merge([_travel, _out]),
              builder: (context, _) {
                final cards = _cards();

                // Each sleeve sets off a moment after the one in front of it.
                //
                // Moving them in lockstep is correct and lifeless — a row of pictures
                // sliding as one board. Records on a shelf do not do that: the one
                // you are pulling moves first and the rest follow, and the tail of
                // that is most of what makes the movement feel like something rather
                // than like a transition. So each card's progress is the same curve,
                // started late in proportion to how far behind the leading sleeve it
                // is, and everything is still exactly in place when the journey ends.
                double progressFor(double slot) {
                  if (_heading == 0) return 0;
                  // Counted from the sleeve leading the way: the one travelling out.
                  final behind = (_heading > 0 ? slot + 1 : 1 - slot).clamp(0.0, 3.0);
                  const lag = 0.10;
                  final start = (behind * lag).clamp(0.0, 0.34);
                  final local =
                      ((_travel.value - start) / (1 - start)).clamp(0.0, 1.0);
                  return Curves.easeInOutCubic.transform(local) * _heading;
                }

                // Painted back to front: the ones furthest from the middle first, so
                // the record being listened to is in front of its neighbours however
                // far along the journey everything is.
                final middle = Curves.easeInOutCubic.transform(_travel.value) *
                    _heading;
                final ordered = [...cards]..sort((a, b) =>
                    (b.slot - middle).abs().compareTo((a.slot - middle).abs()));

                return Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    for (final card in ordered)
                      _Sleeve(
                        // Keyed by the place as well as the record: a queue of two
                        // has the same track to the left and to the right of you, and
                        // two children of one Stack may not share a key. The place is
                        // fixed for the length of a journey, so identity still holds
                        // while everything moves.
                        key: ValueKey('${card.track.id}@${card.slot}'),
                        // Where it is *now*: its own place, less how far the whole
                        // shelf has travelled. At p = 1 the right-hand sleeve sits at
                        // 0 — the middle — which is the point of the whole thing.
                        d: card.slot - progressFor(card.slot),
                        side: side,
                        jacket: jacket,
                        jacketUrl: api.jacketUrl(card.track,
                            small: (card.slot - middle).abs() > 0.5),
                        discUrl: api.discUrl(card.track),
                        spin: _spin,
                        out: _out.value,
                      ),
                  ],
                );
              },
            ),
          ),
        ),
        );
      },
    );
  }
}

/// One record, placed by how far it is from the middle.
///
/// [d] is a distance in shelf places: 0 is the middle, ±1 are the two beside it, and
/// anything beyond that is off-stage. Everything about the pose — where it sits, how
/// big it is, how far it is turned away, whether its disc is showing — is a function
/// of that one number, which is what makes the movement continuous rather than a set
/// of separate animations that have to be kept in step.
class _Sleeve extends StatelessWidget {
  const _Sleeve({
    super.key,
    required this.d,
    required this.side,
    required this.jacket,
    required this.jacketUrl,
    required this.discUrl,
    required this.spin,
    required this.out,
  });

  final double d;
  final double side;
  final double jacket;
  final String? jacketUrl;
  final String? discUrl;
  final Animation<double> spin;
  final double out;

  @override
  Widget build(BuildContext context) {
    if (jacketUrl == null) return const SizedBox.shrink();

    final away = d.abs();
    if (away > 2.2) return const SizedBox.shrink();

    // Nearer the edges the shelf is deeper, so the steps between places get shorter.
    final x = side * 0.45 * d * (1 - 0.08 * away);
    final scale = (1 - 0.42 * away.clamp(0.0, 1.6)).clamp(0.24, 1.0);
    final turn = -0.78 * d.clamp(-1.4, 1.4);
    final fade = away <= 1 ? 1.0 - 0.62 * away : (1.9 - away).clamp(0.0, 1.0) * 0.38;

    // Only whatever is in the middle has its record out, and only as far as it is
    // actually in the middle: a sleeve halfway to the edge has put it away again.
    final centre = (1 - away).clamp(0.0, 1.0);
    final showing = out * centre;

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0011)
        ..translateByDouble(x, 0.0, 0.0, 1.0)
        ..rotateY(turn)
        ..scaleByDouble(scale, scale, 1.0, 1.0),
      child: Opacity(
        opacity: fade.clamp(0.0, 1.0),
        child: SizedBox(
          width: jacket,
          height: jacket,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              if (showing > 0.01)
                _Disc(
                    spin: spin,
                    url: discUrl,
                    size: jacket * 0.92,
                    out: showing,
                    jacket: jacket),
              _Jacket(url: jacketUrl, size: jacket),
            ],
          ),
        ),
      ),
    );
  }
}

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
    return Transform.translate(
      offset: Offset(jacket * 0.34 * out, 0),
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
