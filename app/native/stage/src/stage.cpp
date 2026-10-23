// The native stage. See ws_stage.h for what it offers.
//
// A frame:
//   0. the ground under the figure (lib/src/state/show/show_rig.dart), where the
//      blend wants one: black, a wash of the palette, MilkDrop's picture fitted to
//      the stage, or a field (a scene shader as a backdrop), into its own picture;
//   1. the scene — the figure — its .frag (the Flutter stage's own, fitted to GLSL
//      ES on load — glsl.h), at the working size into a half-float picture (RGBA16F
//      where the GPU can draw into one, else RGBA8); then the blend of the two
//      (shaders/show/under.frag): the figure's own pixels over the ground, its
//      backdrop the rig's way;
//   2. the trails, where the scene has them: shaders/show/feedback.frag again, over
//      last frame's picture — in floating point, so a trail fades all the way out
//      instead of sticking at the last step an 8-bit picture can hold;
//   3. the bloom: the picture halved five times with a 13-tap filter and brought back
//      up with a tent, each level added (a wide, smooth glow for a few cheap passes);
//   4. the finish, at the picture's full size into one of three RGBA8 textures: the
//      bloom added as light, the fringe and the vignette, the film curve, the grain,
//      and a dither so the 8 bits out show no bands.
// The newest finished texture is handed to whoever shows it (ws_latest) behind a
// fence; the thread never draws into the one handed out nor the newest one.
#include "ws_stage.h"
#include "glsl.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#ifdef WS_MILK
#include <projectM-4/projectM.h>
#include "milk_core.h"
#endif

#include "dance.h"
#include "fx.h"
#include "particles.h"
#include "target.h"

// ANGLE's EGL tokens (EGL/eglext_angle.h), for an eglext.h without them.
#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE 0x3208
#endif
#ifndef EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE 0x3209
#endif
#ifndef EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE
#define EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE 0x320A
#endif
#ifndef EGL_PLATFORM_ANGLE_DEVICE_TYPE_D3D_WARP_ANGLE
#define EGL_PLATFORM_ANGLE_DEVICE_TYPE_D3D_WARP_ANGLE 0x320B
#endif
#ifndef EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE
#define EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE 0x3200
#endif

#include <algorithm>
#include <atomic>
#include <cctype>
#include <deque>
#include <map>
#include <memory>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifndef WS_MILK
namespace milk {
// No MilkDrop in this build of the stage (Windows: projectM is the helper's there,
// and its frames come up as the texture named "milk", ws_dance_texture). The same
// shape as milk_core.h's, so the stage reads the same.
struct Core {
  std::function<void(const std::string&)> say = [](const std::string&) {};
  GLuint tex = 0;
  int width = 0, height = 0;
  bool open(int, int, int, const std::string&) { return false; }
  void close() {}
  bool command(const std::string&, const std::vector<uint8_t>&) { return false; }
  void render() {}
};
}  // namespace milk
#endif

namespace ws {

using Clock = std::chrono::steady_clock;

// The finishing passes, the stage's own.
static const char* kVert = R"(#version 300 es
out vec2 vUv;
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  vUv = p;
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

// Jimenez's 13-tap downsample (Call of Duty: Advanced Warfare's bloom).
static const char* kDown = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uSrc;
uniform vec2 uTexel;   // of the source
uniform float uFirst;  // 1 on the first level: bright parts only, a soft knee
out vec4 fragColor;
vec3 s(vec2 o) { return texture(uSrc, vUv + o * uTexel).rgb; }
void main() {
  vec3 a = s(vec2(-2, 2)), b = s(vec2(0, 2)), c = s(vec2(2, 2));
  vec3 d = s(vec2(-2, 0)), e = s(vec2(0, 0)), f = s(vec2(2, 0));
  vec3 g = s(vec2(-2, -2)), h = s(vec2(0, -2)), i = s(vec2(2, -2));
  vec3 j = s(vec2(-1, 1)), k = s(vec2(1, 1)), l = s(vec2(-1, -1)), m = s(vec2(1, -1));
  vec3 col = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
  if (uFirst > 0.5) {
    float lum = max(col.r, max(col.g, col.b));
    float knee = smoothstep(0.35, 0.9, lum);
    col *= knee;
  }
  fragColor = vec4(col, 1.0);
}
)";

// A 9-tap tent, added onto the level above.
static const char* kUp = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uSrc;
uniform vec2 uTexel;
uniform float uRadius;
out vec4 fragColor;
vec3 s(vec2 o) { return texture(uSrc, vUv + o * uTexel * uRadius).rgb; }
void main() {
  vec3 col = s(vec2(0)) * 4.0 + (s(vec2(-1, 0)) + s(vec2(1, 0)) + s(vec2(0, -1)) + s(vec2(0, 1))) * 2.0
           + s(vec2(-1, -1)) + s(vec2(1, -1)) + s(vec2(-1, 1)) + s(vec2(1, 1));
  fragColor = vec4(col / 16.0, 1.0);
}
)";

static const char* kFinish = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uBase;
uniform sampler2D uBloom;
uniform sampler2D uFrom;    // the scene being left, under a crossfade
uniform vec2 uResolution;
uniform float uBloomAmount, uVignette, uGrain, uTone, uFringe, uTime, uFlipY, uCurve;
uniform float uMixK;        // 1: all the scene on; under 1, the one being left shows
uniform float uWhite;       // the strobe and the hands' hit: white over everything
uniform float uBlack;       // the blackout
out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
vec3 aces(vec3 x) {
  const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}
// AgX (Troy Sobotka), the minimal fit by Wrensch: rolls a bright colour off towards
// white instead of skewing its hue, as ACES does.
vec3 agxContrast(vec3 x) {
  vec3 x2 = x * x, x4 = x2 * x2;
  return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}
vec3 agx(vec3 v) {
  const mat3 m = mat3(0.842479062253094, 0.0423282422610123, 0.0423756549057051,
                      0.0784335999999992, 0.878468636469772, 0.0784336,
                      0.0792237451477643, 0.0791661274605434, 0.879142973793104);
  const mat3 mi = mat3(1.19687900512017, -0.0528968517574562, -0.0529716355144438,
                       -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
                       -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
  const float lo = -12.47393, hi = 4.026069;
  v = clamp(log2(max(m * v, vec3(1e-10))), lo, hi);
  v = agxContrast((v - lo) / (hi - lo));
  return clamp(mi * v, 0.0, 1.0);
}
void main() {
  vec2 uv = vec2(vUv.x, uFlipY > 0.5 ? 1.0 - vUv.y : vUv.y);
  vec2 c = uv - 0.5;
  float r2 = dot(c, c);
  vec2 off = c * uFringe * r2 * 4.0;
  vec3 base = vec3(texture(uBase, uv + off).r, texture(uBase, uv).g, texture(uBase, uv - off).b);
  // The scenes cross as light, eased, so neither dips dark half way.
  if (uMixK < 1.0) base = mix(texture(uFrom, uv).rgb, base, smoothstep(0.0, 1.0, uMixK));
  vec3 light = base + texture(uBloom, uv).rgb * uBloomAmount;
  light *= 1.0 - smoothstep(0.35, 1.0, sqrt(r2) * 1.414) * 0.75 * uVignette;
  // The scenes are drawn as display values (they were written for the Flutter
  // stage's ACES on 8 bits), so ACES is the default; AgX is the one to move to.
  vec3 curved = uCurve > 0.5 ? agx(light * 1.6) : aces(light * 1.1);
  vec3 col = mix(clamp(light, 0.0, 1.0), curved, uTone);
  vec2 px = gl_FragCoord.xy;
  float g = hash(px + fract(uTime * 7.31) * 100.0) - 0.5;
  col += g * uGrain * (0.06 + 0.06 * (1.0 - dot(col, vec3(0.333))));
  // Triangular dither, a step of the 8 bits wide: no bands in a dark gradient.
  float d = hash(px * 1.37 + 11.0) + hash(px * 0.71 + 3.0) - 1.0;
  col += d / 255.0;
  col = mix(col, vec3(1.0), uWhite);
  col *= 1.0 - uBlack;
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
)";

// The ground's own passes: a wash of two of the palette's colours, breathing slowly;
// and a copy of a picture (MilkDrop's), filled and cropped to the stage when 16:9.
static const char* kWash = R"(#version 300 es
precision highp float;
uniform vec2 uResolution;
uniform vec3 uA;
uniform vec3 uB;
uniform float uTime;
out vec4 fragColor;
void main() {
  vec2 uv = gl_FragCoord.xy / uResolution;
  float k = smoothstep(0.0, 1.0, uv.y + 0.12 * sin(uTime * 0.07 + uv.x * 2.0));
  fragColor = vec4(mix(uA, uB, k), 1.0);
}
)";
static const char* kCopy = R"(#version 300 es
precision highp float;
precision highp sampler2D;
uniform vec2 uResolution;
uniform sampler2D uSrc;
uniform float uFit;  // the picture's own aspect, to be filled and cropped; 0 as it is
out vec4 fragColor;
void main() {
  vec2 uv = gl_FragCoord.xy / uResolution;
  if (uFit > 0.5) {
    float stage = uResolution.x / uResolution.y;
    float pic = uFit;
    vec2 fit = stage > pic ? vec2(1.0, pic / stage) : vec2(stage / pic, 1.0);
    uv = clamp((uv - 0.5) * fit + 0.5, 0.0, 1.0);
  }
  fragColor = vec4(texture(uSrc, uv).rgb, 1.0);
}
)";

