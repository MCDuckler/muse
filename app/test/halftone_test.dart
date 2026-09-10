// The printed background, and the arithmetic that decides how much of it to draw.
//
// The painter walks a grid of cells at an angle and keeps the ones that land on the
// screen. Narrowing that walk is worth about nine tenths of its cost — and getting the
// range wrong shows up as a background that is silently missing a corner, which is
// exactly the kind of thing nobody notices until it is shipped.
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/ui/halftone.dart';

/// Every cell the painter would actually draw, found the slow, obvious way.
Set<String> drawnOn(Size size) {
  final cos = math.cos(halftoneAngle), sin = math.sin(halftoneAngle);
  final rows = ((size.width + size.height) / halftonePitch).ceil();
  final out = <String>{};
  for (var j = -rows; j <= rows; j++) {
    for (var i = -rows; i <= rows; i++) {
      final x = i * halftonePitch * cos - j * halftonePitch * sin;
      final y = i * halftonePitch * sin + j * halftonePitch * cos;
      if (x < -halftonePitch ||
          y < -halftonePitch ||
          x > size.width + halftonePitch ||
          y > size.height + halftonePitch) {
        continue;
      }
      out.add('$i,$j');
    }
  }
  return out;
}

void main() {
  const screens = [
    Size(320, 640),
    Size(400, 800),
    Size(900, 500),
    Size(1440, 900),
    Size(200, 200),
  ];

  test('the narrowed range still covers every dot on the screen', () {
    for (final size in screens) {
      final cells = visibleCells(size, halftoneAngle, halftonePitch);
      final inside = <String>{};
      for (var j = cells.jLow; j <= cells.jHigh; j++) {
        for (var i = cells.iLow; i <= cells.iHigh; i++) {
          inside.add('$i,$j');
        }
      }
      final missing = drawnOn(size).difference(inside);
      expect(missing, isEmpty,
          reason: '$size would lose ${missing.length} dots');
    }
  });

  test('and it is a small fraction of what was walked before', () {
    for (final size in screens) {
      final cells = visibleCells(size, halftoneAngle, halftonePitch);
      final now = (cells.iHigh - cells.iLow + 1) * (cells.jHigh - cells.jLow + 1);
      final rows = ((size.width + size.height) / halftonePitch).ceil();
      final before = (2 * rows + 1) * (2 * rows + 1);
      expect(now * 4, lessThan(before),
          reason: '$size: $before -> $now cells is not worth the arithmetic');
    }
  });
}
