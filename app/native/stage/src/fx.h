// The stage's own passes that carry pictures from frame to frame, which a scene's
// one shader cannot:
//
//   Slime  the veins (scene `@slime`): Jones's physarum on the GPU. Hundreds of
//          thousands of agents, their places and headings a float texture, each
//          sensing a trail map ahead of it at three points and turning towards its
//          own kind's scent (and away from the others'), laying trail as it goes —
//          drawn as points, added up — while the trail spreads and fades. Up to
//          three kinds, a colour each. Dart says the rules a frame (show_veins.dart:
//          the floats in kSlime's order, through ws_words).
//   Slit   the slit-scan (ws_treat mode 9): the figure's last frames kept in a ring
//          of pictures, and each part of the picture taken from a frame further
//          back than the next — the rows, the columns, out from the middle, a wave —
//          so a thing that moves is drawn out along its own time.
//   Mosh   the datamosh (ws_mosh): a change of scene with its key frame lost. The
//          last picture of the scene being left is kept, and the new scene's motion
//          — found block by block between its frames, as a codec's P-frames find
//          it, read as a smooth field and carried on frame to frame (a P-frame
//          played again and again), a swirl where the new scene is still, a push
//          on the kick — drags the old picture's light into streaks; the new
//          scene's change since the last frame (the residual) is let in slowly, so
//          its shapes surface in the old one's light; and the new picture breaks
//          through in soft patches, where it moves first, until it is all there.
//          Never squares: a block's motion is read between its neighbours'.
//          Held (ws_mosh_hold): the same, on and on over whatever is drawn — the
//          picture never quite let through but where the hands say (how healed, a
//          key frame whole), and taken whole again when it goes to mud (flat, black
//          or white: looked at a few times a second).
#pragma once
#include <GLES3/gl3.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "glsl.h"
#include "target.h"

namespace ws {

static const char* kFxVert = R"(#version 300 es
out vec2 vUv;
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  vUv = p;
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

inline void fxQuad() { glDrawArrays(GL_TRIANGLES, 0, 3); }

inline void fxTex(GLuint program, const char* name, int unit, GLuint tex, GLenum target = GL_TEXTURE_2D) {
  glActiveTexture(GL_TEXTURE0 + unit);
  glBindTexture(target, tex);
  glUniform1i(glGetUniformLocation(program, name), unit);
}

inline void fxSet(GLuint p, const char* n, float v) { glUniform1f(glGetUniformLocation(p, n), v); }
inline void fxSet2(GLuint p, const char* n, float a, float b) { glUniform2f(glGetUniformLocation(p, n), a, b); }

inline GLuint fxLink(const char* vert, const char* frag, const char* what) {
  std::string err;
  const GLuint p = glsl::link(vert, frag, err);
  if (!p) std::fprintf(stderr, "stage: %s: %s\n", what, err.c_str());
  return p;
}

inline void fxWrap(GLuint tex, GLenum mode, GLenum filter = GL_LINEAR) {
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, mode);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, mode);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
}

inline void fxCopy(const Target& from, const Target& to) {
  glBindFramebuffer(GL_READ_FRAMEBUFFER, from.fbo);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, to.fbo);
  glBlitFramebuffer(0, 0, from.w, from.h, 0, 0, to.w, to.h, GL_COLOR_BUFFER_BIT, from.w == to.w && from.h == to.h ? GL_NEAREST : GL_LINEAR);
  glBindFramebuffer(GL_FRAMEBUFFER, to.fbo);
}

static const char* kHash = R"(
float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}
)";

// ------------------------------------------------------------------ the slime
// Its floats (ws_words), in order — show_veins.dart's VeinsParams writes them.
enum SlimeAt {
  kSlSide = 0,      // agents a side (side² of them): 128..1024
  kSlSpeed,         // trail pixels a frame (at 60 a second, the map 540 high)
  kSlAngle,         // the sensors' angle off ahead, radians
  kSlDist,          // how far ahead they sense (trail pixels, the map 540 high)
  kSlTurn,          // how far they turn a frame, radians
  kSlJitter,        // a random turn every frame, radians
  kSlDeposit,       // trail laid a frame
  kSlDecay,         // the trail kept a frame (at 60 a second)
  kSlDiffuse,       // how much of it spreads a frame, 0..1
  kSlSpecies,       // kinds, 1..3
  kSlRepel,         // how much a kind shuns the others' trail
  kSlSeed,          // a count: changed, the agents are born again ...
  kSlShape,         // ... in this shape (0 anywhere 1 a disc heading in 2 a burst out
                    // from the middle 3 a ring 4 clusters 5 stripes)
  kSlShare,         // ... this share of them
  kSlPullX,         // a point the agents steer to (or from, strength < 0), 0..1
  kSlPullY,
  kSlPull,
  kSlPullR,         // its reach, a share of the height
  kSlLook,          // 0 glow 1 ink 2 contours 3 relief
  kSlExposure,      // how far over an even spread the trail is read (0.3: the veins
                    // bright, the gaps dark)
  kSlTime,
  kSlKick,          // the kick's decay, 0..1: the light
  kSlScatter,       // a scatter of every heading, 0..1 (the snare)
  kSlColour0,       // three rgb
  kSlFood = kSlColour0 + 9,  // how many food spots, then x y amount radius each (≤ 8)
  kSlFoodAt,
  kSlScale = kSlFoodAt + 32, // the trail map's share of the working size
  kSlCount
};

static const char* kSlimeStep = R"(#version 300 es
precision highp float;
precision highp sampler2D;
uniform sampler2D uAgents;
uniform sampler2D uTrail;
uniform vec2 uSize;
uniform float uSpeed, uAngle, uDist, uTurn, uJitter, uRepel, uFrame, uScatter;
uniform vec4 uPull;   // x y (trail pixels), strength, reach (pixels)
out vec4 o;
HASH
float smell(vec2 p, int s) {
  vec3 t = texture(uTrail, p / uSize).rgb;
  float own = s == 0 ? t.r : (s == 1 ? t.g : t.b);
  return own - uRepel * (t.r + t.g + t.b - own);
}
void main() {
  ivec2 c = ivec2(gl_FragCoord.xy);
  vec4 a = texelFetch(uAgents, c, 0);
  vec2 p = a.xy;
  float ang = a.z;
  int s = int(a.w + 0.5);
  float r = hash12(vec2(c) + fract(uFrame * 0.6180339) * 917.0);
  float r2 = hash12(vec2(c).yx * 1.37 + fract(uFrame * 0.0137) * 571.0);
  float f = smell(p + vec2(cos(ang), sin(ang)) * uDist, s);
  float l = smell(p + vec2(cos(ang + uAngle), sin(ang + uAngle)) * uDist, s);
  float rt = smell(p + vec2(cos(ang - uAngle), sin(ang - uAngle)) * uDist, s);
  if (f > l && f > rt) {
  } else if (f < l && f < rt) {
    ang += (r - 0.5) * 2.0 * uTurn;
  } else if (l > rt) {
    ang += uTurn * (0.6 + 0.4 * r);
  } else if (rt > l) {
    ang -= uTurn * (0.6 + 0.4 * r);
  }
  ang += (r2 - 0.5) * (uJitter + uScatter * 2.5);
  if (uPull.z != 0.0) {
    vec2 d = uPull.xy - p;
    d -= uSize * floor(d / uSize + 0.5);
    float to = atan(d.y, d.x) + (uPull.z < 0.0 ? 3.14159265 : 0.0);
    float off = mod(to - ang + 3.14159265, 6.2831853) - 3.14159265;
    ang += off * min(abs(uPull.z), 1.0) * 0.2 / (1.0 + length(d) / max(uPull.w, 1.0));
  }
  p += vec2(cos(ang), sin(ang)) * uSpeed;
  p = mod(p, uSize);
  o = vec4(p, mod(ang, 6.2831853), a.w);
}
)";

