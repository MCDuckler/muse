// How a record comes out of its sleeve.
//
// It does not slide half out and stop, which is what it used to do. It comes right out
// — clear of the cover — and then leans back against the front of it, which is where a
// record you have taken out actually sits. That is two movements expressed as one
// number, so it can be checked as one number.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/record_stage.dart';

void main() {
  test('it starts inside the sleeve', () {
    expect(Disc.travel(0), 0);
  });

  test('it comes right out before it comes back', () {
    final furthest = [
      for (var i = 0; i <= 100; i++) Disc.travel(i / 100),
    ].reduce((a, b) => a > b ? a : b);
    expect(furthest, greaterThan(Disc.travel(1)),
        reason: 'it never went further out than where it ends up');
    expect(Disc.travel(Disc.infront), furthest,
        reason: 'the turn is where it stops being behind the cover');
  });

  test('and it settles half over the cover', () {
    // Half of a disc that is 0.92 of the jacket wide is 0.46 of the jacket.
    expect(Disc.travel(1), closeTo(0.46, 0.01));
  });

  test('it is behind the sleeve on the way out and in front once it is clear', () {
    expect(Disc.infront, greaterThan(0.0));
    expect(Disc.infront, lessThan(1.0));
    // Nothing jumps at the handover: where it is at the moment it changes places is
    // the same on both sides of that moment.
    final before = Disc.travel(Disc.infront - 0.001);
    final after = Disc.travel(Disc.infront + 0.001);
    expect((before - after).abs(), lessThan(0.01));
  });

  test('the way out is monotonic, and so is the way back', () {
    var last = -1.0;
    for (var i = 0; i <= 50; i++) {
      final now = Disc.travel(Disc.infront * i / 50);
      expect(now, greaterThanOrEqualTo(last));
      last = now;
    }
    last = double.infinity;
    for (var i = 0; i <= 50; i++) {
      final now = Disc.travel(Disc.infront + (1 - Disc.infront) * i / 50);
      expect(now, lessThanOrEqualTo(last));
      last = now;
    }
  });
}
