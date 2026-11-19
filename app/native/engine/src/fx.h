// rekordbox's effects, made here: its BEAT FX (the DJM-900NXS2's fourteen, the ones
// rekordbox and the DDJ-400 carry), its SOUND COLOR FX (the channel knob's six) and its
// RELEASE FX. Sample by sample, nothing allocated once made (each unit's lines are made
// at init), in time with the beat it is given.
//
// A BEAT FX's LEVEL/DEPTH is its balance of effect and original (and, by effect, its
// depth or feedback); its beats are a fraction of the beat (1/16 … 16) or, for the LFO
// effects, the LFO's cycle. The echoes and reverbs ring out when turned off (their send
// shut, their tail left to fade), the rest let go of the sound at once (a 10 ms fade).
// How each behaves follows the DJM-900NXS2's operating instructions (its effects' table).
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "dsp.h"

namespace we {

enum FxKind {
  kFxDelay = 0, kFxEcho, kFxPingPong, kFxSpiral, kFxReverb, kFxTrans, kFxFilter, kFxFlanger,
  kFxPhaser, kFxPitch, kFxSlipRoll, kFxRoll, kFxVinylBrake, kFxHelix, kFxKinds
};
enum ColorKind { kCfxFilter = 0, kCfxSpace, kCfxDubEcho, kCfxSweep, kCfxNoise, kCfxCrush, kCfxKinds };
enum ReleaseKind { kRfxEcho = 0, kRfxVinylBrake, kRfxBackspin, kRfxKinds };

// The effects that ring out after they are turned off (the DJM manual's: the echoes and
// the reverb leave their sound when the fader comes down).
inline bool spills(int k) {
  return k == kFxDelay || k == kFxEcho || k == kFxPingPong || k == kFxSpiral || k == kFxReverb;
}

// A stereo delay line: written a frame at a time, read any distance back (linear).
struct Line {
  std::vector<float> buf;
  size_t n = 1, w = 0;
  void init(size_t frames) { n = std::max<size_t>(frames, 4); buf.assign(n * 2, 0.f); w = 0; }
  void clear() { std::fill(buf.begin(), buf.end(), 0.f); }
  inline void push(float l, float r) { buf[w * 2] = l; buf[w * 2 + 1] = r; w = (w + 1) % n; }
  // `back` frames before the newest (1: the newest)
  inline float read(int ch, double back) const {
    back = std::clamp(back, 1.0, (double)(n - 2));
    double p = (double)w - back;
    while (p < 0) p += (double)n;
    const size_t a = (size_t)p % n, b = (a + 1) % n;
    const float f = (float)(p - std::floor(p));
    return buf[a * 2 + ch] + (buf[b * 2 + ch] - buf[a * 2 + ch]) * f;
  }
};

// One-pole smoothing toward a target, per sample (`k` of the way each sample).
struct Smooth {
  float now = 0;
  inline float to(float target, float k) { now += (target - now) * k; return now; }
};

// Freeverb's reverb (Jezar's): eight combs, four allpasses a side, the right spread.
struct Reverb {
  static constexpr int kCombs = 8, kAll = 4;
  struct Comb { std::vector<float> b; size_t i = 0; float store = 0; };
  struct All { std::vector<float> b; size_t i = 0; };
  Comb comb[2][kCombs];
  All all[2][kAll];
  float room = 0.84f, damp = 0.25f;
  void init(double rate) {
    static const int cl[kCombs] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
    static const int al[kAll] = {556, 441, 341, 225};
    const double k = rate / 44100.0;
    for (int s = 0; s < 2; s++) {
      for (int c = 0; c < kCombs; c++) { comb[s][c].b.assign((size_t)((cl[c] + 23 * s) * k), 0.f); comb[s][c].i = 0; comb[s][c].store = 0; }
      for (int a = 0; a < kAll; a++) { all[s][a].b.assign((size_t)((al[a] + 23 * s) * k), 0.f); all[s][a].i = 0; }
    }
  }
  void clear() {
    for (auto& s : comb) for (auto& c : s) { std::fill(c.b.begin(), c.b.end(), 0.f); c.store = 0; }
    for (auto& s : all) for (auto& a : s) std::fill(a.b.begin(), a.b.end(), 0.f);
  }
  // A mono send in, a stereo wet out.
  inline void run(float in, float& l, float& r) {
    float out[2] = {0, 0};
    for (int s = 0; s < 2; s++) {
      for (auto& c : comb[s]) {
        float y = c.b[c.i];
        c.store = y * (1 - damp) + c.store * damp;
        c.b[c.i] = in * 0.015f + c.store * room;
        if (++c.i >= c.b.size()) c.i = 0;
        out[s] += y;
      }
      for (auto& a : all[s]) {
        float bo = a.b[a.i];
        a.b[a.i] = out[s] + bo * 0.5f;
        out[s] = bo - out[s];
        if (++a.i >= a.b.size()) a.i = 0;
      }
    }
    l = out[0]; r = out[1];
  }
};

// A pitch shifter of two grains read off a short line, crossfaded (the speed of the read
// against the write is the shift): no time change, a little smear.
struct Shifter {
  Line line;
  double phase = 0, win = 2048;
  void init(double rate) { win = std::round(rate * 0.045); line.init((size_t)win * 3); phase = 0; }
  inline void run(float& l, float& r, double ratio) {
    line.push(l, r);
    phase += (1.0 - ratio) / win;
    phase -= std::floor(phase);
    const double p2 = std::fmod(phase + 0.5, 1.0);
    const float g1 = (float)(1 - std::fabs(2 * phase - 1)), g2 = (float)(1 - std::fabs(2 * p2 - 1));
    const double d1 = 2 + phase * win, d2 = 2 + p2 * win;
    l = line.read(0, d1) * g1 + line.read(0, d2) * g2;
    r = line.read(1, d1) * g1 + line.read(1, d2) * g2;
  }
};

// A first-order allpass (the phaser's stage).
struct AllpassStage {
  float z[2] = {0, 0};
  inline float run(int ch, float x, float a) { float y = -a * x + z[ch]; z[ch] = x + a * y; return y; }
};

// White noise, cheap and the same every time.
struct Noise {
  uint32_t s = 0x9E3779B9u;
  inline float next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return (float)(int32_t)s * (1.0f / 2147483648.0f); }
};

