// WetOwl's booth engine. See we_engine.h for what it offers, and
// ~/.claude/plans/wetowl-native-engine.md for why it exists.
//
// Every deck is rendered in one callback off one sample clock, from records decoded
// whole into memory (16-bit, at the engine's rate). So two decks' tempos can be set
// in an exact ratio — nothing drifts — and where each is heard is known to the
// sample, so SYNC is one jump and a loop's end is a sample, not a timer.
//
// A deck plays through a *voice*: a read head on the record and, with key lock, a
// Rubber Band stretcher (R3, real-time), else a cubic resampler. A jump (a seek, SYNC
// putting the deck on the beat, a cue) starts a fresh voice at the new place and
// crossfades the two over a few milliseconds, so it is heard at once rather than
// after the stretcher's ~40 ms. A loop's wrap is done at the record, ahead of the
// stretcher, with the sound past the loop's end crossfaded into the sound after its
// start: the stretcher never learns a loop happened.
//
// Where a keylocked deck is *heard* comes from the voice's feed log: which record
// frames went in, at what rate. A rate takes effect, for the timing of what comes
// out, kShift input frames after it was set (measured: proto/rbtest.cpp, ±0.3 ms
// through tempo steps for R2 and R3 at 44.1/48 kHz).
#include "we_engine.h"
#include "dsp.h"

#include "rubberband/RubberBandStretcher.h"
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include "miniaudio.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

using RubberBand::RubberBandStretcher;