static const char* kSlimeSeed = R"(#version 300 es
precision highp float;
precision highp sampler2D;
uniform sampler2D uAgents;
uniform vec2 uSize;
uniform float uShape, uShare, uSeed, uSpecies, uFresh;
out vec4 o;
HASH
void main() {
  vec2 c = gl_FragCoord.xy;
  vec4 a = texelFetch(uAgents, ivec2(c), 0);
  float pick = hash12(c * 0.917 + uSeed * 13.1);
  if (uFresh < 0.5 && pick > uShare) { o = a; return; }
  float u = hash12(c * 1.71 + uSeed * 3.1), v = hash12(c * 2.33 + uSeed * 1.37), w = hash12(c * 0.53 + uSeed * 7.9);
  vec2 mid = uSize * 0.5;
  float big = uSize.y * 0.44;
  float th = v * 6.2831853;
  vec2 dir = vec2(cos(th), sin(th));
  vec2 p;
  float ang;
  int shape = int(uShape + 0.5);
  if (shape == 1) {         // a disc, heading in
    p = mid + dir * big * sqrt(u); ang = th + 3.14159265;
  } else if (shape == 2) {  // a burst out of the middle
    p = mid + dir * big * 0.06 * sqrt(u); ang = th;
  } else if (shape == 3) {  // a ring, heading round it
    p = mid + dir * big * (0.82 + 0.18 * u); ang = th + 1.5707963 * (w < 0.5 ? 1.0 : -1.0);
  } else if (shape == 4) {  // clusters, each heading out of itself
    float k = floor(w * 6.0);
    vec2 at = vec2(hash12(vec2(k, uSeed)), hash12(vec2(uSeed, k * 1.7))) * 0.7 + 0.15;
    p = at * uSize + dir * big * 0.12 * sqrt(u); ang = th;
  } else if (shape == 5) {  // stripes, up and down them
    p = vec2((floor(u * 7.0) + 0.5) / 7.0 * uSize.x + (w - 0.5) * 3.0, v * uSize.y); ang = w < 0.5 ? 1.5707963 : -1.5707963;
  } else {                  // anywhere
    p = vec2(u, v) * uSize; ang = w * 6.2831853;
  }
  float kind = min(floor(hash12(c * 3.17 + 0.5) * uSpecies), uSpecies - 1.0);
  o = vec4(mod(p, uSize), mod(ang, 6.2831853), kind);
}
)";

static const char* kSlimeDotVert = R"(#version 300 es
precision highp float;
precision highp sampler2D;
uniform sampler2D uAgents;
uniform int uSide;
uniform vec2 uSize;
uniform float uDeposit;
out vec3 vC;
void main() {
  vec4 a = texelFetch(uAgents, ivec2(gl_VertexID % uSide, gl_VertexID / uSide), 0);
  gl_Position = vec4((floor(a.xy) + 0.5) / uSize * 2.0 - 1.0, 0.0, 1.0);
  gl_PointSize = 1.0;
  int s = int(a.w + 0.5);
  vC = (s == 0 ? vec3(1, 0, 0) : (s == 1 ? vec3(0, 1, 0) : vec3(0, 0, 1))) * uDeposit;
}
)";

static const char* kSlimeDotFrag = R"(#version 300 es
precision highp float;
in vec3 vC;
out vec4 o;
void main() { o = vec4(vC, 0.0); }
)";

static const char* kSlimeSpread = R"(#version 300 es
precision highp float;
precision highp sampler2D;
uniform sampler2D uTrail;
uniform vec2 uSize;
uniform float uDecay, uDiffuse;
uniform int uFood;
uniform vec4 uFoodAt[8];  // x y (pixels) amount radius (pixels)
out vec4 o;
void main() {
  vec2 px = gl_FragCoord.xy;
  vec2 t = 1.0 / uSize;
  vec2 uv = px * t;
  vec3 c = texture(uTrail, uv).rgb;
  vec3 b = vec3(0);
  for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++) b += texture(uTrail, uv + vec2(x, y) * t).rgb;
  vec3 v = mix(c, b / 9.0, uDiffuse) * uDecay;
  for (int i = 0; i < 8; i++) {
    if (i >= uFood) break;
    vec2 d = px - uFoodAt[i].xy;
    d -= uSize * floor(d / uSize + 0.5);
    float r = max(uFoodAt[i].w, 1.0);
    v += vec3(uFoodAt[i].z * exp(-dot(d, d) / (r * r)));
  }
  o = vec4(min(v, vec3(200.0)), 1.0);
}
)";

