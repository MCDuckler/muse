import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../mag.dart';
import '../booth_clock.dart';
import '../meters.dart' show PhaseMeter;
import '../wave_strip.dart';
import 'console.dart';

/// The two records' shapes across the top of the room, each in its deck's colour,
/// facing each other over the meter that says how far apart their beats are. Each
/// has the whole song as a thin strip beside it: where it is, and how much is left.
class ConsoleWaves extends StatelessWidget {
  const ConsoleWaves({super.key, required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    return Plate(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: LayoutBuilder(builder: (context, c) {
        const meter = 22.0, overview = 16.0, gaps = 8.0;
        final lane = ((c.maxHeight - meter - 2 * overview - gaps) / 2).clamp(40.0, 260.0);
        return Stack(
          children: [
            Column(
              children: [
                _Overview(booth: booth, deck: booth.a, height: overview),
                const SizedBox(height: 2),
                _Lane(booth: booth, deck: booth.a, height: lane),
                _Phase(booth: booth, height: meter),
                _Lane(booth: booth, deck: booth.b, height: lane, mirrored: true),
                const SizedBox(height: 2),
                _Overview(booth: booth, deck: booth.b, height: overview),
              ],
            ),
            // While a mix runs, it says so over the shapes it is mixing.
            Positioned(
              top: overview + 8,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (child, a) => FadeTransition(
                    opacity: a,
                    child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(a), child: child),
                  ),
                  child: booth.mixing != null
                      ? _Banner(booth: booth)
                      : booth.arming != null
                          ? _Arming(booth: booth)
                          : const SizedBox(key: ValueKey('none')),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _Lane extends StatelessWidget {
  const _Lane({required this.booth, required this.deck, required this.height, this.mirrored = false});
  final Booth booth;
  final engine.Deck deck;
  final double height;
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    final t = deck.track;
    final c = Console.deck(deck.name);
    final auto = booth.auto;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(deck.name, textAlign: TextAlign.center, style: Mag.numerals(18, color: t == null ? Console.faint : c)),
          ),
          Expanded(
            child: t == null
                ? Center(child: Container(height: 1, color: Console.line))
                : WaveStrip(
                    position: BoothClock.of(context).positionOf(deck),
                    timing: deck.timing,
                    bands: booth.bands[t.id],
                    duration: deck.duration ?? Duration.zero,
                    playing: deck.playing,
                    loop: deck.loopStart != null && deck.loopEnd != null ? (deck.loopStart!, deck.loopEnd!) : null,
                    hotCues: deck.hotCues,
                    markAt: auto.running && identical(booth.master, deck) ? auto.goesAt : null,
                    height: height,
                    // Sixteen seconds of the room's time, not the record's: a deck at
                    // 1.07× shows 17 s of its record in the same width, so both strips
                    // scroll at one speed and two records in step show their beats in
                    // one line.
                    window: Duration(microseconds: (16e6 * deck.pitch).round()),
                    mirrored: mirrored,
                    accent: c,
                    onScrub: (to) => unawaited(deck.seek(to)),
                  ),
          ),
          SizedBox(width: 62, child: _Left(deck: deck)),
        ],
      ),
    );
  }
}

/// How much of the record is left, counted down as a DJ reads it.
class _Left extends StatelessWidget {
  const _Left({required this.deck});
  final engine.Deck deck;

  @override
  Widget build(BuildContext context) {
    final total = deck.duration;
    if (deck.track == null || total == null) return const SizedBox();
    return ListenableBuilder(
      listenable: BoothClock.of(context).positionOf(deck),
      builder: (context, _) {
        final left = total - deck.position;
        final s = math.max(0, left.inSeconds);
        final soon = deck.playing && s < 30;
        return Text('-${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
            textAlign: TextAlign.right,
            style: Mag.typewriter(13, color: soon ? Console.deck(deck.name) : Console.quiet, bold: true));
      },
    );
  }
}

/// The whole song, thin: where the needle is and where the cues and the booth's
/// own mix point are. Clicked, it goes there.
class _Overview extends StatelessWidget {
  const _Overview({required this.booth, required this.deck, required this.height});
  final Booth booth;
  final engine.Deck deck;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = deck.track;
    final total = deck.duration;
    if (t == null || total == null || total <= Duration.zero) return SizedBox(height: height);
    final c = Console.deck(deck.name);
    final bands = booth.bands[t.id];
    final mark = booth.auto.running && identical(booth.master, deck) ? booth.auto.goesAt : null;
    return Padding(
      padding: const EdgeInsets.only(left: 26, right: 62),
      child: LayoutBuilder(builder: (context, box) {
        void at(double dx) => unawaited(deck.seek(total * (dx / box.maxWidth).clamp(0.0, 1.0)));
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTapDown: (d) => at(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
            child: ListenableBuilder(
              listenable: BoothClock.of(context).positionOf(deck),
              builder: (context, _) => CustomPaint(
                size: Size(box.maxWidth, height),
                painter: _OverviewPainter(
                  t: deck.position.inMicroseconds / total.inMicroseconds,
                  bands: bands,
                  colour: c,
                  cues: [for (final d in deck.hotCues.values) d.inMicroseconds / total.inMicroseconds],
                  mark: mark == null ? null : mark.inMicroseconds / total.inMicroseconds,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter({required this.t, required this.bands, required this.colour, required this.cues, required this.mark});
  final double t;
  final ({List<int> low, List<int> mid, List<int> high})? bands;
  final Color colour;
  final List<double> cues;
  final double? mark;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final b = bands;
    final played = w * t.clamp(0.0, 1.0);
    if (b != null && b.low.isNotEmpty) {
      final n = b.low.length;
      final step = math.max(1, (n / w).floor());
      for (var x = 0.0; x < w; x += 2) {
        final i = (x / w * n).floor().clamp(0, n - 1);
        var v = 0;
        for (var k = i; k < math.min(n, i + step); k++) {
          v = math.max(v, math.max(b.low[k], math.max(b.mid[k], b.high[k])));
        }
        final bar = h * (0.15 + 0.85 * v / 255);
        canvas.drawRect(Rect.fromLTWH(x, (h - bar) / 2, 1.4, bar),
            Paint()..color = x < played ? colour.withValues(alpha: 0.45) : Console.quiet.withValues(alpha: 0.55));
      }
    } else {
      canvas.drawRect(Rect.fromLTWH(0, h / 2 - 1, w, 2), Paint()..color = Console.line);
      canvas.drawRect(Rect.fromLTWH(0, h / 2 - 1, played, 2), Paint()..color = colour.withValues(alpha: 0.6));
    }
    for (final c in cues) {
      canvas.drawRect(Rect.fromLTWH(w * c - 1, 0, 2, h), Paint()..color = colour);
    }
    final m = mark;
    if (m != null) {
      canvas.drawRect(Rect.fromLTWH(w * m - 1, 0, 2, h), Paint()..color = Console.ink);
    }
    canvas.drawRect(Rect.fromLTWH(played - 1, -1, 2, h + 2), Paint()..color = Console.ink);
  }

  @override
  bool shouldRepaint(_OverviewPainter old) =>
      old.t != t || old.bands != bands || old.mark != mark || old.cues.length != cues.length;
}

/// How far apart the beats are: a needle about the middle, and a number only when
/// there is something wrong with it.
class _Phase extends StatelessWidget {
  const _Phase({required this.booth, required this.height});
  final Booth booth;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: BoothClock.of(context).positionOf(booth.master),
      builder: (context, _) {
        final drift = PhaseMeter.driftOf(booth);
        final beat = booth.other(booth.master).beat;
        final ms = drift == null || beat == null ? null : (drift * beat.inMilliseconds).round();
        final locked = ms != null && ms.abs() <= 12;
        return SizedBox(
          height: height,
          child: Row(
            children: [
              const SizedBox(width: 26),
              Expanded(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _PhasePainter(drift: drift, locked: locked),
                ),
              ),
              SizedBox(
                width: 62,
                child: Text(
                  ms == null ? '' : locked ? 'IN' : '${ms > 0 ? '+' : ''}$ms',
                  textAlign: TextAlign.right,
                  style: locked ? Console.label(9, color: Console.ink) : Mag.numerals(13, color: Console.quiet),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PhasePainter extends CustomPainter {
  _PhasePainter({required this.drift, required this.locked});
  final double? drift;
  final bool locked;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2, w = size.width;
    canvas.drawLine(Offset(0, y), Offset(w, y), Paint()..color = Console.line);
    canvas.drawLine(Offset(w / 2, y - 6), Offset(w / 2, y + 6), Paint()..color = Console.quiet..strokeWidth = 1.5);
    final d = drift;
    if (d == null) return;
    final x = w * (0.5 + d.clamp(-0.5, 0.5));
    final c = locked ? Console.ink : Console.a;
    canvas.drawRect(Rect.fromLTRB(math.min(w / 2, x), y - 2, math.max(w / 2, x), y + 2), Paint()..color = c.withValues(alpha: 0.35));
    canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: 3, height: size.height * 0.75), Paint()..color = c);
  }

  @override
  bool shouldRepaint(_PhasePainter old) => old.drift != drift || old.locked != locked;
}

/// A mix in progress: which way, how, and how far through.
class _Banner extends StatelessWidget {
  const _Banner({required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final m = booth.mixing!;
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      key: const ValueKey('mixing'),
      width: 260,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 9),
      decoration: BoxDecoration(
        color: Console.ground.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent),
        boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.3), blurRadius: 18)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(m.from, style: Mag.numerals(18, color: Console.deck(m.from))),
              const SizedBox(width: 6),
              Icon(transitionIcon(m.kind), size: 16, color: Console.ink),
              const SizedBox(width: 6),
              Text(m.to, style: Mag.numerals(18, color: Console.deck(m.to))),
              const SizedBox(width: 12),
              Text(m.kind.label.toUpperCase(), style: Console.label(10, color: Console.ink)),
              const SizedBox(width: 8),
              Text('${m.bars}', style: Mag.numerals(13, color: Console.quiet)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: m.k,
              minHeight: 4,
              color: accent,
              backgroundColor: Console.line,
            ),
          ),
        ],
      ),
    );
  }
}

/// A mix waiting for its beat: which way, how, and in how long.
class _Arming extends StatelessWidget {
  const _Arming({required this.booth});
  final Booth booth;

  @override
  Widget build(BuildContext context) {
    final m = booth.arming!;
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      key: const ValueKey('arming'),
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
      decoration: BoxDecoration(
        color: Console.ground.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.6)),
      ),
      child: StreamBuilder<int>(
        stream: Stream.periodic(const Duration(milliseconds: 50), (i) => i),
        builder: (context, _) {
          final left = m.startsAt.difference(DateTime.now());
          final s = left.isNegative ? 0.0 : left.inMilliseconds / 1000;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(m.from, style: Mag.numerals(16, color: Console.deck(m.from))),
              const SizedBox(width: 6),
              Icon(transitionIcon(m.kind), size: 15, color: Console.quiet),
              const SizedBox(width: 6),
              Text(m.to, style: Mag.numerals(16, color: Console.deck(m.to))),
              const SizedBox(width: 12),
              Text('ON THE ONE', style: Console.label(9, color: Console.quiet)),
              const SizedBox(width: 10),
              SizedBox(width: 34, child: Text(s.toStringAsFixed(1), style: Mag.numerals(15, color: accent))),
            ],
          );
        },
      ),
    );
  }
}
