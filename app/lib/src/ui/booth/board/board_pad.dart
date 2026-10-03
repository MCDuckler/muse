// One pad of the board: pressed, it makes its sound; lit while it does, with the
// sound's shape across it and the sweep of it passing.
//
// Not a Pad: a pad of the board is pressed and let go (a hold plays while it is held),
// several at once under several fingers, so it listens to pointers rather than to
// taps. Its face is drawn in one painter — fill, edge, the sound's silhouette, the
// sweep, a countdown along its foot while it waits for the beat — and its words sit
// over that.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../state/booth/board/pad_spec.dart';
import '../../../state/booth/board/soundboard.dart' show PadState;
import '../../feel.dart';
import '../../mag.dart';
import '../desk/console.dart';

/// A pad colour, as the look makes it: the decks' own two, the edition's accent,
/// and five that read on the dark panel and on paper alike.
Color padColourOf(PadColour c, BuildContext context) => switch (c) {
      PadColour.a => Console.a,
      PadColour.b => Console.b,
      PadColour.accent => Theme.of(context).colorScheme.primary,
      PadColour.teal => Console.light ? const Color(0xFF0E8F82) : const Color(0xFF2BD1BE),
      PadColour.violet => Console.light ? const Color(0xFF6A4BE0) : const Color(0xFF9B82FF),
      PadColour.orange => Console.light ? const Color(0xFFD9641A) : const Color(0xFFFF9A4D),
      PadColour.white => Console.ink,
      PadColour.grey => Console.quiet,
    };

IconData padModeIcon(PadMode m) => switch (m) {
      PadMode.oneShot => Icons.play_arrow,
      PadMode.hold => Icons.touch_app_outlined,
      PadMode.toggle => Icons.swap_horiz,
      PadMode.loop => Icons.all_inclusive,
    };

class BoardPad extends StatefulWidget {
  const BoardPad({
    super.key,
    required this.spec,
    required this.state,
    required this.now,
    this.peaks,
    this.onDown,
    this.onUp,
    this.onEdit,
    this.keyCap,
    this.compact = false,
    this.selected = false,
    this.editing = false,
    this.dropping = false,
  });

  /// Null for an empty pad.
  final PadSpec? spec;
  final PadState state;

  /// The room's clock, for the sweep: read only while the pad sounds.
  final ValueListenable<DateTime> now;
  final Float32List? peaks;
  final VoidCallback? onDown;
  final VoidCallback? onUp;

  /// Right-click, long-press, or the pencil: the pad's settings.
  final VoidCallback? onEdit;
  final String? keyCap;

  /// A strip's pad: name and sweep, nothing else.
  final bool compact;
  final bool selected;

  /// The board is in edit: a press selects rather than plays.
  final bool editing;

  /// Something is being dragged over it.
  final bool dropping;

  @override
  State<BoardPad> createState() => _BoardPadState();
}

class _BoardPadState extends State<BoardPad> {
  bool _down = false;
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final empty = spec == null;
    final c = empty ? Console.faint : padColourOf(spec.colour, context);
    final s = widget.state;
    final lit = s.sounding;
    final fg = lit ? Console.ground : Console.ink;
    final cap = widget.keyCap;

    Widget face = ValueListenableBuilder<DateTime>(
      valueListenable: widget.now,
      builder: (context, now, child) => CustomPaint(
        painter: _PadFacePainter(
          colour: c,
          lit: lit,
          down: _down,
          over: _over && !empty,
          empty: empty,
          selected: widget.selected,
          dropping: widget.dropping,
          peaks: widget.compact ? null : widget.peaks,
          progress: s.progressAt(now),
          countdown: s.waitingUntil == null
              ? null
              : (s.waitingUntil!.difference(now).inMicroseconds / 1.6e6).clamp(0.0, 1.0),
          held: s.held,
        ),
        child: child,
      ),
      child: empty
          ? Center(child: Icon(Icons.add, size: widget.compact ? 14 : 22, color: Console.faint))
          : Padding(
              padding: EdgeInsets.all(widget.compact ? 5 : 8),
              child: Stack(
                children: [
                  if (!widget.compact) ...[
                    // Top left: the choke group, and the pencil while hovered.
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (spec.choke > 0)
                          Container(
                            width: 14,
                            height: 14,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: lit ? Console.ground : c, width: 1),
                            ),
                            child: Text('${spec.choke}', style: Console.label(7, color: lit ? Console.ground : c)),
                          ),
                        if (_over && widget.onEdit != null && !lit) ...[
                          if (spec.choke > 0) const SizedBox(width: 5),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onEdit,
                            child: Tooltip(
                              message: 'Settings',
                              child: Icon(Icons.edit_outlined, size: 13, color: Console.quiet),
                            ),
                          ),
                        ],
                      ]),
                    ),
                    // Top right: the key — or, with no keys (a phone), how it plays.
                    if (cap == null)
                      Positioned(right: 0, top: 0, child: _modeMarks(spec, lit))
                    else
                      Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(4, 1, 4, 1),
                          decoration: BoxDecoration(
                            color: lit ? Console.ground.withValues(alpha: 0.25) : Console.ground,
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: lit ? Console.ground.withValues(alpha: 0.3) : Console.line),
                          ),
                          child: Text(cap, style: Mag.typewriter(9, color: lit ? Console.ground : Console.quiet, bold: true)),
                        ),
                      ),
                    // Bottom right: how it plays, beside the name.
                    if (cap != null) Positioned(right: 0, bottom: 1, child: _modeMarks(spec, lit)),
                  ],
                  // The name, along the foot: two lines on a narrow pad, in a size
                  // the pad's width allows.
                  Positioned(
                    left: 0,
                    right: widget.compact || cap == null ? 0 : 30,
                    bottom: widget.compact ? null : 0,
                    top: widget.compact ? 0 : null,
                    child: LayoutBuilder(
                      builder: (context, c) => Text(
                        spec.name,
                        maxLines: widget.compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: Console.label(
                            widget.compact ? 8 : (c.maxWidth / 9).clamp(7.5, 10).toDouble(),
                            color: fg),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );

    face = MouseRegion(
      cursor: empty && widget.onEdit == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (e.buttons == 2) return; // the secondary button is the menu's, below
          if (empty || widget.editing) {
            widget.onEdit?.call();
            return;
          }
          setState(() => _down = true);
          feel(Feel.commit);
          widget.onDown?.call();
        },
        onPointerUp: (_) {
          if (!_down) return;
          setState(() => _down = false);
          widget.onUp?.call();
        },
        onPointerCancel: (_) {
          if (!_down) return;
          setState(() => _down = false);
          widget.onUp?.call();
        },
        child: GestureDetector(
          onLongPress: widget.onEdit,
          onSecondaryTap: widget.onEdit,
          child: AnimatedScale(
            scale: _down ? 0.97 : 1,
            duration: const Duration(milliseconds: 90),
            child: face,
          ),
        ),
      ),
    );
    if (empty || widget.compact) return face;
    final l = spec.trimOut ?? const Duration(seconds: 0);
    final length = l > Duration.zero ? '${(l - spec.trimIn).inMilliseconds / 1000} s · ' : '';
    return Tooltip(
      message: '${spec.name} · $length${spec.mode.label}'
          '${cap == null ? '' : ' · $cap'}${spec.choke > 0 ? ' · choke ${spec.choke}' : ''}'
          '${spec.quantise == Quantise.off ? '' : ' · on the ${spec.quantise.name}'}',
      waitDuration: const Duration(milliseconds: 700),
      child: face,
    );
  }
}

