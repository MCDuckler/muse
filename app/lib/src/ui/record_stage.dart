import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';

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
    this.before,
    this.after,
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

  /// Two away, either side. Only ever seen off-stage at the edge of the frame — but a
  /// journey driven by a finger can be held halfway for as long as somebody likes, and
  /// an empty space where the fourth sleeve should be is visible when it is.
  final Track? before;
  final Track? after;

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

/// What a change of track turned out to be.
enum ShelfMove {
  /// The same record is still in the middle; only its neighbours may have changed.
  none,

  /// One step along the shelf, to the right-hand record or the left-hand one.
  forward,
  back,

  /// Nowhere near: a different queue, a tap on a distant row. Nothing to travel.
  restock,

  /// Back where it started: a journey was in flight and the record it was leaving is
  /// the one wanted again. The journey is not finished, it is undone.
  abandon,

  /// Already on the way there. A finger dragged the shelf most of the way and let go;
  /// the player is only now catching up with what the hand already did.
  resume,
}

/// Which record stands where, kept apart from the animation that moves them.
///
/// This is the whole of the bookkeeping the stage does, and every way the movement
/// used to break was a mistake in it rather than in the drawing — so it lives on its
/// own, where it can be checked without a screen.
class Shelf {
  Shelf({this.left, required this.middle, this.right});

  Track? left;
  Track middle;
  Track? right;

  /// The sleeve waiting off-stage for the journey in flight, on the side it comes in
  /// from.
  Track? incoming;

  /// +1 while everything is moving one place to the left, -1 the other way, 0 at rest.
  int heading = 0;

  bool get travelling => heading != 0;

  /// The record that will be in the middle when the journey in flight finishes.
  Track? get destination =>
      heading > 0 ? right : (heading < 0 ? left : null);

  /// Start a journey by hand: a finger dragging the shelf rather than a skip arriving.
  ///
  /// Says whether there is anything that way. The sleeve coming in from off-stage is
  /// two along, which the stage is told about precisely so that a drag held halfway
  /// has something to show at the edge.
  bool begin(int direction, {Track? before, Track? after}) {
    if (direction > 0 && right == null) return false;
    if (direction < 0 && left == null) return false;
    heading = direction;
    incoming = direction > 0 ? after : before;
    return true;
  }

  /// Take the journey in flight to be finished, right now.
  ///
  /// Where a journey ends is known before it starts — the right-hand record becomes
  /// the middle one, and the one waiting off-stage takes its place — so an interrupted
  /// journey has an answer, and it is this one.
  void settle() {
    if (heading > 0 && right != null) {
      left = middle;
      middle = right!;
      right = incoming;
    } else if (heading < 0 && left != null) {
      right = middle;
      middle = left!;
      left = incoming;
    }
    incoming = null;
    heading = 0;
  }

  /// The record in the middle is now [track]. Says how the shelf got there.
  ///
  /// Skipping twice inside half a second used to be measured against where the records
  /// were when the *first* skip began, and by then the answer was no longer one of the
  /// three places on the shelf — so the second skip fell through to a restock and the
  /// whole thing snapped. Settling first makes it a step along the shelf like any other.
  ShelfMove goTo(Track track, {Track? previous, Track? next}) {
    // Already going there. A drag that was let go past the point of no return started
    // this journey before the player was told; finishing it is all that is left.
    if (travelling && destination?.id == track.id) {
      incoming = heading > 0 ? next : previous;
      return ShelfMove.resume;
    }
    if (track.id != middle.id && travelling) settle();

    if (track.id == middle.id) {
      // Skipped forward and straight back again, inside the half second the journey
      // takes. The sleeves are mid-stage and the record they were leaving is wanted
      // again: the honest answer is to take them back, not to finish a journey to
      // somewhere nobody is going any more and then snap.
      if (travelling) return ShelfMove.abandon;
      // Otherwise the queue was edited under us. New company, no journey.
      left = previous;
      right = next;
      return ShelfMove.none;
    }
    if (right?.id == track.id) {
      heading = 1;
      incoming = next;
      return ShelfMove.forward;
    }
    if (left?.id == track.id) {
      heading = -1;
      incoming = previous;
      return ShelfMove.back;
    }
    left = previous;
    middle = track;
    right = next;
    incoming = null;
    heading = 0;
    return ShelfMove.restock;
  }

