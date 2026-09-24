import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';

import '../../state/booth/booth.dart';
import '../../state/booth/deck.dart';
import '../../state/booth/mixer.dart';
import '../feel.dart';
import 'booth_clock.dart';
import '../mag.dart';

/// How far apart the two records' beats are, and which way.
///
/// The one thing a DJ is listening for while beatmatching, drawn: a needle that sits
/// in the middle when the beats land together and swings to whichever side is ahead.
/// It is not a guess — both decks know where their beats are and where they have got
/// to, so this is the difference between two clocks.
///
/// Nothing at all when either record has no grid: a needle that moves for a song with
/// no pulse is a needle keeping time with nothing.
class PhaseMeter extends StatelessWidget {
  const PhaseMeter({super.key, required this.booth, this.height = 26});

  /// The room's, or — given none — whichever one is above this in the tree.
  final Booth? booth;
  final double height;

  /// How far the deck being watched is ahead of the master, as a fraction of a beat,
  /// the short way round: -0.5 to 0.5. Null when either has no grid or is parked.
  static double? driftOf(Booth booth) {
    final m = booth.master, o = booth.other(booth.master);
    if (!m.playing || !o.playing) return null;
    final now = DateTime.now();
    final mine = o.beatAt(now), theirs = m.beatAt(now);
    if (mine == null || theirs == null) return null;
    var ahead = mine.phase - theirs.phase;
    if (ahead > 0.5) ahead -= 1;
    if (ahead < -0.5) ahead += 1;
    return ahead;
  }

  @override
  Widget build(BuildContext context) {
    final booth = this.booth ?? context.read<AppState>().booth;
    // The drift changes every frame, so it is drawn from the room's clock rather
    // than from the booth, which only says when something is switched.
    return ListenableBuilder(
      listenable: BoothClock.of(context).positionOf(booth.master),
      builder: (context, _) => _draw(context, booth),
    );
  }

