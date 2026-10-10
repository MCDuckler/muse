import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../state/booth/booth.dart';
import '../../../state/booth/deck.dart' as engine;
import '../../../state/booth/mixer.dart' show EqSet;
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

  // The crossfader and the EQ change the drawing (the shape as the room hears it,
  // the mix's progress), so the waves follow the booth's moves as well as the booth.
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: booth.moves, builder: (context, _) => _waves(context));

  Widget _waves(BuildContext context) {
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
                RepaintBoundary(child: _Phase(booth: booth, height: meter)),
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
                    child: ScaleTransition(
                        scale: Tween(begin: 0.92, end: 1.0).animate(a), child: child),
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
  const _Lane(
      {required this.booth, required this.deck, required this.height, this.mirrored = false});
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
            child: Text(deck.name,
                textAlign: TextAlign.center,
                style: Mag.numerals(18, color: t == null ? Console.faint : c)),
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
                    loop: deck.loopStart != null && deck.loopEnd != null
                        ? (deck.loopStart!, deck.loopEnd!)
                        : null,
                    hotCues: deck.hotCues,
                    cueLabels: {for (final n in deck.padWhy.keys) n: deck.padLabel(n)},
                    markAt: auto.running && identical(booth.master, deck) ? auto.goesAt : null,
                    height: height,
                    // Sixteen seconds of the room's time, not the record's: a deck at
                    // 1.07× shows 17 s of its record in the same width, so both strips
                    // scroll at one speed and two records in step show their beats in
                    // one line.
                    window: Duration(microseconds: (16e6 * deck.pitch).round()),
                    inks: WaveInks.press,
                    // The record as the room hears it: kill the bass on the mixer and
                    // the bass goes out of the picture too. Serato has done this for
                    // years and it is the thing people miss when it is not there — with
                    // a bass swapped out mid-mix you can see which record is carrying
                    // the bottom without having to remember which knob you turned.
                    gains: _heard(booth.eqOf(deck)),
                    mirrored: mirrored,
                    accent: c,
                    onScrub: (to) => unawaited(deck.seekByHand(to)),
                  ),
          ),
          SizedBox(width: 62, child: RepaintBoundary(child: _Left(deck: deck))),
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
            style: Mag.typewriter(13,
                color: soon ? Console.deck(deck.name) : Console.quiet, bold: true));
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
    final position = BoothClock.of(context).positionOf(deck);
    // Everything about the record that does not move with the needle, worked out once
    // per build rather than once a frame.
    final span = slicesSpan(deck.timing, total.inMicroseconds.toDouble()) / total.inMicroseconds;
    final cues = [for (final d in deck.hotCues.values) d.inMicroseconds / total.inMicroseconds];
    final markAt = mark == null ? null : mark.inMicroseconds / total.inMicroseconds;
    // Every four bars, down the whole record: the same rules the lane draws tall, so
    // the shape of the song can be read as phrases rather than as a lump — where its
    // eights fall, and where one runs short.
    final phrases = [
      for (final m in deck.timing?.markers ?? const <int>[])
        if (m * 1000 <= total.inMicroseconds) m * 1000 / total.inMicroseconds,
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 26, right: 62),
      child: LayoutBuilder(builder: (context, box) {
        void at(double dx) =>
            unawaited(deck.seekByHand(total * (dx / box.maxWidth).clamp(0.0, 1.0)));
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTapDown: (d) => at(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
            // The record's shape and the needle over it are two layers, not one.
            //
            // The shape does not change while a record plays; the needle changes
            // sixty times a second. Painted together, every one of those frames
            // redrew the whole of a four-minute record — and once the shape was asked
            // for at a hundredth of a second a slice, that is walking twenty-four
            // thousand of them to move a line two pixels. Behind a RepaintBoundary
            // the shape is rasterised once and kept, and the needle is a rectangle.
            // Sized, because a Stack takes its bounds from its parent and this one's
            // parent gives it none.
            child: SizedBox(
                width: box.maxWidth,
                height: height,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: ListenableBuilder(
                          listenable: position,
                          builder: (context, _) => CustomPaint(
                            size: Size(box.maxWidth, height),
                            painter: _OverviewShape(
                              // Which column the record has reached, not where it is: the
                              // bars are drawn every two pixels and coloured by whether
                              // they are behind the needle, so the shape has nothing new to
                              // say until the needle crosses into the next one. On a
                              // four-minute record that is a repaint a second or two
                              // instead of sixty.
                              playedCol: (position.value.inMicroseconds /
                                      total.inMicroseconds *
                                      box.maxWidth /
                                      2)
                                  .floor(),
                              bands: bands,
                              // How much of the record the slices cover. See
                              // slicesSpan: they were measured across the file, and
                              // `total` is the engine's idea of the record.
                              span: span,
                              inks: WaveInks.press,
                              colour: c,
                              cues: cues,
                              mark: markAt,
                              phrases: phrases,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          size: Size(box.maxWidth, height),
                          painter: _OverviewHead(position: position, total: total),
                        ),
                      ),
                    ),
                  ],
                )),
          ),
        );
      }),
    );
  }
}