// ------------------------------------------------------------------ BEAT FX
// Pioneer's LEVEL/DEPTH balance (the DJM-900NXS2's manual: "the balance of the original
// and the effect"): the original whole to the middle and gone at the end, the effect
// coming in to the middle and whole from there.
inline float dryOf(float L) { return std::min(1.f, 2.f * (1.f - L)); }
inline float wetOf(float L) { return std::min(1.f, 2.f * L); }

struct BeatFx {
  double rate = 48000;
  int kind = kFxEcho;
  bool on = false, wasOn = false;
  float level = 0.5f, param = 0.5f;
  double beats = 1;
  // send (into the echoes and reverbs), and the effect's presence (the rest)
  Ramp send, mix;
  Smooth lvl, delayFrames, gate;
  Line line, line2;      // delays (16 s); ping pong's right; the reverb's pre-delay
  Line cap;              // roll, vinyl brake: what was played
  std::vector<float> loop;  // the helix's turn
  Reverb reverb;
  Shifter shifter;
  Biquad bq, lowCut;
  AllpassStage ap[6];
  float fbL = 0, fbR = 0;            // the phaser's feedback
  double capRead = 0, capLen = 0, brakeSpeed = 1, lastLen = 0;
  int64_t capWritten = 0;
  double loopPhase = 0, loopTurned = 0;
  size_t loopLen = 0;
  float tail = 0;                    // how loud the wet still is (for "done")
  int bqEvery = 0;
  bool fresh = true;                 // a new effect: its delay time starts where it is