  /// The journey came back to where it started. Nothing moved after all.
  void abandon({Track? previous, Track? next}) {
    incoming = null;
    heading = 0;
    left = previous;
    right = next;
  }

  /// The journey finished on its own: the arrangement it was heading for is the truth.
  void arrive({Track? previous, required Track track, Track? next}) {
    left = previous;
    middle = track;
    right = next;
    incoming = null;
    heading = 0;
  }
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

  /// What is on the shelf right now. Held separately from the widget so a skip can be
  /// *travelled to* rather than appearing already finished.
  late final Shelf _shelf =
      Shelf(left: widget.previous, middle: widget.track, right: widget.next);

  /// A finger on the shelf, moving it by hand.
  ///
  /// The gesture used to slide the whole stage sideways and spring back — a picture of
  /// a swipe rather than the thing itself. Now the drag *is* the journey: the sleeves
  /// travel exactly as far as the hand takes them, in both directions, and letting go
  /// either carries the movement through or takes it back. Nothing else moves.
  bool _scrubbing = false;

  /// How far the finger has gone, in pixels, signed. Left is forward.
  double _dragged = 0;

  /// How far a finger must travel for one whole step along the shelf. Set from the
  /// stage's own width, so the sleeves keep pace with the hand.
  double _reach = 240;

