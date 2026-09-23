// Taking a record apart, here, on this computer.
//
// This is the same separation the server does, in Dart, because a desk has cores a
// small shared box does not. The server's version is `server/muse/stems.py` and it is
// the one to read for *why* any of this is the way it is: the voice living in the
// middle, drums being vertical and notes horizontal, and the honest account of what
// neither trick manages.
//
// The two are one algorithm written twice, which is a thing worth being nervous about.
// They are kept in step by their constants — every number below has a named twin in
// stems.py — and by both suites of tests putting the same made-up sound through and
// demanding the same properties of what comes out. What they must agree on is the
// sound, not the bits: a record separated at a desk and the same record separated on
// the box should be indistinguishable to a listener, and either may end up in the
// house's cache.
//
// No Flutter here on purpose. It runs in an isolate, off the frame thread, because
// four minutes of music is a few seconds of arithmetic and a booth that stutters
// while it thinks is worse than one that cannot separate at all.
import 'dart:math' as math;
import 'dart:typed_data';

/// What the parts are rendered at. The server's RATE.
const rate = 32000;

const _fft = 2048;
const _hop = 512;

/// How far the medians look. The server's _SPAN.
const _span = 17;

/// Frames at a time. The server's _BLOCK.
const _block = 384;

/// The band the voice is taken out of. The server's _VOICE_LOW and _VOICE_HIGH.
const _voiceLow = 200.0;
const _voiceHigh = 8000.0;

/// The parts a record comes in, as the server names them.
const partNames = ['instrumental', 'drums', 'music'];

// ------------------------------------------------------------------ the window
/// Hann, symmetric — numpy's `hanning`, which divides by n-1 rather than n. A window
/// that disagreed with the server's by one sample would put a faint buzz on every
/// part rendered here and nowhere else.
final Float64List _window = () {
  final w = Float64List(_fft);
  for (var i = 0; i < _fft; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (_fft - 1));
  }
  return w;
}();

// ------------------------------------------------------------------ the transform
/// An in-place complex FFT, radix 2, decimation in time.
///
/// Written out rather than taken from a package: it is forty lines, it is the only
/// thing here that has to be fast, and a dependency that pulls in a plotting library
/// to multiply some numbers is not worth the download.
void _transform(Float64List re, Float64List im, {required bool inverse}) {
  final n = re.length;
  // Bit-reversal permutation.
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i], ti = im[i];
      re[i] = re[j];
      im[i] = im[j];
      re[j] = tr;
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final angle = 2 * math.pi / len * (inverse ? 1 : -1);
    final wr = math.cos(angle), wi = math.sin(angle);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final ar = re[i + k], ai = im[i + k];
        final br = re[i + k + len ~/ 2], bi = im[i + k + len ~/ 2];
        final tr = br * cr - bi * ci, ti = br * ci + bi * cr;
        re[i + k] = ar + tr;
        im[i + k] = ai + ti;
        re[i + k + len ~/ 2] = ar - tr;
        im[i + k + len ~/ 2] = ai - ti;
        final nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = nr;
      }
    }
  }
  if (inverse) {
    for (var i = 0; i < n; i++) {
      re[i] /= n;
      im[i] /= n;
    }
  }
}

/// The bins of a real transform: 0 to nyquist inclusive.
const _bins = _fft ~/ 2 + 1;

int framesIn(int samples) => samples < _fft ? 0 : 1 + (samples - _fft) ~/ _hop;

// ------------------------------------------------------------------ sliding medians
/// The median of every [_span] neighbours along one run of numbers, where the run is
/// [count] values starting at [from] and stepping by [stride]. Edges repeat, as
/// numpy's `pad(mode: 'edge')` does.
///
/// A sorted window carried along rather than a sort at every step: seventeen values
/// shuffled up or down beats seventeen values sorted from scratch, and this is thirty
/// million medians for one record.
void _medianAlong(Float32List src, int from, int stride, int count,
    Float32List dst, int dstFrom, int dstStride) {
  if (count == 0) return;
  const half = _span ~/ 2;
  final sorted = Float64List(_span);
  double at(int i) => src[from + (i < 0 ? 0 : (i >= count ? count - 1 : i)) * stride];

  // The first window, sorted.
  for (var k = 0; k < _span; k++) {
    final v = at(k - half);
    var j = k - 1;
    while (j >= 0 && sorted[j] > v) {
      sorted[j + 1] = sorted[j];
      j--;
    }
    sorted[j + 1] = v;
  }
  dst[dstFrom] = sorted[half];

  for (var i = 1; i < count; i++) {
    final out = at(i - 1 - half);
    final into = at(i + half);
    if (out != into) {
      // Out: find it and close the gap.
      var g = 0;
      while (sorted[g] != out) {
        g++;
      }
      // In: slide whichever way makes room, so the window stays sorted.
      if (into > out) {
        while (g + 1 < _span && sorted[g + 1] < into) {
          sorted[g] = sorted[g + 1];
          g++;
        }
      } else {
        while (g > 0 && sorted[g - 1] > into) {
          sorted[g] = sorted[g - 1];
          g--;
        }
      }
      sorted[g] = into;
    }
    dst[dstFrom + i * dstStride] = sorted[half];
  }
}