static const char* kSlimeLook = R"(#version 300 es
precision highp float;
precision highp sampler2D;
uniform sampler2D uTrail;
uniform vec2 uResolution;
uniform vec2 uSize;
uniform vec3 uC0, uC1, uC2;
uniform float uLook, uExposure, uKick, uTime;
out vec4 o;
vec3 at(vec2 uv) { return texture(uTrail, uv).rgb * uExposure; }
vec3 tint(vec3 t) {
  float s = t.r + t.g + t.b + 1e-5;
  return (t.r * uC0 + t.g * uC1 + t.b * uC2) / s;
}
void main() {
  vec2 uv = gl_FragCoord.xy / uResolution;
  vec3 t = at(uv) * (1.0 + 0.35 * uKick);
  float sum = t.r + t.g + t.b;
  float k = 1.0 - exp(-sum);
  vec3 hue = tint(t);
  int look = int(uLook + 0.5);
  vec3 col;
  if (look == 1) {
    // Ink: the veins' spines alone — where the trail is higher than round it — as
    // hairlines of cream with the kind's colour in them, on black.
    vec2 e = 3.0 / uSize;
    float round4 = dot(at(uv + vec2(e.x, 0)) + at(uv - vec2(e.x, 0)) + at(uv + vec2(0, e.y)) + at(uv - vec2(0, e.y)), vec3(0.25));
    float ridge = smoothstep(0.0, 0.25, (sum - round4) / (sum + 0.05));
    col = mix(hue, vec3(1.0, 0.96, 0.88), 0.6) * ridge * smoothstep(0.15, 0.6, k) * 1.2;
  } else if (look == 2) {
    // Contours: the density as a map, a thin line at each step of it, drifting
    // outwards; nothing between the lines.
    float q = k * 9.0 - uTime * 0.3;
    float w = fwidth(q) + 1e-4;
    float band = 1.0 - smoothstep(w * 0.4, w * 1.4, abs(fract(q) - 0.5));
    col = (hue * 0.75 + 0.25) * band * (0.2 + 0.9 * k * k);
  } else if (look == 3) {
    // Relief: the trail as a height, lit as polished metal from the top left.
    vec2 e = 1.0 / uSize;
    float h0 = 1.0 - exp(-sum);
    float hx = (1.0 - exp(-dot(at(uv + vec2(e.x, 0)), vec3(1)))) - (1.0 - exp(-dot(at(uv - vec2(e.x, 0)), vec3(1))));
    float hy = (1.0 - exp(-dot(at(uv + vec2(0, e.y)), vec3(1)))) - (1.0 - exp(-dot(at(uv - vec2(0, e.y)), vec3(1))));
    vec3 n = normalize(vec3(-hx * 14.0, -hy * 14.0, 1.0));
    vec3 l = normalize(vec3(-0.55, 0.65, 0.5));
    float diff = max(dot(n, l), 0.0);
    float spec = pow(max(dot(reflect(-l, n), vec3(0, 0, 1)), 0.0), 40.0);
    float rim = pow(1.0 - n.z, 2.0);
    col = (hue * 0.5 * diff + hue * rim * 0.9 + vec3(spec) * 1.2) * smoothstep(0.08, 0.35, h0);
  } else {
    // Glow: the kinds' colours as light, the thick veins burning towards white.
    col = (1.0 - exp(-(t.r * uC0 + t.g * uC1 + t.b * uC2) * 1.3)) + vec3(1.0) * pow(max(k - 0.75, 0.0) * 3.0, 2.0) * 0.6;
  }
  o = vec4(col, 1.0);
}
)";

struct Slime {
  GLuint step_ = 0, seed_ = 0, dot_ = 0, spread_ = 0, look_ = 0, vao_ = 0;
  Target agentsA, agentsB, trailA, trailB;
  int side = 0, tw = 0, th = 0;
  float seedWas = -1;
  int64_t frame = 0, lastDrawn = -1000;
  bool failed = false;

  bool setUp() {
    if (step_) return true;
    if (failed) return false;
    auto with = [](const char* src) {
      std::string s = src;
      const size_t at = s.find("HASH");
      if (at != std::string::npos) s.replace(at, 4, kHash);
      return s;
    };
    const std::string stepSrc = with(kSlimeStep), seedSrc = with(kSlimeSeed);
    step_ = fxLink(kFxVert, stepSrc.c_str(), "the slime's step");
    seed_ = step_ ? fxLink(kFxVert, seedSrc.c_str(), "the slime's seed") : 0;
    dot_ = seed_ ? fxLink(kSlimeDotVert, kSlimeDotFrag, "the slime's trail") : 0;
    spread_ = dot_ ? fxLink(kFxVert, kSlimeSpread, "the slime's spread") : 0;
    look_ = spread_ ? fxLink(kFxVert, kSlimeLook, "the slime's look") : 0;
    if (!look_) { failed = true; lost(); return false; }
    glGenVertexArrays(1, &vao_);
    return true;
  }

  // Into `out` (w×h), its frame from `v` (SlimeAt); `dt` the seconds since the last.
  // `agentFormat` RGBA32F where the GPU can draw into one; `trailFormat` the stage's
  // working format.
  void draw(Target& out, const std::vector<float>& v, double dt, GLenum agentFormat, GLenum trailFormat, GLuint quadVao, int64_t frameNo) {
    out.bind();
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    if ((int)v.size() < kSlCount || !setUp()) return;
    glDisable(GL_BLEND);
    const int wantSide = std::clamp((int)v[kSlSide], 64, 1024);
    const float scale = std::clamp(v[kSlScale], 0.2f, 1.0f);
    const int wantW = std::clamp((int)std::lround(out.w * scale), 64, 1600), wantH = std::clamp((int)std::lround(out.h * scale), 36, 900);
    // Back after a while away: a network of another record's, started again.
    bool fresh = frameNo - lastDrawn > 120;
    lastDrawn = frameNo;
    if (wantSide != side) {
      side = wantSide;
      agentsA.make(side, side, agentFormat);
      agentsB.make(side, side, agentFormat);
      fxWrap(agentsA.tex, GL_CLAMP_TO_EDGE, GL_NEAREST);
      fxWrap(agentsB.tex, GL_CLAMP_TO_EDGE, GL_NEAREST);
      fresh = true;
    }
    if (wantW != tw || wantH != th) {
      tw = wantW; th = wantH;
      trailA.make(tw, th, trailFormat);
      trailB.make(tw, th, trailFormat);
      for (Target* t : {&trailA, &trailB}) {
        fxWrap(t->tex, GL_REPEAT);
        t->bind();
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
      }
      fresh = true;
    }
    const float px = th / 540.0f;  // the rules are said for a map 540 high
    const float steps = (float)std::clamp(dt * 60.0, 0.25, 2.5);
    frame++;
    glBindVertexArray(quadVao);

    // born again: all of them (a new map, a new count), or a share in a shape
    if (fresh || v[kSlSeed] != seedWas) {
      seedWas = v[kSlSeed];
      agentsB.bind();
      glUseProgram(seed_);
      fxTex(seed_, "uAgents", 0, agentsA.tex);
      fxSet2(seed_, "uSize", (float)tw, (float)th);
      fxSet(seed_, "uShape", fresh ? 0.0f : v[kSlShape]);
      fxSet(seed_, "uShare", fresh ? 1.0f : std::clamp(v[kSlShare], 0.0f, 1.0f));
      fxSet(seed_, "uSeed", std::fmod(v[kSlSeed] * 0.618f + (float)(frame % 997) * 0.013f, 97.0f));
      fxSet(seed_, "uSpecies", std::clamp(std::round(v[kSlSpecies]), 1.0f, 3.0f));
      fxSet(seed_, "uFresh", fresh ? 1.0f : 0.0f);
      fxQuad();
      std::swap(agentsA, agentsB);
    }

    // 1. the agents sense, turn and move
    agentsB.bind();
    glUseProgram(step_);
    fxTex(step_, "uAgents", 0, agentsA.tex);
    fxTex(step_, "uTrail", 1, trailA.tex);
    fxSet2(step_, "uSize", (float)tw, (float)th);
    fxSet(step_, "uSpeed", v[kSlSpeed] * px * steps);
    fxSet(step_, "uAngle", v[kSlAngle]);
    fxSet(step_, "uDist", std::max(1.0f, v[kSlDist] * px));
    fxSet(step_, "uTurn", v[kSlTurn] * std::min(steps, 1.5f));
    fxSet(step_, "uJitter", v[kSlJitter]);
    fxSet(step_, "uRepel", v[kSlRepel]);
    fxSet(step_, "uFrame", (float)(frame % 100000));
    fxSet(step_, "uScatter", v[kSlScatter]);
    glUniform4f(glGetUniformLocation(step_, "uPull"), v[kSlPullX] * tw, v[kSlPullY] * th, v[kSlPull], v[kSlPullR] * th);
    fxQuad();
    std::swap(agentsA, agentsB);

    // 2. their trail laid, added up
    trailA.bind();
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE);
    glUseProgram(dot_);
    fxTex(dot_, "uAgents", 0, agentsA.tex);
    glUniform1i(glGetUniformLocation(dot_, "uSide"), side);
    fxSet2(dot_, "uSize", (float)tw, (float)th);
    fxSet(dot_, "uDeposit", v[kSlDeposit] * steps);
    glBindVertexArray(vao_);
    glDrawArrays(GL_POINTS, 0, side * side);
    glDisable(GL_BLEND);
    glBindVertexArray(quadVao);

