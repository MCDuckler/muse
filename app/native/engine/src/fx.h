// rekordbox's effects, made here: its BEAT FX (the DJM-900NXS2's fourteen, the ones
// rekordbox and the DDJ-400 carry), its SOUND COLOR FX (the channel knob's six) and its
// RELEASE FX. Sample by sample, nothing allocated once made (each unit's lines are made
// at init), in time with the beat it is given.
//
// A BEAT FX's LEVEL/DEPTH is its balance of effect and original (and, by effect, its
// depth or feedback); its beats are a fraction of the beat (1/16 … 16) or, for the LFO
// effects, the LFO's cycle. The echoes and reverbs ring out when turned off (their send
// shut, their tail left to fade), the rest let go of the sound at once (a 10 ms fade).
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

// The effects that ring out after they are turned off.
inline bool spills(int k) {
  return k == kFxDelay || k == kFxEcho || k == kFxPingPong || k == kFxSpiral || k == kFxReverb || k == kFxHelix;
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
struct BeatFx {
  double rate = 48000;
  int kind = kFxEcho;
  bool on = false, wasOn = false;
  float level = 0.5f, param = 0.5f;
  double beats = 1;
  // send (into the echoes and reverbs), and the effect's presence (the rest)
  Ramp send, mix;
  Smooth lvl, delayFrames;
  Line line, line2;      // delays (16 s), the second for ping pong / the spiral's diffusion
  Line cap;              // roll, helix, vinyl brake: what was played
  Reverb reverb;
  Shifter shifter;
  Biquad bq;
  AllpassStage ap[6];
  float fbL = 0, fbR = 0;            // the phaser's feedback
  double capRead = 0, capLen = 0, brakeSpeed = 1;
  int64_t capWritten = 0;
  float tail = 0;                    // how loud the wet still is (for "done")
  int bqEvery = 0;
  bool fresh = true;                 // a new effect: its delay time starts where it is

  void init(double r) {
    rate = r;
    line.init((size_t)(r * 16.5)); line2.init((size_t)(r * 16.5));
    cap.init((size_t)(r * 16.5));
    reverb.init(r); shifter.init(r);
    send.now = send.target = 0; mix.now = mix.target = 0;
  }
  bool active() const { return on || send.now > 0 || mix.now > 0 || tail > 1e-4f; }

  void set(int k, bool turnOn, float lv, double b, float p) {
    level = std::clamp(lv, 0.f, 1.f);
    param = std::clamp(p, 0.f, 1.f);
    if (b > 0) beats = std::clamp(b, 1.0 / 16, 64.0);
    if (k >= 0 && k < kFxKinds && k != kind) {
      // another effect: the old one's tail is let go of (a short fade), lines cleared
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
    if (fresh) { fresh = false; delayFrames.now = kind == kFxTrans ? 1.f : (float)len; }
    float peak = 0;
    for (int i = 0; i < n; i++) {
      const float x0 = lr[i * 2], x1 = lr[i * 2 + 1];
      const float s = send.next(), m = mix.next();
      const float L = lvl.to(level, 0.002f);
      const double bp = beatPos + perFrame * i;
      float w0 = x0, w1 = x1;  // the effect's sound
      switch (kind) {
        case kFxDelay:
        case kFxEcho: {
          const float fb = kind == kFxDelay ? 0.f : 0.42f + 0.38f * L;
          const float d = delayFrames.to((float)len, 0.0008f);
          const float y0 = line.read(0, d), y1 = line.read(1, d);
          line.push(x0 * s + y0 * fb, x1 * s + y1 * fb);
          lr[i * 2] = x0 * (1 - 0.35f * L * s) + y0 * L;
          lr[i * 2 + 1] = x1 * (1 - 0.35f * L * s) + y1 * L;
          peak = std::max(peak, std::fabs(y0) + std::fabs(y1));
          continue;
        }
        case kFxPingPong: {
          const float fb = 0.45f + 0.35f * L;
          const float d = delayFrames.to((float)len, 0.0008f);
          const float yl = line.read(0, d), yr = line2.read(1, d);
          const float mono = 0.5f * (x0 + x1);
          line.push(mono * s + yr * fb, 0);
          line2.push(0, yl);
          lr[i * 2] = x0 * (1 - 0.35f * L * s) + yl * L;
          lr[i * 2 + 1] = x1 * (1 - 0.35f * L * s) + yr * L;
          peak = std::max(peak, std::fabs(yl) + std::fabs(yr));
          continue;
        }
        case kFxSpiral: {
          // an echo whose time glides to the beat chosen (its pitch bends as it does),
          // smeared each pass: the repeats swirl into a wash
          const float fb = 0.6f + 0.33f * L;
          const float d = delayFrames.to((float)len, 0.00015f);
          float y0 = line.read(0, d), y1 = line.read(1, d);
          const float a = 0.55f;
          y0 = ap[0].run(0, y0, a); y1 = ap[0].run(1, y1, a);
          y0 = ap[1].run(0, y0, -a); y1 = ap[1].run(1, y1, -a);
          line.push(x0 * s + y1 * fb, x1 * s + y0 * fb);
          lr[i * 2] = x0 * (1 - 0.35f * L * s) + y0 * L;
          lr[i * 2 + 1] = x1 * (1 - 0.35f * L * s) + y1 * L;
          peak = std::max(peak, std::fabs(y0) + std::fabs(y1));
          continue;
        }
        case kFxReverb: {
          reverb.room = 0.70f + 0.28f * param;
          float rl, rr;
          reverb.run(0.5f * (x0 + x1) * s, rl, rr);
          lr[i * 2] = x0 * (1 - 0.4f * L * s) + rl * L * 1.4f;
          lr[i * 2 + 1] = x1 * (1 - 0.4f * L * s) + rr * L * 1.4f;
          peak = std::max(peak, std::fabs(rl) + std::fabs(rr));
          continue;
        }
        case kFxTrans: {
          // cut in time: on for the first half of each `beats`, off for the rest
          const double ph = std::fmod(bp / beats, 1.0);
          const float target = (ph < 0.5) ? 1.f : 1.f - L;
          const float g = delayFrames.to(target, 0.02f);
          w0 = x0 * g; w1 = x1 * g;
          break;
        }
        case kFxFilter: {
          if (bqEvery-- <= 0) {
            bqEvery = 32;
            const double ph = std::fmod(bp / beats, 1.0);
            const double sweep = 0.5 - 0.5 * std::cos(2 * kPi * ph);
            const double f = 250 * std::pow(40.0, sweep);  // 250 Hz … 10 kHz
            bq.lowpass(std::min(f, rate * 0.45), rate, 0.9 + 5.0 * L);
          }
          w0 = bq.run(0, x0); w1 = bq.run(1, x1);
          break;
        }
        case kFxFlanger: {
          const double ph = std::fmod(bp / beats, 1.0);
          const double d = (0.0006 + 0.0045 * (0.5 - 0.5 * std::cos(2 * kPi * ph))) * rate;
          const float fb = 0.35f + 0.5f * L;
          const float y0 = line.read(0, d), y1 = line.read(1, d);
          line.push(x0 + y0 * fb, x1 + y1 * fb);
          w0 = 0.6f * (x0 + y0); w1 = 0.6f * (x1 + y1);
          break;
        }
        case kFxPhaser: {
          const double ph = std::fmod(bp / beats, 1.0);
          const double f = 300 * std::pow(8.0, 0.5 - 0.5 * std::cos(2 * kPi * ph));
          const double t = std::tan(kPi * f / rate);
          const float a = (float)((t - 1) / (t + 1));
          const float fb = 0.2f + 0.55f * L;
          float y0 = x0 + fbL * fb, y1 = x1 + fbR * fb;
          for (auto& st : ap) { y0 = st.run(0, y0, a); y1 = st.run(1, y1, a); }
          fbL = y0; fbR = y1;
          w0 = 0.6f * (x0 + y0); w1 = 0.6f * (x1 + y1);
          break;
        }
        case kFxPitch: {
          // LEVEL/DEPTH is the pitch: the middle none, an octave down to an octave up
          const float k = (L - 0.5f) * 2;
          const double semis = std::fabs(k) < 0.03f ? 0.0 : 12.0 * k;
          shifter.run(w0, w1, std::pow(2.0, semis / 12.0));
          lr[i * 2] = x0 * (1 - m) + w0 * m;
          lr[i * 2 + 1] = x1 * (1 - m) + w1 * m;
          continue;
        }
        case kFxSlipRoll:
        case kFxRoll: {
          // what was played from the moment it went on, round again every `beats`
          cap.push(x0, x1); capWritten++;
          if (capLen != len && kind == kFxSlipRoll) capLen = len;  // the length follows the beats at once
          const double into = std::fmod((double)capWritten - 1, std::max(16.0, capLen));
          const double back = (double)capWritten - into;
          w0 = cap.read(0, back); w1 = cap.read(1, back);
          // its own level: LEVEL/DEPTH lets the original through under it
          const float k = 0.5f + 0.5f * L;
          w0 = w0 * k + x0 * (1 - k); w1 = w1 * k + x1 * (1 - k);
          break;
        }
        case kFxVinylBrake: {
          // the sound slows to a stop over `beats`, its pitch going with it
          cap.push(x0, x1); capWritten++;
          brakeSpeed = std::max(0.0, brakeSpeed - 1.0 / std::max(1.0, len * (0.6 + 0.8 * (1 - L))));
          capRead += brakeSpeed;
          const double back = (double)capWritten - capRead;
          const float fade = (float)std::min(1.0, brakeSpeed * 8);
          w0 = cap.read(0, back) * fade; w1 = cap.read(1, back) * fade;
          break;
        }
        case kFxHelix: {
          // what was playing caught and held, round and round; LEVEL/DEPTH lets new sound
          // into it as it turns
          const double back = std::max(16.0, capLen);  // a full turn back
          const float o0 = line.read(0, back), o1 = line.read(1, back);
          const float in = on ? (1 - 0.85f * L) * 0.6f : 0.f;
          const float keep = on ? 0.97f : 0.86f;
          line.push(o0 * keep + x0 * in * s, o1 * keep + x1 * in * s);
          capWritten++;
          lr[i * 2] = x0 * (1 - 0.6f * m) + o0 * (0.4f + 0.6f * L);
          lr[i * 2 + 1] = x1 * (1 - 0.6f * m) + o1 * (0.4f + 0.6f * L);
          peak = std::max(peak, std::fabs(o0) + std::fabs(o1));
          continue;
        }
        default: break;
      }
      lr[i * 2] = x0 * (1 - m) + w0 * m;
      lr[i * 2 + 1] = x1 * (1 - m) + w1 * m;
    }
    tail = spills(kind) ? std::max(peak, tail * 0.9f) : 0.f;
    if (!spills(kind) && !on && mix.now <= 0) tail = 0;
  }

  void startCapture(double len) {
    capLen = len; capWritten = 0; capRead = 0; brakeSpeed = 1;
    // the helix's loop fills with what plays on its first turn
    if (kind == kFxHelix) line.clear();
    cap.clear();
    delayFrames.now = kind == kFxTrans ? 1.f : (float)len;
  }
};

// ------------------------------------------------------------------ SOUND COLOR FX
// The channel's knob: the middle nothing, either way more of the effect, each way its
// own flavour (rekordbox's SPACE, DUB ECHO, SWEEP, NOISE, CRUSH, FILTER).
struct ColorFx {
  double rate = 48000;
  int kind = kCfxFilter;
  float knob = 0, param = 0.5f;
  Filter filter;   // NOISE's and CRUSH's tone (FILTER itself is the deck's own filter)
  Reverb reverb;
  Line line;
  Biquad loopF, bp;
  Noise noise;
  Smooth amt, env, hold;
  float crushHold[2] = {0, 0};
  int crushCount = 0;
  float tail = 0;
  void init(double r) {
    rate = r; filter.init(r); reverb.init(r); line.init((size_t)(r * 2.5));
  }
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
    filter.set(knob);
    const float a = std::fabs(knob);
    if (a < 0.02f && tail < 1e-4f && amt.now < 1e-3f) return;
    float peak = 0;
    switch (kind) {
      case kCfxSpace: {
        // reverb, its send the knob: left low and dark, right high and bright
        reverb.room = 0.74f + 0.22f * param;
        if (knob < 0) loopF.lowpass(900, rate); else loopF.highpass(700, rate);
        for (int i = 0; i < n; i++) {
          const float s = amt.to(a, 0.003f);
          float in = 0.5f * (lr[i * 2] + lr[i * 2 + 1]) * s;
          in = loopF.run(0, in);
          float rl, rr;
          reverb.run(in, rl, rr);
          lr[i * 2] += rl * 1.8f; lr[i * 2 + 1] += rr * 1.8f;
          peak = std::max(peak, std::fabs(rl));
        }
        break;
      }
      case kCfxDubEcho: {
        // an echo a dotted eighth apart, its repeats darker (left) or thinner (right)
        // each pass, more of them the further the knob
        const double d = std::clamp(beatSec, 0.15, 2.0) * 0.75 * rate;
        const double fc = knob < 0 ? 3000 * std::pow(0.15, (double)a) : 300 * std::pow(8.0, (double)a);
        if (knob < 0) loopF.lowpass(fc, rate); else loopF.highpass(fc, rate);
        const float fb = 0.5f + 0.35f * param;
        for (int i = 0; i < n; i++) {
          const float s = amt.to(a, 0.003f);
          const float y0 = line.read(0, d), y1 = line.read(1, d);
          const float f0 = loopF.run(0, y0), f1 = loopF.run(1, y1);
          line.push(lr[i * 2] * s + f0 * fb, lr[i * 2 + 1] * s + f1 * fb);
          lr[i * 2] += y0; lr[i * 2 + 1] += y1;
          peak = std::max(peak, std::fabs(y0));
        }
        break;
      }
      case kCfxSweep: {
        if (knob > 0) {
          // a band narrowing and rising with the knob
          const double f = 300 * std::pow(20.0, (double)a);
          bp.lowpass(std::min(f, rate * 0.45), rate, 1.0 + 6.0 * a);
          for (int i = 0; i < n; i++) {
            const float m = amt.to(a, 0.003f);
            lr[i * 2] = lr[i * 2] * (1 - m) + bp.run(0, lr[i * 2]) * m;
            lr[i * 2 + 1] = lr[i * 2 + 1] * (1 - m) + bp.run(1, lr[i * 2 + 1]) * m;
          }
        } else {
          // a gate: what falls under a threshold rising with the knob goes quiet
          const float th = 0.02f + 0.4f * a * a;
          for (int i = 0; i < n; i++) {
            const float m = amt.to(a, 0.003f);
            const float e = env.to(std::max(std::fabs(lr[i * 2]), std::fabs(lr[i * 2 + 1])), 0.01f);
            const float g = hold.to(e > th ? 1.f : 0.f, e > th ? 0.05f : 0.002f);
            const float k = 1 - m + m * g;
            lr[i * 2] *= k; lr[i * 2 + 1] *= k;
          }
        }
        break;
      }
      case kCfxNoise: {
        // white noise in under the knob's filter, as much as the knob is turned
        for (int i = 0; i < n; i++) {
          const float m = amt.to(a, 0.003f) * (0.12f + 0.2f * param);
          lr[i * 2] += noise.next() * m; lr[i * 2 + 1] += noise.next() * m;
        }
        filter.run(lr, n);
        return;
      }
      case kCfxCrush: {
        // fewer bits and a lower rate the further, darker left, thinner right
        const float bits = 16 - 12 * a;
        const float q = std::pow(2.f, bits - 1);
        const int every = 1 + (int)(a * 12 * (0.5f + param));
        for (int i = 0; i < n; i++) {
          if (crushCount-- <= 0) {
            crushCount = every - 1;
            crushHold[0] = std::round(lr[i * 2] * q) / q;
            crushHold[1] = std::round(lr[i * 2 + 1] * q) / q;
          }
          const float m = amt.to(a, 0.003f);
          lr[i * 2] = lr[i * 2] * (1 - m) + crushHold[0] * m;
          lr[i * 2 + 1] = lr[i * 2 + 1] * (1 - m) + crushHold[1] * m;
        }
        filter.run(lr, n);
        return;
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
