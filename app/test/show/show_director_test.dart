// The director: scenes turned off (their card at 0) are stepped past and never
// reached for, though chosen by name one still goes on; the combinations drawn by
// weight, the background held a while.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_combos.dart';
import 'package:muse/src/state/show/show_director.dart';
import 'package:muse/src/state/show/show_engine.dart';
import 'package:muse/src/state/show/show_events.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_state.dart';
import 'package:muse/src/ui/show/scene.dart';

void main() {
  final st = ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A', section: 'drop', energy: 0.8, level: 1), b: const ShowDeck(name: 'B'));
  ShowDirector make() => ShowDirector(scenes: const [
        SceneMeta(id: 'one', priority: 3),
        SceneMeta(id: 'two'),
        SceneMeta(id: 'three'),
      ]);

  test('the arrows step past a scene that is off', () {
    final d = make()..rules = const [ComboRule(scenes: {'two'}, weight: 0)];
    d.choose('one');
    d.next();
    expect(d.scene, 'three');
    d.next();
    expect(d.scene, 'one');
    d.next(by: -1);
    expect(d.scene, 'three');
  });

  test('the director never reaches for one, however well it fits', () {
    final d = make()..rules = const [ComboRule(scenes: {'one'}, weight: 0)];
    expect(d.fitting(st).map((s) => s.id), isNot(contains('one')));
    d.direct(st, const []);
    expect(d.scene, isNot('one'));
  });

  test('but by name it goes on', () {
    final d = make()..rules = const [ComboRule(scenes: {'one'}, weight: 0)];
    d.choose('one');
    expect(d.scene, 'one');
  });

  test('one switched off while it is on goes at once (chosen by hand, at the section turning)', () {
    final d = make();
    d.direct(st, const []);
    expect(d.scene, 'one');
    d.rules = const [ComboRule(scenes: {'one'}, weight: 0)];
    // No beat, no phrase, no section: it goes all the same.
    d.direct(st, const []);
    expect(d.scene, isNot('one'));
    d.choose('one');
    d.direct(st, const []);
    expect(d.scene, 'one', reason: 'the hands\' choice holds');
    d.locked = true;
    d.direct(st, const []);
    expect(d.scene, 'one');
  });

  test('every one off is none off: the stage is never empty', () {
    final d = make()..rules = const [ComboRule(scenes: {'one'}, weight: 0), ComboRule(scenes: {'two'}, weight: 0), ComboRule(scenes: {'three'}, weight: 0)];
    expect(d.on.length, 3);
    d.direct(st, const []);
    expect(d.scene, isNotNull);
  });

  test('what has been on a lot scores less, another family a little more', () {
    final d = make()..families = {'one': 'geometric', 'two': 'figurative', 'three': 'geometric'};
    d.choose('one');
    // Twenty minutes on 'one' (a second a frame): its lead of 3 points is gone.
    final frame = ShowState(now: DateTime(2026), dt: 1, a: const ShowDeck(name: 'A', section: 'drop', energy: 0.8, level: 1), b: const ShowDeck(name: 'B'));
    for (var i = 0; i < 1200; i++) {
      d.direct(frame, const []);
    }
    expect(d.fatigue['one'], greaterThan(600));
    final order = d.fitting(frame).map((s) => s.id).toList();
    expect(order.first, isNot('one'));
    // The other family first.
    expect(order.first, 'two');
  });

  test('the bias moves the energy a scene is matched against', () {
    final calmScene = const SceneMeta(id: 'calm', energy: (0.0, 0.4));
    final busyScene = const SceneMeta(id: 'busy', energy: (0.6, 1.0));
    final d = ShowDirector(scenes: [calmScene, busyScene]);
    final mid = ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A', energy: 0.5, level: 1), b: const ShowDeck(name: 'B'));
    d.bias = -1;
    expect(d.fitting(mid).first.id, 'calm');
    d.bias = 1;
    expect(d.fitting(mid).first.id, 'busy');
  });

  test('a combination by weight for the scene on, its background held for phrases', () {
    final d = make()
      ..kinds = const {'one': Figure.kinetic, 'two': Figure.kinetic, 'three': Figure.kinetic}
      ..rules = const [ComboRule(grounds: {'black'}, weight: 0), ComboRule(mixes: {Mix.add}, weight: 0)]
      ..grounds = () => const {'black', 'milk', 'wash'};
    final frame = ShowState(now: DateTime(2026), dt: 0.5, a: const ShowDeck(name: 'A', energy: 0.5, level: 1), b: const ShowDeck(name: 'B'));
    d
      ..choose('one')
      ..locked = true;
    d.direct(frame, const []);
    d.locked = false;
    final first = d.combo!;
    expect(first.scene, 'one');
    expect(['milk', 'wash'], contains(first.ground), reason: 'black is off, the camera is not here');
    expect(first.mix, isNot(Mix.add));
    // Bars go by, phrases turn: within the hold the background stays.
    final bar = ShowEvent(ShowEventKind.bar, DateTime(2026), data: const {'master': true});
    final phrase = ShowEvent(ShowEventKind.phrase, DateTime(2026), data: const {'master': true});
    d.locked = true; // the scene; the combination still turns
    for (var i = 0; i < 15; i++) {
      d.direct(frame, [bar, if (i % 8 == 7) phrase]);
      expect(d.combo!.ground, first.ground);
    }
    d.locked = false;
    // Over many phrases past the hold, the other background comes round.
    var changed = false;
    for (var i = 0; i < 2000 && !changed; i++) {
      d.direct(frame, [bar, if (i % 8 == 7) phrase]);
      changed = d.combo!.ground != first.ground;
    }
    expect(changed, isTrue);
    // A background held by the hands: the only one.
    d.heldGround = 'white';
    d.direct(frame, const []);
    expect(d.combo!.ground, 'white');
  });

  test('the hands play one combination: on as it is, held', () {
    final d = make()..kinds = const {'one': Figure.kinetic, 'two': Figure.dancers, 'three': Figure.kinetic};
    d.direct(st, const []);
    const c = Combo(ground: 'white', scene: 'two', style: 'plain', mask: Mask.inverted, mix: Mix.contrast);
    d.play(c);
    expect(d.scene, 'two');
    expect(d.combo, c);
    expect(d.locked, isTrue);
    final phrase = ShowEvent(ShowEventKind.phrase, DateTime(2026), data: const {'master': true});
    for (var i = 0; i < 200; i++) {
      d.direct(st, [phrase]);
    }
    expect(d.combo, c);
  });

  test('a scene whose combinations are all off is not reached for', () {
    final d = make()
      ..kinds = const {'one': Figure.kinetic, 'two': Figure.kinetic, 'three': Figure.kinetic}
      ..rules = const [ComboRule(scenes: {'one'}, grounds: {'milk'}, weight: 0), ComboRule(scenes: {'one'}, grounds: {'wash'}, weight: 0)]
      ..grounds = () => const {'milk', 'wash'};
    expect(d.leans['one'], 0);
    expect(d.on.map((s) => s.id), ['two', 'three']);
  });

  test('a launch landing on the bar a section turns on is kept for that section', () {
    final d = make();
    final bar = ShowEvent(ShowEventKind.bar, DateTime(2026), data: const {'master': true});
    final section = ShowEvent(ShowEventKind.section, DateTime(2026), data: const {'master': true});
    d.direct(st, const []);
    d.choose('two');
    // The section is said a frame after the bar the launch landed on.
    d.direct(st, [bar]);
    d.direct(ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A', section: 'chorus', energy: 0.8, level: 1), b: const ShowDeck(name: 'B')), [section]);
    expect(d.scene, 'two', reason: 'the hands\' choice survives the turn it landed on');
  });

  test('every family of the shipped scenes comes on over a long set, the figures too', () {
    // The scene files as the app reads them (the needs left out: no camera, MilkDrop
    // or lyrics here).
    final files = Directory('assets/show/scenes').listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
    final book = SceneBook.fromStrings([for (final f in files) f.readAsStringSync()]);
    final d = ShowDirector(scenes: book.metas, seed: 3)
      ..families = {for (final l in book.looks.values) l.id: ShowEngine.familyOf(l.rig.figure.kind, l.rig.ground.kind)};
    const form = [('intro', 0.3), ('verse', 0.5), ('build', 0.7), ('drop', 0.9), ('chorus', 0.8), ('breakdown', 0.35)];
    const barSeconds = 240 / 128;
    final seconds = <String, double>{};
    var t = DateTime(2026);
    String? was;
    for (var b = 0; b < 1200; b++) {
      final (label, energy) = form[(b ~/ 32) % form.length];
      t = t.add(const Duration(milliseconds: 1875));
      final frame = ShowState(now: t, dt: barSeconds, a: ShowDeck(name: 'A', section: label, energy: energy, level: 1, playing: true), b: const ShowDeck(name: 'B'));
      d.direct(frame, [
        ShowEvent(ShowEventKind.bar, t, data: const {'master': true}),
        if (b % 8 == 0) ShowEvent(ShowEventKind.phrase, t, data: const {'master': true}),
        if (label != was) ShowEvent(ShowEventKind.section, t, data: const {'master': true}),
      ]);
      was = label;
      final fam = d.families[d.scene] ?? '?';
      seconds[fam] = (seconds[fam] ?? 0) + barSeconds;
    }
    final total = seconds.values.fold<double>(0, (a, b) => a + b);
    for (final fam in ['geometric', 'figurative', 'organic', 'media']) {
      expect((seconds[fam] ?? 0) / total, greaterThan(0.08), reason: '$fam: ${seconds.map((k, v) => MapEntry(k, (v / total * 100).round()))} %');
    }
  });
}
