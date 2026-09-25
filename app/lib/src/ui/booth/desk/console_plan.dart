import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../state/booth/booth.dart';
import '../../../state/booth/mixer.dart';
import '../../../state/booth/automix.dart';
import '../../../state/booth/planner.dart';
import '../../feel.dart';
import '../../mag.dart';
import 'console.dart';
import 'console_set.dart' show planPair;

/// Asked for from the keyboard (P): the room switches between the waveforms and the
/// plan each time this counts up.
final planViewToggles = ValueNotifier<int>(0);

/// What the Auto DJ is about to do, drawn out, with a hand on it.
///
/// The two records as two lanes on one ruler of bars — the one playing above, the one
/// coming below, lined up the way the mix will line them up — each with its phrases,
/// how hard each bar hits, where the voice is, its drops and its hook; over them, the
/// move itself: the fader, each stem's level, the bass taken out, the filter. Beside
/// it, every move the planner weighed, best first, and why; any of them can be
/// chosen instead, made longer or shorter, or moved a phrase either way.
class ConsolePlan extends StatefulWidget {
  const ConsolePlan({super.key, required this.booth});
  final Booth booth;

  @override
  State<ConsolePlan> createState() => _ConsolePlanState();
}

class _ConsolePlanState extends State<ConsolePlan> {
  // The playhead moves between the booth's own reports.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final booth = widget.booth;
    return ListenableBuilder(
      listenable: Listenable.merge([booth, booth.auto, planPair]),
      builder: (context, _) => Plate(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final booth = widget.booth;
    final auto = booth.auto;
    final accent = Theme.of(context).colorScheme.primary;
    final from = booth.master;
    final to = booth.other(from);
    final pair = planPair.value;
    // A pair further down the set, asked for from the strip.
    if (pair != null && (pair.$1 != auto.current?.id || pair.$2 != auto.next?.id)) {
      return _PairBody(booth: booth, pair: pair, accent: accent);
    }
    final p = auto.planned;
    final go = auto.goesAt;

    String? why;
    if (!auto.running) {
      why = 'The Auto DJ is off. Switched on, its plan for the next transition is laid out here.';
    } else if (auto.next == null) {
      why = 'The last record: nothing to mix into.';
    } else if (auto.replaying) {
      why = 'A kept mix, done again as it was.';
    } else if (p == null || go == null || from.timing?.bar == null || to.timing?.bar == null) {
      final kind = auto.plan?.kind;
      final doing = auto.working;
      final secs = auto.workingFor?.inSeconds ?? 0;
      why = doing != null
          ? 'Working out the next transition: $doing…${secs >= 3 ? ' ($secs s)' : ''}'
          : kind == null
              ? 'Working out the next transition…'
              : 'These two cannot be put in step: ${kind.label}, nothing more to plan.';
    }
    if (why != null) {
      return Center(child: Text(why, style: Mag.typewriter(12, color: Console.quiet)));
    }

    final steps = MixStep.onBars(Booth.plan(p!.kind, from: from.name, to: to.name), p.bars);
    final stems = from.stemmed && to.stemmed;
    final canSteer = auto.canSteer;

    final header = Row(
      children: [
        Text('PLAN', style: Console.label(9, color: accent)),
        const SizedBox(width: 12),
        Icon(transitionIcon(p.kind), size: 16, color: Console.ink),
        const SizedBox(width: 6),
        Text('${p.kind.label.toUpperCase()} · ${p.bars} BARS', style: Console.label(9, color: Console.ink)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(p.why,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.typewriter(11, color: Console.quiet)),
        ),
        if (auto.steered) ...[
          Text('BY HAND', style: Console.label(8.5, color: accent)),
          const SizedBox(width: 6),
          Pad(
            label: 'AUTO',
            height: 24,
            colour: Console.ink,
            tooltip: "Let the Auto DJ choose again",
            onTap: canSteer ? () => unawaited(auto.letThePlannerChoose()) : null,
          ),
        ],
      ],
    );

    Widget nudge(String what, String tip, Future<void> Function(int) by) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(what, style: Console.label(8)),
            const SizedBox(width: 4),
            Pad(
              icon: Icons.chevron_left,
              height: 24,
              width: 28,
              tooltip: '$tip a phrase earlier',
              onTap: canSteer ? () => unawaited(by(-1)) : null,
            ),
            const SizedBox(width: 2),
            Pad(
              icon: Icons.chevron_right,
              height: 24,
              width: 28,
              tooltip: '$tip a phrase later',
              onTap: canSteer ? () => unawaited(by(1)) : null,
            ),
          ],
        );

