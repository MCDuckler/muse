// The native stage with no window: every frame timed with a glFinish, on the GPU
// asked for, and the last one written out — the spike's measure (does a scene hold
// 60 frames a second at full size, on the iGPU and on the NVIDIA card) and its eye.
//
//   stage_bench --shaders app/shaders/show --scene flash --size 1920x1080 [--scale 1]
//               [--device n] [--frames 300] [--trails 0.8] [--ppm out.ppm] [--list]
//               [--milk preset [--milk-textures dir]] [--ground black|white|wash|milk|field:<name>] [--blend 0..3] [--mask 0..2] [--m1 v]
//               [--treat mode] [--cell px]   (the scene through dance_fx.frag's mode: 8 the crt…)
//               [--type3d look] [--bends 0..2] (--scene ignored: the 3D type, a made-up field of three
//                                              blocks, turning; look 0 chrome … 10 mercury; bends 1:
//                                              inflate, ripple, melt, wobble, arc; 2: and a morph, the
//                                              echoes, the rows repeated)
//               (with --milk the ground is MilkDrop in contrast unless said otherwise; blend 0 normal 1 add 2 screen 3 contrast, mask 0 none 1 keyhole 2 inverted)
//               [--slime look] (--scene ignored: the veins, fx.h; look 0 glow 1 ink 2 contours 3 relief;
//                               [--species n] [--agents side])
//               [--slit shape] (the scene through the slit-scan, fx.h: 0 rows 1 columns 2 out from
//                               the middle 3 a wave 4 bands 5 out from the middle line)
//               [--milk-size WxH] (MilkDrop's own picture, 960x540 unless said)
//               [--audio pcm.raw --feed feed.f32] (a real record for MilkDrop: s16 mono 44.1 kHz,
//                               and per frame 8 floats — bass mid treb, their followers, the
//                               kick, the snare — as the booth would send; tools/show-audit/
//                               milk_feed.py makes both)
//               [--accent w] (MilkDrop's accents, wo_fx_*, on the kick as hard as w: milk_accent.dart's
//                               kick landing with a push, a turn and a flash)
//               [--stats out.f32] (per frame the picture's mean light and how much it moved
//                               since the frame before, two floats; read back every frame)
//               [--mosh scene] (the first half --scene, then a datamosh into this one; --ppm-at f
//                               writes frame f instead of the last; --ppm-at f,g,… each of
//                               them, as <ppm>.<f>.ppm)
//               [--mosh-hold grain] (the datamosh held from frame 10 on, as mosh_clock.dart
//                               would drive it in a verse: a little healed on each bar, a key
//                               frame every 8 bars; grain 0..1)
// A synthetic record plays: 128 BPM, a kick each beat, a snare on two and four.
#include "ws_stage.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  std::string dir = "shaders/show", scene = "flash", ppm, milk, milkTextures;
  std::string ground;
  int blend = -1, mask = 0;
  float m1 = 0, cell = 0;
  int treat = 0, type3d = -1, bends = 0, slime = -1, species = 3, agents = 640, slit = -1, ppmAt = -1;
  std::vector<int> ppmAts;  // several frames, each its own file
  std::string mosh, audio, feed, stats;
  float moshHold = -1;
  int milkW = 960, milkH = 540;
  float accent = 0;
  float expo = 0.3f, mapScale = 1.0f;
  std::vector<std::pair<int, float>> qs;  // --q i=v: the veins' float i set to v
  int W = 1920, H = 1080, frames = 300, device = -1;
  float scale = 1, trails = 0, bloom = 0.6f;
  bool list = false;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
    if (a == "--shaders") dir = next();
    else if (a == "--scene") scene = next();
    else if (a == "--size") { std::string s = next(); std::sscanf(s.c_str(), "%dx%d", &W, &H); }
    else if (a == "--scale") scale = std::atof(next().c_str());
    else if (a == "--frames") frames = std::atoi(next().c_str());
    else if (a == "--device") device = std::atoi(next().c_str());
    else if (a == "--trails") trails = std::atof(next().c_str());
    else if (a == "--bloom") bloom = std::atof(next().c_str());
    else if (a == "--ppm") ppm = next();
    else if (a == "--list") list = true;
    else if (a == "--milk") milk = next();
    else if (a == "--milk-textures") milkTextures = next();
    else if (a == "--ground") ground = next();
    else if (a == "--blend") blend = std::atoi(next().c_str());
    else if (a == "--mask") mask = std::atoi(next().c_str());
    else if (a == "--m1") m1 = (float)std::atof(next().c_str());
    else if (a == "--treat") treat = std::atoi(next().c_str());
    else if (a == "--type3d") type3d = std::atoi(next().c_str());
    else if (a == "--bends") bends = std::atoi(next().c_str());
    else if (a == "--cell") cell = (float)std::atof(next().c_str());
    else if (a == "--slime") slime = std::atoi(next().c_str());
    else if (a == "--species") species = std::atoi(next().c_str());
    else if (a == "--agents") agents = std::atoi(next().c_str());
    else if (a == "--expo") expo = (float)std::atof(next().c_str());
    else if (a == "--map") mapScale = (float)std::atof(next().c_str());
    else if (a == "--q") { int i = 0; float x = 0; if (std::sscanf(next().c_str(), "%d=%f", &i, &x) == 2) qs.push_back({i, x}); }
    else if (a == "--slit") slit = std::atoi(next().c_str());
    else if (a == "--mosh") mosh = next();
    else if (a == "--mosh-hold") moshHold = (float)std::atof(next().c_str());
    else if (a == "--milk-size") { std::string v = next(); std::sscanf(v.c_str(), "%dx%d", &milkW, &milkH); }
    else if (a == "--audio") audio = next();
    else if (a == "--feed") feed = next();
    else if (a == "--stats") stats = next();
    else if (a == "--accent") accent = (float)std::atof(next().c_str());
    else if (a == "--ppm-at") {
      const std::string v = next();
      ppmAt = std::atoi(v.c_str());
      for (size_t at = 0; at != std::string::npos; at = v.find(',', at), at = at == std::string::npos ? at : at + 1)
        ppmAts.push_back(std::atoi(v.c_str() + at));
      if (ppmAts.size() < 2) ppmAts.clear();
    }
  }
  if (list) {
    auto queryDevices = (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    auto queryString = (PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress("eglQueryDeviceStringEXT");
    EGLDeviceEXT devices[16];
    EGLint n = 0;
    if (queryDevices && queryDevices(16, devices, &n)) {
      for (int i = 0; i < n; i++) {
        const char* ext = queryString ? queryString(devices[i], EGL_EXTENSIONS) : "";
        const char* node = queryString ? queryString(devices[i], 0x3233 /* EGL_DRM_DEVICE_FILE_EXT */) : nullptr;
        std::printf("device %d: %s %s\n", i, node ? node : "-", ext && std::strstr(ext, "mesa") ? "(mesa)" : "");
      }
    }
    return 0;
  }
  ws_shaders(dir.c_str());
  if (ws_attach_headless(device) != 0) { std::fprintf(stderr, "stage: %s\n", ws_error()); return 1; }
  std::printf("GL: %s / %s\n", (const char*)glGetString(0x1F01), (const char*)glGetString(0x1F02));
  ws_size(W, H, scale);
  // The 3D type: a field of three blocks with a hole each (16 bits: red high, green
  // low; 0.5 the edge, 20 pixels every 0.5), as show_type3d.dart would send.
  const int tw = 600, th = 200;
  if (type3d >= 0) {
    scene = "@sim:type3d";
    std::vector<uint8_t> f((size_t)tw * th * 4, 0);
    for (int y = 0; y < th; y++) {
      for (int x = 0; x < tw; x++) {
        float best = 1e9f;
        for (int k = 0; k < 3; k++) {
          const float cx = 120.0f + k * 180.0f, cy = 100.0f;
          const float dx = std::fabs(x - cx) - 60.0f, dy = std::fabs(y - cy) - 70.0f;
          const float out = std::sqrt(std::max(dx, 0.0f) * std::max(dx, 0.0f) + std::max(dy, 0.0f) * std::max(dy, 0.0f)) + std::min(std::max(dx, dy), 0.0f);
          const float hole = 22.0f - std::sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
          best = std::min(best, std::max(out, hole));
        }
        const int v = (int)std::lround(std::clamp(0.5f + best / 40.0f, 0.0f, 1.0f) * 65535);
        uint8_t* o = &f[((size_t)y * tw + x) * 4];
        o[0] = (uint8_t)(v >> 8); o[1] = (uint8_t)(v & 255); o[3] = 255;
      }
    }
    ws_dance_texture("type3d.sdf", tw, th, f.data(), 0);
    ws_dance_texture("type3d.sdfb", tw, th, f.data(), 0);
  }
  if (slime >= 0) scene = "@slime";
  ws_scene(scene.c_str());
  ws_post(trails, bloom, 0.6f, 0.4f, 1, 0.006f);
  if (!milk.empty()) {
    ws_milk(("open " + std::to_string(milkW) + " " + std::to_string(milkH) + " 60" + (milkTextures.empty() ? std::string() : " " + milkTextures)).c_str(), nullptr, 0);
    ws_milk(("preset " + milk).c_str(), nullptr, 0);
    if (ground.empty()) ground = "milk";
    if (blend < 0) blend = 3;
  }
  if (!ground.empty()) {
    int kind = 0;
    std::string field;
    if (ground == "wash") kind = 1;
    else if (ground == "milk") kind = 2;
    else if (ground == "white") kind = 7;
    else if (ground.rfind("field:", 0) == 0) { kind = 4; field = ground.substr(6); }
    ws_ground(kind, field.empty() ? nullptr : field.c_str(), 1.0f, nullptr);
  }
  // The blend (0 normal 1 add 2 screen 3 contrast), the mask (0 none 1 keyhole
  // 2 inverted); a shader scene's figure is its light.
  ws_blend(blend < 0 ? 0 : blend, mask, 2, 1.0f);
  // A treatment over the scene: its pass needs a glyph atlas, any will do here.
  if (treat > 0) {
    std::vector<uint8_t> glyphs(64 * 16 * 4, 255);
    ws_dance_texture("glyphs", 64, 16, glyphs.data(), 0);
    // mode cell(÷ height) ink3 paper3 tint glyphs pop popX popY time, the knobs
    const float t[WS_TREAT] = {(float)treat, (cell > 0 ? cell : 8.0f) / H, 0.965f, 0.86f, 1.0f, 0.027f, 0.008f, 0.06f, 0.2f, 4, 0, 0.5f, 0.5f, 0, 1, 1, 1, 1, 1};
    ws_treat(t, WS_TREAT);
  }
  if (slit >= 0) {
    // mode 9, the shape, flipped no, the kick, the time; the weight knob all the way back
    float t[WS_TREAT] = {};
    t[0] = 9; t[1] = (float)slit; t[14] = 1; t[15] = 1;
    ws_treat(t, WS_TREAT);
  }
  // A real record: its sound and what the booth would make of it, frame by frame.
  auto slurp = [](const std::string& path) {
    std::vector<uint8_t> out;
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return out;
    std::fseek(f, 0, SEEK_END);
    out.resize((size_t)std::ftell(f));
    std::fseek(f, 0, SEEK_SET);
    out.resize(std::fread(out.data(), 1, out.size(), f));
    std::fclose(f);
    return out;
  };
  const std::vector<uint8_t> audioBytes = audio.empty() ? std::vector<uint8_t>() : slurp(audio);
  const std::vector<uint8_t> feedBytes = feed.empty() ? std::vector<uint8_t>() : slurp(feed);
  const int feedFrames = (int)(feedBytes.size() / (8 * sizeof(float)));
  if (!feed.empty() && feedFrames > 0) frames = std::min(frames, feedFrames);
  FILE* statsOut = stats.empty() ? nullptr : std::fopen(stats.c_str(), "wb");
  std::vector<float> lumaWas;
  std::vector<uint8_t> px((size_t)W * H * 4);
  auto writePpm = [&](const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return;
    std::fprintf(f, "P6 %d %d 255\n", W, H);
    for (int y = H - 1; y >= 0; y--)
      for (int x = 0; x < W; x++) std::fwrite(&px[((size_t)y * W + x) * 4], 1, 3, f);
    std::fclose(f);
  };
  double total = 0, worst = 0;
  int timed = 0;
  for (int f = 0; f < frames; f++) {
    const double t = f / 60.0;
    const double beats = t * 128 / 60;
    const double beat = beats - std::floor(beats);
    const int inBar = (int)std::floor(beats) % 4;
    float v[WS_COMMON - 2] = {};
    // uTime uBeat uBar uPhrase uEnergy uIntensity uKick uLow uMid uHigh uAir uOnset uHue uHue2 uDropNear uBuild uHit uVocal
    // uM1..4 uHitKick uHitSnare uHitTop uBeatDecay uBarDecay uBarSaw uPhraseSaw uDownbeat uExposure uBandLow uBandMid uBandHigh uBarIndex
    const float kick = (float)std::exp(-beat * 9);
    v[0] = (float)t; v[1] = (float)beat; v[2] = (float)((inBar + beat) / 4); v[3] = (float)std::fmod(beats / 16, 1.0);
    v[4] = 0.8f; v[5] = 0.8f; v[6] = kick; v[7] = 0.6f + 0.4f * kick; v[8] = 0.5f; v[9] = 0.4f; v[10] = 0.3f; v[11] = kick;
    v[12] = 0.62f; v[13] = 0.95f; v[14] = 0; v[15] = 0; v[16] = 0; v[17] = 0.2f; v[18] = m1;
    v[22] = kick; v[23] = (inBar % 2 == 1) ? (float)std::exp(-beat * 7) : 0; v[24] = (float)std::exp(-std::fmod(beat * 2, 1.0) * 10) * 0.5f;
    v[25] = (float)std::exp(-beat * 6); v[26] = (float)std::exp(-((inBar + beat) / 4) * 5); v[27] = (float)((inBar + beat) / 4);
    v[28] = (float)std::fmod(beats / 16, 1.0); v[29] = inBar == 0 ? (float)std::exp(-beat * 6) : 0; v[30] = 0.9f;
    v[31] = 0.5f + 0.5f * kick; v[32] = 0.5f; v[33] = 0.4f; v[34] = (float)std::floor(beats / 4);
    ws_inputs(v, WS_COMMON - 2);
    if (type3d >= 0) {
      // type3d.frag's floats in its order (show_type3d.dart's Type3dParams).
      const float yaw = (float)t * 0.9f, pitch = 0.25f * (float)std::sin(t);
      const float cy = std::cos(yaw), sy = std::sin(yaw), cp = std::cos(pitch), sp = std::sin(pitch);
      const float hx = tw / 2.0f / 140.0f, hy = th / 2.0f / 140.0f;
      const float mix = bends > 1 ? 0.5f + 0.5f * (float)std::sin(t * 2.0) : 0.0f;
      std::vector<float> q = {(float)W, (float)H, (float)t,
                              cy, 0, -sy, sy * sp, cp, cy * sp, sy * cp, -sp, cy * cp,
                              0, 0, -4.2f,
                              hx, hy, hx, hy, 20.0f / 140.0f, 20.0f / 140.0f, mix, 0, 1.3f,
                              0.11f, 0.02f, 0.0f, (float)beats * 3.14159f, 0.0f,
                              // inflate ripple phase melt · slice shatter wobble squash · arc stack gap repeat
                              bends > 0 ? kick * 0.5f : 0, bends > 0 ? 0.8f : 0, (float)beats * 6.283f, bends > 0 ? 0.3f : 0,
                              0, 0, bends > 0 ? 0.8f : 0, 0,
                              bends > 0 ? 0.2f : 0, bends > 1 ? 1.0f : 0, 0.12f, bends > 1 ? 1.6f : 0,
                              (float)type3d,
                              0.9f, 0.75f, 1.0f, 0.35f, 0.12f, 0.66f, 1.0f, 0.3f, 0.85f,
                              0.6f, kick, 0.0f, 1.7f, 1.0f, 1.0f, 0.0f, 0.0f};
      ws_words(q.data(), (int)q.size());
    }
    if (!milk.empty() && feedFrames > 0) {
      // The record's own: its 735 samples a frame, and the booth's levels.
      const size_t at = (size_t)f * 735 * 2;
      if (at + 735 * 2 <= audioBytes.size()) {
        ws_milk("pcm 735", audioBytes.data() + at, 735 * 2);
      }
      const float* lv = reinterpret_cast<const float*>(feedBytes.data()) + (size_t)f * 8;
      char line[128];
      std::snprintf(line, sizeof line, "audio %.3f %.3f %.3f %.3f %.3f %.3f", lv[0], lv[1], lv[2], lv[3], lv[4], lv[5]);
      ws_milk(line, nullptr, 0);
      std::snprintf(line, sizeof line, "vars wo_hit_kick=%.3f wo_hit_snare=%.3f wo_playing=1", lv[6], lv[7]);
      ws_milk(line, nullptr, 0);
      if (accent > 0) {
        const float k = lv[6], side = (f / 30) % 2 ? 1.0f : -1.0f;
        static const float zk = std::getenv("ACC_ZOOM") ? std::atof(std::getenv("ACC_ZOOM")) : 0.03f;
        static const float fk = std::getenv("ACC_FLASH") ? std::atof(std::getenv("ACC_FLASH")) : 0.25f;
        static const float dk = std::getenv("ACC_DECAY") ? std::atof(std::getenv("ACC_DECAY")) : 0.0f;
        static const float ak = std::getenv("ACC_AMP") ? std::atof(std::getenv("ACC_AMP")) : 1.0f;
        std::snprintf(line, sizeof line, "vars wo_fx_amp=%.4f wo_fx_zoom=%.4f wo_fx_rot=%.4f wo_fx_flash=%.4f wo_fx_decay=%.4f",
                      ak * accent * (0.3f + 0.9f * k), zk * accent * k, 0.05f * accent * k * side, fk * accent * k, dk * accent);
        ws_milk(line, nullptr, 0);
      }
    } else if (!milk.empty()) {
      // A kick's thump, in samples, and the levels the booth sends.
      int16_t pcm[735];
      for (int i = 0; i < 735; i++) pcm[i] = (int16_t)(20000 * kick * std::sin((f * 735 + i) * 0.0078) + 3000 * std::sin((f * 735 + i) * 0.31));
      char line[64];
      std::snprintf(line, sizeof line, "pcm %d", 735);
      ws_milk(line, (const uint8_t*)pcm, (int)sizeof pcm);
      std::snprintf(line, sizeof line, "audio %.3f 1 1 1 1 1", 0.55 + 1.7 * kick);
      ws_milk(line, nullptr, 0);
    }
    if (slime >= 0) {
      // The veins' rules (fx.h's SlimeAt), as show_veins.dart would send them.
      std::vector<float> q(160, 0.0f);
      q[0] = (float)agents; q[1] = 1.0f + 0.8f * kick; q[2] = 0.4f; q[3] = 18; q[4] = 0.4f; q[5] = 0.03f;
      q[6] = 0.15f; q[7] = 0.9f; q[8] = 0.5f; q[9] = (float)species; q[10] = 0.5f;
      q[11] = (float)std::floor(beats / 32); q[12] = (float)((int)std::floor(beats / 32) % 6); q[13] = 0.4f;
      q[14] = 0.5f; q[15] = 0.5f; q[16] = 0; q[17] = 0.4f;
      q[18] = (float)slime; q[19] = expo; q[20] = (float)t; q[21] = kick; q[22] = (inBar % 2 == 1) ? (float)std::exp(-beat * 7) : 0;
      const float cols[9] = {0.95f, 0.35f, 0.55f, 0.3f, 0.75f, 1.0f, 1.0f, 0.8f, 0.3f};
      for (int k = 0; k < 9; k++) q[23 + k] = cols[k];
      q[32] = 2;
      q[33] = 0.5f + 0.3f * (float)std::cos(beats * 0.4); q[34] = 0.5f + 0.3f * (float)std::sin(beats * 0.4); q[35] = 3 * kick; q[36] = 0.02f;
      q[37] = 0.5f - 0.3f * (float)std::cos(beats * 0.4); q[38] = 0.5f - 0.3f * (float)std::sin(beats * 0.4); q[39] = 3 * kick; q[40] = 0.02f;
      q[65] = mapScale;
      for (auto [i, x] : qs) if (i >= 0 && i < 160) q[i] = x;
      ws_words(q.data(), 66);
    }
    if (slit >= 0) {
      float tq[WS_TREAT] = {};
      tq[0] = 9; tq[1] = (float)slit; tq[10] = kick; tq[13] = (float)t; tq[14] = 1; tq[15] = 1;
      ws_treat(tq, WS_TREAT);
    }
    if (moshHold >= 0) {
      // On each bar a little healed (a few patches let through), a key frame every 8.
      const double barPhase = std::fmod(beats, 4.0) / 4.0;
      const float pulse = (float)std::exp(-barPhase * 14.0);
      const float hold[WS_MOSH_HOLD] = {f >= 10 ? 1.0f : 0.0f, 0.22f + 0.38f * pulse, 1.2f, moshHold, (float)std::floor(beats / 32.0)};
      ws_mosh_hold(hold, WS_MOSH_HOLD);
    }
    if (!mosh.empty() && f == frames / 2) {
      ws_scene(mosh.c_str());
      ws_mosh(1.9f, 1.0f);
    }
    const bool many = std::find(ppmAts.begin(), ppmAts.end(), f) != ppmAts.end();
    const bool shoot = !ppm.empty() && (many || (ppmAts.empty() && (ppmAt >= 0 ? f == ppmAt : f + 1 == frames)));
    ws_bench(1, shoot || statsOut ? px.data() : nullptr);
    if (many) writePpm(ppm + "." + std::to_string(f) + ".ppm");
    if (statsOut) {
      // Every fourth pixel each way: the mean light, and the mean change since the last.
      std::vector<float> luma;
      luma.reserve((size_t)(W / 4) * (H / 4));
      double sum = 0, moved = 0;
      for (int y = 0; y < H; y += 4)
        for (int x = 0; x < W; x += 4) {
          const uint8_t* q = &px[((size_t)y * W + x) * 4];
          const float l = (0.2126f * q[0] + 0.7152f * q[1] + 0.0722f * q[2]) / 255.0f;
          luma.push_back(l);
          sum += l;
        }
      if (lumaWas.size() == luma.size())
        for (size_t i = 0; i < luma.size(); i++) moved += std::fabs(luma[i] - lumaWas[i]);
      const float row[2] = {(float)(sum / luma.size()), (float)(moved / luma.size())};
      std::fwrite(row, sizeof(float), 2, statsOut);
      lumaWas.swap(luma);
    }
    ws_stats_t s{};
    ws_stats(&s);
    if (f >= 10) { total += s.frame_ms; timed++; }
    if (f >= 10 && s.worst_ms > worst) worst = s.worst_ms;
  }
  if (statsOut) std::fclose(statsOut);
  char said[2048];
  if (ws_milk_said(said, sizeof said) > 0) std::printf("milk said: %s", said);
  ws_stats_t s{};
  ws_stats(&s);
  // frame_ms is smoothed; the plain mean is what is reported.
  std::printf("%s %dx%d work %dx%d %s: %.2f ms a frame (worst %.2f) → %.0f fps\n", scene.c_str(), W, H, s.work_width, s.work_height,
              s.float_targets ? "RGBA16F" : "RGBA8", total / std::max(1, timed), worst, 1000.0 / (total / std::max(1, timed)));
  if (!ppm.empty() && ppmAts.empty()) writePpm(ppm);
  return 0;
}