    // 3. it spreads and fades, and the food is laid
    trailB.bind();
    glUseProgram(spread_);
    fxTex(spread_, "uTrail", 0, trailA.tex);
    fxSet2(spread_, "uSize", (float)tw, (float)th);
    fxSet(spread_, "uDecay", std::pow(std::clamp(v[kSlDecay], 0.0f, 0.999f), steps));
    fxSet(spread_, "uDiffuse", std::clamp(v[kSlDiffuse], 0.0f, 1.0f));
    const int food = std::clamp((int)v[kSlFood], 0, 8);
    glUniform1i(glGetUniformLocation(spread_, "uFood"), food);
    float spots[32] = {};
    for (int i = 0; i < food; i++) {
      spots[i * 4] = v[kSlFoodAt + i * 4] * tw;
      spots[i * 4 + 1] = v[kSlFoodAt + i * 4 + 1] * th;
      spots[i * 4 + 2] = v[kSlFoodAt + i * 4 + 2] * steps;
      spots[i * 4 + 3] = v[kSlFoodAt + i * 4 + 3] * th;
    }
    glUniform4fv(glGetUniformLocation(spread_, "uFoodAt"), 8, spots);
    fxQuad();
    std::swap(trailA, trailB);

    // 4. as a picture
    out.bind();
    glUseProgram(look_);
    fxTex(look_, "uTrail", 0, trailA.tex);
    fxSet2(look_, "uResolution", (float)out.w, (float)out.h);
    fxSet2(look_, "uSize", (float)tw, (float)th);
    const float* c = &v[kSlColour0];
    glUniform3f(glGetUniformLocation(look_, "uC0"), c[0], c[1], c[2]);
    glUniform3f(glGetUniformLocation(look_, "uC1"), c[3], c[4], c[5]);
    glUniform3f(glGetUniformLocation(look_, "uC2"), c[6], c[7], c[8]);
    fxSet(look_, "uLook", v[kSlLook]);
    // Exposed against the trail an even spread of the agents would keep (laid a frame,
    // over what fades a frame): the knob is how far over that the veins are read.
    const float laid = std::max(v[kSlDeposit] * (float)side * side / ((float)tw * th), 1e-5f);
    fxSet(look_, "uExposure", v[kSlExposure] * (1 - std::clamp(v[kSlDecay], 0.0f, 0.999f)) / laid);
    fxSet(look_, "uKick", v[kSlKick]);
    fxSet(look_, "uTime", v[kSlTime]);
    fxQuad();
  }

  void lost() {
    for (GLuint* p : {&step_, &seed_, &dot_, &spread_, &look_}) {
      if (*p) glDeleteProgram(*p);
      *p = 0;
    }
    if (vao_) glDeleteVertexArrays(1, &vao_);
    vao_ = 0;
    for (Target* t : {&agentsA, &agentsB, &trailA, &trailB}) t->drop();
    side = tw = th = 0;
    seedWas = -1;
  }
};

// ------------------------------------------------------------------ the slit-scan
static const char* kSlitFrag = R"(#version 300 es
precision highp float;
precision highp sampler2D;
precision highp sampler2DArray;
uniform sampler2D uNow;
uniform sampler2DArray uHist;
uniform vec2 uResolution;
uniform float uHead, uLayers, uFilled, uSpan, uShape, uTime, uKick, uFlip;
out vec4 o;
float delay(vec2 uv) {
  int s = int(uShape + 0.5);
  float a = uResolution.x / uResolution.y;
  float d;
  if (s == 1) d = uv.x;                                                    // the columns
  else if (s == 2) d = length((uv - 0.5) * vec2(a, 1.0)) * 1.25;           // out from the middle
  else if (s == 3) d = 0.5 + 0.5 * sin(uv.y * 7.0 + uv.x * 2.0 - uTime * 1.1); // a wave
  else if (s == 4) d = floor(uv.y * 9.0) / 8.0;                            // bands
  else if (s == 5) d = abs(uv.x - 0.5) * 2.0;                              // out from the middle line
  else d = 1.0 - uv.y;                                                     // the rows, top the oldest
  d = uFlip > 0.5 ? 1.0 - d : d;
  return clamp(d, 0.0, 1.0);
}
vec4 layer(vec2 uv, float back) { return texture(uHist, vec3(uv, mod(uHead - back + uLayers * 4.0, uLayers))); }
void main() {
  vec2 uv = gl_FragCoord.xy / uResolution;
  float span = min(uSpan * (1.0 + 0.25 * uKick), uFilled - 1.0);
  float d = delay(uv) * max(span, 0.0);
  float i = floor(d), f = d - i;
  vec4 c;
  if (i < 0.5) c = mix(texture(uNow, uv), layer(uv, 1.0), f);
  else c = mix(layer(uv, i), layer(uv, i + 1.0), f);
  o = c;
}
)";

struct Slit {
  static constexpr int kLayers = 40;
  GLuint prog_ = 0, hist_ = 0, fbo_ = 0;
  int hw = 0, hh = 0, head = -1, filled = 0;
  int64_t lastFrame = -10, frames = 0;
  bool failed = false;