    final controls = Wrap(
      spacing: 14,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        nudge('OUT', 'The old record goes out', auto.nudgeOut),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('LENGTH', style: Console.label(8)),
            const SizedBox(width: 4),
            for (final n in const [4, 8, 16, 32, 64]) ...[
              Pad(
                label: '$n',
                height: 24,
                width: 32,
                lit: p.bars == n,
                colour: Console.ink,
                tooltip: 'Over $n bars',
                onTap: canSteer && p.bars != n ? () => unawaited(auto.lengthen(n)) : null,
              ),
              const SizedBox(width: 2),
            ],
          ],
        ),
        nudge('IN', 'The new record comes in', auto.nudgeIn),
        _Legend(stems: stems),
      ],
    );

    final picture = _Picture(
      from: from.timing!,
      to: to.timing!,
      fromDeck: from.name,
      toDeck: to.name,
      goesAt: go!,
      inAt: auto.comesInAt ?? to.position,
      bars: p.bars,
      steps: steps,
      fromVoice: auto.fromVoice,
      toVoice: auto.toVoice,
      playhead: from.position,
      stems: stems,
      fromTitle: from.track?.displayTitle ?? '',
      toTitle: to.track?.displayTitle ?? '',
    );

    final drawing = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRect(
            child: CustomPaint(painter: _PlanPainter(picture)),
          ),
        ),
        const SizedBox(height: 6),
        controls,
      ],
    );
    final options = auto.options.length > 1 ? _Options(booth: booth, enabled: canSteer) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: 6),
        Expanded(child: _beside(drawing, options)),
      ],
    );
  }
}

/// The drawing with the options beside it where there is room, under it where there
/// is not: a phone.
Widget _beside(Widget drawing, Widget? options) => LayoutBuilder(builder: (context, c) {
      if (options == null) return drawing;
      if (c.maxWidth >= 560) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: drawing),
            const SizedBox(width: 12),
            SizedBox(width: 250, child: options),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: drawing),
          const SizedBox(height: 8),
          Expanded(flex: 4, child: options),
        ],
      );
    });

/// Every move the planner weighed, best first; one tapped is the one done.
class _Options extends StatelessWidget {
  const _Options({required this.booth, required this.enabled});
  final Booth booth;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final auto = booth.auto;
    return OptionsList(
        options: auto.options, chosen: auto.planned, enabled: enabled, onPick: (o) => unawaited(auto.steer(o)));
  }
}

/// Every move the planner weighed for a pair, best first; one tapped is the one done.
class OptionsList extends StatelessWidget {
  const OptionsList({super.key, required this.options, required this.chosen, required this.enabled, required this.onPick});
  final List<MixPlan> options;
  final MixPlan? chosen;
  final bool enabled;
  final void Function(MixPlan) onPick;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final now = chosen;
    final top = options.map((o) => o.score).fold<double>(0.01, math.max);
    return Container(
      decoration: BoxDecoration(
        color: Console.ground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Console.line),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: options.length,
        itemBuilder: (context, i) {
          final o = options[i];
          final chosen = now != null && now.kind == o.kind && now.shift == o.shift && (identical(now, o) || now.why == o.why);
          return InkWell(
            onTap: enabled && !chosen
                ? () {
                    feel(Feel.commit);
                    onPick(o);
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                children: [
                  Icon(transitionIcon(o.kind), size: 15, color: chosen ? accent : Console.quiet),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('${o.kind.label} · ${o.bars}${o.shift == 0 ? '' : ' · ${o.shift > 0 ? '+' : ''}${o.shift.round()} st'}',
                                style: Mag.typewriter(11.5, color: chosen ? accent : Console.ink)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: (o.score / top).clamp(0.0, 1.0),
                                  minHeight: 3,
                                  color: chosen ? accent : Console.quiet,
                                  backgroundColor: Console.line,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Text(o.why,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Mag.typewriter(10, color: Console.faint)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.stems});
  final bool stems;

  @override
  Widget build(BuildContext context) {
    Widget key(Color c, String what) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 3, color: c),
          const SizedBox(width: 3),
          Text(what, style: Console.label(7.5)),
          const SizedBox(width: 8),
        ]);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (stems) ...[
          key(PlanColours.drums, 'DRUMS'),
          key(PlanColours.rest, 'BASS+REST'),
          key(PlanColours.vocals, 'VOICE'),
        ] else
          key(Console.ink, 'LEVEL'),
        key(PlanColours.sung, 'SUNG'),
        key(PlanColours.drop, 'DROP'),
      ],
    );
  }
}

