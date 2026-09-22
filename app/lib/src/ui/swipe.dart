import 'package:flutter/material.dart';

import 'feel.dart';
import 'mag.dart';
import 'motion.dart';

/// A drag that the content actually follows.
///
/// The first pass used velocity alone: nothing moved until the finger lifted, and the
/// gesture either fired or did not with no sign of which. Here the child tracks the
/// finger, springs back when the drag is too small, and completes when it is not — so
/// the gesture is legible while it happens and cancellable half-way.
/// How far the row this is inside is being pushed, from 0 to 1.
///
/// A row is not only the thing being dragged: it also holds controls that belong to
/// the list rather than to the song — the grip you hold to move it. Those have no
/// business staying put while the row slides out from under them, and the row itself
/// cannot tell them, because the drag is handled above it. This is how it tells them.
class SwipingNow extends InheritedWidget {
  const SwipingNow({super.key, required this.progress, required super.child});

  final double progress;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SwipingNow>()?.progress ?? 0;

  @override
  bool updateShouldNotify(SwipingNow old) => old.progress != progress;
}

/// A row pushed away by a Dismissible, telling its own insides how far.
///
/// Dismissible knows exactly how far it has been dragged and nothing below it can
/// hear: the row is handed to it as a finished widget. This keeps the number where
/// [SwipingNow] can be read from, and the row is built once and passed through rather
/// than rebuilt on every frame of the drag.
class Pushable extends StatefulWidget {
  const Pushable({super.key, required this.child, required this.builder});

  /// The row. Built by the caller, wrapped here, and handed back to [builder].
  final Widget child;

  /// Builds whatever does the pushing around the row — a Dismissible, usually —
  /// given the row and the reporter to hand to its `onUpdate`.
  final Widget Function(
      BuildContext context, Widget row, void Function(double) report) builder;

  @override
  State<Pushable> createState() => _PushableState();
}

class _PushableState extends State<Pushable> {
  double _pushed = 0;

  void _report(double progress) {
    // A hundredth of a row is below what anybody can see and above what a rebuild is
    // worth; Dismissible reports every pixel.
    if ((progress - _pushed).abs() < 0.01) return;
    setState(() => _pushed = progress);
  }

  @override
  Widget build(BuildContext context) => SwipingNow(
        // Over the whole of it rather than only the row, so what the Dismissible
        // uncovers can hear the drag too and draw itself to it. The row is the same
        // widget on every frame, so it is not rebuilt for this; only the parts that
        // ask are.
        progress: _pushed.clamp(0.0, 1.0),
        child: widget.builder(context, widget.child, _report),
      );
}

class DragFollow extends StatefulWidget {
  const DragFollow({
    super.key,
    required this.child,
    this.onSwipeLeft,
    this.onSwipeRight,
    this.onSwipeUp,
    this.onSwipeDown,
    this.horizontalTravel = 90,
    this.verticalTravel = 90,
    this.completeAt = 0.45,
    this.fadeWithDrag = false,
    this.behind,
  });

  final Widget child;
  final VoidCallback? onSwipeLeft;
  final VoidCallback? onSwipeRight;
  final VoidCallback? onSwipeUp;
  final VoidCallback? onSwipeDown;

  /// How far the content moves at a completed drag. Deliberately short: this is
  /// feedback, not a page transition.
  final double horizontalTravel;
  final double verticalTravel;

  /// Fraction of the travel at which releasing completes rather than springs back.
  final double completeAt;
  final bool fadeWithDrag;

  /// Drawn underneath while the drag is happening, told how far along it is (0 to 1)
  /// and which way it is going. This is how a row says what letting go will do without
  /// anything showing when nobody is touching it.
  final Widget Function(BuildContext context, double progress, bool forward)? behind;

  @override
  State<DragFollow> createState() => _DragFollowState();
}

class _DragFollowState extends State<DragFollow> with SingleTickerProviderStateMixin {
  late final AnimationController _spring = AnimationController.unbounded(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() => setState(() {}));

  Offset _offset = Offset.zero;
  bool _horizontal = false;
  bool _locked = false;

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  bool get _hasHorizontal => widget.onSwipeLeft != null || widget.onSwipeRight != null;
  bool get _hasVertical => widget.onSwipeUp != null || widget.onSwipeDown != null;

  /// Whether the drag has been far enough to do something, as of the last frame.
  ///
  /// Kept so the tick happens *at* the line rather than when the finger lifts: a
  /// gesture with a threshold is a mechanism, and a mechanism says when it has caught.
  /// Told after the fact, all somebody can do is find out they guessed right.
  bool _caught = false;

