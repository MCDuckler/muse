// Which record stands where while the stage is moving.
//
// Every way this animation "broke randomly" was a mistake in this bookkeeping rather
// than in the drawing: a skip measured against where the records were half a second
// ago, and a shelf that snapped because the answer was no longer one of the three
// places on it.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/api/models.dart';
import 'package:muse/src/ui/record_stage.dart';

Track song(int id) =>
    Track(id: id, title: 'Song $id', artists: const ['A'], state: 'ready',
        source: 'youtube', displayTitle: 'Song $id');

void main() {
  spacing();
  test('a skip to the next record is a step along the shelf', () {
    final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
    expect(shelf.goTo(song(3), previous: song(2), next: song(4)),
        ShelfMove.forward);
    expect(shelf.heading, 1);
    expect(shelf.incoming?.id, 4, reason: 'waiting off-stage on the right');
    // Nothing has moved yet: the journey is what moves it.
    expect(shelf.middle.id, 2);
  });

  test('a skip back is the same step the other way', () {
    final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
    expect(shelf.goTo(song(1), previous: song(0), next: song(2)), ShelfMove.back);
    expect(shelf.heading, -1);
    expect(shelf.incoming?.id, 0);
  });

  test('arriving makes the destination the truth', () {
    final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
    shelf.goTo(song(3), previous: song(2), next: song(4));
    shelf.arrive(previous: song(2), track: song(3), next: song(4));
    expect([shelf.left?.id, shelf.middle.id, shelf.right?.id], [2, 3, 4]);
    expect(shelf.travelling, isFalse);
    expect(shelf.incoming, isNull);
  });

  test('skipping again mid-journey is another step, not a snap', () {
    // The bug: the second skip was compared against records that had already left,
    // fell through to "somewhere else entirely", and the whole shelf jumped.
    final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
    shelf.goTo(song(3), previous: song(2), next: song(4));

    expect(shelf.goTo(song(4), previous: song(3), next: song(5)),
        ShelfMove.forward);
    expect(shelf.middle.id, 3, reason: 'the first journey landed where it was going');
    expect(shelf.left?.id, 2);
    expect(shelf.incoming?.id, 5);
  });

  test('skipping back mid-journey settles the same way', () {
    final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
    shelf.goTo(song(1), previous: song(0), next: song(2));      // heading back
    expect(shelf.goTo(song(0), previous: null, next: song(1)), ShelfMove.back);
    expect(shelf.middle.id, 1);
    expect(shelf.right?.id, 2);
  });

  test('turning round mid-journey undoes it rather than finishing it', () {
    // Skip forward and straight back again. Finishing the journey to a record nobody
    // is going to any more, and then snapping back, is the version that broke.
    final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
    shelf.goTo(song(3), previous: song(2), next: song(4));      // forward, in flight
    expect(shelf.goTo(song(2), previous: song(1), next: song(3)),
        ShelfMove.abandon);
    expect(shelf.middle.id, 2, reason: 'nothing moved after all');
    expect(shelf.travelling, isTrue, reason: 'until the sleeves are back');

    shelf.abandon(previous: song(1), next: song(3));
    expect([shelf.left?.id, shelf.middle.id, shelf.right?.id], [1, 2, 3]);
    expect(shelf.incoming, isNull);
  });

  test('somewhere else entirely restocks rather than travelling', () {
    final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
    expect(shelf.goTo(song(90), previous: song(89), next: song(91)),
        ShelfMove.restock);
    expect([shelf.left?.id, shelf.middle.id, shelf.right?.id], [89, 90, 91]);
    expect(shelf.travelling, isFalse);
  });

  test('the queue being edited changes the company, not the record', () {
    final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
    expect(shelf.goTo(song(2), previous: song(7), next: song(8)), ShelfMove.none);
    expect([shelf.left?.id, shelf.middle.id, shelf.right?.id], [7, 2, 8]);
  });

  test('an edit once the sleeves are at rest changes the company', () {
    final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
    shelf.goTo(song(3), previous: song(2), next: song(4));
    shelf.arrive(previous: song(2), track: song(3), next: song(4));
    expect(shelf.goTo(song(3), previous: song(2), next: song(9)), ShelfMove.none);
    expect(shelf.right?.id, 9);
  });

  group('dragged by hand', () {
    test('a drag starts the same journey a skip would', () {
      final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
      expect(shelf.begin(1, before: song(0), after: song(4)), isTrue);
      expect(shelf.heading, 1);
      expect(shelf.incoming?.id, 4, reason: 'two along, waiting off-stage');
      expect(shelf.middle.id, 2, reason: 'the finger has not taken it anywhere yet');
    });

    test('a drag towards nothing does not start one', () {
      final shelf = Shelf(left: song(1), middle: song(2));
      expect(shelf.begin(1, after: null), isFalse);
      expect(shelf.travelling, isFalse);
    });

    test('letting go past the point of no return is not a second journey', () {
      // The hand starts the journey; the player is only told afterwards, and arrives
      // to find the sleeves already most of the way there. Treating that as a fresh
      // skip restarted the movement from nothing, halfway through it.
      final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
      shelf.begin(1, before: song(0), after: song(4));
      expect(shelf.goTo(song(3), previous: song(2), next: song(4)),
          ShelfMove.resume);
      expect(shelf.heading, 1, reason: 'the same journey, still running');
      expect(shelf.middle.id, 2);
      expect(shelf.incoming?.id, 4);
    });

    test('a drag taken back leaves the shelf where it was', () {
      final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
      shelf.begin(1, after: song(4));
      shelf.abandon(previous: song(1), next: song(3));
      expect([shelf.left?.id, shelf.middle.id, shelf.right?.id], [1, 2, 3]);
      expect(shelf.travelling, isFalse);
    });

    test('changing direction mid-drag swaps which journey is being scrubbed', () {
      final shelf = Shelf(left: song(1), middle: song(2), right: song(3));
      shelf.begin(1, before: song(0), after: song(4));
      shelf.abandon(previous: song(1), next: song(3));
      expect(shelf.begin(-1, before: song(0), after: song(4)), isTrue);
      expect(shelf.heading, -1);
      expect(shelf.incoming?.id, 0);
      expect(shelf.middle.id, 2);
    });
  });

  test('a shelf with nothing beside it still moves when it can', () {
    final shelf = Shelf(middle: song(2), right: song(3));
    expect(shelf.goTo(song(3), previous: song(2), next: null), ShelfMove.forward);
    shelf.settle();
    expect([shelf.left?.id, shelf.middle.id, shelf.right?.id], [2, 3, null]);
  });
}