/// The plan view's own colours: a stem each, and the marks on the records.
abstract final class PlanColours {
  static const drums = Color(0xFF5AC8FA);
  static const rest = Color(0xFF7ED67A);
  static const vocals = Color(0xFFFF7AC6);
  static const sung = Color(0xFFB98CFF);
  static const drop = Color(0xFFFFFFFF);
  static const kill = Color(0xFFFF4A3D);
  static const filter = Color(0xFF9D8CFF);
}

/// Everything the painter needs, read off the booth once a frame.
class _Picture {
  const _Picture({
    required this.from,
    required this.to,
    required this.fromDeck,
    required this.toDeck,
    required this.goesAt,
    required this.inAt,
    required this.bars,
    required this.steps,
    required this.fromVoice,
    required this.toVoice,
    required this.playhead,
    required this.stems,
    required this.fromTitle,
    required this.toTitle,
  });
  final TrackTiming from, to;
  final String fromDeck, toDeck;
  final Duration goesAt, inAt, playhead;
  final int bars;
  final List<MixStep> steps;
  final VocalMap? fromVoice, toVoice;
  final bool stems;
  final String fromTitle, toTitle;
}

/// A place in [t], in its bars: 12.5 is half way through its thirteenth.
double barAt(TrackTiming t, Duration at) {
  final d = t.downbeats;
  final bar = t.bar;
  final ms = at.inMilliseconds;
  if (d.isEmpty || bar == null) return 0;
  final len = bar.inMicroseconds / 1000;
  if (ms < d.first) return (ms - d.first) / len;
  var i = 0;
  while (i + 1 < d.length && d[i + 1] <= ms) {
    i++;
  }
  return i + (ms - d[i]) / len;
}

/// The move at [k] of the way through, as the booth will carry it out: the fader
/// travelled to evenly; a stem deck's levels likewise, held at the last step's until
/// the end (see Booth.go); the bands and the loop held from the step that set them.
class PlanAt {
  PlanAt(this.steps, this.deck);
  final List<MixStep> steps;
  final String deck;

  double crossfader(double k) {
    MixStep? before, after;
    for (final s in steps) {
      if (s.crossfader == null) continue;
      if (s.at <= k) {
        before = s;
      } else {
        after ??= s;
      }
    }
    if (before == null) return after?.crossfader ?? 0;
    if (after == null) return before.crossfader!;
    final t = ((k - before.at) / (after.at - before.at)).clamp(0.0, 1.0);
    return before.crossfader! + (after.crossfader! - before.crossfader!) * t;
  }

  StemLevels stems(double k) {
    MixStep? before, after;
    for (final s in steps) {
      if (s.decks[deck]?.stems == null) continue;
      if (s.at <= k) {
        before = s;
      } else {
        after ??= s;
      }
    }
    if (before == null) return StemLevels.all;
    final a = before.decks[deck]!.stems!;
    if (after == null || after.at >= 1) return a;
    final span = after.at - before.at;
    return a.lerp(after.decks[deck]!.stems!, span <= 0 ? 1 : ((k - before.at) / span).clamp(0.0, 1.0));
  }

  T? held<T>(double k, T? Function(DeckStep) what) {
    T? got;
    for (final s in steps) {
      if (s.at > k) break;
      final d = s.decks[deck];
      if (d == null) continue;
      final v = what(d);
      if (v != null) got = v;
    }
    return got;
  }

  double filter(double k) {
    MixStep? before, after;
    for (final s in steps) {
      if (s.decks[deck]?.filter == null) continue;
      if (s.at <= k) {
        before = s;
      } else {
        after ??= s;
      }
    }
    if (before == null) return 0;
    final a = before.decks[deck]!.filter!;
    if (after == null) return a;
    final t = ((k - before.at) / (after.at - before.at)).clamp(0.0, 1.0);
    return a + (after.decks[deck]!.filter! - a) * t;
  }
}

