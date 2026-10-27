// The dancers on the native stage: the scanned bodies skinned on the GPU, with a
// depth buffer, lit per pixel, and the stages round them — drawn from a list of
// commands the Dart side records each frame (lib/src/ui/show/show_dance_surface.dart).
//
// Dart keeps what it is good at: the choreography (moves, blends, the troupe, the
// cameras' cuts) and every stage's art (tiles, beams, a sun, ribbons — as coloured
// triangles already on the picture). This draws what a canvas could not: bodies with
// real overlaps, per-pixel light and chrome, outlines from the shell's back faces,
// shadows flattened onto a floor or thrown on a wall, a mirror under the floor.
//
// The commands are floats, an op then its numbers (see the Op enum); 2D positions
// are in the reference size the camera command gives (Dart's picture), so the list
// does not care what size the stage draws at.
#pragma once
#include <GLES3/gl3.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "glsl.h"

namespace ws {

enum DanceOp {
  kFill = 1, kTris = 2, kPoints = 3, kClip = 4, kCamera = 5, kPose = 6, kBody = 7, kOutline = 8,
  kFloorShadow = 9, kWallShadow = 10, kPost = 11, kClearDepth = 12, kFluid = 13, kDust = 14,
  kMesh = 15, kPostFx = 16,
};
enum DanceBlend { kOver = 0, kPlus = 1, kSrc = 2, kDarken = 3 };
enum DanceShade { kLit = 0, kFlat = 1, kChrome = 3 };

// A mesh of a dancer, as Dart read it (show_dance_rig.dart's DanceMesh), drawn per
// corner: a position split where the skin's islands meet.
struct DanceMeshData {
  std::vector<float> pos, nrm, uv;
  std::vector<uint8_t> bone, weight;
  std::vector<uint16_t> src, tris;
  std::vector<uint8_t> skin;  // RGBA, top row first
  int skinW = 0, skinH = 0;
  bool skinDirty = false;
  // on the GPU
  GLuint vao = 0, vbo = 0, ibo = 0, tex = 0;
  int indices = 0;
  bool uploaded = false;
  // the dust: points scattered over the surface, as many to an area, in no order
  // (the first n of them are an even share), drawn through the same skinning
  GLuint dustVao = 0, dustVbo = 0;
  int dustN = 0;
};

static const char* kBodyVert = R"(#version 300 es
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNrm;
layout(location = 2) in vec4 aBones;
layout(location = 3) in vec4 aWeights;
layout(location = 4) in vec2 aUv;
uniform vec4 uSkin[96];      // 32 bones, 3 rows of a 3x4 each
uniform mat4 uModel;         // the spot: turned, mirrored, scaled, moved, lifted
uniform mat4 uViewProj;
uniform int uPass;           // 0 body, 1 outline, 2 floor shadow, 3 wall shadow
uniform float uInflate;
uniform vec3 uLight;         // floor: the light's slope (x/z, y/z); wall: the lamp
uniform float uWallY;
uniform float uFlipZ;        // 1: the mirror under the floor
out vec3 vPos;
out vec3 vNrm;
out vec2 vUv;
void main() {
  ivec4 b = ivec4(aBones + 0.5);
  vec4 r0 = vec4(0), r1 = vec4(0), r2 = vec4(0);
  for (int i = 0; i < 4; i++) {
    float w = aWeights[i];
    if (w <= 0.0) continue;
    r0 += uSkin[b[i] * 3] * w;
    r1 += uSkin[b[i] * 3 + 1] * w;
    r2 += uSkin[b[i] * 3 + 2] * w;
  }
  vec4 p = vec4(aPos, 1.0);
  vec3 local = vec3(dot(r0, p), dot(r1, p), dot(r2, p));
  vec3 n = vec3(dot(r0.xyz, aNrm), dot(r1.xyz, aNrm), dot(r2.xyz, aNrm));
  vec4 world = uModel * vec4(local, 1.0);
  vec3 wn = normalize(mat3(uModel) * n);
  if (uPass == 1) world.xyz += wn * uInflate;
  if (uPass == 2) {
    world.xy -= uLight.xy * world.z;
    world.z = 0.002;
  } else if (uPass == 3) {
    float dy = world.y - uLight.y;
    float t = abs(dy) < 1e-3 ? 1.0 : (uWallY - uLight.y) / dy;
    world.x = uLight.x + (world.x - uLight.x) * t;
    world.z = uLight.z + (world.z - uLight.z) * t;
    world.y = uWallY - 0.002;
  }
  if (uFlipZ > 0.5) { world.z = -world.z; wn.z = -wn.z; }
  vPos = world.xyz;
  vNrm = wn;
  vUv = aUv;
  gl_Position = uViewProj * world;
}
)";

static const char* kBodyFrag = R"(#version 300 es
precision highp float;
in vec3 vPos;
in vec3 vNrm;
in vec2 vUv;
uniform int uShade;          // 0 lit, 1 flat, 3 chrome; -1 one colour (outline, shadow)
uniform vec4 uColour;        // the one colour, or the flat one
uniform bool uTextured;
uniform sampler2D uSkinTex;
uniform vec3 uEye, uRight, uUp, uFwd;
uniform vec3 uKey, uKeyColour, uFill, uRim;
uniform float uKeyK, uFillK, uAmbient, uRimK, uRimPower, uToon, uAlpha, uDim, uShadeFlat;
out vec4 fragColor;

float s3(float e0, float e1, float x) { float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }

// The studio chrome reflects (show_dance_draw.dart's chromeEnv, the same numbers):
// camera space, x right, y up, z toward the eye.
vec3 chromeEnv(vec3 r) {
  vec3 c;
  if (r.y >= 0.0) {
    float k = s3(0.0, 0.85, r.y);
    c = vec3(1.0 - 0.62 * k, 1.0 - 0.58 * k, 1.0 - 0.48 * k);
  } else {
    float k = s3(0.0, -0.35, r.y);
    float band = exp(-((r.y + 0.12) * (r.y + 0.12)) / 0.002) * 0.25;
    c = vec3(0.05 + 0.5 * (1.0 - k) * (1.0 - k) + band);
  }
  float line = exp(-(r.y * r.y) / 0.0009) * 0.6;
  float l1 = dot(r, normalize(vec3(-0.45, 0.55, 0.70)));
  float l2 = dot(r, normalize(vec3(0.85, 0.15, -0.50)));
  float soft = s3(0.93, 0.975, l1) * 1.4 + s3(0.9, 0.96, l2) * 0.9;
  return c + line + soft;
}

void main() {
  if (uShade < 0) { fragColor = uColour; return; }
  vec3 n = normalize(vNrm);
  vec3 v = normalize(uEye - vPos);
  if (dot(n, v) < 0.0) n = -n;  // an open scan's inside, seen through a gap
  float edge = 1.0 - abs(dot(n, v));
  vec3 col;
  if (uShade == 3) {
    vec3 r = reflect(-v, n);
    vec3 rc = vec3(dot(r, uRight), dot(r, uUp), -dot(r, uFwd));
    float fres = 0.78 + 0.22 * edge * edge;
    col = chromeEnv(rc) * fres * uKeyColour + uRim * edge * edge * edge * uRimK;
  } else {
    vec3 kd = normalize(uKey);
    float diff = max(dot(n, kd), 0.0);
    if (uToon > 0.0) diff = ceil(diff * uToon) / uToon;
    float fill = max(0.5 - 0.5 * (n.x * kd.x + n.y * kd.y) * 0.8 - 0.2 * n.z, 0.0);
    col = vec3(uAmbient) + uKeyK * diff * uKeyColour + uFillK * fill * uFill;
    if (uShade == 1) {
      float k = uShadeFlat > 0.5 && dot(uColour.rgb, vec3(0.2126, 0.7152, 0.0722)) > 0.02 ? 0.75 + 0.35 * diff : 1.0;
      col = uColour.rgb * k;
    }
    if (uRimK > 0.001) {
      float k = pow(edge, uRimPower) * uRimK;
      if (uToon > 0.0) k = k > 0.35 ? uRimK : 0.0;
      col += uRim * k;
    }
    // The light held to 1, as the canvas holds a vertex colour: lit past white it
    // washed the brightest of a skin (a face) out to white.
    col = min(col, vec3(1.0));
    if (uTextured && uShade == 0) col *= texture(uSkinTex, vUv).rgb;
  }
  fragColor = vec4(col * uDim, uAlpha);
}
)";

