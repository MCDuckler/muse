// Where the beats and the bars of a record are, from a trained network.
//
// "Beat This!" (Foscarin, Schlüter, Widmer — ISMIR 2024, MIT; JKU Linz) reads a
// log-mel spectrogram and says, fifty times a second, how much it believes a beat is
// there and how much a bar starts there. It was trained on everything from techno to
// string quartets, and where the arithmetic on the server counts the bar from a guess
// about the bass, this one has heard ten thousand records start their bars. Its beats
// are only as fine as its frames (twenty milliseconds), so the house keeps its own
// exact grid and takes from here what it cannot work out: which beat the bar starts
// on, and beats through the parts of a record where an onset envelope loses them.
//
// The frontend is the model's own (frontend.json beside it: the window and the mel
// filters as exported): 22 050 Hz mono, frames of 1024 under a Hann window every 441
// samples, centred with reflected edges (torch.stft), the magnitude over √1024, 128 mel
// bands, and log1p of a thousand times that. Checked against the reference in
// test/beat_net_test.dart.
//
// Flutter-free: this runs in the windowless separator (bin/wetowl_separate.dart).
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';
import 'ort.dart';

/// The rate the model listens at, and its frames a second.
const beatRate = 22050;
const beatFps = 50;

/// The network's frames a pass: what it was trained on, and what the fixed-shape
/// session is opened with. Consecutive passes overlap by [border] frames, whose
/// answers are taken from whichever pass has them away from its edge.
const beatChunk = 1500;
const beatBorder = 6;

/// The model's frontend, from the JSON beside it.
class BeatFrontend {
  BeatFrontend._(this._window, this._melFrom, this._mel);

  factory BeatFrontend.fromJson(String json) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    if (j['sample_rate'] != beatRate || j['n_fft'] != _nFft || j['hop_length'] != _hop) {
      throw StateError('a frontend this program does not know');
    }
    final window = Float64List.fromList([for (final v in j['window'] as List) (v as num).toDouble()]);
    final filters = j['mel_filters'] as List;
    // Each band is a small triangle over the bins: only its span is kept and summed.
    final from = Int32List(filters.length);
    final rows = <Float64List>[];
    for (var m = 0; m < filters.length; m++) {
      final row = [for (final v in filters[m] as List) (v as num).toDouble()];
      var a = 0;
      while (a < row.length && row[a] == 0) {
        a++;
      }
      var b = row.length;
      while (b > a && row[b - 1] == 0) {
        b--;
      }
      from[m] = a;
      rows.add(Float64List.fromList(row.sublist(a, b)));
    }
    return BeatFrontend._(window, from, rows);
  }

  static const _nFft = 1024;
  static const _hop = 441;
  static const _bins = _nFft ~/ 2 + 1;

  final Float64List _window;
  final Int32List _melFrom;
  final List<Float64List> _mel;
  int get mels => _mel.length;

  /// How many frames [samples] samples make.
  static int framesOf(int samples) => 1 + samples ~/ _hop;

  /// The log-mel spectrogram of [x] (mono, [beatRate]): [framesOf] rows of [mels].
  Float32List logMel(Float32List x) {
    final frames = framesOf(x.length);
    final out = Float32List(frames * mels);
    const edge = _nFft ~/ 2;
    // Reflected by half a frame each side, as torch.stft(center=True) does.
    final padded = Float64List(x.length + 2 * edge);
    for (var i = 0; i < x.length; i++) {
      padded[edge + i] = x[i];
    }
    for (var i = 1; i <= edge; i++) {
      padded[edge - i] = padded[edge + math.min(i, x.length - 1)];
      padded[edge + x.length - 1 + i] = padded[edge + x.length - 1 - math.min(i, x.length - 1)];
    }
    final fft = RealFft(_nFft);
    final frame = Float64List(_nFft);
    final re = Float64List(_bins), im = Float64List(_bins), mag = Float64List(_bins);
    const norm = 1 / 32; // 1/√1024: torchaudio's normalized="frame_length"
    for (var t = 0; t < frames; t++) {
      final at = t * _hop;
      for (var i = 0; i < _nFft; i++) {
        frame[i] = padded[at + i] * _window[i];
      }
      fft.forward(frame, 0, re, im);
      for (var k = 0; k < _bins; k++) {
        mag[k] = math.sqrt(re[k] * re[k] + im[k] * im[k]) * norm;
      }
      for (var m = 0; m < mels; m++) {
        final row = _mel[m];
        final from = _melFrom[m];
        var sum = 0.0;
        for (var k = 0; k < row.length; k++) {
          sum += row[k] * mag[from + k];
        }
        out[t * mels + m] = math.log(1 + 1000.0 * sum);
      }
    }
    return out;
  }
}

