import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/art_cache.dart';
import '../state/sleeve_board.dart';
import 'sleeve_ink.dart';

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
    this.axis = ShelfAxis.sideways,
    this.board,
  });

  /// The back of whatever is in the middle, and what is written on it.
  final SleeveBoard? board;

  /// Which way the shelf runs. Everything about the movement is the same either way —
  /// the same journey, the same lag, the same drag — laid along a different line.
  final ShelfAxis axis;

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
/// How much room is left between the record and the edge of the screen.
const double _wallClearance = 26;

class Shelf {
  Shelf({this.left, required this.middle, this.right});

  /// How far apart the records stand, given how big they are drawn and how much room
  /// they are standing in.
  ///
  /// Measured from the record rather than from the stage: shrinking the cover used to
  /// leave the neighbours standing where they were, so the shelf grew a gap on either
  /// side and at the smallest size the record sat alone in a field of nothing.
  ///
  /// And opened up as the cover grows. A big cover needs more than the same proportion
  /// of itself between it and the next one — the further the record in the middle
  /// reaches towards the walls, the further out of its way its neighbours have to
  /// stand, or they are behind it rather than beside it.
  static double step(double jacket, double stage) {
    final share = stage <= 0 ? 1.0 : (jacket / stage).clamp(0.4, 1.0);
    return jacket * (0.45 + 0.22 * share);
  }

  /// Where a record stands, in pixels from the middle, when it is [d] places out.
  ///
  /// Nearer the edges the shelf is deeper, so the steps between places get shorter.
  static double along(double jacket, double stage, double d) =>
      step(jacket, stage) * d * (1 - 0.08 * d.abs());

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
    // Two movements and time for both: a record rolls out of its sleeve slowly — that
    // is the weight of it — and then the one being played arrives on the deck.
    duration: const Duration(milliseconds: 1500),
    reverseDuration: const Duration(milliseconds: 520),
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

