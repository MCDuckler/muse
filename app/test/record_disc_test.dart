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
    expect(Disc.sliding(0), 0);
    expect(Disc.arriving(0), 0);
  });

  test('it leaves the sleeve first and arrives second, never both at once', () {
    // Two things, not one: the record slides out of the side of its cover and off the
    // screen, and then the record being played appears where it will be played. A
    // small disc crawling to the middle and growing would be a picture being resized.
    expect(Disc.sliding(0), 0);
    expect(Disc.sliding(Disc.leaves), 1, reason: 'gone by the handover');
    expect(Disc.arriving(Disc.leaves), 0, reason: 'and the big one starts there');
    expect(Disc.arriving(1), 1);
    for (var i = 0; i <= 40; i++) {
      final out = i / 40;
      final leaving = Disc.sliding(out);
      final arriving = Disc.arriving(out);
      expect(leaving < 1 && arriving > 0, isFalse,
          reason: 'one at a time, at $out');
    }
  });

  test('both halves are one way only', () {
    var last = -1.0;
    for (var i = 0; i <= 50; i++) {
      final now = Disc.sliding(i / 50);
      expect(now, greaterThanOrEqualTo(last));
      last = now;
    }
    last = -1.0;
    for (var i = 0; i <= 50; i++) {
      final now = Disc.arriving(i / 50);
      expect(now, greaterThanOrEqualTo(last));
      last = now;
    }
  });

  test('the record leaving the sleeve is done by the time the deck has one', () {
    // They are two different things in two different places — one belongs to the
    // cover, one to the stage — and the handover is the only moment they share.
    expect(Disc.sliding(Disc.leaves), 1);
    expect(Disc.arriving(Disc.leaves), 0);
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