namespace we {

constexpr int kBlock = 256;           // the engine's own block, frames
constexpr int kChunkBits = 16;        // a source's memory comes in chunks of 64k frames
constexpr int64_t kChunk = 1 << kChunkBits;
constexpr double kRateMin = 0.25, kRateMax = 4.0;   // a deck's rate, and its bend, each

// ------------------------------------------------------------------ sources
struct Source {
  int channels = 2;
  std::vector<int16_t*> chunks;       // the table is made once, long enough for hours
  std::atomic<int64_t> frames{0};
  std::atomic<bool> done{false};
  bool freed = false;                 // Dart let go; deleted once no deck plays it
  Source(int ch, int64_t maxFrames) : channels(ch) { chunks.assign((size_t)(maxFrames / kChunk + 2), nullptr); }
  ~Source() { for (auto* c : chunks) delete[] c; }
  inline const int16_t* frame(int64_t f) const {
    return chunks[(size_t)(f >> kChunkBits)] + (f & (kChunk - 1)) * channels;
  }
};

// ------------------------------------------------------------------ a small ring
template <typename T, int N>
struct Ring {
  std::array<T, N> v;
  int head = 0, count = 0;
  void clear() { head = count = 0; }
  T& operator[](int i) { return v[(head + i) % N]; }
  T& back() { return (*this)[count - 1]; }
  void push(const T& x) {
    if (count == N) { head = (head + 1) % N; count--; }  // the oldest is long past by now
    v[(head + count) % N] = x; count++;
  }
  void pop_front() { head = (head + 1) % N; count--; }
  void pop_back() { count--; }
};

// ------------------------------------------------------------------ decks
struct Slot {
  Source* src = nullptr;
  Ramp gain, pair[3];
};

struct Deck;

// A run of record frames fed in one go: input index → record frame.
struct Feed { double in, at; };
// An effective rate from an input index on, with the output time it begins at.
struct Mark { double in, ratio, out; };

struct Voice {
  bool used = false, keylock = true;
  std::unique_ptr<RubberBandStretcher> rb;
  bool faster = false;      // rb is Rubber Band's lighter engine (R2), not R3
  double head = 0;          // the record frame read next
  double ratio = 1;         // record frames per output frame, as last set
  double pitch = 1;
  // keylock bookkeeping
  double fed = 0;           // real input frames given to the stretcher
  int64_t out = 0;          // frames taken out, the trimmed start included
  int64_t delay = 0, trim = 0;
  Ring<Feed, 2048> feeds;
  Ring<Mark, 2048> marks;
  int markAt = 0;           // the mark the ear is in
  // the crossfade
  Ramp weight;
  bool dying = false;
  // a loop's seam: the old path (head + ghostBy) faded out over ghostLen frames
  int ghostLeft = 0, ghostLen = 0;
  double ghostBy = 0;
  double lastHeard = 0;
};

struct Deck {
  int index = 0;
  std::array<Slot, WE_SOURCES> slots;
  Voice voices[2];
  int active = 0;
  bool playing = false, keylock = true;
  double rate = 1, bend = 1, trim = 1, pitch = 1;
  double head = 0;           // where it is when parked
  // loop, in record frames
  bool looping = false;
  double loopA = 0, loopB = 0;
  // grid
  std::vector<double>* beats = nullptr;   // record seconds
  int barOne = 0;
  // sync
  int master = -1, every = 1;
  double offset = 0;         // seconds of its own record ahead of the master's beat
  double fold = 1;           // its beats per master beat
  bool snapPending = false;
  double phaseError = 0;
  // a start in step, when the master is heard at startAt
  int startMaster = -1;
  double startAt = 0;
  bool startWaiting = false;
  bool alignOnce = false;
  int ended = 0;
  // the brake
  bool braking = false;
  double brakeLeft = 0, brakeTotal = 0;
  // sound
  Ramp level;
  Bands bands;
  Filter filter;
  Echo echo;
  float gateDepth = 0;
  double gatePeriod = 0, gateOrigin = 0;
  float peakL = 0, peakR = 0;
  int64_t moves = 0;
  double heardNow = 0;       // the record frame heard at this block's start
  float buf[kBlock * 2];
};

enum CmdKind {
  kSource, kSourceGain, kPlay, kSeek, kRate, kBend, kKeylock, kShift, kBeats, kSync, kBarOne, kStart,
  kLoop, kLoopBeats, kLevel, kEq, kFilter, kGate, kEcho, kBrake, kMaster, kFreeSource, kSyncOffset, kAlign
};
struct Cmd {
  CmdKind kind;
  int deck = 0, i0 = 0, i1 = 0, i2 = 0;
  double d0 = 0, d1 = 0, d2 = 0, d3 = 0;
  float f0 = 0, f1 = 0, f2 = 0, f3 = 0;
  std::vector<double>* beats = nullptr;
};

struct State {
  std::atomic<uint32_t> seq{0};
  we_deck_state s{};
};

struct Engine {
  int rate = 48000;
  bool device = false;
  ma_device dev{};
  double latency = 0;
  std::atomic<int64_t> rendered{0};
  std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
  std::array<Deck, WE_DECKS> decks;
  Ramp master;
  Limiter limiter;
  // commands, from Dart to the audio thread
  std::mutex cmdLock;
  std::vector<Cmd> cmds, taking;
  // sources
  std::mutex srcLock;
  std::vector<Source*> sources{nullptr};
  // what the audio thread is done with, freed on Dart's thread
  std::mutex retireLock;
  std::vector<std::vector<double>*> retiredBeats;
  std::vector<Source*> retiredSources;
  std::vector<int> pendingFree;  // source ids Dart freed, checked by the audio thread
  std::array<State, WE_DECKS> states;
  std::atomic<float> peaks[WE_DECKS][2];
  int64_t shift = 2048;
  bool split = false;   // WETOWL_ENGINE_SPLIT: deck A alone on the left, B on the right (the probe)
  std::vector<float> scratchL, scratchR, scratchOut;
  // The audio thread's load: how long a callback took against the time it had (an
  // average over about a second, the worst since Dart last asked), and the callbacks
  // that took longer than that (each one heard as a gap). Keylocked decks run on
  // Rubber Band's finer engine (R3) until the load says the machine cannot carry it,
  // then on its faster one (R2), for the rest of the run.
  int period = 0;
  std::atomic<float> loadAvg{0}, loadWorst{0};
  std::atomic<int64_t> late{0};
  double lateScore = 0;
  std::atomic<bool> faster{false};
  bool stretchPinned = false;   // WETOWL_ENGINE_STRETCH said which: never switched
  bool revoice = false;
  float* outScratch[2];
  float tmp[kBlock * 2];
  float trimBuf[8192 * 2];
};

Engine* E = nullptr;
std::string lastError;

double now() {
  if (!E) return 0;
  if (!E->device) return (double)E->rendered.load() / E->rate;
  return std::chrono::duration<double>(std::chrono::steady_clock::now() - E->t0).count();
}

// ------------------------------------------------------------------ the grid
double beatIndexAt(const Deck& d, double sec) {
  const auto* b = d.beats;
  if (!b || b->size() < 2) return 0;
  const auto& v = *b;
  if (sec <= v[0]) return (sec - v[0]) / (v[1] - v[0]);
  if (sec >= v.back()) return (double)(v.size() - 1) + (sec - v.back()) / (v.back() - v[v.size() - 2]);
  size_t lo = 0, hi = v.size() - 1;
  while (hi - lo > 1) { size_t m = (lo + hi) / 2; if (v[m] <= sec) lo = m; else hi = m; }
  return (double)lo + (sec - v[lo]) / (v[lo + 1] - v[lo]);
}

double beatTime(const Deck& d, double idx) {
  const auto& v = *d.beats;
  const double n = (double)v.size();
  if (idx <= 0) return v[0] + idx * (v[1] - v[0]);
  if (idx >= n - 1) return v.back() + (idx - (n - 1)) * (v.back() - v[v.size() - 2]);
  size_t i = (size_t)idx;
  return v[i] + (idx - (double)i) * (v[i + 1] - v[i]);
}

// The beat's length around sec: the mean of the eight either side, so a wobbly
// analysis beat does not wobble a tempo.
double periodAt(const Deck& d, double sec) {
  const auto* b = d.beats;
  if (!b || b->size() < 2) return 0.5;
  const auto& v = *b;
  long i = (long)beatIndexAt(d, sec);
  long lo = std::clamp(i - 8, 0L, (long)v.size() - 2), hi = std::clamp(i + 8, lo + 1, (long)v.size() - 1);
  return (v[(size_t)hi] - v[(size_t)lo]) / (double)(hi - lo);
}

bool hasGrid(const Deck& d) { return d.beats && d.beats->size() >= 2; }

// ------------------------------------------------------------------ reading the record
inline void frameAt(Deck& d, int64_t f, float& l, float& r) {
  l = r = 0;
  for (auto& s : d.slots) {
    Source* src = s.src;
    if (!src || f < 0) continue;
    if (f >= src->frames.load(std::memory_order_acquire)) continue;
    const float g = s.gain.now;
    if (g <= 0.f) continue;
    const int16_t* p = src->frame(f);
    if (src->channels == 2) {
      l += g * p[0] * (1.f / 32768); r += g * p[1] * (1.f / 32768);
    } else if (src->channels >= 6) {
      const float a = s.pair[0].now, b = s.pair[1].now, c = s.pair[2].now;
      l += g * (a * p[0] + b * p[2] + c * p[4]) * (1.f / 32768);
      r += g * (a * p[1] + b * p[3] + c * p[5]) * (1.f / 32768);
    } else {
      l += g * p[0] * (1.f / 32768); r += g * p[0] * (1.f / 32768);
    }
  }
}

// The record at a fractional frame: cubic (Catmull-Rom) between frames.
inline void readAt(Deck& d, double pos, float& l, float& r) {
  const int64_t i = (int64_t)std::floor(pos);
  const float t = (float)(pos - (double)i);
  if (t < 1e-6f) { frameAt(d, i, l, r); return; }
  float l0, r0, l1, r1, l2, r2, l3, r3;
  frameAt(d, i - 1, l0, r0); frameAt(d, i, l1, r1); frameAt(d, i + 1, l2, r2); frameAt(d, i + 2, l3, r3);
  auto cr = [t](float a, float b, float c, float e) {
    return b + 0.5f * t * (c - a + t * (2.f * a - 5.f * b + 4.f * c - e + t * (3.f * (b - c) + e - a)));
  };
  l = cr(l0, l1, l2, l3); r = cr(r0, r1, r2, r3);
}

// One frame of a voice's path through the record, the loop's seam crossfaded.
inline void voiceFrame(Deck& d, Voice& v, float& l, float& r) {
  readAt(d, v.head, l, r);
  if (v.ghostLeft > 0) {
    float gl, gr;
    readAt(d, v.head + v.ghostBy, gl, gr);
    const float w = (float)v.ghostLeft / (float)v.ghostLen;  // the old path's share
    l = l * (1 - w) + gl * w; r = r * (1 - w) + gr * w;
    v.ghostLeft--;
  }
}

// The voice's head moved on by step, round the loop where there is one.
inline void advance(Deck& d, Voice& v, double step) {
  v.head += step;
  if (d.looping && v.head >= d.loopB && d.loopB > d.loopA) {
    const double len = d.loopB - d.loopA;
    while (v.head >= d.loopB) v.head -= len;
    v.ghostBy = len;
    v.ghostLen = std::max(16, std::min((int)(E->rate * 0.003), (int)(len / 4)));
    v.ghostLeft = v.ghostLen;
    d.moves++;
  }
}

// Gains slide per frame of the record read.
inline void stepGains(Deck& d) {
  for (auto& s : d.slots) { if (!s.src) continue; s.gain.next(); s.pair[0].next(); s.pair[1].next(); s.pair[2].next(); }
}

// ------------------------------------------------------------------ voices
// What a stretcher is ever asked for: the rate and the bend at their ends, and never
// a NaN (Rubber Band R3 reads out of bounds far past these).
inline double stretchable(double ratio) {
  return std::isfinite(ratio) ? std::clamp(ratio, kRateMin * kRateMin, kRateMax * kRateMax) : 1.0;
}

void voiceStart(Deck& d, Voice& v, double at, bool keylock, double ratio) {
  if (keylock) ratio = stretchable(ratio);
  v.used = true; v.dying = false;
  v.keylock = keylock; v.head = at; v.ratio = ratio;
  v.ghostLeft = 0; v.lastHeard = at;
  if (keylock) {
    const bool faster = E->faster.load();
    if (!v.rb || v.faster != faster) {
      const auto o = RubberBandStretcher::OptionProcessRealTime |
                     (faster ? RubberBandStretcher::OptionEngineFaster | RubberBandStretcher::OptionWindowShort : RubberBandStretcher::OptionEngineFiner) |
                     RubberBandStretcher::OptionPitchHighConsistency | RubberBandStretcher::OptionChannelsTogether;
      v.rb.reset(new RubberBandStretcher((size_t)E->rate, 2, o, 1.0, 1.0));
      v.rb->setMaxProcessSize(4096);
      v.faster = faster;
    }
    v.rb->reset();
    v.rb->setTimeRatio(1.0 / ratio);
    v.rb->setPitchScale(d.pitch);
    v.pitch = d.pitch;
    const size_t pad = v.rb->getPreferredStartPad();
    static float zeros[8192] = {0};
    size_t left = pad;
    while (left > 0) {
      const size_t n = std::min<size_t>(left, 4096);
      const float* z[2] = {zeros, zeros};
      v.rb->process(z, n, false);
      left -= n;
    }
    v.delay = v.trim = (int64_t)v.rb->getStartDelay();
    v.fed = 0; v.out = 0;
    v.feeds.clear(); v.marks.clear(); v.markAt = 0;
    v.feeds.push({0, at});
    v.marks.push({0, ratio, 0});
  }
}

// Where the voice's next output frame is heard: the record frame.
double voiceHeard(Voice& v) {
  if (!v.keylock) return v.head;
  const double t = (double)(v.out - v.delay);   // output time of the real input emerging next
  if (t <= 0) return v.feeds.count ? v.feeds[0].at : v.head;
  // the mark the ear is in
  while (v.markAt + 1 < v.marks.count && v.marks[v.markAt + 1].out <= t) v.markAt++;
  const Mark& m = v.marks[v.markAt];
  const double in = m.in + (t - m.out) * m.ratio;
  // the feed it came from
  int fi = 0;
  for (int i = v.feeds.count - 1; i >= 0; i--) if (v.feeds[i].in <= in) { fi = i; break; }
  const Feed& f = v.feeds[fi];
  // drop what the ear has passed (keep one before)
  while (v.markAt > 1) { v.marks.pop_front(); v.markAt--; }
  while (fi > 1) { v.feeds.pop_front(); fi--; }
  return f.at + (in - f.in);
}

// A keylocked voice's rate: the stretcher told now, the timing of the frames fed from
// here on reckoned with it kShift frames back.
void voiceRatio(Voice& v, double ratio) {
  if (v.keylock) ratio = stretchable(ratio);
  if (ratio == v.ratio && v.marks.count) return;
  v.ratio = ratio;
  if (!v.keylock) return;
  v.rb->setTimeRatio(1.0 / ratio);
  // The ear's own input index, below which the past is fixed.
  const double t = (double)(v.out - v.delay);
  const Mark& cur = v.marks[v.markAt];
  const double heardIn = t <= 0 ? 0 : cur.in + (t - cur.out) * cur.ratio;
  double at = std::max(heardIn, v.fed - (double)E->shift);
  while (v.marks.count > 1 && v.marks.back().in >= at && v.marks.count - 1 > v.markAt) v.marks.pop_back();
  Mark& last = v.marks.back();
  if (at <= last.in) { last.ratio = ratio; return; }
  v.marks.push({at, ratio, last.out + (at - last.in) / last.ratio});
}

// n frames of a voice into out (added, at its weight), from frame `from` of the block.
void voiceRender(Deck& d, Voice& v, float* out, int from, int n) {
  if (!v.keylock) {
    for (int k = from; k < n; k++) {
      float l, r;
      voiceFrame(d, v, l, r);
      advance(d, v, v.ratio);
      stepGains(d);
      const float w = v.weight.next();
      out[k * 2] += l * w; out[k * 2 + 1] += r * w;
    }
    return;
  }
  if (d.pitch != v.pitch) { v.rb->setPitchScale(d.pitch); v.pitch = d.pitch; }
  const int want = n - from;
  auto& inL = E->scratchL; auto& inR = E->scratchR;
  while ((int64_t)v.rb->available() < want + v.trim) {
    size_t need = v.rb->getSamplesRequired();
    if (need == 0) need = 256;
    need = std::min<size_t>(need, 4096);
    for (size_t i = 0; i < need; i++) {
      const double before = v.head;
      float l, r;
      voiceFrame(d, v, l, r);
      advance(d, v, 1.0);
      stepGains(d);
      inL[i] = l; inR[i] = r;
      if (v.head != before + 1.0) v.feeds.push({v.fed + (double)i + 1, v.head});  // a loop's wrap
    }
    const float* in[2] = {inL.data(), inR.data()};
    v.rb->process(in, need, false);
    v.fed += (double)need;
  }
  // the start's delay, thrown away
  while (v.trim > 0) {
    const size_t k = (size_t)std::min<int64_t>(v.trim, 8192);
    float* o[2] = {E->trimBuf, E->trimBuf + 8192};
    const size_t got = v.rb->retrieve(o, k);
    v.trim -= (int64_t)got; v.out += (int64_t)got;
    if (got == 0) break;
  }
  float* o[2] = {inL.data(), inR.data()};
  const size_t got = v.rb->retrieve(o, (size_t)want);
  v.out += (int64_t)got;
  for (size_t i = 0; i < got; i++) {
    const float w = v.weight.next();
    out[(from + (int)i) * 2] += inL[i] * w;
    out[(from + (int)i) * 2 + 1] += inR[i] * w;
  }
}

// ------------------------------------------------------------------ deck moves
double effRate(const Deck& d) { return d.rate * d.bend * d.trim * (d.braking ? 1.0 : 1.0); }

Voice& activeVoice(Deck& d) { return d.voices[d.active]; }

double heardOf(Deck& d) {
  Voice& v = activeVoice(d);
  if (!d.playing || !v.used) return d.head;
  return voiceHeard(v);
}

// Puts a playing deck at record frame `at` at once: a new voice there, the old one
// faded out over 4 ms.
void jump(Deck& d, double at, int fadeFrames = -1) {
  d.moves++;
  if (!d.playing) { d.head = at; return; }
  if (fadeFrames < 0) fadeFrames = (int)(E->rate * 0.004);
  Voice& old = activeVoice(d);
  d.active ^= 1;
  Voice& v = activeVoice(d);
  voiceStart(d, v, at, d.keylock && !d.braking, effRate(d));
  v.weight.now = 0; v.weight.set(1, fadeFrames);
  if (old.used) { old.dying = true; old.weight.set(0, fadeFrames); }
}

void play(Deck& d, bool on, int fromFrame = 0) {
  if (on == d.playing) return;
  if (on) {
    d.playing = true;
    Voice& v = activeVoice(d);
    voiceStart(d, v, d.head, d.keylock, effRate(d));
    v.weight.now = 0; v.weight.set(1, (int)(E->rate * 0.002));
    (void)fromFrame;
  } else {
    // Parked where it was heard, not where the stretcher had read to.
    d.head = heardOf(d);
    for (auto& v : d.voices) { if (v.used) { v.dying = true; v.weight.set(0, (int)(E->rate * 0.003)); } }
    d.playing = false;
  }
}

double secToFrame(double s) { return s * E->rate; }
double frameToSec(double f) { return f / E->rate; }

// ------------------------------------------------------------------ sync
// The fold: the follower's beats per master beat, a power of two that puts its rate
// within half/double of its own tempo.
double foldFor(double base) {
  double q = 1;
  while (base * q < M_SQRT1_2) q *= 2;
  while (base * q > M_SQRT2) q /= 2;
  return q;
}

// The follower's error, seconds of its own record (+: it should move on), and the
// rate it should run at, from both decks heard now.
bool syncError(Deck& f, Deck& m, double& errSec, double& rateFor, bool refold) {
  if (!hasGrid(f) || !hasGrid(m)) return false;
  const double hm = frameToSec(m.heardNow), hf = frameToSec(f.heardNow);
  const double pm = periodAt(m, hm), pf = periodAt(f, hf);
  const double masterBeatsPerSec = effRate(m) / pm;
  const double base = masterBeatsPerSec * pf;
  if (refold) f.fold = foldFor(base);
  rateFor = base * f.fold;
  const double q = f.fold;
  const double phm = beatIndexAt(m, hm) - m.barOne, phf = beatIndexAt(f, hf) - f.barOne - f.offset / pf;
  // In master beats, wrapped at what may be lined up: every beats, a slower
  // follower's beat being two of the master's.
  double errM = phf / q - phm;
  const double mod = (double)std::max(1, f.every) * std::max(1.0, 1.0 / q);
  errM = std::fmod(errM, mod);
  if (errM > mod / 2) errM -= mod;
  if (errM < -mod / 2) errM += mod;
  errSec = -errM * q * pf;  // follower ahead (errM > 0) → move back
  return true;
}

void syncBlock(Deck& f) {
  if (f.master < 0 || f.master == f.index) return;
  Deck& m = E->decks[f.master];
  // A brake is the master's alone: followed, a keylocked follower would be stretched
  // to a fiftieth of its speed.
  if (m.braking) return;
  double err = 0, rateFor = f.rate;
  if (!syncError(f, m, err, rateFor, false)) return;
  f.phaseError = -err;
  // The tempo, always: a master's fader carries the follower in the same block.
  f.rate = std::clamp(rateFor, kRateMin, kRateMax);
  if (!f.playing || !m.playing) { f.trim = 1; return; }
  if (f.snapPending) {
    f.snapPending = false;
    if (std::fabs(err) > 0.0002) jump(f, f.heardNow + secToFrame(err));
    f.trim = 1;
    return;
  }
  if (f.bend != 1.0) {
    // A hand on the jog: the place it leaves the deck in is kept.
    f.offset -= err;
    f.trim = 1;
    return;
  }
  // Held: a hair of rate, a second's time constant, nothing inside a fifth of a
  // millisecond. An exact ratio leaves it next to nothing to do.
  if (std::fabs(err) < 0.0002) { f.trim = 1; return; }
  f.trim = 1 + std::clamp(err / 1.0, -0.003, 0.003);
}

// Where the follower's beat matching the master's now is, nearest `near`: frames.
double inStepNear(Deck& f, Deck& m, double near) {
  const double hm = frameToSec(m.heardNow);
  const double pm = periodAt(m, hm), pf = periodAt(f, frameToSec(near));
  f.fold = foldFor(effRate(m) / pm * pf);
  const double q = f.fold;
  const double want = q * (beatIndexAt(m, hm) - m.barOne) + f.barOne + f.offset / pf;
  const double mod = (double)std::max(1, f.every) * std::max(1.0, q);  // in follower beats
  const double at = beatIndexAt(f, frameToSec(near));
  const double k = std::round((at - want) / mod);
  return secToFrame(beatTime(f, want + k * mod));
}

// Where the follower's beat matching the master's beat at master time `masterSec`
// is, nearest `near` (frames): for a start at a moment still to come.
double inStepAt(Deck& f, Deck& m, double masterSec, double near) {
  const double pm = periodAt(m, masterSec), pf = periodAt(f, frameToSec(near));
  f.fold = foldFor(effRate(m) / pm * pf);
  const double q = f.fold;
  const double want = q * (beatIndexAt(m, masterSec) - m.barOne) + f.barOne + f.offset / pf;
  const double mod = (double)std::max(1, f.every) * std::max(1.0, q);
  const double at = beatIndexAt(f, frameToSec(near));
  const double k = std::round((at - want) / mod);
  return secToFrame(beatTime(f, want + k * mod));
}

// ------------------------------------------------------------------ commands
void apply(const Cmd& c) {
  if (c.kind == kMaster) { E->master.set(c.f0, (int)(E->rate * 0.02)); return; }
  if (c.kind == kFreeSource) {
    E->pendingFree.push_back(c.i0);
    return;
  }
  if (c.deck < 0 || c.deck >= WE_DECKS) return;
  Deck& d = E->decks[c.deck];
  const int ramp = (int)(c.d0 * E->rate);
  switch (c.kind) {
    case kSource: {
      Source* s = nullptr;
      { std::lock_guard<std::mutex> g(E->srcLock);
        if (c.i1 > 0 && c.i1 < (int)E->sources.size()) s = E->sources[(size_t)c.i1]; }
      d.slots[(size_t)c.i0].src = s;
      break;
    }
    case kSourceGain: {
      auto& s = d.slots[(size_t)c.i0];
      // A slot that was silent comes up from nothing, not from where it last was.
      s.gain.set(c.f0, ramp); s.pair[0].set(c.f1, ramp); s.pair[1].set(c.f2, ramp); s.pair[2].set(c.f3, ramp);
      break;
    }
    case kPlay: play(d, c.i0 != 0); if (!c.i0) d.braking = false; break;
    case kSeek: jump(d, secToFrame(c.d0)); break;
    case kRate: if (d.master < 0) d.rate = std::clamp(c.d0, kRateMin, kRateMax); break;
    case kBend: d.bend = std::clamp(c.d0, kRateMin, kRateMax); break;
    case kKeylock:
      if ((c.i0 != 0) != d.keylock) {
        d.keylock = c.i0 != 0;
        if (d.playing) jump(d, heardOf(d), (int)(E->rate * 0.01));
      }
      break;
    case kShift: d.pitch = std::pow(2.0, c.d0 / 12.0); break;
    case kBeats: {
      std::lock_guard<std::mutex> g(E->retireLock);
      if (d.beats) E->retiredBeats.push_back(d.beats);
      d.beats = c.beats;
      break;
    }
    case kSync:
      if (c.i0 < 0 || c.i0 >= WE_DECKS || c.i0 == c.deck) { d.master = -1; d.trim = 1; d.snapPending = false; break; }
      // The master never follows its follower, however far round: SYNC passes to it.
      // Left following, each would set its tempo from the other's every block, and
      // with their folds a factor of two apart both rates halve every block, to
      // nothing in a tenth of a second (the stretcher crashed at the bottom).
      for (int k = c.i0, hops = 0; k >= 0 && hops < WE_DECKS; k = E->decks[(size_t)k].master, hops++) {
        Deck& x = E->decks[(size_t)k];
        if (x.master == c.deck) { x.master = -1; x.trim = 1; x.snapPending = false; break; }
      }
      d.master = c.i0; d.every = std::max(1, c.i1); d.offset = c.d0;
      d.heardNow = heardOf(d);
      { double e, r; if (syncError(d, E->decks[(size_t)c.i0], e, r, true)) d.rate = std::clamp(r, kRateMin, kRateMax); }
      d.snapPending = true;
      break;
    case kBarOne: d.barOne = c.i0; break;
    case kStart: {
      if (c.i0 < 0 || c.i0 >= WE_DECKS) { play(d, true); break; }
      Deck& m = E->decks[(size_t)c.i0];
      d.every = std::max(1, c.i1); d.offset = c.d0;
      m.heardNow = heardOf(m);
      if (c.d1 >= 0 && m.playing) {
        d.startMaster = c.i0; d.startAt = secToFrame(c.d1); d.startWaiting = true;
      } else {
        if (hasGrid(d) && hasGrid(m)) d.head = inStepNear(d, m, d.head);
        play(d, true);
      }
      if (d.master == c.i0) d.snapPending = false;
      break;
    }
    case kSyncOffset: d.offset = c.d0; break;
    case kAlign:
      if (c.i0 < 0 || c.i0 >= WE_DECKS || c.i0 == c.deck) break;
      if (d.master < 0) { d.every = std::max(1, c.i1); d.offset = c.d0; }
      d.alignOnce = true;
      { Deck& m = E->decks[(size_t)c.i0]; d.heardNow = heardOf(d); m.heardNow = heardOf(m);
        double e, r; if (d.playing && m.playing && syncError(d, m, e, r, true) && std::fabs(e) > 0.0002) jump(d, d.heardNow + secToFrame(e)); }
      break;
    case kLoop: {
      if (c.d1 <= c.d0) { d.looping = false; break; }
      d.loopA = secToFrame(c.d0); d.loopB = secToFrame(c.d1); d.looping = true;
      const double len = d.loopB - d.loopA;
      if (d.playing) {
        Voice& v = activeVoice(d);
        if (v.used && v.head >= d.loopB) {
          // Read past the end already (the stretcher reads ahead): again from where
          // the ear is, folded into the loop if the ear is past its end too.
          double h = heardOf(d);
          if (h >= d.loopB) h = d.loopA + std::fmod(h - d.loopA, len);
          jump(d, h);
        }
      } else if (d.head >= d.loopB) {
        d.head = d.loopA + std::fmod(d.head - d.loopA, len);
      }
      break;
    }
    case kLoopBeats: {
      if (!hasGrid(d)) break;
      const double at = frameToSec(heardOf(d));
      double from = std::floor(beatIndexAt(d, at) + 1e-6);
      if (c.i0) {
        // the bar's first beat if it was passed within a beat, else the next
        const double rel = from - d.barOne;
        const double bar = std::floor(rel / 4) * 4 + d.barOne;
        from = (from - bar < 1) ? bar : bar + 4;
      }
      const double a = beatTime(d, from), b = beatTime(d, from + c.d1);
      Cmd l{kLoop}; l.deck = c.deck; l.d0 = a; l.d1 = b;
      apply(l);
      break;
    }
    case kLevel: d.level.set(c.f0, ramp); break;
    case kEq: d.bands.set(c.f0, c.f1, c.f2, ramp); break;
    case kFilter: d.filter.set(c.f0); break;
    case kGate: d.gateDepth = c.f0; d.gatePeriod = c.d1; d.gateOrigin = c.d2; break;
    case kEcho: d.echo.set(c.f0, c.f1, c.d1, (int)(E->rate * 0.03)); break;
    case kBrake:
      if (!d.playing) break;
      d.braking = true; d.brakeTotal = d.brakeLeft = std::max(0.05, c.d0);
      jump(d, heardOf(d), (int)(E->rate * 0.005));  // onto a resampler: the pitch must fall
      break;
    default: break;
  }
}

// ------------------------------------------------------------------ a block
void renderDeck(Deck& d, int n) {
  std::memset(d.buf, 0, sizeof(float) * (size_t)n * 2);
  int from = 0;
  if (d.startWaiting && d.startMaster >= 0) {
    Deck& m = E->decks[(size_t)d.startMaster];
    if (!m.playing) {
      d.startWaiting = false; play(d, true);
    } else {
      // the master heard at startAt within this block?
      const double dt = (d.startAt - m.heardNow) / effRate(m);  // output frames until then
      const int k = (int)std::floor(dt + 0.5);
      if (k < n) {
        d.startWaiting = false;
        // On its beat to the sample, whatever it was parked a hair off: the beat of
        // its own nearest where it waits, lined up with the master's at that moment.
        if (hasGrid(d) && hasGrid(m)) d.head = inStepAt(d, m, frameToSec(d.startAt), d.head);
        play(d, true);
        from = std::max(0, k);
      }
    }
  }
  if (d.braking) {
    d.brakeLeft -= (double)n / E->rate;
    const double k = std::max(0.0, d.brakeLeft / d.brakeTotal);
    d.bend = 0.02 + 0.98 * k * k;
    if (d.brakeLeft <= 0) { play(d, false); d.braking = false; d.bend = 1; }
  }
  if (!d.playing && !d.voices[0].used && !d.voices[1].used) return;
  const double r = effRate(d);
  for (auto& v : d.voices) {
    if (!v.used) continue;
    if (!v.dying) voiceRatio(v, r);
    voiceRender(d, v, d.buf, &v == &activeVoice(d) ? from : 0, n);
    if (v.dying && !v.weight.moving() && v.weight.now <= 0) v.used = false;
  }
  if (d.playing && !activeVoice(d).used) d.playing = false;
  // Off the end of the record (all of it decoded): stopped there.
  if (d.playing && !d.looping) {
    int64_t len = 0; bool done = true;
    for (auto& sl : d.slots) if (sl.src && sl.gain.target > 0) { len = std::max(len, sl.src->frames.load()); done = done && sl.src->done.load(); }
    if (done && len > 0 && d.heardNow >= (double)len) {
      play(d, false); d.head = (double)len; d.ended++;
    }
  }
  // gate, off the record's own clock
  if (d.gateDepth > 0.001f && d.gatePeriod > 0.001) {
    const double t0 = frameToSec(d.heardNow), dt = r / E->rate;
    for (int k = 0; k < n; k++) {
      const double t = t0 + dt * k;
      const float g = 1.f - d.gateDepth * (float)(0.5 - 0.5 * std::cos(2 * kPi * (t - d.gateOrigin) / d.gatePeriod));
      d.buf[k * 2] *= g; d.buf[k * 2 + 1] *= g;
    }
  }
  d.echo.run(d.buf, n);
  d.bands.run(d.buf, n);
  d.filter.run(d.buf, n);
  float pl = 0, pr = 0;
  for (int k = 0; k < n; k++) {
    const float g = d.level.next() * 0.5956621f;  // -4.5 dB headroom, as the old chain
    d.buf[k * 2] *= g; d.buf[k * 2 + 1] *= g;
    pl = std::max(pl, std::fabs(d.buf[k * 2])); pr = std::max(pr, std::fabs(d.buf[k * 2 + 1]));
  }
  d.peakL = std::max(d.peakL, pl); d.peakR = std::max(d.peakR, pr);
}

void publish(Deck& d, double at) {
  State& st = E->states[(size_t)d.index];
  st.seq.fetch_add(1, std::memory_order_acq_rel);
  auto& s = st.s;
  s.heard = frameToSec(d.heardNow);
  s.at = at;
  s.rate = d.playing ? effRate(d) : 0;
  int64_t len = 0;
  for (auto& sl : d.slots) if (sl.src) len = std::max(len, sl.src->frames.load());
  s.length = frameToSec((double)len);
  s.loop_a = frameToSec(d.loopA); s.loop_b = frameToSec(d.loopB);
  s.phase_error = d.phaseError;
  s.moves = d.moves;
  s.playing = d.playing || d.startWaiting; s.looping = d.looping; s.synced = d.master >= 0; s.braking = d.braking;
  s.ended = d.ended;
  s.peak_l = std::max(s.peak_l, d.peakL); s.peak_r = std::max(s.peak_r, d.peakR);
  d.peakL = d.peakR = 0;
  st.seq.fetch_add(1, std::memory_order_acq_rel);
}

void block(float* out, int n, float** deckOut, double at) {
  // commands, if Dart is not adding to them this very moment
  if (E->cmdLock.try_lock()) {
    E->taking.swap(E->cmds);
    E->cmdLock.unlock();
    for (auto& c : E->taking) apply(c);
    E->taking.clear();
  }
  // sources Dart freed, once no deck plays them
  if (!E->pendingFree.empty() && E->retireLock.try_lock()) {
    for (size_t i = 0; i < E->pendingFree.size();) {
      const int id = E->pendingFree[i];
      Source* s = nullptr;
      { std::lock_guard<std::mutex> g(E->srcLock); if (id > 0 && id < (int)E->sources.size()) s = E->sources[(size_t)id]; }
      bool inUse = false;
      for (auto& d : E->decks) for (auto& sl : d.slots) if (sl.src == s) inUse = true;
      if (!inUse && s) { E->retiredSources.push_back(s); E->pendingFree.erase(E->pendingFree.begin() + (long)i); }
      else if (!s) E->pendingFree.erase(E->pendingFree.begin() + (long)i);
      else i++;
    }
    E->retireLock.unlock();
  }
  for (auto& d : E->decks) d.heardNow = heardOf(d);
  for (auto& d : E->decks) syncBlock(d);
  std::memset(out, 0, sizeof(float) * (size_t)n * 2);
  for (auto& d : E->decks) {
    renderDeck(d, n);
    if (deckOut && deckOut[d.index]) std::memcpy(deckOut[d.index], d.buf, sizeof(float) * (size_t)n * 2);
    for (int k = 0; k < n * 2; k++) out[k] += d.buf[k];
  }
  if (E->split) {
    Deck& a = E->decks[0]; Deck& b = E->decks[1];
    for (int k = 0; k < n; k++) {
      out[k * 2] = 0.5f * (a.buf[k * 2] + a.buf[k * 2 + 1]);
      out[k * 2 + 1] = 0.5f * (b.buf[k * 2] + b.buf[k * 2 + 1]);
    }
  } else {
    for (int k = 0; k < n; k++) { const float g = E->master.next(); out[k * 2] *= g; out[k * 2 + 1] *= g; }
    E->limiter.run(out, n);
  }
  for (auto& d : E->decks) publish(d, at);
}

// t0: when the sound card asked for these frames. Each block is heard `latency`
// after that, plus the frames before it in the same call — not after the moment it
// happens to be rendered, which on a busy machine is later and later through the call.
void renderAll(float* out, int frames, float** deckOut, double t0 = 0) {
  int done = 0;
  float* dk[WE_DECKS];
  while (done < frames) {
    const int n = std::min(kBlock, frames - done);
    const double at = E->device ? t0 + E->latency + (double)done / E->rate : (double)E->rendered.load() / E->rate;
    for (int i = 0; i < WE_DECKS; i++) dk[i] = deckOut && deckOut[i] ? deckOut[i] + (size_t)done * 2 : nullptr;
    block(out + (size_t)done * 2, n, deckOut ? dk : nullptr, at);
    done += n;
    E->rendered.fetch_add(n);
  }
}

// Every keylocked deck onto the stretcher the run is on now, where it is heard: a
// jump to its own place, crossfaded over 30 ms.
void revoiceAll() {
  for (auto& d : E->decks) {
    if (!d.playing || !d.keylock || d.braking) continue;
    Voice& v = activeVoice(d);
    if (!v.used || !v.keylock || v.faster == E->faster.load()) continue;
    jump(d, heardOf(d), (int)(E->rate * 0.03));
  }
}

bool anyKeylocked() {
  for (auto& d : E->decks) if (d.playing && d.keylock && !d.braking) return true;
  return false;
}

void callback(ma_device*, void* out, const void*, ma_uint32 frames) {
  if (!E) return;
  const double t0 = now();
  if (E->revoice) { E->revoice = false; revoiceAll(); }
  renderAll((float*)out, (int)frames, nullptr, t0);
  // How long that took against the time there was.
  const double budget = (double)frames / E->rate;
  const float load = (float)((now() - t0) / budget);
  const float a = (float)std::min(1.0, budget / 1.0);
  E->loadAvg.store(E->loadAvg.load() + (load - E->loadAvg.load()) * a);
  if (load > E->loadWorst.load()) E->loadWorst.store(load);
  E->lateScore *= std::exp(-budget / 5.0);
  if (load > 1.0f) { E->late.fetch_add(1); E->lateScore += 1; }
  // Too much for this machine with keylocked decks on R3: R2 from here on. Three late
  // calls within seconds, or most of the time there is spent.
  if (!E->faster.load() && !E->stretchPinned && anyKeylocked() && (E->lateScore >= 3 || E->loadAvg.load() > 0.6f)) {
    E->faster.store(true);
    E->revoice = true;
  }
}

void push(const Cmd& c) {
  if (!E) return;
  std::lock_guard<std::mutex> g(E->cmdLock);
  E->cmds.push_back(c);
}

void freeRetired() {
  if (!E) return;
  std::vector<std::vector<double>*> b;
  std::vector<Source*> s;
  { std::lock_guard<std::mutex> g(E->retireLock); b.swap(E->retiredBeats); s.swap(E->retiredSources); }
  for (auto* x : b) delete x;
  for (auto* x : s) {
    std::lock_guard<std::mutex> g(E->srcLock);
    for (auto& p : E->sources) if (p == x) p = nullptr;
    delete x;
  }
}

}  // namespace we