// The common block's names, in order (shaders/show/common.glsl).
static const char* kCommon[WS_COMMON] = {
    "uResolution", "uTime", "uBeat", "uBar", "uPhrase", "uEnergy", "uIntensity", "uKick", "uLow", "uMid", "uHigh",
    "uAir", "uOnset", "uHue", "uHue2", "uDropNear", "uBuild", "uHit", "uVocal", "uM1", "uM2", "uM3", "uM4",
    "uHitKick", "uHitSnare", "uHitTop", "uBeatDecay", "uBarDecay", "uBarSaw", "uPhraseSaw", "uDownbeat",
    "uExposure", "uBandLow", "uBandMid", "uBandHigh", "uBarIndex", nullptr};

struct Stage {
  // where
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  bool headless = false;
  // Windows (ws_attach_shared): the frames go to the view as Direct3D textures
  // shared by handle, one surface of ANGLE's per output slot — or, where the card
  // will not share, as pixels, two buffers turn and turn about.
  bool shared = false, readback = false, warp = false;
  EGLConfig config = nullptr;
  EGLSurface current = EGL_NO_SURFACE;
  EGLSurface shares[3] = {EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_SURFACE};
  void* shareHandles[3] = {nullptr, nullptr, nullptr};
  int shareW[3] = {0, 0, 0}, shareH[3] = {0, 0, 0};
  std::mutex pixLock;
  std::vector<uint8_t> pixels[2];
  int pixelFront = 0, pixelW = 0, pixelH = 0;
  bool pixHeld = false;
  std::string shaderDir = ".";
  std::string error;
  // the thread
  std::thread thread;
  std::atomic<bool> running{false};
  // The loop's nap between frames, cut short by ws_stop.
  std::mutex napLock;
  std::condition_variable nap;
  // asked for (any thread)
  std::mutex lock;
  int width = 1280, height = 720;
  float scale = 1.0f, fps = 60;
  std::string scene = "flash";
  float post[6] = {0, 0.5f, 0.6f, 0.5f, 1, 0.008f};  // trails bloom vignette grain tone fringe
  float common[WS_COMMON] = {};
  // the scene being left, how far across, its knobs
  std::string from;
  float fromK = 1, fromKnobs[4] = {};
  float flashWhite = 0, flashBlack = 0;
  bool freeze = false;
  float palette[9] = {1, 1, 1, 1, 1, 1, 1, 1, 1};  // primary, secondary, accent
  std::string particleKinds;
  float recipe[12] = {};
  bool hasRecipe = false;
  // The ground under the figure, and the blend of the two (show_rig.dart's RigGround
  // and RigBlend; under.frag): the ground's kind (0 black 1 wash 2 milk 3 camera
  // 4 field 5 cover 6 pulse 7 white), a field's shader, how much of it, its knobs;
  // the blend (show_combos.dart's Mix 0..3) and the mask (Mask 0..2), which pixels
  // are the figure (0 the alpha 254/255 band, 1 the alpha, 2 the light), how much.
  int groundKind = 0;
  std::string groundField;
  float groundDim = 1, groundKnobs[4] = {};
  int blendMix = 0, blendMask = 0, blendCoverage = 0;
  float blendStrength = 1;
  // The treatment over the figure (ws_treat): mode 0 none.
  float treat[WS_TREAT] = {};
  // The figure's ghosts (ws_ghosts): under 2 none; and whether the working size
  // follows the frames (ws_adapt).
  int ghostCount = 0;
  float ghostDiffer = 0.5f;
  bool adapt = true;
  // The slit-scan as a layer (ws_slit): mode 0 none.
  float slitLayer[WS_TREAT] = {};
  // The words' frame (ws_words): the sim shader's floats in the file's order.
  std::vector<float> words;
  // The datamosh asked for (ws_mosh): a count, and how long and how hard.
  int moshAsk = 0;
  // ws_dump: where the next frame's layers go (empty: nowhere).
  std::string dumpPath;
  float moshSeconds = 1, moshStrength = 1;
  void (*onFrame)(void*) = nullptr;
  void* onFrameUser = nullptr;
  // drawn (the stage's thread)
  GLuint vao = 0;
  glsl::Programs programs;
  GLuint down = 0, up = 0, finish = 0, wash = 0, copy = 0;
  Target work, leaving, scratch, ground, trailA, trailB, bloom[6], out[3];
  // the dancers (dance.h): drawn from Dart's list where the scene is "@dance"
  Dance dance;
  // the stage's own passes that keep pictures (fx.h): the veins, the slit-scan, the
  // datamosh; which picture the last frame showed (0 work, 1 the trails, 2 the mosh's)
  Slime slime;
  Slit slit;
  Mosh mosh;
  int moshDone = 0, lastPic = 0;
  GLenum agentFormat = GL_RGBA16F;
  // particles, the scene they are for, and how they are drawn
  std::map<std::string, std::unique_ptr<Particles>> particles;
  std::string particleScene;
  GLuint particleProgram = 0, particleVao = 0, particleVbo = 0;
  std::vector<float> particleData;
  Clock::time_point lastFrame{};
  // the working size the thread chose, against the frames it manages
  float autoScale = 1;
  int late = 0, onTime = 0;
  std::string trailScene;
  GLenum workFormat = GL_RGBA8;
  bool floatTargets = false;
  GLuint black = 0;
  // handed out
  std::mutex outLock;
  int published = -1, shown = -1;
  GLsync fences[3] = {nullptr, nullptr, nullptr};
  // counted
  std::atomic<int64_t> frames{0};
  float frameMs = 0, worstMs = 0, rate = 0;
  int64_t rateFrames = 0;
  Clock::time_point rateAt = Clock::now(), t0 = Clock::now();
  int curve = 0;
  int flipY = 0;
  // MilkDrop
  std::mutex milkLock;
  std::deque<std::pair<std::string, std::vector<uint8_t>>> milkQueue;
  std::string milkSaid;
  milk::Core milk;
  bool milkOpen = false;
  // To open it again on a new context: the line that opened it, and its preset.
  std::string milkOpenLine;
  // MilkDrop drawn at the stage's own size ("open 0 0 …", "size 0 0"): 16:9, as tall
  // as the stage's picture, between 360 and 1080 rows; or at the size it was told.
  bool milkFit = false;
  std::pair<std::string, std::vector<uint8_t>> milkPreset;
  bool milkReopen = false;
};

Stage* S = nullptr;

bool hasExtension(const char* name) {
  GLint n = 0;
  glGetIntegerv(GL_NUM_EXTENSIONS, &n);
  for (GLint i = 0; i < n; i++) {
    const char* e = (const char*)glGetStringi(GL_EXTENSIONS, (GLuint)i);
    if (e && std::strcmp(e, name) == 0) return true;
  }
  return false;
}

// On the stage's thread, its context current: what lasts between frames.
bool setUp() {
  glGenVertexArrays(1, &S->vao);
  S->floatTargets = hasExtension("GL_EXT_color_buffer_float") || hasExtension("GL_EXT_color_buffer_half_float");
  S->workFormat = S->floatTargets ? GL_RGBA16F : GL_RGBA8;
  // The slime's agents (fx.h): their places in full floats where the GPU can draw
  // into them, else in halves (half a pixel of a map 960 wide: they step coarser).
  S->agentFormat = hasExtension("GL_EXT_color_buffer_float") ? GL_RGBA32F : S->workFormat;
  std::string err;
  S->down = glsl::link(kVert, kDown, err);
  S->up = S->down ? glsl::link(kVert, kUp, err) : 0;
  S->finish = S->up ? glsl::link(kVert, kFinish, err) : 0;
  S->particleProgram = S->finish ? glsl::link(kParticleVert, kParticleFrag, err) : 0;
  S->wash = S->particleProgram ? glsl::link(kVert, kWash, err) : 0;
  S->copy = S->wash ? glsl::link(kVert, kCopy, err) : 0;
  if (!S->copy) { S->error = "the stage's own passes: " + err; return false; }
  glGenVertexArrays(1, &S->particleVao);
  glGenBuffers(1, &S->particleVbo);
  glBindVertexArray(S->particleVao);
  glBindBuffer(GL_ARRAY_BUFFER, S->particleVbo);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 7 * sizeof(float), (void*)0);
  glVertexAttribDivisor(0, 1);
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, 7 * sizeof(float), (void*)(3 * sizeof(float)));
  glVertexAttribDivisor(1, 1);
  glBindVertexArray(0);
  S->programs.dir = S->shaderDir;
  // A black picture for a sampler that has nothing (a cover not yet here).
  glGenTextures(1, &S->black);
  glBindTexture(GL_TEXTURE_2D, S->black);
  const uint8_t px[4] = {0, 0, 0, 255};
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
  if (const char* c = std::getenv("WETOWL_STAGE_CURVE")) S->curve = std::strcmp(c, "agx") == 0;
  if (const char* f = std::getenv("WETOWL_STAGE_FLIP")) S->flipY = f[0] == '1';
  return true;
}

void drawQuad() { glDrawArrays(GL_TRIANGLES, 0, 3); }

void bindTex(GLuint program, const char* name, int unit, GLuint tex) {
  glActiveTexture(GL_TEXTURE0 + unit);
  glBindTexture(GL_TEXTURE_2D, tex);
  glUniform1i(glGetUniformLocation(program, name), unit);
}

