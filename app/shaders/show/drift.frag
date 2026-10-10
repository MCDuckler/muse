#version 460 core
#include <flutter/runtime_effect.glsl>

// Drift: for a breakdown, an intro, the quiet. An aurora — ribbons of light
// folding slowly across a dark sky with stars in it — breathing with the bar; no
// flash on the beat; the voice warms the ribbons.

uniform vec2 uResolution;
uniform float uTime;
uniform float uBeat;
uniform float uBar;
uniform float uPhrase;
uniform float uEnergy;
uniform float uIntensity;
uniform float uKick;
uniform float uLow;
uniform float uMid;
uniform float uHigh;
uniform float uAir;
uniform float uOnset;
uniform float uHue;
uniform float uHue2;
uniform float uDropNear;
uniform float uBuild;
uniform float uHit;
uniform float uVocal;
uniform float uM1;
uniform float uM2;
uniform float uM3;
uniform float uM4;
// The dynamics (state/show/show_dynamics.dart): the hits, which snap to 1 and fall
// in a fifth of a second; the grid's own ramps; the exposure; the bands against
// the record's own loud.
uniform float uHitKick;
uniform float uHitSnare;
uniform float uHitTop;
uniform float uBeatDecay;
uniform float uBarDecay;
uniform float uBarSaw;
uniform float uPhraseSaw;
uniform float uDownbeat;
uniform float uExposure;
uniform float uBandLow;
uniform float uBandMid;
uniform float uBandHigh;
uniform float uBarIndex;   // the bar, counted from the record's first downbeat

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash(i), b = hash(i + vec2(1, 0)), c = hash(i + vec2(0, 1)), d = hash(i + vec2(1, 1));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 5; i++) {
    v += a * noise(p);
    p = p * 2.1 + vec2(3.1, 1.7);
    a *= 0.5;
  }
  return v;
}

vec3 hsl(float h, float s, float l) {
  vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
  vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0);
  vec3 rgb = mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
  return l + (rgb - 0.5) * (1.0 - abs(2.0 * l - 1.0)) * 1.0 - (0.5 - l) * 0.0;
}

// One ribbon: a band of light along a folded line, soft-edged.
float ribbon(vec2 p, float y0, float t, float width, float fold) {
  float y = y0 + fold * (fbm(vec2(p.x * 0.9 + t, 3.0 * y0)) - 0.5)
      + 0.08 * sin(p.x * 2.5 + t * 1.7);
  float d = abs(p.y - y);
  float glow = exp(-d * d / (width * width));
  // Curtains: the ribbon is made of vertical threads of varying brightness.
  float threads = 0.45 + 0.55 * fbm(vec2(p.x * 9.0 + t * 0.6, y0 * 10.0 + p.y * 1.5));
  return glow * threads;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  float aspect = uResolution.x / uResolution.y;
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
  float t = uTime * 0.035;
  float breath = 0.9 + 0.1 * sin(uBar * 6.2831);

  // The sky: near black, a little bluer at the top.
  vec3 col = vec3(0.004, 0.005, 0.012) * (1.0 - uv.y * 0.5);

  // Stars: sparse, twinkling slowly, brighter where the air is.
  vec2 sp = p * 90.0;
  vec2 cell = floor(sp);
  float star = hash(cell);
  if (star > 0.985) {
    vec2 centre = cell + 0.5 + 0.5 * (vec2(hash(cell + 7.0), hash(cell + 13.0)) - 0.5);
    float d = length(sp - centre);
    float twinkle = 0.6 + 0.4 * sin(uTime * (1.0 + 2.0 * hash(cell + 3.0)) + hash(cell) * 20.0);
    col += vec3(0.8, 0.85, 1.0) * exp(-d * d * 22.0) * twinkle * (0.5 + 0.5 * uAir) * 0.9;
  }

  // Three ribbons in the palette, the brightest lowest.
  vec3 c1 = hsl(uHue, 0.75, 0.5);
  vec3 c2 = hsl(uHue2, 0.7, 0.55);
  vec3 c3 = hsl(uHue + 0.06, 0.6, 0.7);
  float r1 = ribbon(p, 0.12, t, 0.10, 0.35);
  float r2 = ribbon(p, -0.02, t * 1.3 + 4.0, 0.07, 0.30);
  float r3 = ribbon(p, -0.18, t * 0.8 + 9.0, 0.05, 0.25);
  col += c1 * r1 * 0.35 * breath;
  col += c2 * r2 * 0.42 * breath;
  col += c3 * r3 * 0.22 * (0.7 + 0.3 * uMid);

  // The voice warms the whole sky a little, from below.
  col += hsl(0.08, 0.6, 0.6) * uVocal * 0.08 * (1.0 - uv.y);

  // A build creeps in as a tightening ring of light.
  if (uBuild > 0.0) {
    float ring = exp(-pow((length(p) - (0.75 - 0.6 * uBuild)) * 18.0, 2.0)) * uBuild;
    col += c2 * ring * 0.5;
  }

  col *= 0.55 + 0.45 * uIntensity;
  fragColor = vec4(col, 1.0);
}
