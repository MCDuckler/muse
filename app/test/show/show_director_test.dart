// Scenes turned off in the show's menu: the arrows step past them and the director
// never reaches for one; chosen by name, one still goes on.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_director.dart';
import 'package:muse/src/state/show/show_events.dart';
import 'package:muse/src/state/show/show_rig.dart';
import 'package:muse/src/state/show/show_state.dart';

void main() {
  final st = ShowState(now: DateTime(2026), a: const ShowDeck(name: 'A', section: 'drop', energy: 0.8, level: 1), b: const ShowDeck(name: 'B'));
  ShowDirector make() => ShowDirector(scenes: const [
        SceneMeta(id: 'one', priority: 3),
        SceneMeta(id: 'two'),
        SceneMeta(id: 'three'),
      ]);

  test('the arrows step past a scene that is off', () {
    final d = make()..off = {'two'};
    d.choose('one');
    d.next();
    expect(d.scene, 'three');
    d.next();
    expect(d.scene, 'one');
    d.next(by: -1);
    expect(d.scene, 'three');
  });

  test('the director never reaches for one, however well it fits', () {
    final d = make()..off = {'one'};
    expect(d.fitting(st).map((s) => s.id), isNot(contains('one')));
    d.direct(st, const []);
    expect(d.scene, isNot('one'));
  });

  test('but by name it goes on', () {
    final d = make()..off = {'one'};
    d.choose('one');
    expect(d.scene, 'one');
  });

  test('every one off is none off: the stage is never empty', () {
    final d = make()..off = {'one', 'two', 'three'};
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

  test('a ground from the pool, held for phrases', () {
    final d = make()
      ..grounds = () => const [(RigGround.milk, 1), (RigGround(kind: Ground.wash), 1)];
    final frame = ShowState(now: DateTime(2026), dt: 0.5, a: const ShowDeck(name: 'A', energy: 0.5, level: 1), b: const ShowDeck(name: 'B'));
    d.direct(frame, const []);
    expect(d.ground, isNotNull);
    final first = d.ground;
    // Bars go by, phrases turn: within the hold nothing changes.
    final bar = ShowEvent(ShowEventKind.bar, DateTime(2026), data: const {'master': true});
    final phrase = ShowEvent(ShowEventKind.phrase, DateTime(2026), data: const {'master': true});
    for (var i = 0; i < 16; i++) {
      d.direct(frame, [bar, if (i % 8 == 7) phrase]);
      expect(d.ground, first);
    }
    // Over many phrases past the hold, the other ground comes round.
    var changed = false;
    for (var i = 0; i < 2000 && !changed; i++) {
      d.direct(frame, [bar, if (i % 8 == 7) phrase]);
      changed = d.ground != first;
    }
    expect(changed, isTrue);
    // No pool: no ground of the director's.
    d.grounds = () => const [];
    d.direct(frame, const []);
    expect(d.ground, isNull);
  });
}