  Widget _draw(BuildContext context, Booth booth) {
    final scheme = Theme.of(context).colorScheme;
    final drift = driftOf(booth);
    final m = booth.master, o = booth.other(m);
    final beat = o.beat;
    final ms = drift == null || beat == null
        ? null
        : (drift * beat.inMilliseconds).round();
    final locked = ms != null && ms.abs() <= 12;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Text('${o.name} against ${m.name}', style: Mag.flag(8, color: scheme.onSurfaceVariant)),
          const SizedBox(width: 10),
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _PhasePainter(
                drift: drift,
                ink: scheme.onSurface,
                accent: scheme.primary,
                good: locked,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 66,
            child: Text(
              ms == null ? '—' : locked ? 'LOCKED' : '${ms > 0 ? '+' : ''}$ms ms',
              textAlign: TextAlign.right,
              style: Mag.typewriter(10.5,
                  color: ms == null
                      ? scheme.onSurfaceVariant
                      : locked
                          ? scheme.primary
                          : scheme.onSurface,
                  bold: locked),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhasePainter extends CustomPainter {
  const _PhasePainter({required this.drift, required this.ink, required this.accent, required this.good});
  final double? drift;
  final Color ink, accent;
  final bool good;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2, w = size.width;
    canvas.drawLine(Offset(0, y), Offset(w, y), Paint()..color = ink.withValues(alpha: 0.25)..strokeWidth = 1);
    // A scale in quarters of a beat, the middle one heavier.
    for (var i = 0; i <= 8; i++) {
      final x = w * i / 8;
      final mid = i == 4;
      canvas.drawLine(Offset(x, y - (mid ? 8 : 4)), Offset(x, y + (mid ? 8 : 4)),
          Paint()..color = ink.withValues(alpha: mid ? 0.8 : 0.25)..strokeWidth = mid ? 1.5 : 1);
    }
    final d = drift;
    if (d == null) return;
    final x = w * (0.5 + d.clamp(-0.5, 0.5));
    final colour = good ? accent : ink;
    // The needle, and the road it has to travel back: the bar from the middle to it
    // says how far out it is at a glance, the needle says exactly where.
    canvas.drawRect(Rect.fromLTRB(math.min(w / 2, x), y - 3, math.max(w / 2, x), y + 3),
        Paint()..color = colour.withValues(alpha: 0.30));
    canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: 3, height: size.height * 0.8),
        Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_PhasePainter old) => old.drift != drift || old.good != good || old.accent != accent;
}

/// How loud a channel is sending, as a column of blocks.
///
/// Read off the song's own shape at the needle — the loudness the analysis measured,
/// at the level this channel is set to — rather than off the speaker, which no
/// platform here will let an app listen to. So it is honest about the music and not
/// about the output stage: a kill does not show on it, the fader does.
class LevelMeter extends StatelessWidget {
  const LevelMeter({
    super.key,
    required this.deck,
    required this.bands,
    required this.level,
    this.width = 10,
    this.height = 120,
  });

  final Deck deck;
  final ({List<int> low, List<int> mid, List<int> high})? bands;
  final double level;
  final double width, height;

  /// The loudness at the needle, 0 to 1, or null with no shape to read.
  static double? loudnessAt(Deck deck, ({List<int> low, List<int> mid, List<int> high})? bands) {
    final b = bands;
    final total = deck.duration;
    if (b == null || b.low.isEmpty || total == null || total <= Duration.zero) return null;
    final at = (deck.position.inMicroseconds / total.inMicroseconds * b.low.length).floor();
    if (at < 0 || at >= b.low.length) return null;
    // The loudest of the three bands at that slice: a bass drop is loud even when the
    // top has gone.
    final peak = math.max(b.low[at], math.max(b.mid[at], b.high[at]));
    return peak / 255;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: height,
      child: ListenableBuilder(
        listenable: BoothClock.of(context).positionOf(deck),
        builder: (context, _) => CustomPaint(
          painter: _LevelPainter(
            value: deck.playing ? (loudnessAt(deck, bands) ?? 0) * level : 0.0,
            ink: scheme.onSurface,
            accent: scheme.primary,
          ),
        ),
      ),
    );
  }
}

class _LevelPainter extends CustomPainter {
  const _LevelPainter({required this.value, required this.ink, required this.accent});
  final double value;
  final Color ink, accent;

  @override
  void paint(Canvas canvas, Size size) {
    const blocks = 14;
    final h = size.height / blocks;
    final lit = (value.clamp(0.0, 1.0) * blocks).round();
    for (var i = 0; i < blocks; i++) {
      final on = blocks - i <= lit;
      // The top three are the loud end: red when they light, ink when they do not.
      final hot = i < 3;
      canvas.drawRect(
        Rect.fromLTWH(0, i * h + 1, size.width, h - 2),
        Paint()
          ..color = on
              ? (hot ? accent : ink.withValues(alpha: 0.9))
              : ink.withValues(alpha: 0.10),
      );
    }
  }

  @override
  bool shouldRepaint(_LevelPainter old) => old.value != value || old.accent != accent;
}

/// One band of a channel's EQ: a knob that turns, and kills when it is pushed.
///
/// Turned by dragging up and down — the way a real one is — from a kill at the bottom
/// through flat at the middle to a little boost at the top. Tapping it kills the band
/// outright and tapping again puts it back flat, because that is the gesture that
/// happens mid-blend and it should not need aim.
class EqKnob extends StatefulWidget {
  const EqKnob({
    super.key,
    required this.label,
    required this.db,
    required this.onChanged,
    this.size = 34,
  });

  final String label;
  final double db;
  final ValueChanged<double> onChanged;
  final double size;

