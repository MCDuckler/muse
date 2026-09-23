// The Fourier transform the model's spectrograms are made with.
//
// No Flutter and no packages here: this file is compiled into the windowless
// separator (bin/wetowl_separate.dart) as well as tested inside the app.
import 'dart:math' as math;
import 'dart:typed_data';

/// A real FFT of one power-of-two length, done as a complex FFT of half that length.
///
/// The model eats about five thousand of these for every eleven seconds of music, so
/// the tables are worked out once and nothing is allocated per transform.
///
/// Scaling is numpy's and torch's: [forward] is unscaled, [inverse] divides by the
/// length, so one after the other gives back what went in.
class RealFft {
  RealFft(this.size)
      : _half = size >> 1,
        _re = Float64List(size >> 1),
        _im = Float64List(size >> 1),
        _rev = Int32List(size >> 1),
        _cos = Float64List(size >> 2),
        _sin = Float64List(size >> 2),
        _wr = Float64List((size >> 1) + 1),
        _wi = Float64List((size >> 1) + 1) {
    if (size < 4 || size & (size - 1) != 0) {
      throw ArgumentError('the length has to be a power of two: $size');
    }
    final m = _half;
    var bits = 0;
    while (1 << bits < m) {
      bits++;
    }
    for (var i = 0; i < m; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
    for (var k = 0; k < m >> 1; k++) {
      final a = -2 * math.pi * k / m;
      _cos[k] = math.cos(a);
      _sin[k] = math.sin(a);
    }
    for (var k = 0; k <= m; k++) {
      final a = -2 * math.pi * k / size;
      _wr[k] = math.cos(a);
      _wi[k] = math.sin(a);
    }
  }

  /// How many samples go in.
  final int size;

  /// How many bins come out: one more than half the length.
  int get bins => _half + 1;

  final int _half;
  final Float64List _re, _im;
  final Int32List _rev;
  final Float64List _cos, _sin; // the half-length transform's twiddles
  final Float64List _wr, _wi; // e^(-2πik/size), for folding the halves together

  void _complex({required bool inverse}) {
    final m = _half;
    final re = _re, im = _im;
    for (var i = 0; i < m; i++) {
      final j = _rev[i];
      if (i < j) {
        final tr = re[i], ti = im[i];
        re[i] = re[j];
        im[i] = im[j];
        re[j] = tr;
        im[j] = ti;
      }
    }
    final sign = inverse ? -1.0 : 1.0;
    for (var len = 2; len <= m; len <<= 1) {
      final half = len >> 1;
      final stride = m ~/ len;
      for (var k = 0; k < half; k++) {
        final wr = _cos[k * stride], wi = sign * _sin[k * stride];
        for (var a = k; a < m; a += len) {
          final b = a + half;
          final tr = wr * re[b] - wi * im[b];
          final ti = wr * im[b] + wi * re[b];
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
  }

  /// The spectrum of [size] samples of [x] from [from], into [outRe] and [outIm]
  /// ([bins] long each).
  void forward(List<double> x, int from, Float64List outRe, Float64List outIm) {
    final m = _half;
    final re = _re, im = _im;
    for (var k = 0; k < m; k++) {
      re[k] = x[from + 2 * k];
      im[k] = x[from + 2 * k + 1];
    }
    _complex(inverse: false);
    for (var k = 0; k <= m; k++) {
      final a = k == m ? 0 : k;
      final b = k == 0 ? 0 : m - k;
      final zr = re[a], zi = im[a], yr = re[b], yi = im[b];
      final er = (zr + yr) * 0.5, ei = (zi - yi) * 0.5; // the even samples' spectrum
      final or = (zi + yi) * 0.5, oi = (yr - zr) * 0.5; // the odd samples'
      final wr = _wr[k], wi = _wi[k];
      outRe[k] = er + wr * or - wi * oi;
      outIm[k] = ei + wr * oi + wi * or;
    }
  }

  /// [size] samples back out of a spectrum of [bins], into [out] from [at].
  ///
  /// The imaginary parts of the first and last bins are ignored, as numpy's and
  /// torch's irfft ignore them: a real signal cannot have any there.
  void inverse(Float64List inRe, Float64List inIm, List<double> out, int at) {
    final m = _half;
    final re = _re, im = _im;
    for (var k = 0; k < m; k++) {
      final ar = inRe[k], ai = k == 0 ? 0.0 : inIm[k];
      final br = inRe[m - k], bi = -(m - k == m ? 0.0 : inIm[m - k]); // conj(X[m-k])
      final er = (ar + br) * 0.5, ei = (ai + bi) * 0.5;
      final dr = (ar - br) * 0.5, di = (ai - bi) * 0.5;
      // times e^(+2πik/size): the odd samples' spectrum
      final wr = _wr[k], wi = -_wi[k];
      final or = dr * wr - di * wi, oi = dr * wi + di * wr;
      re[k] = er - oi;
      im[k] = ei + or;
    }
    _complex(inverse: true);
    final scale = 1.0 / m;
    for (var k = 0; k < m; k++) {
      out[at + 2 * k] = re[k] * scale;
      out[at + 2 * k + 1] = im[k] * scale;
    }
  }
}