// The size MilkDrop is drawn at where it fits the stage: 16:9 (its picture is filled
// and cropped to the stage as a 16:9 one), as tall as the stage's own picture.
static void milkFitted(int& w, int& h) {
  const int rows = S->work.h > 0 ? std::clamp(S->work.h, 360, 1080) : 540;
  h = rows & ~1;
  w = (rows * 16 / 9) & ~1;
}

// MilkDrop's commands since the last frame, on the stage's thread.
void milkCommands() {
  std::deque<std::pair<std::string, std::vector<uint8_t>>> batch;
  { std::lock_guard<std::mutex> g(S->milkLock); batch.swap(S->milkQueue); }
  for (auto& [line, payload] : batch) {
    if (line.rfind("open", 0) == 0) {
      if (S->milkOpen) continue;
      int w = 960, h = 540, fps = 60;
      char textures[1024] = {0};
      std::sscanf(line.c_str(), "open %d %d %d %1023[^\n]", &w, &h, &fps, textures);
      S->milkFit = w <= 0 || h <= 0;
      if (S->milkFit) milkFitted(w, h);
      S->milk.say = [](const std::string& l) {
        std::lock_guard<std::mutex> g(S->milkLock);
        S->milkSaid += l + "\n";
      };
      S->milkOpen = S->milk.open(w, h, fps, textures);
      if (!S->milkOpen) S->milk.say("projectm: could not be created");
      else S->milkOpenLine = line;
      continue;
    }
    if (!S->milkOpen) continue;
    if (line == "quit") { S->milk.close(); S->milkOpen = false; S->milkOpenLine.clear(); S->milkPreset.first.clear(); continue; }
    if (line.rfind("preset", 0) == 0 || line.rfind("data", 0) == 0) S->milkPreset = {line, payload};
    if (line.rfind("size", 0) == 0) {
      int w = 0, h = 0;
      std::sscanf(line.c_str(), "size %d %d", &w, &h);
      S->milkFit = w <= 0 || h <= 0;
      if (S->milkFit) continue;  // fitted at the next frame
    }
    S->milk.command(line, payload);
  }
  // Fitted to the stage: drawn again at its new size where the stage's changed.
  if (S->milkOpen && S->milkFit) {
    int w = 0, h = 0;
    milkFitted(w, h);
    if (w != S->milk.width || h != S->milk.height) S->milk.command("size " + std::to_string(w) + " " + std::to_string(h), {});
  }
}