  void init(double r) {
    rate = r;
    line.init((size_t)(r * 16.5)); line2.init((size_t)(r * 16.5));
    cap.init((size_t)(r * 16.5));
    loop.assign((size_t)(r * 16.5) * 2, 0.f);
    reverb.init(r); shifter.init(r);
    lowCut.highpass(200, r);
    send.now = send.target = 0; mix.now = mix.target = 0;
  }
  bool active() const { return on || send.now > 0 || mix.now > 0 || tail > 1e-4f; }

  // `p`: the effect's own (REVERB its amount 0..1; PITCH its pitch, (p × 150 − 50) %).
  void set(int k, bool turnOn, float lv, double b, float p) {
    level = std::clamp(lv, 0.f, 1.f);
    param = std::clamp(p, 0.f, 1.f);
    if (b > 0) beats = std::clamp(b, 1.0 / 16, 64.0);
    if (k >= 0 && k < kFxKinds && k != kind) {
      // another effect: the old one's tail is let go of, its lines cleared
      kind = k;
      tail = 0; line.clear(); line2.clear(); reverb.clear(); fresh = true;
    }
    on = turnOn;
    const int ms10 = (int)(rate * 0.01);
    send.set(on ? 1.f : 0.f, ms10);
    mix.set(on ? 1.f : 0.f, ms10);
  }

