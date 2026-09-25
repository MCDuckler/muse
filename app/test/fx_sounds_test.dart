// The booth's own sounds: that each one is the shape it claims to be, and that two
// renders of the same shot are the same samples.
//
// With FX_OUT set, every sound is also written there as a WAV, at the lengths and the
// tempo the probe measures them at (tool/booth_probe): that is how the offline
// renderer gets the same sound the speaker gets without the synthesis being written
// twice and drifting apart.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse/src/state/booth/fx_sounds.dart';

/// The level of [x] over the window from [a] to [b] of it, in decibels.
double _rms(Float32List x, double a, double b) {
  final n = x.length ~/ 2;
  final from = (n * a).round() * 2, to = (n * b).round() * 2;
  var sum = 0.0;
  for (var i = from; i < to; i++) {
    sum += x[i] * x[i];
  }
  final count = math.max(1, to - from);
  return 20 * math.log(math.sqrt(sum / count) + 1e-12) / math.ln10;
}

/// Where the weight of [x] sits in the spectrum over that window, in hertz: a
/// one-block centroid, enough to say "this got brighter" without an FFT library.
double _centroid(Float32List x, double a, double b, {int rate = fxRate}) {
  final n = x.length ~/ 2;
  final from = (n * a).round(), to = (n * b).round();
  // Zero crossings of the mid channel: for noise, the rate is proportional to where
  // the band sits. Crude, exact, and no dependency.
  var crossings = 0;
  var was = 0.0;
  for (var i = from; i < to; i++) {
    final v = x[i * 2] + x[i * 2 + 1];
    if (was <= 0 && v > 0) crossings++;
    was = v;
  }
  final seconds = (to - from) / rate;
  return seconds <= 0 ? 0 : crossings / seconds;
}

void main() {
  const beat = 0.5; // 120 a minute

  test('the same shot renders the same samples', () {
    final a = renderFx(FxSound.riser, seconds: 4, beat: beat);
    final b = renderFx(FxSound.riser, seconds: 4, beat: beat);
    expect(a.length, b.length);
    for (var i = 0; i < a.length; i += 977) {
      expect(a[i], b[i], reason: 'sample $i');
    }
  });

  test('every sound is peaked, finite, and starts and ends at rest', () {
    for (final sound in FxSound.values) {
      final x = renderFx(sound, seconds: 3, beat: beat);
      var most = 0.0;
      for (final v in x) {
        expect(v.isFinite, isTrue, reason: sound.name);
        if (v.abs() > most) most = v.abs();
      }
      expect(most, closeTo(0.9, 0.001), reason: sound.name);
      expect(x.first.abs(), lessThan(0.02), reason: '${sound.name} opens on a step');
      expect(x.last.abs(), lessThan(0.02), reason: '${sound.name} ends on a step');
    }
  });

  test('the riser climbs, in level and in brightness', () {
    final x = renderFx(FxSound.riser, seconds: 8, beat: beat);
    final early = _rms(x, 0.05, 0.2), late = _rms(x, 0.8, 0.98);
    expect(late - early, greaterThan(12), reason: 'swells $early to $late dB');
    expect(_centroid(x, 0.8, 0.98), greaterThan(_centroid(x, 0.05, 0.2) * 3));
    // And it is out of the way of the bass it builds over: the last of it, the
    // loudest, still has nothing much under 200 Hz — a low-passed copy is far down.
    expect(_rms(x, 0.95, 1.0), lessThan(0.0));
  });

  test('the sweeps go opposite ways', () {
    final up = renderFx(FxSound.sweepUp, seconds: 2, beat: beat);
    final down = renderFx(FxSound.sweepDown, seconds: 2, beat: beat);
    expect(_rms(up, 0.7, 0.95), greaterThan(_rms(up, 0.05, 0.3) + 8));
    expect(_rms(down, 0.05, 0.3), greaterThan(_rms(down, 0.7, 0.95) + 8));
    expect(_centroid(up, 0.7, 0.95), greaterThan(_centroid(up, 0.05, 0.3)));
    expect(_centroid(down, 0.7, 0.95), lessThan(_centroid(down, 0.05, 0.3)));
  });

  test('the hydrant arches and the impact decays', () {
    final h = renderFx(FxSound.hydrant, seconds: 2, beat: beat);
    expect(_rms(h, 0.4, 0.6), greaterThan(_rms(h, 0.0, 0.1) + 6));
    expect(_rms(h, 0.4, 0.6), greaterThan(_rms(h, 0.9, 1.0) + 6));
    final i = renderFx(FxSound.impact, seconds: 2, beat: beat);
    expect(_rms(i, 0.0, 0.05), greaterThan(_rms(i, 0.5, 1.0) + 20));
  });

  test('a shot says its gain, and how long it is', () {
    expect(const FxShot(FxSound.riser, span: 1).gain, closeTo(0.251, 0.001));
    expect(const FxShot(FxSound.impact, beats: 8, gainDb: 0).gain, closeTo(1.0, 1e-9));
    const move = Duration(seconds: 16), beat = Duration(milliseconds: 500);
    // A span is of the move: half of sixteen seconds.
    expect(const FxShot(FxSound.sweepUp, span: 0.5).lengthIn(move, beat),
        const Duration(seconds: 8));
    // Beats are the master's, whatever the move is.
    expect(const FxShot(FxSound.impact, beats: 8).lengthIn(move, beat),
        const Duration(seconds: 4));
  });

  test('the wav is a wav', () {
    final w = fxWav(renderFx(FxSound.impact, seconds: 0.5, beat: beat));
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
    expect(w.length, 44 + (fxRate * 0.5).round() * 4);
  });

  test('rendered for the probe', () {
    // The offline renderer asks for the exact sounds a move needs — FX_SPEC is
    // `<sound>:<milliseconds>:<beat ms>`, comma separated — rather than a grid of
    // lengths it would have to stretch. That way the probe measures the samples the
    // speaker gets, and the synthesis is written once.
    final out = Platform.environment['FX_OUT'], spec = Platform.environment['FX_SPEC'];
    if (out == null || spec == null) return;
    Directory(out).createSync(recursive: true);
    for (final one in spec.split(',')) {
      final parts = one.split(':');
      if (parts.length != 3) continue;
      final sound = FxSound.values.firstWhere((s) => s.name == parts[0]);
      final ms = int.parse(parts[1]), beatMs = int.parse(parts[2]);
      final x = renderFx(sound, seconds: ms / 1000, beat: beatMs / 1000);
      File('$out/${sound.name}-${ms}ms-${beatMs}b.wav').writeAsBytesSync(fxWav(x));
    }
  });
}
