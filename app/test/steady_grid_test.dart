// One steady grid through the beats the analysis found.
//
// The tracker places each beat to within a frame and wanders where the music thins:
// one real record's last eighteen beats sat 45 ms late, and a mix held to the beats
// nearby followed them there. A record made on a computer runs to a clock; the grid
// through all of its beats, strays left out, is the clock.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';

TrackTiming grid(
  double ms, {
  int count = 400,
  double from = 500,
  double jitter = 0,
  int seed = 7,
  double? bpm,
  int barStartsOn = 0,
  List<int> Function(List<int>)? edit,
}) {
  final r = math.Random(seed);
  var beats = [
    for (var i = 0; i < count; i++)
      (from + i * ms + (r.nextDouble() * 2 - 1) * jitter).round(),
  ];
  if (edit != null) beats = edit(beats);
  return TrackTiming(
    durationMs: beats.last + 2000,
    bpm: bpm ?? double.parse((60000 / ms).toStringAsFixed(1)),
    beats: beats,
    barStartsOn: barStartsOn,
  );
}

void main() {
  test('frame-by-frame wobble averages away', () {
    final t = grid(60000 / 145.3, jitter: 23);
    expect(t.steady, isNotNull);
    expect(t.gridBpm, closeTo(145.3, 0.02));
    // Anywhere in the record, the grid is where the beats are on average.
    for (final i in [3, 100, 250, 396]) {
      final true_ = 500 + i * 60000 / 145.3;
      final on = t.onGrid(Duration(milliseconds: t.beats[i]));
      expect(on.inMicroseconds / 1000, closeTo(true_, 3), reason: 'beat $i');
    }
  });

  test('a stretch the tracker lost is left out, not followed', () {
    const ms = 412.93;
    // The last eighteen beats 45 ms late, as the analysis had them on a real record.
    final t = grid(ms, edit: (b) => [
          for (var i = 0; i < b.length; i++) i >= b.length - 18 ? b[i] + 45 : b[i],
        ]);
    final s = t.steady!;
    final last = t.beats.length - 5;
    final shouldBe = 500 + last * ms;
    final x = (t.beats[last] - 45 - s.origin) / s.period;
    expect(x - x.round(), closeTo(0, 0.01));
    final at = t.smoothBeatAt(Duration(microseconds: (shouldBe * 1000).round()))!;
    expect(at.phase < 0.01 || at.phase > 0.99, isTrue,
        reason: 'the true beat reads as on the beat, not 45 ms before it');
  });

  test('a beat the tracker missed does not shift every beat after it', () {
    const ms = 500.0;
    final t = grid(ms, edit: (b) => [...b.sublist(0, 200), ...b.sublist(201)]);
    expect(t.gridBpm, closeTo(120, 0.01));
    final late = t.onGrid(Duration(milliseconds: t.beats.last));
    expect(late.inMilliseconds, t.beats.last);
  });

  test('a record whose tempo really changes is not given one grid', () {
    // 120 for half, 126 for the rest: two grids, not one.
    final beats = <int>[];
    var at = 500.0;
    for (var i = 0; i < 400; i++) {
      beats.add(at.round());
      at += i < 200 ? 500 : 60000 / 126;
    }
    final t = TrackTiming(durationMs: at.round() + 1000, bpm: 123, beats: beats);
    expect(t.steady, isNull);
    expect(t.gridBpm, 123, reason: 'the analysis\'s own figure, where there is no one grid');
    expect(t.smoothBeatAt(const Duration(seconds: 50)), isNotNull,
        reason: 'and the beats nearby still give a grid');
  });

  test('a record that drifts slowly is not given one grid either', () {
    // A band: 120 at the start, 121.5 by the end, a little faster every bar.
    final beats = <int>[];
    var at = 500.0;
    for (var i = 0; i < 480; i++) {
      beats.add(at.round());
      at += 60000 / (120 + 1.5 * i / 480);
    }
    final t = TrackTiming(durationMs: at.round() + 1000, bpm: 120.7, beats: beats);
    expect(t.steady, isNull);
  });

  test('a real record: its middle wobbles, its ends wander, and it is one grid', () {
    // Druck Alert's own shape: ±20 ms from beat to beat, the first beats 68 ms late
    // and the last eighteen 45 ms late.
    final t = grid(412.93, count: 412, jitter: 20, edit: (b) => [
          for (var i = 0; i < b.length; i++)
            i < 8 ? b[i] + 68 : i >= b.length - 18 ? b[i] + 45 : b[i],
        ]);
    expect(t.steady, isNotNull);
    expect(t.gridBpm, closeTo(145.30, 0.02));
  });

  test('bars start where the analysis said they do', () {
    final t = grid(450, barStartsOn: 2, jitter: 10);
    final s = t.steady!;
    final n = ((t.beats[2] - s.origin) / s.period).round();
    expect(n, 2);
    final down = t.nextOnGrid(Duration(milliseconds: t.beats[3]), every: 4)!;
    expect((down.inMilliseconds - t.beats[6]).abs(), lessThan(12),
        reason: 'the next downbeat after beat 3 is beat 6');
  });

  test('the next beat on the grid, at or after a moment', () {
    final t = grid(500);
    expect(t.nextOnGrid(const Duration(milliseconds: 500))!.inMilliseconds, 500);
    expect(t.nextOnGrid(const Duration(milliseconds: 501))!.inMilliseconds, 1000);
    expect(t.nextOnGrid(const Duration(milliseconds: 1200), every: 4)!.inMilliseconds, 2500);
  });
}
