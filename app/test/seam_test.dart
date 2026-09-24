// A loop's seam spliced where the two sides agree (seam.dart).
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/booth/seam.dart';

void main() {
  // Something like music: noise, smoothed, a different sound at each end of the loop.
  const rate = 44100;
  const n = rate * 4;
  final r = math.Random(4);
  final pcm = Float32List(n * 2);
  var l = 0.0, rr = 0.0;
  for (var i = 0; i < n; i++) {
    l = 0.9 * l + 0.1 * (r.nextDouble() * 2 - 1);
    rr = 0.9 * rr + 0.1 * (r.nextDouble() * 2 - 1);
    pcm[2 * i] = l * 3;
    pcm[2 * i + 1] = rr * 3;
  }
  Float32List window(int centre) {
    const w = seamReach + seamHalf;
    return Float32List.fromList(pcm.sublist((centre - w) * 2, (centre - w + seamWindow) * 2));
  }

  // The jump the splice makes: the sample it goes back to against the one that would
  // have come next, and the one before each, both channels.
  double jump(int ia, int ib) =>
      (pcm[2 * ib] - pcm[2 * ia]).abs() + (pcm[2 * ib + 1] - pcm[2 * ia + 1]).abs() +
      (pcm[2 * ib - 2] - pcm[2 * ia - 2]).abs() + (pcm[2 * ib - 1] - pcm[2 * ia - 1]).abs();

  test('the ends move together, a millisecond and a half at most, to a quieter seam', () {
    var better = 0;
    var total = 0.0, plain = 0.0;
    for (var k = 0; k < 40; k++) {
      final sa = rate + k * 997, sb = sa + 72900;
      final d = bestSplice(window(sa), window(sb));
      expect(d.abs(), lessThanOrEqualTo(seamReach));
      total += jump(sa + d, sb + d);
      plain += jump(sa, sb);
      if (jump(sa + d, sb + d) <= jump(sa, sb)) better++;
    }
    expect(better, 40, reason: 'never worse than leaving it');
    expect(total, lessThan(plain / 3), reason: 'and on the whole a good deal quieter');
  });

  test('the ends are handed over half a sample to the safe side', () {
    final (a, b) = seamPoints(44100, 44100 * 2, 3, 44100);
    // The engine starts on the first sample at or after the start...
    expect((a.inMicroseconds * 44100 / 1e6).ceil(), 44103);
    // ...and plays up to the one before the first sample past the end.
    expect((b.inMicroseconds * 44100 / 1e6).floor(), 88203);
  });
}
