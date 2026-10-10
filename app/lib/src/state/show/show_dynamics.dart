// The dynamics: the record's sound turned into things a picture can answer.
//
// A band's level, read raw off the pulse, is a poor thing to drive a picture with:
// a kick is a soft bump in it, a breakdown drops it to nothing so the room goes
// dark, a loud record pins it. What a VJ's eye answers to is *change* — the hit,
// not the level — judged against what came just before. So, per band, each frame:
//
//   fast     the level with an instant attack and a short release, so a hit is a
//            spike and not a smear;
//   slow     its average over the last second or two: the floor the hit stands on;
//   peak     its loudest over the last seconds, decaying: the record's own scale,
//            so a quiet passage reacts as much as a loud one (adaptive gain);
//   hit      how far the level just leapt above the floor, against the peak — 0 to
//            1 — and an envelope on it that snaps to 1 on a leap and falls in
//            150–250 ms, which is what a flash should do.
//
// And from the grid, exactly, with no audio in it: ramps and decays for the beat,
// the bar and the phrase, so rhythmic motion is on the grid whatever the record
// does; and an exposure that follows the loudness slowly, so a drop is bright and
// a breakdown still shows.
//
// Everything lands in the frame as `dyn.*` (ShowState.dyn), and from there in the
// shaders' common block.
import 'dart:math' as math;

import 'show_state.dart';

class _Follower {
  double fast = 0, slow = 0, peak = 0.3, trough = 0, hit = 0, lastRaw = 0;

  /// [v] the band now, [dt] seconds, [release] of the fast follower, [fall] of
  /// the hit envelope.
  void feed(double v, double dt, {double release = 0.12, double fall = 0.2, double sensitivity = 1.0}) {
    if (v >= fast) {
      fast = v;
    } else {
      fast += (v - fast) * (1 - math.exp(-dt / release));
    }
    slow += (v - slow) * (1 - math.exp(-dt / 1.4));
    // The peak decays over about six seconds, and never under a floor: silence
    // must not make the next whisper a shout.
    peak = math.max(math.max(peak * math.exp(-dt / 6.0), 0.12), v);
    // And the trough: the quietest it gets between hits, rising slowly, so the
    // band is read as where the level sits between its own floor and its own
    // ceiling — a steady kick pattern swings it 0..1 on every beat.
    trough = math.min(trough + (peak - trough) * (1 - math.exp(-dt / 3.0)), v);
    // The leap: how far above the floor, against the record's scale, and only on
    // the way up — a level that stays high is one hit, not a hundred.
    final rising = v > lastRaw + 0.02;
    final leap = math.max(0.0, v - slow * 1.1) / peak * sensitivity;
    if (rising && leap > 0.18) {
      hit = math.max(hit, leap.clamp(0.0, 1.0));
    } else {
      hit *= math.exp(-dt / fall);
    }
    lastRaw = v;
  }

  double get gain => ((fast - trough) / math.max(peak - trough, 0.05)).clamp(0.0, 1.0);
}

class ShowDynamics {
  final _sub = _Follower(), _low = _Follower(), _mid = _Follower(), _high = _Follower(), _air = _Follower();
  final _kick = _Follower(), _onset = _Follower();
  double _loud = 0, _exposure = 0.7, _energy = 0;

  /// One frame: the `dyn.*` for [st], [dt] seconds after the last.
  Map<String, double> frame(ShowState st, double dt) {
    dt = dt.clamp(1 / 240, 0.1);
    final a = st.audio;
    _sub.feed(a.sub, dt, release: 0.15);
    _low.feed(a.low, dt, release: 0.14);
    _mid.feed(a.mid, dt, release: 0.1);
    _high.feed(a.high, dt, release: 0.08);
    _air.feed(a.air, dt, release: 0.06);
    _kick.feed(a.kick, dt, release: 0.1, fall: 0.18, sensitivity: 1.3);
    _onset.feed(a.onset, dt, release: 0.08, fall: 0.15);

    // The kick hit: the kick channel's leap, backed by the bass; the snare's from
    // the middle; the top's from the air and the highs.
    final kickHit = math.max(_kick.hit, math.min(_sub.hit, _low.hit) * 0.8);
    final snareHit = math.max(_mid.hit, _onset.hit * 0.7) * (1 - kickHit * 0.5);
    final topHit = math.max(_air.hit, _high.hit * 0.8);

    // The loudness, and an exposure that follows it: up in a third of a second,
    // down in two, so a drop lights the room and a breakdown dims it but not to
    // nothing.
    final loud = (a.sub * 0.3 + a.low * 0.35 + a.mid * 0.25 + a.high * 0.1);
    final tauL = loud > _loud ? 0.3 : 2.0;
    _loud += (loud - _loud) * (1 - math.exp(-dt / tauL));
    final want = 0.45 + 0.65 * (_loud / math.max(0.15, math.max(_low.peak, _mid.peak)));
    _exposure += (want.clamp(0.35, 1.2) - _exposure) * (1 - math.exp(-dt / 0.4));
    final m = st.master;
    final energy = (m.energy * (0.4 + 0.6 * m.level)).clamp(0.0, 1.0);
    _energy += (energy - _energy) * (1 - math.exp(-dt / 0.8));

    // The grid's own ramps and decays: exact.
    final beat = m.beatPhase, bar = m.barPhase, phrase = m.phrasePhase;
    final inBar = m.beatInBar ?? 0;
    return {
      'dyn.hit.kick': kickHit,
      'dyn.hit.snare': snareHit,
      'dyn.hit.top': topHit,
      'dyn.hit.any': math.max(kickHit, math.max(snareHit, topHit)),
      'dyn.band.sub': _sub.gain,
      'dyn.band.low': _low.gain,
      'dyn.band.mid': _mid.gain,
      'dyn.band.high': _high.gain,
      'dyn.band.air': _air.gain,
      'dyn.loud': _loud,
      'dyn.exposure': _exposure,
      'dyn.energy': _energy,
      'dyn.beat.saw': beat,
      'dyn.beat.decay': m.playing ? math.exp(-beat * 6) : 0,
      'dyn.beat.pulse': m.playing ? math.pow(math.max(0, math.cos(beat * math.pi)), 3).toDouble() : 0,
      'dyn.half.saw': ((inBar % 2) + beat) / 2,
      'dyn.bar.saw': bar,
      'dyn.bar.decay': m.playing ? math.exp(-bar * 5) : 0,
      'dyn.phrase.saw': phrase,
      'dyn.phrase.decay': m.playing ? math.exp(-phrase * 4) : 0,
      'dyn.downbeat': m.playing && inBar == 0 ? math.exp(-beat * 6) : 0,
    };
  }
}
