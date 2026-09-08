import 'package:flutter_test/flutter_test.dart';

/// Where a track goes back to when a removal is undone.
///
/// Restoring appends to the end and then walks the track home, because the server has
/// no insert-at-position. Putting it back at the end would be a different queue from
/// the one that existed a second ago, which is not what "undo" means.
int? restoreTarget({required int removedFrom, required int lengthAfterAppend}) {
  if (removedFrom >= lengthAfterAppend) return null;   // already in the right place
  return removedFrom;
}

void main() {
  group('undoing a removal', () {
    test('walks the track back to where it was', () {
      // Queue of 4, removed index 1, re-added at the end of the now-3 list -> index 3.
      expect(restoreTarget(removedFrom: 1, lengthAfterAppend: 4), 1);
    });

    test('a track removed from the end needs no move', () {
      expect(restoreTarget(removedFrom: 3, lengthAfterAppend: 4), 3);
    });

    test('a position past the end is left alone rather than guessed at', () {
      // The queue shrank while the snackbar was up; appending is the honest answer.
      expect(restoreTarget(removedFrom: 9, lengthAfterAppend: 4), isNull);
    });

    test('the first position round-trips', () {
      expect(restoreTarget(removedFrom: 0, lengthAfterAppend: 2), 0);
    });
  });
}