  bool setUp() {
    if (prog_) return true;
    if (failed) return false;
    prog_ = fxLink(kFxVert, kSlitFrag, "the slit-scan");
    if (!prog_) { failed = true; return false; }
    glGenFramebuffers(1, &fbo_);
    return true;
  }

  // The figure in `t` drawn out along its time, via `via` and back. q: ws_treat's
  // floats — mode 9, q[1] the shape, q[8] flipped, q[10] the kick, q[13] the time,
  // q[14] how far back (the weight knob: 1 the whole ring), q[15] frames a layer
  // (the spacing knob, 0 is 2).
  void pass(const float* q, Target& t, Target& via, int64_t frameNo, GLuint quadVao) {
    if (!setUp()) return;
    const int w = std::max(16, std::min(t.w / 2, 960)), h = std::max(9, std::min(t.h / 2, 540));
    if (w != hw || h != hh || !hist_) {
      if (hist_) glDeleteTextures(1, &hist_);
      glGenTextures(1, &hist_);
      glBindTexture(GL_TEXTURE_2D_ARRAY, hist_);
      glTexStorage3D(GL_TEXTURE_2D_ARRAY, 1, GL_RGBA8, w, h, kLayers);
      glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      hw = w; hh = h; head = -1; filled = 0;
    }
    // A gap (the treatment was off a while): what is in the ring is another picture.
    if (frameNo - lastFrame > 3) { head = -1; filled = 0; frames = 0; }
    lastFrame = frameNo;
    const int every = std::clamp(q[15] > 0 ? (int)std::lround(q[15] * 2) : 2, 1, 4);
    if (frames++ % every == 0) {
      head = (head + 1) % kLayers;
      filled = std::min(filled + 1, kLayers);
      glBindFramebuffer(GL_READ_FRAMEBUFFER, t.fbo);
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo_);
      glFramebufferTextureLayer(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, hist_, 0, head);
      glBlitFramebuffer(0, 0, t.w, t.h, 0, 0, hw, hh, GL_COLOR_BUFFER_BIT, GL_LINEAR);
    }
    via.make(t.w, t.h, t.internal);
    via.bind();
    glDisable(GL_BLEND);
    glBindVertexArray(quadVao);
    glUseProgram(prog_);
    fxTex(prog_, "uNow", 0, t.tex);
    fxTex(prog_, "uHist", 1, hist_, GL_TEXTURE_2D_ARRAY);
    fxSet2(prog_, "uResolution", (float)t.w, (float)t.h);
    fxSet(prog_, "uHead", (float)head);
    fxSet(prog_, "uLayers", (float)kLayers);
    fxSet(prog_, "uFilled", (float)filled);
    fxSet(prog_, "uSpan", (float)(kLayers - 1) * std::clamp(q[14] > 0 ? q[14] : 1.0f, 0.1f, 1.0f));
    fxSet(prog_, "uShape", q[1]);
    fxSet(prog_, "uFlip", q[8]);
    fxSet(prog_, "uKick", q[10]);
    fxSet(prog_, "uTime", q[13]);
    fxQuad();
    fxCopy(via, t);
  }

  void lost() {
    if (prog_) glDeleteProgram(prog_);
    if (hist_) glDeleteTextures(1, &hist_);
    if (fbo_) glDeleteFramebuffers(1, &fbo_);
    prog_ = hist_ = fbo_ = 0;
    hw = hh = 0; head = -1; filled = 0;
  }
};

// ------------------------------------------------------------------ the datamosh
// The new picture's brightness at a quarter of its size, four taps a texel.
static const char* kMoshLuma = R"(#version 300 es
precision highp float;
uniform sampler2D uSrc;
uniform vec2 uTexel;  // the source's
in vec2 vUv;
out vec4 o;
float l(vec2 o2) { return dot(texture(uSrc, vUv + o2 * uTexel).rgb, vec3(0.299, 0.587, 0.114)); }
void main() { o = vec4((l(vec2(-1, -1)) + l(vec2(1, -1)) + l(vec2(-1, 1)) + l(vec2(1, 1))) * 0.25, 0, 0, 1); }
)";

// The motion, a block of 16 pixels (4 of the quarter picture) at a time: where in the
// last frame this block's picture was, searched ±4 quarter pixels, a little against
// moving at all (a flat block would wander).
static const char* kMoshMatch = R"(#version 300 es
precision highp float;
precision highp sampler2D;
uniform sampler2D uNow;
uniform sampler2D uPrev;
uniform vec2 uSize;  // the quarter pictures, pixels
out vec4 o;
float sad(ivec2 b, ivec2 d) {
  float s = 0.0;
  for (int y = 0; y < 4; y++)
    for (int x = 0; x < 4; x++) {
      ivec2 p = b + ivec2(x, y);
      ivec2 q = clamp(p + d, ivec2(0), ivec2(uSize) - 1);
      s += abs(texelFetch(uNow, p, 0).r - texelFetch(uPrev, q, 0).r);
    }
  return s;
}
void main() {
  ivec2 b = ivec2(gl_FragCoord.xy) * 4;
  float best = sad(b, ivec2(0)) - 0.02;
  ivec2 at = ivec2(0);
  for (int y = -4; y <= 4; y++)
    for (int x = -4; x <= 4; x++) {
      if (x == 0 && y == 0) continue;
      float s = sad(b, ivec2(x, y)) + 0.004 * float(abs(x) + abs(y));
      if (s < best) { best = s; at = ivec2(x, y); }
    }
  o = vec4(vec2(at), best / 16.0, 1.0);
}
)";