/// A mixer's three knobs as plain factors for the drawing: 1 at noon, 0 killed.
///
/// Decibels are turned into what they are worth to the ear, and a boost is let through
/// only a little way — the picture is there to say what is in the record, and a shape
/// that grows when a knob is turned up would be saying something about the knob.
({double low, double mid, double high}) _heard(EqSet eq) {
  double one(double db) =>
      db <= EqSet.killed ? 0.0 : math.pow(10, db / 20).toDouble().clamp(0.0, 1.4);
  return (low: one(eq.low), mid: one(eq.mid), high: one(eq.high));
}

class _OverviewShape extends CustomPainter {
  _OverviewShape(
      {required this.playedCol,
      required this.bands,
      required this.span,
      required this.inks,
      required this.colour,
      required this.cues,
      required this.mark,
      required this.phrases});
  final int playedCol;
  final ({List<int> low, List<int> mid, List<int> high})? bands;

  /// What fraction of the record the slices cover — 1.0 where the file and the engine
  /// agree how long it is, which is nearly always.
  final double span;

  /// The three inks the record's shape is printed in. See WaveInks.
  final WaveInks inks;

  /// The deck's own colour, for its cues and its mark.
  final Color colour;
  final List<double> cues;
  final double? mark;
  final List<double> phrases;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final b = bands;
    final played = playedCol * 2.0;
    // A strip along the foot for the four-bar rules, and the shape stands on it.
    // Drawn *through* the shape they were a grid over the record; drawn under it they
    // are a ruler beside it, which is what they are for.
    const foot = 5.0;
    final wh = h - foot;
    if (b != null && b.low.isNotEmpty) {
      final n = b.low.length;
      final paint = Paint();
      for (var x = 0.0; x < w; x += 2) {
        // Every slice under the bar's two pixels: stepping by one pixel's worth read
        // half of them, and a short loud hit between two bars was simply not there.
        final i = (x / w / span * n).floor().clamp(0, n - 1);
        final end = math.max(i + 1, ((x + 2) / w / span * n).floor()).clamp(0, n);
        var lo = 0, md = 0, hi = 0;
        for (var k = i; k < end; k++) {
          if (b.low[k] > lo) lo = b.low[k];
          if (b.mid[k] > md) md = b.mid[k];
          if (b.high[k] > hi) hi = b.high[k];
        }
        final v = math.max(lo, math.max(md, hi));
        final bar = wh * (0.15 + 0.85 * v / 255);
        // The same three inks as the lane, so the whole record and the bit under the
        // needle are the same picture at two scales: the breakdown that is a cyan band
        // an inch wide up here is the cyan the lane is showing down there.
        //
        // Behind the needle it is dimmed rather than recoloured. It used to be the
        // other way about — the played part in the deck's colour, the rest in grey —
        // which spent the only colour the strip had on saying something the needle
        // already says, and left the record's own shape with none.
        final ink = Color(waveInk(inks, lo / 255, md / 255, hi / 255));
        canvas.drawRect(Rect.fromLTWH(x, (wh - bar) / 2, 1.4, bar),
            paint..color = x < played ? ink.withValues(alpha: 0.30) : ink);
      }
    } else {
      canvas.drawRect(Rect.fromLTWH(0, wh / 2 - 1, w, 2), Paint()..color = Console.line);
    }
    // The four-bar rules, along the foot. Only where there is room to tell them
    // apart: on a long record they fall every few pixels at this width, and a rule
    // every few pixels is a grey wash rather than a ruler.
    if (phrases.length > 1) {
      final apart = w * (phrases[1] - phrases[0]);
      if (apart >= 5) {
        canvas.drawRect(
            Rect.fromLTWH(0, h - 1, w, 1), Paint()..color = Console.ink.withValues(alpha: 0.10));
        final rule = Paint()..color = Console.ink.withValues(alpha: 0.45);
        // Every fourth — sixteen bars — stands the full depth of the strip, so the
        // eights are countable without counting.
        final eight = Paint()..color = Console.ink.withValues(alpha: 0.75);
        for (var i = 0; i < phrases.length; i++) {
          final x = w * phrases[i];
          final tall = i % 4 == 0 && apart >= 12;
          final up = tall ? foot : foot * 0.6;
          canvas.drawRect(Rect.fromLTWH(x, h - up, 1, up), tall ? eight : rule);
        }
      }
    }
    for (final c in cues) {
      canvas.drawRect(Rect.fromLTWH(w * c - 1, 0, 2, h), Paint()..color = colour);
    }
    final m = mark;
    if (m != null) {
      canvas.drawRect(Rect.fromLTWH(w * m - 1, 0, 2, h), Paint()..color = Console.ink);
    }
  }

  @override
  bool shouldRepaint(_OverviewShape old) =>
      old.playedCol != playedCol ||
      old.bands != bands ||
      old.span != span ||
      old.inks != inks ||
      old.mark != mark ||
      old.cues.length != cues.length ||
      old.phrases.length != phrases.length;
}

