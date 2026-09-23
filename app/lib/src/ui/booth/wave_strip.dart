import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../mag.dart';

/// A song's shape printed as a strip, with the grid on it.
///
/// Three inks: the bass as the heavy one, the middle over it, the top as the finest —
/// so "the bass drops out here" is visible from across the room, which is the one
/// thing a DJ reads off a waveform. Beat ticks along the foot, downbeats taller, the
/// phrases bracketed along the head, the mix-in and mix-out cues flagged, the loop
/// shaded. The playhead stands a third of the way in and the song runs under it.
///
/// Dragging scrubs: the song moves under the finger, and where it stops is where it
/// plays from. Drawn from a position notifier so the strip repaints on its own
/// clock and nothing else does.
class WaveStrip extends StatelessWidget {
  const WaveStrip({
    super.key,
    required this.position,
    required this.timing,
    required this.bands,
    required this.duration,
    required this.playing,
    this.loop,
    this.hotCues = const {},
    this.window = const Duration(seconds: 20),
    this.height = 72,
    this.onScrub,
    this.accent,
    this.markAt,
    this.mirrored = false,
  });

  /// A moment worth flagging that is not the song's own — where the booth means to
  /// mix out of it.
  final Duration? markAt;

  /// Hanging from the top rather than standing on the foot, so two of these can face
  /// each other and their beats line up to the eye.
  final bool mirrored;

  final ValueListenable<Duration> position;
  final TrackTiming? timing;
  final ({List<int> low, List<int> mid, List<int> high})? bands;
  final Duration duration;
  final bool playing;
  final (Duration, Duration)? loop;
  final Map<int, Duration> hotCues;

  /// How much of the song the strip shows at once.
  final Duration window;
  final double height;
  final void Function(Duration to)? onScrub;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: onScrub == null
            ? null
            : (d) {
                final perPixel = window.inMicroseconds / width;
                final at = position.value -
                    Duration(microseconds: (d.delta.dx * perPixel).round());
                onScrub!(Duration(
                    microseconds: at.inMicroseconds.clamp(0, duration.inMicroseconds)));
              },
        child: SizedBox(
          // As wide as it is given: a painter with no child is as wide as nothing.
          width: width,
          height: height,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _StripPainter(
                position: position,
                timing: timing,
                bands: bands,
                duration: duration,
                window: window,
                loop: loop,
                hotCues: hotCues,
                markAt: markAt,
                mirrored: mirrored,
                ink: scheme.onSurface,
                accent: accent ?? scheme.primary,
                paper: scheme.surface,
                quiet: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.position,
    required this.timing,
    required this.bands,
    required this.duration,
    required this.window,
    required this.loop,
    required this.hotCues,
    required this.markAt,
    required this.mirrored,
    required this.ink,
    required this.accent,
    required this.paper,
    required this.quiet,
  }) : super(repaint: position);

  final ValueListenable<Duration> position;
  final TrackTiming? timing;
  final ({List<int> low, List<int> mid, List<int> high})? bands;
  final Duration duration;
  final Duration window;
  final (Duration, Duration)? loop;
  final Map<int, Duration> hotCues;
  final Duration? markAt;
  final bool mirrored;
  final Color ink, accent, paper, quiet;

  /// Where the playhead stands: a third in, so most of the strip is what is coming.
  static const _head = 0.34;