  @override
  State<EqKnob> createState() => _EqKnobState();
}

class _EqKnobState extends State<EqKnob> {
  double? _from;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final killed = widget.db <= EqSet.killed;
    // Where the pointer sits, as on a DJ mixer: straight up flat, the bottom of the
    // travel a kill (EqSet.knobOf).
    final t = EqSet.knobOf(widget.db);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            feel(Feel.pick);
            widget.onChanged(killed ? 0 : EqSet.killed);
          },
          onVerticalDragStart: (_) => _from = EqSet.knobOf(widget.db),
          onVerticalDragUpdate: (d) {
            // The whole travel in about a hundred and twenty pixels of finger, on the
            // knob's own taper; a little either side of straight up is flat.
            var t = ((_from ?? 0.5) - d.delta.dy / 120).clamp(0.0, 1.0);
            _from = t;
            if ((t - 0.5).abs() < 0.025) t = 0.5;
            widget.onChanged(EqSet.dbOf(t));
          },
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: CustomPaint(
              painter: _KnobPainter(
                t: t,
                killed: killed,
                ink: scheme.onSurface,
                accent: scheme.primary,
                paper: scheme.surface,
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(widget.label, style: Mag.flag(7.5, color: killed ? scheme.primary : scheme.onSurfaceVariant)),
      ],
    );
  }
}

class _KnobPainter extends CustomPainter {
  const _KnobPainter({
    required this.t,
    required this.killed,
    required this.ink,
    required this.accent,
    required this.paper,
  });
  final double t;
  final bool killed;
  final Color ink, accent, paper;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 2;
    // A printed dial: a ruled circle, ticks at the ends and the middle, a pointer.
    canvas.drawCircle(c, r, Paint()..color = killed ? accent.withValues(alpha: 0.18) : paper);
    canvas.drawCircle(c, r, Paint()..color = killed ? accent : ink..style = PaintingStyle.stroke..strokeWidth = 1.4);
    // The travel: 270 degrees, from bottom-left round to bottom-right.
    const from = math.pi * 0.75, sweep = math.pi * 1.5;
    for (final at in const [0.0, 0.5, 1.0]) {
      final a = from + sweep * at;
      final p1 = c + Offset(math.cos(a), math.sin(a)) * (r + 1);
      final p2 = c + Offset(math.cos(a), math.sin(a)) * (r + 3.5);
      canvas.drawLine(p1, p2, Paint()..color = ink.withValues(alpha: at == 0.5 ? 0.9 : 0.4)..strokeWidth = 1);
    }
    final a = from + sweep * t;
    canvas.drawLine(c, c + Offset(math.cos(a), math.sin(a)) * (r - 2),
        Paint()..color = killed ? accent : ink..strokeWidth = 2..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_KnobPainter old) => old.t != t || old.killed != killed || old.accent != accent;
}

/// A channel's own fader: how loud this deck is, apart from the crossfader.
class ChannelFader extends StatelessWidget {
  const ChannelFader({super.key, required this.value, required this.onChanged, this.height = 120});

  final double value;
  final ValueChanged<double> onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 26,
      height: height,
      child: LayoutBuilder(builder: (context, c) {
        void at(double dy) => onChanged((1 - dy / c.maxHeight).clamp(0.0, 1.0));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) => at(d.localPosition.dy),
          onVerticalDragUpdate: (d) => at(d.localPosition.dy),
          onTapDown: (d) => at(d.localPosition.dy),
          child: CustomPaint(
            painter: _ChannelPainter(value: value, ink: scheme.onSurface, paper: scheme.surface, accent: scheme.primary),
          ),
        );
      }),
    );
  }
}

