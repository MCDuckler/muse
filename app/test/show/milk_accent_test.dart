import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/milk_accent.dart';
import 'package:muse/src/state/show/show_state.dart';

// A deck [beats] in, in [section], as loud as [energy].
ShowDeck _at(double beats, String section, {double energy = 0.9, double buildK = 0, double? dropAway}) {
  final i = beats.floor();
  return ShowDeck(
    name: 'A',
    playing: true,
    trackId: 7,
    bpm: 128,
    section: section,
    energy: energy,
    level: 1,
    buildK: buildK,
    beatIndex: i,
    beatPhase: beats - i,
    beatInBar: i % 4,
    barIndex: i ~/ 4,
    dropBeatsAway: dropAway,
  );
}

/// [a] played from [from] to [to] beats at 60 frames a second, 128 a minute.
List<Map<String, double>> _play(MilkAccent a, double from, double to, String section, {double? react, double energy = 0.9}) {
  const dt = 1 / 60, perFrame = 128 / 60 * dt;
  return [for (var b = from; b < to; b += perFrame) a.frame(_at(b, section, energy: energy), dt, react: react, salt: 7)];
}

double _most(List<Map<String, double>> fx, String k) => fx.map((x) => x[k]!.abs()).fold(0.0, (a, b) => a > b ? a : b);

void main() {
  test('a quiet part leaves the preset as it is', () {
    final fx = _play(MilkAccent(), 0, 32, 'intro', energy: 0.2);
    for (final k in MilkAccent.none.keys) {
      expect(_most(fx.skip(60).toList(), k), lessThan(0.01), reason: k);
    }
  });

  test('a drop moves it on the beat', () {
    final a = MilkAccent();
    final fx = _play(a, 0, 64, 'drop');
    expect(_most(fx.skip(120).toList(), 'wo_fx_amp'), greaterThan(0.5));
    // What a frame adds swings: on its landing, then let go of.
    final amps = fx.skip(120).map((x) => x['wo_fx_amp']!).toList();
    final lo = amps.reduce((a, b) => a < b ? a : b), hi = amps.reduce((a, b) => a > b ? a : b);
    expect(hi - lo, greaterThan(0.4));
  });

  test('a preset that moves by itself gets less, the most reactive none to speak of', () {
    final deaf = _most(_play(MilkAccent(), 0, 32, 'drop', react: 0).skip(120).toList(), 'wo_fx_amp');
    final lively = _most(_play(MilkAccent(), 0, 32, 'drop', react: 1).skip(120).toList(), 'wo_fx_amp');
    expect(lively, lessThan(deaf * 0.25));
  });

  test('the phrases deal different landings and moves over a record', () {
    final a = MilkAccent();
    final lands = <MilkLand>{}, moves = <MilkMove>{};
    for (var phrase = 0; phrase < 24; phrase++) {
      a.frame(_at(phrase * 16.0 + 0.5, phrase.isEven ? 'drop' : 'chorus'), 1 / 60, salt: 7);
      lands.add(a.land);
      moves.addAll(a.moves);
    }
    expect(lands.length, greaterThanOrEqualTo(3));
    expect(moves.length, greaterThanOrEqualTo(4));
  });

  test('a build pushes in, and the drop bursts', () {
    final a = MilkAccent();
    const dt = 1 / 60, perFrame = 128 / 60 * dt;
    double zoomAt(double b, ShowDeck d) => a.frame(d, dt, react: 0, salt: 7)['wo_fx_zoom']!;
    var z = 0.0;
    for (var b = 0.0; b < 32; b += perFrame) {
      z = zoomAt(b, _at(b, 'build', energy: 0.6, buildK: b / 32, dropAway: 32 - b));
    }
    expect(z, greaterThan(0.01));
    var burst = 0.0;
    for (var b = 32.0; b < 33; b += perFrame) {
      burst = zoomAt(b, _at(b, 'drop', dropAway: 32 - b));
    }
    expect(burst, greaterThan(0.03));
  });
}