// The dust (kDust): the body as points, skinned as the body is, which leave it — from
// the top down, a ragged edge — when it bursts, drift, rise and swirl, and come back.
static const char* kDustVert = R"(#version 300 es
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNrm;
layout(location = 2) in vec4 aBones;
layout(location = 3) in vec4 aWeights;
layout(location = 4) in vec2 aUv;
uniform vec4 uSkin[96];
uniform mat4 uModel;
uniform mat4 uViewProj;
uniform vec3 uEye;
uniform float uSize, uFocal, uExplode, uSwirl, uRise, uTime, uShimmer;
out vec2 vUv;
out float vLit, vK, vH, vFade;
float h11(float x) { return fract(sin(x * 12.9898 + 4.1414) * 43758.5453); }
vec3 flow(vec3 p, float t) {
  return vec3(sin(p.y * 1.7 + t * 0.9) + sin(p.z * 2.3 - t * 0.7),
              sin(p.z * 1.9 + t * 0.8) + sin(p.x * 2.1 + t * 1.1),
              sin(p.x * 1.6 - t * 0.6) + sin(p.y * 2.4 + t * 0.5)) * 0.5;
}
void main() {
  ivec4 b = ivec4(aBones + 0.5);
  vec4 r0 = vec4(0), r1 = vec4(0), r2 = vec4(0);
  for (int i = 0; i < 4; i++) {
    float w = aWeights[i];
    if (w <= 0.0) continue;
    r0 += uSkin[b[i] * 3] * w;
    r1 += uSkin[b[i] * 3 + 1] * w;
    r2 += uSkin[b[i] * 3 + 2] * w;
  }
  vec4 p = vec4(aPos, 1.0);
  vec3 local = vec3(dot(r0, p), dot(r1, p), dot(r2, p));
  vec3 n = vec3(dot(r0.xyz, aNrm), dot(r1.xyz, aNrm), dot(r2.xyz, aNrm));
  vec4 world = uModel * vec4(local, 1.0);
  vec3 wn = normalize(mat3(uModel) * n);
  if (dot(wn, uEye - world.xyz) < 0.0) wn = -wn;
  float id = float(gl_VertexID);
  float h1 = h11(id * 0.1234), h2 = h11(id * 0.731 + 3.1), h3 = h11(id * 1.917 + 7.7);
  vec3 rnd = normalize(vec3(h1, h2, h3) - 0.5 + 1e-4);
  // Which go first: the top of the body, a ragged edge down it.
  float order = clamp(1.0 - world.z / 1.9, 0.0, 1.0) * 0.6 + h2 * 0.4;
  float k = smoothstep(order * 0.7, order * 0.7 + 0.3, uExplode);
  vec3 off = (wn * 0.25 + rnd * 0.5) * k * (0.35 + h3);
  off.z += uRise * k * k * (0.4 + h1);
  off += flow(world.xyz * 1.3 + rnd * 2.0, uTime * 0.6) * uSwirl * k * 0.6;
  off += rnd * uShimmer * 0.012;
  world.xyz += off;
  gl_Position = uViewProj * world;
  float px = uSize * uFocal / max(gl_Position.w, 0.05);
  gl_PointSize = clamp(px * (1.0 - 0.3 * k), 1.0, 9.0);
  // Smaller than a pixel they pile up: each the fainter, so a body far off is not a
  // white blob — but a mote in the air, alone, is not.
  vFade = mix(clamp(pow(px / 2.4, 1.5), 0.1, 1.0), 1.0, k * 0.8);
  vLit = max(dot(wn, normalize(vec3(-0.35, -0.8, 0.65))), 0.0);
  vK = k;
  vH = clamp(world.z / 1.9, 0.0, 1.0);
  vUv = aUv;
}
)";

static const char* kDustFrag = R"(#version 300 es
precision highp float;
in vec2 vUv;
in float vLit, vK, vH, vFade;
uniform int uMode;          // 0 the skin, 1 one colour, 2 two up the body
uniform vec3 uA, uB;
uniform float uAlpha;
uniform bool uTextured;
uniform sampler2D uSkinTex;
out vec4 fragColor;
void main() {
  vec2 q = gl_PointCoord * 2.0 - 1.0;
  float r2 = dot(q, q);
  if (r2 > 1.0) discard;
  float soft = 1.0 - r2 * r2;
  vec3 col;
  if (uMode == 0 && uTextured) col = texture(uSkinTex, vUv).rgb * (0.6 + 0.6 * vLit);
  else if (uMode == 2) col = mix(uA, uB, vH) * (0.55 + 0.6 * vLit);
  else col = uA * (0.45 + 0.75 * vLit);
  // A mote in the air cools towards the second colour and dims.
  col = mix(col, uB * 0.9, vK * 0.55);
  float a = soft * uAlpha * vFade;
  // Added up as light; its coverage (the blend's alpha) built up three times as fast,
  // so where the dust is, the figure is — faint motes and all.
  fragColor = vec4(col * a, a * 3.0);
}
)";

static const char* kFlatVert = R"(#version 300 es
layout(location = 0) in vec2 aPos;    // pixels of the reference picture, y from the top
layout(location = 1) in vec4 aColour;
uniform vec2 uRef;
out vec4 vColour;
void main() {
  vColour = aColour;
  vec2 ndc = aPos / uRef * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
)";

static const char* kFlatFrag = R"(#version 300 es
precision highp float;
in vec4 vColour;
out vec4 fragColor;
void main() { fragColor = vColour; }
)";

// A mesh (the murmuration's birds, its sprites): a colour per corner, multiplying a
// picture where it has one (the pigeon's skin, the soft sprite), indexed or not.
static const char* kMeshVert = R"(#version 300 es
layout(location = 0) in vec2 aPos;    // pixels of the reference picture, y from the top
layout(location = 1) in vec2 aUv;     // 0..1 over the picture, from its top row
layout(location = 2) in vec4 aColour;
uniform vec2 uRef;
out vec2 vUv;
out vec4 vColour;
void main() {
  vUv = aUv;
  vColour = aColour;
  vec2 ndc = aPos / uRef * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
)";

static const char* kMeshFrag = R"(#version 300 es
precision highp float;
uniform sampler2D uTex;
uniform float uTextured;
in vec2 vUv;
in vec4 vColour;
out vec4 fragColor;
// The picture went up bottom row first (setTexture's flip), as GL keeps one.
void main() { fragColor = uTextured > 0.5 ? texture(uTex, vec2(vUv.x, 1.0 - vUv.y)) * vColour : vColour; }
)";

// Soft round points (the mirror ball's flecks): a quad each, instanced.
static const char* kDotVert = R"(#version 300 es
layout(location = 0) in vec2 aAt;
uniform vec2 uRef;
uniform float uRadius;
out vec2 vLocal;
void main() {
  vec2 corner = vec2(float(gl_VertexID & 1), float((gl_VertexID >> 1) & 1)) * 2.0 - 1.0;
  vLocal = corner;
  vec2 ndc = (aAt + corner * uRadius) / uRef * 2.0 - 1.0;
  gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
}
)";

static const char* kDotFrag = R"(#version 300 es
precision highp float;
in vec2 vLocal;
uniform vec4 uColour;
out vec4 fragColor;
void main() {
  float a = 1.0 - smoothstep(0.7, 1.0, length(vLocal));
  fragColor = vec4(uColour.rgb, uColour.a * a);
}
)";

class Dance {
 public:
  // Registered from any thread; uploaded on the stage's.
  int addMesh(DanceMeshData&& m) {
    std::lock_guard<std::mutex> g(lock_);
    meshes_.push_back(std::make_unique<DanceMeshData>(std::move(m)));
    return (int)meshes_.size() - 1;
  }
  void setSkin(int id, int w, int h, const uint8_t* rgba) {
    std::lock_guard<std::mutex> g(lock_);
    if (id < 0 || id >= (int)meshes_.size()) return;
    auto& m = *meshes_[(size_t)id];
    m.skin.assign(rgba, rgba + (size_t)w * h * 4);
    m.skinW = w; m.skinH = h; m.skinDirty = true;
  }
  void setTexture(const std::string& name, int w, int h, const uint8_t* rgba, bool flipRows) {
    std::lock_guard<std::mutex> g(lock_);
    auto& t = pendingTex_[name];
    t.w = w; t.h = h; t.data.assign((size_t)w * h * 4, 0);
    t.dirty = true;
    for (int y = 0; y < h; y++)
      std::memcpy(t.data.data() + (size_t)y * w * 4, rgba + (size_t)(flipRows ? h - 1 - y : y) * w * 4, (size_t)w * 4);
  }
  void setCommands(const float* c, int n) {
    std::lock_guard<std::mutex> g(lock_);
    commands_.assign(c, c + n);
  }
  // Whether the frame drawn last was the plain look — its bodies drawn to replace
  // (kSrc), in their own colours: the figure that goes over the ground whole.
  bool plainThisFrame() const { return plain_; }

  // A named texture, uploaded (the room's frame, the cover), or 0. On the stage's
  // thread: what came in since goes up first.
  GLuint texture(const std::string& name) {
    {
      std::lock_guard<std::mutex> g(lock_);
      for (auto& [n, t] : pendingTex_) if (t.dirty) { uploadTex(n, t); t.dirty = false; }
    }
    auto it = textures_.find(name);
    return it == textures_.end() ? 0 : it->second;
  }

  bool hasCommands() {
    std::lock_guard<std::mutex> g(lock_);
    return !commands_.empty();
  }

