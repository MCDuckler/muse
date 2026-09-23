// Taking a record apart with a trained model: SCNet Small, four parts at once.
//
// The network itself runs in ONNX Runtime (see ort.dart); what is here is everything
// either side of it, written to match what the network was trained and measured
// with, number for number:
//
//   * the spectrogram going in and the sound coming out — SCNet's own STFT, which is
//     torch.stft with NO window (rectangular), n_fft 4096, hop 1024, centred with
//     reflected edges, and normalised by 1/√n_fft;
//   * how a whole record is cut into the eleven-second pieces the network takes and
//     sewn back together — ZFTurbo's demix: half-overlapping pieces, a linear fade over
//     a tenth of each edge, reflected padding at the ends.
//
// The Python this mirrors is tools/separation/ (export_scnet.py, and the candidate
// that measured it). A difference here is a difference in the sound, so the two are
// checked against each other by tools/separation/check_worker.py.
//
// No Flutter and no packages: compiled into the windowless separator.
import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';

/// The rate the model was trained at. Everything in here is at this rate.
const modelRate = 44100;

/// What the four channels of the answer are, in order.
const modelSources = ['drums', 'bass', 'other', 'vocals'];

/// The piece of a record the network takes at once: eleven seconds.
const chunkSamples = 485100;

const _nFft = 4096;
const _hop = 1024;
const _bins = _nFft ~/ 2 + 1;

/// SCNet pads each piece so its frame count comes out even (its separation network
/// halves along time). Computed the way it computes it.
int _padFor(int length) {
  var pad = _hop - length % _hop;
  if ((length + pad) ~/ _hop % 2 == 0) pad += _hop;
  return pad;
}

final int _pad = _padFor(chunkSamples);
final int _padded = chunkSamples + _pad;

/// Time frames in one piece's spectrogram.
final int frames = 1 + _padded ~/ _hop;

/// Floats in what goes into the network: two channels, real and imaginary.
final int specInLength = 4 * _bins * frames;

/// Floats in what comes out: four parts × two channels × real and imaginary.
final int specOutLength = 16 * _bins * frames;

/// The shapes ONNX Runtime is told.
List<int> get specInShape => [1, 4, _bins, frames];
List<int> get specOutShape => [1, 4, 4, _bins, frames];

/// The trained network: a spectrogram in ([specInLength] floats), eight spectrograms
/// out ([specOutLength]).
typedef Network = void Function(Float32List specIn, Float32List specOut);

/// The working space for turning spectrograms into sound and back: one per thread.
class Spectra {
  final RealFft _fft = RealFft(_nFft);
  final Float64List _signal = Float64List(_padded + _nFft);
  final Float64List _re = Float64List(_bins), _im = Float64List(_bins);
  final Float64List _frame = Float64List(_nFft);
  final Float64List _sum = Float64List(_nFft + _hop * (frames - 1));

  /// How many frames lie over each sample of the reassembled sound. With no window
  /// this is simply a count, and it is what torch.istft divides by.
  static final Float64List _cover = () {
    final c = Float64List(_nFft + _hop * (frames - 1));
    for (var t = 0; t < frames; t++) {
      for (var j = 0; j < _nFft; j++) {
        c[t * _hop + j] += 1;
      }
    }
    return c;
  }();

  /// One channel ([chunkSamples] of [x]) into its two planes of [specIn].
  void analyse(Float32List x, int channel, Float32List specIn) {
    // Zero-padded to the even frame count, then reflected by half a frame each side:
    // torch.stft(center=True). Reflection leaves the edge sample out — x[1] mirrors
    // to just before x[0] — which is numpy's and torch's 'reflect'.
    const edge = _nFft ~/ 2;
    final s = _signal;
    for (var i = 0; i < _padded; i++) {
      s[edge + i] = i < chunkSamples ? x[i] : 0.0;
    }
    for (var i = 1; i <= edge; i++) {
      s[edge - i] = s[edge + i];
      s[edge + _padded - 1 + i] = s[edge + _padded - 1 - i];
    }
    const norm = 1 / 64; // 1/√4096
    final reAt = channel * 2 * _bins * frames;
    final imAt = (channel * 2 + 1) * _bins * frames;
    for (var t = 0; t < frames; t++) {
      _fft.forward(s, t * _hop, _re, _im);
      for (var f = 0; f < _bins; f++) {
        specIn[reAt + f * frames + t] = _re[f] * norm;
        specIn[imAt + f * frames + t] = _im[f] * norm;
      }
    }
  }

  /// Signal [p] of the network's answer back into sound, [chunkSamples] into [out].
  void synthesise(Float32List specOut, int p, Float32List out) {
    // The answer is (1, 4, 4, bins, frames); read as sixteen planes, plane 2p is the
    // real half of signal p and 2p+1 its imaginary half.
    const unnorm = 64.0; // torch.istft(normalized=True) puts back the 1/√n_fft
    final reAt = 2 * p * _bins * frames;
    final imAt = (2 * p + 1) * _bins * frames;
    final sum = _sum;
    sum.fillRange(0, sum.length, 0);
    for (var t = 0; t < frames; t++) {
      for (var f = 0; f < _bins; f++) {
        _re[f] = specOut[reAt + f * frames + t] * unnorm;
        _im[f] = specOut[imAt + f * frames + t] * unnorm;
      }
      _fft.inverse(_re, _im, _frame, 0);
      final at = t * _hop;
      for (var j = 0; j < _nFft; j++) {
        sum[at + j] += _frame[j];
      }
    }
    const edge = _nFft ~/ 2;
    final cover = _cover;
    for (var i = 0; i < chunkSamples; i++) {
      out[i] = sum[edge + i] / cover[edge + i];
    }
  }
}