// The motion as a smooth field, a quarter of the picture: the blocks' motion read
// between them (no squares), a little of the picture's own flow on top (Horn and
// Schunck, one step: the change in light against its slope), and the last frame's
// field carried on — a P-frame played again and again, the old picture streaming the
// way the new one moved. A kick throws it further.
static const char* kMoshField = R"(#version 300 es
precision highp float;
precision highp sampler2D;
uniform sampler2D uMv;     // the blocks' motion, quarter pixels (a texel a block of 4)
uniform sampler2D uField;  // the field so far
uniform sampler2D uNow;    // the new scene's brightness, a quarter
uniform sampler2D uPrev;   // and the last frame's
uniform vec2 uSize;        // the quarter picture, pixels
uniform float uKick, uFresh, uTime, uSeed, uSwirl;
in vec2 vUv;
out vec4 o;
HASH
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}
// A slow swirl (the curl of a drifting noise): what a still scene moves the old
// picture by, so it melts all the same.
vec2 swirl(vec2 uv) {
  vec2 p = uv * vec2(2.6, 1.6) + vec2(uSeed, uTime * 0.15);
  float e = 0.05;
  float n = noise(p) + 0.5 * noise(p * 2.1 + 7.0);
  float nx = noise(p + vec2(e, 0)) + 0.5 * noise((p + vec2(e, 0)) * 2.1 + 7.0);
  float ny = noise(p + vec2(0, e)) + 0.5 * noise((p + vec2(0, e)) * 2.1 + 7.0);
  return vec2(ny - n, -(nx - n)) / e;
}
vec2 mvAt(vec2 q) {
  // The blocks' motion read between their middles.
  vec2 b = q / 4.0 - 0.5;
  ivec2 i = ivec2(floor(b));
  vec2 f = fract(b);
  ivec2 hi = textureSize(uMv, 0) - 1;
  vec2 a = texelFetch(uMv, clamp(i, ivec2(0), hi), 0).xy;
  vec2 c = texelFetch(uMv, clamp(i + ivec2(1, 0), ivec2(0), hi), 0).xy;
  vec2 d = texelFetch(uMv, clamp(i + ivec2(0, 1), ivec2(0), hi), 0).xy;
  vec2 e = texelFetch(uMv, clamp(i + ivec2(1, 1), ivec2(0), hi), 0).xy;
  return mix(mix(a, c, f.x), mix(d, e, f.x), f.y);
}
void main() {
  vec2 q = gl_FragCoord.xy;
  vec2 v = (mvAt(q) * 2.0 + mvAt(q + vec2(3.0, 0.0)) + mvAt(q - vec2(3.0, 0.0)) + mvAt(q + vec2(0.0, 3.0)) + mvAt(q - vec2(0.0, 3.0))) / 6.0;
  vec2 t = 1.0 / uSize;
  float it = texture(uNow, vUv).r - texture(uPrev, vUv).r;
  vec2 g = vec2(texture(uNow, vUv + vec2(t.x, 0)).r - texture(uNow, vUv - vec2(t.x, 0)).r,
                texture(uNow, vUv + vec2(0, t.y)).r - texture(uNow, vUv - vec2(0, t.y)).r) * 0.5;
  v += clamp(-it * g / (dot(g, g) + 0.004), vec2(-3.0), vec2(3.0)) * 0.6;
  // Where the new scene hardly moves, the swirl; on a kick a push out from the middle.
  float still = 1.0 - smoothstep(0.3, 2.0, length(v));
  v += swirl(vUv) * uSwirl * still;
  v += (vUv - 0.5) * uKick * 6.0;
  // The field so far, where this motion came from, blurred a touch.
  vec2 back = vUv + v * t;
  vec2 was = (texture(uField, back).xy * 4.0 + texture(uField, back + vec2(t.x, 0)).xy + texture(uField, back - vec2(t.x, 0)).xy
            + texture(uField, back + vec2(0, t.y)).xy + texture(uField, back - vec2(0, t.y)).xy) / 8.0;
  vec2 f = mix(was, v, uFresh);
  f *= 1.0 + uKick * 0.5;
  o = vec4(clamp(f, vec2(-24.0), vec2(24.0)), 0.0, 1.0);
}
)";

// One frame of the mosh: the old picture dragged along the field and smeared down
// it (the streaks a held P-frame leaves) — where it moves, block by block, as a codec
// moves it: the drag stepped to its blocks (some of them halved), a few blocks thrown
// too far (more on the kick), the colour dragged further and coarser than the light
// (a codec keeps less of it). The new picture's own change let in slowly and coarse,
// a block's at a time, so its shapes surface through the old one's light; the new
// picture itself breaking through in patches with block edges, where it moves first,
// a few blocks stuck on the old one till the last. uGlitch: how much of the codec's
// grain, 0 (a smooth melt) to 1.
static const char* kMoshStep = R"(#version 300 es
precision highp float;
precision highp sampler2D;
uniform sampler2D uOld;    // the moshed picture so far
uniform sampler2D uNow;    // the new scene, this frame
uniform sampler2D uPrev;   // the new scene, the last frame
uniform sampler2D uMv;     // the blocks' motion, quarter pixels
uniform sampler2D uField;  // the smooth field, quarter pixels
uniform sampler2D uLuma;   // the new scene's brightness, a quarter
uniform vec2 uResolution;
uniform float uK, uStrength, uKick, uHavePrev, uSeed, uGlitch, uFade;
out vec4 o;
HASH
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}
vec3 toYcc(vec3 c) { return vec3(dot(c, vec3(0.25, 0.5, 0.25)), dot(c, vec3(0.5, 0.0, -0.5)), dot(c, vec3(-0.25, 0.5, -0.25))); }
vec3 toRgb(vec3 y) { return vec3(y.x + y.y - y.z, y.x + y.z, y.x - y.y - y.z); }
void main() {
  vec2 px = gl_FragCoord.xy;
  vec2 uv = px / uResolution;
  vec2 r = 1.0 / uResolution;
  float scale = uResolution.x / float(textureSize(uField, 0).x);  // quarter pixels to pixels
  float bs = 4.0 * scale;                                        // a block, pixels (16)
  vec2 cell = floor(px / bs);
  // Some blocks split in four, as a codec splits the busy ones.
  float split = step(0.6, hash12(cell + uSeed * 0.37));
  vec2 sub = floor(px / (bs * 0.5));
  vec2 blockAt = mix(cell * bs + bs * 0.5, sub * bs * 0.5 + bs * 0.25, split);
  vec2 field = texture(uField, uv).xy * scale * uHavePrev;
  vec2 blockField = texture(uField, blockAt * r).xy * scale * uHavePrev;
  vec2 block = texelFetch(uMv, ivec2(px / bs), 0).xy * scale * uHavePrev;
  // Where it moves the codec's way, block by block; where it is still, the melt.
  float moving = smoothstep(0.3, 2.0, length(blockField));
  float blocky = uGlitch * mix(0.15, 0.85, moving);
  vec2 mv = mix(field, mix(blockField, block, 0.35), blocky);
  // A few blocks thrown too far (a P-frame's vector run wild), more on the kick.
  float wild = step(1.0 - uGlitch * (0.12 + 0.3 * uKick), hash12(cell + floor(uK * 9.0) + uSeed));
  mv *= (1.4 + 0.8 * uStrength) * (1.0 + wild * 2.2);
  // And a slow melt along the new picture's edges, so a still scene still pulls the
  // old one into its shape.
  vec2 lt = 1.0 / vec2(textureSize(uLuma, 0));
  vec2 slope = vec2(texture(uLuma, uv + vec2(lt.x, 0)).r - texture(uLuma, uv - vec2(lt.x, 0)).r,
                    texture(uLuma, uv + vec2(0, lt.y)).r - texture(uLuma, uv - vec2(0, lt.y)).r);
  mv += slope * 14.0 * uStrength * (1.0 - uK);
  // The old picture where this pixel's picture came from, and smeared down the drag
  // (weighted towards where it came from: a streak, not a swelling).
  vec3 a = texture(uOld, uv + mv * r).rgb;
  vec3 b = texture(uOld, uv + mv * 0.5 * r).rgb;
  vec3 c = texture(uOld, uv + mv * 1.6 * r).rgb;
  vec3 d = texture(uOld, uv + mv * 2.4 * r).rgb;
  vec3 old = mix(a * 0.4 + b * 0.3 + c * 0.2 + d * 0.1, max(a, b), 0.2);
  // The colour from further down the drag and from a coarser grid: it bleeds.
  vec2 chromaAt = mix(uv, (floor(px / 4.0) * 4.0 + 2.0) * r, uGlitch) + mv * (1.0 + 0.6 * uGlitch) * r;
  vec3 ycc = toYcc(old);
  ycc.yz = mix(ycc.yz, toYcc(texture(uOld, chromaAt).rgb).yz, 0.5 + 0.4 * uGlitch);
  old = toRgb(ycc) * uFade;
  // The new picture's own change, let in as the time runs — a block's at a time
  // (coarse, stepped), so its shapes surface blocky through the old light.
  vec3 now = texture(uNow, uv).rgb;
  vec3 res = (now - texture(uPrev, uv + mv * r).rgb) * uHavePrev;
  vec2 rb = (floor(px / 8.0) * 8.0 + 4.0) * r;
  vec3 resBlock = (texture(uNow, rb).rgb - texture(uPrev, rb + mv * r).rgb) * uHavePrev;
  resBlock = floor(resBlock * 6.0 + 0.5) / 6.0;
  res = mix(res, resBlock, uGlitch * 0.7);
  vec3 col = old + res * smoothstep(0.08, 0.6, uK) * (0.7 + 0.3 * uStrength);
  // Where the new picture moves, it breaks through first; then in patches — their
  // edges the blocks' — and a few blocks stuck on the old picture till the last.
  vec2 nAt = mix(uv, (cell * bs + bs * 0.5) * r, uGlitch * 0.8);
  float n = noise(nAt * vec2(4.0, 2.4) + uSeed) * 0.65 + noise(nAt * vec2(11.0, 6.5) - uSeed) * 0.35;
  n -= clamp(length(field) * 0.05, 0.0, 0.25);
  float stuck = step(1.0 - 0.07 * uGlitch, hash12(cell * 1.7 + uSeed));
  n += stuck * 0.6;
  float edge = uK * 1.45 - 0.42;
  float soft = mix(0.1, 0.02, uGlitch);
  float reveal = 1.0 - smoothstep(edge - soft, edge + soft, n);
  col = mix(col, now, reveal);
  col = mix(col, now, smoothstep(0.9, 1.0, uK));
  o = vec4(clamp(col, vec3(0.0), vec3(8.0)), 1.0);
}
)";