// A scene's shader into `t`: the common block, [knobs] for uM1..4 where given.
void drawScene(const glsl::Program* p, Target& t, const float* common, const float* knobs, GLuint milkTex) {
  t.bind();
  if (!p) {
    glClearColor(0.15f, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    return;
  }
  glUseProgram(p->id);
  for (int i = 1; kCommon[i]; i++) {
    const GLint at = p->loc(kCommon[i]);
    if (at < 0) continue;
    float v = common[i + 1];
    if (knobs && i >= 19 && i <= 22) v = knobs[i - 19];  // uM1..uM4
    glUniform1f(at, v);
  }
  if (const GLint at = p->loc("uResolution"); at >= 0) glUniform2f(at, (float)t.w, (float)t.h);
  if (const GLint at = p->loc("wsHeight"); at >= 0) glUniform1f(at, (float)t.h);
  int unit = 0;
  for (const auto& name : p->samplers) bindTex(p->id, name.c_str(), unit++, name == "uMilk" && milkTex ? milkTex : S->black);
  drawQuad();
}

// The figure in `t` through a treatment (dance_fx.frag; ws_treat's floats), via
// `via` and back: what the Flutter stage's _treated does, before the blend. Its alpha
// stays 1, as a scene's is (the blend reads its own coverage as ever).
// The figure in `t` with its ghosts round it (shaders/show/ghosts.frag), via `via`
// and back: what the Flutter stage's _ghosted does, between the style and the blend.
void ghostPass(Target& t, Target& via, int count, float differ, float time, float kick) {
  const glsl::Program* g = S->programs.get("ghosts");
  if (!g) return;
  via.make(t.w, t.h, S->workFormat);
  via.bind();
  glDisable(GL_BLEND);
  glUseProgram(g->id);
  auto set = [&](const char* n, float v) { if (const GLint at = g->loc(n); at >= 0) glUniform1f(at, v); };
  if (const GLint at = g->loc("uResolution"); at >= 0) glUniform2f(at, (float)t.w, (float)t.h);
  set("wsHeight", (float)t.h);
  set("uCount", (float)count);
  set("uDiffer", differ);
  set("uTime", time);
  set("uKick", kick);
  bindTex(g->id, "uImage", 0, t.tex);
  drawQuad();
  glBindFramebuffer(GL_READ_FRAMEBUFFER, via.fbo);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, t.fbo);
  glBlitFramebuffer(0, 0, t.w, t.h, 0, 0, t.w, t.h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  glBindFramebuffer(GL_FRAMEBUFFER, t.fbo);
}

void treatPass(const float* q, Target& t, Target& via) {
  const glsl::Program* fx = S->programs.get("sim/dance_fx");
  const GLuint atlas = S->dance.texture("glyphs");
  if (!fx || !atlas) return;
  via.make(t.w, t.h, S->workFormat);
  via.bind();
  glDisable(GL_BLEND);
  glUseProgram(fx->id);
  auto set = [&](const char* n, float v) { if (const GLint at = fx->loc(n); at >= 0) glUniform1f(at, v); };
  if (const GLint at = fx->loc("uResolution"); at >= 0) glUniform2f(at, (float)t.w, (float)t.h);
  set("wsHeight", (float)t.h);
  set("uMode", q[0]);
  set("uCell", q[1] * t.h);
  if (const GLint at = fx->loc("uInk"); at >= 0) glUniform3f(at, q[2], q[3], q[4]);
  if (const GLint at = fx->loc("uPaper"); at >= 0) glUniform3f(at, q[5], q[6], q[7]);
  set("uTint", q[8]);
  set("uGlyphs", q[9]);
  set("uPop", q[10]);
  if (const GLint at = fx->loc("uPopAt"); at >= 0) glUniform2f(at, q[11], q[12]);
  set("uTime", q[13]);
  set("uCoverageOut", 0.0f);
  set("uWeight", q[14]);
  set("uSpacing", q[15]);
  set("uHeight", q[16]);
  set("uGain", q[17]);
  set("uSize", q[18]);
  bindTex(fx->id, "uImage", 0, t.tex);
  bindTex(fx->id, "uAtlas", 1, atlas);
  drawQuad();
  glBindFramebuffer(GL_READ_FRAMEBUFFER, via.fbo);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, t.fbo);
  glBlitFramebuffer(0, 0, t.w, t.h, 0, 0, t.w, t.h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  glBindFramebuffer(GL_FRAMEBUFFER, t.fbo);
}

// A sim drawn by Dart's numbers: the words (ui/show/show_words.dart: the record's line
// set in type, rasterised by Dart into a picture per line and sent up by name,
// "words.t0", "words.t1"), the 3D type (show_type3d.dart: its line's distance field,
// "type3d.sdf"). Drawn through the Flutter stage's own sim shader (shaders/show/sim/
// words_fx.frag, sim/type3d.frag) with its floats in the order the file declares
// them — what Dart's setFloat(i) does on the Flutter stage, so the two draw the same
// frame from the same numbers (ws_words, whichever sim is on). A sampler uX is the
// texture "<prefix>.x" (lower case); uGround is the ground's picture.
void drawSim(Target& t, const char* program, const std::string& prefix, const std::vector<float>& v, GLuint groundTex) {
  const glsl::Program* p = S->programs.get(program);
  t.bind();
  if (!p) {
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    return;
  }
  glUseProgram(p->id);
  glsl::setFloats(*p, v.data(), (int)v.size());
  if (const GLint at = p->loc("uResolution"); at >= 0) glUniform2f(at, (float)t.w, (float)t.h);
  // Straight colour for the blend's mix by the coverage; premultiplied where the layer
  // goes out whole (no blend: the finish reads the colour alone).
  if (const GLint at = p->loc("uPremul"); at >= 0) glUniform1f(at, groundTex ? 0.0f : 1.0f);
  // Whether the ground's picture is bound (a sim that looks through itself at it).
  if (const GLint at = p->loc("uGroundOn"); at >= 0) glUniform1f(at, groundTex ? 1.0f : 0.0f);
  if (const GLint at = p->loc("wsHeight"); at >= 0) glUniform1f(at, (float)t.h);
  int unit = 0;
  for (const auto& name : p->samplers) {
    GLuint tex = 0;
    if (name == "uGround") {
      tex = groundTex;
    } else if (name.size() > 1 && name[0] == 'u') {
      std::string key = prefix + "." + name.substr(1);
      for (auto& ch : key) ch = (char)std::tolower((unsigned char)ch);
      tex = S->dance.texture(key);
    }
    bindTex(p->id, name.c_str(), unit++, tex ? tex : S->black);
  }
  drawQuad();
}

// A target written out for ws_dump: RGBA as little-endian float32, box-filtered down
// to at most 320 wide, top row first ([flip]: read bottom row first, as a layer is).
void dumpTarget(const Target& t, GLenum format, const std::string& file, bool flip) {
  if (!t.fbo || t.w <= 0 || t.h <= 0) return;
  const bool isFloat = format == GL_RGBA16F || format == GL_RGBA32F;
  std::vector<float> px((size_t)t.w * t.h * 4);
  glBindFramebuffer(GL_FRAMEBUFFER, t.fbo);
  if (isFloat) {
    glReadPixels(0, 0, t.w, t.h, GL_RGBA, GL_FLOAT, px.data());
  } else {
    std::vector<uint8_t> b((size_t)t.w * t.h * 4);
    glReadPixels(0, 0, t.w, t.h, GL_RGBA, GL_UNSIGNED_BYTE, b.data());
    for (size_t i = 0; i < b.size(); i++) px[i] = b[i] / 255.0f;
  }
  const int f = std::max(1, (t.w + 319) / 320), ow = t.w / f, oh = t.h / f;
  std::vector<float> o((size_t)ow * oh * 4, 0.0f);
  for (int y = 0; y < oh * f; y++) {
    const int oy = flip ? oh - 1 - y / f : y / f;
    for (int x = 0; x < ow * f; x++)
      for (int c = 0; c < 4; c++) o[((size_t)oy * ow + x / f) * 4 + c] += px[((size_t)y * t.w + x) * 4 + c] / (f * f);
  }
  if (FILE* out = std::fopen(file.c_str(), "wb")) {
    const int32_t dims[2] = {ow, oh};
    std::fwrite(dims, sizeof dims, 1, out);
    std::fwrite(o.data(), sizeof(float), o.size(), out);
    std::fclose(out);
  }
}

// One frame into out[slot].
void frame(int slot) {
  int W, H; float sc; std::string sceneName, fromName, kinds, groundField; float post[6]; float common[WS_COMMON];
  float fromK, fromKnobs[4], white, black, palette[9], recipe[12], groundDim, groundKnobs[4], blendStrength;
  int groundKind, blendMix, blendMask, blendCoverage;
  float treat[WS_TREAT];
  int ghostCount;
  float ghostDiffer;
  float slitLayer[WS_TREAT];
  bool freeze, hasRecipe;
  std::vector<float> wordsV;
  int moshAsk;
  float moshSeconds, moshStrength;
  std::string dumpPath;
  {
    std::lock_guard<std::mutex> g(S->lock);
    W = S->width; H = S->height; sc = S->scale * S->autoScale; sceneName = S->scene;
    std::memcpy(post, S->post, sizeof post);
    std::memcpy(common, S->common, sizeof common);
    fromName = S->from; fromK = S->fromK; std::memcpy(fromKnobs, S->fromKnobs, sizeof fromKnobs);
    white = S->flashWhite; black = S->flashBlack; freeze = S->freeze;
    std::memcpy(palette, S->palette, sizeof palette);
    kinds = S->particleKinds;
    std::memcpy(recipe, S->recipe, sizeof recipe); hasRecipe = S->hasRecipe;
    groundKind = S->groundKind; groundField = S->groundField; groundDim = S->groundDim;
    std::memcpy(groundKnobs, S->groundKnobs, sizeof groundKnobs);
    blendMix = S->blendMix; blendMask = S->blendMask; blendCoverage = S->blendCoverage; blendStrength = S->blendStrength;
    std::memcpy(treat, S->treat, sizeof treat);
    ghostCount = S->ghostCount; ghostDiffer = S->ghostDiffer;
    std::memcpy(slitLayer, S->slitLayer, sizeof slitLayer);
    wordsV = S->words;
    moshAsk = S->moshAsk; moshSeconds = S->moshSeconds; moshStrength = S->moshStrength;
    dumpPath.swap(S->dumpPath);
  }
  // A sim of Dart's numbers: the words, or one by name (`@sim:type3d`).
  const bool simByName = sceneName.rfind("@sim:", 0) == 0;
  const bool wordsScene = sceneName == "@words" || simByName;
  // The veins (fx.h's Slime): their rules a frame are the words' floats too.
  const bool slimeScene = sceneName == "@slime";
  const auto now = Clock::now();
  double dt = S->lastFrame.time_since_epoch().count() == 0 ? 1.0 / 60 : std::chrono::duration<double>(now - S->lastFrame).count();
  S->lastFrame = now;
  if (freeze) dt = 0;
  const int w = std::max(8, (int)std::lround(W * sc)), h = std::max(8, (int)std::lround(H * sc));
  glBindVertexArray(S->vao);
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);

  // 0. MilkDrop, where a scene samples it: its commands, then its frame.
  const glsl::Program* p = sceneName == "@dance" || wordsScene || slimeScene ? nullptr : S->programs.get(sceneName);
  const glsl::Program* leaving = fromName.empty() || fromK >= 1 ? nullptr : S->programs.get(fromName);
  milkCommands();
  auto samplesMilk = [](const glsl::Program* q) {
    if (!q) return false;
    for (const auto& n : q->samplers) if (n == "uMilk") return true;
    return false;
  };
  // The ground and the blend: not under a scene that draws MilkDrop itself (it is
  // the ground), nor for a figure plainly on black (the figure as it is drawn).
  const bool blendNow = !samplesMilk(p) && blendStrength > 0 && !(groundKind == 0 && blendMix == 0 && blendMask == 0);
  const bool groundMilk = blendNow && groundKind == 2;
  const bool milkNow = S->milkOpen && (samplesMilk(p) || samplesMilk(leaving) || groundMilk);
  if (milkNow) {
    S->milk.render();
    // projectM leaves its own state behind.
    glBindVertexArray(S->vao);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_CULL_FACE);
  }
  // Without MilkDrop in this build, its picture is the helper's, uploaded by name.
  const bool milkWanted = samplesMilk(p) || samplesMilk(leaving) || groundMilk;
  const GLuint milkTex = milkNow ? S->milk.tex : milkWanted && !S->milkOpen ? S->dance.texture("milk") : 0;

  // 0. the ground, into its own picture
  if (blendNow) {
    S->ground.make(w, h, S->workFormat);
    glDisable(GL_BLEND);
    const glsl::Program* field = (groundKind == 4 || groundKind == 6) && !groundField.empty() ? S->programs.get(groundField) : nullptr;
    if (field) {
      drawScene(field, S->ground, common, groundKnobs, milkTex);
    } else if (groundKind == 1) {
      S->ground.bind();
      glUseProgram(S->wash);
      glUniform2f(glGetUniformLocation(S->wash, "uResolution"), (float)w, (float)h);
      glUniform3f(glGetUniformLocation(S->wash, "uA"), palette[0] * 0.22f, palette[1] * 0.22f, palette[2] * 0.22f);
      glUniform3f(glGetUniformLocation(S->wash, "uB"), palette[3] * 0.12f, palette[4] * 0.12f, palette[5] * 0.12f);
      glUniform1f(glGetUniformLocation(S->wash, "uTime"), common[2]);
      drawQuad();
    } else if (groundKind == 2 && milkTex) {
      S->ground.bind();
      glUseProgram(S->copy);
      glUniform2f(glGetUniformLocation(S->copy, "uResolution"), (float)w, (float)h);
      glUniform1f(glGetUniformLocation(S->copy, "uFit"), 16.0f / 9.0f);
      bindTex(S->copy, "uSrc", 0, milkTex);
      drawQuad();
    } else if ((groundKind == 3 || groundKind == 5) && S->dance.texture(groundKind == 3 ? "camera" : "cover")) {
      // The room's frame (16:9) or the record's cover (square), as uploaded.
      S->ground.bind();
      glUseProgram(S->copy);
      glUniform2f(glGetUniformLocation(S->copy, "uResolution"), (float)w, (float)h);
      glUniform1f(glGetUniformLocation(S->copy, "uFit"), groundKind == 3 ? 16.0f / 9.0f : 1.0f);
      bindTex(S->copy, "uSrc", 0, S->dance.texture(groundKind == 3 ? "camera" : "cover"));
      drawQuad();
    } else if (groundKind == 7) {
      S->ground.bind();
      glClearColor(1, 1, 1, 1);
      glClear(GL_COLOR_BUFFER_BIT);
    } else {
      // Black: a ground whose picture is not here (yet).
      S->ground.bind();
      glClearColor(0, 0, 0, 1);
      glClear(GL_COLOR_BUFFER_BIT);
    }
    glBindVertexArray(S->vao);
  }

  // 0b. a datamosh asked for: the last frame's picture, before anything is drawn over
  // it, kept for the mosh to start from
  if (moshAsk != S->moshDone) {
    S->moshDone = moshAsk;
    const Target& last = S->lastPic == 2 ? S->mosh.a : S->lastPic == 1 ? S->trailA : S->work;
    if (last.tex) S->mosh.begin(last, w, h, S->workFormat, moshSeconds, moshStrength);
    glBindVertexArray(S->vao);
  }

  // 1. the scene, and the one being left (as drawn: no trails, no particles)
  S->work.make(w, h, S->workFormat);
  if (sceneName == "@dance") {
    S->work.withDepth();
    S->scratch.make(w, h, S->workFormat);
    S->dance.draw(S->work.fbo, S->work.tex, w, h, S->programs, S->scratch.fbo);
    glBindVertexArray(S->vao);
  } else if (slimeScene) {
    S->slime.draw(S->work, wordsV, dt, S->agentFormat, S->workFormat, S->vao, S->frames);
    glBindVertexArray(S->vao);
  } else if (wordsScene) {
    const std::string sim = simByName ? sceneName.substr(5) : std::string("words");
    drawSim(S->work, simByName ? ("sim/" + sim).c_str() : "sim/words_fx", sim, wordsV, blendNow ? S->ground.tex : 0);
  } else {
    drawScene(p, S->work, common, nullptr, milkTex);
  }
  if (leaving) {
    S->leaving.make(w, h, S->workFormat);
    drawScene(leaving, S->leaving, common, fromKnobs, milkTex);
  }

  // 1b. the particles, added to the scene's light; a new scene starts them afresh
  if (S->particleScene != sceneName) { S->particles.clear(); S->particleScene = sceneName; }
  if (!kinds.empty()) {
    // common[i + 1] holds kCommon[i]: uKick 7, uEnergy 5, uBuild 16, uDropNear 15, uHigh 10.
    ParticleInputs in{common[8], common[6], common[17], common[16], common[11],
                      {palette[0], palette[1], palette[2]}, {palette[6], palette[7], palette[8]}, common[2]};
    S->particleData.clear();
    size_t at = 0;
    while (at <= kinds.size()) {
      const size_t comma = kinds.find(',', at);
      const std::string kind = kinds.substr(at, comma == std::string::npos ? std::string::npos : comma - at);
      if (!kind.empty()) {
        auto& sys = S->particles[kind];
        if (!sys) sys = std::make_unique<Particles>(kind);
        sys->step(in, dt, w, h);
        sys->instances(in, S->particleData);
      }
      if (comma == std::string::npos) break;
      at = comma + 1;
    }
    const int n = (int)(S->particleData.size() / 7);
    if (n > 0) {
      S->work.bind();
      glEnable(GL_BLEND);
      glBlendFunc(GL_ONE, GL_ONE);
      glUseProgram(S->particleProgram);
      glUniform2f(glGetUniformLocation(S->particleProgram, "uResolution"), (float)w, (float)h);
      glBindVertexArray(S->particleVao);
      glBindBuffer(GL_ARRAY_BUFFER, S->particleVbo);
      glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(S->particleData.size() * sizeof(float)), S->particleData.data(), GL_STREAM_DRAW);
      glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, n);
      glBindVertexArray(S->vao);
      glDisable(GL_BLEND);
    }
  }

  // 1b'. the treatment over the figure, where its rig asks for one (ws_treat)
  if (treat[0] > 8.5f) {
    // the slit-scan: the figure's own last frames (fx.h)
    S->scratch.make(w, h, S->workFormat);
    S->slit.pass(treat, S->work, S->scratch, S->frames, S->vao);
    glBindVertexArray(S->vao);
  } else if (treat[0] > 0.5f) {
    treatPass(treat, S->work, S->scratch);
    glBindVertexArray(S->vao);
  }

  // 1b''. the layer over the style: the slit-scan (one ring of frames: not where the
  // style is the slit-scan already), then the ghosts round it (ws_slit, ws_ghosts)
  if (slitLayer[0] > 8.5f && !(treat[0] > 8.5f)) {
    S->scratch.make(w, h, S->workFormat);
    S->slit.pass(slitLayer, S->work, S->scratch, S->frames, S->vao);
    glBindVertexArray(S->vao);
  }
  if (ghostCount >= 2) {
    ghostPass(S->work, S->scratch, ghostCount, ghostDiffer, common[2], common[24]);
    glBindVertexArray(S->vao);
  }

  if (!dumpPath.empty()) {
    dumpTarget(S->work, S->workFormat, dumpPath + ".fig", true);
    if (blendNow) dumpTarget(S->ground, S->workFormat, dumpPath + ".ground", true);
    if (FILE* f = std::fopen((dumpPath + ".json").c_str(), "w")) {
      std::fprintf(f, "{\"scene\":\"%s\",\"w\":%d,\"h\":%d,\"blend\":%d,\"mix\":%d,\"mask\":%d,\"coverage\":%d,\"strength\":%g,"
                      "\"groundKind\":%d,\"groundDim\":%g,\"treat\":%g,\"bloom\":%g,\"tone\":%g,\"vignette\":%g}\n",
                   sceneName.c_str(), w, h, blendNow ? 1 : 0, blendMix, blendMask, blendCoverage, blendStrength, groundKind, groundDim,
                   treat[0], post[1], post[4], post[2]);
      std::fclose(f);
    }
  }

  // 1c. the blend: the figure over the ground, its backdrop the rig's way (under.frag);
  // the scene's post goes over both.
  if (blendNow) {
    if (const glsl::Program* u = S->programs.get("under")) {
      S->scratch.make(w, h, S->workFormat);
      S->scratch.bind();
      glDisable(GL_BLEND);
      glUseProgram(u->id);
      auto set = [&](const char* n, float v) { if (const GLint at = u->loc(n); at >= 0) glUniform1f(at, v); };
      if (const GLint at = u->loc("uResolution"); at >= 0) glUniform2f(at, (float)w, (float)h);
      set("wsHeight", (float)h);
      set("uMix", (float)blendMix);
      set("uMask", (float)blendMask);
      set("uCoverage", (float)blendCoverage);
      set("uStrength", blendStrength);
      set("uGroundFit", 0.0f);
      set("uGroundDim", groundDim);
      bindTex(u->id, "uScene", 0, S->work.tex);
      bindTex(u->id, "uGround", 1, S->ground.tex);
      drawQuad();
      glBindFramebuffer(GL_READ_FRAMEBUFFER, S->scratch.fbo);
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER, S->work.fbo);
      glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
      glBindFramebuffer(GL_FRAMEBUFFER, S->work.fbo);
    }
  }

  // 2. the trails, with the record's recipe where the scene takes it
  const Target* current = &S->work;
  const float trails = post[0];
  if (trails > 0 && freeze && S->trailScene == sceneName && S->trailA.tex && S->trailA.w == w && S->trailA.h == h) {
    // Held still: the last trails as they were (fed the same frame again and again,
    // the feedback would brighten a frozen picture).
    current = &S->trailA;
  } else if (trails > 0) {
    const glsl::Program* fb = S->programs.get("feedback");
    if (fb) {
      const bool fresh = S->trailScene != sceneName || S->trailA.w != w || S->trailA.h != h;
      S->trailA.make(w, h, S->workFormat);
      S->trailB.make(w, h, S->workFormat);
      S->trailScene = sceneName;
      S->trailB.bind();
      glUseProgram(fb->id);
      auto set = [&](const char* n, float v) { if (const GLint at = fb->loc(n); at >= 0) glUniform1f(at, v); };
      if (const GLint at = fb->loc("uResolution"); at >= 0) glUniform2f(at, (float)w, (float)h);
      if (const GLint at = fb->loc("wsHeight"); at >= 0) glUniform1f(at, (float)h);
      if (hasRecipe) {
        set("uDecay", recipe[0]); set("uZoom", recipe[1]); set("uRotate", recipe[2]); set("uTint", recipe[3]);
        if (const GLint at = fb->loc("uTintColour"); at >= 0) glUniform3f(at, recipe[4], recipe[5], recipe[6]);
        set("uFold", recipe[7]); set("uWarp", recipe[8]); set("uHueTurn", recipe[9]); set("uShiftX", recipe[10]); set("uShiftY", recipe[11]);
      } else {
        set("uDecay", trails);
        set("uZoom", 1.0f + 0.010f * common[6]);
        set("uRotate", 0.003f);
        set("uTint", 0.12f);
        if (const GLint at = fb->loc("uTintColour"); at >= 0) glUniform3f(at, palette[3], palette[4], palette[5]);
      }
      set("uTime", common[2]);
      bindTex(fb->id, "uPrev", 0, fresh ? S->work.tex : S->trailA.tex);
      bindTex(fb->id, "uNow", 1, S->work.tex);
      drawQuad();
      std::swap(S->trailA, S->trailB);
      current = &S->trailA;
    }
  } else {
    S->trailScene.clear();
  }

  // 2b. the datamosh under way: the picture being left moved by this one's motion
  if (S->mosh.active) {
    current = S->mosh.step(*current, dt, common[24], S->workFormat, S->vao);
    glBindVertexArray(S->vao);
  }
  S->lastPic = current == &S->mosh.a ? 2 : current == &S->trailA ? 1 : 0;

  // 3. the bloom: five levels down, back up
  int bw = w, bh = h, levels = 0;
  for (int i = 0; i < 5; i++) {
    bw = std::max(2, bw / 2); bh = std::max(2, bh / 2);
    S->bloom[i].make(bw, bh, S->workFormat);
    levels++;
  }
  glUseProgram(S->down);
  const Target* src = current;
  for (int i = 0; i < levels; i++) {
    S->bloom[i].bind();
    bindTex(S->down, "uSrc", 0, src->tex);
    glUniform2f(glGetUniformLocation(S->down, "uTexel"), 1.0f / src->w, 1.0f / src->h);
    glUniform1f(glGetUniformLocation(S->down, "uFirst"), i == 0 ? 1.0f : 0.0f);
    drawQuad();
    src = &S->bloom[i];
  }
  glUseProgram(S->up);
  glEnable(GL_BLEND);
  glBlendFunc(GL_ONE, GL_ONE);
  for (int i = levels - 1; i > 0; i--) {
    S->bloom[i - 1].bind();
    bindTex(S->up, "uSrc", 0, S->bloom[i].tex);
    glUniform2f(glGetUniformLocation(S->up, "uTexel"), 1.0f / S->bloom[i].w, 1.0f / S->bloom[i].h);
    glUniform1f(glGetUniformLocation(S->up, "uRadius"), 1.0f);
    drawQuad();
  }
  glDisable(GL_BLEND);

  // 4. the finish, at full size
  Target& o = S->out[slot];
  o.make(W, H, GL_RGBA8);
  o.bind();
  glUseProgram(S->finish);
  bindTex(S->finish, "uBase", 0, current->tex);
  bindTex(S->finish, "uBloom", 1, S->bloom[0].tex);
  bindTex(S->finish, "uFrom", 2, leaving ? S->leaving.tex : S->black);
  auto fset = [&](const char* n, float v) { glUniform1f(glGetUniformLocation(S->finish, n), v); };
  glUniform2f(glGetUniformLocation(S->finish, "uResolution"), (float)W, (float)H);
  fset("uBloomAmount", post[1]);
  fset("uVignette", post[2]);
  fset("uGrain", post[3]);
  fset("uTone", post[4]);
  fset("uFringe", post[5]);
  fset("uTime", common[2]);
  fset("uFlipY", (float)S->flipY);
  fset("uCurve", (float)S->curve);
  fset("uMixK", leaving ? fromK : 1.0f);
  fset("uWhite", white);
  fset("uBlack", black);
  drawQuad();
  if (!dumpPath.empty()) dumpTarget(o, GL_RGBA8, dumpPath + ".out", false);
}