  void _onStart(DragStartDetails _) {
    _spring.stop();
    _locked = false;
    _caught = false;
  }

  void _onUpdate(DragUpdateDetails d) {
    final delta = d.delta;
    if (!_locked) {
      // Decide once whether this is a horizontal or a vertical gesture, so a slightly
      // diagonal drag does not jitter between the two.
      if (delta.distance < 0.5) return;
      _horizontal = delta.dx.abs() > delta.dy.abs();
      if (_horizontal && !_hasHorizontal) return;
      if (!_horizontal && !_hasVertical) return;
      _locked = true;
    }

    setState(() {
      if (_horizontal) {
        final dx = _offset.dx + delta.dx;
        _offset = Offset(_resist(dx, widget.horizontalTravel), 0);
      } else {
        final dy = _offset.dy + delta.dy;
        _offset = Offset(0, _resist(dy, widget.verticalTravel));
      }
    });

    // Crossing the line, and crossing back: both are worth saying, because a drag that
    // has gone too far and come back should not feel the same as one that has not gone
    // far enough yet.
    final travel = _horizontal ? widget.horizontalTravel : widget.verticalTravel;
    final moved = (_horizontal ? _offset.dx : _offset.dy).abs();
    final caught = moved >= travel * widget.completeAt;
    if (caught != _caught) {
      _caught = caught;
      if (caught) feel(Feel.edge);
    }
  }

  /// Past the travel distance the content keeps moving, but grudgingly — the drag
  /// stays connected to the finger without sliding off the screen.
  double _resist(double value, double travel) {
    final limit = travel * 1.6;
    if (value.abs() <= travel) return value;
    final overshoot = value.abs() - travel;
    final damped = travel + overshoot * 0.35;
    return (damped > limit ? limit : damped) * value.sign;
  }

  void _onEnd(DragEndDetails d) {
    if (!_locked) return _settle();
    final velocity = _horizontal
        ? d.velocity.pixelsPerSecond.dx
        : d.velocity.pixelsPerSecond.dy;
    final travel = _horizontal ? widget.horizontalTravel : widget.verticalTravel;
    final moved = _horizontal ? _offset.dx : _offset.dy;
    final past = moved.abs() >= travel * widget.completeAt;
    final flung = velocity.abs() > 550;

    if (past || flung) {
      final forward = (flung ? velocity : moved) > 0;
      final action = _horizontal
          ? (forward ? widget.onSwipeRight : widget.onSwipeLeft)
          : (forward ? widget.onSwipeDown : widget.onSwipeUp);
      if (action != null) {
        feel(Feel.commit);
        action();
        _settle();
        return;
      }
    }
    _settle();
  }

  void _settle() {
    final from = _offset;
    _spring
      ..value = 0
      ..duration = const Duration(milliseconds: 260);
    final animation = CurvedAnimation(parent: _spring, curve: Curves.easeOutBack);
    void tick() => setState(() {
          _offset = Offset.lerp(from, Offset.zero, animation.value) ?? Offset.zero;
        });
    _spring.removeListener(tick);
    _spring.addListener(tick);
    _spring.animateTo(1.0).whenComplete(() {
      _spring.removeListener(tick);
      if (mounted) setState(() => _offset = Offset.zero);
    });
  }

  @override
  Widget build(BuildContext context) {
    final travel = _horizontal ? widget.horizontalTravel : widget.verticalTravel;
    final progress =
        (_horizontal ? _offset.dx.abs() : _offset.dy.abs()) / (travel == 0 ? 1 : travel);
    final opacity =
        widget.fadeWithDrag ? (1 - progress.clamp(0.0, 1.0) * 0.45) : 1.0;

    final moved = Transform.translate(
      offset: _offset,
      child: Opacity(
        opacity: opacity,
        child: SwipingNow(progress: progress.clamp(0.0, 1.0), child: widget.child),
      ),
    );

    // Only the directions this row actually uses.
    //
    // A pan recogniser claims a drag whichever way it goes, so a row that only does
    // something sideways still took hold of an upward drag and gave nothing back —
    // which is the gesture the player bar uses to open, and it never arrived. Asking
    // for one axis lets the other one be somebody else's.
    final both = _hasHorizontal && _hasVertical;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: both ? _onStart : null,
      onPanUpdate: both ? _onUpdate : null,
      onPanEnd: both ? _onEnd : null,
      onHorizontalDragStart: both || !_hasHorizontal ? null : _onStart,
      onHorizontalDragUpdate: both || !_hasHorizontal ? null : _onUpdate,
      onHorizontalDragEnd: both || !_hasHorizontal ? null : _onEnd,
      onVerticalDragStart: both || !_hasVertical ? null : _onStart,
      onVerticalDragUpdate: both || !_hasVertical ? null : _onUpdate,
      onVerticalDragEnd: both || !_hasVertical ? null : _onEnd,
      child: widget.behind == null || _offset == Offset.zero
          ? moved
          : Stack(
              children: [
                Positioned.fill(
                  child: widget.behind!(
                      context,
                      progress.clamp(0.0, 1.0),
                      (_horizontal ? _offset.dx : _offset.dy) > 0),
                ),
                moved,
              ],
            ),
    );
  }
}


