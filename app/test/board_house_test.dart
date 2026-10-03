// The house's shelf on the board: kept beside the user's own sounds without mixing
// with them, found by id like any other, and a pad that takes one of its sounds holds
// it the way it came — short name, colour, mode, choke and duck.

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/booth/board/pad_spec.dart';
import 'package:muse/src/state/booth/board/samples.dart';
import 'package:muse/src/ui/booth/board/board_library.dart';

void main() {
  Map<String, dynamic> horn() => {
        'id': 12,
        'name': 'Air horn (canned, single blast)',
        'duration_ms': 1600,
        'shape': [255, 128, 0],
        'group': 'Horns & sirens',
        'pad': {'name': 'Air Horn', 'colour': 'orange', 'mode': 'hold', 'choke': 2, 'duck': 0.35},
        'words': null,
      };

  test('the shelf sits beside the user\'s own sounds', () {
    final library = SampleLibrary()
      ..takeServerList([
        {'id': 7, 'name': 'Mine', 'duration_ms': 900, 'shape': [0, 255]},
      ])
      ..takeHouseList([horn()]);
    expect(library.byId(7)!.house, isFalse);
    final s = library.byId(12)!;
    expect(s.house, isTrue);
    expect(s.group, 'Horns & sirens');
    expect(s.length, const Duration(milliseconds: 1600));
    expect(library.peaks[12]!.first, 1.0);
    expect(library.known.keys, [7], reason: 'the shelf is not the user\'s own');
    expect([for (final x in library.all) x.id], containsAll([7, 12]));

    // A new listing replaces the shelf and leaves the user's own alone.
    library.takeHouseList(const []);
    expect(library.byId(12), isNull);
    expect(library.byId(7), isNotNull);
  });

  test('a pad takes a house sound the way it came', () {
    final s = SampleLibrary.fromServer(horn(), house: true);
    final spec = padFor(s);
    expect(spec.sampleId, 12);
    expect(spec.name, 'AIR HORN');
    expect(spec.colour, PadColour.orange);
    expect(spec.mode, PadMode.hold);
    expect(spec.choke, 2);
    expect(spec.duck, closeTo(0.35, 1e-9));
  });

  test('a sound without hints is held as before', () {
    final s = SampleLibrary.fromServer({'id': 3, 'name': 'Kick · 2 bars', 'duration_ms': 500});
    final spec = padFor(s);
    expect(spec.name, 'KICK');
    expect(spec.mode, PadMode.oneShot);
    expect(spec.colour, PadColour.white);
  });
}
