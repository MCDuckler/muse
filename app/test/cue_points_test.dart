// Where a mix leaves and lands: a hand's cue first, then the structure's own places,
// then the plain analysis — and never in the middle of the payoff.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/automix.dart';

const bpm = 120.0;
const barMs = 2000;

TrackTiming record({
  int bars = 96,
  int mixInBar = 8,
  int mixOutBar = 63,
  List<TrackSection> sections = const [],
  List<CuePoint> outs = const [],
  List<CuePoint> ins = const [],
  List<int>? energy,
  ({int? outMs, int? inMs})? hand,
}) {
  final downs = [for (var i = 0; i <= bars; i++) i * barMs];
  return TrackTiming(
    durationMs: bars * barMs,
    bpm: bpm,
    beats: [for (var i = 0; i < bars * 4; i++) i * barMs ~/ 4],
    downbeats: downs,
    fourBars: [for (var i = 0; i < bars; i += 4) i * barMs],
    energy: energy ?? [for (var i = 0; i < bars; i++) 240],
    cues: MixCues(firstDownbeatMs: 0, mixInMs: mixInBar * barMs, mixOutMs: mixOutBar * barMs, soundEndMs: bars * barMs),
    structure: sections.isEmpty && outs.isEmpty && ins.isEmpty
        ? null
        : TrackStructure(barsMs: downs.sublist(0, bars), mixDb: [for (var i = 0; i < bars; i++) -10.0], sections: sections, outs: outs, ins: ins),
    handCues: hand,
  );
}

TrackSection section(String label, int from, int to) => TrackSection(
    label: label, startBar: from, endBar: to, startMs: from * barMs, endMs: to * barMs, drums: true, vocals: false, energyDb: -10);

void main() {
  const length = Duration(milliseconds: 16 * barMs);
  int barOf(Duration d) => d.inMilliseconds ~/ barMs;

  test('the plain cue is used where nothing better is known', () {
    expect(barOf(AutoMix.outPoint(record(), length: length)), 64, reason: 'on the marker near bar 63');
    expect(barOf(AutoMix.inPoint(record(), bars: 16)), 0, reason: 'sixteen bars before an 8-bar intro ends: the start');
  });

  test("a hand's cue comes first", () {
    final t = record(hand: (outMs: 40 * barMs, inMs: 16 * barMs));
    expect(barOf(AutoMix.outPoint(t, length: length)), 40);
    expect(barOf(AutoMix.inPoint(t, bars: 16)), 16);
    // Off the end: pulled back to where the move still fits.
    final late = record(bars: 64, hand: (outMs: 60 * barMs, inMs: null));
    expect(barOf(AutoMix.outPoint(late, length: length)), lessThanOrEqualTo(48));
  });

  test("the structure's outro beats the plain cue, and an 'after' beats a 'before'", () {
    final t = record(
      mixOutBar: 63,
      outs: const [CuePoint(ms: 48 * barMs, bar: 48, why: 'before its breakdown'), CuePoint(ms: 72 * barMs, bar: 72, why: 'after its chorus')],
    );
    expect(barOf(AutoMix.outPoint(t, length: length)), 72);
    final withOutro = record(outs: const [CuePoint(ms: 72 * barMs, bar: 72, why: 'after its chorus'), CuePoint(ms: 80 * barMs, bar: 80, why: 'its outro')]);
    expect(barOf(AutoMix.outPoint(withOutro, length: length)), 80);
    // One with no room for the move is passed over.
    final tooLate = record(outs: const [CuePoint(ms: 88 * barMs, bar: 88, why: 'its outro'), CuePoint(ms: 64 * barMs, bar: 64, why: 'after its drop')]);
    expect(barOf(AutoMix.outPoint(tooLate, length: length)), 64);
  });

  test('never in the middle of a chorus or a drop', () {
    final t = record(mixOutBar: 60, sections: [section('inst', 0, 56), section('chorus', 56, 72), section('inst', 72, 96)]);
    expect(barOf(AutoMix.outPoint(t, length: length)), 72, reason: 'after the chorus');
    // No room after it: before it.
    final tail = record(bars: 80, mixOutBar: 66, sections: [section('inst', 0, 60), section('drop', 60, 80)]);
    expect(barOf(AutoMix.outPoint(tail, length: length)), 60);
  });

  test("the structure's intro end is what the new record is parked before", () {
    final t = record(mixInBar: 40, ins: const [CuePoint(ms: 16 * barMs, bar: 16, why: 'the intro is over')]);
    expect(barOf(AutoMix.inPoint(t, bars: 8)), 8);
  });

  test('a thin lead-in is seen from the plain energy alone', () {
    final thin = record(mixInBar: 24, energy: [for (var i = 0; i < 96; i++) i < 24 ? 40 : 240]);
    expect(AutoMix.quietBars(thin, Duration.zero, 16), isTrue);
    expect(barOf(AutoMix.inPoint(thin, bars: 16)), greaterThanOrEqualTo(16), reason: 'in later, not into the thin bars');
    expect(AutoMix.quietBars(record(), Duration.zero, 16), isFalse);
  });

  test('the old rules hand out phrase multiples', () {
    final a = record(), b = record();
    final unsynced = TrackTiming(durationMs: 100000, bpm: 170, beats: [for (var i = 0; i < 200; i++) i * 353], downbeats: [for (var i = 0; i < 50; i++) i * 1412]);
    expect(AutoMix.choose(a, unsynced).bars, 4);
    expect(AutoMix.choose(a, b, style: MixStyle.normal).bars, anyOf(8, 16));
  });
}