Widget _modeMarks(PadSpec spec, bool lit) => Row(mainAxisSize: MainAxisSize.min, children: [
      if (spec.quantise != Quantise.off) ...[
        Icon(Icons.timer_outlined, size: 11, color: lit ? Console.ground : Console.quiet),
        const SizedBox(width: 3),
      ],
      Icon(padModeIcon(spec.mode), size: 12, color: lit ? Console.ground : Console.quiet),
    ]);

class _PadFacePainter extends CustomPainter {
  _PadFacePainter({
    required this.colour,
    required this.lit,
    required this.down,
    required this.over,
    required this.empty,
    required this.selected,
    required this.dropping,
    required this.peaks,
    required this.progress,
    required this.countdown,
    required this.held,
  });

  final Color colour;
  final bool lit, down, over, empty, selected, dropping, held;
  final Float32List? peaks;
  final double? progress;
  final double? countdown;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    final fill = lit
        ? colour.withValues(alpha: down ? 0.75 : 0.92)
        : down
            ? Console.raised.withValues(alpha: 0.6)
            : over
                ? Console.hover
                : Console.raised;
    if (lit) {
      canvas.drawRRect(
          r.inflate(2),
          Paint()
            ..color = colour.withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    }
    canvas.drawRRect(r, Paint()..color = fill);

    // The sound's shape, faint, across the middle; the sweep fills it as the sound
    // passes.
    final p = peaks;
    if (p != null && p.isNotEmpty) {
      final mid = size.height * 0.56;
      final h = size.height * 0.26;
      final w = size.width - 12;
      final path = Path();
      for (var i = 0; i < p.length; i++) {
        final x = 6 + w * i / (p.length - 1);
        path.moveTo(x, mid - h * p[i]);
        path.lineTo(x, mid + h * p[i]);
      }
      final ink = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, w / p.length * 0.7)
        ..color = (lit ? Console.ground : colour).withValues(alpha: lit ? 0.35 : 0.22);
      canvas.drawPath(path, ink);
      final sweep = progress;
      if (sweep != null && lit) {
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(0, 0, 6 + w * sweep, size.height));
        canvas.drawPath(path, ink..color = Console.ground.withValues(alpha: 0.9));
        canvas.restore();
      }
    } else if (progress != null && lit) {
      // No shape known: the sweep is a line along the foot.
      canvas.drawRect(Rect.fromLTWH(6, size.height - 5, (size.width - 12) * progress!, 2),
          Paint()..color = Console.ground.withValues(alpha: 0.8));
    }

    // Waiting for the beat: the time left draining along the foot.
    final c = countdown;
    if (c != null) {
      canvas.drawRect(Rect.fromLTWH(6, size.height - 5, size.width - 12, 2), Paint()..color = Console.line);
      canvas.drawRect(Rect.fromLTWH(6, size.height - 5, (size.width - 12) * (1 - c), 2), Paint()..color = colour);
    }

    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected || dropping || c != null ? 1.5 : 1
      ..color = dropping
          ? Console.ink
          : lit
              ? colour
              : selected || c != null
                  ? colour
                  : empty
                      ? Console.line
                      : colour.withValues(alpha: 0.45);
    if (empty && !dropping) {
      // Dashed: nothing here yet.
      final path = Path()..addRRect(r.deflate(0.5));
      for (final m in path.computeMetrics()) {
        var d = 0.0;
        while (d < m.length) {
          canvas.drawPath(m.extractPath(d, d + 5), edge);
          d += 9;
        }
      }
    } else {
      canvas.drawRRect(r.deflate(0.5), edge);
    }
  }

  @override
  bool shouldRepaint(_PadFacePainter o) =>
      o.colour != colour ||
      o.lit != lit ||
      o.down != down ||
      o.over != over ||
      o.empty != empty ||
      o.selected != selected ||
      o.dropping != dropping ||
      o.peaks != peaks ||
      o.progress != progress ||
      o.countdown != countdown ||
      o.held != held;
}
