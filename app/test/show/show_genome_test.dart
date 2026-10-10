// A record's genome: the same record draws the same numbers every time, a different
// record draws different ones, and the numbers stay within what the stage can use.
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_genome.dart';
import 'package:muse/src/state/show/show_state.dart';

void main() {
  test('the same record is the same genome', () {
    final a = Genome.of(trackId: 42, camelot: '8A', bpm: 128, cover: const Color(0xffd04070));
    final b = Genome.of(trackId: 42, camelot: '8A', bpm: 128, cover: const Color(0xffd04070));
    expect(a.genes, b.genes);
    expect(a.genes.isNotEmpty, isTrue);
  });

  test('another record is another genome', () {
    final a = Genome.of(trackId: 42, camelot: '8A', bpm: 128);
    final b = Genome.of(trackId: 43, camelot: '8A', bpm: 128);
    expect(a.genes, isNot(equals(b.genes)));
    // And a re-tagged record changes, but not everything.
    final c = Genome.of(trackId: 42, camelot: '9A', bpm: 128);
    expect(c.genes, isNot(equals(a.genes)));
  });

  test('the numbers stay in range, over many records', () {
    for (var id = 1; id < 300; id++) {
      final g = Genome.of(trackId: id, camelot: '${1 + id % 12}${id.isEven ? 'A' : 'B'}', bpm: 90.0 + id % 90);
      expect(g['feedback.zoom'], inInclusiveRange(0.98, 1.03));
      expect(g['feedback.fold'], isIn([0.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0]));
      expect(g['feedback.decay'], inInclusiveRange(0.3, 0.75));
      expect(g['fluid.fade'], inInclusiveRange(0.95, 0.985));
      expect(g['veins.look'], inInclusiveRange(5, 14));
      expect(g['scene.tunnel'], greaterThan(0));
    }
  });

  test('it rides in the frame, by name, and comes back from JSON', () {
    final g = Genome.of(trackId: 7, camelot: '5B', bpm: 124);
    final st = ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A'), b: const ShowDeck(name: 'B'), genome: g);
    expect(st['gene.feedback.zoom'], g['feedback.zoom']);
    final back = ShowState.fromJson(st.toJson());
    expect(back.genome.genes, g.genes);
    expect(ShowState.fromJson(st.copyWith(genome: Genome.none).toJson()).genome.isEmpty, isTrue);
  });
}