  // `beatSec`: a beat now, seconds; `beatPos`: the beats counted at this block's first
  // frame (their phase: TRANS and the LFOs keep to the bar).
  void run(float* lr, int n, double beatSec, double beatPos) {
    if (!active()) { wasOn = false; return; }
    beatSec = std::clamp(beatSec, 0.15, 2.0);
    const double perFrame = 1.0 / (beatSec * rate);   // beats a frame
    const double len = std::max(16.0, beats * beatSec * rate);
    const bool started = on && !wasOn;
    wasOn = on;
    if (started) startCapture(len);
    if (fresh) { fresh = false; delayFrames.now = (float)len; gate.now = 1; }
    // SLIP ROLL takes the sound again when its beats change (ROLL keeps what it took)
    if (on && kind == kFxSlipRoll && std::fabs(len - lastLen) > 1) startCapture(len);
    if (kind == kFxRoll) capLen = len;
    lastLen = len;
    float peak = 0;
    for (int i = 0; i < n; i++) {
      const float x0 = lr[i * 2], x1 = lr[i * 2 + 1];
      const float s = send.next(), m = mix.next();
      const float L = lvl.to(level, 0.002f);
      const double bp = beatPos + perFrame * i;
      // the echoes' own balance: their send shut, the original whole again
      const float dryS = 1 - s * (1 - dryOf(L)), wet = wetOf(L);
      float w0 = x0, w1 = x1;  // the effect's sound, balanced against the original below
      switch (kind) {
        case kFxDelay:
        case kFxEcho: {
          // DELAY one repeat; ECHO repeats fading (a DJM's: about 4.4 dB each)
          const float fb = kind == kFxDelay ? 0.f : 0.6f;
          const float d = delayFrames.to((float)len, 0.0008f);
          const float y0 = line.read(0, d), y1 = line.read(1, d);
          line.push(x0 * s + y0 * fb, x1 * s + y1 * fb);
          lr[i * 2] = x0 * dryS + y0 * wet;
          lr[i * 2 + 1] = x1 * dryS + y1 * wet;
          peak = std::max(peak, std::fabs(y0) + std::fabs(y1));
          continue;
        }
        case kFxPingPong: {
          // left at the beats, right a turn later, across and back, fading
          const float fb = 0.6f;
          const float d = delayFrames.to((float)len, 0.0008f);
          const float yl = line.read(0, d), yr = line2.read(1, d);
          const float mono = 0.5f * (x0 + x1);
          line.push(mono * s + yr * fb, 0);
          line2.push(0, yl);
          lr[i * 2] = x0 * dryS + yl * wet;
          lr[i * 2 + 1] = x1 * dryS + yr * wet;
          peak = std::max(peak, std::fabs(yl) + std::fabs(yr));
          continue;
        }
        case kFxSpiral: {
          // a reverberant echo whose time glides to the beats chosen (its pitch bends as
          // it does); LEVEL/DEPTH its feedback and its balance
          const float fb = 0.5f + 0.47f * L;
          const float d = delayFrames.to((float)len, 0.00015f);
          float y0 = line.read(0, d), y1 = line.read(1, d);
          y0 = ap[0].run(0, y0, 0.6f); y1 = ap[0].run(1, y1, 0.6f);
          y0 = ap[1].run(0, y0, -0.6f); y1 = ap[1].run(1, y1, -0.6f);
          y0 = ap[2].run(0, y0, 0.45f); y1 = ap[2].run(1, y1, 0.45f);
          line.push(x0 * s + y1 * fb, x1 * s + y0 * fb);
          lr[i * 2] = x0 * dryS + y0 * wet;
          lr[i * 2 + 1] = x1 * dryS + y1 * wet;
          peak = std::max(peak, std::fabs(y0) + std::fabs(y1));
          continue;
        }
        case kFxReverb: {
          // its amount (the BEAT buttons, 1–100 %) the room's size; a pre-delay of 15 ms
          // and a low cut on what goes in, the early reflections and the tail
          reverb.room = 0.62f + 0.36f * param;
          reverb.damp = 0.42f - 0.27f * param;
          const float in = lowCut.run(0, 0.5f * (x0 + x1) * s);
          line2.push(in, 0);
          const float pre = line2.read(0, rate * 0.015);
          float rl, rr;
          reverb.run(pre, rl, rr);
          const float e = 0.35f * line2.read(0, rate * 0.023);  // an early reflection
          rl = rl * 2.2f + e; rr = rr * 2.2f + 0.35f * line2.read(0, rate * 0.031);
          lr[i * 2] = x0 * dryS + rl * wet;
          lr[i * 2 + 1] = x1 * dryS + rr * wet;
          peak = std::max(peak, std::fabs(rl) + std::fabs(rr));
          continue;
        }
        case kFxTrans: {
          // cut on the beats: LEVEL/DEPTH the cut's depth, then its length (a fifth of
          // each `beats` to the half)
          const double ph = std::fmod(bp / beats, 1.0);
          const float depth = std::min(1.f, 2 * L), cut = 0.2f + 0.3f * std::max(0.f, 2 * L - 1);
          const float target = ph >= 1.0 - cut ? 1.f - depth : 1.f;
          const float g = gate.to(target, 0.02f);
          w0 = x0 * g; w1 = x1 * g;
          break;
        }
        case kFxFilter: {
          // a resonant low pass swept round every `beats`; LEVEL/DEPTH how far down
          if (bqEvery-- <= 0) {
            bqEvery = 32;
            const double ph = std::fmod(bp / beats, 1.0);
            const double sweep = 0.5 - 0.5 * std::cos(2 * kPi * ph);
            const double f = 18000 * std::pow(120.0 / 18000, sweep * L);
            bq.lowpass(std::min(f, rate * 0.45), rate, 2.2);
          }
          w0 = bq.run(0, x0); w1 = bq.run(1, x1);
          break;
        }
        case kFxFlanger: {
          // a jet: a short delay swept once every `beats`, fed back; LEVEL/DEPTH its depth
          const double ph = std::fmod(bp / beats, 1.0);
          const double d = (0.0004 + 0.0065 * (0.5 - 0.5 * std::cos(2 * kPi * ph))) * rate;
          const float y0 = line.read(0, d), y1 = line.read(1, d);
          line.push(x0 + y0 * 0.65f, x1 + y1 * 0.65f);
          const float k = 0.55f * L;
          w0 = x0 * (1 - k) + y0 * k * 0.75f; w1 = x1 * (1 - k) + y1 * k * 0.75f;
          break;
        }
        case kFxPhaser: {
          const double ph = std::fmod(bp / beats, 1.0);
          const double f = 200 * std::pow(15.0, 0.5 - 0.5 * std::cos(2 * kPi * ph));
          const double t = std::tan(kPi * f / rate);
          const float a = (float)((t - 1) / (t + 1));
          float y0 = x0 + fbL * 0.55f, y1 = x1 + fbR * 0.55f;
          for (auto& st : ap) { y0 = st.run(0, y0, a); y1 = st.run(1, y1, a); }
          fbL = y0; fbR = y1;
          const float k = 0.5f * L;
          w0 = x0 * (1 - k) + y0 * k; w1 = x1 * (1 - k) + y1 * k;
          break;
        }
        case kFxPitch: {
          // its pitch the BEAT buttons' (−50 … +100 %), LEVEL/DEPTH how much of it: none
          // at the left
          const double pct = param * 150.0 - 50.0;
          const double ratio = std::max(0.25, 1.0 + pct / 100.0 * L);
          shifter.run(w0, w1, ratio);
          // near no shift, the original itself (the shifter's grains lag it a little)
          const float k = m * (float)std::clamp(std::fabs(ratio - 1) * 25, 0.0, 1.0);
          lr[i * 2] = x0 * (1 - k) + w0 * k;
          lr[i * 2 + 1] = x1 * (1 - k) + w1 * k;
          continue;
        }
        case kFxSlipRoll:
        case kFxRoll: {
          // what was played from the moment it went on, round again every `beats`
          cap.push(x0, x1); capWritten++;
          const double turn = std::max(16.0, capLen);
          const double into = std::fmod((double)capWritten - 1, turn);
          const double back = (double)capWritten - into;
          const float r0 = cap.read(0, back), r1 = cap.read(1, back);
          w0 = x0 * dryOf(L) + r0 * wetOf(L); w1 = x1 * dryOf(L) + r1 * wetOf(L);
          break;
        }
        case kFxVinylBrake: {
          // the sound slows over `beats` to the speed LEVEL/DEPTH asks (to a stop at the
          // right, back up to the record's own at the left)
          cap.push(x0, x1); capWritten++;
          const double target = 1.0 - L, by = 1.0 / std::max(1.0, len);
          brakeSpeed += std::clamp(target - brakeSpeed, -by, by);
          capRead += brakeSpeed;
          const double lag = (double)capWritten - capRead;
          const float slow = (float)std::clamp((1 - brakeSpeed) * 12, 0.0, 1.0);
          if (slow <= 0 && lag > 0) capRead = (double)capWritten;  // back up to speed: caught up
          const float fade = (float)std::min(1.0, brakeSpeed * 10);
          const float b0 = cap.read(0, std::max(1.0, lag)) * fade, b1 = cap.read(1, std::max(1.0, lag)) * fade;
          w0 = x0 * (1 - slow) + b0 * slow; w1 = x1 * (1 - slow) + b1 * slow;
          break;
        }
        case kFxHelix: {
          // what was playing caught and held, round and round; new beats play the turn
          // faster or slower (its pitch with it); LEVEL/DEPTH how much new sound goes into
          // it (the right: none, held as it is), and its balance
          const double step = (double)loopLen / std::max(16.0, len);
          size_t at = (size_t)loopPhase % std::max<size_t>(loopLen, 1);
          const float o0 = loop[at * 2], o1 = loop[at * 2 + 1];
          const bool first = loopTurned < (double)loopLen;
          const float keep = first ? 0.f : L, in = first ? 1.f : (1 - L);
          if (on) { loop[at * 2] = o0 * keep + x0 * in; loop[at * 2 + 1] = o1 * keep + x1 * in; }
          loopPhase += step; loopTurned += step;
          if (loopPhase >= (double)loopLen) loopPhase -= (double)loopLen;
          const float h0 = first ? x0 : o0, h1 = first ? x1 : o1;
          w0 = x0 * dryOf(L) + h0 * wetOf(L); w1 = x1 * dryOf(L) + h1 * wetOf(L);
          break;
        }
        default: break;
      }
      lr[i * 2] = x0 * (1 - m) + w0 * m;
      lr[i * 2 + 1] = x1 * (1 - m) + w1 * m;
    }
    tail = spills(kind) ? std::max(peak, tail * 0.9f) : 0.f;
  }

