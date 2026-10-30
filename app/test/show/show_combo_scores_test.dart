// How the combinations look, measured (combo_scores.dart), and the director by it: the
// ugly ones never come by themselves (but let come by the hands); the intensity
// follows the record — spare in an intro, the hardest on the drop; a record leans on
// a look of its own; a section that comes back brings back its combination.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/milk_feed.dart';
import 'package:muse/src/state/show/milk_library.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:muse/src/state/show/combo_scores.dart';
import 'package:muse/src/state/show/show_combos.dart';
import 'package:muse/src/state/show/show_director.dart';
import 'package:muse/src/state/show/show_events.dart';
import 'package:muse/src/state/show/show_plan.dart';
import 'package:muse/src/state/show/show_faves.dart';
import 'package:muse/src/state/show/show_store.dart';
import 'package:muse/src/state/show/show_taste.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_state.dart';

// A table of two backgrounds, two masks, two blends: the figure `one.raw`, its eight
// cells in background × mask × blend order. Quality: on white, normal, unmasked it is
// ugly (1 of 35); the rest fine. Intensity: the black ones calm, the white ones hard.
final _table = jsonEncode({
  'version': 1,
  'grounds': ['black', 'white'],
  'masks': ['none', 'keyhole'],
  'mixes': ['normal', 'add'],
  'figures': {
    'one.raw': {'q': 'zzzz1zzz', 'i': '3333xxxx'},
    'milk.raw': {'q': 'p', 'i': 'k'},
  },
});

ShowState _frame(String? section, {double energy = 0.5, double buildK = 0, int track = 1}) => ShowState(
    now: DateTime(2026),
    dt: 0.5,
    a: ShowDeck(name: 'A', section: section, energy: energy, level: 1, buildK: buildK, playing: true, trackId: track, bpm: 128),
    b: const ShowDeck(name: 'B'));

final _bar = ShowEvent(ShowEventKind.bar, DateTime(2026), data: const {'master': true});
final _phrase = ShowEvent(ShowEventKind.phrase, DateTime(2026), data: const {'master': true});
final _section = ShowEvent(ShowEventKind.section, DateTime(2026), data: const {'master': true});
final _drop = ShowEvent(ShowEventKind.drop, DateTime(2026), data: const {'master': true});

ShowDirector _director(ComboScores s, {int seed = 1}) => ShowDirector(scenes: const [SceneMeta(id: 'one')], seed: seed)
  ..kinds = const {'one': Figure.kinetic}
  ..scores = s
  ..grounds = (() => const {'black', 'white'})
  // One style, no masks but two, no blends but two: the table's eight.
  ..plan = () {
    // Every level at 1, every background taking every mask and blend: these alone.
    var p = const ShowPlan(notWith: {}, levels: {
      PlanAxis.ground: {'white': 1},
      PlanAxis.mask: {'none': 1, 'keyhole': 1},
      PlanAxis.fx: {'none': 1},
    }).withShared(PlanAxis.mask, 'inverted', muted: true).withShared(PlanAxis.mix, 'screen', muted: true).withShared(PlanAxis.mix, 'contrast', muted: true);
    // No effects: the table's eight looks alone.
    for (final f in Fx.values) {
      if (f != Fx.none) p = p.withShared(PlanAxis.fx, f.name, muted: true);
    }
    for (final t in treatmentStyles) {
      p = p.withIn('one', PlanAxis.style, t, muted: true);
    }
    return p;
  }();