  /// The record turning over in the air, and which way up it has landed.
  ///
  /// One movement: thrown, so it rises and comes back down, and turning while it is up
  /// there so it lands on its other face. Held apart from everything else on the stage
  /// because it happens to the sleeve rather than to the shelf.
  late final AnimationController _toss = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  )..addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      setState(() {
        _showingBack = !_showingBack;
        _toss.value = 0;
      });
      // Landing face-down is what opens the board: nothing is fetched, and nothing is
      // on screen, until a record is actually turned over.
      final board = widget.board;
      if (board == null) return;
      if (_showingBack) {
        unawaited(board.open(widget.track.id));
      } else {
        board.close();
      }
    });

  /// Which face is towards you at rest.
  bool _showingBack = false;

  /// Whether the record has been pulled out by hand, rather than because it is
  /// playing. Null until somebody says otherwise, and forgotten when the song changes:
  /// a decision about *this* record is not a decision about the next one.
  bool? _discByHand;

  bool get _discWanted => _discByHand ?? widget.playing;

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
        precacheImage(artwork(url), context).catchError((_) {});
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _warmSleeves();
    // The pens sit under the record and the record sits on the stage; the board is the
    // one thing both of them hold, so it is where the way back is kept.
    widget.board?.onTurnBack = _tossIt;
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

    if (widget.track.id != _shelf.middle.id) {
      // A different record: it arrives the right way up and with its own disc put
      // away, whatever was decided about the last one.
      _discByHand = null;
      if (_showingBack) widget.board?.close();
      _showingBack = false;
      _toss.value = 0;
    }

    switch (_shelf.goTo(widget.track,
        previous: widget.previous, next: widget.next)) {
      case ShelfMove.forward:
      case ShelfMove.back:
        // A step along the shelf. Everything slides one place; the sleeve that was
        // next is now the one in the middle, in the place the middle one has left.
        _travel.forward(from: 0);
        // The record on the deck stays exactly where it is. What starts again is the
        // *next* record coming out of its sleeve — and when it arrives it is laid on
        // top of the one playing, which is what happens on a table and what the deck
        // draws. Taking the record off and putting it back for every skip was the
        // sleeve's idea of what was going on, not the deck's.
        _out.value = 0;
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
      if (_discWanted && !_travel.isAnimating && !_scrubbing && !_showingBack) {
        _out.forward();
      }
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      // At rest the record goes back in its sleeve and the turntable stops where it
      // is. It does not lie down: a sleeve tipping over every time you pause reads as
      // something going wrong rather than as something stopping.
      //
      // Unless it was pulled out by hand, in which case it stays where it was put.
      if (!_scrubbing && !_discWanted) _out.reverse();
      _spin.stop();
    }
  }

  /// Tapping the record: out of the sleeve, or back into it.
  ///
  /// The cover is a thing to look at, and while the disc is halfway across it you
  /// cannot. So it goes away when asked and comes back the same way it left — the same
  /// movement, run backwards, rather than a second animation that has to be kept in
  /// step with the first.
  void _toggleDisc() {
    if (_showingBack || _toss.isAnimating) return;
    setState(() => _discByHand = !_discWanted);
    if (_discWanted) {
      _out.forward();
    } else {
      _out.reverse();
    }
  }

  /// The sleeve itself, so a finger on the screen can be asked where it is on it.
  ///
  /// A key rather than arithmetic. Working the position out from the stage's size and
  /// the layout meant assuming the stage is exactly as big as it asked to be and that
  /// the sleeve sits in the middle of it — and it is not: the box is given whatever
  /// space is going, the square inside it is drawn from the corner, and the sleeve is
  /// then scaled and tilted on top of that. Every one of those is an offset, and they
  /// added up to a line landing an inch from the finger. Asking the sleeve where it is
  /// costs one lookup and cannot be wrong.
  final GlobalKey _backKey = GlobalKey();

  bool get _drawable => _showingBack && _toss.value == 0 && widget.board != null;

  /// How far above the fingertip the pen actually is, on screen.
  ///
  /// A finger covers the thing it is pointing at. Everything about drawing on a phone
  /// with one is aiming at a spot you cannot see, and the answer every stylus-less
  /// drawing tool has landed on is the same: put the nib a little above the contact
  /// patch, and show that spot somewhere the hand is not.
  static const double lift = 44;

  /// Where the pen is now, 0 to 1 on the sleeve. Null when nothing is being drawn.
  Offset? _penAt;

  /// Where the finger is, in the stage's own square.
  ///
  /// Kept as well as the point on the sleeve, because the glass is held above the
  /// *hand* — the same distance above it, always. Hanging it off the point on the
  /// sleeve instead meant it moved whenever the sleeve did, flipped to the other side
  /// of the finger near the top edge, and slid along the edges when it was clamped to
  /// stay on the stage. All three read as the glass wandering about on its own.
  Offset? _fingerAt;

  /// The square the stage actually draws in.
  ///
  /// Not this widget's own box: it is given whatever space is going, and the square is
  /// drawn inside that. The glass is painted in the square's coordinates, so the
  /// square is what the sleeve's position has to be measured against — measuring
  /// against the wrong one of the two is the same mistake as before, one level up.
  final GlobalKey _stageKey = GlobalKey();

  /// The sleeve as it is actually drawn, in the stage square's coordinates.
  Rect? _sleeveRect() {
    final box = _backKey.currentContext?.findRenderObject() as RenderBox?;
    final stage = _stageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || stage == null || box.size.width <= 0) return null;
    final topLeft = stage.globalToLocal(box.localToGlobal(Offset.zero));
    // Through the transform rather than from the box's own size: the sleeve is scaled
    // where it is drawn, and how big it looks is the only size that matters here.
    final corner = stage.globalToLocal(
        box.localToGlobal(Offset(box.size.width, box.size.height)));
    return Rect.fromPoints(topLeft, corner);
  }

  Offset01? _on(Offset global) {
    final box = _backKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || box.size.width <= 0) return null;
    // globalToLocal walks back through every transform between here and the screen,
    // which is the scaling, the perspective and the tilt, all of them, exactly.
    final local = box.globalToLocal(global.translate(0, -lift));
    return Offset01(
      (local.dx / box.size.width).clamp(0.0, 1.0),
      (local.dy / box.size.height).clamp(0.0, 1.0),
    );
  }

  void _pen(Offset global, {required bool start}) {
    final at = _on(global);
    final stage = _stageKey.currentContext?.findRenderObject() as RenderBox?;
    if (at == null || stage == null) return;
    if (start) {
      widget.board!.begin(at);
    } else {
      widget.board!.extend(at);
    }
    setState(() {
      _penAt = Offset(at.x, at.y);
      _fingerAt = stage.globalToLocal(global);
    });
  }

  void _liftPen() {
    widget.board?.end();
    setState(() {
      _penAt = null;
      _fingerAt = null;
    });
  }

  /// Thrown in the air, landing on its other face.
  void _tossIt() {
    if (_toss.isAnimating || _shelf.travelling || _scrubbing) return;
    // Not with the record halfway out of it: the two would be turning over together
    // and the disc has no back.
    if (_discWanted) {
      _discByHand = false;
      _out.reverse();
    }
    _toss.forward(from: 0);
  }

  @override
  void dispose() {
    // The board belongs to the record being shown, and this is the thing showing it.
    // Leaving the player with a sleeve face-down used to leave the board open behind
    // it — so the pens turned up again on a screen with no back on it, over a flat
    // cover, or over the next record entirely.
    if (_showingBack) widget.board?.close();
    _travel.dispose();
    _out.dispose();
    _spin.dispose();
    _toss.dispose();
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

  bool get _upright => widget.axis == ShelfAxis.upwards;

  void _dragUpdate(DragUpdateDetails d) {
    _dragged += _upright ? d.delta.dy : d.delta.dx;

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
    // The record playing is not touched by this. A finger going through the covers is
    // looking for the next one, and the one already on the deck keeps turning until
    // something is put on top of it.
  }

  void _dragEnd(DragEndDetails d) {
    _scrubbing = false;
    if (!_shelf.travelling) return;

    final velocity = _upright
        ? d.velocity.pixelsPerSecond.dy
        : d.velocity.pixelsPerSecond.dx;
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

  /// The magnifying glass, held in one place above the hand.
  ///
  /// Directly over the finger and always the same distance above it — not above the
  /// point on the sleeve, and never flipped or nudged aside to keep it on the stage.
  /// A glass that moves relative to the hand holding it is a glass you have to keep
  /// finding, and finding it is the one thing it exists to save you from. It may hang
  /// off the top of the stage; that is fine, and better than it jumping.
  Widget _loupe(double side) {
    final sleeve = _sleeveRect();
    final at = _penAt;
    final finger = _fingerAt;
    final board = widget.board;
    if (sleeve == null || at == null || finger == null || board == null) {
      return const SizedBox.shrink();
    }
    final radius = (side * 0.26).clamp(72.0, 136.0);
    final centre = finger.translate(0, -(radius + 30));

    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: SleeveLoupe(
              board: board,
              card: SleeveCard(),
              sleeve: sleeve,
              at: at,
              centre: centre,
              radius: radius,
              nib: board.nib,
            ),
          ),
        ),
      ),
    );
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
        // Where the deck is: the bottom edge of the stage, which is the line the
        // song's name is written on. Measured from the middle of the cover, because
        // that is where the disc starts from — and the cover does not sit in the
        // middle of the stage, it sits above the space kept for its reflection.
        // The record is the width of the room it is in, less enough that it is not
        // touching the walls. Measured from the screen rather than from the stage:
        // the cover sits inside a page with margins of its own, and a record the
        // width of the stage is a record two thumbs narrower than the phone. It is
        // drawn outside the stage box, which is what the stack's clipBehavior is for.
        //
        // It does not follow the cover's size setting either — making the sleeve
        // smaller is about how much of the shelf you can see, and a record on a deck
        // is the size a record is.
        final screen = MediaQuery.sizeOf(context).width;
        final platter = screen - _wallClearance * 2;
        // Far enough right that the sleeve-sized one is past the edge of the phone.
        final away = screen * 0.85;
        // Where the deck is: the line the song's name is written on, which is the
        // bottom of the stage. Measured from the middle of the cover, because that is
        // where the record is put down — and the cover does not sit in the middle of
        // the stage, it sits above the space kept for its reflection. The last term
        // is the sliver of record left below the cut, so the cut itself lands on the
        // line rather than a little under it.
        final deck = side / 2 +
            jacket * Mirror.defaultDepth / 2 -
            platter * 0.02 +
            // The covers came down, so the deck follows them: what has to stay the
            // same is the band of record below the covers, because that band is where
            // the label is.
            side * 0.02;
        // Where the covers stand is wherever leaves a third of the record showing
        // below them — a record peeking out from behind its sleeve, with its label in
        // the open.
        //
        // Worked out rather than picked, because the two things it sits between both
        // move: the record is the width of the screen and the cover is whatever size
        // somebody set it to. A fixed offset gives a sliver of record at one setting
        // and a cover floating clear of it at another. This gives the same peek at
        // every setting, which is the thing actually being looked at.
        //
        // The clamp is for the largest cover, which is as tall as the whole stage on
        // its own: past that point the peek has to give, or the cover climbs out of
        // the top of the stage and into the buttons above it.
        final peek = platter * 0.34;
        // The record is drawn from its top down to a little past its middle, so the
        // bottom of what is visible is the deck line plus that little.
        final showsTo = deck + platter * 0.02;
        // A cover's own bottom edge, from the middle of the sleeve's box: the box
        // holds the reflection as well, and the reflection is not the cover.
        final edge = jacket * (1 - Mirror.defaultDepth) / 2;
        final coversDown = (showsTo - peek - edge).clamp(-side * 0.06, side * 0.24);
        // The finger covers one shelf place, so the sleeve under it stays under it —
        // and a shelf place is measured from the record, so this follows the record's
        // size as well.
        _reach = Shelf.step(jacket, side);

        return RepaintBoundary(
          child: SizedBox(
          key: _stageKey,
          width: side,
          height: side,
          // One axis only, and it is the one the records travel along — so the other
          // direction still belongs to the page: a drag down closes the player.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Tapping the record puts it back in its sleeve, or takes it out again —
            // unless it is turned over, in which case a tap is a dot of ink.
            onTap: _drawable ? null : _toggleDisc,
            // While the sleeve is face-down every drag is a pen. The shelf keeps
            // still: you are writing on this record, not looking for the next one.
            //
            // From the moment the finger lands, not from the moment it has moved far
            // enough to count as a drag — the glass is most wanted before the line
            // starts, while you are still aiming.
            onPanDown: !_drawable ? null : (d) => _pen(d.globalPosition, start: true),
            onPanUpdate:
                !_drawable ? null : (d) => _pen(d.globalPosition, start: false),
            onPanEnd: !_drawable ? null : (_) => _liftPen(),
            onPanCancel: !_drawable ? null : _liftPen,
            onHorizontalDragStart: _drawable || _upright ? null : _dragStart,
            onHorizontalDragUpdate: _drawable || _upright ? null : _dragUpdate,
            onHorizontalDragEnd: _drawable || _upright ? null : _dragEnd,
            // Up and over. Only where the shelf runs across the screen: where it runs
            // up and down, a swipe up is already how you change record, and one drag
            // meaning two things is how a screen stops being predictable.
            onVerticalDragStart: _upright && !_drawable ? _dragStart : null,
            onVerticalDragUpdate: _upright && !_drawable ? _dragUpdate : null,
            onVerticalDragEnd: _drawable
                ? null
                : _upright
                    ? _dragEnd
                    : (d) {
                        if (d.velocity.pixelsPerSecond.dy < -520) _tossIt();
                      },
            child: AnimatedBuilder(
              animation: Listenable.merge([_travel, _out, _toss]),
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
                // How far towards face-down the middle record is: one when it is, zero
                // when it is not, and part-way through the throw.
                final flipped = _showingBack ? 1 - _toss.value : _toss.value;
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
                    // The record first, the covers over it: a record peeks out from
                    // behind its sleeve, it does not lie across the front of it.
                    if (!_showingBack)
                      Deck(
                        url: api.discUrl(widget.track),
                        spin: _spin,
                        size: platter,
                        drop: deck,
                        arriving: Curves.easeInOutCubic.transform(_out.value),
                      ),
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
                        upright: _upright,
                        // Only the record in the middle turns over; the ones beside it
                        // are somebody else's.
                        toss: card.slot == 0 ? _toss.value : 0.0,
                        showingBack: card.slot == 0 && _showingBack,
                        board: card.slot == 0 ? widget.board : null,
                        backKey: card.slot == 0 ? _backKey : null,
                        // Bigger while it is turned over. A sleeve you are drawing on
                        // wants the room, and the neighbours it is borrowing it from
                        // are not what anybody is looking at.
                        grow: card.slot == 0 ? 1 + 0.30 * flipped : 1.0,
                        jacket: jacket,
                        stage: side,
                        down: coversDown,
                        drop: deck,
                        platter: platter,
                        leaving: away,
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
                        out: Curves.easeInOutCubic.transform(_out.value),
                      ),
                    // The glass, over everything, in the stage's own coordinates —
                    // outside the sleeve so that nothing about the sleeve's own scale
                    // or tilt applies to it. It is being held above the record, not
                    // lying on it.
                    if (_penAt != null) _loupe(side),
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
    required this.upright,
    required this.toss,
    required this.showingBack,
    required this.board,
    required this.backKey,
    required this.grow,
    required this.jacket,
    required this.stage,
    required this.down,
    required this.drop,
    required this.platter,
    required this.leaving,
    required this.jacketUrl,
    required this.discUrl,
    required this.spin,
    required this.out,
  });

  final double d;

  /// The shelf runs up the screen rather than across it.
  final bool upright;

  /// How far through being thrown in the air, 0 to 1. Zero for everything that is not
  /// the record in the middle.
  final double toss;

  /// Which face was towards you before the throw started.
  final bool showingBack;

  /// The back of this record, and what is on it. Only the one in the middle has one.
  final SleeveBoard? board;

  /// Put on the sleeve's own box, so a finger can ask it where it is rather than
  /// having its position worked out from the layout.
  final GlobalKey? backKey;

  /// Larger than its place on the shelf would make it — a record turned over to be
  /// drawn on wants the room.
  final double grow;

  final double jacket;

  /// How big the stage is, which is how much room the shelf has.
  final double stage;

  /// How far below the middle of the stage the covers stand.
  final double down;

  /// How far below the middle of this cover the deck is — the line the disc comes to
  /// rest on, which is the bottom of the stage and the top of the song's name.
  final double drop;

  /// How wide the record itself is drawn: the screen, less its margins.
  final double platter;

  /// How far right the record goes on its way off the screen.
  final double leaving;
  final String? jacketUrl;
  final String? discUrl;
  final Animation<double> spin;
  final double out;

  @override
  Widget build(BuildContext context) {
    if (jacketUrl == null) return const SizedBox.shrink();

    final away = d.abs();
    if (away > 2.2) return const SizedBox.shrink();

    final along = Shelf.along(jacket, stage, d);
    final scale = (1 - 0.42 * away.clamp(0.0, 1.6)).clamp(0.24, 1.0);
    // Turned away from the middle: about the upright axis on a shelf, about the
    // horizontal one on a stack — a record lifted off a pile tips towards you rather
    // than swinging round.
    final turn = -0.78 * d.clamp(-1.4, 1.4);
    final fade = away <= 1 ? 1.0 - 0.62 * away : (1.9 - away).clamp(0.0, 1.0) * 0.38;

    // Only whatever is in the middle has its record out, and only as far as it is
    // actually in the middle: a sleeve halfway to the edge has put it away again. And
    // nothing is out of a sleeve that is in the air — the disc would be turning over
    // with it, and a record has no back.
    final centre = (1 - away).clamp(0.0, 1.0);
    final showing = out * centre * (1 - toss.clamp(0.0, 1.0));

    // Faded by the pictures themselves rather than by an Opacity around them.
    // Opacity between 0 and 1 saves a layer, and there is one of these for every
    // sleeve on stage on every frame of every journey — four full-size offscreen
    // buffers a frame was most of why the movement dropped frames at all.
    final dim = fade.clamp(0.0, 1.0);

    return Transform(
      alignment: Alignment.center,
      transform: upright
          ? (Matrix4.identity()
            ..setEntry(3, 2, 0.0011)
            ..translateByDouble(0.0, along + down, 0.0, 1.0)
            ..rotateX(-turn)
            ..scaleByDouble(scale * grow, scale * grow, 1.0, 1.0))
          : (Matrix4.identity()
            ..setEntry(3, 2, 0.0011)
            ..translateByDouble(along, down, 0.0, 1.0)
            ..rotateY(turn)
            ..scaleByDouble(scale * grow, scale * grow, 1.0, 1.0)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            key: backKey,
            width: jacket,
            height: jacket,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // Behind the sleeve on the way out, in front of it once it is clear.
                //
                // That order *is* the movement: a record comes out from behind its
                // cover, and once it is out it is the thing in front. Drawing it
                // behind the whole way meant it slid out and then sat half-hidden, and
                // drawing it in front the whole way meant it appeared to come out of
                // thin air rather than out of the sleeve.
                // Only the record on its way out of this sleeve. What it becomes —
                // the record on the deck — belongs to the stage rather than to any
                // one cover, and stays where it is while the covers move about
                // behind it.
                if (showing > 0.01 && showing < Disc.leaves)
                  Disc(
                      spin: spin,
                      url: discUrl,
                      sleeve: jacket * 0.92,
                      away: leaving,
                      out: showing,
                      dim: dim),
                _Face(
                    url: jacketUrl,
                    size: jacket,
                    dim: dim,
                    toss: toss,
                    showingBack: showingBack,
                    board: board),
              ],
            ),
          ),
          // What the record is standing on, said as quietly as possible. The
          // cardboard only — the disc is turning, and a turning reflection is
          // something the eye follows instead of the record itself.
          //
          // It goes out as the record comes out, because the record comes to rest in
          // exactly the band the reflection lies in: something standing on a shelf
          // hides the shelf's shine, and a reflected cover ghosted across the label
          // was the whole reason the record read as hidden rather than as behind.
          //
          // Skipped once it is dim enough not to be seen, or once the record has
          // taken its place: it is the one thing here that genuinely needs a layer of
          // its own, and a mask drawn at no strength at all costs exactly as much as
          // one you can see.
          if (dim > 0.25 && !upright && toss == 0 && showing < 0.99)
            RepaintBoundary(
              child: Mirror(
                size: jacket,
                strength: 0.28 * (1 - showing.clamp(0.0, 1.0)),
                child: showingBack
                    ? _Back(size: jacket, dim: dim, board: board)
                    : _Jacket(url: jacketUrl, size: jacket, dim: dim),
              ),
            )
          else
            // Kept as space either way, so the sleeve sits at the same height on the
            // stage whether or not it is standing on anything. On a stack there is
            // nothing under a record but the next record, so no reflection.
            SizedBox(width: jacket, height: jacket * Mirror.defaultDepth),
        ],
      ),
    );
  }
}