  void startCapture(double len) {
    capLen = len; capWritten = 0; capRead = 0; brakeSpeed = 1;
    cap.clear();
    loopLen = std::min((size_t)len, loop.size() / 2); loopPhase = 0; loopTurned = 0;
    delayFrames.now = (float)len;
  }
};

// ------------------------------------------------------------------ SOUND COLOR FX
// The channel's knob: the middle nothing, either way more of the effect, each way its own
// flavour, as the DJM-900NXS2's manual has them:
//   SPACE     reverb: left on the lows and mids, right on the mids and highs; PARAMETER its
//             feedback (the tail's length)
//   DUB ECHO  an echo fading: left on the mids alone, right on the highs alone; PARAMETER
//             its feedback
//   SWEEP     left a gate (tighter, quieter; PARAMETER tighter still), right a band pass
//             narrowing (PARAMETER its centre, higher to the right)
//   NOISE     white noise in through a filter (left its low pass closing, right its high
//             pass opening; the record itself untouched); PARAMETER its volume
//   CRUSH     left more distortion; right crushed, then through a high pass opening;
//             PARAMETER more of it
struct ColorFx {
  double rate = 48000;
  int kind = kCfxFilter;
  float knob = 0, param = 0.5f;
  Reverb reverb;
  Line line;
  Biquad sendLo, sendHi, loopLo, loopHi, bp, noiseF, hp;
  Noise noise;
  Smooth amt, env, hold;
  float crushHold[2] = {0, 0};
  int crushCount = 0;
  float tail = 0;
  int every = 0;
  void init(double r) { rate = r; reverb.init(r); line.init((size_t)(r * 2.5)); }
  void setKind(int k, float p) {
    p = std::clamp(p, 0.f, 1.f);
    if (k != kind && k >= 0 && k < kCfxKinds) { kind = k; reverb.clear(); line.clear(); tail = 0; }
    param = p;
  }
  // Something to do: turned, or still easing back, or still ringing (a stopped deck's
  // channel runs on for it: a DJM's NOISE is heard with no music under it too).
  bool busy() const { return kind != kCfxFilter && (std::fabs(knob) >= 0.02f || tail >= 1e-4f || amt.now >= 1e-3f); }
  void run(float* lr, int n, double beatSec) {
    if (kind == kCfxFilter) return;
    const float a = std::fabs(knob);
    if (a < 0.02f && tail < 1e-4f && amt.now < 1e-3f) return;
    const bool left = knob < 0;
    float peak = 0;
    switch (kind) {
      case kCfxSpace: {
        reverb.room = 0.7f + 0.28f * param;
        reverb.damp = 0.3f;
        if (left) { sendLo.lowpass(2500, rate); sendHi.highpass(80, rate); }
        else { sendLo.lowpass(16000, rate); sendHi.highpass(600, rate); }
        for (int i = 0; i < n; i++) {
          const float s = amt.to(a, 0.003f);
          const float in = sendHi.run(0, sendLo.run(0, 0.5f * (lr[i * 2] + lr[i * 2 + 1]) * s));
          float rl, rr;
          reverb.run(in, rl, rr);
          lr[i * 2] += rl * 2.4f; lr[i * 2 + 1] += rr * 2.4f;
          peak = std::max(peak, std::fabs(rl));
        }
        break;
      }
      case kCfxDubEcho: {
        const double d = std::clamp(beatSec, 0.15, 2.0) * 0.75 * rate;
        if (left) { sendLo.lowpass(2500, rate); sendHi.highpass(300, rate); }
        else { sendLo.lowpass(18000, rate); sendHi.highpass(2500, rate); }
        loopLo.lowpass(left ? 2200 : 12000, rate); loopHi.highpass(left ? 350 : 2000, rate);
        const float fb = 0.45f + 0.45f * param;
        for (int i = 0; i < n; i++) {
          const float s = amt.to(a, 0.003f);
          const float y0 = line.read(0, d), y1 = line.read(1, d);
          const float in0 = sendHi.run(0, sendLo.run(0, lr[i * 2] * s)), in1 = sendHi.run(1, sendLo.run(1, lr[i * 2 + 1] * s));
          line.push(in0 + loopHi.run(0, loopLo.run(0, y0)) * fb, in1 + loopHi.run(1, loopLo.run(1, y1)) * fb);
          lr[i * 2] += y0 * 1.3f; lr[i * 2 + 1] += y1 * 1.3f;
          peak = std::max(peak, std::fabs(y0));
        }
        break;
      }
      case kCfxSweep: {
        if (!left) {
          // a band, narrower the further, around a centre the PARAMETER sets
          const double fc = 150 * std::pow(60.0, (double)param);
          for (int i = 0; i < n; i++) {
            const float m = amt.to(a, 0.003f);
            if (every-- <= 0) { every = 32; bp.lowpass(std::min(fc, rate * 0.45), rate, 0.7 + 9.0 * m * m); hp.highpass(fc * (0.25 + 0.7 * m), rate, 0.7 + 2.0 * m); }
            const float b0 = hp.run(0, bp.run(0, lr[i * 2])), b1 = hp.run(1, bp.run(1, lr[i * 2 + 1]));
            lr[i * 2] = lr[i * 2] * (1 - m) + b0 * m;
            lr[i * 2 + 1] = lr[i * 2 + 1] * (1 - m) + b1 * m;
          }
        } else {
          // a gate: what falls under a threshold (higher the further, and with the
          // PARAMETER) goes quiet; the rest a little quieter too
          const float th = 0.01f + (0.05f + 0.35f * param) * a * a;
          for (int i = 0; i < n; i++) {
            const float m = amt.to(a, 0.003f);
            const float e = env.to(std::max(std::fabs(lr[i * 2]), std::fabs(lr[i * 2 + 1])), 0.02f);
            const float g = hold.to(e > th ? 1.f : 0.f, e > th ? 0.08f : 0.004f);
            const float k = (1 - m + m * g) * (1 - 0.15f * m);
            lr[i * 2] *= k; lr[i * 2 + 1] *= k;
          }
        }
        break;
      }
      case kCfxNoise: {
        for (int i = 0; i < n; i++) {
          const float m = amt.to(a, 0.003f);
          if (every-- <= 0) {
            every = 32;
            if (left) noiseF.lowpass(18000 * std::pow(80.0 / 18000, (double)m), rate, 1.2);
            else noiseF.highpass(30 * std::pow(12000.0 / 30, (double)m), rate, 1.2);
          }
          const float v = std::min(1.f, m * 6) * (0.03f + 0.25f * param);
          const float z0 = noiseF.run(0, noise.next()) * v, z1 = noiseF.run(1, noise.next()) * v;
          lr[i * 2] += z0; lr[i * 2 + 1] += z1;
        }
        break;
      }
      case kCfxCrush: {
        // fewer bits, a lower rate, a little drive: further, and with the PARAMETER, more
        const float k = a * (0.4f + 0.6f * param);
        const float q = std::pow(2.f, 15 - 12 * k);
        const int hold = 1 + (int)(k * 14);
        if (!left) hp.highpass(40 * std::pow(100.0, (double)a), rate, 0.9);
        for (int i = 0; i < n; i++) {
          if (crushCount-- <= 0) {
            crushCount = hold - 1;
            for (int ch = 0; ch < 2; ch++) {
              const float x = std::tanh(lr[i * 2 + ch] * (1 + 3 * k)) / std::tanh(1 + 3 * k);
              crushHold[ch] = std::round(x * q) / q;
            }
          }
          const float m = amt.to(a, 0.003f);
          float c0 = crushHold[0], c1 = crushHold[1];
          if (!left) { c0 = hp.run(0, c0); c1 = hp.run(1, c1); }
          lr[i * 2] = lr[i * 2] * (1 - m) + c0 * m;
          lr[i * 2 + 1] = lr[i * 2 + 1] * (1 - m) + c1 * m;
        }
        break;
      }
      default: break;
    }
    tail = std::max(peak, tail * 0.9f);
  }
};