void main() {
  final s = ComboScores.parse(_table)!;
  const ugly = Combo(ground: 'white', scene: 'one', style: 'raw');

  test('the table read: a cell by its background, mask and blend; a world by itself', () {
    expect(s.quality(ugly), closeTo(1 / 35, 1e-9));
    expect(s.quality(const Combo(ground: 'white', scene: 'one', style: 'raw', mix: Mix.add)), 1.0);
    expect(s.intensity(const Combo(ground: 'black', scene: 'one', style: 'raw')), closeTo(3 / 35, 1e-9));
    expect(s.intensity(const Combo(ground: 'white', scene: 'one', style: 'raw', mask: Mask.keyhole)), closeTo(33 / 35, 1e-9));
    expect(s.quality(const Combo(ground: ownGround, scene: 'milk', style: 'raw')), closeTo(25 / 35, 1e-9));
    expect(s.quality(const Combo(ground: 'black', scene: 'two', style: 'raw')), isNull, reason: 'never measured');
    expect(ComboScores.lean(null), 1);
    expect(ComboScores.lean(0.1), 0);
    expect(ComboScores.lean(0.9), 1);
  });

  test('the ugly one never comes by itself; named by the hands, it does', () {
    final d = _director(s);
    expect(d.weigh(ugly), 0);
    d.choose('one');
    for (var i = 0; i < 300; i++) {
      d.direct(_frame('verse'), [_bar, if (i % 8 == 7) _phrase, if (i % 32 == 0) _section]);
      expect(d.combo, isNot(ugly));
    }
    d.plan = d.plan.withCell('one', cellOf(ugly), 2).withAllow('one', cellOf(ugly), true);
    // The hands' ×2, however it measured.
    expect(d.weigh(ugly), 2);
  });

  test('the intensity follows the record: calm in the intro, hard on the drop', () {
    expect(ShowDirector.intensityFor(_frame('drop', energy: 0.9).master), greaterThan(0.8));
    expect(ShowDirector.intensityFor(_frame('intro', energy: 0.2).master), lessThan(0.25));
    expect(ShowDirector.intensityFor(_frame('build', buildK: 0.9).master), greaterThan(ShowDirector.intensityFor(_frame('build', buildK: 0.1).master)));
    // The first combination of a record, drawn many times over.
    int hard(String section, double energy) {
      var n = 0;
      for (var i = 0; i < 200; i++) {
        final d = _director(s, seed: i);
        d.direct(_frame(section, energy: energy, track: i), [_bar, _section]);
        if (d.combo!.ground == 'white') n++;
      }
      return n;
    }
    expect(hard('drop', 0.95), greaterThan(170));
    expect(hard('intro', 0.1), lessThan(30));
  });

  test('a record leans on a look of its own, the same every time it plays', () {
    final d = _director(s)..choose('one');
    const c = Combo(ground: 'white', scene: 'one', style: 'raw', mix: Mix.add);
    d.direct(_frame('verse', track: 7), const []);
    final seven = [for (final g in ['black', 'white']) d.affinity(c.copyWith(ground: g))];
    d.direct(_frame('verse', track: 8), const []);
    d.direct(_frame('verse', track: 7), const []);
    expect([for (final g in ['black', 'white']) d.affinity(c.copyWith(ground: g))], seven);
    // Over many records, some lean one way and some the other.
    final leans = <double>{};
    for (var t = 0; t < 40; t++) {
      d.direct(_frame('verse', track: 100 + t), const []);
      leans.add(d.affinity(c));
    }
    expect(leans.length, greaterThan(1));
  });

  test('the chorus comes back with its combination', () {
    final d = _director(s)..choose('one');
    d.direct(_frame('verse'), [_bar, _section]);
    d.direct(_frame('chorus'), [_bar, _section]);
    for (var i = 0; i < 3; i++) {
      d.direct(_frame('chorus'), [_bar]);
    }
    final chorus = d.combo!;
    var back = 0;
    for (var round = 0; round < 20; round++) {
      d.direct(_frame('verse'), [_bar, _section]);
      for (var i = 0; i < 3; i++) {
        d.direct(_frame('verse'), [_bar]);
      }
      d.direct(_frame('chorus'), [_bar, _section]);
      if (d.combo == chorus) back++;
    }
    expect(back, greaterThan(10));
  });

  test('a drop on the same scene turns the combination', () {
    final d = _director(s)..choose('one');
    d.direct(_frame('build', buildK: 0.9), [_bar, _section]);
    d.direct(_frame('build', buildK: 0.9), [_bar]);
    var turned = 0;
    for (var i = 0; i < 40; i++) {
      final was = d.combo;
      d.direct(_frame('drop', energy: 0.95, track: 1), [_bar, _drop]);
      if (d.combo != was) turned++;
      d.direct(_frame('build', buildK: 0.9), [_bar]);
    }
    expect(turned, greaterThan(5));
  });

  test('the hands\' taste: a skip says less, its kin a little less; a starred favourite says more', () {
    const c = Combo(ground: 'milk', scene: 'one', style: 'raw', mix: Mix.add);
    const kin = Combo(ground: 'milk', scene: 'one', style: 'raw', mix: Mix.screen);
    const other = Combo(ground: 'wash', scene: 'one', style: 'raw');
    var skips = ShowTaste.skipped(const {}, c);
    skips = ShowTaste.skipped(skips, c);
    expect(ShowTaste.lean(c, skips, const []), closeTo(1 / 3, 1e-9));
    expect(ShowTaste.lean(kin, skips, const []), closeTo(1 / 1.5, 1e-9));
    expect(ShowTaste.lean(other, skips, const []), 1);
    final fave = ShowFave(id: 'f', at: DateTime(2026), combo: other, stars: 5);
    expect(ShowTaste.lean(other, const {}, [fave]), closeTo(1.75, 1e-9));
    expect(ShowTaste.lean(other.copyWith(ground: 'milk'), const {}, [fave]), closeTo(1.3, 1e-9));
    expect(ShowTaste.lean(other, const {}, [ShowFave(id: 'g', at: DateTime(2026), combo: other, stars: 2)]), 1);
    // Kept in the document, the oldest dropped past the limit.
    final doc = ShowDoc.fromJson(jsonDecode(jsonEncode(ShowDoc(taste: skips).toJson())) as Map<String, dynamic>);
    expect(doc.taste, {c.key: 2.0});
    var many = <String, double>{};
    for (var i = 0; i < ShowTaste.kept + 5; i++) {
      many = ShowTaste.skipped(many, Combo(ground: 'g$i', scene: 'one', style: 'raw'));
    }
    expect(many.length, ShowTaste.kept);
    expect(many.containsKey(const Combo(ground: 'g0', scene: 'one', style: 'raw').key), isFalse);
  });

  test('MilkDrop: near the record\'s intensity, a figure not lost; the favourites more', () {
    SharedPreferences.setMockInitialValues({});
    MilkPreset p(String name) => MilkPreset(path: '/x/$name.milk', name: name, author: 'A', collection: 'shipped');
    final calm = p('calm'), wild = p('wild'), ugly = p('ugly'), glare = p('glare'), mine = p('mine');
    // alone, under a figure, intensity
    final m = MilkScores.parse(jsonEncode({
      'version': 1,
      'presets': {'A - calm': 'zz2', 'A - wild': 'zzy', 'A - ugly': '1z5', 'A - glare': 'z1k'},
    }))!;
    final d = MilkFeed.shared.director
      ..scores = m
      ..target = 0.9
      ..underFigure = false;
    expect(d.weigh(wild), greaterThan(d.weigh(calm) * 10));
    expect(d.weigh(ugly), greaterThan(0), reason: 'how one looks on its own is not weighed');
    expect(d.weigh(glare), greaterThan(0), reason: 'fine on its own');
    d.target = 0.1;
    expect(d.weigh(calm), greaterThan(d.weigh(wild) * 10));
    d.underFigure = true;
    expect(d.weigh(glare), 0, reason: 'a figure is lost in it');
    expect(d.weigh(mine), greaterThan(0), reason: 'never measured: middling');
    final before = d.weigh(calm);
    MilkFeed.shared.library.favourites.add(calm.fullName);
    expect(d.weigh(calm), closeTo(before * 2.5, 1e-9));
    MilkFeed.shared.library.favourites.remove(calm.fullName);
    // Skipped by the hands twice: a third as often.
    MilkFeed.shared.library.skips[calm.fullName] = 2;
    expect(d.weigh(calm), closeTo(before / 3, 1e-9));
    MilkFeed.shared.library.skips.remove(calm.fullName);
    // Loud: of two as intense, the one that moves with the music by itself, more.
    final r = MilkScores.parse(jsonEncode({
      'version': 1,
      'presets': {'A - calm': 'zzyz', 'A - wild': 'zzy0'},
    }))!;
    d
      ..scores = r
      ..target = 0.95
      ..underFigure = false;
    expect(d.weigh(calm), greaterThan(d.weigh(wild) * 3));
    d.target = 0.2;
    expect(d.weigh(calm), closeTo(d.weigh(wild), 1e-9), reason: 'quiet: as they come');
    d.scores = null;
  });

  test('the changes by where the record is: a drop moshed most, the quiet never, dissolved slowly', () {
    expect(ShowDirector.moshChance(0.35, 'intro'), 0);
    expect(ShowDirector.moshChance(0.35, 'breakdown'), 0);
    expect(ShowDirector.moshChance(0.35, 'verse'), 0.35);
    expect(ShowDirector.moshChance(0.35, 'build'), lessThan(0.35));
    expect(ShowDirector.moshChance(0.35, 'chorus'), greaterThan(0.35));
    expect(ShowDirector.moshChance(0.35, 'verse', drop: true), greaterThan(ShowDirector.moshChance(0.35, 'chorus')));
    expect(ShowDirector.moshChance(0, 'drop', drop: true), 0, reason: 'the hands said no moshes');
    expect(ShowDirector.dissolveFor('outro'), 3);
    expect(ShowDirector.dissolveFor('breakdown'), 2);
    expect(ShowDirector.dissolveFor('chorus'), 1);
    // On a drop with moshes on, most drops are moshed into; in an intro none.
    final d = ShowDirector(scenes: const [SceneMeta(id: 'one', sections: ['build', 'intro']), SceneMeta(id: 'two', sections: ['drop'])])..moshShare = 0.35;
    var moshed = 0;
    for (var i = 0; i < 100; i++) {
      d.direct(_frame('build', buildK: 0.9), [_bar, _section]);
      final was = d.moshes;
      d.direct(_frame('drop', energy: 0.95), [_bar, _section, _drop]);
      if (d.moshes > was) moshed++;
    }
    expect(moshed, greaterThan(35));
  });

  test('the shipped table, where there is one, reads', () {
    final f = File(ComboScores.asset);
    if (!f.existsSync()) return;
    final t = ComboScores.parse(f.readAsStringSync());
    expect(t, isNotNull);
    expect(t!.quality(const Combo(ground: 'milk', scene: 'blocks', style: 'raw')), isNotNull);
  });
}
