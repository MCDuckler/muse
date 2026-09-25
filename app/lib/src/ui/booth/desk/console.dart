// The booth on a desk is a piece of hardware, not a page: dark, lit where something
// is on, each deck in its own colour. These are its parts.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../state/booth/booth.dart' show Transition;
import '../../feel.dart';
import '../../mag.dart';
import '../../metal_button.dart';

/// The console's colours. The room is dark whatever edition the app is in — a booth
/// is a place with the lights down — and each deck has a colour of its own, taken
/// from the magazine: the masthead red for A, the highlighter yellow for B. The
/// edition's accent is kept for the loud things: the mix, and the booth mixing.
class Console {
  const Console._();

  static const ground = Color(0xFF0B0B0D);
  static const panel = Color(0xFF131316);
  static const raised = Color(0xFF1D1D21);
  static const line = Color(0x1FFFFFFF);
  static const ink = Color(0xFFEDE9E1);
  static const quiet = Color(0xFF8E8A82);
  static const faint = Color(0xFF55524C);

  static const a = Color(0xFFFF4A3D);
  static const b = Color(0xFFFFE14D);

  static Color deck(String name) => name == 'A' ? a : b;

  /// Small capitals for the few words a control needs.
  static TextStyle label(double size, {Color color = quiet}) => Mag.flag(size, color: color);
}

/// A panel of the console: a slightly raised plate with a hairline edge.
class Plate extends StatelessWidget {
  const Plate({super.key, required this.child, this.padding = const EdgeInsets.all(12), this.edge});
  final Widget child;
  final EdgeInsets padding;

  /// A coloured edge, for the deck that is the master.
  final Color? edge;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Console.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: edge ?? Console.line, width: edge == null ? 1 : 1.5),
        ),
        child: child,
      );
}

/// A pad: pressed, it does its one thing; lit, it says that thing is on.
class Pad extends StatefulWidget {
  const Pad({
    super.key,
    this.label,
    this.icon,
    required this.onTap,
    this.onLongPress,
    this.lit = false,
    this.colour = Console.ink,
    this.tooltip,
    this.height = 34,
    this.width,
    this.dim = false,
    this.progress,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool lit;
  final Color colour;
  final String? tooltip;
  final double height;
  final double? width;

  /// Set but not active: a cue that is stored, drawn in the colour but not lit.
  final bool dim;

  /// Something this pad is waiting on, and how far through it is, 0 to 1: drawn as a
  /// thin bar along the pad's foot. Zero is an empty bar — waiting its turn.
  final double? progress;

  @override
  State<Pad> createState() => _PadState();
}

class _PadState extends State<Pad> {
  bool _down = false;
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    final c = widget.colour;
    final fill = widget.lit
        ? c.withValues(alpha: _down ? 0.7 : 0.9)
        : _down
            ? Console.raised.withValues(alpha: 0.6)
            : _over && on
                ? const Color(0xFF26262B)
                : Console.raised;
    final fg = widget.lit
        ? Console.ground
        : !on
            ? Console.faint
            : widget.dim
                ? c
                : Console.ink;
    Widget face = AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      height: widget.height,
      width: widget.width,
      alignment: Alignment.center,
      // A narrow pad (a bar count) keeps its word: less air either side of it.
      padding: EdgeInsets.symmetric(horizontal: widget.width != null && widget.width! < 40 ? 4 : 8),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: widget.lit
                ? c
                : widget.dim
                    ? c.withValues(alpha: 0.6)
                    : Console.line),
        boxShadow: widget.lit
            ? [BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 12, spreadRadius: -2)]
            : null,
      ),
      child: widget.icon != null && widget.label == null
          ? Icon(widget.icon, size: widget.height * 0.5, color: fg)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: widget.height * 0.42, color: fg),
                  const SizedBox(width: 5),
                ],
                if (widget.label != null)
                  Flexible(
                    child: Text(widget.label!,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: Console.label(math.max(8.0, widget.height * 0.3), color: fg)),
                  ),
              ],
            ),
    );
    final progress = widget.progress;
    if (progress != null) {
      face = Stack(
        children: [
          face,
          Positioned(
            left: 5,
            right: 5,
            bottom: 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(1),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: progress.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 400),
                builder: (context, v, _) => LinearProgressIndicator(
                  value: v,
                  minHeight: 2,
                  color: c,
                  backgroundColor: Console.line,
                ),
              ),
            ),
          ),
        ],
      );
    }
    face = MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: on ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: on ? (_) => setState(() => _down = false) : null,
        onTap: on
            ? () {
                feel(Feel.pick);
                widget.onTap!();
              }
            : null,
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onLongPress,
        child: face,
      ),
    );
    return widget.tooltip == null
        ? face
        : Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 500), child: face);
  }
}

/// A round button — play, the one thing on a deck that is round on every deck: the
/// same steel-and-light button as the player's, in the deck's colour, its ring lit
/// while the deck plays.
class RoundButton extends StatefulWidget {
  const RoundButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 54,
    this.colour = Console.ink,
    this.lit = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final Color colour;
  final bool lit;
  final String? tooltip;

