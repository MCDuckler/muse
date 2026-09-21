// One record, the whole way.
//
// There used to be two: a sleeve-sized disc rolled out of the side of the cover and
// faded away while a second, bigger one appeared on the deck, and these tests policed
// the handover between them. There is nothing to hand over now. The record starts
// behind its sleeve at the size a record is inside one, and comes up to where it plays
// at the size it plays at — the same object at every moment in between.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/record_stage.dart';

void main() {
  const sleeveAt = 60.0, sleeveSize = 280.0, drop = -20.0, size = 400.0;
  ({double dy, double scale}) at(double t) => Deck.pose(t,
      sleeveAt: sleeveAt, sleeveSize: sleeveSize, drop: drop, size: size);

  test('in its sleeve it is behind the cover, and smaller than it', () {
    final p = at(0);
    expect(p.dy, sleeveAt, reason: 'centred on the cover it is hidden by');
    expect(size * p.scale, lessThan(sleeveSize), reason: 'or its edge would show');
    expect(size * p.scale, greaterThan(sleeveSize * 0.9), reason: 'a record fills its sleeve');
  });

  test('out, it is where it plays and the size it plays at', () {
    final p = at(1);
    expect(p.dy, closeTo(drop, 1e-9));
    expect(p.scale, closeTo(1, 1e-9));
  });

  test('it only ever rises and only ever grows on the way', () {
    var last = at(0);
    for (var i = 1; i <= 50; i++) {
      final now = at(i / 50);
      expect(now.dy, lessThanOrEqualTo(last.dy + 1e-9), reason: 'up is towards the top');
      expect(now.scale, greaterThanOrEqualTo(last.scale - 1e-9));
      last = now;
    }
  });

  test('it rises before it grows', () {
    // Clear of the cover as a record first, and only then up to size: growing first
    // would push its edges out past the sides of the sleeve it is still inside.
    final mid = at(0.4);
    final risen = (sleeveAt - mid.dy) / (sleeveAt - drop);
    final grown = (mid.scale - at(0).scale) / (1 - at(0).scale);
    expect(risen, greaterThan(grown));
  });

  test('outside the range it holds its ends', () {
    expect(at(-1).dy, at(0).dy);
    expect(at(2).scale, at(1).scale);
  });
}
