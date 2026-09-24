// Which record follows which, and the order of a set: the key as DJs move round the
// wheel, the tempo as far as the automix pulls, the loudness against the arc, and
// never the same artist twice running — and a beam search that follows an arc where
// the best next record, one at a time, would not.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/state/booth/set_planner.dart';

TrackTiming timing({double bpm = 128, String? camelot, double conf = 0.6, double? lufs}) => TrackTiming(
      durationMs: 240000,
      bpm: bpm,
      beats: [for (var i = 0; i < 400; i++) (i * 60000 / bpm).round()],
      camelot: camelot,
      keyConfidence: conf,
      structure: lufs == null ? null : TrackStructure(lufs: lufs),
    );

Track song(int id, {String? title, List<String> artists = const ['Someone'], double? lufs}) =>
    Track.fromJson({
      'id': id,
      'title': title ?? 'Song $id',
      'artists': artists,
      'duration_ms': 240000,
      'state': 'ready',
      'stream_url': '/tracks/$id/stream',
      'source': 'youtube',
      'loudness_lufs': lufs,
    });

void main() {
  group('the key move', () {
    test('round the wheel as a DJ reads it', () {
      final a = timing(camelot: '8A');
      expect(SetPlanner.keyMove(a, timing(camelot: '8A')).score, 1.0);
      expect(SetPlanner.keyMove(a, timing(camelot: '8B')).score, closeTo(0.9, 0.001), reason: 'relative');
      expect(SetPlanner.keyMove(a, timing(camelot: '9A')).score, closeTo(0.85, 0.001), reason: 'a fifth');
      expect(SetPlanner.keyMove(a, timing(camelot: '7A')).score, closeTo(0.85, 0.001));
      final tone = SetPlanner.keyMove(a, timing(camelot: '10A'));
      expect(tone.boost, isTrue, reason: 'a tone up is a boost');
      final semi = SetPlanner.keyMove(a, timing(camelot: '3A'));
      expect(semi.boost, isTrue, reason: '+7 is a semitone up');
      final clash = SetPlanner.keyMove(a, timing(camelot: '2B'));
      expect(clash.clash, isTrue);
      expect(clash.score, lessThan(0.3));
    });

    test('a guess at a key says nothing', () {
      final a = timing(camelot: '8A', conf: 0.05), b = timing(camelot: '2B', conf: 0.9);
      final m = SetPlanner.keyMove(a, b);
      expect(m.score, 0.5);
      expect(m.clash, isFalse);
      expect(SetPlanner.keysClash(timing(camelot: '8A'), timing(camelot: '2B')), isTrue);
    });
  });

  group('the fit', () {
    test('the same artist again, and the same song in another edit, are marked down', () {
      final a = timing(camelot: '8A'), b = timing(camelot: '8A');
      final plain = SetPlanner.fit(a, b, ta: song(1, artists: ['Ann']), tb: song(2, artists: ['Bob']));
      final again = SetPlanner.fit(a, b, ta: song(1, artists: ['Ann']), tb: song(2, artists: ['ann']));
      expect(again.score, lessThan(plain.score - 0.2));
      expect(again.why, contains('same artist'));
      final edit = SetPlanner.fit(a, b,
          ta: song(1, title: 'Blue (Da Ba Dee)'), tb: song(2, title: 'blue (da ba dee) [Radio Edit]'));
      expect(edit.why, contains('same song'));
    });

    test('loudness follows the step the arc wants', () {
      final a = timing(lufs: -14), louder = timing(lufs: -10), same = timing(lufs: -14);
      final up = SetPlanner.fit(a, louder, wantedStep: 0.28);
      final level = SetPlanner.fit(a, same, wantedStep: 0.28);
      expect(up.terms['energy']!, greaterThan(level.terms['energy']!), reason: 'wanted up: louder fits');
      expect(SetPlanner.fit(a, same).terms['energy']!, greaterThan(SetPlanner.fit(a, louder).terms['energy']!),
          reason: 'wanted level: the same fits');
      expect(up.why, contains('louder'));
    });

    test('says why in a few words', () {
      final f = SetPlanner.fit(timing(bpm: 128, camelot: '8A'), timing(bpm: 130, camelot: '9A'));
      expect(f.why, allOf(contains('faster'), contains('a fifth apart (8A→9A)')));
    });
  });

  group('the order', () {
    TrackTiming? Function(int) known(Map<int, TrackTiming> m) => (id) => m[id];

    test('follows the arc rather than the best next record', () {
      // On now: a soft record. Two loud and two soft to come. Greedy takes a soft one
      // next (as loud); a build wants the set to climb, so the soft ones go first
      // and then the loud — but not soft, loud, soft, loud.
      final on = song(0, lufs: -16);
      final rest = [song(1, lufs: -8), song(2, lufs: -16), song(3, lufs: -8), song(4, lufs: -15)];
      final t = {for (final s in [on, ...rest]) s.id: timing(camelot: '8A')};
      final build = SetPlanner.order(rest, from: on, timingOf: known(t), arc: EnergyArc.build);
      final loud = [for (final s in build) s.id == 1 || s.id == 3];
      expect(loud.sublist(2), [true, true], reason: 'the loud ones last: ${build.map((s) => s.id)}');
      final cool = SetPlanner.order(rest, from: song(0, lufs: -8), timingOf: known(t), arc: EnergyArc.coolDown);
      expect([for (final s in cool) s.id == 1 || s.id == 3].sublist(0, 2), [true, true],
          reason: 'cooling down: the loud ones first');
    });

    test('a locked record stays where it is', () {
      final on = song(0, lufs: -16);
      final rest = [song(1, lufs: -8), song(2, lufs: -16), song(3, lufs: -8)];
      final t = {for (final s in [on, ...rest]) s.id: timing(camelot: '8A')};
      final got = SetPlanner.order(rest, from: on, timingOf: known(t), arc: EnergyArc.build, locked: {1});
      expect(got.first.id, 1, reason: 'pinned first, loud or not');
    });

    test('the same artist is not put twice running when another will do', () {
      final on = song(0, artists: ['Ann']);
      final rest = [song(1, artists: ['Ann']), song(2, artists: ['Bob'])];
      final t = {for (final s in [on, ...rest]) s.id: timing(camelot: '8A')};
      expect(SetPlanner.order(rest, from: on, timingOf: known(t)).first.id, 2);
    });

    test('records nothing is known about keep their place', () {
      final rest = [song(1), song(2), song(3)];
      expect(SetPlanner.order(rest, from: song(0), timingOf: (_) => null).map((s) => s.id), [1, 2, 3]);
    });
  });
}