int freeSlot() {
  std::lock_guard<std::mutex> g(S->outLock);
  for (int i = 0; i < 3; i++) if (i != S->published && i != S->shown) return i;
  return 0;
}

void publish(int slot) {
  GLsync f = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
  glFlush();
  std::lock_guard<std::mutex> g(S->outLock);
  if (S->fences[slot]) glDeleteSync(S->fences[slot]);
  S->fences[slot] = f;
  S->published = slot;
}

void count(double ms) {
  S->frames++;
  // A heartbeat on stderr every five seconds: the stage's own thread drawing, whatever
  // the window it is shown in is doing.
  {
    static auto said = std::chrono::steady_clock::now();
    static long long saidFrames = 0;
    const auto now = std::chrono::steady_clock::now();
    if (now - said > std::chrono::seconds(5)) {
      std::fprintf(stderr, "stage: drawn %lld frames in the last %lld ms\n", (long long)(S->frames - saidFrames),
                   (long long)std::chrono::duration_cast<std::chrono::milliseconds>(now - said).count());
      said = now;
      saidFrames = S->frames;
    }
  }
  S->frameMs = S->frameMs * 0.9f + (float)ms * 0.1f;
  S->worstMs = std::max(S->worstMs, (float)ms);
  S->rateFrames++;
  const auto now = Clock::now();
  const double dt = std::chrono::duration<double>(now - S->rateAt).count();
  if (dt >= 1.0) {
    S->rate = (float)(S->rateFrames / dt);
    S->rateFrames = 0;
    S->rateAt = now;
  }
}

