// The sounds the booth makes itself.
//
// Every transition in booth.dart is made of things done *to* the two records: a band
// killed, a filter closed, a loop tightened, an echo opened, a stem handed over. What
// no amount of that can do is *add* anything — and the transitions people know from
// djay's list are mostly additions: the noise that climbs under the last bars before a
// drop (Riser), the whoosh over the change (Sweep), the resonant gush across it
// (Hydrant), the hit on the one. That is sound the DJ brings, not sound the record has.
//
// So the booth makes it. Synthesised rather than sampled, for three reasons: a riser
// has to end *exactly* on the drop, whatever the master's tempo and however many bars
// the move is, and a sample stretched from four seconds to eleven is a different sound;
// nothing has to be licensed, fetched or shipped in the bundle; and a render is a pure
// function of its arguments, so the offline probe measures the same sound the speaker
// gets (tool/booth_probe/fx_sounds.py is this file again in Python, and
// test/fx_sounds_test.dart holds the two to the same numbers).
//
// Everything here is deterministic: the noise is a counter-seeded xorshift, not
// Random(), so the same move rendered twice is the same samples twice.
import 'dart:math' as math;
import 'dart:typed_data';

/// What the booth can play over a transition.
enum FxSound {
  /// The uplifter: band-passed noise climbing from a rumble to a hiss over the whole
  /// of it, gated in a roll that accelerates from eighths to thirty-seconds, with a
  /// tone rising under the last half. Ends dead on its last sample — the silence it
  /// leaves is where the drop goes.
  riser,

  /// A short noise sweep up into the change: the plainest of them, and the one that
  /// fits anywhere.
  sweepUp,

  /// A noise sweep falling away after the change, decaying as it goes. What a DJ
  /// throws behind the first bar of the new record.
  sweepDown,

  /// The gush: a high-resonance band of noise wobbling as it opens and closes, run
  /// through a modulated comb so it comes out metallic and wide. djay calls its own
  /// Hydrant; this is the same idea — a hose held over the change.
  hydrant,

  /// The hit on the one: a sub falling from 140 Hz to the floor under a bright crash.
  impact,
}

extension FxWords on FxSound {
  /// As a person says it.
  String get label => switch (this) {
        FxSound.sweepUp => 'sweep up',
        FxSound.sweepDown => 'sweep down',
        _ => name,
      };
}

/// Where in a transition a sound is played, for how long, and how loud.
///
/// Hung on the step that fires it, and measured the way the rest of a plan is: [span]
/// is a fraction of the *whole move*, so a riser over the last half of it is
/// `FxShot(riser, span: 0.5)` on the step at 0.5 and it ends dead on the move's last
/// beat whatever the tempo or the bar count. A sound whose length is its own and not
/// the move's — the hit on the one — says [beats] instead, in the master's beats.
///
/// [gainDb] is where the sound sits against a record at full level. Every sound is
/// rendered to the same peak, so this is the only dial there is.
class FxShot {
  const FxShot(this.sound, {this.span = 0, this.beats = 0, this.gainDb = -12});

  final FxSound sound;
  final double span;
  final int beats;
  final double gainDb;

  /// The gain as a multiplier.
  double get gain => math.pow(10, gainDb / 20).toDouble();

  /// How long this shot lasts, given the whole [move] and the master's [beat].
  Duration lengthIn(Duration move, Duration beat) => beats > 0
      ? beat * beats
      : Duration(microseconds: (move.inMicroseconds * span).round());

  @override
  String toString() =>
      '${sound.label} ${beats > 0 ? '$beats beats' : '${(span * 100).round()}% of it'} '
      '${gainDb.round()} dB';
}

/// The sample rate everything here is made at — the renderer's, and every deck's.
const fxRate = 44100;

/// [sound] as interleaved stereo floats: [seconds] long, over a record whose beat
/// lasts [beat] seconds (what the gating and the wobble are counted in), peaking at
/// [peak].
///
/// Deterministic, and pure: no clock, no Random, no state kept between calls.
Float32List renderFx(
  FxSound sound, {
  required double seconds,
  required double beat,
  int rate = fxRate,
  double peak = 0.9,
}) {
  final n = math.max(1, (seconds * rate).round());
  final out = Float32List(n * 2);
  switch (sound) {
    case FxSound.riser:
      _riser(out, n, rate, beat);
    case FxSound.sweepUp:
      _sweep(out, n, rate, up: true);
    case FxSound.sweepDown:
      _sweep(out, n, rate, up: false);
    case FxSound.hydrant:
      _hydrant(out, n, rate, beat);
    case FxSound.impact:
      _impact(out, n, rate);
  }
  _edges(out, n, rate);
  _normalise(out, peak);
  return out;
}

// --------------------------------------------------------------------------- parts