  @override
  State<RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<RoundButton> with SingleTickerProviderStateMixin {
  late final AnimationController _lit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 420),
    value: widget.lit ? 1 : 0,
  );
  bool _down = false;

  @override
  void didUpdateWidget(RoundButton old) {
    super.didUpdateWidget(old);
    if (old.lit != widget.lit) widget.lit ? _lit.forward() : _lit.reverse();
  }

  @override
  void dispose() {
    _lit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    // The bloom wants room outside the button's own circle: drawn a little larger
    // than the size it takes in the row, and left to spill.
    final whole = widget.size * 1.3;
    final button = MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: on ? (_) => setState(() => _down = true) : null,
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: on
            ? () {
                feel(Feel.commit);
                widget.onTap!();
              }
            : null,
        child: SizedBox.square(
          dimension: widget.size,
          child: OverflowBox(
            maxWidth: whole,
            maxHeight: whole,
            child: AnimatedScale(
              scale: _down ? 0.96 : 1,
              duration: const Duration(milliseconds: 90),
              child: CustomPaint(
                size: Size.square(whole),
                painter: MetalFace(
                  colour: on ? widget.colour : Console.faint,
                  pressed: _down,
                  dark: true,
                  lit: _lit,
                ),
                child: Center(
                  child: MetalIcon(
                    child: Icon(widget.icon, size: whole * 0.34, color: on ? Colors.white : Console.quiet),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return widget.tooltip == null
        ? button
        : Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 500), child: button);
  }
}

/// A rotary knob. [value] runs from [min] to [max]; drag up or down to turn it,
/// double-click to put it back to [rest]. [killAt] is a floor that reads as a kill.
class Knob extends StatefulWidget {
  const Knob({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = -1,
    this.max = 1,
    this.rest = 0,
    this.label,
    this.colour = Console.ink,
    this.size = 38,
    this.bipolar = true,
    this.tooltip,
  });

  final double value, min, max, rest;
  final ValueChanged<double>? onChanged;
  final String? label;
  final Color colour;
  final double size;

  /// Lit from the middle out (an EQ, a filter) rather than from the bottom.
  final bool bipolar;
  final String? tooltip;

  @override
  State<Knob> createState() => _KnobState();
}

class _KnobState extends State<Knob> {
  double? _start;
  double _from = 0;

  double get _t => ((widget.value - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final on = widget.onChanged != null;
    final knob = MouseRegion(
      cursor: on ? SystemMouseCursors.resizeUpDown : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: on ? () => widget.onChanged!(widget.rest) : null,
        onVerticalDragStart: on
            ? (d) {
                _start = d.globalPosition.dy;
                _from = _t;
              }
            : null,
        onVerticalDragUpdate: on
            ? (d) {
                final t = (_from + (_start! - d.globalPosition.dy) / 160).clamp(0.0, 1.0);
                var v = widget.min + t * (widget.max - widget.min);
                // A detent at rest, felt as it is crossed.
                final near = (widget.max - widget.min) * 0.03;
                if ((v - widget.rest).abs() < near) {
                  if ((widget.value - widget.rest).abs() >= near) feel(Feel.edge);
                  v = widget.rest;
                }
                widget.onChanged!(v);
              }
            : null,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: CustomPaint(
            painter: _KnobPainter(
              t: _t,
              restT: ((widget.rest - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0),
              colour: on ? widget.colour : Console.faint,
              bipolar: widget.bipolar,
            ),
          ),
        ),
      ),
    );
    final withLabel = widget.label == null
        ? knob
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              knob,
              const SizedBox(height: 3),
              Text(widget.label!, style: Console.label(8)),
            ],
          );
    return widget.tooltip == null
        ? withLabel
        : Tooltip(message: widget.tooltip!, waitDuration: const Duration(milliseconds: 600), child: withLabel);
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter({required this.t, required this.restT, required this.colour, required this.bipolar});
  final double t, restT;
  final Color colour;
  final bool bipolar;

  static const _sweep = math.pi * 1.5;
  static const _start = math.pi * 0.75;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = Console.line;
    final arc = Rect.fromCircle(center: c, radius: r - 2);
    canvas.drawArc(arc, _start, _sweep, false, track);
    final from = bipolar ? restT : 0.0;
    final lo = math.min(from, t), hi = math.max(from, t);
    if (hi - lo > 0.001) {
      canvas.drawArc(
          arc,
          _start + _sweep * lo,
          _sweep * (hi - lo),
          false,
          track
            ..color = colour
            ..strokeWidth = 3);
    }
    canvas.drawCircle(c, r - 7, Paint()..color = Console.raised);
    canvas.drawCircle(
        c,
        r - 7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Console.line);
    final a = _start + _sweep * t;
    canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * (r * 0.18),
        c + Offset(math.cos(a), math.sin(a)) * (r - 9),
        Paint()
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..color = Console.ink);
  }

  @override
  bool shouldRepaint(_KnobPainter old) =>
      old.t != t || old.colour != colour || old.restT != restT || old.bipolar != bipolar;
}