// ------------------------------------------------------------------ the spectrogram
class _Block {
  _Block(this.frames)
      : re = Float64List(frames * _bins),
        im = Float64List(frames * _bins),
        mag = Float32List(frames * _bins);
  final int frames;
  final Float64List re, im;
  final Float32List mag;
}

/// Frames [first, last) of [x], windowed and transformed.
_Block _spectra(Float32List x, int first, int last) {
  final block = _Block(last - first);
  final re = Float64List(_fft), im = Float64List(_fft);
  for (var f = 0; f < block.frames; f++) {
    final at = (first + f) * _hop;
    for (var i = 0; i < _fft; i++) {
      re[i] = x[at + i] * _window[i];
      im[i] = 0;
    }
    _transform(re, im, inverse: false);
    final into = f * _bins;
    for (var k = 0; k < _bins; k++) {
      block.re[into + k] = re[k];
      block.im[into + k] = im[k];
      block.mag[into + k] = math.sqrt(re[k] * re[k] + im[k] * im[k]);
    }
  }
  return block;
}

/// Overlap-add frames back into [into], starting at frame [first]. The dividing
/// through by the window's own weight happens once at the end, in [_finish].
void _addFrames(Float32List into, Float64List re, Float64List im, int frames,
    int first, int fromFrame) {
  final fr = Float64List(_fft), fi = Float64List(_fft);
  for (var f = 0; f < frames; f++) {
    final src = (fromFrame + f) * _bins;
    // Back to a full spectrum: a real signal's is a mirror of itself.
    for (var k = 0; k < _bins; k++) {
      fr[k] = re[src + k];
      fi[k] = im[src + k];
    }
    for (var k = 1; k < _fft - _bins + 1; k++) {
      fr[_fft - k] = re[src + k];
      fi[_fft - k] = -im[src + k];
    }
    _transform(fr, fi, inverse: true);
    final at = (first + f) * _hop;
    for (var i = 0; i < _fft; i++) {
      into[at + i] += fr[i] * _window[i];
    }
  }
}

Float32List _roomFor(int frames) =>
    Float32List(_fft + _hop * (frames > 0 ? frames - 1 : 0));

/// Undo the windowing's weight and cut to [length].
Float32List _finish(Float32List out, int frames, int length) {
  final weight = Float64List(out.length);
  for (var f = 0; f < frames; f++) {
    final at = f * _hop;
    for (var i = 0; i < _fft; i++) {
      weight[at + i] += _window[i] * _window[i];
    }
  }
  final done = Float32List(length);
  final n = math.min(length, out.length);
  for (var i = 0; i < n; i++) {
    done[i] = out[i] / math.max(weight[i], 1e-6);
  }
  return done;
}