/// The sleeve, thrown in the air and landing on its other face.
///
/// One movement rather than two. It rises and comes back down on a single arc, turning
/// while it is up there, and it grows a little on the way — which is what something
/// coming towards you does, and what makes it read as thrown rather than as a picture
/// being rotated in place.
class _Face extends StatelessWidget {
  const _Face({
    required this.url,
    required this.size,
    required this.dim,
    required this.toss,
    required this.showingBack,
    this.board,
  });

  final String? url;
  final double size;
  final double dim;
  final double toss;
  final bool showingBack;
  final SleeveBoard? board;

  @override
  Widget build(BuildContext context) {
    Widget front() => _Jacket(url: url, size: size, dim: dim);
    // Nothing is drawn on it mid-throw: the board is not a surface until it has landed.
    Widget back() =>
        _Back(size: size, dim: dim, board: toss > 0 ? null : board);

    if (toss <= 0) {
      return showingBack ? back() : front();
    }

    // Up and down again: highest halfway through, back where it started at the end.
    final rise = math.sin(toss * math.pi);
    // Half a turn, eased so it is quickest at the top of the arc where the record is
    // furthest away and the turn is least readable anyway.
    final turned = Curves.easeInOutSine.transform(toss) * math.pi;
    // Past a quarter turn the far side is towards you.
    final far = turned > math.pi / 2;
    final showing = far != showingBack;

    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0012)
        ..translateByDouble(0.0, -size * 0.34 * rise, 0.0, 1.0)
        ..scaleByDouble(1 + 0.12 * rise, 1 + 0.12 * rise, 1.0, 1.0)
        ..rotateX(-turned),
      // The far side of a rotated thing is a mirror of the near side, so whatever is
      // painted on it has to be turned over again to be the right way up.
      child: showing
          ? Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()..rotateX(math.pi),
              child: back(),
            )
          : front(),
    );
  }
}

