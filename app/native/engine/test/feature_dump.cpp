// A record played through the engine offline, its measures (we_features) printed a
// row per read: the scales in tap.h are set from these, against pulse.py's own
// on the same records (test/feature_calibrate.py).
//
//   ffmpeg -v error -i song.m4a -ac 2 -ar 48000 -f s16le - > /tmp/x.raw
//   build/feature_dump /tmp/x.raw [--hz 60] [--eq-low-kill-at s] [--no-tap] > rows.csv
//
// Columns: t, then sub low mid high air kick snare hat onset rms peak rows, of the
// master; t is the moment read (the engine's clock, which offline is the frames
// rendered).
#include "we_engine.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "feature_dump <s16le stereo 48k> [--hz n] [--eq-low-kill-at s]\n"); return 2; }
  int hz = 60;
  double killAt = -1;
  bool tap = true;
  for (int i = 2; i + 1 < argc; i++) {
    if (!std::strcmp(argv[i], "--hz")) hz = std::atoi(argv[++i]);
    else if (!std::strcmp(argv[i], "--eq-low-kill-at")) killAt = std::atof(argv[++i]);
  }
  bool device = false;
  for (int i = 2; i < argc; i++) {
    if (!std::strcmp(argv[i], "--no-tap")) tap = false;  // the render's own cost
    if (!std::strcmp(argv[i], "--device")) device = true;  // played on the sound card, read as the show reads
  }
  FILE* f = std::fopen(argv[1], "rb");
  if (!f) { std::perror(argv[1]); return 1; }
  std::vector<int16_t> pcm;
  int16_t buf[65536];
  size_t got;
  while ((got = std::fread(buf, sizeof(int16_t), 65536, f)) > 0) pcm.insert(pcm.end(), buf, buf + got);
  std::fclose(f);
  const int64_t frames = (int64_t)pcm.size() / 2;

  if (we_start(device ? 0 : 48000, device ? 1 : 0) != 0) { std::fprintf(stderr, "engine: %s\n", we_error()); return 1; }
  const int src = we_source_new(2, frames);
  we_source_append(src, pcm.data(), frames);
  we_source_done(src);
  we_deck_source(0, 0, src);
  we_deck_source_gain(0, 0, 1, 1, 1, 1, 0);
  we_deck_play(0, 1);

  we_features_state s{};
  if (tap) we_features(WE_MASTER, 0, 0, &s);  // turns the measuring on
  if (device) {
    // Read as the show does, every few milliseconds at the clock plus the latency;
    // each row with where the deck is heard at its moment (record seconds).
    std::fprintf(stderr, "device: %d Hz, latency %.1f ms\n", we_rate(), we_latency() * 1000);
    std::printf("at,kick,snare,hat,low,heard,rows\n");
    double last = we_now();
    const double end = last + (double)frames / 48000 + 0.5;
    while (we_now() < end) {
      std::this_thread::sleep_for(std::chrono::milliseconds(4));
      const double to = we_now() + we_latency();
      if (we_features(WE_MASTER, last, to, &s) && s.rows > 0) {
        we_deck_state d{};
        we_deck_read(0, &d);
        const double heard = d.heard + (s.at - d.at) * d.rate;
        std::printf("%.5f,%.4f,%.4f,%.4f,%.4f,%.5f,%d\n", s.at, s.kick, s.snare, s.hat, s.low, heard, s.rows);
      }
      last = to;
    }
    we_stop();
    return 0;
  }
  const int step = 48000 / hz;
  std::vector<float> out((size_t)step * 2);
  double last = 0;
  bool killed = false;
  std::printf("t,sub,low,mid,high,air,kick,snare,hat,onset,rms,peak,rows\n");
  for (int64_t done = 0; done < frames; done += step) {
    we_render(out.data(), step, nullptr);
    const double t = we_now();
    if (killAt >= 0 && !killed && t >= killAt) { we_deck_eq(0, -40, 0, 0, 0); killed = true; }
    if (tap && we_features(WE_MASTER, last, t, &s)) {
      std::printf("%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d\n", t, s.sub, s.low, s.mid, s.high, s.air,
                  s.kick, s.snare, s.hat, s.onset, s.rms, s.peak, s.rows);
    }
    last = t;
  }
  we_stop();
  return 0;
}