  // On the stage's thread, the old context still current: every GL object let go,
  // so the next context builds its own. The stage stops and starts again with a new
  // context when its texture is closed and opened (a window gone full screen and
  // back); a vertex array or a framebuffer is a context's own, and bound by its old
  // name in a new one it is nothing — the dancers drew through theirs with no index
  // buffer bound, and the driver read their indices from address zero. The CPU
  // copies stay: meshes, skins and textures go up again on the next frame.
  void lost() {
    std::lock_guard<std::mutex> g(lock_);
    for (auto& mp : meshes_) {
      auto& m = *mp;
      if (m.vao) glDeleteVertexArrays(1, &m.vao);
      if (m.vbo) glDeleteBuffers(1, &m.vbo);
      if (m.ibo) glDeleteBuffers(1, &m.ibo);
      if (m.tex) glDeleteTextures(1, &m.tex);
      if (m.dustVao) glDeleteVertexArrays(1, &m.dustVao);
      if (m.dustVbo) glDeleteBuffers(1, &m.dustVbo);
      m.vao = m.vbo = m.ibo = m.tex = m.dustVao = m.dustVbo = 0;
      m.dustN = 0;
      m.uploaded = false;
      m.skinDirty = m.skinW > 0 && !m.skin.empty();
    }
    for (auto& [name, t] : textures_) if (t) glDeleteTextures(1, &t);
    textures_.clear();
    for (auto& [name, t] : pendingTex_) t.dirty = true;
    for (GLuint* p : {&body_, &flat_, &dot_, &mesh_, &dust_, &fVel_, &fDye_, &fDiv_, &fJac_, &fProj_, &fShow_}) {
      if (*p) glDeleteProgram(*p);
      *p = 0;
    }
    for (GLuint* v : {&flatVao_, &dotVao_, &meshVao_, &emptyVao_}) {
      if (*v) glDeleteVertexArrays(1, v);
      *v = 0;
    }
    for (GLuint* b : {&flatVbo_, &dotVbo_, &meshVbo_, &meshIbo_}) {
      if (*b) glDeleteBuffers(1, b);
      *b = 0;
    }
    for (FTarget* t : {&fVelA_, &fVelB_, &fDyeA_, &fDyeB_, &fPresA_, &fPresB_, &fDivT_, &fMask_}) t->drop();
  }

  // On the stage's thread: the commands into `t` (which has a depth buffer), the
  // post, where asked for, through `post` into `scratch` and back.
  void draw(GLuint fbo, GLuint tex, int w, int h, glsl::Programs& programs, GLuint scratchFbo) {
    std::vector<float> c;
    {
      std::lock_guard<std::mutex> g(lock_);
      c = commands_;
      for (auto& m : meshes_) upload(*m);
      for (auto& [name, t] : pendingTex_) if (t.dirty) { uploadTex(name, t); t.dirty = false; }
    }
    if (!setUp()) return;
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glViewport(0, 0, w, h);
    // Alpha is the coverage (shaders/show/under.frag): nothing drawn yet is none.
    glClearColor(0, 0, 0, 0);
    glClearDepthf(1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    w_ = w; h_ = h;
    firstDraw_ = true;
    plain_ = false;
    size_t i = 0;
    while (i < c.size()) {
      const int op = (int)c[i++];
      switch (op) {
        case kFill: {
          const float x0 = c[i], y0 = c[i + 1], x1 = c[i + 2], y1 = c[i + 3];
          float col[4] = {c[i + 4], c[i + 5], c[i + 6], c[i + 7]};
          int blend = (int)c[i + 8];
          i += 9;
          // The first fill over the whole picture is the stage's paper (its backdrop):
          // kept in its colour but at no coverage, so the blend can treat it as the
          // ground's to take, where the bodies over it are the figure's.
          if (firstDraw_ && x0 <= 0 && y0 <= 0 && x1 >= refW_ && y1 >= refH_) {
            col[3] = 0;
            blend = kSrc;
          }
          firstDraw_ = false;
          const float v[36] = {x0, y0, col[0], col[1], col[2], col[3], x1, y0, col[0], col[1], col[2], col[3],
                               x1, y1, col[0], col[1], col[2], col[3], x0, y0, col[0], col[1], col[2], col[3],
                               x1, y1, col[0], col[1], col[2], col[3], x0, y1, col[0], col[1], col[2], col[3]};
          tris(v, 6, blend);
          break;
        }
        case kTris: {
          firstDraw_ = false;
          const int n = (int)c[i], blend = (int)c[i + 1];
          i += 2;
          tris(&c[i], n, blend);
          i += (size_t)n * 6;
          break;
        }
        case kPoints: {
          firstDraw_ = false;
          const int n = (int)c[i];
          const float radius = c[i + 1];
          const float col[4] = {c[i + 2], c[i + 3], c[i + 4], c[i + 5]};
          const int blend = (int)c[i + 6];
          i += 7;
          points(&c[i], n, radius, col, blend);
          i += (size_t)n * 2;
          break;
        }
        case kClip: {
          const float x0 = c[i], y0 = c[i + 1], x1 = c[i + 2], y1 = c[i + 3];
          i += 4;
          if (x0 < 0) {
            glDisable(GL_SCISSOR_TEST);
          } else {
            const float sx = w_ / refW_, sy = h_ / refH_;
            glEnable(GL_SCISSOR_TEST);
            glScissor((int)(x0 * sx), (int)(h_ - y1 * sy), (int)((x1 - x0) * sx), (int)((y1 - y0) * sy));
          }
          break;
        }
        case kCamera:
          camera(&c[i]);
          i += 12;
          break;
        case kPose: {
          const int slot = (int)c[i], mesh = (int)c[i + 1], bones = (int)c[i + 2];
          Pose& p = poses_[slot];
          p.mesh = mesh;
          spot(&c[i + 3], p.model);
          std::memset(p.skin, 0, sizeof p.skin);
          for (int b = 0; b < bones && b < 32; b++)
            for (int r = 0; r < 3; r++)
              for (int k = 0; k < 4; k++) p.skin[(b * 3 + r) * 4 + k] = c[i + 9 + (size_t)b * 12 + r * 4 + k];
          i += 9 + (size_t)bones * 12;
          break;
        }
        case kBody: {
          firstDraw_ = false;
          body(&c[i]);
          i += 31;
          break;
        }
        case kOutline: {
          const int slot = (int)c[i];
          const float width = c[i + 1];
          const float col[4] = {c[i + 2], c[i + 3], c[i + 4], c[i + 5]};
          const int blend = (int)c[i + 6];
          i += 7;
          pass(slot, 1, width, nullptr, 0, col, blend, /*backOnly*/ true);
          break;
        }
        case kFloorShadow: {
          const int slot = (int)c[i];
          const float l[3] = {c[i + 1], c[i + 2], c[i + 3]};
          const float col[4] = {c[i + 4], c[i + 5], c[i + 6], 1};
          i += 7;
          if (l[2] < 0.05f) break;
          const float slope[3] = {l[0] / l[2], l[1] / l[2], 0};
          pass(slot, 2, 0, slope, 0, col, kDarken, false);
          break;
        }
        case kWallShadow: {
          const int slot = (int)c[i];
          const float lamp[3] = {c[i + 1], c[i + 2], c[i + 3]};
          const float wallY = c[i + 4];
          const float col[4] = {c[i + 5], c[i + 6], c[i + 7], 1};
          i += 8;
          pass(slot, 3, 0, lamp, wallY, col, kDarken, false);
          break;
        }
        case kPost: {
          post(&c[i], programs, fbo, tex, scratchFbo);
          i += 19;
          break;
        }
        case kFluid: {
          firstDraw_ = false;
          const int nSplats = (int)c[i], nSlots = (int)c[i + 1];
          fluid(&c[i], fbo);
          i += 13 + (size_t)nSplats * 5 + (size_t)nSlots;
          break;
        }
        case kClearDepth:
          glClear(GL_DEPTH_BUFFER_BIT);
          break;
        case kDust: {
          firstDraw_ = false;
          dust(&c[i]);
          i += 17;
          break;
        }
        case kMesh: {
          firstDraw_ = false;
          const int nv = (int)c[i], ni = (int)c[i + 1], blend = (int)c[i + 2], texId = (int)c[i + 3];
          i += 4;
          const size_t need = (size_t)std::max(0, nv) * 8 + (size_t)std::max(0, ni);
          if (nv < 0 || ni < 0 || i + need > c.size()) { i = c.size(); break; }
          mesh(c.data() + i, nv, c.data() + i + (size_t)nv * 8, ni, blend, texId);
          i += need;
          break;
        }
        case kPostFx: {
          // which finish (0 dance_fx, 1 flock_fx), its glyphs (mesh.<n>, -1 the
          // dancers'), its alpha out, flock_fx's sweep, then as kPost's.
          if (i + 23 > c.size()) { i = c.size(); break; }
          const int which = (int)c[i], atlas = (int)c[i + 1];
          GLuint atlasTex = 0;
          if (atlas >= 0) {
            auto it = textures_.find("mesh." + std::to_string(atlas));
            if (it != textures_.end()) atlasTex = it->second;
          }
          if (atlas < 0 || atlasTex) post(&c[i + 4], programs, fbo, tex, scratchFbo, which == 1 ? "sim/flock_fx" : "sim/dance_fx", atlasTex, c[i + 2], c[i + 3]);
          i += 23;
          break;
        }
        default:
          i = c.size();  // a list it does not understand: stop rather than misread
      }
    }
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_BLEND);
    glBlendEquation(GL_FUNC_ADD);
    glDepthMask(GL_TRUE);
  }

