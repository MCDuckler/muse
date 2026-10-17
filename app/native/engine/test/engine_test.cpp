// The engine rendered offline and measured on its own outputs: two click tracks
// at different tempos synced must put their clicks within half a millisecond of
// each other at once and for ten minutes, through master pitch moves, with key lock
// on and off; a loop of beats must come round in exactly that many beats; a jump
// and a loop seam must not click.
//
//   cmake -B build -DWETOWL_ENGINE_TESTS=ON && cmake --build build -j && build/engine_test
#include "we_engine.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <vector>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; std::printf("  FAIL %s:%d: ", __FILE__, __LINE__); std::printf(__VA_ARGS__); std::printf("\n"); } } while (0)

static const int R = 48000;

// A click track: a burst on every beat (louder on the bar's one), a quiet noise bed.
struct Track { std::vector<int16_t> pcm; std::vector<double> beats; };
static Track clicks(double bpm, double first, double seconds, unsigned seed) {
  Track t;
  const int64_t n = (int64_t)(seconds * R);
  t.pcm.assign((size_t)n * 2, 0);
  unsigned s = seed;
  for (int64_t i = 0; i < n; i++) {
    s = s * 1664525u + 1013904223u;
    const int16_t v = (int16_t)(((int)(s >> 16) - 32768) / 64);
    t.pcm[(size_t)i * 2] = v; t.pcm[(size_t)i * 2 + 1] = v;
  }
  const double spb = 60.0 / bpm;
  for (double b = first; b < seconds - 0.2; b += spb) {
    t.beats.push_back(b);
    const int64_t k = (int64_t)std::llround(b * R);
    const float amp = (t.beats.size() % 4 == 1) ? 0.9f : 0.6f;
    for (int j = 0; j < 240 && k + j < n; j++) {
      const float x = amp * std::exp(-j / 40.f) * std::sin(j * 0.9f);
      const int16_t v = (int16_t)std::clamp(x * 32767.f, -32767.f, 32767.f);
      t.pcm[(size_t)(k + j) * 2] = (int16_t)std::clamp(t.pcm[(size_t)(k + j) * 2] + v, -32767, 32767);
      t.pcm[(size_t)(k + j) * 2 + 1] = t.pcm[(size_t)(k + j) * 2];
    }
  }
  return t;
}

static int load(int deck, const Track& t) {
  const int src = we_source_new(2, (int64_t)t.pcm.size() / 2);
  we_source_append(src, t.pcm.data(), (int64_t)t.pcm.size() / 2);
  we_source_done(src);
  we_deck_source(deck, 0, src);
  we_deck_source_gain(deck, 0, 1, 1, 1, 1, 0);
  we_deck_beats(deck, t.beats.data(), (int)t.beats.size());
  we_deck_bar_one(deck, 0);
  return src;
}

// Renders seconds; each deck's output kept (stereo, post fader).
struct Run { std::vector<float> master, a, b; };
static void render(Run& run, double seconds, std::function<void(double)> at = nullptr) {
  const int block = 480;
  const int64_t n = (int64_t)(seconds * R);
  std::vector<float> m(block * 2), a(block * 2), b(block * 2), z(block * 2);
  for (int64_t done = 0; done < n; done += block) {
    if (at) at((double)(run.a.size() / 2) / R);
    float* decks[WE_DECKS] = {a.data(), b.data(), z.data(), z.data()};
    we_render(m.data(), block, decks);
    run.master.insert(run.master.end(), m.begin(), m.end());
    run.a.insert(run.a.end(), a.begin(), a.end());
    run.b.insert(run.b.end(), b.begin(), b.end());
  }
}