// On the stage's thread, its context still current, as the thread stops: everything
// made in this context let go. The texture's close stops the stage and its open
// starts it again (a window gone full screen and back does both), and the start
// makes a new context sharing the view's: the buffers, textures and programs would
// carry over, but a vertex array or a framebuffer is a context's own, and the old
// names in the new context are nothing — the dancers' draws went through theirs
// with no index buffer bound and crashed in the driver. So nothing carries over:
// every part builds its own again on the first frame (the shaders compile again,
// the meshes go up again, MilkDrop opens again with its preset).
void tearDown() {
  S->dance.lost();
  S->slime.lost();
  S->slit.lost();
  S->mosh.lost();
  S->programs.clear();
  for (GLuint* p : {&S->down, &S->up, &S->finish, &S->particleProgram, &S->wash, &S->copy}) {
    if (*p) glDeleteProgram(*p);
    *p = 0;
  }
  for (GLuint* v : {&S->vao, &S->particleVao}) {
    if (*v) glDeleteVertexArrays(1, v);
    *v = 0;
  }
  if (S->particleVbo) { glDeleteBuffers(1, &S->particleVbo); S->particleVbo = 0; }
  if (S->black) { glDeleteTextures(1, &S->black); S->black = 0; }
  for (Target* t : {&S->work, &S->leaving, &S->scratch, &S->ground, &S->trailA, &S->trailB}) t->drop();
  for (auto& t : S->bloom) t.drop();
  {
    std::lock_guard<std::mutex> g(S->outLock);
    for (int i = 0; i < 3; i++) {
      if (S->fences[i]) glDeleteSync(S->fences[i]);
      S->fences[i] = nullptr;
      S->out[i].drop();
    }
    S->published = S->shown = -1;
  }
  S->trailScene.clear();
  if (S->milkOpen) {
    S->milk.close();
    S->milkOpen = false;
    S->milkReopen = !S->milkOpenLine.empty();
  }
  glFinish();
}

// The frame's work done on the GPU before anyone else reads the picture.
void finishOnGpu() {
  GLsync f = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
  glFlush();
  glClientWaitSync(f, GL_SYNC_FLUSH_COMMANDS_BIT, 200'000'000);
  glDeleteSync(f);
}

// A pbuffer of ANGLE's, backed by a Direct3D texture that can be shared, and its
// handle; EGL_NO_SURFACE (and the error said) where there is no such thing here.
EGLSurface sharedSurface(int w, int h, void** handle) {
  const EGLint attrs[] = {EGL_WIDTH, w, EGL_HEIGHT, h, EGL_TEXTURE_TARGET, EGL_TEXTURE_2D, EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA, EGL_NONE};
  EGLSurface s = eglCreatePbufferSurface(S->display, S->config, attrs);
  if (s == EGL_NO_SURFACE) {
    const EGLint plain[] = {EGL_WIDTH, w, EGL_HEIGHT, h, EGL_NONE};
    s = eglCreatePbufferSurface(S->display, S->config, plain);
  }
  if (s == EGL_NO_SURFACE) { S->error = "no surface to share"; return EGL_NO_SURFACE; }
  using Query = EGLBoolean(EGLAPIENTRY*)(EGLDisplay, EGLSurface, EGLint, void**);
  auto query = (Query)eglGetProcAddress("eglQuerySurfacePointerANGLE");
  void* got = nullptr;
  if (!query || !query(S->display, s, EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE, &got) || !got) {
    eglDestroySurface(S->display, s);
    S->error = "the surface has no Direct3D handle to share";
    return EGL_NO_SURFACE;
  }
  *handle = got;
  return s;
}

