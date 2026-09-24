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
}