/// Turns one eleven-second piece into its four parts, both channels each.
abstract class Piece {
  /// A piece done on this thread alone, calling [network] in the middle.
  factory Piece(Network network, {Float32List? specIn, Float32List? specOut}) =
      _OneThread;

  /// [left] and [right] are [chunkSamples] long. [out] gets eight of the same length:
  /// part `s`, channel `c` at `out[s * 2 + c]`, in [modelSources] order.
  Future<void> separate(Float32List left, Float32List right, List<Float32List> out);
}

class _OneThread implements Piece {
  _OneThread(this.network, {Float32List? specIn, Float32List? specOut})
      : specIn = specIn ?? Float32List(specInLength),
        specOut = specOut ?? Float32List(specOutLength);

  final Network network;
  final Float32List specIn, specOut;
  final Spectra _spectra = Spectra();

  @override
  Future<void> separate(
      Float32List left, Float32List right, List<Float32List> out) async {
    _spectra.analyse(left, 0, specIn);
    _spectra.analyse(right, 1, specIn);
    network(specIn, specOut);
    for (var p = 0; p < 8; p++) {
      _spectra.synthesise(specOut, p, out[p]);
    }
  }
}

/// A stretch of finished sound: the parts, both channels, interleaved, for the
/// samples [from] to `from + length` of the record.
typedef Finished = Future<void> Function(
    int from, int length, List<Float32List> parts);

/// A whole record through [piece], eleven seconds at a time, handed on as it is
/// finished rather than all at the end — twelve minutes of four stereo parts is a
/// gigabyte, and none of it has to be held at once.
///
/// [stereo] is interleaved two-channel floats at [modelRate]. [done] gets the eight
/// separated signals (see [Piece.separate]) a stretch at a time, in order, covering
/// the record exactly once. [progress] hears how far through it is, 0 to 1.
Future<void> demix(Float32List stereo, Piece piece, Finished done,
    {int overlap = 2,
    void Function(double)? progress,
    Float32List? left,
    Float32List? right,
    List<Float32List>? out}) async {
  final length = stereo.length ~/ 2;
  if (length == 0) throw ArgumentError('there is no sound in that');
  const size = chunkSamples;
  final step = size ~/ overlap;
  final border = size - step;
  final fade = size ~/ 10;

  // The ends of the record reflected outwards by a border, so the first and last
  // seconds are separated with music either side of them like every other second.
  // Only on a record long enough to reflect.
  final reflected = length > 2 * border && border > 0;
  final total = reflected ? length + 2 * border : length;
  int source(int i) {
    if (!reflected) return i;
    var o = i - border;
    if (o < 0) o = -o;
    if (o >= length) o = 2 * (length - 1) - o;
    return o;
  }

  // [left], [right] and [out] may be handed in — memory other threads can see.
  left ??= Float32List(size);
  right ??= Float32List(size);
  out ??= List.generate(8, (_) => Float32List(size));
  final sum = List.generate(8, (_) => Float64List(size));
  final weight = Float64List(size);

  double window(int j, {required bool first, required bool last}) {
    if (j < fade && !first) return j / (fade - 1);
    if (j >= size - fade && !last) return 1 - (j - (size - fade)) / (fade - 1);
    return 1;
  }

  var at = 0;
  while (at < total) {
    final have = math.min(size, total - at);
    for (var j = 0; j < have; j++) {
      final o = source(at + j) * 2;
      left[j] = stereo[o];
      right[j] = stereo[o + 1];
    }
    // A short last piece is filled out to the size the network takes: reflected if
    // there is enough of it to reflect, silence if not.
    for (var j = have; j < size; j++) {
      if (have > size ~/ 2) {
        final m = 2 * (have - 1) - j;
        left[j] = left[m];
        right[j] = right[m];
      } else {
        left[j] = 0;
        right[j] = 0;
      }
    }
    await piece.separate(left, right, out);

    final first = at == 0;
    final last = at + step >= total;
    for (var j = 0; j < have; j++) {
      final w = window(j, first: first, last: last);
      weight[j] += w;
      for (var p = 0; p < 8; p++) {
        sum[p][j] += out[p][j] * w;
      }
    }
    final finished = last ? have : step;
    await _handOn(at, finished, sum, weight, reflected ? border : 0, length, done);
    progress?.call(math.min(1.0, (at + finished) / total));
    if (last) break;
    // Slide along: what the next piece overlaps stays, the rest has gone.
    for (var p = 0; p < 8; p++) {
      sum[p].setRange(0, size - step, sum[p], step);
      sum[p].fillRange(size - step, size, 0);
    }
    weight.setRange(0, size - step, weight, step);
    weight.fillRange(size - step, size, 0);
    at += step;
  }
}

Future<void> _handOn(int at, int count, List<Float64List> sum, Float64List weight,
    int border, int length, Finished done) async {
  // From the padded record back to the real one.
  final from = math.max(at - border, 0);
  final to = math.min(at + count - border, length);
  if (to <= from) return;
  final n = to - from;
  final skip = from - (at - border);
  final parts = List.generate(8, (_) => Float32List(n));
  for (var i = 0; i < n; i++) {
    final w = weight[skip + i];
    for (var p = 0; p < 8; p++) {
      final v = w > 0 ? sum[p][skip + i] / w : 0.0;
      parts[p][i] = v.isFinite ? v : 0.0;
    }
  }
  await done(from, n, parts);
}
