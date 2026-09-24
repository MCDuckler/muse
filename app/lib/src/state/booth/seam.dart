// A loop's seam spliced where the two sides agree.
//
// The engine loops sample-exactly: it plays up to the sample before the loop's end
// and carries on from its start. Two unrelated points of a waveform spliced together
// are a click, once a bar, for as long as the loop runs. DJ software crossfades a few
// milliseconds there; this engine cannot. What it can do is splice where the two sides
// already agree: within a millisecond and a half, where the two samples either side of
// the loop's end match the two either side of its start. On three records' one, two
// and four bar loops that took the jump from about twice an ordinary step of the
// waveform to under half of one, and the worst from fifty times to six. (Matched over a
// few milliseconds around the splice instead, the seams came out worse than not moving
// them: the neighbourhood agreed while the one sample that mattered did not.)
import 'package:flutter/foundation.dart';

/// How far either way the ends are moved, in samples: 1.5 ms at 44.1 kHz.
const seamReach = 66;

/// Samples either side of the splice compared.
const seamHalf = 1;

/// How many frames either window needs: [seamReach] + [seamHalf] either side.
const seamWindow = 2 * (seamReach + seamHalf);

/// The move, in samples, that makes the seam quietest: both windows are stereo
/// interleaved floats of [seamWindow] frames, centred on the loop's start ([a]) and
/// its end ([b]). Ties go to the smaller move.
int bestSplice(Float32List a, Float32List b) {
  const w = seamReach + seamHalf;
  var best = 0;
  var least = double.infinity;
  for (var d = -seamReach; d <= seamReach; d++) {
    var sum = 0.0;
    for (var k = -seamHalf; k < seamHalf; k++) {
      final i = (w + d + k) * 2;
      final l = a[i] - b[i], r = a[i + 1] - b[i + 1];
      sum += l * l + r * r;
    }
    if (sum < least - 1e-12 || (sum <= least + 1e-12 && d.abs() < best.abs())) {
      least = sum;
      best = d;
    }
  }
  return best;
}

/// The loop's ends for the engine, each half a sample to the safe side of the exact
/// one so its own rounding lands on it: it starts on the first sample at or after the
/// start, and stops before the first sample that would run past the end.
(Duration, Duration) seamPoints(int startSample, int endSample, int move, int rate) {
  Duration at(double s) => Duration(microseconds: (s / rate * 1e6).round());
  return (at(startSample + move - 0.5), at(endSample + move + 0.5));
}
