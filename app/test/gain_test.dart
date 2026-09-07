import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// Mirrors PlayerService._volumeFor. A player can only attenuate, so a positive
/// gain on a quiet track is ignored rather than pushed into clipping.
double volumeFor(double? gainDb) {
  if (gainDb == null || gainDb >= 0) return 1.0;
  return math.pow(10, gainDb / 20).toDouble().clamp(0.05, 1.0);
}

void main() {
  test('loud tracks are pulled down', () {
    expect(volumeFor(-3.4), closeTo(0.676, 0.001));
    expect(volumeFor(-6.0), closeTo(0.501, 0.001));
  });

  test('quiet tracks are left alone instead of clipped', () {
    expect(volumeFor(8.3), 1.0);
    expect(volumeFor(0.0), 1.0);
  });

  test('an unmeasured track plays at full volume', () {
    expect(volumeFor(null), 1.0);
  });

  test('a pathological gain never mutes a track completely', () {
    expect(volumeFor(-90), 0.05);
  });
}