// ------------------------------------------------------------------ RELEASE FX
// Held: the effect over the sound and the original let go of; let go of: the original
// back. ECHO leaves the last beat ringing as the sound drops away; VINYL BRAKE stops it;
// BACKSPIN spins it back.
struct ReleaseFx {
  double rate = 48000;
  int kind = kRfxEcho;
  bool on = false, wasOn = false;
  double beats = 1;
  Line line, cap;
  Ramp dry;
  double speed = 1, read = 0;
  int64_t written = 0;
  float tail = 0;
  void init(double r) { rate = r; line.init((size_t)(r * 16.5)); cap.init((size_t)(r * 16.5)); dry.now = dry.target = 1; }
  bool active() const { return on || dry.now < 1 || tail > 1e-4f; }
  void set(int k, bool hold, double b) {
    if (k >= 0 && k < kRfxKinds) kind = k;
    if (b > 0) beats = std::clamp(b, 1.0 / 16, 16.0);
    on = hold;
    dry.set(hold ? 0.f : 1.f, (int)(rate * (hold ? 0.004 : 0.01)));
  }
  void run(float* lr, int n, double beatSec) {
    // the capture runs always, so a release has what was just played to work on
    const double len = std::max(16.0, beats * std::clamp(beatSec, 0.15, 2.0) * rate);
    const bool started = on && !wasOn;
    wasOn = on;
    if (started) { speed = kind == kRfxBackspin ? -2.5 : 1; read = 0; written = 0; }
    float peak = 0;
    for (int i = 0; i < n; i++) {
      const float x0 = lr[i * 2], x1 = lr[i * 2 + 1];
      cap.push(x0, x1);
      const float dr = dry.next();
      float w0 = 0, w1 = 0;
      if (kind == kRfxEcho) {
        // the line keeps the last `beats` of the sound; held, it repeats them (no new
        // sound in) as the sound drops away; let go of, the repeats ring out
        const float y0 = line.read(0, len), y1 = line.read(1, len);
        const bool ringing = on || tail > 1e-3f;
        if (ringing) {
          line.push(y0 * 0.62f, y1 * 0.62f);
          w0 = y0; w1 = y1;
          peak = std::max(peak, std::fabs(y0) + std::fabs(y1));
        } else {
          line.push(x0, x1);
        }
      } else if (on) {
        written++;
        if (kind == kRfxVinylBrake) speed = std::max(0.0, speed - 1.0 / len);
        else speed = std::min(0.0, speed + 2.5 / len);  // the backspin slows to rest
        read += speed;
        const double back = (double)written - read;
        const float fade = (float)std::min(1.0, std::fabs(speed) * 8);
        w0 = cap.read(0, back) * fade; w1 = cap.read(1, back) * fade;
      }
      const float wet = 1 - dr;
      lr[i * 2] = x0 * dr + w0 * (kind == kRfxEcho ? 1.f : wet);
      lr[i * 2 + 1] = x1 * dr + w1 * (kind == kRfxEcho ? 1.f : wet);
    }
    tail = kind == kRfxEcho && (on || tail > 1e-3f) ? std::max(peak, tail * 0.9f) : 0.f;
  }
};

}  // namespace we