// Windows: the finished picture into the slot's shared surface — a Direct3D texture
// of ANGLE's making, whose handle the view's Direct3D opens (ws_share) — and waited
// for here, so the view never reads a frame half drawn (two Direct3D devices share
// a texture, not a queue).
void shareOut(int slot) {
  Target& o = S->out[slot];
  if (S->shares[slot] != EGL_NO_SURFACE && (S->shareW[slot] != o.w || S->shareH[slot] != o.h)) {
    eglDestroySurface(S->display, S->shares[slot]);
    S->shares[slot] = EGL_NO_SURFACE;
    S->shareHandles[slot] = nullptr;
  }
  if (S->shares[slot] == EGL_NO_SURFACE) {
    void* handle = nullptr;
    EGLSurface s = sharedSurface(o.w, o.h, &handle);
    if (s == EGL_NO_SURFACE) return;
    S->shares[slot] = s;
    S->shareHandles[slot] = handle;
    S->shareW[slot] = o.w;
    S->shareH[slot] = o.h;
  }
  if (!eglMakeCurrent(S->display, S->shares[slot], S->shares[slot], S->context)) {
    S->error = "the shared surface would not be made current";
    return;
  }
  glBindFramebuffer(GL_READ_FRAMEBUFFER, o.fbo);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
  glBlitFramebuffer(0, 0, o.w, o.h, 0, 0, o.w, o.h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  finishOnGpu();
  eglMakeCurrent(S->display, S->current, S->current, S->context);
}

// Where the card will not share: the finished picture read back as pixels (top row
// first — the finish turned it over), into the buffer the view is not reading.
void readBack(int slot) {
  Target& o = S->out[slot];
  finishOnGpu();
  std::vector<uint8_t>& back = S->pixels[1 - S->pixelFront];
  back.resize((size_t)o.w * o.h * 4);
  glBindFramebuffer(GL_FRAMEBUFFER, o.fbo);
  glReadPixels(0, 0, o.w, o.h, GL_RGBA, GL_UNSIGNED_BYTE, back.data());
  std::lock_guard<std::mutex> g(S->pixLock);
  S->pixelFront = 1 - S->pixelFront;
  S->pixelW = o.w;
  S->pixelH = o.h;
}

void run() {
  if (!eglMakeCurrent(S->display, S->current, S->current, S->context)) {
    S->error = "the stage's context would not be made current";
    S->running = false;
    return;
  }
  if (!setUp()) { S->running = false; return; }
  if (S->milkReopen) {
    // MilkDrop again, as it was: its open line first, then its preset.
    S->milkReopen = false;
    std::lock_guard<std::mutex> g(S->milkLock);
    if (!S->milkPreset.first.empty()) S->milkQueue.emplace_front(S->milkPreset);
    S->milkQueue.emplace_front(S->milkOpenLine, std::vector<uint8_t>());
  }
  auto next = Clock::now();
  GLsync lastFence = nullptr;
  Clock::time_point lastBegan{};
  while (S->running.load()) {
    // The last frame, waited for on the GPU: how long it took from its start to done
    // is what says whether the working size is too big for this GPU (a CPU timer
    // says nothing — the GPU's work is queued). Thirty slow frames in a row take
    // the size down a step, three hundred quick ones put it back.
    if (lastFence) {
      glClientWaitSync(lastFence, GL_SYNC_FLUSH_COMMANDS_BIT, 50'000'000);
      glDeleteSync(lastFence);
      lastFence = nullptr;
      float fps;
      bool adapt;
      { std::lock_guard<std::mutex> g(S->lock); fps = S->fps; adapt = S->adapt; }
      // Held by the hands (ws_adapt 0): the size asked for, whatever the frames.
      if (!adapt) { S->autoScale = 1; S->late = S->onTime = 0; }
      if (fps >= 30 && adapt) {
        const double took = std::chrono::duration<double>(Clock::now() - lastBegan).count();
        const double budget = 1.0 / fps;
        if (took > budget * 0.9) {
          S->onTime = 0;
          if (++S->late >= 30) { S->late = 0; S->autoScale = std::max(0.5f, S->autoScale * 0.85f); }
        } else if (took < budget * 0.5) {
          S->late = 0;
          if (++S->onTime >= 300 && S->autoScale < 1) { S->onTime = 0; S->autoScale = std::min(1.0f, S->autoScale / 0.85f); }
        } else {
          S->late = 0;
        }
      }
    }
    const auto began = Clock::now();
    lastBegan = began;
    const int slot = freeSlot();
    frame(slot);
    if (S->shared) shareOut(slot);
    else if (S->readback) readBack(slot);
    lastFence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    publish(slot);
    count(std::chrono::duration<double, std::milli>(Clock::now() - began).count());
    void (*cb)(void*); void* user;
    float fps;
    { std::lock_guard<std::mutex> g(S->lock); cb = S->onFrame; user = S->onFrameUser; fps = S->fps; }
    if (cb) cb(user);
    if (fps > 0) {
      next += std::chrono::microseconds((int64_t)(1e6 / fps));
      const auto now = Clock::now();
      if (next < now) next = now;
      // Until the next frame, or a stop (parked at half a frame a second, a plain
      // sleep held ws_stop — and the thread that called it — for up to two seconds).
      std::unique_lock<std::mutex> nap(S->napLock);
      S->nap.wait_until(nap, next, [] { return !S->running.load(); });
    }
  }
  tearDown();
  eglMakeCurrent(S->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

EGLContext makeContext(EGLDisplay d, EGLConfig config, EGLContext share) {
  const EGLint attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
  return eglCreateContext(d, config, share, attrs);
}

}  // namespace ws

using namespace ws;

extern "C" {

WS_API void ws_shaders(const char* dir) {
  if (!S) S = new Stage();
  S->shaderDir = dir ? dir : ".";
}

WS_API int ws_attach_current(void) {
  if (!S) S = new Stage();
  if (S->running) return 0;
  EGLDisplay d = eglGetCurrentDisplay();
  EGLContext share = eglGetCurrentContext();
  if (d == EGL_NO_DISPLAY || share == EGL_NO_CONTEXT) { S->error = "no EGL context on this thread"; return 1; }
  EGLint id = 0;
  eglQueryContext(d, share, EGL_CONFIG_ID, &id);
  const EGLint want[] = {EGL_CONFIG_ID, id, EGL_NONE};
  EGLConfig config = nullptr;
  EGLint n = 0;
  if (!eglChooseConfig(d, want, &config, 1, &n) || n < 1) { S->error = "the view's EGL config is not to be had"; return 2; }
  S->display = d;
  // A Flutter view reads a texture's first row as its top; GL writes its bottom first.
  S->flipY = 1;
  S->context = makeContext(d, config, share);
  if (S->context == EGL_NO_CONTEXT) { S->error = "no GLES 3 context sharing the view's"; return 3; }
  S->running = true;
  S->thread = std::thread(run);
  return 0;
}

WS_API int ws_attach_headless(int device) {
  if (!S) S = new Stage();
  EGLDisplay d = EGL_NO_DISPLAY;
  if (device >= 0) {
    auto queryDevices = (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    auto platformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLDeviceEXT devices[16];
    EGLint count = 0;
    if (queryDevices && platformDisplay && queryDevices(16, devices, &count) && device < count) {
      d = platformDisplay(EGL_PLATFORM_DEVICE_EXT, devices[device], nullptr);
    }
  } else {
    d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  }
  if (d == EGL_NO_DISPLAY || !eglInitialize(d, nullptr, nullptr)) { S->error = "no EGL display"; return 1; }
  eglBindAPI(EGL_OPENGL_ES_API);
  const EGLint want[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
  EGLConfig config = nullptr;
  EGLint n = 0;
  if (!eglChooseConfig(d, want, &config, 1, &n) || n < 1) {
    const EGLint any[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE};
    if (!eglChooseConfig(d, any, &config, 1, &n) || n < 1) { S->error = "no GLES 3 config"; return 2; }
  }
  S->display = d;
  S->context = makeContext(d, config, EGL_NO_CONTEXT);
  if (S->context == EGL_NO_CONTEXT) { S->error = "no GLES 3 context"; return 3; }
  if (!eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, S->context)) { S->error = "surfaceless contexts are not supported here"; return 4; }
  S->headless = true;
  if (!setUp()) return 5;
  return 0;
}

WS_API int ws_attach_shared(void) {
  if (!S) S = new Stage();
#ifndef _WIN32
  S->error = "frames are shared by Direct3D handle on Windows only";
  return 5;
#else
  if (S->running) return 0;
  if (S->display == EGL_NO_DISPLAY) {
    // ANGLE on Direct3D 11: the card; failing that (or with WETOWL_STAGE_WARP=1),
    // Windows' own software rasteriser, which draws the same picture, slowly.
    auto platformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    const char* warpEnv = std::getenv("WETOWL_STAGE_WARP");
    const bool warpOnly = warpEnv && warpEnv[0] == '1';
    EGLDisplay d = EGL_NO_DISPLAY;
    for (int device = warpOnly ? 1 : 0; device < 2 && d == EGL_NO_DISPLAY; device++) {
      const EGLint attrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
                              EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE,
                              device == 0 ? EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE : EGL_PLATFORM_ANGLE_DEVICE_TYPE_D3D_WARP_ANGLE,
                              EGL_NONE};
      EGLDisplay c = platformDisplay ? platformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, attrs) : EGL_NO_DISPLAY;
      if (c != EGL_NO_DISPLAY && eglInitialize(c, nullptr, nullptr)) {
        d = c;
        S->warp = device == 1;
      }
    }
    if (d == EGL_NO_DISPLAY) {
      d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
      if (d == EGL_NO_DISPLAY || !eglInitialize(d, nullptr, nullptr)) { S->error = "no EGL display from ANGLE"; return 1; }
    }
    S->display = d;
  }
  eglBindAPI(EGL_OPENGL_ES_API);
  const EGLint want[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                         EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig config = nullptr;
  EGLint n = 0;
  if (!eglChooseConfig(S->display, want, &config, 1, &n) || n < 1) { S->error = "no GLES 3 config from ANGLE"; return 2; }
  S->config = config;
  S->context = makeContext(S->display, config, EGL_NO_CONTEXT);
  if (S->context == EGL_NO_CONTEXT) { S->error = "no GLES 3 context from ANGLE"; return 3; }
  // Something to be current on: a surface of one pixel (a surfaceless context is
  // not every driver's).
  if (S->current == EGL_NO_SURFACE) {
    const EGLint one[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    S->current = eglCreatePbufferSurface(S->display, config, one);
  }
  // Can this card share? Tried once, on a surface of eight pixels.
  void* handle = nullptr;
  EGLSurface probe = sharedSurface(8, 8, &handle);
  S->shared = probe != EGL_NO_SURFACE;
  if (probe != EGL_NO_SURFACE) eglDestroySurface(S->display, probe);
  S->readback = !S->shared;
  S->error.clear();
  // The view reads the texture's first row as its top, shared or as pixels, as
  // Flutter's Linux view does (the blit into ANGLE's surface keeps the rows as they
  // are: the first build hung the dancers from the ceiling), so the finish turns
  // the picture over; WETOWL_STAGE_FLIP=0 says otherwise, for a card that does not
  // agree.
  S->flipY = 1;
  S->headless = false;
  S->running = true;
  S->thread = std::thread(run);
  return 0;
#endif
}

WS_API int ws_features(void) {
  int f = 0;
#ifdef WS_MILK
  f |= 1;
#endif
  if (S && S->shared) f |= 2;
  if (S && S->readback) f |= 4;
  f |= 8;  // ws_treat
  f |= 16; // @sim:<name>
  f |= 32; // @slime
  f |= 64; // ws_treat mode 9, the slit-scan
  f |= 128; // ws_mosh
  f |= 256; // ws_ghosts, ws_adapt
  return f;
}

WS_API const char* ws_error(void) { return S ? S->error.c_str() : ""; }

WS_API void ws_stop(void) {
  if (!S) return;
  {
    std::lock_guard<std::mutex> g(S->napLock);
    S->running = false;
  }
  S->nap.notify_all();
  if (S->thread.joinable()) {
    S->thread.join();
    // The thread let go of everything it made (tearDown); the context goes with it.
    // The next attach makes a new one sharing the view's.
    if (!S->headless && S->context != EGL_NO_CONTEXT) {
      eglDestroyContext(S->display, S->context);
      S->context = EGL_NO_CONTEXT;
    }
    if (S->shared || S->readback) {
      // The shared surfaces and the pixels go too: the next attach makes its own.
      // Under the lock the view reads the handles by.
      std::lock_guard<std::mutex> out(S->outLock);
      for (int i = 0; i < 3; i++) {
        if (S->shares[i] != EGL_NO_SURFACE) eglDestroySurface(S->display, S->shares[i]);
        S->shares[i] = EGL_NO_SURFACE;
        S->shareHandles[i] = nullptr;
        S->shareW[i] = S->shareH[i] = 0;
      }
      if (S->current != EGL_NO_SURFACE) {
        eglDestroySurface(S->display, S->current);
        S->current = EGL_NO_SURFACE;
      }
      std::lock_guard<std::mutex> g(S->pixLock);
      S->pixelW = S->pixelH = 0;
    }
  }
}

WS_API void ws_size(int width, int height, float scale) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->width = std::max(8, width); S->height = std::max(8, height);
  S->scale = std::clamp(scale, 0.1f, 2.0f);
}

WS_API void ws_rate(float fps) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->fps = fps;
}

WS_API void ws_scene(const char* name) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->scene = name ? name : "";
}

WS_API void ws_post(float trails, float bloom, float vignette, float grain, float tone, float fringe) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  const float v[6] = {std::clamp(trails, 0.0f, 0.97f), bloom, vignette, grain, tone, fringe};
  std::memcpy(S->post, v, sizeof v);
}