// Where the clicks are in a deck's output: the half-way rise of a 1 ms energy
// envelope, refined to the sample. Seconds.
static std::vector<double> onsets(const std::vector<float>& x, double from = 0.05) {
  std::vector<double> out;
  const size_t n = x.size() / 2;
  const int w = 48;
  std::vector<double> env(n, 0);
  double acc = 0;
  for (size_t i = 0; i < n; i++) {
    const double v = x[i * 2];
    acc += v * v;
    if (i >= (size_t)w) acc -= (double)x[(i - w) * 2] * x[(i - w) * 2];
    env[i] = acc / w;
  }
  const double floor = 0.0015;  // the noise bed sits far under this
  for (size_t i = (size_t)(from * R); i < n; i++) {
    if (env[i] > floor && env[i - 1] <= floor) {
      // the peak of the next 6 ms, then the half-way crossing before it
      size_t pk = i; for (size_t j = i; j < std::min(n, i + 288); j++) if (env[j] > env[pk]) pk = j;
      size_t k = pk; while (k > 0 && env[k] > env[pk] * 0.5) k--;
      out.push_back(((double)k - w / 2.0) / R);
      i = pk + (size_t)(0.1 * R);
    }
  }
  return out;
}

// Each of b's clicks against the nearest of a's: errors in ms.
static std::vector<double> apart(const std::vector<double>& a, const std::vector<double>& b, double from, double to) {
  std::vector<double> e;
  for (double t : b) {
    if (t < from || t > to) continue;
    auto it = std::lower_bound(a.begin(), a.end(), t);
    double best = 1e9;
    if (it != a.end()) best = *it - t;
    if (it != a.begin() && std::fabs(*(it - 1) - t) < std::fabs(best)) best = *(it - 1) - t;
    e.push_back(-best * 1000);
  }
  return e;
}

static double worst(const std::vector<double>& e) { double w = 0; for (double x : e) w = std::max(w, std::fabs(x)); return w; }

static void fresh() { we_stop(); we_start(R, 0); }

static void test_sync(bool keylock, bool late) {
  std::printf("sync, key lock %s, %s\n", keylock ? "on" : "off", late ? "SYNC pressed with both playing" : "started in step");
  fresh();
  auto A = clicks(124, 0.37, 700, 1), B = clicks(128, 0.21, 700, 2);
  load(0, A); load(1, B);
  we_deck_keylock(0, keylock); we_deck_keylock(1, keylock);
  we_deck_play(0, 1);
  Run run;
  if (late) {
    we_deck_seek(1, 3.3);  // well off the beat
    we_deck_play(1, 1);
    render(run, 2.0);
    we_deck_sync(1, 0, 1, 0);
  } else {
    render(run, 1.0);
    we_deck_seek(1, 10.0);
    we_deck_start(1, 0, 1, -1, 0);
    we_deck_sync(1, 0, 1, 0);
  }
  const double t0 = run.a.size() / 2.0 / R;
  render(run, 40, [&](double t) {
    if (t > t0 + 15 && t < t0 + 15.02) we_deck_rate(0, 1.04);   // the master's fader
    if (t > t0 + 27 && t < t0 + 27.02) we_deck_rate(0, 0.97);
  });
  auto ea = onsets(run.a), eb = onsets(run.b);
  auto first = apart(ea, eb, t0 + 0.02, t0 + 0.6);
  auto steady = apart(ea, eb, t0 + 0.6, t0 + 39);
  std::sort(steady.begin(), steady.end());
  std::printf("  first beats worst %.3f ms; then %zu clicks: median %.3f, worst %.3f ms\n",
              worst(first), steady.size(), steady.empty() ? 0 : steady[steady.size() / 2], worst(steady));
  CHECK(!first.empty() && worst(first) < 0.5, "the first beats after sync are %.3f ms apart", worst(first));
  CHECK(steady.size() > 60, "only %zu clicks found", steady.size());
  CHECK(worst(steady) < 0.5, "held %.3f ms apart at worst", worst(steady));
}

static void test_long_hold() {
  std::printf("ten minutes synced, key lock on\n");
  fresh();
  auto A = clicks(126, 0.5, 660, 3), B = clicks(122.37, 0.11, 660, 4);
  load(0, A); load(1, B);
  we_deck_play(0, 1);
  Run run;
  render(run, 0.5);
  we_deck_seek(1, 5);
  we_deck_start(1, 0, 1, -1, 0);
  we_deck_sync(1, 0, 1, 0);
  render(run, 600);
  auto e = apart(onsets(run.a), onsets(run.b), 590, 600);
  std::printf("  after ten minutes: worst %.3f ms over %zu clicks\n", worst(e), e.size());
  CHECK(!e.empty() && worst(e) < 0.5, "after ten minutes %.3f ms apart", worst(e));
}

