// The shape of the reflection under the record.
//
// Three versions of this fade were shipped and each was wrong in a way that is obvious
// on a screen and invisible in the source: flipped about the wrong axis, so the copy
// landed on top of the cover; then a straight ramp to zero, whose corner the eye reads
// as the bottom edge of a picture; then a steep decay that spent the whole visible fade
// in the first third of the band, so the reflection appeared to stop short. The curve is
// arithmetic, so it can be checked like arithmetic.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/record_stage.dart';

void main() {
  test('it starts whole and ends at nothing', () {
    expect(Mirror.fadeAt(0), 1.0);
    expect(Mirror.fadeAt(1), 0.0);
  });

  test('it never brightens on the way down', () {
    var last = 2.0;
    for (var i = 0; i <= 100; i++) {
      final now = Mirror.fadeAt(i / 100);
      expect(now, lessThanOrEqualTo(last));
      last = now;
    }
  });

  test('it levels off at the bottom rather than arriving still falling', () {
    // The corner that reads as an edge. A curve that eases out has almost no slope
    // left by the time it reaches nothing.
    final slope = Mirror.fadeAt(0.95) - Mirror.fadeAt(1.0);
    final steepest = Mirror.fadeAt(0.45) - Mirror.fadeAt(0.5);
    expect(slope, lessThan(steepest / 3),
        reason: 'still dropping by $slope at the end against $steepest in the middle');
  });

  test('and it eases in at the top too, so the seam is not a line', () {
    final slope = Mirror.fadeAt(0.0) - Mirror.fadeAt(0.05);
    final steepest = Mirror.fadeAt(0.45) - Mirror.fadeAt(0.5);
    expect(slope, lessThan(steepest / 3));
  });

  test('it is still worth seeing halfway down', () {
    // The failure that made it look like it cut off: nothing left by a third of the
    // way, so the band was mostly empty and the eye put the edge where it lost it.
    expect(Mirror.fadeAt(0.5), greaterThan(0.35));
    expect(Mirror.fadeAt(0.75), greaterThan(0.1));
  });

  test('the sampled stops cover the whole band in order', () {
    expect(Mirror.fadeStops.first, 0.0);
    expect(Mirror.fadeStops.last, 1.0);
    for (var i = 1; i < Mirror.fadeStops.length; i++) {
      expect(Mirror.fadeStops[i], greaterThan(Mirror.fadeStops[i - 1]));
      // Close enough together that a straight line between two samples is not a
      // visible facet of the curve.
      expect(Mirror.fadeStops[i] - Mirror.fadeStops[i - 1], lessThanOrEqualTo(0.2));
    }
  });
}