/// A row you can push aside to do one thing to it.
///
/// The row follows the finger and no further: it moves the distance it is dragged, up
/// to a short limit, and springs back. It never leaves the frame — going off the edge
/// is what a list says when a row is being *removed*, and this row is staying exactly
/// where it is.
class SwipeAction extends StatelessWidget {
  const SwipeAction({
    super.key,
    required this.child,
    this.onSwipe,
    this.icon = Icons.playlist_play,
    this.label = 'Play next',
    this.onSwipeAway,
    this.awayIcon = Icons.delete_outline,
    this.awayLabel = 'Remove',
  });

  final Widget child;

  /// Pulled towards you — the additive one.
  final VoidCallback? onSwipe;
  final IconData icon;
  final String label;

  /// Pushed away — the destructive one, where a list has one.
  final VoidCallback? onSwipeAway;
  final IconData awayIcon;
  final String awayLabel;

  @override
  Widget build(BuildContext context) => DragFollow(
        horizontalTravel: 84,
        onSwipeRight: onSwipe,
        onSwipeLeft: onSwipeAway,
        behind: (context, progress, forward) =>
            (forward ? onSwipe : onSwipeAway) == null
                ? const SizedBox.shrink()
                : SwipeBack(
                    away: !forward,
                    icon: forward ? icon : awayIcon,
                    label: forward ? label : awayLabel,
                    progress: progress,
                  ),
        child: child,
      );
}

/// What a row uncovers as it is pushed: the thing letting go will do.
///
/// A tinted back the height and width of the row — the row is a card now and covers
/// it, so only the strip the drag has opened shows — with a badge at the open edge
/// that grows with the drag and fills at the line where letting go means it. The
/// word comes with the fill, printed small under the glyph the way a caption sits
/// under a picture, so it fits in the strip rather than sliding half under the row.
///
/// Told how far by [progress], or by the [SwipingNow] above it when it is the back of
/// a Dismissible, which reports the drag to that and nothing else.
class SwipeBack extends StatelessWidget {
  const SwipeBack({
    super.key,
    required this.icon,
    required this.label,
    this.away = false,
    this.progress,
    this.caughtAt = 0.45,
  });

  final IconData icon;
  final String label;

  /// Pushed away — the destructive one — rather than pulled towards.
  final bool away;

  /// 0 to 1 of the travel. Null to read it from the row being pushed.
  final double? progress;

  /// The fraction of the travel at which letting go completes. Matches DragFollow.
  final double caughtAt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = (progress ?? SwipingNow.of(context)).clamp(0.0, 1.0);
    final caught = p >= caughtAt;
    final ink = away ? scheme.error : scheme.primary;
    final onInk = away ? scheme.onError : scheme.onPrimary;
    final still = stillness(context);
    return FractionallySizedBox(
      heightFactor: 1,
      widthFactor: 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ink.withValues(alpha: 0.10 + 0.16 * p),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Align(
          alignment: away ? Alignment.centerRight : Alignment.centerLeft,
          // As wide as the strip a full drag opens, with the badge in the middle of
          // it: a word set off the edge slid half under the row.
          child: SizedBox(
            width: 84,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedScale(
                  scale: caught ? 1 : 0.7 + 0.25 * (p / caughtAt).clamp(0.0, 1.0),
                  duration: still ? Duration.zero : Motion.quick,
                  curve: caught ? Motion.pop : Motion.enter,
                  child: AnimatedContainer(
                    duration: still ? Duration.zero : Motion.quick,
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: caught ? ink : ink.withValues(alpha: 0.18),
                    ),
                    child: Icon(icon, size: 17, color: caught ? onInk : ink),
                  ),
                ),
                AnimatedOpacity(
                  opacity: caught ? 1 : 0,
                  duration: still ? Duration.zero : Motion.quick,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(label.toUpperCase(),
                        maxLines: 1,
                        style: Mag.flag(7.5, color: ink)
                            .copyWith(letterSpacing: 0.5)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
