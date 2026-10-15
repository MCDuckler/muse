// Scenes turned off in the show's menu: the arrows step past them and the director
// never reaches for one; chosen by name, one still goes on.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/show/show_director.dart';
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
}