/// What the network said about a record: where its beats and its bars are.
class BeatsFound {
  const BeatsFound({required this.beatsMs, required this.downbeatsMs, required this.device});
  final List<int> beatsMs, downbeatsMs;
  final String device;

  Map<String, dynamic> toJson() => {
        'version': 1,
        'model': 'beat-this-final0',
        'fps': beatFps,
        'device': device,
        'beats_ms': beatsMs,
        'downbeats_ms': downbeatsMs,
      };
}

/// The network, open and ready.
class BeatTracker {
  BeatTracker._(this._net, this.frontend);

  static BeatTracker open({
    required String library,
    required String model,
    required BeatFrontend frontend,
    int threads = 4,
    bool cuda = false,
  }) =>
      BeatTracker._(
          OrtNetwork.open(
            library: library,
            model: model,
            inputName: 'spectrogram',
            inputShape: const [1, beatChunk, 128],
            outputName: 'beat',
            outputShape: const [1, beatChunk],
            moreOutputs: const {'downbeat': [1, beatChunk]},
            threads: threads,
            cuda: cuda,
          ),
          frontend);

  final OrtNetwork _net;
  final BeatFrontend frontend;
  String get device => _net.device;
  String? get gpuProblem => _net.gpuProblem;

  /// One pass on silence: what the card's libraries cannot do shows up here rather
  /// than on the first record.
  void warmUp() {
    _net.input.fillRange(0, _net.input.length, 0);
    _net.run();
  }

  /// The beat and downbeat logits for every frame of [spec] ([frames] rows of 128).
  (Float32List, Float32List) logits(Float32List spec, int frames) {
    final beat = Float32List(frames)..fillRange(0, frames, -1000);
    final down = Float32List(frames)..fillRange(0, frames, -1000);
    final done = List<bool>.filled(frames, false);
    final mels = frontend.mels;
    for (var start = -beatBorder; start < frames - beatBorder; start += beatChunk - 2 * beatBorder) {
      final a = math.max(0, start), b = math.min(frames, start + beatChunk);
      _net.input.fillRange(0, _net.input.length, 0);
      _net.input.setRange((a - start) * mels, (a - start) * mels + (b - a) * mels, spec, a * mels);
      _net.run();
      final ob = _net.outputs['beat']!, od = _net.outputs['downbeat']!;
      // Each pass answers for its middle; the first pass to answer a frame keeps it.
      final lo = math.max(0, start + beatBorder), hi = math.min(frames, start + beatChunk - beatBorder);
      for (var f = lo; f < hi; f++) {
        if (done[f]) continue;
        done[f] = true;
        beat[f] = ob[f - start];
        down[f] = od[f - start];
      }
      if (b >= frames) break;
    }
    return (beat, down);
  }

  /// Where the beats and bars of [mono] ([beatRate]) are.
  BeatsFound track(Float32List mono) {
    final frames = BeatFrontend.framesOf(mono.length);
    final spec = frontend.logMel(mono);
    final (beat, down) = logits(spec, frames);
    final beats = peaks(beat);
    final downs = snapToBeats(peaks(down), beats);
    int ms(double frame) => (frame * 1000 / beatFps).round();
    return BeatsFound(
      beatsMs: [for (final b in beats) ms(b)],
      downbeatsMs: [for (final d in downs) ms(d)],
      device: device,
    );
  }

  void close() => _net.close();
}

/// The frames the network is surest of: above zero, the most within ±3 frames, and two
/// side by side taken as one between them (the model's own "minimal" post-processing).
List<double> peaks(Float32List logits, {int width = 7}) {
  final n = logits.length;
  final half = width ~/ 2;
  final found = <List<int>>[];
  for (var i = 0; i < n; i++) {
    final v = logits[i];
    if (v <= 0) continue;
    var top = true;
    for (var j = math.max(0, i - half); j <= math.min(n - 1, i + half); j++) {
      if (logits[j] > v) {
        top = false;
        break;
      }
    }
    if (!top) continue;
    if (found.isNotEmpty && i - found.last.last <= 1) {
      found.last.add(i);
    } else {
      found.add([i]);
    }
  }
  return [for (final g in found) g.fold(0, (a, b) => a + b) / g.length];
}

/// Each downbeat moved onto the beat nearest it, once.
List<double> snapToBeats(List<double> downs, List<double> beats) {
  if (beats.isEmpty) return const [];
  final out = <double>{};
  for (final d in downs) {
    var best = beats.first;
    for (final b in beats) {
      if ((b - d).abs() < (best - d).abs()) best = b;
    }
    out.add(best);
  }
  return out.toList()..sort();
}