class _PlanPainter extends CustomPainter {
  _PlanPainter(this.p);
  final _Picture p;

  static const _around = 8.0; // bars shown either side of the transition

  @override
  void paint(Canvas canvas, Size size) {
    final g = barAt(p.from, p.goesAt);
    final start = g - _around, end = g + p.bars + _around;
    double x(double bar) => (bar - start) / (end - start) * size.width;

    const gap = 16.0;
    final laneH = (size.height - gap) / 2;
    final top = Rect.fromLTWH(0, 0, size.width, laneH);
    final bottom = Rect.fromLTWH(0, laneH + gap, size.width, laneH);

    // The transition's span, over both lanes.
    canvas.drawRect(Rect.fromLTRB(x(g), 0, x(g + p.bars), size.height),
        Paint()..color = Console.ink.withValues(alpha: 0.05));
    for (final at in [g, g + p.bars]) {
      canvas.drawLine(Offset(x(at), 0), Offset(x(at), size.height),
          Paint()
            ..color = Console.ink.withValues(alpha: 0.35)
            ..strokeWidth = 1);
    }

    // The incoming's bars, placed on the outgoing's ruler: its parked place meets the
    // transition's first bar.
    final i0 = barAt(p.to, p.inAt);
    double fromIn(double bar) => g + (bar - i0);

    _record(canvas, top, p.from, p.fromVoice, (b) => x(b), start, end, Console.deck(p.fromDeck), p.fromTitle);
    _record(canvas, bottom, p.to, p.toVoice, (b) => x(fromIn(b)), i0 - (g - start), i0 + (end - g),
        Console.deck(p.toDeck), p.toTitle);

    // The move, drawn over each record.
    _automation(canvas, top, PlanAt(p.steps, p.fromDeck), outgoing: true, x: x, g: g);
    _automation(canvas, bottom, PlanAt(p.steps, p.toDeck), outgoing: false, x: x, g: g);

    // Where the record playing is now.
    final head = barAt(p.from, p.playhead);
    if (head >= start && head <= end) {
      canvas.drawLine(Offset(x(head), 0), Offset(x(head), laneH),
          Paint()
            ..color = Console.ink
            ..strokeWidth = 2);
    }

    // The two places, as times in each record.
    _text(canvas, 'OUT ${_clock(p.goesAt)} · IN ${_clock(p.inAt)} · ${p.bars} BARS',
        Offset(x(g) + 4, laneH + 3), Console.quiet, 8.5, rightOf: size.width * 0.6);
  }

  void _record(Canvas canvas, Rect lane, TrackTiming t, VocalMap? v, double Function(double) x, double from,
      double to, Color colour, String title) {
    canvas.drawRRect(RRect.fromRectAndRadius(lane, const Radius.circular(4)),
        Paint()..color = Console.ground);
    final d = t.downbeats;
    final first = math.max(0, from.floor());
    final last = math.min(d.length - 1, to.ceil());
    final markers = t.markers.toSet();
    for (var b = first; b <= last; b++) {
      final x0 = x(b.toDouble()), x1 = x(b + 1.0);
      if (x1 < 0 || x0 > lane.width) continue;
      // How hard the bar hits.
      if (b < t.energy.length) {
        final h = t.energy[b] / 255 * lane.height * 0.55;
        canvas.drawRect(Rect.fromLTRB(x0 + 0.5, lane.bottom - h, x1 - 0.5, lane.bottom),
            Paint()..color = colour.withValues(alpha: 0.18));
      }
      // The voice.
      final level = v?.bars;
      if (level != null && b < level.length && level[b] > 0) {
        final a = (level[b] / 255).clamp(0.0, 1.0);
        canvas.drawRect(Rect.fromLTRB(x0, lane.top + 3, x1, lane.top + 9),
            Paint()..color = PlanColours.sung.withValues(alpha: level[b] >= VocalMap.sung ? 0.3 + 0.6 * a : 0.12));
      }
      // Its phrases.
      if (markers.contains(d[b])) {
        canvas.drawLine(Offset(x0, lane.top), Offset(x0, lane.bottom),
            Paint()
              ..color = Console.line
              ..strokeWidth = 1);
      }
    }
    // Drops.
    for (final ms in t.drops) {
      final b = barAt(t, Duration(milliseconds: ms));
      if (b < from || b > to) continue;
      final px = x(b);
      canvas.drawLine(Offset(px, lane.top), Offset(px, lane.bottom),
          Paint()
            ..color = PlanColours.drop.withValues(alpha: 0.7)
            ..strokeWidth = 1.5);
      _text(canvas, 'DROP', Offset(px + 3, lane.bottom - 12), PlanColours.drop, 7.5);
    }
    // The hook, where the words say it is sung.
    for (final ms in v?.hook?.at ?? const <int>[]) {
      final b = barAt(t, Duration(milliseconds: ms));
      if (b < from || b > to) continue;
      final px = x(b);
      final path = Path()
        ..moveTo(px, lane.top + 10)
        ..lineTo(px + 4, lane.top + 15)
        ..lineTo(px, lane.top + 20)
        ..lineTo(px - 4, lane.top + 15)
        ..close();
      canvas.drawPath(path, Paint()..color = PlanColours.vocals);
      _text(canvas, 'HOOK', Offset(px + 6, lane.top + 10), PlanColours.vocals, 7.5);
    }
    _text(canvas, title, Offset(lane.left + 6, lane.top + 11), colour, 10, rightOf: lane.width * 0.45);
  }

