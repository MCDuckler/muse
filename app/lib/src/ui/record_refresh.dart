import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';

/// Pull to refresh, as a record being put on.
///
/// Pulling a list down brings a small record down from the top of it; pulled far enough
/// the arm swings over and the needle is on, and letting go there plays it — the record
/// turns for as long as the page takes to come back. Everywhere a list can be pulled it
/// is this, rather than the platform's grey circle on a page that is otherwise ink and
/// paper.
///
/// The pulling itself is still Flutter's: when it counts as a pull, how far is far
/// enough, what letting go early does. Only what is drawn is ours, from what the
/// indicator says about itself and from how far the list has been dragged.
class RecordRefresh extends StatefulWidget {
  const RecordRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.notificationPredicate = defaultScrollNotificationPredicate,
    this.edgeOffset = 0,
  });

  final RefreshCallback onRefresh;
  final Widget child;
  final ScrollNotificationPredicate notificationPredicate;

  /// How far below the top of the list the record hangs, for a list that starts under
  /// something.
  final double edgeOffset;

  @override
  State<RecordRefresh> createState() => _RecordRefreshState();
}

class _RecordRefreshState extends State<RecordRefresh> with TickerProviderStateMixin {
  RefreshIndicatorStatus? _status;

  /// How far it has been pulled, as a share of far enough. One is the needle down.
  double _pull = 0;

  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  /// The record going back up when it is over, from wherever it was.
  late final AnimationController _leave =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  double _leftFrom = 0;

  @override
  void dispose() {
    _spin.dispose();
    _leave.dispose();
    super.dispose();
  }

  bool get _busy =>
      _status == RefreshIndicatorStatus.snap || _status == RefreshIndicatorStatus.refresh;

  void _said(RefreshIndicatorStatus? status) {
    if (!mounted) return;
    final was = _status;
    setState(() => _status = status);
    if (_busy) {
      if (!_spin.isAnimating && !stillness(context)) _spin.repeat();
      return;
    }
    _spin.stop();
    final over = status == null ||
        status == RefreshIndicatorStatus.done ||
        status == RefreshIndicatorStatus.canceled;
    if (over && was != null) {
      _leftFrom = was == RefreshIndicatorStatus.refresh || was == RefreshIndicatorStatus.snap
          ? 1
          : _pull.clamp(0.0, 1.0);
      _pull = 0;
      _leave.forward(from: 0);
    }
  }