/// A vertical fader: a channel's gain, a deck's pitch.
class VFader extends StatelessWidget {
  const VFader({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.centre,
    this.colour = Console.ink,
    this.width = 30,
    this.inverted = false,
    this.onDoubleTap,
  });

  final double value, min, max;

  /// A detent in the middle (a pitch fader's zero). Null for none.
  final double? centre;
  final ValueChanged<double>? onChanged;
  final Color colour;
  final double width;

  /// Up is less: how a pitch fader reads (plus at the bottom, as on the hardware).
  final bool inverted;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: LayoutBuilder(builder: (context, c) {
        final h = c.maxHeight;
        double tOf(double dy) {
          final t = (1 - (dy - 10) / (h - 20)).clamp(0.0, 1.0);
          return inverted ? 1 - t : t;
        }

        void at(double dy) {
          if (onChanged == null) return;
          var v = min + tOf(dy) * (max - min);
          final mid = centre;
          if (mid != null && (v - mid).abs() < (max - min) * 0.02) {
            if ((value - mid).abs() >= (max - min) * 0.02) feel(Feel.edge);
            v = mid;
          }
          onChanged!(v);
        }

        return MouseRegion(
          cursor: onChanged == null ? SystemMouseCursors.basic : SystemMouseCursors.resizeUpDown,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (d) => at(d.localPosition.dy),
            onVerticalDragUpdate: (d) => at(d.localPosition.dy),
            onDoubleTap: onDoubleTap,
            child: CustomPaint(
              size: Size(width, h),
              painter: _VFaderPainter(
                t: ((value - min) / (max - min)).clamp(0.0, 1.0),
                centreT: centre == null ? null : ((centre! - min) / (max - min)),
                colour: onChanged == null ? Console.faint : colour,
                inverted: inverted,
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _VFaderPainter extends CustomPainter {
  _VFaderPainter({required this.t, required this.centreT, required this.colour, required this.inverted});
  final double t;
  final double? centreT;
  final Color colour;
  final bool inverted;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    double yOf(double t) {
      final u = inverted ? 1 - t : t;
      return 10 + (1 - u) * (size.height - 20);
    }

    final slot = Paint()
      ..color = Console.ground
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x, 10), Offset(x, size.height - 10), slot);
    final ticks = Paint()
      ..color = Console.line
      ..strokeWidth = 1;
    for (var i = 0; i <= 10; i++) {
      final y = 10 + i / 10 * (size.height - 20);
      final w = i % 5 == 0 ? 9.0 : 5.0;
      canvas.drawLine(Offset(x + 6, y), Offset(x + 6 + w, y), ticks);
    }
    if (centreT != null) {
      final y = yOf(centreT!);
      canvas.drawLine(Offset(x - 12, y), Offset(x + 15, y), Paint()..color = Console.quiet..strokeWidth = 1);
      // Lit from the centre to the cap: how far from zero it is.
      canvas.drawLine(Offset(x, y), Offset(x, yOf(t)), Paint()..color = colour..strokeWidth = 4..strokeCap = StrokeCap.round);
    } else {
      canvas.drawLine(Offset(x, size.height - 10), Offset(x, yOf(t)),
          Paint()..color = colour.withValues(alpha: 0.8)..strokeWidth = 4..strokeCap = StrokeCap.round);
    }
    final y = yOf(t);
    final cap = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y), width: size.width - 4, height: 18),
        const Radius.circular(4));
    canvas.drawRRect(cap, Paint()..color = const Color(0xFF2A2A30));
    canvas.drawRRect(cap, Paint()..style = PaintingStyle.stroke..color = Console.line);
    canvas.drawLine(Offset(x - size.width / 2 + 5, y), Offset(x + size.width / 2 - 5, y), Paint()..color = Console.ink..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_VFaderPainter old) => old.t != t || old.colour != colour;
}

/// Each transition's icon, wherever one is shown.
IconData transitionIcon(Transition k) => switch (k) {
      Transition.blend => Icons.merge,
      Transition.cut => Icons.content_cut,
      Transition.fade => Icons.gradient,
      Transition.sweep => Icons.filter_list,
      Transition.roll => Icons.loop,
      Transition.brake => Icons.stop_circle_outlined,
      Transition.swap => Icons.swap_horiz,
      Transition.announce => Icons.record_voice_over,
      Transition.acapellaOut => Icons.mic_external_on,
      Transition.stemBlend => Icons.layers,
      Transition.dropSwap => Icons.bolt,
      Transition.echoOut => Icons.graphic_eq,
      Transition.loopBuild => Icons.all_inclusive,
      Transition.breakSwap => Icons.call_split,
      Transition.filterRide => Icons.tune,
    };