  @override
  void initState() {
    super.initState();
    if (widget.playing) {
      _out.value = 1;
      _spin.repeat();
    }
    _travel.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        // Arrived: the arrangement the journey was heading for is now the truth.
        setState(() {
          _shelf.arrive(
              previous: widget.previous, track: widget.track, next: widget.next);
          _travel.value = 0;
        });
      } else if (status == AnimationStatus.dismissed && _shelf.travelling) {
        // Or came back: an abandoned journey ends where it began.
        setState(() =>
            _shelf.abandon(previous: widget.previous, next: widget.next));
      } else {
        return;
      }
      // Either way, the record now at rest in the middle comes out.
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
    for (final track in [
      widget.previous,
      widget.next,
      widget.track,
      widget.before,
      widget.after,
    ]) {
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
    if (old.next?.id != widget.next?.id ||
        old.previous?.id != widget.previous?.id ||
        old.after?.id != widget.after?.id ||
        old.before?.id != widget.before?.id) {
      _warmSleeves();
    }

    switch (_shelf.goTo(widget.track,
        previous: widget.previous, next: widget.next)) {
      case ShelfMove.forward:
      case ShelfMove.back:
        // A step along the shelf. Everything slides one place; the sleeve that was
        // next is now the one in the middle, in the place the middle one has left.
        _travel.forward(from: 0);
        // The record goes back into its sleeve on the way out, rather than blinking
        // off the screen — one movement, the way it happens on a table. The next one
        // slides out when it arrives, which the playing branch below takes care of.
        _out.reverse();
      case ShelfMove.resume:
        // The hand started this one. It is already running; nothing to do but let it
        // finish where it was always going.
        break;
      case ShelfMove.abandon:
        // Not while the hand is still on it. The player rebuilds this a few times a
        // second as the song plays, and every one of those rebuilds arrives with the
        // record that is still in the middle — which is the same thing an undone skip
        // looks like. Taking it back under the finger cancelled the drag mid-gesture.
        if (_scrubbing) break;
        _travel.reverse();
        _out.reverse();
      case ShelfMove.restock:
        _travel.value = 0;
        _out.value = 0;
      case ShelfMove.none:
        break;
    }

    if (widget.playing) {
      // Not while a sleeve is still travelling, and not while a finger is holding one
      // halfway across the stage: a disc sliding out of something that is moving is
      // two movements fighting, and under a finger it is a third.
      if (!_travel.isAnimating && !_scrubbing) _out.forward();
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      // At rest the record goes back in its sleeve and the turntable stops where it
      // is. It does not lie down: a sleeve tipping over every time you pause reads as
      // something going wrong rather than as something stopping.
      if (!_scrubbing) _out.reverse();
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

  // ------------------------------------------------------------ dragging by hand

  void _dragStart(DragStartDetails _) {
    _travel.stop();
    _scrubbing = true;
    // A drag that catches a journey mid-flight takes it over from exactly where it is,
    // rather than snapping it back to the start.
    _dragged = _shelf.travelling ? -_travel.value * _reach * _shelf.heading : 0;
  }

  void _dragUpdate(DragUpdateDetails d) {
    _dragged += d.delta.dx;

    // Pulling the shelf to the left brings the next record in; to the right, the one
    // before. Changing your mind mid-drag changes which journey is being scrubbed.
    final wanted = _dragged < 0 ? 1 : -1;
    if (_shelf.heading != wanted) {
      setState(() {
        if (_shelf.travelling) {
          _shelf.abandon(previous: widget.previous, next: widget.next);
        }
        _shelf.begin(wanted, before: widget.before, after: widget.after);
      });
    }
    if (!_shelf.travelling) {
      // Nothing that way: the shelf does not move, and the drag does not build up a
      // debt that has to be paid back before the other direction answers.
      _dragged = 0;
      return;
    }

    final along = (_dragged.abs() / _reach).clamp(0.0, 1.0);
    _travel.value = along;
    // The record goes back into its sleeve as the sleeve leaves, at the speed of the
    // hand — the same movement a skip makes, only this time somebody is doing it.
    if (widget.playing) _out.value = 1 - along;
  }

  void _dragEnd(DragEndDetails d) {
    _scrubbing = false;
    if (!_shelf.travelling) return;

    final velocity = d.velocity.pixelsPerSecond.dx;
    // A flick counts, but only a flick the way the shelf is already going.
    final flung =
        velocity.abs() > 420 && velocity.sign == -_shelf.heading.toDouble();
    final go = _shelf.heading > 0 ? widget.onNext : widget.onPrevious;

    if (go != null && (_travel.value >= 0.4 || flung)) {
      // Past the point of no return: carry the movement through from where the hand
      // left it, and tell the player what just happened.
      _travel.forward();
      go();
    } else {
      // Not far enough. Back the way it came, and the record comes out again when it
      // gets there — see the status listener.
      _travel.reverse();
    }
  }

  /// Everything on stage, with the slot each one occupies at rest.
  List<_Card> _cards() {
    final out = <_Card>[
      if (_shelf.left != null) _Card(_shelf.left!, -1),
      _Card(_shelf.middle, 0),
      if (_shelf.right != null) _Card(_shelf.right!, 1),
    ];
    if (_shelf.incoming != null && _shelf.travelling) {
      // Waiting just off-stage, on the side it will come in from.
      out.add(_Card(_shelf.incoming!, 2.0 * _shelf.heading));
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
        // One shelf place is 0.45 of the stage; the finger covers the same ground, so
        // the sleeve under it stays under it.
        _reach = side * 0.45;

        return RepaintBoundary(
          child: SizedBox(
          width: side,
          height: side,
          // Horizontal only, so a drag up or down still belongs to the page.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: _dragStart,
            onHorizontalDragUpdate: _dragUpdate,
            onHorizontalDragEnd: _dragEnd,
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
                final heading = _shelf.heading;
                double progressFor(double slot) {
                  if (heading == 0) return 0;
                  // Counted from the sleeve leading the way: the one travelling out.
                  final behind = (heading > 0 ? slot + 1 : 1 - slot).clamp(0.0, 3.0);
                  const lag = 0.10;
                  final start = (behind * lag).clamp(0.0, 0.34);
                  final local =
                      ((_travel.value - start) / (1 - start)).clamp(0.0, 1.0);
                  return Curves.easeInOutCubic.transform(local) * heading;
                }

                // Painted back to front: the ones furthest from the middle first, so
                // the record being listened to is in front of its neighbours however
                // far along the journey everything is.
                final middle =
                    Curves.easeInOutCubic.transform(_travel.value) * heading;
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
                        // The same picture wherever it stands. Choosing the small
                        // one for the sleeves off to the side meant the URL changed
                        // halfway through the journey, and a changed URL is a second
                        // download and a fresh decode landing in the middle of the
                        // movement — which is precisely where a stutter is visible.
                        // It saved nothing either: _warmSleeves already fetches the
                        // full-size one for all three.
                        jacketUrl: api.jacketUrl(card.track, small: false),
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

    // Faded by the pictures themselves rather than by an Opacity around them.
    // Opacity between 0 and 1 saves a layer, and there is one of these for every
    // sleeve on stage on every frame of every journey — four full-size offscreen
    // buffers a frame was most of why the movement dropped frames at all.
    final dim = fade.clamp(0.0, 1.0);

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0011)
        ..translateByDouble(x, 0.0, 0.0, 1.0)
        ..rotateY(turn)
        ..scaleByDouble(scale, scale, 1.0, 1.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
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
                      jacket: jacket,
                      dim: dim),
                _Jacket(url: jacketUrl, size: jacket, dim: dim),
              ],
            ),
          ),
          // What the record is standing on, said as quietly as possible. The
          // cardboard only — the disc is turning, and a turning reflection is
          // something the eye follows instead of the record itself.
          //
          // Skipped once it is dim enough not to be seen: it is the one thing here
          // that genuinely needs a layer of its own, and the sleeves it would be
          // under at that point are themselves nearly gone.
          if (dim > 0.25)
            RepaintBoundary(
              child: Mirror(
                size: jacket,
                child: _Jacket(url: jacketUrl, size: jacket, dim: dim),
              ),
            )
          else
            SizedBox(width: jacket, height: jacket * 0.34),
        ],
      ),
    );
  }
}

