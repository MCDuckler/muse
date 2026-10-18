// What the room hears, measured as it is played: the show's sound (state/show/)
// read off the engine's own output instead of modelled from the house's pulse.
//
// The house's pulse (server/muse/pulse.py) is the record as mastered. The booth's
// output is the record through everything the DJ does to it: the EQ's kills, the
// filter's sweep, the echo's tail, a loop, a brake, the gate, two records at once.
// So every deck's output (post fader) and the master's are measured here, one row
// every hop (256 frames, 5.3 ms at 48 kHz), each row stamped with the moment it is
// *heard* — the engine knows its own latency — so a picture asking "what is heard
// now" gets the row for now, not the one decoded 20 ms ago.
//
// Time matters more than detail. A flash a frame late reads as late, so the levels
// and hits come from filters and envelopes that only look back (causal): a band's
// level is its RMS over the last few hops, a hit is how far that level rose against
// four hops back (21 ms, the house's frame). The FFT's spectrum, which needs a long
// window and would lean late, is only the picture's 32-bin spectrum.
//
// Scales: each value 0..1 against fixed references (the k* constants below),
// measured on the house's own records so that a mastered dance record's loud sits
// near 1 (calibrate: test/feature_dump.cpp; pulse.py's kick and this one agree at
// r ≈ 0.9, this one ~20 ms later — pulse.py stamps a frame at its window's start). Fixed and not adaptive on purpose: an
// EQ kill must read as the band gone, not as a quiet band turned back up. The show's
// dynamics (show_dynamics.dart) does the adapting.
#pragma once
#include "dsp.h"

#include <array>
#include <cmath>
#include <complex>
#include <cstdint>
#include <vector>

namespace we {

constexpr int kHop = 256;
constexpr int kSpectrumBins = 32;
constexpr int kFftSize = 2048;

// One hop's measure.
struct FeatureRow {
  double at = 0;  // heard at, we_now() time, of the hop's last frame
  float sub = 0, low = 0, mid = 0, high = 0, air = 0;
  float kick = 0, snare = 0, hat = 0, onset = 0;
  float rms = 0, peak = 0;
  float spectrum[kSpectrumBins] = {};
};

// A band: a bandpass made of a high-pass and two low-passes (or none), squared and
// summed over each hop.
struct BandFilter {
  Biquad hp, lp1, lp2;
  bool hasHp = false, hasLp = false;
  double sum = 0;
  void init(double lo, double hi, double rate) {
    hasHp = lo > 0; hasLp = hi > 0 && hi < rate * 0.45;
    if (hasHp) hp.highpass(lo, rate);
    if (hasLp) { lp1.lowpass(hi, rate); lp2.lowpass(hi, rate); }
  }
  inline void run(float x) {
    if (hasHp) x = hp.run(0, x);
    if (hasLp) x = lp2.run(0, lp1.run(0, x));
    sum += (double)x * x;
  }
};

// A radix-2 FFT, enough for one spectrum every other hop.
struct Fft {
  int n = 0;
  std::vector<std::complex<float>> tw;
  std::vector<int> rev;
  void init(int size) {
    n = size;
    tw.resize((size_t)n / 2);
    for (int i = 0; i < n / 2; i++) tw[(size_t)i] = std::polar(1.f, (float)(-2 * kPi * i / n));
    rev.resize((size_t)n);
    int bits = 0;
    while ((1 << bits) < n) bits++;
    for (int i = 0; i < n; i++) {
      int r = 0;
      for (int b = 0; b < bits; b++) if (i & (1 << b)) r |= 1 << (bits - 1 - b);
      rev[(size_t)i] = r;
    }
  }
  void run(std::vector<std::complex<float>>& a) const {
    for (int i = 0; i < n; i++) if (i < rev[(size_t)i]) std::swap(a[(size_t)i], a[(size_t)rev[(size_t)i]]);
    for (int len = 2; len <= n; len <<= 1) {
      const int step = n / len;
      for (int i = 0; i < n; i += len)
        for (int j = 0; j < len / 2; j++) {
          const auto u = a[(size_t)(i + j)], v = a[(size_t)(i + j + len / 2)] * tw[(size_t)(j * step)];
          a[(size_t)(i + j)] = u + v; a[(size_t)(i + j + len / 2)] = u - v;
        }
    }
  }
};

class Analyzer {
 public:
  // Where each value's 1 is, in the units measured (RMS of the band's signal, full
  // scale 1; a rise over 21 ms): the median of nine of the house's records' 99.5th
  // percentiles (test/feature_dump.cpp), as pulse.py puts a record's own 99.5th
  // percentile at 255. Measured 2026-10-18 on pop, techno, house and eurodance; a
  // record's own sits within about ×1.5 of these.
  static constexpr float kSub = 0.17f, kLow = 0.26f, kMid = 0.22f, kHigh = 0.09f, kAir = 0.077f;
  static constexpr float kKick = 0.22f, kOnset = 4.35f, kSnare = 2.56f, kHat = 1.54f;
  static constexpr float kRms = 0.39f;