WS_API void ws_from(const char* name, float k, const float* knobs) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->from = name ? name : "";
  S->fromK = std::clamp(k, 0.0f, 1.0f);
  if (knobs) std::memcpy(S->fromKnobs, knobs, sizeof S->fromKnobs);
}

WS_API void ws_flash(float white, float black, int freeze) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->flashWhite = std::clamp(white, 0.0f, 1.0f);
  S->flashBlack = std::clamp(black, 0.0f, 1.0f);
  S->freeze = freeze != 0;
}

WS_API void ws_palette(const float* rgb9) {
  if (!S || !rgb9) return;
  std::lock_guard<std::mutex> g(S->lock);
  std::memcpy(S->palette, rgb9, sizeof S->palette);
}

WS_API void ws_particles(const char* kinds) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->particleKinds = kinds ? kinds : "";
}

WS_API void ws_trails(const float* recipe, int n) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->hasRecipe = recipe && n >= 12;
  if (S->hasRecipe) std::memcpy(S->recipe, recipe, sizeof S->recipe);
}

WS_API int ws_dance_mesh(int positions, const float* pos, const float* nrm, const uint8_t* bones, const uint8_t* weights,
                         int corners, const float* uv, const uint16_t* src, int tris, const uint16_t* idx) {
  if (!S) S = new Stage();
  DanceMeshData m;
  m.pos.assign(pos, pos + (size_t)positions * 3);
  m.nrm.assign(nrm, nrm + (size_t)positions * 3);
  m.bone.assign(bones, bones + (size_t)positions * 4);
  m.weight.assign(weights, weights + (size_t)positions * 4);
  m.uv.assign(uv, uv + (size_t)corners * 2);
  m.src.assign(src, src + corners);
  m.tris.assign(idx, idx + (size_t)tris * 3);
  return S->dance.addMesh(std::move(m));
}

WS_API void ws_dance_skin(int mesh, int width, int height, const uint8_t* rgba) {
  if (!S || !rgba) return;
  S->dance.setSkin(mesh, width, height, rgba);
}

WS_API void ws_dance_texture(const char* name, int width, int height, const uint8_t* rgba, int flipRows) {
  if (!S || !name || !rgba) return;
  S->dance.setTexture(name, width, height, rgba, flipRows != 0);
}

WS_API void ws_dance_frame(const float* commands, int n) {
  if (!S || !commands) return;
  S->dance.setCommands(commands, n);
}

WS_API void ws_words(const float* values, int n) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  if (!values || n <= 0) S->words.clear();
  else S->words.assign(values, values + std::min(n, 512));
}

WS_API void ws_dump(const char* path) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->dumpPath = path ? path : "";
}

WS_API void ws_mosh(float seconds, float strength) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->moshAsk++;
  S->moshSeconds = seconds;
  S->moshStrength = strength;
}

WS_API void ws_ground(int kind, const char* field, float dim, const float* knobs4) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->groundKind = kind;
  S->groundField = field ? field : "";
  S->groundDim = std::clamp(dim, 0.0f, 1.0f);
  for (int i = 0; i < 4; i++) S->groundKnobs[i] = knobs4 ? knobs4[i] : 0;
}

WS_API void ws_blend(int mix, int mask, int coverage, float strength) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  // show_combos.dart's Mix (0 normal 1 add 2 screen 3 contrast) and Mask (0 none
  // 1 keyhole 2 inverted); the coverage 0 band, 1 alpha, 2 light.
  S->blendMix = std::clamp(mix, 0, 3);
  S->blendMask = std::clamp(mask, 0, 2);
  S->blendCoverage = std::clamp(coverage, 0, 2);
  S->blendStrength = std::clamp(strength, 0.0f, 1.0f);
}

WS_API void ws_treat(const float* p, int n) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  for (int i = 0; i < WS_TREAT; i++) S->treat[i] = p && i < n ? p[i] : 0;
}

WS_API void ws_ghosts(int count, float differ) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->ghostCount = std::clamp(count, 0, 12);
  S->ghostDiffer = std::clamp(differ, 0.0f, 1.0f);
}

WS_API void ws_slit(const float* p, int n) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  for (int i = 0; i < WS_TREAT; i++) S->slitLayer[i] = p && i < n ? p[i] : 0;
}

WS_API void ws_adapt(int on) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->adapt = on != 0;
}

WS_API void ws_inputs(const float* values, int n) {
  if (!S || !values) return;
  std::lock_guard<std::mutex> g(S->lock);
  n = std::min(n, WS_COMMON - 2);
  std::memcpy(S->common + 2, values, sizeof(float) * (size_t)n);
}

WS_API void ws_milk(const char* line, const uint8_t* payload, int length) {
  if (!S || !line) return;
  std::lock_guard<std::mutex> g(S->milkLock);
  // PCM piles up when nobody draws: the newest second of it is plenty.
  if (S->milkQueue.size() > 600) S->milkQueue.pop_front();
  S->milkQueue.emplace_back(line, payload && length > 0 ? std::vector<uint8_t>(payload, payload + length) : std::vector<uint8_t>());
}

WS_API int ws_milk_said(char* out, int capacity) {
  if (!S || !out || capacity <= 1) return 0;
  std::lock_guard<std::mutex> g(S->milkLock);
  const int n = (int)std::min<size_t>(S->milkSaid.size(), (size_t)capacity - 1);
  std::memcpy(out, S->milkSaid.data(), (size_t)n);
  out[n] = 0;
  S->milkSaid.erase(0, (size_t)n);
  return n;
}

WS_API uint32_t ws_latest(int* width, int* height) {
  if (!S) return 0;
  std::lock_guard<std::mutex> g(S->outLock);
  if (S->published < 0) return 0;
  S->shown = S->published;
  const Target& t = S->out[S->shown];
  if (S->fences[S->shown]) glWaitSync(S->fences[S->shown], 0, GL_TIMEOUT_IGNORED);
  if (width) *width = t.w;
  if (height) *height = t.h;
  return t.tex;
}

WS_API void* ws_share(int* width, int* height) {
  if (!S || !S->shared) return nullptr;
  std::lock_guard<std::mutex> g(S->outLock);
  if (S->published < 0 || !S->shareHandles[S->published]) return nullptr;
  S->shown = S->published;
  if (width) *width = S->shareW[S->shown];
  if (height) *height = S->shareH[S->shown];
  return S->shareHandles[S->shown];
}

WS_API const uint8_t* ws_pixels(int* width, int* height) {
  if (!S || !S->readback || S->pixHeld) return nullptr;
  S->pixLock.lock();
  if (S->pixelW == 0) {
    S->pixLock.unlock();
    return nullptr;
  }
  S->pixHeld = true;
  if (width) *width = S->pixelW;
  if (height) *height = S->pixelH;
  return S->pixels[S->pixelFront].data();
}

WS_API void ws_pixels_done(void) {
  if (!S || !S->pixHeld) return;
  S->pixHeld = false;
  S->pixLock.unlock();
}

WS_API void ws_on_frame(void (*callback)(void*), void* user) {
  if (!S) S = new Stage();
  std::lock_guard<std::mutex> g(S->lock);
  S->onFrame = callback; S->onFrameUser = user;
}

WS_API void ws_stats(ws_stats_t* out) {
  if (!out) return;
  *out = ws_stats_t{};
  if (!S) return;
  out->frames = S->frames.load();
  out->fps = S->rate;
  out->frame_ms = S->frameMs;
  out->worst_ms = S->worstMs;
  S->worstMs = 0;
  out->width = S->width; out->height = S->height;
  out->work_width = S->work.w; out->work_height = S->work.h;
  out->float_targets = S->floatTargets ? 1 : 0;
  out->auto_scale = S->autoScale;
}

WS_API int ws_bench(int frames, uint8_t* rgba) {
  if (!S || !S->headless) return 1;
  int slot = 0;
  for (int i = 0; i < frames; i++) {
    const auto began = Clock::now();
    frame(slot);
    glFinish();
    count(std::chrono::duration<double, std::milli>(Clock::now() - began).count());
    if (i + 1 < frames) slot = (slot + 1) % 3;
  }
  if (rgba) {
    const Target& o = S->out[slot];
    glBindFramebuffer(GL_FRAMEBUFFER, o.fbo);
    glReadPixels(0, 0, o.w, o.h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
  }
  return 0;
}

}  // extern "C"