 private:
  struct Pose {
    int mesh = -1;
    float skin[32 * 12] = {};
    float model[16] = {};
    bool mirrored = false;
  };
  struct PendingTex { int w = 0, h = 0; std::vector<uint8_t> data; bool dirty = true; };

  bool setUp() {
    if (body_) return true;
    std::string err;
    body_ = glsl::link(kBodyVert, kBodyFrag, err);
    flat_ = body_ ? glsl::link(kFlatVert, kFlatFrag, err) : 0;
    dot_ = flat_ ? glsl::link(kDotVert, kDotFrag, err) : 0;
    mesh_ = dot_ ? glsl::link(kMeshVert, kMeshFrag, err) : 0;
    if (!mesh_) {
      std::fprintf(stderr, "stage: the dancers' shaders: %s\n", err.c_str());
      body_ = flat_ = 0;
      return false;
    }
    glGenVertexArrays(1, &flatVao_);
    glGenBuffers(1, &flatVbo_);
    glBindVertexArray(flatVao_);
    glBindBuffer(GL_ARRAY_BUFFER, flatVbo_);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)(2 * sizeof(float)));
    glGenVertexArrays(1, &emptyVao_);
    glGenVertexArrays(1, &dotVao_);
    glGenBuffers(1, &dotVbo_);
    glBindVertexArray(dotVao_);
    glBindBuffer(GL_ARRAY_BUFFER, dotVbo_);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), (void*)0);
    glVertexAttribDivisor(0, 1);
    glGenVertexArrays(1, &meshVao_);
    glGenBuffers(1, &meshVbo_);
    glGenBuffers(1, &meshIbo_);
    glBindVertexArray(meshVao_);
    glBindBuffer(GL_ARRAY_BUFFER, meshVbo_);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8 * sizeof(float), (void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 8 * sizeof(float), (void*)(2 * sizeof(float)));
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, 8 * sizeof(float), (void*)(4 * sizeof(float)));
    glBindVertexArray(0);
    return true;
  }

  void upload(DanceMeshData& m) {
    if (!m.uploaded) {
      // per corner: pos 3, nrm 3, bones 4 (bytes), weights 4 (bytes), uv 2
      const size_t corners = m.src.size();
      std::vector<uint8_t> buf(corners * 40);
      for (size_t k = 0; k < corners; k++) {
        const size_t p = m.src[k];
        uint8_t* o = buf.data() + k * 40;
        std::memcpy(o, &m.pos[p * 3], 12);
        std::memcpy(o + 12, &m.nrm[p * 3], 12);
        std::memcpy(o + 24, &m.bone[p * 4], 4);
        std::memcpy(o + 28, &m.weight[p * 4], 4);
        std::memcpy(o + 32, &m.uv[k * 2], 8);
      }
      glGenVertexArrays(1, &m.vao);
      glGenBuffers(1, &m.vbo);
      glGenBuffers(1, &m.ibo);
      glBindVertexArray(m.vao);
      glBindBuffer(GL_ARRAY_BUFFER, m.vbo);
      glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)buf.size(), buf.data(), GL_STATIC_DRAW);
      glEnableVertexAttribArray(0);
      glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 40, (void*)0);
      glEnableVertexAttribArray(1);
      glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 40, (void*)12);
      glEnableVertexAttribArray(2);
      glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_FALSE, 40, (void*)24);
      glEnableVertexAttribArray(3);
      glVertexAttribPointer(3, 4, GL_UNSIGNED_BYTE, GL_TRUE, 40, (void*)28);
      glEnableVertexAttribArray(4);
      glVertexAttribPointer(4, 2, GL_FLOAT, GL_FALSE, 40, (void*)32);
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, m.ibo);
      glBufferData(GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)(m.tris.size() * 2), m.tris.data(), GL_STATIC_DRAW);
      glBindVertexArray(0);
      m.indices = (int)m.tris.size();
      m.uploaded = true;
    }
    if (m.skinDirty && m.skinW > 0) {
      if (!m.tex) glGenTextures(1, &m.tex);
      glBindTexture(GL_TEXTURE_2D, m.tex);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, m.skinW, m.skinH, 0, GL_RGBA, GL_UNSIGNED_BYTE, m.skin.data());
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      // The copy stays: it goes up again in a new context (lost()).
      m.skinDirty = false;
    }
  }


  void uploadTex(const std::string& name, PendingTex& t) {
    GLuint& tex = textures_[name];
    if (!tex) glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, t.w, t.h, 0, GL_RGBA, GL_UNSIGNED_BYTE, t.data.data());
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  }

  static void blendFor(int blend) {
    glBlendEquation(GL_FUNC_ADD);
    switch (blend) {
      case kPlus: glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE); break;
      case kSrc: glDisable(GL_BLEND); break;
      case kDarken: glEnable(GL_BLEND); glBlendEquation(GL_MIN); break;
      default: glEnable(GL_BLEND); glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA); break;
    }
  }

  void tris(const float* v, int n, int blend) {
    if (n <= 0) return;
    glDisable(GL_DEPTH_TEST);
    blendFor(blend);
    glUseProgram(flat_);
    glUniform2f(glGetUniformLocation(flat_, "uRef"), refW_, refH_);
    glBindVertexArray(flatVao_);
    glBindBuffer(GL_ARRAY_BUFFER, flatVbo_);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)n * 6 * sizeof(float), v, GL_STREAM_DRAW);
    glDrawArrays(GL_TRIANGLES, 0, n);
  }

  void mesh(const float* v, int nv, const float* idx, int ni, int blend, int texId) {
    if (nv <= 0) return;
    GLuint t = 0;
    if (texId >= 0) {
      auto it = textures_.find("mesh." + std::to_string(texId));
      if (it != textures_.end()) t = it->second;
    }
    glDisable(GL_DEPTH_TEST);
    blendFor(blend);
    glUseProgram(mesh_);
    glUniform2f(glGetUniformLocation(mesh_, "uRef"), refW_, refH_);
    glUniform1f(glGetUniformLocation(mesh_, "uTextured"), t ? 1.0f : 0.0f);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, t);
    glUniform1i(glGetUniformLocation(mesh_, "uTex"), 0);
    glBindVertexArray(meshVao_);
    glBindBuffer(GL_ARRAY_BUFFER, meshVbo_);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)nv * 8 * sizeof(float), v, GL_STREAM_DRAW);
    if (ni > 0) {
      meshIdx_.resize((size_t)ni);
      for (int k = 0; k < ni; k++) meshIdx_[(size_t)k] = (GLuint)std::clamp((int)idx[k], 0, nv - 1);
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, meshIbo_);
      glBufferData(GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)ni * sizeof(GLuint), meshIdx_.data(), GL_STREAM_DRAW);
      glDrawElements(GL_TRIANGLES, ni, GL_UNSIGNED_INT, nullptr);
    } else {
      glDrawArrays(GL_TRIANGLES, 0, nv);
    }
  }

  void points(const float* at, int n, float radius, const float* col, int blend) {
    if (n <= 0) return;
    glDisable(GL_DEPTH_TEST);
    blendFor(blend);
    glUseProgram(dot_);
    glUniform2f(glGetUniformLocation(dot_, "uRef"), refW_, refH_);
    glUniform1f(glGetUniformLocation(dot_, "uRadius"), radius);
    glUniform4f(glGetUniformLocation(dot_, "uColour"), col[0], col[1], col[2], col[3]);
    glBindVertexArray(dotVao_);
    glBindBuffer(GL_ARRAY_BUFFER, dotVbo_);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)n * 2 * sizeof(float), at, GL_STREAM_DRAW);
    glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, n);
  }

  // DanceCam (show_dance_draw.dart), as a matrix: screen x = cx + focal·(d·right)/z,
  // screen y (down) = cy − focal·(d·up)/z, z = d·forward — the same picture the Dart
  // side's backgrounds were projected into.
  void camera(const float* c) {
    const float ex = c[0], ey = c[1], ez = c[2], tx = c[3], ty = c[4], tz = c[5];
    const float fov = c[6], roll = c[7], shx = c[8], shy = c[9];
    refW_ = c[10]; refH_ = c[11];
    float f[3] = {tx - ex, ty - ey, tz - ez};
    norm(f);
    float r[3] = {f[1] * 1 - f[2] * 0, f[2] * 0 - f[0] * 1, f[0] * 0 - f[1] * 0};  // f × (0,0,1)
    if (len(r) < 1e-6f) { r[0] = 1; r[1] = 0; r[2] = 0; }
    norm(r);
    float u[3] = {r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0]};
    if (roll != 0) {
      const float cs = std::cos(roll), sn = std::sin(roll);
      float r2[3], u2[3];
      for (int k = 0; k < 3; k++) { r2[k] = r[k] * cs + u[k] * sn; u2[k] = u[k] * cs - r[k] * sn; }
      std::memcpy(r, r2, sizeof r); std::memcpy(u, u2, sizeof u);
    }
    eye_[0] = ex; eye_[1] = ey; eye_[2] = ez;
    std::memcpy(right_, r, sizeof r); std::memcpy(up_, u, sizeof u); std::memcpy(fwd_, f, sizeof f);
    const float focal = refH_ / 2 / std::tan(fov / 2);
    focal_ = focal;
    const float cx = refW_ / 2 + shx * refW_, cy = refH_ / 2 + shy * refH_;
    const float n = 0.05f, fa = 200.0f;
    // rows of clip = M · (world − eye): X = right, Y = up, Z = forward (depth)
    const float ax = 2 * focal / refW_, bx = 2 * cx / refW_ - 1;
    const float ay = 2 * focal / refH_, by = 1 - 2 * cy / refH_;
    const float az = (fa + n) / (fa - n), bz = -2 * fa * n / (fa - n);
    float rows[4][4];
    for (int k = 0; k < 3; k++) {
      rows[0][k] = ax * r[k] + bx * f[k];
      rows[1][k] = ay * u[k] + by * f[k];
      rows[2][k] = az * f[k];
      rows[3][k] = f[k];
    }
    const float e[3] = {ex, ey, ez};
    rows[0][3] = -(rows[0][0] * e[0] + rows[0][1] * e[1] + rows[0][2] * e[2]);
    rows[1][3] = -(rows[1][0] * e[0] + rows[1][1] * e[1] + rows[1][2] * e[2]);
    rows[2][3] = -(rows[2][0] * e[0] + rows[2][1] * e[1] + rows[2][2] * e[2]) + bz;
    rows[3][3] = -(rows[3][0] * e[0] + rows[3][1] * e[1] + rows[3][2] * e[2]);
    // column-major for GL
    for (int col = 0; col < 4; col++)
      for (int row = 0; row < 4; row++) viewProj_[col * 4 + row] = rows[row][col];
  }

  // DanceSpot: x y yaw mirror scale lift.
  static void spot(const float* s, float* m) {
    const float x = s[0], y = s[1], yaw = s[2], mirror = s[3] > 0.5f ? -1.0f : 1.0f, k = s[4], lift = s[5];
    const float c = std::cos(yaw), sn = std::sin(yaw);
    // world = T · R(yaw) · S(k) · Mirror(x)
    float M[16] = {c * k * mirror, sn * k * mirror, 0, 0, -sn * k, c * k, 0, 0, 0, 0, k, 0, x, y, lift, 1};
    std::memcpy(m, M, sizeof M);
  }

  void bindPose(const Pose& p, const DanceMeshData& m, int passKind, float inflate, const float* light, float wallY, bool flipZ) {
    glUseProgram(body_);
    glUniform4fv(glGetUniformLocation(body_, "uSkin"), 96, p.skin);
    glUniformMatrix4fv(glGetUniformLocation(body_, "uModel"), 1, GL_FALSE, p.model);
    glUniformMatrix4fv(glGetUniformLocation(body_, "uViewProj"), 1, GL_FALSE, viewProj_);
    glUniform1i(glGetUniformLocation(body_, "uPass"), passKind);
    glUniform1f(glGetUniformLocation(body_, "uInflate"), inflate);
    glUniform3f(glGetUniformLocation(body_, "uLight"), light ? light[0] : 0, light ? light[1] : 0, light ? light[2] : 0);
    glUniform1f(glGetUniformLocation(body_, "uWallY"), wallY);
    glUniform1f(glGetUniformLocation(body_, "uFlipZ"), flipZ ? 1.0f : 0.0f);
    glUniform3fv(glGetUniformLocation(body_, "uEye"), 1, eye_);
    glUniform3fv(glGetUniformLocation(body_, "uRight"), 1, right_);
    glUniform3fv(glGetUniformLocation(body_, "uUp"), 1, up_);
    glUniform3fv(glGetUniformLocation(body_, "uFwd"), 1, fwd_);
    glBindVertexArray(m.vao);
  }

  // Which way round a front face winds once the spot (and the mirror under the floor)
  // has had its say: a mirror turns it over.
  void frontFace(bool mirrored, bool flipZ) {
    const bool flip = mirrored != flipZ;
    glFrontFace(flip ? GL_CW : GL_CCW);
  }

  void pass(int slot, int kind, float inflate, const float* light, float wallY, const float* col, int blend, bool backOnly) {
    auto it = poses_.find(slot);
    if (it == poses_.end()) return;
    const Pose& p = it->second;
    std::lock_guard<std::mutex> g(lock_);
    if (p.mesh < 0 || p.mesh >= (int)meshes_.size()) return;
    const DanceMeshData& m = *meshes_[(size_t)p.mesh];
    if (!m.uploaded) return;
    bindPose(p, m, kind, inflate, light, wallY, false);
    glUniform1i(glGetUniformLocation(body_, "uShade"), -1);
    glUniform4f(glGetUniformLocation(body_, "uColour"), col[0], col[1], col[2], col[3]);
    blendFor(blend);
    if (backOnly) {
      // the shell's back faces only: the outline round the body, behind it
      glEnable(GL_CULL_FACE);
      glCullFace(GL_FRONT);
      frontFace(p.model[0] * p.model[5] - p.model[1] * p.model[4] < 0, false);
      glEnable(GL_DEPTH_TEST);
      glDepthFunc(GL_LEQUAL);
      glDepthMask(blend == kOver ? GL_TRUE : GL_FALSE);
    } else {
      // a shadow: flat on its plane, every face, no depth (it lies under the bodies)
      glDisable(GL_CULL_FACE);
      glDisable(GL_DEPTH_TEST);
    }
    glDrawElements(GL_TRIANGLES, m.indices, GL_UNSIGNED_SHORT, nullptr);
    glDisable(GL_CULL_FACE);
    glDepthMask(GL_TRUE);
  }

  // slot shade underFloor twoSided blend | key3 keyColour3 keyK | fill3 fillK ambient |
  // rim3 rimK rimPower | flat4 (a < 0: none) shadeFlat toon alpha dim textured
  void body(const float* b) {
    const int slot = (int)b[0], shade = (int)b[1];
    const bool underFloor = b[2] > 0.5f;
    const int blend = (int)b[4];
    if (blend == kSrc) plain_ = true;
    auto it = poses_.find(slot);
    if (it == poses_.end()) return;
    const Pose& p = it->second;
    std::lock_guard<std::mutex> g(lock_);
    if (p.mesh < 0 || p.mesh >= (int)meshes_.size()) return;
    const DanceMeshData& m = *meshes_[(size_t)p.mesh];
    if (!m.uploaded) return;
    bindPose(p, m, 0, 0, nullptr, 0, underFloor);
    glUniform1i(glGetUniformLocation(body_, "uShade"), shade);
    glUniform3f(glGetUniformLocation(body_, "uKey"), b[5], b[6], b[7]);
    glUniform3f(glGetUniformLocation(body_, "uKeyColour"), b[8], b[9], b[10]);
    glUniform1f(glGetUniformLocation(body_, "uKeyK"), b[11]);
    glUniform3f(glGetUniformLocation(body_, "uFill"), b[12], b[13], b[14]);
    glUniform1f(glGetUniformLocation(body_, "uFillK"), b[15]);
    glUniform1f(glGetUniformLocation(body_, "uAmbient"), b[16]);
    glUniform3f(glGetUniformLocation(body_, "uRim"), b[17], b[18], b[19]);
    glUniform1f(glGetUniformLocation(body_, "uRimK"), b[20]);
    glUniform1f(glGetUniformLocation(body_, "uRimPower"), b[21]);
    glUniform4f(glGetUniformLocation(body_, "uColour"), b[22], b[23], b[24], b[25]);
    glUniform1f(glGetUniformLocation(body_, "uShadeFlat"), b[26]);
    glUniform1f(glGetUniformLocation(body_, "uToon"), b[27]);
    glUniform1f(glGetUniformLocation(body_, "uAlpha"), b[28]);
    glUniform1f(glGetUniformLocation(body_, "uDim"), b[29]);
    const bool textured = b[30] > 0.5f && m.tex;
    glUniform1i(glGetUniformLocation(body_, "uTextured"), textured ? 1 : 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, m.tex);
    glUniform1i(glGetUniformLocation(body_, "uSkinTex"), 0);
    blendFor(blend);
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LEQUAL);
    // An added body (an afterimage) does not hide what is behind it.
    glDepthMask(blend == kPlus ? GL_FALSE : GL_TRUE);
    glDisable(GL_CULL_FACE);
    glDrawElements(GL_TRIANGLES, m.indices, GL_UNSIGNED_SHORT, nullptr);
    glDepthMask(GL_TRUE);
  }

  // The mesh's surface as points: about [kDustPoints] of them by area, each with the
  // position, normal, skin weights (the corners', by where it lies, the four most) and
  // texture place where it lies; shuffled, so any first share of them is even.
  static constexpr int kDustPoints = 160000;
  static void buildDust(DanceMeshData& m) {
    const size_t tris = m.tris.size() / 3;
    if (!tris || m.dustVbo) return;
    std::vector<float> area(tris);
    double total = 0;
    auto P = [&](int corner) { return &m.pos[(size_t)m.src[(size_t)corner] * 3]; };
    for (size_t t = 0; t < tris; t++) {
      const float *a = P(m.tris[t * 3]), *b = P(m.tris[t * 3 + 1]), *c = P(m.tris[t * 3 + 2]);
      const float u[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]}, v[3] = {c[0] - a[0], c[1] - a[1], c[2] - a[2]};
      const float x = u[1] * v[2] - u[2] * v[1], y = u[2] * v[0] - u[0] * v[2], z = u[0] * v[1] - u[1] * v[0];
      area[t] = 0.5f * std::sqrt(x * x + y * y + z * z);
      total += area[t];
    }
    if (total <= 0) return;
    uint32_t seed = 0x9e3779b9u;
    auto rnd = [&]() { seed = seed * 1664525u + 1013904223u; return (float)(seed >> 8) / 16777216.0f; };
    std::vector<uint8_t> buf;
    buf.reserve((size_t)kDustPoints * 44);
    for (size_t t = 0; t < tris; t++) {
      const float want = (float)(area[t] / total * kDustPoints);
      int k = (int)want + (rnd() < want - std::floor(want) ? 1 : 0);
      const int cs[3] = {m.tris[t * 3], m.tris[t * 3 + 1], m.tris[t * 3 + 2]};
      for (int j = 0; j < k; j++) {
        float bu = rnd(), bv = rnd();
        if (bu + bv > 1) { bu = 1 - bu; bv = 1 - bv; }
        const float bw[3] = {1 - bu - bv, bu, bv};
        float pos[3] = {}, nrm[3] = {}, uv[2] = {};
        float wsum[256] = {};
        int used[12], nUsed = 0;
        for (int q = 0; q < 3; q++) {
          const size_t pi = m.src[(size_t)cs[q]];
          for (int d = 0; d < 3; d++) { pos[d] += m.pos[pi * 3 + d] * bw[q]; nrm[d] += m.nrm[pi * 3 + d] * bw[q]; }
          uv[0] += m.uv[(size_t)cs[q] * 2] * bw[q];
          uv[1] += m.uv[(size_t)cs[q] * 2 + 1] * bw[q];
          for (int e = 0; e < 4; e++) {
            const int bone = m.bone[pi * 4 + e];
            const float w = m.weight[pi * 4 + e] / 255.0f * bw[q];
            if (w <= 0) continue;
            if (wsum[bone] == 0) used[nUsed++] = bone;
            wsum[bone] += w;
          }
        }
        // the four heaviest, to 255 together
        uint8_t bones[4] = {}, weights[4] = {};
        float top[4] = {};
        for (int u2 = 0; u2 < nUsed; u2++) {
          const int bone = used[u2];
          const float w = wsum[bone];
          for (int s = 0; s < 4; s++) {
            if (w > top[s]) {
              for (int r = 3; r > s; r--) { top[r] = top[r - 1]; bones[r] = bones[r - 1]; }
              top[s] = w; bones[s] = (uint8_t)bone;
              break;
            }
          }
        }
        const float sum = top[0] + top[1] + top[2] + top[3];
        int given = 0;
        for (int s = 0; s < 4; s++) {
          weights[s] = (uint8_t)std::lround(sum > 0 ? top[s] / sum * 255 : (s == 0 ? 255 : 0));
          given += weights[s];
        }
        weights[0] = (uint8_t)std::clamp(weights[0] + 255 - given, 0, 255);
        const float nl = std::sqrt(nrm[0] * nrm[0] + nrm[1] * nrm[1] + nrm[2] * nrm[2]) + 1e-6f;
        for (float& x : nrm) x /= nl;
        const size_t at = buf.size();
        buf.resize(at + 40);
        uint8_t* o = buf.data() + at;
        std::memcpy(o, pos, 12);
        std::memcpy(o + 12, nrm, 12);
        std::memcpy(o + 24, bones, 4);
        std::memcpy(o + 28, weights, 4);
        std::memcpy(o + 32, uv, 8);
      }
    }
    const size_t n = buf.size() / 40;
    for (size_t a = n; a > 1; a--) {
      const size_t b = (size_t)(rnd() * a) % a;
      if (b != a - 1) for (int q = 0; q < 40; q++) std::swap(buf[(a - 1) * 40 + q], buf[b * 40 + q]);
    }
    glGenVertexArrays(1, &m.dustVao);
    glGenBuffers(1, &m.dustVbo);
    glBindVertexArray(m.dustVao);
    glBindBuffer(GL_ARRAY_BUFFER, m.dustVbo);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)buf.size(), buf.data(), GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 40, (void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 40, (void*)12);
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_FALSE, 40, (void*)24);
    glEnableVertexAttribArray(3);
    glVertexAttribPointer(3, 4, GL_UNSIGNED_BYTE, GL_TRUE, 40, (void*)28);
    glEnableVertexAttribArray(4);
    glVertexAttribPointer(4, 2, GL_FLOAT, GL_FALSE, 40, (void*)32);
    glBindVertexArray(0);
    m.dustN = (int)n;
  }

  // slot size(m) explode swirl rise time mode a3 b3 alpha density blend shimmer
  void dust(const float* d) {
    const int slot = (int)d[0];
    auto it = poses_.find(slot);
    if (it == poses_.end()) return;
    const Pose& p = it->second;
    std::lock_guard<std::mutex> g(lock_);
    if (p.mesh < 0 || p.mesh >= (int)meshes_.size()) return;
    DanceMeshData& m = *meshes_[(size_t)p.mesh];
    if (!m.uploaded) return;
    if (!dust_) {
      std::string err;
      dust_ = glsl::link(kDustVert, kDustFrag, err);
      if (!dust_) { std::fprintf(stderr, "stage: the dust: %s\n", err.c_str()); return; }
    }
    buildDust(m);
    const int n = std::min(m.dustN, (int)std::lround(m.dustN * std::clamp(d[14], 0.02f, 1.0f)));
    if (n <= 0) return;
    glUseProgram(dust_);
    auto set = [&](const char* name, float v) { glUniform1f(glGetUniformLocation(dust_, name), v); };
    glUniform4fv(glGetUniformLocation(dust_, "uSkin"), 96, p.skin);
    glUniformMatrix4fv(glGetUniformLocation(dust_, "uModel"), 1, GL_FALSE, p.model);
    glUniformMatrix4fv(glGetUniformLocation(dust_, "uViewProj"), 1, GL_FALSE, viewProj_);
    glUniform3fv(glGetUniformLocation(dust_, "uEye"), 1, eye_);
    set("uSize", d[1]);
    set("uFocal", focal_ * (float)h_ / refH_);
    set("uExplode", d[2]);
    set("uSwirl", d[3]);
    set("uRise", d[4]);
    set("uTime", d[5]);
    set("uShimmer", d[16]);
    glUniform1i(glGetUniformLocation(dust_, "uMode"), (int)d[6]);
    glUniform3f(glGetUniformLocation(dust_, "uA"), d[7], d[8], d[9]);
    glUniform3f(glGetUniformLocation(dust_, "uB"), d[10], d[11], d[12]);
    set("uAlpha", d[13]);
    glUniform1i(glGetUniformLocation(dust_, "uTextured"), m.tex ? 1 : 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, m.tex);
    glUniform1i(glGetUniformLocation(dust_, "uSkinTex"), 0);
    (void)d[15];  // always added: premultiplied light, coverage alongside
    glEnable(GL_BLEND);
    glBlendEquation(GL_FUNC_ADD);
    glBlendFunc(GL_ONE, GL_ONE);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glBindVertexArray(m.dustVao);
    glDrawArrays(GL_POINTS, 0, n);
  }

  // mode cell ink3 paper3 tint glyphs pop popX popY time, and the treatment's knobs
  // weight spacing height gain size (0 is 1) (dance_fx.frag)
  // [program] the finish's shader (sim/dance_fx, or the birds' sim/flock_fx), its
  // glyphs [atlasTex] (0: the dancers'), its alpha out the coverage where
  // [coverageOut] is 1, [sweep] flock_fx's bar.
  void post(const float* p, glsl::Programs& programs, GLuint fbo, GLuint srcTex, GLuint scratchFbo, const char* program = "sim/dance_fx",
            GLuint atlasTex = 0, float coverageOut = 1, float sweep = 0) {
    const glsl::Program* fx = programs.get(program);
    if (!atlasTex) {
      auto atlas = textures_.find("glyphs");
      if (atlas != textures_.end()) atlasTex = atlas->second;
    }
    if (!fx || !atlasTex) return;
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    glBindFramebuffer(GL_FRAMEBUFFER, scratchFbo);
    glViewport(0, 0, w_, h_);
    glUseProgram(fx->id);
    auto set = [&](const char* n, float v) { if (const GLint at = fx->loc(n); at >= 0) glUniform1f(at, v); };
    if (const GLint at = fx->loc("uResolution"); at >= 0) glUniform2f(at, (float)w_, (float)h_);
    if (const GLint at = fx->loc("wsHeight"); at >= 0) glUniform1f(at, (float)h_);
    set("uMode", p[0]);
    set("uCell", p[1] * h_ / refH_);
    if (const GLint at = fx->loc("uInk"); at >= 0) glUniform3f(at, p[2], p[3], p[4]);
    if (const GLint at = fx->loc("uPaper"); at >= 0) glUniform3f(at, p[5], p[6], p[7]);
    set("uTint", p[8]);
    set("uGlyphs", p[9]);
    set("uPop", p[10]);
    if (const GLint at = fx->loc("uPopAt"); at >= 0) glUniform2f(at, p[11], p[12]);
    set("uTime", p[13]);
    set("uWeight", p[14]);
    set("uSpacing", p[15]);
    set("uHeight", p[16]);
    set("uGain", p[17]);
    set("uSize", p[18]);
    // Its alpha the coverage (the dancers': the glyphs, the dots, the lines are the
    // figure), or whole (the birds', blended by their light).
    set("uCoverageOut", coverageOut);
    set("uSweep", sweep);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, srcTex);
    glUniform1i(fx->loc("uImage"), 0);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, atlasTex);
    glUniform1i(fx->loc("uAtlas"), 1);
    glBindVertexArray(emptyVao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    // back into the picture
    glBindFramebuffer(GL_READ_FRAMEBUFFER, scratchFbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
    glBlitFramebuffer(0, 0, w_, h_, 0, 0, w_, h_, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  }

  // ---------------------------------------------------------------- the fluid
  // Stam's stable fluids at a third of the picture, in floating point: velocity in
  // cells a second, the dye carried by it, the divergence relaxed out by Jacobi
  // rounds, the bodies a mask the fluid cannot enter (rendered from their poses), the
  // hands, feet and heads pushing it as splats. A dye source of the palette's colours
  // wells up in patches, so there is always fluid round them to push.
  struct FTarget {
    GLuint tex = 0, fbo = 0;
    int w = 0, h = 0;
    void make(int width, int height, GLenum fmt) {
      if (tex && w == width && h == height) return;
      if (fbo) glDeleteFramebuffers(1, &fbo);
      if (tex) glDeleteTextures(1, &tex);
      w = width; h = height;
      glGenTextures(1, &tex);
      glBindTexture(GL_TEXTURE_2D, tex);
      glTexStorage2D(GL_TEXTURE_2D, 1, fmt, w, h);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glGenFramebuffers(1, &fbo);
      glBindFramebuffer(GL_FRAMEBUFFER, fbo);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
      glClearColor(0, 0, 0, 0);
      glClear(GL_COLOR_BUFFER_BIT);
    }
    void bind() const { glBindFramebuffer(GL_FRAMEBUFFER, fbo); glViewport(0, 0, w, h); }
    void drop() {
      if (fbo) glDeleteFramebuffers(1, &fbo);
      if (tex) glDeleteTextures(1, &tex);
      tex = fbo = 0; w = h = 0;
    }
  };

  static constexpr const char* kFluidVert = R"(#version 300 es
out vec2 vUv;
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  vUv = p;
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

  // velocity: carried by itself, slowed, pushed by the splats, a slow swirl, stopped
  // inside the bodies
  static constexpr const char* kFluidVel = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uVel, uMask;
uniform vec2 uTexel;
uniform float uDt, uKeep, uTime, uSwirl;
uniform int uSplats;
uniform vec4 uSplat[32];     // x, y (uv), vx, vy (cells a second)
uniform float uRadius[32];   // uv, of the height
uniform float uAspect;
out vec4 fragColor;
void main() {
  vec2 v = texture(uVel, vUv).xy;
  vec2 back = vUv - uDt * v * uTexel;
  vec2 nv = texture(uVel, back).xy * uKeep;
  for (int i = 0; i < 32; i++) {
    if (i >= uSplats) break;
    vec2 d = (vUv - uSplat[i].xy) * vec2(uAspect, 1.0);
    float r = uRadius[i];
    nv += uSplat[i].zw * exp(-dot(d, d) / (r * r)) * 0.35;
  }
  vec2 q = vUv * 3.0 + vec2(uTime * 0.05, -uTime * 0.04);
  nv += vec2(sin(q.y * 2.3 + uTime * 0.3), cos(q.x * 1.9 - uTime * 0.25)) * uSwirl * uDt;
  if (texture(uMask, vUv).r > 0.5) nv = vec2(0.0);
  fragColor = vec4(nv, 0.0, 1.0);
}
)";

  static constexpr const char* kFluidDye = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uVel, uDye, uMask;
uniform vec2 uTexel;
uniform float uDt, uKeep, uTime, uRate, uKick;
uniform vec3 uC0, uC1, uC2;
uniform int uSplats;
uniform vec4 uSplat[32];
uniform float uRadius[32];
uniform float uAspect;
out vec4 fragColor;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
void main() {
  vec2 v = texture(uVel, vUv).xy;
  vec3 d = texture(uDye, vUv - uDt * v * uTexel).rgb * uKeep;
  // the wells: patches of the palette's colours, welling and fading slowly
  vec2 q = vUv * vec2(uAspect, 1.0) * 2.4;
  float n = noise(q + vec2(uTime * 0.07, uTime * 0.05));
  float m = noise(q * 1.7 - vec2(uTime * 0.04, -uTime * 0.06) + 11.0);
  vec3 c = mix(mix(uC0, uC1, smoothstep(0.3, 0.7, n)), uC2, smoothstep(0.55, 0.85, m));
  float well = smoothstep(0.42, 0.78, n) * (0.4 + 0.6 * smoothstep(0.2, 0.9, m));
  d += c * well * uRate * uDt * (1.0 + 2.5 * uKick);
  // a bright wake where a hand passes fast
  for (int i = 0; i < 32; i++) {
    if (i >= uSplats) break;
    vec2 e = (vUv - uSplat[i].xy) * vec2(uAspect, 1.0);
    float r = uRadius[i] * 0.6;
    d += uC2 * exp(-dot(e, e) / (r * r)) * clamp(length(uSplat[i].zw) * 0.004, 0.0, 1.0) * uDt * 3.0;
  }
  // the bodies hold it back
  d *= 1.0 - texture(uMask, vUv).r;
  fragColor = vec4(d, 1.0);
}
)";

  static constexpr const char* kFluidDiv = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uVel, uMask;