class _ChannelPainter extends CustomPainter {
  const _ChannelPainter({required this.value, required this.ink, required this.paper, required this.accent});
  final double value;
  final Color ink, paper, accent;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    canvas.drawLine(Offset(x, 4), Offset(x, size.height - 4), Paint()..color = ink..strokeWidth = 2);
    for (var i = 0; i <= 10; i++) {
      final y = 4 + (size.height - 8) * i / 10;
      canvas.drawLine(Offset(x - 5, y), Offset(x + 5, y),
          Paint()..color = ink.withValues(alpha: i == 0 ? 0.9 : 0.3)..strokeWidth = 1);
    }
    final y = 4 + (size.height - 8) * (1 - value.clamp(0.0, 1.0));
    final knob = Rect.fromCenter(center: Offset(x, y), width: size.width - 2, height: 14);
    canvas.drawRect(knob.shift(const Offset(1.5, 1.5)), Paint()..color = ink);
    canvas.drawRect(knob, Paint()..color = paper);
    canvas.drawRect(knob, Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 1.3);
    canvas.drawLine(Offset(knob.left + 3, y), Offset(knob.right - 3, y), Paint()..color = accent..strokeWidth = 1.8);
  }

  @override
  bool shouldRepaint(_ChannelPainter old) => old.value != value || old.accent != accent;
}


/// A slider whose nought is the middle: the pitch fader, the filter knob.
///
/// Material's own fills from the left, so a control that is *off* at the centre of
/// its travel is drawn half full — which reads as half on. This one fills from the
/// middle out, the way a mixer's centre-detented control is marked.
class CentreSlider extends StatelessWidget {
  const CentreSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = -1,
    this.max = 1,
    this.detent = 0.03,
    this.height = 22,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final double min, max;

  /// How near the middle counts as the middle.
  final double detent;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final centre = (min + max) / 2;
    return LayoutBuilder(builder: (context, c) {
      void at(double dx) {
        if (onChanged == null) return;
        var v = min + (dx / c.maxWidth).clamp(0.0, 1.0) * (max - min);
        if ((v - centre).abs() < detent * (max - min)) {
          if ((value - centre).abs() >= detent * (max - min)) feel(Feel.edge);
          v = centre;
        }
        onChanged!(v);
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) => at(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
        onTapDown: (d) => at(d.localPosition.dx),
        child: SizedBox(
          height: height,
          child: CustomPaint(
            painter: _CentrePainter(
              t: ((value - min) / (max - min)).clamp(0.0, 1.0),
              on: onChanged != null,
              ink: scheme.onSurface,
              accent: scheme.primary,
              paper: scheme.surface,
            ),
          ),
        ),
      );
    });
  }
}

class _CentrePainter extends CustomPainter {
  const _CentrePainter({
    required this.t,
    required this.on,
    required this.ink,
    required this.accent,
    required this.paper,
  });
  final double t;
  final bool on;
  final Color ink, accent, paper;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2, w = size.width, mid = w / 2;
    canvas.drawLine(Offset(0, y), Offset(w, y),
        Paint()..color = ink.withValues(alpha: on ? 0.35 : 0.15)..strokeWidth = 2);
    canvas.drawLine(Offset(mid, y - 6), Offset(mid, y + 6),
        Paint()..color = ink.withValues(alpha: on ? 0.8 : 0.3)..strokeWidth = 1.5);
    final x = w * t;
    if ((x - mid).abs() > 1) {
      canvas.drawRect(
          Rect.fromLTRB(math.min(mid, x), y - 2.5, math.max(mid, x), y + 2.5),
          Paint()..color = on ? accent : ink.withValues(alpha: 0.25));
    }
    final knob = Rect.fromCenter(center: Offset(x, y), width: 9, height: size.height - 4);
    canvas.drawRect(knob.shift(const Offset(1.2, 1.2)), Paint()..color = ink.withValues(alpha: on ? 1 : 0.3));
    canvas.drawRect(knob, Paint()..color = paper);
    canvas.drawRect(knob,
        Paint()..color = on ? ink : ink.withValues(alpha: 0.4)..style = PaintingStyle.stroke..strokeWidth = 1.2);
  }

  @override
  bool shouldRepaint(_CentrePainter old) => old.t != t || old.on != on || old.accent != accent;
}
