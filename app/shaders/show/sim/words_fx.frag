#version 460 core
#include <flutter/runtime_effect.glsl>

// The words' frame (ui/show/show_words.dart): the line being sung, set once into a
// picture, drawn here every frame — on the native stage (stage.cpp, "@words", the
// floats in the order below through ws_words) and on the Flutter one alike.
//
// The picture encodes its words: in every letter's pixel the red is the word's index
// (of sixteen), the green how far along the word the pixel is, the alpha the
// coverage. With one age a word (seconds since the voice reached it; under nought for
// one not yet sung) the shader lights, fades in or types each word:
//   mode 0  karaoke  the whole line shown, the unsung words at uDimK, the sung lit
//   mode 1  appear   a word comes as it is sung, over uFadeIn seconds
//   mode 2  typed    glyph by glyph through the word being sung (uOn, uK)
// Two pictures: A the line on, B the one before, going (fading, drifting up).
//
// Under every letter a soft shadow, a step down and right, so the type reads on any
// ground. The output's alpha is the coverage (the blend, under.frag, takes it as
// such): a letter in its ink, the shadow black, nothing between — the ground alone.
// The colour is straight for the native blend's mix (uPremul 0), premultiplied for a
// Flutter picture and for the native stage drawing the layer whole (uPremul 1).
// A snare may slip rows (uGlitch); a drop's kick may pull the reds and blues apart
// (uSplit); a word flares as it comes (uFlash).

uniform vec2 uResolution;
uniform float uTime;
uniform float uKick;
uniform float uSnare;
uniform float uLow;
uniform float uBeat;
uniform float uShadow;     // the shadow's reach, pixels
uniform float uShadowK;    // how dark it is, 0..1
uniform float uSplit;      // the chromatic split, pixels
uniform float uGlitch;     // 0..1
uniform vec3 uInk;
uniform vec3 uAccent;
uniform float uAccentK;    // the word being sung in the accent, 0..1
uniform float uDimK;       // an unsung word's share, karaoke
uniform float uFadeIn;     // seconds a word takes to come
uniform float uFlash;      // how much a word flares as it comes
uniform float uCur;        // which picture holds the line on: 0 uT0, 1 uT1
uniform vec4 uRectA;       // where the line's picture sits on the stage, 0..1
uniform float uFadeA;
uniform vec2 uScaleA;      // about its middle
uniform float uModeA;
uniform float uOnA;        // the word being sung
uniform float uKA;         // how far through it
uniform vec4 uAgeA0;       // the words' ages: 0..3, 4..7, 8..11, 12..15
uniform vec4 uAgeA1;
uniform vec4 uAgeA2;
uniform vec4 uAgeA3;
uniform vec4 uRectB;       // the line before, going
uniform float uFadeB;
uniform vec2 uScaleB;
uniform float uRiseB;      // lifted, 0..1 of the height
uniform float uModeB;
uniform float uOnB;
uniform float uKB;
uniform vec4 uAgeB0;
uniform vec4 uAgeB1;
uniform vec4 uAgeB2;
uniform vec4 uAgeB3;
uniform float uPremul;     // 1: the colour premultiplied by the alpha (what a Flutter picture
                           // holds); 0: straight, for the native blend's own mix
uniform sampler2D uT0;
uniform sampler2D uT1;

out vec4 fragColor;

const float WORDS = 16.0;

float hash(float x) { return fract(sin(x * 12.9898) * 43758.5453); }

float part(vec4 v, int j) { return j == 0 ? v.x : (j == 1 ? v.y : (j == 2 ? v.z : v.w)); }

float ageOf(int i, bool a) {
  int q = i / 4;
  int j = i - q * 4;
  vec4 v = a ? (q == 0 ? uAgeA0 : (q == 1 ? uAgeA1 : (q == 2 ? uAgeA2 : uAgeA3)))
             : (q == 0 ? uAgeB0 : (q == 1 ? uAgeB1 : (q == 2 ? uAgeB2 : uAgeB3)));
  return part(v, j);
}

// The stage's uv as a picture's: the picture sat in rect, scaled about its middle,
// lifted by rise.
vec2 toPic(vec2 uv, vec4 rect, vec2 scale, float rise) {
  vec2 c = 0.5 * (rect.xy + rect.zw);
  vec2 q = c + (uv - c) / scale;
  q.y += rise;
  return (q - rect.xy) / max(rect.zw - rect.xy, vec2(1e-4));
}

