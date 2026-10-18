// The engine's sound shaping, sample by sample: what the old mpv chain did with
// lavfi filters (mixer_desktop.dart), done here the same way so a deck sounds the
// same on either engine.
#pragma once
#include <algorithm>
#include <cmath>
#include <vector>

namespace we {

constexpr double kPi = 3.14159265358979323846;

inline float dbToGain(float db) { return db <= -39.9f ? 0.f : std::pow(10.f, db / 20.f); }

// A value that slides to its target over a given time, sample by sample.
struct Ramp {
  float now = 1, target = 1, step = 0;
  int left = 0;
  void set(float to, int samples) {
    target = to;
    if (samples <= 0) { now = to; left = 0; step = 0; return; }
    left = samples;
    step = (to - now) / samples;
  }
  float next() {
    if (left > 0) { now += step; if (--left == 0) now = target; }
    return now;
  }
  bool moving() const { return left > 0; }
};

// A second-order section (RBJ cookbook), transposed direct form II, per channel.
struct Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double z1[2] = {0, 0}, z2[2] = {0, 0};
  void lowpass(double f, double rate, double q = M_SQRT1_2) {
    double w = 2 * kPi * f / rate, c = std::cos(w), s = std::sin(w), al = s / (2 * q);
    double a0 = 1 + al;
    b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - al) / a0;
  }
  void highpass(double f, double rate, double q = M_SQRT1_2) {
    double w = 2 * kPi * f / rate, c = std::cos(w), s = std::sin(w), al = s / (2 * q);
    double a0 = 1 + al;
    b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - al) / a0;
  }
  inline float run(int ch, float x) {
    double y = b0 * x + z1[ch];
    z1[ch] = b1 * x - a1 * y + z2[ch];
    z2[ch] = b2 * x - a2 * y;
    return (float)y;
  }
  void clear() { z1[0] = z1[1] = z2[0] = z2[1] = 0; }
};

// The three bands: Linkwitz-Riley crossovers (two cascaded Butterworths a side) at
// 300 Hz and 3 kHz, each band through its own gain and added back — the old chain's
// asplit/lowpass/highpass/amix.
struct Bands {
  Biquad lo1, lo2, mhp1, mhp2, mlp1, mlp2, hi1, hi2;
  Ramp low, mid, high;
  bool flat = true;
  void init(double rate) {
    lo1.lowpass(300, rate); lo2.lowpass(300, rate);
    mhp1.highpass(300, rate); mhp2.highpass(300, rate);
    mlp1.lowpass(3000, rate); mlp2.lowpass(3000, rate);
    hi1.highpass(3000, rate); hi2.highpass(3000, rate);
  }
  void set(float l, float m, float h, int samples) {
    low.set(dbToGain(l), samples); mid.set(dbToGain(m), samples); high.set(dbToGain(h), samples);
    flat = false;  // the split is kept on once used: its phase must not come and go
  }
  void run(float* lr, int frames) {
    if (flat) return;
    for (int i = 0; i < frames; i++) {
      float gl = low.next(), gm = mid.next(), gh = high.next();
      for (int ch = 0; ch < 2; ch++) {
        float x = lr[i * 2 + ch];
        float a = lo2.run(ch, lo1.run(ch, x));
        float b = mlp2.run(ch, mlp1.run(ch, mhp2.run(ch, mhp1.run(ch, x))));
        float c = hi2.run(ch, hi1.run(ch, x));
        lr[i * 2 + ch] = a * gl + b * gm + c * gh;
      }
    }
  }
};