  @override
  void paint(Canvas canvas, Size size) {
    final total = duration.inMicroseconds.toDouble();
    if (total <= 0) {
      _empty(canvas, size);
      return;
    }
    final w = size.width, h = size.height;
    // Nothing past the strip's edges: a flag near the end was printed on the panel.
    canvas.clipRect(Offset.zero & size);
    if (mirrored) {
      // Turned over about its middle: the shape hangs from the top, the grid runs
      // along the head. Everything below is drawn once, the right way up.
      canvas.translate(0, h);
      canvas.scale(1, -1);
    }
    final perPixel = window.inMicroseconds / w;
    final at = position.value.inMicroseconds.toDouble();
    final left = at - _head * w * perPixel;
    double xOf(double us) => (us - left) / perPixel;

    // The song's ground: a hairline along the middle where the shape stands.
    final base = h * 0.78;
    canvas.drawLine(Offset(0, base), Offset(w, base), Paint()..color = ink.withValues(alpha: 0.12)..strokeWidth = 1);

    // The loop, shaded, first: everything else is printed over it.
    final lp = loop;
    if (lp != null) {
      final x0 = xOf(lp.$1.inMicroseconds.toDouble()), x1 = xOf(lp.$2.inMicroseconds.toDouble());
      canvas.drawRect(Rect.fromLTRB(x0.clamp(0, w), 0, x1.clamp(0, w), h),
          Paint()..color = accent.withValues(alpha: 0.10));
    }

    // The shape, three inks, each band from the foot up.
    final b = bands;
    if (b != null && b.low.isNotEmpty) {
      final n = b.low.length;
      final usPerSlice = total / n;
      final first = math.max(0, (left / usPerSlice).floor());
      final last = math.min(n - 1, ((left + w * perPixel) / usPerSlice).ceil());
      void band(List<int> v, Color c, double scale) {
        final path = Path()..moveTo(xOf(first * usPerSlice), base);
        for (var i = first; i <= last; i++) {
          final x = xOf(i * usPerSlice);
          path.lineTo(x, base - (v[i] / 255) * (h * 0.62) * scale);
        }
        path.lineTo(xOf((last + 1) * usPerSlice), base);
        path.close();
        canvas.drawPath(path, Paint()..color = c);
      }
      band(b.low, accent.withValues(alpha: 0.85), 1.0);
      band(b.mid, ink.withValues(alpha: 0.45), 0.8);
      band(b.high, ink.withValues(alpha: 0.28), 0.55);
    } else {
      // No shape yet: a quiet line, so the grid still has something to stand on.
      canvas.drawRect(Rect.fromLTWH(0, base - 3, w, 3), Paint()..color = ink.withValues(alpha: 0.10));
    }

    // The grid: ticks along the foot, downbeats taller and darker.
    final t = timing;
    if (t != null && t.hasBeats) {
      final tick = Paint()..color = ink.withValues(alpha: 0.35)..strokeWidth = 1;
      final down = Paint()..color = ink.withValues(alpha: 0.7)..strokeWidth = 1.2;
      final beats = t.beats;
      for (var i = 0; i < beats.length; i++) {
        final x = xOf(beats[i] * 1000.0);
        if (x < -2) continue;
        if (x > w + 2) break;
        final isDown = (i - t.barStartsOn) % 4 == 0;
        canvas.drawLine(Offset(x, h), Offset(x, h - (isDown ? 10 : 5)), isDown ? down : tick);
      }
      // Phrases: a bracket along the head, with the bar count typed at its start.
      final phrases = t.phrases;
      for (var i = 0; i < phrases.length; i++) {
        final x = xOf(phrases[i] * 1000.0);
        final end = i + 1 < phrases.length ? xOf(phrases[i + 1] * 1000.0) : w + 20;
        if (end < 0 || x > w) continue;
        final bracket = Paint()..color = ink.withValues(alpha: 0.55)..strokeWidth = 1;
        canvas.drawLine(Offset(math.max(0, x), 4), Offset(math.min(w, end - 3), 4), bracket);
        canvas.drawLine(Offset(x, 4), Offset(x, 10), bracket);
        _type(canvas, '${i + 1}', Offset(x + 3, 5), quiet, 8);
      }
      // Where the song opens up, drawn the full height of the lane: the thing a mix
      // is landed on, so it has to be visible from further away than a flag.
      for (final d in t.drops) {
        final x = xOf(d * 1000.0);
        if (x < -2 || x > w + 2) continue;
        canvas.drawRect(Rect.fromLTWH(x - 1.5, 0, 3, h),
            Paint()..color = accent.withValues(alpha: 0.35));
        _type(canvas, 'DROP', Offset(x + 5, h * 0.36), accent, 8);
      }
      // The cues: IN and OUT flags in the accent, the way a mark is put on a record.
      final cues = t.cues;
      if (cues != null) {
        _flag(canvas, xOf(cues.mixInMs * 1000.0), 'IN', h, w);
        _flag(canvas, xOf(cues.mixOutMs * 1000.0), 'OUT', h, w);
      }
    }
    for (final e in hotCues.entries) {
      _flag(canvas, xOf(e.value.inMicroseconds.toDouble()), '${e.key}', h, w, hot: true);
    }
    // Where the booth means to mix out of this record: a rule with a hatched run up
    // to it, so how long there is left to it is read off the strip rather than the
    // countdown alone.
    final mark = markAt;
    if (mark != null) {
      final x = xOf(mark.inMicroseconds.toDouble());
      if (x > -40 && x < w + 40) {
        final from = math.max(0.0, xOf(at));
        if (x > from) {
          canvas.drawRect(Rect.fromLTRB(from, 0, math.min(w, x), h),
              Paint()..color = accent.withValues(alpha: 0.07));
        }
        canvas.drawLine(Offset(x, 0), Offset(x, h),
            Paint()..color = accent..strokeWidth = 1.4
              ..strokeCap = StrokeCap.round);
        _flag(canvas, x, 'MIX', h, w);
      }
    }

    // The playhead: a rule in the accent, a notch at its head.
    final x = _head * w;
    canvas.drawLine(Offset(x, 0), Offset(x, h), Paint()..color = accent..strokeWidth = 1.6);
    canvas.drawPath(
        Path()..moveTo(x - 5, 0)..lineTo(x + 5, 0)..lineTo(x, 6)..close(), Paint()..color = accent);

    // The edges fade, so the strip reads as a window onto the song, not the song.
    for (final (x0, x1) in [(0.0, 18.0), (w - 18, w)]) {
      canvas.drawRect(
          Rect.fromLTRB(x0, 0, x1, h),
          Paint()
            ..shader = LinearGradient(
              colors: x0 == 0 ? [paper, paper.withValues(alpha: 0)] : [paper.withValues(alpha: 0), paper],
            ).createShader(Rect.fromLTRB(x0, 0, x1, h)));
    }
  }

