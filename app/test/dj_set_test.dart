// A set as the booth plans it: its shape's curve and tempo path, the rest of a
// shape part-way through, and what is kept between sessions.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/dj_set.dart';
import 'package:muse/src/state/booth/set_planner.dart';

Track song(int id, {int ms = 240000}) => Track.fromJson({
      'id': id,
      'title': 'Song $id',
      'artists': ['Someone'],
      'duration_ms': ms,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
    });

void main() {
  test('a curve is read between its points, with the room\'s word on top', () {
    const s = SetShape(preset: EnergyPreset.build);
    expect(s.energyAt(0), closeTo(0.2, 1e-9));
    expect(s.energyAt(1), closeTo(0.95, 1e-9));
    expect(s.energyAt(0.5), closeTo(0.575, 1e-9));
    expect(s.copyWith(offset: 0.1).energyAt(0), closeTo(0.3, 1e-9));
    expect(s.copyWith(offset: 0.5).energyAt(1), 1.0, reason: 'never past the loudest');
    const peak = SetShape(preset: EnergyPreset.peakLate);
    expect(peak.energyAt(0.75), closeTo(0.95, 1e-9));
    expect(peak.energyAt(0.9), lessThan(0.95));
  });

  test('a tempo path moves evenly in ratio', () {
    const s = SetShape(tempo: (120, 135));
    expect(s.tempoAt(0), 120);
    expect(s.tempoAt(1), closeTo(135, 1e-9));
    expect(s.tempoAt(0.5), closeTo(120 * 1.0606601717798212, 1e-6));
    expect(const SetShape().tempoAt(0.5), isNull);
  });

  test('the rest of a shape carries on where the set had got to', () {
    const s = SetShape(preset: EnergyPreset.peakLate, tempo: (122, 134), minutes: 60);
    final rest = s.from(0.5);
    expect(rest.energyAt(0), closeTo(s.energyAt(0.5), 1e-9), reason: 'it starts where the set is');
    expect(rest.energyAt(0.5), closeTo(s.energyAt(0.75), 1e-9), reason: 'the peak is still to come');
    expect(rest.energyAt(1), closeTo(s.energyAt(1), 1e-9));
    expect(rest.tempoAt(0), closeTo(s.tempoAt(0.5)!, 1e-9));
    expect(rest.tempoAt(1), closeTo(134, 1e-9));
    expect(rest.minutes, closeTo(30, 1e-9));
    expect(s.from(0), same(s));
  });

  test('a shape and a source go to the house as it reads them', () {
    const src = SetSource(library: true, playlists: [(id: 3, name: 'Acid'), (id: 9, name: 'Warm')]);
    expect(src.toJson(), {'library': true, 'playlists': [3, 9]});
    expect(src.label, 'THE LIBRARY + 2 PLAYLISTS');
    expect(const SetSource(playlists: [(id: 3, name: 'Techno · Acid 303')]).label, 'TECHNO · ACID 303');
    final j = const SetShape(tempo: (124, 130), key: 'strict', gap: 4, fresh: 0.8, anchor: 7).toJson();
    expect(j['tempo'], {'from': 124, 'to': 130});
    expect(j['variety'], {'gap': 4, 'smooth': 0.5, 'fresh': 0.8});
    expect(j['anchor'], 7);
    expect(j['key'], 'strict');
    expect(const SetShape(minutes: 45).length, {'minutes': 45});
    expect(const SetShape(tracks: 9).length, {'tracks': 9});
  });

  test('a set is kept between sessions and comes back with its records', () {
    final set = DjSet(
      source: const SetSource(playlists: [(id: 5, name: 'Peak')]),
      shape: const SetShape(preset: EnergyPreset.twoWaves, tempo: (126, 132), minutes: 50),
      slots: [
        SetSlot(track: song(1)),
        SetSlot(track: song(2), pinned: true, fit: 0.9),
        SetSlot(track: song(3)),
      ],
    );
    final kept = set.toKeep();
    final back = DjSet.fromKeep(kept, {1: song(1), 2: song(2), 3: song(3)})!;
    expect(back.tracks.map((t) => t.id), [1, 2, 3]);
    expect(back.slots[1].pinned, isTrue);
    expect(back.source.playlists.single.name, 'Peak');
    expect(back.shape.preset, EnergyPreset.twoWaves);
    expect(back.shape.tempo, (126.0, 132.0));
    expect(back.shape.minutes, 50);
    expect(back.slots[1].at, const Duration(seconds: 210), reason: 'retimed: four minutes less the overlap');
    final drawn = const SetShape().copyWith(preset: EnergyPreset.custom, drawn: [(0, 0.1), (1, 0.9)]);
    expect(SetShape.fromKeep(drawn.toKeep()).points, [(0.0, 0.1), (1.0, 0.9)]);
  });

  test('what the house sends is read', () {
    final slot = SetSlot.fromJson({
      'track': {'id': 4, 'title': 'Four', 'artists': ['X'], 'duration_ms': 1, 'state': 'ready', 'source': 'youtube'},
      'fit': 1.02, 'why': 'the same key', 'energy': 0.7, 'target': 0.72, 'tempo_target': 128.0,
      'bpm': 127.5, 'camelot': '8A', 'parts': true, 'pinned': false, 'at_ms': 90000,
    });
    expect(slot.fit, 1.02);
    expect(slot.at, const Duration(seconds: 90));
    expect(slot.parts, isTrue);
    final stats = PoolStats.fromJson({
      'named': 30, 'ready': 20, 'measured': 18, 'unfetched': 10,
      'bpm': {'from': 60, 'step': 2, 'counts': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 10, 3]},
      'unfetched_ids': [1, 2],
    });
    expect(stats.unfetchedIds, [1, 2]);
    final span = stats.tempoSpan!;
    expect(span.$1, 120);
    expect(span.$2, greaterThanOrEqualTo(124));
    expect(EnergyPreset.coolDown.arc, EnergyArc.coolDown);
  });
}