// The filter knob: below the middle a low pass closing towards 60 Hz on a log
// scale, above it a high pass opening towards 8 kHz — as the old chain's.
struct Filter {
  Biquad hp, lp;
  float knob = 0, shown = 0;
  double rate = 48000;
  void init(double r) { rate = r; }
  void set(float k) { knob = std::clamp(k, -1.f, 1.f); }
  void run(float* lr, int frames) {
    // The knob eased per block (5 ms) so a sweep has no zipper.
    if (std::fabs(knob - shown) > 1e-4f) {
      shown += (knob - shown) * std::min(1.f, frames / (0.03f * (float)rate));
      if (std::fabs(knob - shown) < 1e-4f) shown = knob;
      if (shown > 0.0005f) hp.highpass(10 * std::pow(800.0, (double)shown), rate);
      if (shown < -0.0005f) lp.lowpass(std::min(15000.0, 22000 * std::pow(60.0 / 22000, (double)-shown)), rate);
    }
    if (shown > 0.0005f) {
      for (int i = 0; i < frames; i++) for (int ch = 0; ch < 2; ch++) lr[i * 2 + ch] = hp.run(ch, lr[i * 2 + ch]);
    } else hp.clear();
    if (shown < -0.0005f) {
      for (int i = 0; i < frames; i++) for (int ch = 0; ch < 2; ch++) lr[i * 2 + ch] = lp.run(ch, lr[i * 2 + ch]);
    } else lp.clear();
  }
};

// The echo: a send into two taps (a dotted eighth and a dotted quarter of the beat)
// with feedback, and the dry beside it — the old chain's aecho=0.7:0.8:d1|d2:0.5|0.3.
struct Echo {
  std::vector<float> line;  // stereo, interleaved
  size_t at = 0;
  Ramp send, dry;
  double rate = 48000, beat = 0.5;
  bool on = false;
  void init(double r) {
    rate = r;
    line.assign((size_t)(r * 4) * 2, 0.f);  // four seconds: a dotted quarter of a 30 bpm beat
    send.now = send.target = 0; dry.now = dry.target = 1;
  }
  void set(float s, float d, double b, int samples) {
    send.set(std::clamp(s, 0.f, 1.f), samples); dry.set(std::clamp(d, 0.f, 1.f), samples);
    if (b > 0.05) beat = b;
    on = true;
  }
  void run(float* lr, int frames) {
    if (!on) return;
    const size_t n = line.size() / 2;
    const size_t d1 = std::min(n - 1, (size_t)(beat * 0.75 * rate)), d2 = std::min(n - 1, (size_t)(beat * 1.5 * rate));
    bool quiet = true;
    for (int i = 0; i < frames; i++) {
      float s = send.next(), dr = dry.next();
      for (int ch = 0; ch < 2; ch++) {
        float x = lr[i * 2 + ch];
        float t1 = line[((at + n - d1) % n) * 2 + ch], t2 = line[((at + n - d2) % n) * 2 + ch];
        float wet = 0.8f * (0.5f * t1 + 0.3f * t2);
        line[at * 2 + ch] = x * 0.7f * s + wet * 0.55f;
        lr[i * 2 + ch] = x * dr + wet;
        if (std::fabs(wet) > 1e-5f) quiet = false;
      }
      at = (at + 1) % n;
    }
    // Back to nothing once the send is shut, the dry whole and the tail rung out.
    if (quiet && send.now == 0 && !send.moving() && dr_whole()) on = false;
  }
  bool dr_whole() const { return dry.now == 1 && !dry.moving(); }
};

// The master's ceiling: nothing out over -1 dBFS. A peak limiter with a short look
// ahead, so it bends a transient rather than clipping it.
struct Limiter {
  std::vector<float> delay;  // stereo look-ahead
  size_t at = 0, look = 0;
  float gain = 1, ceiling = 0.989f, release = 0.9995f;
  void init(double rate) {
    look = (size_t)(rate * 0.003);
    delay.assign(look * 2 + 2, 0.f);
    release = (float)std::exp(-1.0 / (0.2 * rate));
  }
  // How many frames late a sample comes out.
  size_t delayFrames() const { return look + 1; }
  void run(float* lr, int frames) {
    for (int i = 0; i < frames; i++) {
      float l = lr[i * 2], r = lr[i * 2 + 1];
      float p = std::max(std::fabs(l), std::fabs(r));
      float want = p > ceiling ? ceiling / p : 1.f;
      if (want < gain) gain = want; else gain = 1 - (1 - gain) * release;
      // out: the delayed sample at the gain the coming peak asks for
      float dl = delay[at * 2], dr = delay[at * 2 + 1];
      delay[at * 2] = l; delay[at * 2 + 1] = r;
      at = (at + 1) % (look + 1);
      lr[i * 2] = std::clamp(dl * gain, -1.f, 1.f);
      lr[i * 2 + 1] = std::clamp(dr * gain, -1.f, 1.f);
    }
  }
};

}  // namespace we