struct Mosh {
  GLuint luma_ = 0, match_ = 0, field_ = 0, step_ = 0;
  Target a, b, prev, lumaNow, lumaPrev, mv, fieldA, fieldB, look1, look2;
  bool active = false, havePrev = false, failed = false;
  float k = 0, seconds = 1, strength = 1, seed = 0;
  // Held (ws_mosh_hold): on until let go, how healed the hands' (not the clock's);
  // the time since its picture was last looked at for mud, and how many key frames
  // the mud has asked for.
  bool held = false, mudKey = false;
  float sinceLook = 0, sinceStart = 0;
  int mudKeys = 0;
  // How much of the codec's grain: 0 a smooth melt, 1 all blocks.
  float glitch = 0.8f;

  bool setUp() {
    if (step_) return true;
    if (failed) return false;
    std::string stepSrc = kMoshStep;
    stepSrc.replace(stepSrc.find("HASH"), 4, kHash);
    luma_ = fxLink(kFxVert, kMoshLuma, "the mosh's brightness");
    match_ = luma_ ? fxLink(kFxVert, kMoshMatch, "the mosh's motion") : 0;
    std::string fieldSrc = kMoshField;
    fieldSrc.replace(fieldSrc.find("HASH"), 4, kHash);
    field_ = match_ ? fxLink(kFxVert, fieldSrc.c_str(), "the mosh's field") : 0;
    step_ = field_ ? fxLink(kFxVert, stepSrc.c_str(), "the mosh") : 0;
    if (!step_) { failed = true; lost(); return false; }
    return true;
  }

  // The picture being left, kept: the mosh starts from it.
  void begin(const Target& last, int w, int h, GLenum fmt, float secs, float str) {
    // Held, the new scene's motion moves the moshed picture on as it is: that is the
    // change's mosh already.
    if (held) return;
    if (!setUp() || !last.tex) return;
    a.make(w, h, fmt);
    b.make(w, h, fmt);
    // Under a mosh already on, the moshed picture goes on being moshed.
    if (!active) fxCopy(last, a);
    active = true;
    havePrev = false;
    k = 0;
    seconds = std::max(0.2f, secs);
    strength = std::clamp(str, 0.0f, 2.0f);
    seed += 17.13f;
  }

  // One frame: `now` the new scene; the picture to show instead (a or `now` itself).
  const Target* step(const Target& now, double dt, float kick, GLenum fmt, GLuint quadVao) {
    if (!active || !step_ || held) return &now;
    if (a.w != now.w || a.h != now.h) { active = false; return &now; }
    run(now, kick, k, strength, glitch, 0.997f, fmt, quadVao);
    k += (float)(dt / seconds);
    if (k >= 1) active = false;
    return &a;
  }

  // Held: on from the picture `now` is (whole), till let go ([release]).
  void hold(const Target& now, GLenum fmt) {
    if (!setUp() || !now.tex) return;
    a.make(now.w, now.h, fmt);
    b.make(now.w, now.h, fmt);
    fxCopy(now, a);
    active = held = true;
    havePrev = false;
    mudKey = false;
    sinceLook = sinceStart = 0;
    seed += 17.13f;
  }

  void release() {
    if (held) active = false;
    held = false;
  }

  // One held frame: how healed (0 all smear .. 1 the new picture whole), how far it
  // is dragged and how blocky, a key frame (the new picture whole, from which it
  // smears again); the picture looked at for mud now and then.
  const Target* stepHeld(const Target& now, double dt, float kick, float heal, float str, float grain, bool key, GLenum fmt, GLuint quadVao) {
    if (!held || !step_) return &now;
    if (a.w != now.w || a.h != now.h || a.internal != fmt) {
      hold(now, fmt);
      if (!held) return &now;
    }
    const bool whole = key || mudKey;
    mudKey = false;
    sinceStart += (float)dt;
    // Slower to fade than a change's (held a long while, it would go dark).
    run(now, kick, whole ? 1.0f : std::clamp(heal, 0.0f, 0.95f), std::clamp(str, 0.0f, 2.0f), std::clamp(grain, 0.0f, 1.0f), 0.9993f, fmt, quadVao);
    sinceLook += (float)dt;
    if (sinceLook > 0.35f) {
      sinceLook = 0;
      if (muddy(now, fmt)) {
        mudKey = true;
        mudKeys++;
      }
    }
    return &a;
  }