static void test_loop(bool keylock) {
  std::printf("a loop of 4 beats, key lock %s\n", keylock ? "on" : "off");
  fresh();
  auto A = clicks(128, 0.25, 120, 5);
  load(0, A);
  we_deck_keylock(0, keylock);
  we_deck_rate(0, 1.03);
  we_deck_play(0, 1);
  Run run;
  render(run, 3.1);
  we_deck_loop_beats(0, 4, 0);
  render(run, 20);
  we_deck_state st{};
  we_deck_read(0, &st);
  const double len = st.loop_b - st.loop_a;
  const double expect = 4 * 60.0 / 128;
  CHECK(st.looping && std::fabs(len - expect) < 1e-6, "loop %.6f s, wanted %.6f", len, expect);
  // every click comes round once a loop: compare each with the one a loop earlier
  auto on = onsets(run.a, 4.0);
  const double period = len / 1.03;  // wall time of one loop
  double w = 0; int pairs = 0;
  for (size_t i = 0; i < on.size(); i++)
    for (size_t j = i + 1; j < on.size(); j++) {
      const double d = on[j] - on[i];
      if (std::fabs(d - period) < 0.02) { w = std::max(w, std::fabs(d - period) * 1000); pairs++; }
    }
  std::printf("  %d clicks a loop apart: worst %.3f ms off the loop's length\n", pairs, w);
  CHECK(pairs > 30, "only %d click pairs", pairs);
  CHECK(w < 0.3, "a loop came round %.3f ms off", w);
  // the clicks heard are the loop's: four a loop
  int inOne = 0; for (double t : on) if (t > 10 && t < 10 + period) inOne++;
  CHECK(inOne == 4, "%d clicks in one loop", inOne);
}

static void test_seam() {
  std::printf("a loop seam on a tone does not click\n");
  fresh();
  Track t;
  const int n = R * 30;
  t.pcm.assign((size_t)n * 2, 0);
  for (int i = 0; i < n; i++) { const int16_t v = (int16_t)(12000 * std::sin(2 * M_PI * 441.3 * i / R)); t.pcm[(size_t)i * 2] = v; t.pcm[(size_t)i * 2 + 1] = v; }
  for (double b = 0; b < 29; b += 0.5) t.beats.push_back(b);
  load(0, t);
  we_deck_keylock(0, 0);
  we_deck_play(0, 1);
  Run run;
  render(run, 1);
  we_deck_loop(0, 2.0001, 2.31234);  // ends nowhere near a zero crossing
  render(run, 5);
  double step = 0, typical = 0;
  for (size_t i = (size_t)R * 2; i + 2 < run.a.size() / 2; i++) {
    const double d = std::fabs(run.a[(i + 1) * 2] - run.a[i * 2]);
    step = std::max(step, d);
  }
  typical = 2 * M_PI * 441.3 / R * 12000 / 32768 * 0.5956621;  // the tone's own largest step
  std::printf("  largest step %.4f against the tone's own %.4f\n", step, typical);
  CHECK(step < typical * 1.6, "a step of %.4f at the seam (the tone's own %.4f)", step, typical);
}

