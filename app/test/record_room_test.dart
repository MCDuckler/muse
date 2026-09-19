// How big the record is drawn, and what that is measured from.
//
// The stage sized the record on the deck from the *window*: on a phone the stage is
// the page, so that was the room it had. Beside a page it is not — the stage is a
// panel three hundred pixels wide in a window of fourteen hundred — and a record sized
// by the window came out four times wider than the box it was drawn in, over
// everything next to it.
import 'package:flutter_test/flutter_test.dart';

/// Mirrors RecordStage: the room the record has, and how wide that makes it.
({double room, double platter}) recordRoom({
  required double stageSide,
  required double windowWidth,
  double discScale = 1.0,
  double wallClearance = 40,
}) {
  final room = (stageSide + wallClearance * 2 + stageSide * 0.06) < windowWidth
      ? stageSide + wallClearance * 2 + stageSide * 0.06
      : windowWidth;
  return (room: room, platter: (room - wallClearance * 2) * discScale);
}

void main() {
  test('on a phone the record is what it always was', () {
    // A 420 phone: the player column is 520 wide at most, less 24 either side.
    final phone = recordRoom(stageSide: 372, windowWidth: 420);
    expect(phone.platter, closeTo(340, 1),
        reason: 'the screen less its margins, as before');
  });

  test('in a panel beside a page it is the panel that decides', () {
    final dock = recordRoom(stageSide: 290, windowWidth: 1440);
    expect(dock.platter, lessThan(340),
        reason: 'a record in a 290 box is not a 1360 record');
    expect(dock.platter, greaterThan(290),
        reason: 'but it still stands a little wider than its sleeve, as a record does');
  });

  test('half a wide window is half a wide window', () {
    final half = recordRoom(stageSide: 550, windowWidth: 1440);
    expect(half.platter, closeTo(583, 2));
    expect(half.platter, lessThan(1440 - 80));
  });

  test('the size setting still does what it says', () {
    final small = recordRoom(stageSide: 290, windowWidth: 1440, discScale: 0.6);
    final big = recordRoom(stageSide: 290, windowWidth: 1440, discScale: 1.15);
    expect(small.platter, lessThan(big.platter));
    expect(big.platter / small.platter, closeTo(1.15 / 0.6, 0.01));
  });
}