  // WETOWL_TAP_RAW=1: every value as measured, unscaled (for the calibration).
  static inline bool raw = false;

  void init(int rate, bool spectrum) {
    rate_ = rate;
    spectrumOn_ = spectrum;
    // pulse.py's five bands, and the kick's 30–150 Hz.
    bands_[0].init(20, 60, rate);
    bands_[1].init(60, 250, rate);
    bands_[2].init(250, 2000, rate);
    bands_[3].init(2000, 6000, rate);
    bands_[4].init(6000, 0, rate);
    kick_.init(30, 150, rate);
    if (spectrum) {
      fft_.init(kFftSize);
      window_.resize(kFftSize);
      for (int i = 0; i < kFftSize; i++) window_[(size_t)i] = (float)(0.5 - 0.5 * std::cos(2 * kPi * i / (kFftSize - 1)));
      buf_.assign(kFftSize, 0.f);
      work_.resize(kFftSize);
      // 32 bins, log-spaced from 30 Hz to 16 kHz (or the Nyquist).
      const double top = std::min(16000.0, rate * 0.48);
      for (int b = 0; b <= kSpectrumBins; b++) {
        const double hz = 30.0 * std::pow(top / 30.0, (double)b / kSpectrumBins);
        edges_[(size_t)b] = std::max(1, (int)std::lround(hz * kFftSize / rate));
      }
      for (int b = 0; b < kSpectrumBins; b++) edges_[(size_t)b + 1] = std::max(edges_[(size_t)b + 1], edges_[(size_t)b] + 1);
    }
  }

  // Feeds n mono frames; calls emit(row, hopEndIndex) for every hop completed, where
  // hopEndIndex counts frames fed since the start (the hop's last frame + 1).
  template <typename Emit>
  void feed(const float* x, int n, Emit&& emit) {
    for (int i = 0; i < n; i++) {
      const float s = x[i];
      for (auto& b : bands_) b.run(s);
      kick_.run(s);
      sq_ += (double)s * s;
      peak_ = std::max(peak_, std::fabs(s));
      if (spectrumOn_) { buf_[(size_t)bufAt_] = s; bufAt_ = (bufAt_ + 1) % kFftSize; }
      if (++inHop_ == kHop) {
        inHop_ = 0;
        fed_ += kHop;
        hop(emit);
      }
    }
  }

 private:
  // The RMS of the last k hops, from a history of per-hop sums of squares.
  struct Env {
    std::array<double, 8> sums{};
    int at = 0;
    void push(double s) { sums[(size_t)at] = s; at = (at + 1) % 8; }
    double rms(int k) const {
      double t = 0;
      for (int i = 1; i <= k; i++) t += sums[(size_t)((at - i + 8) % 8)];
      return std::sqrt(t / (k * kHop));
    }
  };
  // A level's history, hop by hop, to read the rise against four hops back.
  struct Hist {
    std::array<float, 8> v{};
    int at = 0;
    void push(float x) { v[(size_t)at] = x; at = (at + 1) % 8; }
    float back(int k) const { return v[(size_t)((at - 1 - k + 16) % 8)]; }
  };

  static float shape(double v, float ref) {
    if (raw) return (float)v;
    return (float)std::pow(std::clamp(v / ref, 0.0, 1.0), 0.7);
  }
  static float logl(double v) { return (float)std::log1p(100.0 * v); }