/// The back of the sleeve: bare board.
///
/// Drawn here rather than fetched, because there is nothing about it that belongs to
/// this record — every sleeve in the world has roughly this back until somebody prints
/// on it. Kraft card, the grain of the stock, the seam where it is folded, and corners
/// a shade darker from being handled.
class _Back extends StatelessWidget {
  const _Back({required this.size, this.dim = 1.0, this.board});

  final double size;
  final double dim;

  /// What has been written on this one, if anybody has been given the chance.
  final SleeveBoard? board;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Opacity(
          opacity: dim.clamp(0.0, 1.0),
          child: CustomPaint(
            painter: SleeveCard(),
            foregroundPainter:
                board == null ? null : SleeveInk(board: board!, size01: size),
            size: Size(size, size),
          ),
        ),
      );
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
            : Image(
                image: artwork(url!),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                opacity: AlwaysStoppedAnimation(dim)),
      );
}

/// The disc: comes out from behind the jacket, and turns while it plays.
class Disc extends StatelessWidget {
  const Disc({
    super.key,
    required this.spin,
    required this.url,
    required this.sleeve,
    required this.away,
    required this.out,
    this.dim = 1.0,
  });

  final Animation<double> spin;
  final String? url;

  /// The record as it comes out of the cover, which is the cover's own size.
  final double sleeve;

