// The pads a record comes with: in, drop, breakdown, out — each on its own pad, on
// the four-bar grid, where the Auto DJ itself would go.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/auto_pads.dart';
import 'package:muse/src/state/booth/automix.dart';

const barMs = 2000;

TrackTiming record({
  int bars = 96,
  int mixInBar = 8,
  int mixOutBar = 64,
  List<int> dropBars = const [16],
  List<int>? energy,
  TrackStructure? structure,
}) {
  final downs = [for (var i = 0; i <= bars; i++) i * barMs];
  return TrackTiming(
    durationMs: bars * barMs,
    bpm: 120,
    beats: [for (var i = 0; i < bars * 4; i++) i * barMs ~/ 4],
    downbeats: downs,
    fourBars: [for (var i = 0; i < bars; i += 4) i * barMs],
    energy: energy ?? [for (var i = 0; i < bars; i++) 240],
    drops: [for (final b in dropBars) b * barMs],
    cues: MixCues(firstDownbeatMs: 0, mixInMs: mixInBar * barMs, mixOutMs: mixOutBar * barMs, soundEndMs: bars * barMs),
    structure: structure,
  );
}

void main() {
  int barOf(Duration d) => d.inMilliseconds ~/ barMs;
  Map<int, (int, PadWhy)> pads(TrackTiming t) =>
      {for (final e in AutoPads.of(t).entries) e.key: (barOf(e.value.at), e.value.why)};

  test('in, drop, breakdown and out, each on its own pad', () {
    // Loud, then eight quiet bars from bar 40, loud again from 48.
    final energy = [for (var i = 0; i < 96; i++) i >= 40 && i < 48 ? 40 : 240];
    final t = record(energy: energy, dropBars: [16, 48]);
    expect(pads(t), {
      1: (8, PadWhy.mixIn),
      2: (16, PadWhy.drop),
      3: (40, PadWhy.breakdown),
      4: (barOf(AutoMix.outPoint(t, length: const Duration(milliseconds: 16 * barMs))), PadWhy.mixOut),
    });
  });

  test('an intro that ends on the drop is one pad, the drop', () {
    final p = pads(record(mixInBar: 16, dropBars: [16]));
    expect(p.containsKey(1), isFalse);
    expect(p[2], (16, PadWhy.drop));
  });

  test("the structure's breakdown is the one taken, on a marker", () {
    final t = record(
      structure: TrackStructure(
        barsMs: [for (var i = 0; i < 96; i++) i * barMs],
        mixDb: [for (var i = 0; i < 96; i++) -10.0],
        breakdownsMs: const [33 * barMs],
      ),
    );
    expect(pads(t)[3], (32, PadWhy.breakdown));
  });

  test('no drop, no breakdown: those pads stay empty', () {
    final p = pads(record(dropBars: const []));
    expect(p.keys, containsAll([1, 4]));
    expect(p.containsKey(2), isFalse);
    expect(p.containsKey(3), isFalse);
  });

  test('a record with no grid has no pads', () {
    expect(AutoPads.of(const TrackTiming(durationMs: 1000)), isEmpty);
  });
}