  bool _scrolled(ScrollNotification n) {
    if (!widget.notificationPredicate(n) || _busy) return false;
    // The same measure the indicator itself uses: a quarter of the list's height is
    // far enough.
    final far = n.metrics.viewportDimension * 0.25;
    if (far <= 0) return false;
    double? next;
    if (n is OverscrollNotification && n.overscroll < 0 && n.dragDetails != null) {
      // A list that stops at its top: what is pulled past it is handed over here.
      next = _pull - n.overscroll / far;
    } else if (n is ScrollUpdateNotification && n.metrics.pixels < 0) {
      // A list that stretches past its top: it says how far it has been stretched.
      next = -n.metrics.pixels / far;
    } else if (n is ScrollUpdateNotification &&
        n.dragDetails != null &&
        (n.scrollDelta ?? 0) > 0 &&
        _pull > 0) {
      // Pushed back up again without letting go.
      next = _pull - n.scrollDelta! / far;
    } else if (n is ScrollEndNotification && _status == null) {
      next = 0;
    }
    if (next != null) {
      final clamped = next.clamp(0.0, 1.5);
      if (clamped != _pull) setState(() => _pull = clamped);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      // Exactly the room the list would have had without this around it.
      fit: StackFit.passthrough,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _scrolled,
          child: RefreshIndicator.noSpinner(
            onRefresh: widget.onRefresh,
            onStatusChange: _said,
            notificationPredicate: widget.notificationPredicate,
            child: widget.child,
          ),
        ),
        Positioned(
          top: widget.edgeOffset,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: Listenable.merge([_spin, _leave]),
              builder: (context, _) {
                final leaving = _leave.isAnimating
                    ? _leftFrom * (1 - Curves.easeInCubic.transform(_leave.value))
                    : 0.0;
                final shown = _busy ? 1.0 : math.max(_pull.clamp(0.0, 1.0), leaving);
                if (shown <= 0.001) return const SizedBox(height: 0);
                // Past far enough it keeps coming a little, the way anything pulled does.
                final beyond = _busy ? 0.0 : (_pull - 1).clamp(0.0, 0.5);
                const size = 44.0;
                return SizedBox(
                  height: size + 40,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Transform.translate(
                      offset: Offset(
                          0,
                          -size +
                              (size + 14) * Curves.easeOutCubic.transform(shown) +
                              10 * beyond),
                      child: Opacity(
                        opacity: shown.clamp(0.0, 1.0),
                        child: CustomPaint(
                          size: const Size(size + 18, size),
                          painter: _SmallDeck(
                            turn: _spin.value,
                            // The arm comes over in the last stretch of the pull, and
                            // is down for as long as the page is being fetched.
                            arm: _busy || _status == RefreshIndicatorStatus.armed
                                ? 1
                                : ((shown - 0.55) / 0.45).clamp(0.0, 1.0),
                            vinyl: const Color(0xFF141210),
                            label: scheme.primary,
                            metal: scheme.onSurface,
                            ground: scheme.surface,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _SmallDeck extends CustomPainter {
  const _SmallDeck({
    required this.turn,
    required this.arm,
    required this.vinyl,
    required this.label,
    required this.metal,
    required this.ground,
  });

  final double turn;
  final double arm;
  final Color vinyl;
  final Color label;
  final Color metal;
  final Color ground;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.height / 2;
    final c = Offset(r, r);
    // A little paper around it, so it reads over whatever the list has under it.
    canvas.drawCircle(c, r + 3, Paint()..color = ground);
    canvas.drawCircle(c, r, Paint()..color = vinyl);
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = Colors.white.withValues(alpha: 0.10);
    for (final at in [0.86, 0.72, 0.58]) {
      canvas.drawCircle(c, r * at, groove);
    }
    // The label, with a mark off-centre: a plain disc turning is a disc standing still.
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(turn * 2 * math.pi);
    canvas.drawCircle(Offset.zero, r * 0.40, Paint()..color = label);
    canvas.drawRect(
        Rect.fromCenter(center: Offset(0, -r * 0.2), width: r * 0.36, height: r * 0.07),
        Paint()..color = ground);
    canvas.restore();
    canvas.drawCircle(c, 1.6, Paint()..color = ground);

    // The arm, pivoted off the record's top right. At rest it hangs down beside the
    // record, clear of it; down, the needle is on the outer grooves at the record's
    // right-hand side — where it is on a real deck seen from above. The two angles are
    // worked out from that: a needle 0.72 of the way out, an arm 1.09 radii long.
    final pivot = Offset(size.width - 6, 5);
    const rest = math.pi * 0.528, down = math.pi * 0.774;
    final angle = rest + (down - rest) * Curves.easeOutBack.transform(arm.clamp(0.0, 1.0));
    final tip = pivot + Offset(math.cos(angle), math.sin(angle)) * (r * 1.09);
    final line = Paint()
      ..color = metal
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(pivot, tip, line);
    canvas.drawCircle(pivot, 3.2, Paint()..color = metal);
    // The headshell, in line with the arm it is on the end of.
    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    canvas.rotate(angle - math.pi / 2);
    canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: 5, height: 8), Paint()..color = label);
    canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: 5, height: 8),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = metal);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SmallDeck old) =>
      old.turn != turn ||
      old.arm != arm ||
      old.label != label ||
      old.metal != metal ||
      old.ground != ground;
}