  /// How far right it has to go to be off the screen entirely.
  final double away;

  final double out;
  final double dim;

  /// When the record has left the sleeve and the one on the deck starts to arrive.
  ///
  /// Two things happen here, and they are not the same object: the record slides out
  /// of the side of its cover and off the screen, and then *the record* — the one
  /// being played, the width of the deck — appears where it is going to be played and
  /// clicks down into place. A small disc crawling to the middle of the screen and
  /// growing would be a picture being resized; this is a record being taken out of a
  /// sleeve and put on.
  static const double leaves = 0.62;

  /// How far the sleeve-sized record has slid out, 0 to 1, and how far the one on the
  /// deck has arrived, 0 to 1. Only one of them is ever happening.
  ///
  /// Out at an even, unhurried pace — a record has weight, and a cover does not throw
  /// one across the room — and then gone quickly at the end of it rather than fading
  /// for the whole journey.
  static double sliding(double out) =>
      Curves.easeInOutSine.transform((out / leaves).clamp(0.0, 1.0));

  /// How much of it is left to see, as it goes.
  static double leaving(double gone) => (1 - (gone - 0.82) / 0.18).clamp(0.0, 1.0);

  static double arriving(double out) =>
      Curves.easeOutCubic.transform(((out - leaves) / (1 - leaves)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    if (url == null) return const SizedBox.shrink();
    final gone = sliding(out);
    if (gone <= 0) return const SizedBox.shrink();

    final along = gone * away;
    return Transform.translate(
      offset: Offset(along, 0),
      child: RepaintBoundary(
        child: spinning(
          url: url!,
          spin: spin,
          size: sleeve,
          // Rolling, not sliding: a disc that moves without turning is a picture being
          // dragged, and one that turns by the distance it covers over its own radius
          // is a record rolling out of its cover.
          roll: along / (sleeve / 2),
          // Gone in the last fifth of the way out: it leaves, rather than being cut
          // off by the edge of the phone or dimming the whole way across it.
          fade: dim * leaving(gone),
        ),
      ),
    );
  }

  /// A record, turning. Built once and rotated, rather than rebuilt every frame.
  static Widget spinning({
    required String url,
    required Animation<double> spin,
    required double size,
    required double roll,
    required double fade,
  }) =>
      AnimatedBuilder(
        animation: spin,
        builder: (context, child) => Transform.rotate(
          // A record turns clockwise, which from above is the way a clock does.
          angle: -(spin.value * 2 * math.pi + roll),
          child: child,
        ),
        child: SizedBox(
          width: size,
          height: size,
          child: Image(
              image: artwork(url),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              opacity: AlwaysStoppedAnimation(fade)),
        ),
      );
}

/// The record that is playing, on the deck, with the arm on it.
///
/// It belongs to the stage rather than to any one cover, and that is the point: the
/// covers move about behind it — a skip, a drag through the shelf — and the record
/// stays exactly where it is, turning, until the next one is laid on top of it. A
/// record being taken off and put back for every skip was the sleeve's idea of what
/// was happening, not the deck's.
class Deck extends StatefulWidget {
  const Deck({
    super.key,
    required this.url,
    required this.spin,
    required this.size,
    required this.drop,
    required this.arriving,
  });

