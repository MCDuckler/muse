// Picking several songs out of a list, and what that means when you walk away.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/selection.dart';

void main() {
  late Selection selection;

  setUp(() => selection = Selection());

  test('holding a row starts a selection, tapping adds and removes', () {
    expect(selection.active, isFalse);
    selection.start('queue:1', 10);
    expect(selection.active, isTrue);
    expect(selection.has(10), isTrue);
    expect(selection.count, 1);

    selection.toggle('queue:1', 11);
    expect(selection.ids, [10, 11], reason: 'kept in the order they were picked');

    selection.toggle('queue:1', 10);
    expect(selection.ids, [11]);
  });

  test('taking the last one back ends it, rather than leaving an empty bar', () {
    selection.start('queue:1', 10);
    selection.toggle('queue:1', 10);
    expect(selection.active, isFalse);
    expect(selection.count, 0);
  });

  test('a selection belongs to one list', () {
    selection.start('queue:1', 10);
    selection.toggle('queue:1', 11);
    expect(selection.inside('playlist:2'), isFalse);

    // Starting one somewhere else is a new selection, not an addition to that one.
    selection.start('playlist:2', 20);
    expect(selection.inside('playlist:2'), isTrue);
    expect(selection.has(10), isFalse);
    expect(selection.ids, [20]);
  });

  test('select all, and leaving the list', () {
    selection.selectAll('album:Low', [1, 2, 3]);
    expect(selection.count, 3);

    // Walking away from a different screen must not clear this one.
    selection.leave('queue:1');
    expect(selection.count, 3);

    selection.leave('album:Low');
    expect(selection.active, isFalse);
  });

  test('it tells whoever is watching', () {
    var told = 0;
    selection.addListener(() => told++);
    selection.start('queue:1', 1);
    selection.toggle('queue:1', 2);
    selection.clear();
    expect(told, 3);
  });
}
