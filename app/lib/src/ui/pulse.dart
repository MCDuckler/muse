import 'package:flutter/material.dart';

/// A slow, quiet blink — something on screen saying it is nearly over.
///
/// Used on the seekbar when the song playing is the last one in the queue. It has to
/// be slow: anything quick reads as an alert, and this is not an alert, it is the
/// difference between music stopping and music having finished.
class Pulse extends StatefulWidget {
  const Pulse({
    super.key,
    required this.on,
    required this.child,
    this.dimTo = 0.38,
    this.period = const Duration(milliseconds: 1900),
  });

  final bool on;
  final Widget child;

  /// How far down it fades at the bottom of the breath.
  final double dimTo;
  final Duration period;

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _breath =
      AnimationController(vsync: this, duration: widget.period);

  @override
  void initState() {
    super.initState();
    if (widget.on) _breath.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(Pulse old) {
    super.didUpdateWidget(old);
    if (widget.on && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!widget.on && _breath.isAnimating) {
      // Back to full and stop there, rather than freezing halfway into a breath.
      _breath.stop();
      _breath.animateTo(0, duration: const Duration(milliseconds: 300));
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.on && !_breath.isAnimating && _breath.value == 0) return widget.child;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _breath,
        // Built once: the breath is an opacity, and the thing breathing does not
        // change while it does.
        child: widget.child,
        builder: (context, child) => Opacity(
          opacity: 1 - (1 - widget.dimTo) * Curves.easeInOut.transform(_breath.value),
          child: child,
        ),
      ),
    );
  }
}
