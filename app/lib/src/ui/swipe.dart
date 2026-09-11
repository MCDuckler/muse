import 'package:flutter/material.dart';

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
  Widget build(BuildContext context) => widget.builder(
        context,
        SwipingNow(progress: _pushed.clamp(0.0, 1.0), child: widget.child),
        _report,
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

  void _onStart(DragStartDetails _) {
    _spring.stop();
    _locked = false;
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

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _onStart,
      onPanUpdate: _onUpdate,
      onPanEnd: _onEnd,
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget hint(bool forward, double progress) {
      final ground = forward ? scheme.primaryContainer : scheme.errorContainer;
      final ink = forward ? scheme.onPrimaryContainer : scheme.onErrorContainer;
      return Align(
        alignment: forward ? Alignment.centerLeft : Alignment.centerRight,
        // As tall as the row it is behind. It was a small pill floating in the middle
        // of the gap, which reads as a thing lying under the list rather than as the
        // row's own back — and the same gesture in the queue already uncovered a
        // full-height panel, so the two did not look like one idea.
        child: FractionallySizedBox(
          heightFactor: 1,
          child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: ground.withValues(alpha: 0.25 + 0.75 * progress),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(forward ? icon : awayIcon, size: 18, color: ink),
              // The words appear only once the drag is far enough to mean it.
              if (progress > 0.5) ...[
                const SizedBox(width: 8),
                Text(forward ? label : awayLabel,
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: ink)),
              ],
            ],
          ),
        ),
        ),
      );
    }

    return DragFollow(
      horizontalTravel: 76,
      onSwipeRight: onSwipe,
      onSwipeLeft: onSwipeAway,
      behind: (context, progress, forward) =>
          (forward ? onSwipe : onSwipeAway) == null
              ? const SizedBox.shrink()
              : hint(forward, progress),
      child: child,
    );
  }
}