// How far apart the records stand, when the record has been made bigger or smaller.
void spacing() {
  test('the neighbours move in when the record is made smaller', () {
    // A full-size record on a 360 stage, and the same shelf at half that.
    const stage = 360.0;
    final big = Shelf.along(stage * 1.0, stage, 1);
    final small = Shelf.along(stage * 0.5, stage, 1);

    expect(small, lessThan(big),
        reason: 'shrinking the cover used to leave the neighbours where they were, '
            'so the shelf grew a gap either side of it');
    expect(small / big, lessThan(0.5),
        reason: 'it halves with the record and then some: a big cover pushes its '
            'neighbours further out of its way than a small one does');
  });

  test('the shelf is symmetrical and the middle is the middle', () {
    expect(Shelf.along(300, 360, 0), 0);
    expect(Shelf.along(300, 360, -1), -Shelf.along(300, 360, 1));
    expect(Shelf.along(300, 360, -2), -Shelf.along(300, 360, 2));
  });

  test('the steps get shorter towards the edges, whatever the size', () {
    for (final jacket in [180.0, 300.0, 360.0]) {
      final first = Shelf.along(jacket, 360, 1);
      final second = Shelf.along(jacket, 360, 2) - first;
      expect(second, lessThan(first),
          reason: 'the shelf is deeper at the edges, at every size');
    }
  });
}