using namespace we;

// ------------------------------------------------------------------ the C surface
extern "C" {

WE_API int we_start(int rate, int device) {
  if (E) return 0;
  E = new Engine();
  E->device = device != 0;
  E->rate = rate > 0 ? rate : 48000;
  if (E->device) {
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.sampleRate = (ma_uint32)(rate > 0 ? rate : 0);
    // The period: 256 frames where the system's sound server takes them in its stride
    // (PipeWire, measured); on Windows a larger one, so that the stretchers' work —
    // which comes in bursts of a whole FFT frame — has room in each call (WASAPI's own
    // period is 10 ms anyway). WETOWL_ENGINE_PERIOD overrides.
#ifdef _WIN32
    int period = 1024;
#else
    int period = 256;
#endif
    if (const char* pe = std::getenv("WETOWL_ENGINE_PERIOD")) { const int p = std::atoi(pe); if (p >= 64 && p <= 8192) period = p; }
    E->period = period;
    cfg.periodSizeInFrames = (ma_uint32)period;
    cfg.performanceProfile = period <= 256 ? ma_performance_profile_low_latency : ma_performance_profile_conservative;
    cfg.dataCallback = callback;
    cfg.noClip = MA_TRUE;
    if (ma_device_init(nullptr, &cfg, &E->dev) != MA_SUCCESS) {
      lastError = "no sound card would open";
      delete E; E = nullptr;
      return 1;
    }
    E->rate = (int)E->dev.sampleRate;
    E->latency = (double)(E->dev.playback.internalPeriodSizeInFrames * E->dev.playback.internalPeriods) / E->rate;
  }
  E->shift = E->rate > 50000 ? 4096 : 2048;
  if (const char* st = std::getenv("WETOWL_ENGINE_STRETCH")) {
    if (std::strcmp(st, "faster") == 0) { E->faster.store(true); E->stretchPinned = true; }
    if (std::strcmp(st, "finer") == 0) E->stretchPinned = true;
  }
  { const char* sp = std::getenv("WETOWL_ENGINE_SPLIT"); E->split = sp && sp[0] == '1'; }
  E->scratchL.assign(8192, 0.f); E->scratchR.assign(8192, 0.f);
  E->limiter.init(E->rate);
  E->master.now = E->master.target = 1;
  for (int i = 0; i < WE_DECKS; i++) {
    Deck& d = E->decks[(size_t)i];
    d.index = i;
    d.level.now = d.level.target = 1;
    for (auto& s : d.slots) { s.gain.now = s.gain.target = 0; for (auto& p : s.pair) p.now = p.target = 1; }
    d.bands.init(E->rate); d.filter.init(E->rate); d.echo.init(E->rate);
  }
  if (E->device && ma_device_start(&E->dev) != MA_SUCCESS) {
    lastError = "the sound card would not start";
    ma_device_uninit(&E->dev);
    delete E; E = nullptr;
    return 2;
  }
  return 0;
}

WE_API void we_stop(void) {
  if (!E) return;
  if (E->device) ma_device_uninit(&E->dev);
  freeRetired();
  for (auto* s : E->sources) delete s;
  for (auto& d : E->decks) delete d.beats;
  delete E; E = nullptr;
}

WE_API const char* we_error(void) { return lastError.c_str(); }
WE_API int we_rate(void) { return E ? E->rate : 0; }
WE_API double we_latency(void) { return E ? E->latency : 0; }
WE_API double we_now(void) { return now(); }

WE_API void we_stretch(int faster) {
  if (!E) return;
  E->stretchPinned = true;
  if (E->faster.exchange(faster != 0) != (faster != 0)) E->revoice = true;
}

WE_API void we_load(we_load_state* out) {
  if (!out) return;
  *out = we_load_state{};
  if (!E) return;
  out->average = E->loadAvg.load();
  out->worst = E->loadWorst.exchange(0);
  out->late = E->late.load();
  out->faster = E->faster.load() ? 1 : 0;
  out->period = E->period;
}

WE_API void we_render(float* out, int frames, float** decks) {
  if (!E || E->device) return;
  if (E->revoice) { E->revoice = false; revoiceAll(); }
  renderAll(out, frames, decks);
  freeRetired();
}

WE_API int we_source_new(int channels, int64_t hint) {
  if (!E || (channels != 1 && channels != 2 && channels != 6)) return 0;
  freeRetired();
  const int64_t most = std::max<int64_t>(hint * 2, (int64_t)E->rate * 3 * 3600);
  auto* s = new Source(channels, most);
  std::lock_guard<std::mutex> g(E->srcLock);
  E->sources.push_back(s);
  return (int)E->sources.size() - 1;
}

WE_API int we_source_append(int id, const int16_t* pcm, int64_t frames) {
  if (!E) return -1;
  Source* s = nullptr;
  { std::lock_guard<std::mutex> g(E->srcLock); if (id > 0 && id < (int)E->sources.size()) s = E->sources[(size_t)id]; }
  if (!s) return -1;
  int64_t at = s->frames.load();
  int64_t done = 0;
  while (done < frames) {
    const size_t c = (size_t)(at >> kChunkBits);
    if (c >= s->chunks.size()) return -1;
    if (!s->chunks[c]) s->chunks[c] = new (std::nothrow) int16_t[(size_t)kChunk * (size_t)s->channels];
    if (!s->chunks[c]) return -1;
    const int64_t room = kChunk - (at & (kChunk - 1));
    const int64_t n = std::min(room, frames - done);
    std::memcpy(s->chunks[c] + (at & (kChunk - 1)) * s->channels, pcm + done * s->channels, (size_t)(n * s->channels) * sizeof(int16_t));
    at += n; done += n;
    s->frames.store(at, std::memory_order_release);
  }
  return 0;
}

WE_API void we_source_done(int id) {
  if (!E) return;
  std::lock_guard<std::mutex> g(E->srcLock);
  if (id > 0 && id < (int)E->sources.size() && E->sources[(size_t)id]) E->sources[(size_t)id]->done = true;
}

WE_API int64_t we_source_frames(int id) {
  if (!E) return 0;
  std::lock_guard<std::mutex> g(E->srcLock);
  if (id > 0 && id < (int)E->sources.size() && E->sources[(size_t)id]) return E->sources[(size_t)id]->frames.load();
  return 0;
}

WE_API void we_source_free(int id) { Cmd c{kFreeSource}; c.i0 = id; push(c); freeRetired(); }

WE_API void we_deck_source(int deck, int slot, int source) {
  if (slot < 0 || slot >= WE_SOURCES) return;
  Cmd c{kSource}; c.deck = deck; c.i0 = slot; c.i1 = source; push(c);
}
WE_API void we_deck_source_gain(int deck, int slot, float gain, float drums, float rest, float vocals, double ramp) {
  if (slot < 0 || slot >= WE_SOURCES) return;
  Cmd c{kSourceGain}; c.deck = deck; c.i0 = slot; c.f0 = gain; c.f1 = drums; c.f2 = rest; c.f3 = vocals; c.d0 = ramp; push(c);
}
WE_API void we_deck_play(int deck, int playing) { Cmd c{kPlay}; c.deck = deck; c.i0 = playing; push(c); }
WE_API void we_deck_seek(int deck, double t) { Cmd c{kSeek}; c.deck = deck; c.d0 = t; push(c); }
WE_API void we_deck_rate(int deck, double rate) { Cmd c{kRate}; c.deck = deck; c.d0 = rate; push(c); }
WE_API void we_deck_bend(int deck, double f) { Cmd c{kBend}; c.deck = deck; c.d0 = f; push(c); }
WE_API void we_deck_keylock(int deck, int on) { Cmd c{kKeylock}; c.deck = deck; c.i0 = on; push(c); }
WE_API void we_deck_shift(int deck, double semis) { Cmd c{kShift}; c.deck = deck; c.d0 = semis; push(c); }
WE_API void we_deck_beats(int deck, const double* times, int count) {
  Cmd c{kBeats}; c.deck = deck;
  c.beats = count >= 2 ? new std::vector<double>(times, times + count) : nullptr;
  push(c); freeRetired();
}
WE_API void we_deck_sync(int deck, int master, int every, double offset) {
  Cmd c{kSync}; c.deck = deck; c.i0 = master; c.i1 = every; c.d0 = offset; push(c);
}
WE_API void we_deck_bar_one(int deck, int beat) { Cmd c{kBarOne}; c.deck = deck; c.i0 = beat; push(c); }
WE_API void we_deck_start(int deck, int master, int every, double at, double offset) {
  Cmd c{kStart}; c.deck = deck; c.i0 = master; c.i1 = every; c.d1 = at; c.d0 = offset; push(c);
}
WE_API void we_deck_sync_offset(int deck, double offset) { Cmd c{kSyncOffset}; c.deck = deck; c.d0 = offset; push(c); }
WE_API void we_deck_align(int deck, int master, int every, double offset) {
  Cmd c{kAlign}; c.deck = deck; c.i0 = master; c.i1 = every; c.d0 = offset; push(c);
}
WE_API void we_deck_loop(int deck, double a, double b) { Cmd c{kLoop}; c.deck = deck; c.d0 = a; c.d1 = b; push(c); }
WE_API void we_deck_loop_beats(int deck, double beats, int bar) {
  Cmd c{kLoopBeats}; c.deck = deck; c.d1 = beats; c.i0 = bar; push(c);
}
WE_API void we_deck_level(int deck, float gain, double ramp) { Cmd c{kLevel}; c.deck = deck; c.f0 = gain; c.d0 = ramp; push(c); }
WE_API void we_deck_eq(int deck, float low, float mid, float high, double ramp) {
  Cmd c{kEq}; c.deck = deck; c.f0 = low; c.f1 = mid; c.f2 = high; c.d0 = ramp; push(c);
}
WE_API void we_deck_filter(int deck, float knob) { Cmd c{kFilter}; c.deck = deck; c.f0 = knob; push(c); }
WE_API void we_deck_gate(int deck, float depth, double period, double origin) {
  Cmd c{kGate}; c.deck = deck; c.f0 = depth; c.d1 = period; c.d2 = origin; push(c);
}
WE_API void we_deck_echo(int deck, float send, float dry, double beat) {
  Cmd c{kEcho}; c.deck = deck; c.f0 = send; c.f1 = dry; c.d1 = beat; push(c);
}
WE_API void we_deck_brake(int deck, double seconds) { Cmd c{kBrake}; c.deck = deck; c.d0 = seconds; push(c); }
WE_API void we_master_level(float gain) { Cmd c{kMaster}; c.f0 = gain; push(c); }

WE_API void we_deck_read(int deck, we_deck_state* out) {
  if (!E || deck < 0 || deck >= WE_DECKS || !out) return;
  State& st = E->states[(size_t)deck];
  for (int tries = 0; tries < 1000; tries++) {
    const uint32_t a = st.seq.load(std::memory_order_acquire);
    if (a & 1) continue;
    we_deck_state copy = st.s;
    const uint32_t b = st.seq.load(std::memory_order_acquire);
    if (a == b) {
      *out = copy;
      // peaks are "since the last read"
      st.s.peak_l = st.s.peak_r = 0;
      return;
    }
  }
}

WE_API double we_deck_position(int deck) {
  we_deck_state s{};
  we_deck_read(deck, &s);
  if (!s.playing || s.rate <= 0) return s.heard;
  return s.heard + (now() - s.at) * s.rate;
}

}  // extern "C"