  /// The record that is playing now.
  final String? url;
  final Animation<double> spin;

  /// How wide a record is: the screen, less its margins.
  final double size;

  /// How far below the middle of the stage the deck is.
  final double drop;

  /// How far the record that is playing has arrived, 0 to 1.
  final double arriving;

  @override
  State<Deck> createState() => _DeckState();
}

class _DeckState extends State<Deck> {
  /// What is already on the platter, while something new is being laid on it.
  String? _under;

  @override
  void didUpdateWidget(Deck old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url && old.url != null) {
      // Whatever was playing stays where it is until the new one covers it.
      _under = old.url;
    }
    if (widget.arriving >= 1 || widget.url == null) _under = null;
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    final settled = _under;
    if (url == null && settled == null) return const SizedBox.shrink();
    final arriving = widget.arriving.clamp(0.0, 1.0);

    return IgnorePointer(
      // The stage is a square the size of the cover's box; a record is wider than
      // that. Without this, the Stack it sits in shrinks it back to the box — which
      // is why a record "the width of the screen" kept coming out cover-sized.
      child: OverflowBox(
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: SizedBox(
          width: widget.size,
          height: widget.size + widget.drop,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              if (settled != null) _record(settled, 1, 0),
              if (url != null && arriving > 0)
                _record(
                  url,
                  Curves.easeIn.transform((arriving * 1.8).clamp(0.0, 1.0)),
                  // Down the last few pixels as it lands: the click of a record being
                  // set on the platter.
                  (1 - Curves.easeOutBack.transform(arriving)) * widget.size * 0.06,
                ),
              // The arm comes down once the record has stopped moving, and lifts when
              // the next one is on its way.
              Positioned.fill(
                child: Tonearm(
                  radius: widget.size / 2,
                  drop: widget.drop,
                  landed: Tonearm.lowering(
                      settled == null ? arriving : math.max(arriving, 0.0)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One record on the platter: turning, dropped to the deck, and faded into the line
  /// it is cut on rather than sliced at it — a hard edge across a record reads as a
  /// mistake, and one sinking into the deck reads as a record on a deck.
  Widget _record(String url, double fade, double rise) {
    final record = Disc.spinning(
        url: url, spin: widget.spin, size: widget.size, roll: 0, fade: fade);

    // Drawn in two pieces, and that is about memory rather than looks.
    //
    // A mask is an offscreen layer the size of whatever it masks, made again for every
    // frame the record turns — a screen-wide one, three times a second, on a phone
    // that is already holding the engine, the canvas and a queue's worth of artwork.
    // On an iPhone that is how a tab gets reloaded out from under somebody. So the
    // record above the fade is drawn plainly, with no layer at all, and only the inch
    // of it that actually fades is masked.
    const solid = 0.40;
    const gone = 0.52;
    return Transform.translate(
      offset: Offset(0, widget.drop - rise),
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRect(
                  clipper: _Band(0, solid),
                  child: record,
                ),
              ),
              Positioned.fill(
                child: ClipRect(
                  clipper: _Band(solid, gone),
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [Colors.white, Colors.transparent],
                    ).createShader(Rect.fromLTWH(
                        0, solid * widget.size, rect.width,
                        (gone - solid) * widget.size)),
                    child: record,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A horizontal slice of something, as fractions of its height.
class _Band extends CustomClipper<Rect> {
  const _Band(this.from, this.to);
  final double from;
  final double to;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
      0, size.height * from, size.width, size.height * to);

  @override
  bool shouldReclip(_Band old) => old.from != from || old.to != to;
}

/// The arm, riding on the record.
///
/// It comes down after the disc has settled, not with it: a tonearm is lowered onto a
/// record that is already turning, and doing the two together looks like one object
/// arriving in two pieces. Parked it sits off to the right and slightly up; playing it
/// rests on the disc, a little in from the edge, where a needle actually sits.
///
/// Drawn rather than pictured — a line, a counterweight, a head — because at this size
/// a photograph of an arm is four grey pixels, and because it has to be the colour of
/// whatever the app is wearing.
class Tonearm extends StatelessWidget {
  const Tonearm({
    super.key,
    required this.radius,
    required this.drop,
    required this.landed,
    this.dim = 1.0,
  });

  /// The disc's radius, which is the whole of the scale of this.
  final double radius;

  /// How far down the disc is right now, in pixels from the middle of the cover.
  final double drop;

  /// 0 parked, 1 down on the record.
  final double landed;

  final double dim;

  /// When the arm starts coming down, as a fraction of the disc's own journey.
  ///
  /// Only once the disc has all but stopped. The last fifth of the way is the disc
  /// settling; the arm follows that.
  static double lowering(double out) =>
      Curves.easeOutCubic.transform(((out - 0.8) / 0.2).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    if (landed <= 0) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        painter: _ArmPainter(
          radius: radius,
          drop: drop,
          landed: landed,
          colour: Theme.of(context).colorScheme.onSurface,
          dim: dim,
        ),
      ),
    );
  }
}

class _ArmPainter extends CustomPainter {
  _ArmPainter({
    required this.radius,
    required this.drop,
    required this.landed,
    required this.colour,
    required this.dim,
  });

  final double radius;
  final double drop;
  final double landed;
  final Color colour;
  final double dim;

  @override
  void paint(Canvas canvas, Size size) {
    // The middle of the disc, in this box's coordinates: the box is the cover, and the
    // disc has dropped by `drop` from its middle.
    final middle = Offset(size.width / 2, size.height / 2 + drop);
    // The post it turns on: outside the record, up and to the right, where the post
    // stands on a deck.
    final pivot = middle + Offset(radius * 0.80, -radius * 1.00);

    // Where the needle sits, and where it waits. Only the angle between them changes;
    // everything else about the arm is rigid, which is what makes it read as one
    // object being swung rather than a line being redrawn.
    final playing = middle + Offset(-radius * 0.12, -radius * 0.46);
    final parked = middle + Offset(radius * 0.58, -radius * 0.78);
    final head = Offset.lerp(parked, playing, landed)!;

    final reach = head - pivot;
    final angle = math.atan2(reach.dy, reach.dx);
    final length = reach.distance;

    // Drawn the way a part is drawn in a manual: one weight of line, flat metal, no
    // highlights or shadows. It was a little chrome sculpture before — gradients along
    // the tube, a lit edge, a blurred shadow under it — and at this size all of that
    // amounts to noise around a shape that was already saying tonearm on its own.
    final metal = Color.lerp(colour, const Color(0xFFEFEAE1), 0.85)!
        .withValues(alpha: dim);
    final dark = Color.lerp(colour, const Color(0xFF5F584F), 0.72)!
        .withValues(alpha: dim);

    final tube = radius * 0.017;
    final line = Paint()
      ..color = metal
      ..strokeWidth = tube * 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final solid = Paint()..color = metal;

    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(angle);

    // The tube: two straight runs with one bend in them, which is the shape of the
    // thing and the whole of what has to be said about it.
    final bent = Path()
      ..moveTo(-length * 0.26, 0)
      ..lineTo(length * 0.55, 0)
      ..lineTo(length, radius * 0.055);
    canvas.drawPath(bent, line);

    // The counterweight: a plain cylinder at the back of it.
    final weight = radius * 0.070;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(-length * 0.28, 0),
            width: weight * 2.1,
            height: weight * 1.7),
        Radius.circular(weight * 0.45),
      ),
      solid,
    );
    canvas.restore();

    // The head, square to the groove rather than to the arm.
    //
    // A groove is a circle around the middle of the record, so the cartridge sits
    // across the tangent at the point the needle is touching — which is at right
    // angles to the line from the middle of the record to the needle, and has nothing
    // to do with the angle of the arm. Getting the head to that angle is the entire
    // reason a tonearm is bent at all.
    final spoke = head - middle;
    final groove = math.atan2(spoke.dy, spoke.dx) + math.pi / 2;
    canvas.save();
    canvas.translate(head.dx, head.dy);
    canvas.rotate(groove);
    final headLength = radius * 0.17;
    final headDepth = radius * 0.075;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: headLength, height: headDepth),
        Radius.circular(headDepth * 0.25),
      ),
      solid,
    );
    // The needle under the front of it: one short mark, because that is where the
    // record is actually being touched.
    canvas.drawLine(
      Offset(-headLength * 0.30, headDepth * 0.5),
      Offset(-headLength * 0.30, headDepth * 1.15),
      Paint()
        ..color = dark
        ..strokeWidth = headDepth * 0.16
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();

    // The post, drawn last so the arm comes out of it rather than over it.
    canvas.drawCircle(pivot, radius * 0.060, solid);
    canvas.drawCircle(pivot, radius * 0.024, Paint()..color = dark);
  }

  @override
  bool shouldRepaint(_ArmPainter old) =>
      old.radius != radius ||
      old.drop != drop ||
      old.landed != landed ||
      old.colour != colour ||
      old.dim != dim;
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
    this.depth = defaultDepth,
    this.strength = 0.28,
  });

