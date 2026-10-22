// The native stage with no window: every frame timed with a glFinish, on the GPU
// asked for, and the last one written out — the spike's measure (does a scene hold
// 60 frames a second at full size, on the iGPU and on the NVIDIA card) and its eye.
//
//   stage_bench --shaders app/shaders/show --scene flash --size 1920x1080 [--scale 1]
//               [--device n] [--frames 300] [--trails 0.8] [--ppm out.ppm] [--list]
//               [--milk preset] [--ground black|white|wash|milk|field:<name>] [--blend 0..3] [--mask 0..2] [--m1 v]
//               (with --milk the ground is MilkDrop in contrast unless said otherwise; blend 0 normal 1 add 2 screen 3 contrast, mask 0 none 1 keyhole 2 inverted)
// A synthetic record plays: 128 BPM, a kick each beat, a snare on two and four.
#include "ws_stage.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  std::string dir = "shaders/show", scene = "flash", ppm, milk;
  std::string ground;
  int blend = -1, mask = 0;
  float m1 = 0;
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
    else if (a == "--ground") ground = next();
    else if (a == "--blend") blend = std::atoi(next().c_str());
    else if (a == "--mask") mask = std::atoi(next().c_str());
    else if (a == "--m1") m1 = (float)std::atof(next().c_str());
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
  ws_scene(scene.c_str());
  ws_post(trails, bloom, 0.6f, 0.4f, 1, 0.006f);
  if (!milk.empty()) {
    ws_milk("open 960 540 60", nullptr, 0);
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
  std::vector<uint8_t> px((size_t)W * H * 4);
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
    if (!milk.empty()) {
      // A kick's thump, in samples, and the levels the booth sends.
      int16_t pcm[735];
      for (int i = 0; i < 735; i++) pcm[i] = (int16_t)(20000 * kick * std::sin((f * 735 + i) * 0.0078) + 3000 * std::sin((f * 735 + i) * 0.31));
      char line[64];
      std::snprintf(line, sizeof line, "pcm %d", 735);
      ws_milk(line, (const uint8_t*)pcm, (int)sizeof pcm);
      std::snprintf(line, sizeof line, "audio %.3f 1 1 1 1 1", 0.55 + 1.7 * kick);
      ws_milk(line, nullptr, 0);
    }
    ws_bench(1, f + 1 == frames && !ppm.empty() ? px.data() : nullptr);
    ws_stats_t s{};
    ws_stats(&s);
    if (f >= 10) { total += s.frame_ms; timed++; }
    if (f >= 10 && s.worst_ms > worst) worst = s.worst_ms;
  }
  char said[2048];
  if (ws_milk_said(said, sizeof said) > 0) std::printf("milk said: %s", said);
  ws_stats_t s{};
  ws_stats(&s);
  // frame_ms is smoothed; the plain mean is what is reported.
  std::printf("%s %dx%d work %dx%d %s: %.2f ms a frame (worst %.2f) → %.0f fps\n", scene.c_str(), W, H, s.work_width, s.work_height,
              s.float_targets ? "RGBA16F" : "RGBA8", total / std::max(1, timed), worst, 1000.0 / (total / std::max(1, timed)));
  if (!ppm.empty()) {
    FILE* f = std::fopen(ppm.c_str(), "wb");
    std::fprintf(f, "P6 %d %d 255\n", W, H);
    for (int y = H - 1; y >= 0; y--)
      for (int x = 0; x < W; x++) std::fwrite(&px[((size_t)y * W + x) * 4], 1, 3, f);
    std::fclose(f);
  }
  return 0;
}