static void test_jump() {
  std::printf("a seek is heard at once and does not gap\n");
  fresh();
  auto A = clicks(120, 0.5, 60, 6);
  load(0, A);
  we_deck_play(0, 1);
  Run run;
  render(run, 2.3);
  we_deck_seek(0, 20.25);   // a quarter beat before a click at 20.5? (beats at 0.5 + k/2)
  render(run, 1.0);
  auto on = onsets(run.a, 2.3);
  // the first click after the jump: 20.5 - 20.25 = 0.25 s after it
  CHECK(!on.empty() && std::fabs(on[0] - (2.3 + 0.25)) < 0.006, "first click after the seek at %.4f s, wanted %.4f",
        on.empty() ? -1 : on[0], 2.3 + 0.25);
  // no silence: the energy never drops to nothing around the jump
  double least = 1;
  for (size_t i = (size_t)(2.28 * R); i < (size_t)(2.34 * R); i += 48) {
    double e = 0; for (int j = 0; j < 48; j++) e += std::fabs(run.a[(i + j) * 2]);
    least = std::min(least, e / 48);
  }
  CHECK(least > 0.002, "the sound fell to %.5f around the jump", least);
}

static void test_start_at() {
  std::printf("started as the master is heard on a beat, from where it is parked\n");
  fresh();
  auto A = clicks(124, 0.37, 120, 8), B = clicks(130, 0.21, 120, 9);
  load(0, A); load(1, B);
  we_deck_play(0, 1);
  Run run;
  render(run, 1.3);
  // B parked on its beat 20, started as A is heard at its beat 8 (a moment ahead)
  we_deck_seek(1, B.beats[20]);
  we_deck_sync(1, 0, 1, 0);
  we_deck_start(1, 0, 1, A.beats[8], 0);
  render(run, 12);
  auto e = apart(onsets(run.a), onsets(run.b), 0, 13);
  std::printf("  %zu clicks: the first %.3f ms off, worst after it %.3f ms\n", e.size(), e.empty() ? 0 : e[0],
              e.size() > 1 ? worst(std::vector<double>(e.begin() + 1, e.end())) : 0);
  // The first click is the deck's first sound, under its 2 ms fade in: its onset reads
  // a fraction of a millisecond late for that alone.
  CHECK(e.size() > 10 && std::fabs(e[0]) < 1.0, "the first beat %.3f ms off", e.empty() ? 0 : e[0]);
  CHECK(e.size() > 10 && worst(std::vector<double>(e.begin() + 1, e.end())) < 0.5, "started %.3f ms off", worst(e));
  auto ob = onsets(run.b);
  const double wantFirst = A.beats[8] - 0.37 * 0 ;  // A plays from 0: heard at its own time
  CHECK(!ob.empty() && std::fabs(ob[0] - wantFirst) < 0.003, "first B click at %.4f, wanted %.4f", ob.empty() ? -1 : ob[0], wantFirst);
}

static void test_end() {
  std::printf("a record stops at its end\n");
  fresh();
  auto A = clicks(120, 0.5, 3, 10);
  load(0, A);
  we_deck_seek(0, 1.5);
  we_deck_play(0, 1);
  Run run;
  render(run, 2.5);
  we_deck_state st{}; we_deck_read(0, &st);
  CHECK(!st.playing && st.ended == 1, "playing %d ended %d", st.playing, st.ended);
}

static void test_brake() {
  std::printf("the brake stops the deck\n");
  fresh();
  auto A = clicks(120, 0.5, 30, 7);
  load(0, A);
  we_deck_play(0, 1);
  Run run;
  render(run, 1);
  we_deck_brake(0, 0.8);
  render(run, 1.5);
  we_deck_state st{}; we_deck_read(0, &st);
  CHECK(!st.playing, "still playing after the brake");
}

int main(int argc, char** argv) {
  const std::string only = argc > 1 ? argv[1] : "";
  auto want = [&](const char* name) { return only.empty() || only == name; };
  if (we_start(R, 0) != 0) { std::printf("engine would not start: %s\n", we_error()); return 1; }
  if (want("sync")) { test_sync(true, false); test_sync(false, false); test_sync(true, true); test_sync(false, true); }
  if (want("loop")) { test_loop(true); test_loop(false); }
  if (want("seam")) test_seam();
  if (want("jump")) test_jump();
  if (want("brake")) test_brake();
  if (want("start")) test_start_at();
  if (want("end")) test_end();
  if (want("long")) test_long_hold();
  we_stop();
  std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
  return failures ? 1 : 0;
}