  template <typename Emit>
  void hop(Emit&& emit) {
    for (size_t b = 0; b < bands_.size(); b++) { env_[b].push(bands_[b].sum); bands_[b].sum = 0; }
    kickEnv_.push(kick_.sum); kick_.sum = 0;

    FeatureRow r;
    // Levels over windows that hold a few of the band's cycles: 21 ms for the sub and
    // the low, 11 for the mid, a hop above that.
    const double sub = env_[0].rms(4), low = env_[1].rms(4), mid = env_[2].rms(2), high = env_[3].rms(1), air = env_[4].rms(1);
    r.sub = shape(sub, kSub); r.low = shape(low, kLow); r.mid = shape(mid, kMid); r.high = shape(high, kHigh); r.air = shape(air, kAir);

    // The kick: its band's level over the last hop against four hops back, on the way
    // up only, as pulse.py's _kick. One hop, not two: over half within 4–8 ms of the
    // kick being heard, its top in 5–9 (engine_test tap); two hops took 4 ms longer.
    const float k = (float)kickEnv_.rms(1);
    kickHist_.push(k);
    r.kick = shape(std::max(0.f, k - kickHist_.back(4)), kKick);

    // The onsets: each band's log level against four hops back, summed; the snare's
    // from the mid and the high, the hats' from the air.
    const float l[5] = {logl(sub), logl(low), logl(mid), logl(high), logl(air)};
    float rise[5];
    for (int b = 0; b < 5; b++) {
      logHist_[(size_t)b].push(l[b]);
      rise[b] = std::max(0.f, l[b] - logHist_[(size_t)b].back(4));
    }
    r.onset = shape(rise[0] + rise[1] + rise[2] + rise[3] + rise[4], kOnset);
    r.snare = shape(rise[2] + rise[3], kSnare);
    r.hat = shape(rise[4], kHat);

    r.rms = shape(std::sqrt(sq_ / kHop), kRms);
    r.peak = std::min(1.f, peak_);
    sq_ = 0; peak_ = 0;

    if (spectrumOn_) {
      // Every other hop is plenty for a picture; the rest repeat the last.
      if ((fed_ / kHop) % 2 == 0) spectrum();
      std::copy(std::begin(spec_), std::end(spec_), std::begin(r.spectrum));
    }
    emit(r, fed_);
  }

  void spectrum() {
    for (int i = 0; i < kFftSize; i++) work_[(size_t)i] = {buf_[(size_t)((bufAt_ + i) % kFftSize)] * window_[(size_t)i], 0.f};
    fft_.run(work_);
    // Power per bin against a full-scale sine's (window sum² / 4), in dB, −70..0 → 0..1.
    const double full = (kFftSize * 0.5) * (kFftSize * 0.5) / 4.0;
    for (int b = 0; b < kSpectrumBins; b++) {
      double p = 0;
      const int a = edges_[(size_t)b], z = edges_[(size_t)b + 1];
      for (int i = a; i < z && i < kFftSize / 2; i++) p += std::norm(work_[(size_t)i]);
      p /= std::max(1, z - a);
      const double db = 10 * std::log10(p / full + 1e-12);
      const float v = (float)std::clamp((db + 70.0) / 70.0, 0.0, 1.0);
      // A little fall, so a bin flickers less than the FFT does.
      spec_[b] = std::max(v, spec_[b] * 0.85f);
    }
  }

  int rate_ = 48000;
  bool spectrumOn_ = false;
  std::array<BandFilter, 5> bands_;
  BandFilter kick_;
  std::array<Env, 5> env_;
  Env kickEnv_;
  Hist kickHist_;
  std::array<Hist, 5> logHist_;
  double sq_ = 0;
  float peak_ = 0;
  int inHop_ = 0;
  int64_t fed_ = 0;
  Fft fft_;
  std::vector<float> window_, buf_;
  std::vector<std::complex<float>> work_;
  int bufAt_ = 0;
  std::array<int, kSpectrumBins + 1> edges_{};
  float spec_[kSpectrumBins] = {};
};

}  // namespace we