uniform vec2 uTexel;
out vec4 fragColor;
vec2 at(vec2 o) { vec2 p = vUv + o * uTexel; return texture(uMask, p).r > 0.5 ? vec2(0.0) : texture(uVel, p).xy; }
void main() {
  float div = 0.5 * ((at(vec2(1, 0)).x - at(vec2(-1, 0)).x) + (at(vec2(0, 1)).y - at(vec2(0, -1)).y));
  fragColor = vec4(div, 0.0, 0.0, 1.0);
}
)";

  static constexpr const char* kFluidJacobi = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uPres, uDiv, uMask;
uniform vec2 uTexel;
out vec4 fragColor;
void main() {
  float c = texture(uPres, vUv).r;
  float p = 0.0;
  for (int k = 0; k < 4; k++) {
    vec2 o = k == 0 ? vec2(1, 0) : k == 1 ? vec2(-1, 0) : k == 2 ? vec2(0, 1) : vec2(0, -1);
    vec2 q = vUv + o * uTexel;
    p += texture(uMask, q).r > 0.5 ? c : texture(uPres, q).r;
  }
  fragColor = vec4((p - texture(uDiv, vUv).r) * 0.25, 0.0, 0.0, 1.0);
}
)";

  static constexpr const char* kFluidProject = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uVel, uPres, uMask;