  void _automation(Canvas canvas, Rect lane, PlanAt at,
      {required bool outgoing, required double Function(double) x, required double g}) {
    const n = 160;
    double share(double k) => outgoing ? 1 - at.crossfader(k) : at.crossfader(k);
    double y(double v) => lane.bottom - 3 - v.clamp(0.0, 1.0) * (lane.height - 26);

    // The bass taken out, and the filter, as bands along the bottom.
    for (var i = 0; i < n; i++) {
      final k = i / n, k1 = (i + 1) / n;
      final x0 = x(g + k * p.bars), x1 = x(g + k1 * p.bars);
      final low = at.held<double>(k, (d) => d.eq?.low) ?? 0;
      if (low <= EqSet.killed / 2) {
        canvas.drawRect(Rect.fromLTRB(x0, lane.bottom - 3, x1, lane.bottom),
            Paint()..color = PlanColours.kill.withValues(alpha: 0.8));
      }
      final f = at.filter(k);
      if (f.abs() > 0.02) {
        canvas.drawRect(Rect.fromLTRB(x0, lane.top, x1, lane.top + 3),
            Paint()..color = PlanColours.filter.withValues(alpha: 0.25 + 0.7 * f.abs()));
      }
    }

    // Before and after the move each record simply plays, or does not.
    final before = outgoing ? 1.0 : 0.0, after = outgoing ? 0.0 : 1.0;
    Path line(double Function(double k) v) {
      final path = Path()..moveTo(0, y(before * v(0)));
      path.lineTo(x(g), y(before * v(0)));
      for (var i = 0; i <= n; i++) {
        final k = i / n;
        path.lineTo(x(g + k * p.bars), y(v(k)));
      }
      path.lineTo(lane.width, y(after * v(1)));
      return path;
    }

    Paint stroke(Color c, double w) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..color = c;

    if (p.stems) {
      canvas.drawPath(line((k) => share(k) * at.stems(k).drums), stroke(PlanColours.drums, 1.6));
      canvas.drawPath(line((k) => share(k) * at.stems(k).rest), stroke(PlanColours.rest, 1.6));
      canvas.drawPath(line((k) => share(k) * at.stems(k).vocals), stroke(PlanColours.vocals, 1.6));
    } else {
      canvas.drawPath(line(share), stroke(Console.ink, 1.8));
    }
  }

  void _text(Canvas canvas, String s, Offset at, Color colour, double size, {double? rightOf}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: Console.label(size, color: colour)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: rightOf ?? 400);
    tp.paint(canvas, at);
  }

  static String _clock(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(_PlanPainter old) => true;
}


/// The plan view on a pair further down the set: the move the booth would make
/// between them (or the one a hand chose), drawn as the next one is, with every other
/// move it weighed beside it.
class _PairBody extends StatefulWidget {
  const _PairBody({required this.booth, required this.pair, required this.accent});
  final Booth booth;
  final (int, int) pair;
  final Color accent;

