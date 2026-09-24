// The automix's choosing: what it reaches for with records in stems, words and drops,
// and that it does not make the same move twice running.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/automix.dart';
import 'package:muse/src/state/booth/booth.dart';
import 'package:muse/src/state/booth/planner.dart';

/// 128 bpm-ish: a beat every 469 ms, a bar every 1876 ms. [intro] bars before the song
/// is "on", [outro] bars of outro, and [drops] (bars).
TrackTiming record({int bars = 120, int intro = 32, int outro = 32, List<int> drops = const [],
    String camelot = '8A'}) {
  const beat = 469;
  final beats = [for (var i = 0; i < bars * 4; i++) i * beat];
  final downs = [for (var i = 0; i < beats.length; i += 4) beats[i]];
  return TrackTiming(
    durationMs: bars * 4 * beat + 2000,
    bpm: 60000 / beat,
    beats: beats,
    downbeats: downs,
    camelot: camelot,
    keyConfidence: 0.8,
    key: 'A minor',
    drops: [for (final d in drops) downs[d]],
    energy: [for (var i = 0; i < bars; i++) 200],
    cues: MixCues(
        firstDownbeatMs: 0,
        mixInMs: downs[intro],
        mixOutMs: downs[bars - outro],
        soundEndMs: bars * 4 * beat),
  );
}

VocalMap voice(int bars, bool Function(int bar) sung, {List<int> hookAt = const []}) => VocalMap(
      bars: [for (var i = 0; i < bars; i++) sung(i) ? 220 : 0],
      timed: hookAt.isNotEmpty,
      hook: hookAt.isEmpty ? null : (text: 'Tell me something good', at: hookAt),
      lyrics: 'lrclib',
    );