/// White noise from a counter: xorshift32 over an index, so sample *i* is the same
/// number whenever it is asked for and two streams seeded apart never correlate.
double _noise(int seed, int i) {
  var x = (seed * 0x9E3779B1 + i * 0x85EBCA77) & 0xFFFFFFFF;
  if (x == 0) x = 0x2545F491;
  x ^= (x << 13) & 0xFFFFFFFF;
  x ^= x >> 17;
  x ^= (x << 5) & 0xFFFFFFFF;
  return (x & 0xFFFFFF) / 0x7FFFFF - 1.0;
}

/// A state-variable filter of the topology-preserving kind, whose cutoff and
/// resonance can be moved every sample without it ringing or blowing up — which a
/// biquad with its coefficients recomputed per sample will do, and a sweep is nothing
/// but moved cutoff.
class _Svf {
  double _ic1 = 0, _ic2 = 0;
  double _g = 0, _k = 0, _a1 = 0, _a2 = 0, _a3 = 0;

  void set(double hz, double q, int rate) {
    final fc = hz.clamp(15.0, rate * 0.45);
    _g = math.tan(math.pi * fc / rate);
    _k = 1 / q.clamp(0.4, 20.0);
    _a1 = 1 / (1 + _g * (_g + _k));
    _a2 = _g * _a1;
    _a3 = _g * _a2;
  }

  /// One sample in; the low-pass, band-pass and high-pass out.
  (double, double, double) step(double x) {
    final v3 = x - _ic2;
    final v1 = _a1 * _ic1 + _a2 * v3;
    final v2 = _ic2 + _a2 * _ic1 + _a3 * v3;
    _ic1 = 2 * v1 - _ic1;
    _ic2 = 2 * v2 - _ic2;
    return (v2, v1, x - _k * v1 - v2);
  }
}

/// Two of those in series, as a band: one alone falls away at only 6 dB an octave
/// either side, so a "band" at 300 Hz still passes most of the hiss above it — a
/// sweep made of one moved from 200 Hz to 9 k barely changed colour at all (measured
/// on the render: the weight of the spectrum went 3976 → 5060 Hz over the first half
/// of an eight-second riser, where the band itself had gone 220 → 1500).
class _Band {
  final _a = _Svf(), _b = _Svf();

  void set(double hz, double q, int rate) {
    _a.set(hz, q, rate);
    _b.set(hz, q, rate);
  }

  double step(double x) {
    final (_, one, _) = _a.step(x);
    final (_, two, _) = _b.step(one);
    return two;
  }
}

/// How loud a signal has been lately, as a one-pole follower on its square — used to
/// divide a swept band back to a flat level, so that the *written* swell is the swell
/// that comes out.
///
/// A band-pass of fixed shape passes far less noise at 220 Hz than at 9 kHz: the
/// riser's level was measured swinging 60 dB over its length where its amplitude law
/// asked for 26, and the first third of it was under -60 dB — inaudible, and then a
/// sound from nowhere. The filter decides the *colour*; the law decides the level.
///
/// [tau] is chosen longer than whatever modulation must survive (the riser's gate) and
/// shorter than the sweep being flattened.
class _Level {
  _Level(double tau, int rate) : _k = 1 - math.exp(-1 / (tau * rate));
  final double _k;
  double _sq = 0;

  /// [x] brought to about unit level, by what the last [tau] of it averaged.
  double flatten(double x) {
    _sq += (x * x - _sq) * _k;
    return x / (math.sqrt(_sq) + 1e-4);
  }
}

/// A delay line of a few milliseconds, read at a moving distance: what makes the
/// hydrant metallic rather than merely noisy.
class _Comb {
  _Comb(int frames) : _buf = Float64List(frames);
  final Float64List _buf;
  int _at = 0;