// ------------------------------------------------------------------ hits and notes
/// The record split in two: what is percussive, and what is not. (drums, music)
(Float32List, Float32List) hitsAndNotes(Float32List mono) {
  final frames = framesIn(mono.length);
  if (frames == 0) {
    return (Float32List(mono.length), Float32List(mono.length));
  }
  final hitsOut = _roomFor(frames), notesOut = _roomFor(frames);
  const pad = _span ~/ 2;
  for (var start = 0; start < frames; start += _block) {
    final stop = math.min(frames, start + _block);
    // With the neighbours a median at the edge of a block would otherwise want, so a
    // block boundary is not a seam anybody can hear.
    final first = math.max(0, start - pad), last = math.min(frames, stop + pad);
    final b = _spectra(mono, first, last);
    final notes = Float32List(b.frames * _bins);   // holds still in time: the notes
    final hits = Float32List(b.frames * _bins);    // broad in frequency: the drums
    for (var k = 0; k < _bins; k++) {
      _medianAlong(b.mag, k, _bins, b.frames, notes, k, _bins);
    }
    for (var f = 0; f < b.frames; f++) {
      _medianAlong(b.mag, f * _bins, 1, _bins, hits, f * _bins, 1);
    }
    // Wiener-ish soft masks: every bin is shared out rather than given to one side,
    // which is what keeps the two halves adding back up to the record.
    final dr = Float64List(b.frames * _bins), di = Float64List(b.frames * _bins);
    final nr = Float64List(b.frames * _bins), ni = Float64List(b.frames * _bins);
    for (var i = 0; i < b.mag.length; i++) {
      final n2 = notes[i] * notes[i], h2 = hits[i] * hits[i];
      final total = n2 + h2 + 1e-9;
      dr[i] = b.re[i] * (h2 / total);
      di[i] = b.im[i] * (h2 / total);
      nr[i] = b.re[i] * (n2 / total);
      ni[i] = b.im[i] * (n2 / total);
    }
    _addFrames(hitsOut, dr, di, stop - start, start, start - first);
    _addFrames(notesOut, nr, ni, stop - start, start, start - first);
  }
  return (
    _finish(hitsOut, frames, mono.length),
    _finish(notesOut, frames, mono.length),
  );
}

// ------------------------------------------------------------------ the middle of it
/// One for the bins inside the voice's band, zero outside, with an octave of slope
/// either side. The server's _band_mask.
final Float64List _inVoiceBand = () {
  final m = Float64List(_bins);
  for (var k = 0; k < _bins; k++) {
    final hz = math.max(k * rate / _fft, 1e-6);
    final up = (math.log(hz / _voiceLow) / math.ln2).clamp(0.0, 1.0);
    final down = (math.log(_voiceHigh / hz) / math.ln2).clamp(0.0, 1.0);
    m[k] = up * down;
  }
  return m;
}();

/// Everything in [x] below the voice's band or above it.
Float32List _outsideBand(Float32List x) {
  final frames = framesIn(x.length);
  if (frames == 0) return Float32List(x.length);
  final out = _roomFor(frames);
  for (var start = 0; start < frames; start += _block) {
    final stop = math.min(frames, start + _block);
    // No medians here, so the neighbours a block would otherwise want are not taken:
    // every frame is done exactly once.
    final b = _spectra(x, start, stop);
    for (var f = 0; f < b.frames; f++) {
      for (var k = 0; k < _bins; k++) {
        final keep = 1.0 - _inVoiceBand[k];
        b.re[f * _bins + k] *= keep;
        b.im[f * _bins + k] *= keep;
      }
    }
    _addFrames(out, b.re, b.im, b.frames, start, 0);
  }
  return _finish(out, frames, x.length);
}

/// The record with what is in the middle taken out, across the band a voice is in.
/// [stereo] is interleaved; what comes back is interleaved too.
Float32List withoutVoice(Float32List stereo) {
  final n = stereo.length ~/ 2;
  final mid = Float32List(n), side = Float32List(n);
  for (var i = 0; i < n; i++) {
    mid[i] = (stereo[i * 2] + stereo[i * 2 + 1]) / 2;
    side[i] = (stereo[i * 2] - stereo[i * 2 + 1]) / 2;
  }
  final keep = _outsideBand(mid);
  final out = Float32List(n * 2);
  for (var i = 0; i < n; i++) {
    out[i * 2] = keep[i] + side[i];
    out[i * 2 + 1] = keep[i] - side[i];
  }
  return out;
}

// ------------------------------------------------------------------ the whole of it
/// What comes out of one pass: the part that was asked for, and anything the same
/// arithmetic gave for nothing. Interleaved, at [rate]; [channels] says how many.
typedef Parts = ({Map<String, Float32List> sound, int channels});

/// The part of [stereo] called [name], with whatever comes with it.
///
/// [stereo] is interleaved two-channel floats at [rate] — what ffmpeg hands over.
Parts separate(Float32List stereo, String name) {
  if (!partNames.contains(name)) {
    throw ArgumentError('no such part: $name');
  }
  if (stereo.isEmpty) throw ArgumentError('there is no sound in that file');
  if (name == 'instrumental') {
    return (sound: {'instrumental': withoutVoice(stereo)}, channels: 2);
  }
  final n = stereo.length ~/ 2;
  final mono = Float32List(n);
  for (var i = 0; i < n; i++) {
    mono[i] = (stereo[i * 2] + stereo[i * 2 + 1]) / 2;
  }
  final (drums, music) = hitsAndNotes(mono);
  return (sound: {'drums': drums, 'music': music}, channels: 1);
}