/// The needle, and nothing else: what actually moves while a record plays.
///
/// Repainted straight off the clock, with nothing built: a rectangle moved is all a
/// frame of it costs.
class _OverviewHead extends CustomPainter {
  _OverviewHead({required this.position, required this.total}) : super(repaint: position);
  final ValueListenable<Duration> position;
  final Duration total;

  @override
  void paint(Canvas canvas, Size size) {
    final t = position.value.inMicroseconds / total.inMicroseconds;
    final x = size.width * t.clamp(0.0, 1.0);
    canvas.drawRect(Rect.fromLTWH(x - 1, -1, 2, size.height + 2), Paint()..color = Console.ink);
  }

  @override
  bool shouldRepaint(_OverviewHead old) => old.position != position || old.total != total;
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
                  ms == null
                      ? ''
                      : locked
                          ? 'IN'
                          : '${ms > 0 ? '+' : ''}$ms',
                  textAlign: TextAlign.right,
                  style: locked
                      ? Console.label(9, color: Console.ink)
                      : Mag.numerals(13, color: Console.quiet),
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
    canvas.drawLine(
        Offset(w / 2, y - 6),
        Offset(w / 2, y + 6),
        Paint()
          ..color = Console.quiet
          ..strokeWidth = 1.5);
    final d = drift;
    if (d == null) return;
    final x = w * (0.5 + d.clamp(-0.5, 0.5));
    final c = locked ? Console.ink : Console.a;
    canvas.drawRect(Rect.fromLTRB(math.min(w / 2, x), y - 2, math.max(w / 2, x), y + 2),
        Paint()..color = c.withValues(alpha: 0.35));
    canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: 3, height: size.height * 0.75),
        Paint()..color = c);
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
      // Off the room's clock: a stream made in here was a new timer each time the waves
      // were rebuilt, which during a mix is many times a second.
      child: ListenableBuilder(
        listenable: BoothClock.of(context).positionOf(booth.master),
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
              SizedBox(
                  width: 34,
                  child: Text(s.toStringAsFixed(1), style: Mag.numerals(15, color: accent))),
            ],
          );
        },
      ),
    );
  }
}