  /// How much of the height is reflected, and how much room to leave for it.
  ///
  /// A quarter. A whole mirrored copy is a puddle and a third of one reached far
  /// enough down the screen to sit behind the song's title — but a sixth, dimmed to
  /// almost nothing, was a thing you had to be told was there. This is the inch of
  /// light a record picks up from whatever it is standing on, and it is meant to be
  /// seen.
  static const double defaultDepth = 0.24;

  final Widget child;
  final double size;
  final double depth;

  /// How bright the brightest part of it is — the edge touching the record.
  final double strength;

  /// Where the fade is sampled. Enough points that a straight line between any two of
  /// them is indistinguishable from the curve.
  static const List<double> fadeStops = [0.0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1.0];

  /// How much of the reflection is left, [t] of the way down it.
  ///
  /// A smoothstep, and it took three goes to arrive at one. A straight ramp to zero has
  /// a corner at the end, and the eye finds that corner and reads it as the bottom edge
  /// of a picture — which is the one thing a reflection must not have. Replacing it
  /// with a steep decay hid the corner but spent the whole visible fade in the first
  /// third of the band, so the reflection appeared to stop short and the rest of it was
  /// already invisible.
  ///
  /// This is flat at the top, steepest through the middle, and levels into nothing at
  /// the very bottom: its slope is zero at both ends, which is what fading out means
  /// and what neither of the others did.
  static double fadeAt(double t) => 1 - t * t * (3 - 2 * t);

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
              for (final t in fadeStops)
                Colors.white.withValues(alpha: strength * fadeAt(t)),
            ],
            stops: fadeStops,
          ).createShader(bounds),
          // Clipped *inside* the mask, which is the whole of the white fringe.
          //
          // A ShaderMask paints its shader over its own rectangle and nothing else, and
          // dstIn leaves anything outside that rectangle alone — so the rest of the
          // reflected cover, which is a whole album tall, sat below at full brightness.
          // A clip on the outside cut it at the same line the mask ends on, and the
          // antialiased edge of that clip kept a sliver of it: one bright row, exactly
          // where the reflection is meant to have faded to nothing. Clipping first
          // means there is no unmasked content for the edge to keep.
          child: ClipRect(
            child: OverflowBox(
            alignment: Alignment.topCenter,
            maxHeight: size,
            // Flipped about its own middle, so the copy stays in the box and its top
            // edge is the record's bottom edge — which is what a reflection is.
            //
            // Flipping about the top sent the whole copy *upwards* instead, out of
            // this box and straight over the cover above it, so every sleeve was
            // wearing an upside-down picture of itself across its bottom third.
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()..scaleByDouble(1.0, -1.0, 1.0, 1.0),
              child: child,
            ),
          ),
          ),
        ),
    );
  }
}