  // Whether the moshed picture has gone to mud: flat (no light and dark left in it),
  // all but black or white, or gone grey or dark where the scene drawn now is not.
  // Both looked at small, a few times a second.
  bool muddy(const Target& now, GLenum fmt) {
    const Look m = look(a, fmt), s = look(now, fmt);
    if (m.sd < 0.045 || m.mean < 0.012 || m.mean > 0.93 || (m.sd < 0.08 && m.chroma < 0.05)) return true;
    if (s.chroma > 0.08 && m.chroma < 0.4 * s.chroma) return true;
    if (s.mean > 0.05 && m.mean < 0.3 * s.mean) return true;
    return false;
  }

  struct Look {
    double mean, sd, chroma;
  };

  Look look(const Target& t, GLenum fmt) {
    look1.make(128, 72, fmt);
    look2.make(32, 18, fmt);
    fxCopy(t, look1);
    fxCopy(look1, look2);
    look2.bind();
    const bool fl = fmt != GL_RGBA8;
    float px[32 * 18 * 4];
    unsigned char bytes[32 * 18 * 4];
    if (fl) {
      glReadPixels(0, 0, 32, 18, GL_RGBA, GL_FLOAT, px);
    } else {
      glReadPixels(0, 0, 32, 18, GL_RGBA, GL_UNSIGNED_BYTE, bytes);
      for (int i = 0; i < 32 * 18 * 4; i++) px[i] = bytes[i] / 255.0f;
    }
    double sum = 0, sq = 0, chroma = 0;
    const int n = 32 * 18;
    for (int i = 0; i < n; i++) {
      const float r = std::clamp(px[i * 4], 0.0f, 1.0f), g = std::clamp(px[i * 4 + 1], 0.0f, 1.0f), bl = std::clamp(px[i * 4 + 2], 0.0f, 1.0f);
      const float y = 0.299f * r + 0.587f * g + 0.114f * bl;
      sum += y;
      sq += y * y;
      chroma += std::max(r, std::max(g, bl)) - std::min(r, std::min(g, bl));
    }
    const double mean = sum / n;
    return {mean, std::sqrt(std::max(0.0, sq / n - mean * mean)), chroma / n};
  }

  // The frame's passes: the motion, the field, the step into `a`.
  void run(const Target& now, float kick, float kNow, float strengthNow, float grain, float fade, GLenum fmt, GLuint quadVao) {
    const int w = now.w, h = now.h;
    const int qw = std::max(4, w / 4), qh = std::max(4, h / 4);
    prev.make(w, h, fmt);
    lumaNow.make(qw, qh, fmt);
    lumaPrev.make(qw, qh, fmt);
    mv.make(std::max(1, qw / 4), std::max(1, qh / 4), fmt);
    fxWrap(mv.tex, GL_CLAMP_TO_EDGE, GL_NEAREST);
    const bool freshField = fieldA.w != qw || fieldA.h != qh || !havePrev;
    fieldA.make(qw, qh, fmt);
    fieldB.make(qw, qh, fmt);
    fxWrap(fieldA.tex, GL_CLAMP_TO_EDGE, GL_LINEAR);
    fxWrap(fieldB.tex, GL_CLAMP_TO_EDGE, GL_LINEAR);
    if (freshField) {
      fieldA.bind();
      glClearColor(0, 0, 0, 1);
      glClear(GL_COLOR_BUFFER_BIT);
    }
    glDisable(GL_BLEND);
    glBindVertexArray(quadVao);

    lumaNow.bind();
    glUseProgram(luma_);
    fxTex(luma_, "uSrc", 0, now.tex);
    fxSet2(luma_, "uTexel", 1.0f / w, 1.0f / h);
    fxQuad();

    if (havePrev) {
      mv.bind();
      glUseProgram(match_);
      fxTex(match_, "uNow", 0, lumaNow.tex);
      fxTex(match_, "uPrev", 1, lumaPrev.tex);
      fxSet2(match_, "uSize", (float)qw, (float)qh);
      fxQuad();

      fieldB.bind();
      glUseProgram(field_);
      fxTex(field_, "uMv", 0, mv.tex);
      fxTex(field_, "uField", 1, fieldA.tex);
      fxTex(field_, "uNow", 2, lumaNow.tex);
      fxTex(field_, "uPrev", 3, lumaPrev.tex);
      fxSet2(field_, "uSize", (float)qw, (float)qh);
      fxSet(field_, "uKick", kick * strengthNow);
      // How much of the field is this frame's: the rest is carried on (held, more of
      // it this frame's, the codec's way, and less of the swirl: on and on, carried
      // motion and swirl melt everything into one soup).
      fxSet(field_, "uFresh", held ? 0.6f : 0.3f);
      fxSet(field_, "uSwirl", held ? 0.2f : 0.9f);
      fxSet(field_, "uTime", held ? sinceStart : k * seconds);
      fxSet(field_, "uSeed", seed);
      fxQuad();
      std::swap(fieldA, fieldB);
    }

    b.bind();
    glUseProgram(step_);
    fxTex(step_, "uOld", 0, a.tex);
    fxTex(step_, "uNow", 1, now.tex);
    fxTex(step_, "uPrev", 2, prev.tex);
    fxTex(step_, "uMv", 3, mv.tex);
    fxTex(step_, "uLuma", 4, lumaNow.tex);
    fxTex(step_, "uField", 5, fieldA.tex);
    fxSet2(step_, "uResolution", (float)w, (float)h);
    fxSet(step_, "uK", kNow);
    fxSet(step_, "uStrength", strengthNow);
    fxSet(step_, "uKick", kick);
    fxSet(step_, "uHavePrev", havePrev ? 1.0f : 0.0f);
    fxSet(step_, "uSeed", seed);
    fxSet(step_, "uGlitch", grain);
    fxSet(step_, "uFade", fade);
    fxQuad();
    std::swap(a, b);

    fxCopy(now, prev);
    std::swap(lumaNow, lumaPrev);
    havePrev = true;
  }

  void lost() {
    for (GLuint* p : {&luma_, &match_, &field_, &step_}) {
      if (*p) glDeleteProgram(*p);
      *p = 0;
    }
    for (Target* t : {&a, &b, &prev, &lumaNow, &lumaPrev, &mv, &fieldA, &fieldB, &look1, &look2}) t->drop();
    active = havePrev = held = false;
  }
};

}  // namespace ws