uniform vec2 uTexel;
out vec4 fragColor;
void main() {
  float l = texture(uPres, vUv - vec2(uTexel.x, 0.0)).r, r = texture(uPres, vUv + vec2(uTexel.x, 0.0)).r;
  float b = texture(uPres, vUv - vec2(0.0, uTexel.y)).r, t = texture(uPres, vUv + vec2(0.0, uTexel.y)).r;
  vec2 v = texture(uVel, vUv).xy - 0.5 * vec2(r - l, t - b);
  if (texture(uMask, vUv).r > 0.5) v = vec2(0.0);
  fragColor = vec4(v, 0.0, 1.0);
}
)";

  // onto the picture: the dye as light, shaded by its own slope so it reads as smoke
  static constexpr const char* kFluidShow = R"(#version 300 es
precision highp float;
in vec2 vUv;
uniform sampler2D uDye;
uniform vec2 uTexel;
out vec4 fragColor;
void main() {
  vec3 d = texture(uDye, vUv).rgb;
  float l = dot(d, vec3(0.333));
  float gx = dot(texture(uDye, vUv + vec2(uTexel.x, 0.0)).rgb - texture(uDye, vUv - vec2(uTexel.x, 0.0)).rgb, vec3(0.333));
  float gy = dot(texture(uDye, vUv + vec2(0.0, uTexel.y)).rgb - texture(uDye, vUv - vec2(0.0, uTexel.y)).rgb, vec3(0.333));
  float shade = clamp(0.8 + 2.5 * (gy - gx), 0.4, 1.6);
  // rolled off well under white: smoke, not paint (and dark enough for MilkDrop to
  // show through it under the contrast)
  vec3 col = (1.0 - exp(-d * 1.2)) * 0.62 * shade;
  fragColor = vec4(col, 1.0);
}
)";

  bool fluidSetUp() {
    if (fVel_) return true;
    std::string err;
    fVel_ = glsl::link(kFluidVert, kFluidVel, err);
    fDye_ = fVel_ ? glsl::link(kFluidVert, kFluidDye, err) : 0;
    fDiv_ = fDye_ ? glsl::link(kFluidVert, kFluidDiv, err) : 0;
    fJac_ = fDiv_ ? glsl::link(kFluidVert, kFluidJacobi, err) : 0;
    fProj_ = fJac_ ? glsl::link(kFluidVert, kFluidProject, err) : 0;
    fShow_ = fProj_ ? glsl::link(kFluidVert, kFluidShow, err) : 0;
    if (!fShow_) {
      std::fprintf(stderr, "stage: the fluid's shaders: %s\n", err.c_str());
      fVel_ = 0;
      return false;
    }
    return true;
  }

  static void tex(GLuint prog, const char* name, int unit, GLuint t) {
    glActiveTexture(GL_TEXTURE0 + unit);
    glBindTexture(GL_TEXTURE_2D, t);
    glUniform1i(glGetUniformLocation(prog, name), unit);
  }

  // nSplats nSlots kick strength c0 c1 c2 | splats (x y vx vy r, reference pixels) | slots
  void fluid(const float* c, GLuint fbo) {
    if (!fluidSetUp()) return;
    const int nSplats = std::min(32, (int)c[0]), nAll = (int)c[0], nSlots = (int)c[1];
    const float kick = c[2], strength = c[3];
    const float* cols = c + 4;
    const float* sp = c + 13;
    const float* slots = c + 13 + (size_t)nAll * 5;
    const int fw = std::max(32, w_ / 3), fh = std::max(32, h_ / 3);
    const bool fresh = fVelA_.w != fw || fVelA_.h != fh;
    for (FTarget* t : {&fVelA_, &fVelB_, &fDyeA_, &fDyeB_, &fPresA_, &fPresB_, &fDivT_}) t->make(fw, fh, GL_RGBA16F);
    fMask_.make(fw, fh, GL_RGBA8);
    (void)fresh;
    const auto now = std::chrono::steady_clock::now();
    float dt = fLast_.time_since_epoch().count() == 0 ? 1.0f / 60 : std::chrono::duration<float>(now - fLast_).count();
    fLast_ = now;
    dt = std::clamp(dt, 1.0f / 240, 1.0f / 30);
    fTime_ += dt;
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_CULL_FACE);

    // the mask: every body, flat, at the fluid's size
    fMask_.bind();
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    {
      const float white[4] = {1, 1, 1, 1};
      for (int k = 0; k < nSlots; k++) {
        auto it = poses_.find((int)slots[k]);
        if (it == poses_.end()) continue;
        const Pose& p = it->second;
        std::lock_guard<std::mutex> g(lock_);
        if (p.mesh < 0 || p.mesh >= (int)meshes_.size() || !meshes_[(size_t)p.mesh]->uploaded) continue;
        const DanceMeshData& m = *meshes_[(size_t)p.mesh];
        bindPose(p, m, 0, 0, nullptr, 0, false);
        glUniform1i(glGetUniformLocation(body_, "uShade"), -1);
        glUniform4fv(glGetUniformLocation(body_, "uColour"), 1, white);
        glDrawElements(GL_TRIANGLES, m.indices, GL_UNSIGNED_SHORT, nullptr);
      }
    }
    glBindVertexArray(emptyVao_);

    // the splats, in the fluid's units: uv (from the bottom) and cells a second
    float splat[32 * 4], radius[32];
    for (int k = 0; k < nSplats; k++) {
      const float* q = sp + (size_t)k * 5;
      splat[k * 4] = q[0] / refW_;
      splat[k * 4 + 1] = 1 - q[1] / refH_;
      splat[k * 4 + 2] = q[2] * fw / refW_ * strength;
      splat[k * 4 + 3] = -q[3] * fh / refH_ * strength;
      radius[k] = std::max(0.01f, q[4] / refH_);
    }
    const float aspect = (float)fw / fh;
    const float texel[2] = {1.0f / fw, 1.0f / fh};
    auto common = [&](GLuint prog) {
      glUseProgram(prog);
      glUniform2fv(glGetUniformLocation(prog, "uTexel"), 1, texel);
      glUniform1f(glGetUniformLocation(prog, "uDt"), dt);
      glUniform1f(glGetUniformLocation(prog, "uTime"), fTime_);
      glUniform1f(glGetUniformLocation(prog, "uAspect"), aspect);
      glUniform1i(glGetUniformLocation(prog, "uSplats"), nSplats);
      if (nSplats > 0) {
        glUniform4fv(glGetUniformLocation(prog, "uSplat"), nSplats, splat);
        glUniform1fv(glGetUniformLocation(prog, "uRadius"), nSplats, radius);
      }
    };
    // velocity
    fVelB_.bind();
    common(fVel_);
    glUniform1f(glGetUniformLocation(fVel_, "uKeep"), std::pow(0.55f, dt));
    glUniform1f(glGetUniformLocation(fVel_, "uSwirl"), 6.0f * strength * (1 + 2 * kick));
    tex(fVel_, "uVel", 0, fVelA_.tex);
    tex(fVel_, "uMask", 1, fMask_.tex);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    std::swap(fVelA_, fVelB_);
    // divergence, pressure, projection
    fDivT_.bind();
    glUseProgram(fDiv_);
    glUniform2fv(glGetUniformLocation(fDiv_, "uTexel"), 1, texel);
    tex(fDiv_, "uVel", 0, fVelA_.tex);
    tex(fDiv_, "uMask", 1, fMask_.tex);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glUseProgram(fJac_);
    glUniform2fv(glGetUniformLocation(fJac_, "uTexel"), 1, texel);
    for (int k = 0; k < 24; k++) {
      fPresB_.bind();
      tex(fJac_, "uPres", 0, fPresA_.tex);
      tex(fJac_, "uDiv", 1, fDivT_.tex);
      tex(fJac_, "uMask", 2, fMask_.tex);
      glDrawArrays(GL_TRIANGLES, 0, 3);
      std::swap(fPresA_, fPresB_);
    }
    fVelB_.bind();
    glUseProgram(fProj_);
    glUniform2fv(glGetUniformLocation(fProj_, "uTexel"), 1, texel);
    tex(fProj_, "uVel", 0, fVelA_.tex);
    tex(fProj_, "uPres", 1, fPresA_.tex);
    tex(fProj_, "uMask", 2, fMask_.tex);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    std::swap(fVelA_, fVelB_);
    // dye
    fDyeB_.bind();
    common(fDye_);
    glUniform1f(glGetUniformLocation(fDye_, "uKeep"), std::pow(0.72f, dt));
    glUniform1f(glGetUniformLocation(fDye_, "uRate"), 0.55f);
    glUniform1f(glGetUniformLocation(fDye_, "uKick"), kick);
    glUniform3fv(glGetUniformLocation(fDye_, "uC0"), 1, cols);
    glUniform3fv(glGetUniformLocation(fDye_, "uC1"), 1, cols + 3);
    glUniform3fv(glGetUniformLocation(fDye_, "uC2"), 1, cols + 6);
    tex(fDye_, "uVel", 0, fVelA_.tex);
    tex(fDye_, "uDye", 1, fDyeA_.tex);
    tex(fDye_, "uMask", 2, fMask_.tex);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    std::swap(fDyeA_, fDyeB_);
    // onto the picture
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glViewport(0, 0, w_, h_);
    glUseProgram(fShow_);
    glUniform2fv(glGetUniformLocation(fShow_, "uTexel"), 1, texel);
    tex(fShow_, "uDye", 0, fDyeA_.tex);
    glDrawArrays(GL_TRIANGLES, 0, 3);
  }

  FTarget fVelA_, fVelB_, fDyeA_, fDyeB_, fPresA_, fPresB_, fDivT_, fMask_;
  GLuint fVel_ = 0, fDye_ = 0, fDiv_ = 0, fJac_ = 0, fProj_ = 0, fShow_ = 0;
  std::chrono::steady_clock::time_point fLast_{};
  float fTime_ = 0;

  static float len(const float* v) { return std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); }
  static void norm(float* v) { const float l = len(v); if (l > 1e-9f) { v[0] /= l; v[1] /= l; v[2] /= l; } }

  std::mutex lock_;
  std::vector<std::unique_ptr<DanceMeshData>> meshes_;
  std::map<std::string, PendingTex> pendingTex_;
  std::map<std::string, GLuint> textures_;
  std::vector<float> commands_;
  std::map<int, Pose> poses_;
  GLuint dust_ = 0;
  float focal_ = 1000;
  GLuint body_ = 0, flat_ = 0, dot_ = 0, flatVao_ = 0, flatVbo_ = 0, dotVao_ = 0, dotVbo_ = 0, emptyVao_ = 0;
  GLuint mesh_ = 0, meshVao_ = 0, meshVbo_ = 0, meshIbo_ = 0;
  std::vector<GLuint> meshIdx_;
  float viewProj_[16] = {}, eye_[3] = {}, right_[3] = {}, up_[3] = {}, fwd_[3] = {};
  float refW_ = 1920, refH_ = 1080;
  int w_ = 0, h_ = 0;
  bool firstDraw_ = true, plain_ = false;
};

}  // namespace ws