  @override
  State<_PairBody> createState() => _PairBodyState();
}

class _PairBodyState extends State<_PairBody> {
  // Asked once per pair, not on every tick of the view.
  (int, int)? _for;
  Future<List<MixPlan>>? _options;

  Future<List<MixPlan>> _optionsFor(Track a, Track b) {
    if (_for != widget.pair || _options == null) {
      _for = widget.pair;
      _options = widget.booth.auto.optionsFor(a, b);
    }
    return _options!;
  }

  @override
  Widget build(BuildContext context) {
    final booth = widget.booth;
    final pair = widget.pair;
    final accent = widget.accent;
    final auto = booth.auto;
    final all = [if (auto.current != null) auto.current!, ...auto.upcoming];
    Track? find(int id) => all.cast<Track?>().firstWhere((t) => t!.id == id, orElse: () => null);
    final a = find(pair.$1), b = find(pair.$2);
    final back = Pad(label: 'NEXT PAIR', height: 24, colour: Console.ink, tooltip: 'Back to the transition coming', onTap: () => planPair.value = null);
    if (a == null || b == null) {
      return Row(children: [
        Expanded(child: Text('That pair is no longer in the set.', style: Mag.typewriter(12, color: Console.quiet))),
        back,
      ]);
    }
    final ta = booth.timing.peek(a.id), tb = booth.timing.peek(b.id);
    return FutureBuilder<List<MixPlan>>(
      future: _optionsFor(a, b),
      builder: (context, snap) {
        final options = snap.data ?? const <MixPlan>[];
        final chosen = auto.steers[pair] ?? (options.isEmpty ? null : options.first);
        final header = Row(children: [
          Text('PLAN', style: Console.label(9, color: accent)),
          const SizedBox(width: 12),
          Expanded(
            child: Text('${a.displayTitle}  →  ${b.displayTitle}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: Mag.title(13, color: Console.ink)),
          ),
          if (chosen != null) ...[
            Icon(transitionIcon(chosen.kind), size: 16, color: Console.ink),
            const SizedBox(width: 6),
            Text('${chosen.kind.label.toUpperCase()} · ${chosen.bars} BARS', style: Console.label(9, color: Console.ink)),
            const SizedBox(width: 10),
          ],
          if (auto.steers.containsKey(pair)) ...[
            Text('BY HAND', style: Console.label(8.5, color: accent)),
            const SizedBox(width: 6),
            Pad(label: 'AUTO', height: 24, colour: Console.ink, onTap: () => auto.steerPair(a, b, null)),
            const SizedBox(width: 6),
          ],
          back,
        ]);
        Widget middle;
        if (ta == null || tb == null || ta.bar == null || tb.bar == null) {
          middle = Center(child: Text('Nothing known of these two yet.', style: Mag.typewriter(12, color: Console.quiet)));
        } else if (chosen == null) {
          middle = Center(child: Text(snap.hasData ? 'These two cannot be put in step.' : 'Working it out…', style: Mag.typewriter(12, color: Console.quiet)));
        } else {
          final bar = ta.bar!;
          final goesAt = chosen.outAt ?? AutoMix.outPoint(ta, length: bar * chosen.bars);
          final inAt = chosen.inAt ?? AutoMix.inPoint(tb, bars: chosen.bars);
          final steps = MixStep.onBars(Booth.plan(chosen.kind, from: 'A', to: 'B'), chosen.bars);
          middle = ClipRect(
            child: CustomPaint(
              painter: _PlanPainter(_Picture(
                from: ta,
                to: tb,
                fromDeck: 'A',
                toDeck: 'B',
                goesAt: goesAt,
                inAt: inAt,
                bars: chosen.bars,
                steps: steps,
                fromVoice: booth.vocals.peek(a.id),
                toVoice: booth.vocals.peek(b.id),
                playhead: Duration.zero,
                stems: chosen.kind.needsStems,
                fromTitle: a.displayTitle,
                toTitle: b.displayTitle,
              )),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const SizedBox(height: 6),
            Expanded(
              child: _beside(
                middle,
                options.length > 1
                    ? OptionsList(options: options, chosen: chosen, enabled: true, onPick: (o) => auto.steerPair(a, b, o))
                    : null,
              ),
            ),
          ],
        );
      },
    );
  }
}