  /// [x] in, and out the sample [delay] frames back, read between samples.
  double step(double x, double delay) {
    _buf[_at] = x;
    final d = delay.clamp(1.0, _buf.length - 2.0);
    final back = _at - d;
    final i = back.floor();
    final f = back - i;
    final a = _buf[(i % _buf.length + _buf.length) % _buf.length];
    final b = _buf[((i + 1) % _buf.length + _buf.length) % _buf.length];
    _at = (_at + 1) % _buf.length;
    return a + (b - a) * f;
  }
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// [a] to [b] over 0..1, by ear rather than by number: frequency is heard in octaves.
double _glide(double a, double b, double t) => a * math.pow(b / a, t.clamp(0.0, 1.0));

/// A swell or a decay of [db] decibels over 0..1, shaped by [curve] — in decibels,
/// because level is heard that way too. A riser whose amplitude was `t^1.6` was 98 dB
/// down at its start and still 30 down half way through: silence for four bars, and
/// then a sound from nowhere. In decibels it is quiet at the start and *there*.
double _swell(double db, double t, double curve) =>
    math.pow(10, db * (1 - math.pow(t.clamp(0.0, 1.0), curve)) / 20).toDouble();

// -------------------------------------------------------------------------- sounds

/// The uplifter. Three things at once: a band of noise climbing two and a half
/// octaves with its resonance tightening, a roll that gates it faster and faster, and
/// a tone that arrives under the last half and rises with it. The whole lot swells
/// from nothing to full on a curve, so it is barely there for the first bars — a
/// riser that starts loud is a riser nobody can mix under.
void _riser(Float32List out, int n, int rate, double beat) {
  final band = [_Band(), _Band()];
  final cut = [_Svf(), _Svf()];
  // Longer than the slowest gate cycle (half a beat), so the roll survives being
  // flattened; far shorter than the sweep, so the sweep does not.
  final flat = [_Level(0.4, rate), _Level(0.4, rate)];
  var tone = 0.0;
  // The roll's phase, integrated rather than counted: its period shortens as it goes,
  // so a gate placed by "how many have there been" would drift off the beat.
  var roll = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / n;
    final fc = _glide(220, 9000, math.pow(t, 0.85).toDouble());
    final q = _lerp(0.8, 4.0, t);
    // The roll: eighths at the start, thirty-seconds by the end. Each cycle is a
    // decay rather than a square, which is what a filtered noise roll sounds like.
    final period = _glide(beat / 2, beat / 8, math.pow(t, 1.4).toDouble());
    roll += 1 / (period * rate);
    final depth = _lerp(0.75, 0.15, math.pow(t, 0.7).toDouble());
    final gate = 1 - depth * math.pow(roll - roll.floorToDouble(), 0.55);
    // The tone: an octave and a half over the last three fifths, sine, quiet.
    final k = ((t - 0.4) / 0.6).clamp(0.0, 1.0);
    final hz = _glide(330, 2600, math.pow(k, 1.3).toDouble());
    tone += hz / rate;
    final toneAmp = 0.42 * math.pow(k, 2.2);
    // Twenty-six decibels up over the shot: there from the first bar, and four times
    // the sound by the last.
    final swell = _swell(-26, t, 1.15);
    for (var ch = 0; ch < 2; ch++) {
      // The two sides sweep a shade apart, so the noise is wide rather than a point.
      band[ch].set(fc * (ch == 0 ? 0.97 : 1.03), q, rate);
      cut[ch].set(fc * 0.45, 0.7, rate);
      final bp = band[ch].step(_noise(7 + ch, i));
      // The low end kept clear: a riser is not allowed to fight the bass it is
      // building over, and unfiltered noise has a third of its energy down there.
      final (_, _, hp) = cut[ch].step(bp * 5.0);
      final sine = math.sin(2 * math.pi * (tone + ch * 0.12));
      out[i * 2 + ch] = (flat[ch].flatten(hp) * 0.22 * gate + sine * toneAmp) * swell;
    }
  }
}

/// A noise sweep: the band climbs into the change, or falls away from it. Up swells
/// and stops dead on its last sample; down starts full and decays, because that is
/// what each is for.
void _sweep(Float32List out, int n, int rate, {required bool up}) {
  final band = [_Band(), _Band()];
  final cut = [_Svf(), _Svf()];
  // Nothing to preserve here but the sweep itself, so this can be quick.
  final flat = [_Level(0.05, rate), _Level(0.05, rate)];
  for (var i = 0; i < n; i++) {
    final t = i / n;
    final fc = up
        ? _glide(260, 8500, math.pow(t, 0.8).toDouble())
        : _glide(7000, 180, math.pow(t, 0.55).toDouble());
    final q = up ? _lerp(1.1, 3.2, t) : _lerp(2.8, 1.0, t);
    // Up swells twenty-two decibels into the change; down falls thirty-four away
    // from it — both in decibels, so both are a shape rather than a switch.
    final amp = up ? _swell(-22, t, 1.3) : _swell(-34, 1 - t, 1.1);
    for (var ch = 0; ch < 2; ch++) {
      band[ch].set(fc * (ch == 0 ? 0.96 : 1.04), q, rate);
      cut[ch].set(fc * 0.4, 0.7, rate);
      final bp = band[ch].step(_noise(21 + ch, i));
      final (_, _, hp) = cut[ch].step(bp * 5.2);
      out[i * 2 + ch] = flat[ch].flatten(hp) * 0.22 * amp;
    }
  }
}