void main() {
  test('a record whose hook is known announces itself over the one before', () {
    final from = record();
    final to = record();
    // The hook first sung at bar 40.
    final plan = Planner.plan(
      from: MixSide(timing: from, vocals: voice(120, (b) => b > 16 && b < 80), stems: true),
      to: MixSide(timing: to, vocals: voice(120, (b) => b >= 40, hookAt: [to.downbeats[40]]), stems: true),
      style: MixStyle.bold,
      random: math.Random(1),
    );
    expect(plan.kind, Transition.announce, reason: plan.toString());
    expect(plan.inAt, Duration(milliseconds: to.downbeats[40]), reason: 'on the marker of its hook');
    expect(plan.why, contains('Tell me something'));
  });

  test('the same move is not made twice running', () {
    final from = record();
    final to = record();
    final plan = Planner.plan(
      from: MixSide(timing: from, vocals: voice(120, (b) => b > 16 && b < 80), stems: true),
      to: MixSide(timing: to, vocals: voice(120, (b) => b >= 40, hookAt: [to.downbeats[40]]), stems: true),
      style: MixStyle.bold,
      recent: const [Transition.announce],
      random: math.Random(1),
    );
    expect(plan.kind, isNot(Transition.announce));
  });

  test('easy, with room either side, blends long and stem by stem', () {
    final plan = Planner.plan(
      from: MixSide(timing: record(bars: 200, outro: 64), stems: true),
      to: MixSide(timing: record(bars: 200, intro: 64), stems: true),
      style: MixStyle.easy,
      random: math.Random(3),
    );
    expect(plan.kind, Transition.stemBlend);
    expect(plan.bars, 64);
  });

  test('a record with a drop is cued so it lands on the last beat', () {
    final to = record(drops: const [48]);
    final plan = Planner.plan(
      from: MixSide(timing: record()),
      to: MixSide(timing: to),
      style: MixStyle.bold,
      random: math.Random(2),
    );
    expect(plan.kind, anyOf(Transition.dropSwap, Transition.roll));
    final bars = plan.bars;
    expect(plan.inAt, Duration(milliseconds: to.downbeats[48 - bars]));
  });

  test('two voices at once is said, and costs the blend', () {
    final plan = Planner.plan(
      from: MixSide(timing: record(), vocals: voice(120, (b) => true)),
      to: MixSide(timing: record(), vocals: voice(120, (b) => true)),
      style: MixStyle.easy,
      random: math.Random(4),
    );
    // Without stems nothing can take a voice out: what is chosen is not the blend,
    // or is a blend that says what it costs.
    if (plan.kind == Transition.blend) expect(plan.why, contains('two voices'));
  });

  test('without stems, no stem move is planned', () {
    for (var seed = 0; seed < 20; seed++) {
      final plan = Planner.plan(
        from: MixSide(timing: record(), vocals: voice(120, (b) => b > 16)),
        to: MixSide(timing: record(), vocals: voice(120, (b) => b >= 40, hookAt: [record().downbeats[40]])),
        style: MixStyle.values[seed % 3],
        random: math.Random(seed),
      );
      expect(plan.kind.needsStems, isFalse, reason: plan.toString());
    }
  });

  test('a drop too near the start to land on the last beat is not swapped onto', () {
    final from = record();
    for (final (drop, offered) in [(6, false), (40, true)]) {
      final to = record(drops: [drop]);
      final kinds = <Transition>{};
      for (var seed = 0; seed < 40; seed++) {
        kinds.add(Planner.plan(
          from: MixSide(timing: from),
          to: MixSide(timing: to),
          style: MixStyle.bold,
          recent: const [Transition.swap],
          random: math.Random(seed),
        ).kind);
      }
      expect(kinds.contains(Transition.dropSwap), offered, reason: 'drop at bar $drop: $kinds');
    }
  });

  test('a hook first sung near the end is no announcement', () {
    final from = record();
    final to = record();
    final plan = Planner.plan(
      from: MixSide(timing: from, vocals: voice(120, (b) => b > 16 && b < 80), stems: true),
      to: MixSide(timing: to, vocals: voice(120, (b) => b >= 80, hookAt: [to.downbeats[80]]), stems: true),
      style: MixStyle.bold,
      random: math.Random(1),
    );
    expect(plan.kind, isNot(Transition.announce), reason: plan.toString());
  });

  test('the desk\'s echo offers an echo-out; without one there is none', () {
    final with_ = Planner.options(
      from: MixSide(timing: record(), fx: true),
      to: MixSide(timing: record(), fx: true),
      random: math.Random(5),
    );
    expect(with_.any((o) => o.kind == Transition.echoOut), isTrue);
    final without = Planner.options(
      from: MixSide(timing: record()),
      to: MixSide(timing: record()),
      random: math.Random(5),
    );
    expect(without.any((o) => o.kind == Transition.echoOut), isFalse);
  });

  test('two voices at once cost every move, not only the blend', () {
    final quiet = Planner.options(
      from: MixSide(timing: record(), vocals: voice(120, (b) => false)),
      to: MixSide(timing: record(), vocals: voice(120, (b) => false)),
      random: math.Random(6),
    );
    final loud = Planner.options(
      from: MixSide(timing: record(), vocals: voice(120, (b) => true)),
      to: MixSide(timing: record(), vocals: voice(120, (b) => true)),
      style: MixStyle.easy,
      random: math.Random(6),
    );
    MixPlan of(List<MixPlan> l, Transition k) => l.firstWhere((o) => o.kind == k);
    expect(of(loud, Transition.sweep).score, lessThan(of(quiet, Transition.sweep).score));
    expect(of(loud, Transition.sweep).why, contains('two voices'));
  });

  test('keys that clash are mended by a shift where the desk can shift', () {
    // 8A against 4A clashes; a semitone down puts 4A at 9A, a fifth from 8A.
    final from = record(camelot: '8A');
    final to = record(camelot: '4A');
    final options = Planner.options(
      from: MixSide(timing: from, fx: true),
      to: MixSide(timing: to, fx: true),
      random: math.Random(7),
    );
    final mended = options.where((o) => o.shift != 0).toList();
    expect(mended, isNotEmpty, reason: options.toString());
    expect(mended.first.shift, -1);
    expect(mended.first.why, contains('to meet the key'));
    // Without the desk's shift, no such offer.
    final plain = Planner.options(
      from: MixSide(timing: from),
      to: MixSide(timing: to),
      random: math.Random(7),
    );
    expect(plain.every((o) => o.shift == 0), isTrue);
  });

  test('a breakdown ahead in the old record becomes the transition into a drop', () {
    final from = record();
    final withBreak = TrackTiming(
      durationMs: from.durationMs,
      bpm: from.bpm,
      beats: from.beats,
      downbeats: from.downbeats,
      camelot: '8A',
      keyConfidence: 0.8,
      energy: from.energy,
      cues: from.cues,
      structure: TrackStructure(sections: [
        TrackSection(label: 'chorus', startBar: 0, endBar: 64, startMs: from.downbeats[0],
            endMs: from.downbeats[64], drums: true, vocals: false, energyDb: -10),
        TrackSection(label: 'breakdown', startBar: 64, endBar: 80, startMs: from.downbeats[64],
            endMs: from.downbeats[80], drums: false, vocals: false, energyDb: -20),
        TrackSection(label: 'drop', startBar: 80, endBar: 120, startMs: from.downbeats[80],
            endMs: from.downbeats[119], drums: true, vocals: false, energyDb: -9),
      ]),
    );
    final to = record(drops: const [48]);
    final options = Planner.options(
      from: MixSide(timing: withBreak, position: Duration(milliseconds: from.downbeats[20])),
      to: MixSide(timing: to),
      style: MixStyle.bold,
      random: math.Random(8),
    );
    final swap = options.firstWhere((o) => o.kind == Transition.breakSwap);
    expect(swap.bars, 16);
    expect(swap.outAt, Duration(milliseconds: from.downbeats[64]), reason: 'out where the breakdown starts');
    expect(swap.inAt, Duration(milliseconds: to.downbeats[48 - 16]), reason: 'the drop lands on the last beat');
  });

  test('the safe dial keeps the wild moves down', () {
    final to = record(drops: const [48]);
    for (var seed = 0; seed < 12; seed++) {
      final plan = Planner.plan(
        from: MixSide(timing: record(), fx: true),
        to: MixSide(timing: to, fx: true),
        axes: const StyleAxes(length: 0.6, risk: 0.0, vocals: 0.0),
        random: math.Random(seed),
      );
      expect(plan.kind, isNot(anyOf(Transition.loopBuild, Transition.echoOut, Transition.dropSwap)),
          reason: plan.toString());
    }
  });
}
