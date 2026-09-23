// The arithmetic either side of the trained separator: the transform, the
// spectrograms, and the cutting up and sewing together of a whole record.
//
// None of it needs the network. A "network" that hands back its input as the drums
// and nothing as everything else must give back exactly the record as the drums —
// through the transform, the reflected edges, the half-overlapping pieces and their
// fades — and silence for the rest. Anything lost or doubled at a seam shows up here
// as a number, long before it shows up as a click on a deck.
//
// That the numbers match the Python the model was measured with is checked against
// the Python itself: tools/separation/check_worker.py.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/separation/fft.dart';
import 'package:muse/src/separation/scnet.dart';

void main() {
  test('the real FFT agrees with the definition, and inverts', () {
    const n = 64;
    final r = math.Random(3);
    final x = Float64List.fromList([for (var i = 0; i < n; i++) r.nextDouble() - .5]);
    final fft = RealFft(n);
    final re = Float64List(fft.bins), im = Float64List(fft.bins);
    fft.forward(x, 0, re, im);
    for (var k = 0; k < fft.bins; k++) {
      var wr = 0.0, wi = 0.0;
      for (var t = 0; t < n; t++) {
        wr += x[t] * math.cos(-2 * math.pi * k * t / n);
        wi += x[t] * math.sin(-2 * math.pi * k * t / n);
      }
      expect(re[k], closeTo(wr, 1e-9), reason: 'bin $k, real');
      expect(im[k], closeTo(wi, 1e-9), reason: 'bin $k, imaginary');
    }
    final back = Float64List(n);
    fft.inverse(re, im, back, 0);
    for (var t = 0; t < n; t++) {
      expect(back[t], closeTo(x[t], 1e-12));
    }
  });

  test('the inverse ignores what a real signal cannot have', () {
    // numpy's and torch's irfft drop the imaginary parts of the first and last bins;
    // the model's output has them, and they must come to nothing here too.
    final fft = RealFft(16);
    final re = Float64List(9)..[3] = 1;
    final im = Float64List(9)
      ..[0] = 5
      ..[8] = -7;
    final a = Float64List(16), b = Float64List(16);
    fft.inverse(re, im, a, 0);
    fft.inverse(re, Float64List(9), b, 0);
    expect(a, b);
  });

  test('a record comes back whole through every seam', () async {
    // Thirty seconds: long enough to be reflected at both ends and cut into pieces
    // that overlap, with a short last one.
    final r = math.Random(7);
    final n = 30 * modelRate + 1234;
    final stereo = Float32List(n * 2);
    for (var i = 0; i < stereo.length; i++) {
      stereo[i] = (r.nextDouble() - .5) * .8;
    }
    final piece = Piece(_drumsAreEverything);

    final got = List.generate(8, (_) => Float32List(n));
    var next = 0;
    final heard = <double>[];
    await demix(stereo, piece, (from, count, parts) async {
      expect(from, next, reason: 'handed on in order, nothing skipped or repeated');
      for (var p = 0; p < 8; p++) {
        got[p].setRange(from, from + count, parts[p]);
      }
      next = from + count;
    }, progress: heard.add);
    expect(next, n, reason: 'all of it, exactly once');
    expect(heard.last, 1.0);
    for (var i = 1; i < heard.length; i++) {
      expect(heard[i], greaterThanOrEqualTo(heard[i - 1]));
    }

    var worst = 0.0;
    for (var i = 0; i < n; i++) {
      worst = math.max(worst, (got[0][i] - stereo[i * 2]).abs());
      worst = math.max(worst, (got[1][i] - stereo[i * 2 + 1]).abs());
    }
    expect(worst, lessThan(1e-5), reason: 'the drums are the whole record');
    for (var p = 2; p < 8; p++) {
      expect(got[p].every((v) => v == 0), isTrue, reason: 'and the rest is silence');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  for (final seconds in [3, 8]) {
    test('a record shorter than one piece ($seconds s) comes back whole too', () async {
      final n = seconds * modelRate;
      final stereo = Float32List(n * 2);
      for (var i = 0; i < n; i++) {
        stereo[i * 2] = math.sin(i / 50);
        stereo[i * 2 + 1] = math.cos(i / 70) * .5;
      }
      final got = Float32List(n);
      await demix(stereo, Piece(_drumsAreEverything), (from, count, parts) async {
        got.setRange(from, from + count, parts[0]);
      });
      var worst = 0.0;
      for (var i = 0; i < n; i++) {
        worst = math.max(worst, (got[i] - stereo[i * 2]).abs());
      }
      expect(worst, lessThan(1e-5));
    });
  }
}

/// Hands back channel c of the input as drums channel c, and nothing else.
void _drumsAreEverything(Float32List specIn, Float32List specOut) {
  // In: planes [left re, left im, right re, right im]. Out: sixteen planes, 2p and
  // 2p+1 the real and imaginary halves of signal p = part * 2 + channel.
  final plane = specInLength ~/ 4;
  specOut.fillRange(0, specOut.length, 0);
  specOut.setRange(0, 4 * plane, specIn); // drums left re/im, drums right re/im
}