/// The gush. A high-resonance band of noise whose centre arches up and back down over
/// the shot while wobbling a quarter-note either way, run through a comb of a few
/// milliseconds whose delay moves — the comb is what turns "some noise" into a jet of
/// water, and the two sides wobble in opposite directions so it fills the room.
void _hydrant(Float32List out, int n, int rate, double beat) {
  final band = [_Band(), _Band()];
  final cut = [_Svf(), _Svf()];
  final comb = [_Comb(rate ~/ 100), _Comb(rate ~/ 100)];
  final seconds = n / rate;
  for (var i = 0; i < n; i++) {
    final t = i / n;
    // An arch: up over the first half, back down over the second, so it passes
    // *through* the change rather than pointing at it.
    final arch = math.sin(math.pi * t);
    final base = _glide(850, 5200, math.pow(arch, 0.7).toDouble());
    final wobble = math.sin(2 * math.pi * (i / rate) / (beat * 2));
    final amp = math.pow(arch, 0.65).toDouble();
    for (var ch = 0; ch < 2; ch++) {
      final side = ch == 0 ? 1.0 : -1.0;
      band[ch].set(base * (1 + 0.38 * wobble * side), 4.5, rate);
      cut[ch].set(320, 0.7, rate);
      final bp = band[ch].step(_noise(43 + ch, i));
      final (_, _, hp) = cut[ch].step(bp * 4.4);
      // One to six milliseconds, moved slowly and in antiphase across the two sides.
      final ms = 3.5 + 2.5 * math.sin(2 * math.pi * (i / rate) / math.max(0.8, seconds) + (ch == 0 ? 0 : math.pi));
      out[i * 2 + ch] = (hp + comb[ch].step(hp, ms * rate / 1000) * 0.8) * amp * 0.6;
    }
  }
}

/// The hit: a sub falling out of the bottom of the record under a bright crash, both
/// decaying, both done long before the shot's length is up — what is left is silence
/// on purpose, so the hit is a full stop and not a wash.
void _impact(Float32List out, int n, int rate) {
  final high = [_Svf(), _Svf()];
  final low = [_Svf(), _Svf()];
  var sub = 0.0;
  for (var i = 0; i < n; i++) {
    final s = i / rate;
    final hz = _glide(140, 36, (s / 0.28).clamp(0.0, 1.0));
    sub += hz / rate;
    final boom = math.sin(2 * math.pi * sub) * math.exp(-s * 5.5);
    final crash = math.exp(-s * 3.2);
    for (var ch = 0; ch < 2; ch++) {
      high[ch].set(1400, 0.7, rate);
      // And a lid on it at 9 k: a crash open all the way to Nyquist is a hiss, and
      // the weight of the hit read 9 kHz — the noise, not the boom it is meant to be.
      low[ch].set(9000, 0.7, rate);
      final (_, _, hp) = high[ch].step(_noise(91 + ch, i));
      final (lp, _, _) = low[ch].step(hp);
      out[i * 2 + ch] = boom * 0.95 + lp * crash * 0.3;
    }
  }
}

// -------------------------------------------------------------------------- finish

/// Three milliseconds either end, so a shot that stops at full level — the riser and
/// the sweep up both do, on purpose — stops rather than clicks.
void _edges(Float32List out, int n, int rate) {
  final ramp = math.min(n ~/ 2, (rate * 0.003).round());
  if (ramp <= 0) return;
  for (var i = 0; i < ramp; i++) {
    final g = i / ramp;
    out[i * 2] *= g;
    out[i * 2 + 1] *= g;
    final j = n - 1 - i;
    out[j * 2] *= g;
    out[j * 2 + 1] *= g;
  }
}

/// Every sound brought to the same peak, so [FxShot.gainDb] means the same thing
/// whichever one is played.
void _normalise(Float32List out, double peak) {
  var most = 0.0;
  for (final v in out) {
    final a = v.abs();
    if (a > most) most = a;
  }
  if (most <= 1e-6) return;
  final g = peak / most;
  for (var i = 0; i < out.length; i++) {
    out[i] *= g;
  }
}

/// A rendered sound as a RIFF/WAVE file of sixteen-bit samples — what every engine
/// here can be handed without a decoder of its own.
Uint8List fxWav(Float32List stereo, {int rate = fxRate}) {
  final frames = stereo.length ~/ 2;
  final bytes = frames * 4;
  final b = BytesBuilder(copy: false);
  void str(String s) => b.add(s.codeUnits);
  void u32(int v) => b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) => b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
  str('RIFF');
  u32(36 + bytes);
  str('WAVEfmt ');
  u32(16);
  u16(1); // PCM
  u16(2); // stereo
  u32(rate);
  u32(rate * 4); // bytes a second
  u16(4); // bytes a frame
  u16(16); // bits
  str('data');
  u32(bytes);
  final pcm = Int16List(frames * 2);
  for (var i = 0; i < pcm.length; i++) {
    pcm[i] = (stereo[i].clamp(-1.0, 1.0) * 32767).round();
  }
  b.add(pcm.buffer.asUint8List());
  return b.takeBytes();
}