  void _flag(Canvas canvas, double x, String text, double h, double w, {bool hot = false}) {
    if (x < -30 || x > w + 30) return;
    final c = hot ? ink : accent;
    canvas.drawLine(Offset(x, 12), Offset(x, h - 12),
        Paint()..color = c.withValues(alpha: 0.7)..strokeWidth = 1);
    final tp = TextPainter(
      text: TextSpan(text: text, style: Mag.flag(7.5, color: paper)),
      textDirection: TextDirection.ltr,
    )..layout();
    final box = Rect.fromLTWH(x, 12, tp.width + 6, tp.height + 3);
    canvas.drawRect(box, Paint()..color = c);
    _write(canvas, tp, Offset(x + 3, 13.5));
  }

  void _type(Canvas canvas, String text, Offset at, Color c, double size) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: Mag.typewriter(size, color: c)),
      textDirection: TextDirection.ltr,
    )..layout();
    _write(canvas, tp, at);
  }

  /// Words the right way up, whichever way the strip is drawn: the shape and the
  /// grid turn over with the lane, the reading matter does not.
  void _write(Canvas canvas, TextPainter tp, Offset at) {
    if (!mirrored) {
      tp.paint(canvas, at);
      return;
    }
    canvas.save();
    canvas.translate(at.dx, at.dy + tp.height);
    canvas.scale(1, -1);
    tp.paint(canvas, Offset.zero);
    canvas.restore();
  }

  void _empty(Canvas canvas, Size size) {
    canvas.drawLine(Offset(0, size.height * 0.78), Offset(size.width, size.height * 0.78),
        Paint()..color = ink.withValues(alpha: 0.12)..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.markAt != markAt ||
      old.mirrored != mirrored ||
      old.timing != timing ||
      old.bands != bands ||
      old.duration != duration ||
      old.loop != loop ||
      old.hotCues != hotCues ||
      old.accent != accent;
}
