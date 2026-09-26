// The three-band knobs: what a hand's movement is worth, and that the knob and the
// band always agree about where it is.
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/booth/mixer.dart';

void main() {
  test('the knob and the band are the same thing read two ways', () {
    for (final t in const [0.0, 0.05, 0.1, 0.2, 0.25, 0.3, 0.4, 0.49, 0.5, 0.6, 0.75, 1.0]) {
      final db = EqSet.dbOf(t);
      // Everything at or below the kill is the bottom of the travel, so only the
      // travel above it round-trips.
      if (db > EqSet.killed) {
        expect(EqSet.knobOf(db), closeTo(t, 0.0005), reason: 'knob $t is $db dB');
      }
    }
  });

  test('flat is straight up, and the stops are the stops', () {
    expect(EqSet.dbOf(0.5), 0);
    expect(EqSet.knobOf(0), 0.5);
    expect(EqSet.dbOf(1), EqSet.most);
    expect(EqSet.dbOf(0), EqSet.killed);
    expect(EqSet.knobOf(EqSet.killed), 0);
  });

  test('a small movement down is worth about twice one up, not three times', () {
    // The complaint this was changed for: the knobs "decrease volume too early too
    // much". A tenth of the travel below centre used to be -1.8 dB against +0.6 above
    // — three and a quarter times as much for the same movement of the hand.
    final down = EqSet.dbOf(0.4).abs();   // a fifth of the travel down
    final up = EqSet.dbOf(0.6);           // and the same up
    expect(down / up, lessThan(2.5), reason: 'down $down dB against up $up dB');
    expect(down / up, greaterThan(1.5), reason: 'a mixer still takes more than it gives');
  });

  test('a quarter of the travel down is a cut, not a kill', () {
    expect(EqSet.dbOf(0.25), closeTo(-6, 0.01));
    // And the band is still gone by the stop, which is what the transitions rely on.
    expect(EqSet.dbOf(0.02), lessThan(-25));
  });
}
