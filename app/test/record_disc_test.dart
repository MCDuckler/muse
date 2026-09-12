// How a record comes out of its sleeve, and what happens once it has.
//
// It used to slide sideways and lean against the front of the cover, which is what a
// record does in a room. It now comes straight down into the deck below the cover and
// stops there, cut in half by the line the song's name is written on — and once it has
// stopped, the arm comes down on it.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/record_stage.dart';

void main() {
  test('it starts inside the sleeve', () {
    expect(Disc.travel(0), 0);
  });

  test('it comes straight down and stops there', () {
    expect(Disc.travel(1), 1, reason: 'all the way to the deck, and no further');
    var last = -1.0;
    for (var i = 0; i <= 50; i++) {
      final now = Disc.travel(i / 50);
      expect(now, greaterThanOrEqualTo(last),
          reason: 'one way: a record does not come out and go back in on the way out');
      last = now;
    }
  });

  test('it slows into its place rather than arriving at speed', () {
    // Most of the way down in the first half of the journey, and the rest of it spent
    // settling — which is what leaves the arm something to wait for.
    expect(Disc.travel(0.5), greaterThan(0.7));
    expect(Disc.travel(0.9), greaterThan(0.99));
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

  test('the arm waits for the record to settle before it comes down', () {
    expect(Tonearm.lowering(0), 0);
    expect(Tonearm.lowering(0.5), 0, reason: 'the disc is still on its way');
    expect(Tonearm.lowering(0.8), 0, reason: 'and still settling');
    expect(Tonearm.lowering(0.9), greaterThan(0));
    expect(Tonearm.lowering(1), closeTo(1, 0.001));
  });

  test('and it comes off again first when the record goes away', () {
    // The same number read backwards: by the time the disc has started moving, the
    // arm has already been lifted clear of it.
    expect(Tonearm.lowering(0.85), lessThan(Tonearm.lowering(0.95)));
    expect(Tonearm.lowering(0.79), 0);
  });
}