// A pixel of a line's picture, as shown now: (coverage, lit 0..1, the word's age,
// 1 where it is the word being sung).
vec4 shown(vec2 r, bool a) {
  if (r.x < 0.0 || r.x > 1.0 || r.y < 0.0 || r.y > 1.0) return vec4(0.0);
  bool first = (uCur < 0.5) == a;
  vec4 g = first ? texture(uT0, r) : texture(uT1, r);
  if (g.a <= 0.004) return vec4(0.0);
  float idx = g.r / g.a;
  float xf = g.g / g.a;
  int wi = int(floor(idx * WORDS));
  float age = ageOf(wi, a);
  float mode = a ? uModeA : uModeB;
  float on = a ? uOnA : uOnB;
  float k = a ? uKA : uKB;
  float isOn = abs(float(wi) - on) < 0.5 ? 1.0 : 0.0;
  float sung = age >= 0.0 ? 1.0 : 0.0;
  float come = age >= 0.0 ? smoothstep(0.0, max(uFadeIn, 0.001), age) : 0.0;
  float show;
  float lit;
  if (mode < 0.5) {
    show = mix(uDimK, 1.0, come);
    lit = come;
  } else if (mode < 1.5) {
    show = come;
    lit = 1.0;
  } else {
    show = sung * (isOn > 0.5 ? step(xf, k) : 1.0);
    lit = 1.0;
  }
  return vec4(g.a * show, lit, age, isOn);
}

// The shadow under a line: its coverage as shown, reached out and set a step down and
// right, soft. Nothing far from the picture.
float shadow(vec2 uv, vec4 rect, vec2 scale, float rise, bool a) {
  vec2 off = vec2(0.35, 0.8) * uShadow / uResolution;
  vec2 r0 = uShadow / uResolution;
  vec2 c = 0.5 * (rect.xy + rect.zw);
  vec2 ext = 0.5 * (rect.zw - rect.xy) * scale + off + r0 * 1.7 + vec2(0.0, abs(rise));
  if (abs(uv.x - c.x) > ext.x || abs(uv.y - c.y) > ext.y) return 0.0;
  vec2 o = uv - off;
  float s = shown(toPic(o, rect, scale, rise), a).x;
  for (int i = 0; i < 8; i++) {
    float an = float(i) * 0.7853982 + 0.3927;
    vec2 d = vec2(cos(an), sin(an));
    s = max(s, shown(toPic(o + d * r0 * 1.7, rect, scale, rise), a).x * 0.7);
  }
  return s;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec2 p = uv;
  // The glitch: a few bands of rows pushed sideways, which and how far by the moment's
  // hash, so it is never the same slip twice.
  if (uGlitch > 0.001) {
    float band = floor(uv.y * 26.0);
    float seed = floor(uTime * 23.0);
    float on = step(0.7, hash(band * 7.13 + seed));
    p.x += on * (hash(band * 3.7 + seed * 1.3) - 0.5) * 0.18 * uGlitch;
  }
  vec4 A = shown(toPic(p, uRectA, uScaleA, 0.0), true);
  vec4 B = shown(toPic(p, uRectB, uScaleB, uRiseB), false);
  float covA = A.x * uFadeA;
  float covB = B.x * uFadeB;
  // A's colour: the ink, the word being sung in the accent, a flare as a word comes.
  vec3 colA = mix(uInk, uAccent, uAccentK * A.w);
  colA *= 1.0 + uFlash * exp(-max(A.z, 0.0) * 7.0);
  vec3 colB = uInk * 0.92;
  float cov = covA + covB * (1.0 - covA);
  vec3 col = cov > 1e-4 ? (colA * covA + colB * covB * (1.0 - covA)) / cov : vec3(0.0);
  // The split: a drop's kick pulls the reds and the blues apart.
  vec3 chan = vec3(cov);
  if (uSplit > 0.01) {
    vec2 s = vec2(uSplit / uResolution.x, 0.0);
    float r = shown(toPic(p + s, uRectA, uScaleA, 0.0), true).x * uFadeA;
    float b = shown(toPic(p - s, uRectA, uScaleA, 0.0), true).x * uFadeA;
    chan = vec3(max(r, covB), cov, max(b, covB));
    cov = max(cov, max(r, b));
  }
  float sh = 0.0;
  if (uFadeA > 0.001) sh = shadow(p, uRectA, uScaleA, 0.0, true) * uFadeA;
  if (uFadeB > 0.001) sh = max(sh, shadow(p, uRectB, uScaleB, uRiseB, false) * uFadeB);
  sh *= uShadowK;
  float alpha = max(cov, sh);
  vec3 rgb = uPremul > 0.5 ? col * chan : (alpha > 1e-4 ? col * chan / alpha : vec3(0.0));
  fragColor = vec4(clamp(rgb, 0.0, 4.0), alpha);
}