/// The cardboard. Its pose comes from the stage; here it is just the picture.
class _Jacket extends StatelessWidget {
  const _Jacket({required this.url, required this.size, this.dim = 1.0});

  final String? url;
  final double size;

  /// How present it is, 0 to 1 — applied while the picture is painted rather than by
  /// an Opacity above it, which would cost an offscreen buffer every frame.
  final double dim;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: url == null
            ? const SizedBox.shrink()
            : Image.network(url!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                opacity: AlwaysStoppedAnimation(dim)),
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
    this.dim = 1.0,
  });

  final Animation<double> spin;
  final String? url;
  final double size;
  final double out;
  final double jacket;
  final double dim;

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
            child: Image.network(url!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                opacity: AlwaysStoppedAnimation(dim)),
          ),
        ),
      ),
    );
  }
}


/// A reflection under something, on a surface that is barely there.
///
/// The stage had a shadow under the sleeve once and it read as a dark blob. This is
/// the other way of saying the same thing — that the record is standing on something —
/// and it works because it is almost invisible: a short, flipped, quickly fading copy,
/// dim enough that you would not point at it, and missed if it were gone.
class Mirror extends StatelessWidget {
  const Mirror({
    super.key,
    required this.child,
    required this.size,
    this.depth = 0.34,
    this.strength = 0.20,
  });

  final Widget child;
  final double size;

  /// How much of the height is reflected. A whole mirrored copy looks like a puddle;
  /// a third of one looks like a surface.
  final double depth;

  /// How bright the brightest part of it is — the edge touching the record.
  final double strength;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * depth,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: strength),
            Colors.white.withValues(alpha: 0),
          ],
          // Most of the fade happens early: a reflection that lingers reads as a
          // second picture rather than as light on a floor.
          stops: const [0, 0.85],
        ).createShader(bounds),
        child: OverflowBox(
          alignment: Alignment.topCenter,
          maxHeight: size,
          child: Transform(
            alignment: Alignment.topCenter,
            transform: Matrix4.identity()..scaleByDouble(1.0, -1.0, 1.0, 1.0),
            child: child,
          ),
        ),
      ),
    );
  }
}
