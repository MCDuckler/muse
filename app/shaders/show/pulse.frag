#version 460 core
#include <flutter/runtime_effect.glsl>

// The common block (shaders/show/common.glsl), as every scene declares it.
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
uniform float uM1;      // the genome: a salt
uniform float uM2;
uniform float uM3;
uniform float uM4;
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
uniform float uBarIndex;

// Pulse: a quiet, dark, structured field for under a scene — the one that is not
// MilkDrop. Nothing bright, nothing busy: a ground that moves with the record's
// bands and leaves the scene the room. Four variants by uM1 (0..3):
//   0 grid     a perspective floor and ceiling of thin lines, breathing with the low
//              end, the horizon's glow with the kick;
//   1 rays     soft rays from a point below the middle, turning with the bar, lit by
//              the mids;
//   2 smoke    slow curls of value noise in two of the palette's hues, the highs
//              brightening the thin parts;
//   3 stars    a slow starfield drifting in, the kick a faint flash across it.

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
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = p * 2.03 + 17.1;
    a *= 0.5;
  }
  return v;
}

vec3 hue(float h) {
  vec3 k = vec3(0.0, 2.0, 4.0);
  return 0.5 + 0.5 * cos(6.2831853 * h + k);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  float aspect = uResolution.x / uResolution.y;
  vec2 c = (uv - 0.5) * vec2(aspect, 1.0);
  vec3 p1 = hue(uHue) * 0.9 + 0.1, p2 = hue(uHue2) * 0.9 + 0.1;
  int kind = int(uM1 + 0.5);
  vec3 col = vec3(0.0);
  float kick = uHitKick;
  if (kind == 0) {
    // the grid: lines on a floor and a ceiling seen from the middle
    float y = abs(c.y) + 0.02;
    float z = 0.18 / y;
    float x = c.x * z;
    float speed = uTime * (0.6 + 0.8 * uBandLow);
    float lx = smoothstep(0.985, 1.0, abs(fract(x * 1.5) - 0.5) * 2.0);
    float lz = smoothstep(0.985, 1.0, abs(fract(z * 0.8 - speed) - 0.5) * 2.0);
    float fade = exp(-y * 4.5);
    float line = max(lx, lz) * fade;
    vec3 tint = mix(p1, p2, clamp(z * 0.08, 0.0, 1.0));
    col = tint * line * (0.35 + 0.4 * uBandLow);
    // the horizon's glow
    col += p2 * exp(-abs(c.y) * 30.0) * (0.12 + 0.25 * kick + 0.1 * uBeatDecay);
  } else if (kind == 1) {
    // the rays, from below the middle, turning with the bar
    vec2 o = c - vec2(0.0, -0.35);
    float a = atan(o.y, o.x) + uBarSaw * 0.6;
    float r = length(o);
    float ray = pow(0.5 + 0.5 * sin(a * 9.0), 6.0) + 0.5 * pow(0.5 + 0.5 * sin(a * 23.0 + uTime * 0.3), 10.0);
    float fall = exp(-r * 1.8);
    col = mix(p1, p2, 0.5 + 0.5 * sin(a * 2.0)) * ray * fall * (0.18 + 0.3 * uBandMid + 0.2 * kick);
  } else if (kind == 2) {
    // the smoke: two curls of noise in two hues, drifting
    vec2 q = c * 1.6 + vec2(uTime * 0.03, -uTime * 0.02);
    float n1 = fbm(q + fbm(q * 0.7 + uTime * 0.01) * 0.8);
    float n2 = fbm(q * 1.3 - vec2(uTime * 0.02, 0.0) + 5.0);
    vec3 a = p1 * smoothstep(0.35, 0.85, n1);
    vec3 b = p2 * smoothstep(0.4, 0.9, n2);
    col = (a + b) * (0.16 + 0.12 * uBandLow);
    col += (a + b) * smoothstep(0.6, 0.95, n1) * 0.3 * uBandHigh;
  } else {
    // the stars: cells of the picture, one faint star each, drifting in
    float zoom = 1.0 + 0.04 * uBeatDecay;
    vec2 q = c * zoom;
    col = vec3(0.0);
    for (int layer = 0; layer < 3; layer++) {
      float s = 6.0 + float(layer) * 7.0;
      vec2 g = q * s + vec2(uTime * (0.06 + 0.05 * float(layer)), 0.0);
      vec2 cell = floor(g);
      vec2 f = fract(g) - 0.5;
      float h = hash(cell + float(layer) * 13.0);
      vec2 at = (vec2(hash(cell + 1.3), hash(cell + 7.9)) - 0.5) * 0.8;
      float d = length(f - at);
      float star = exp(-d * d * (80.0 + 60.0 * float(layer))) * step(0.72, h);
      float tw = 0.6 + 0.4 * sin(uTime * (1.0 + h * 3.0) + h * 20.0);
      col += mix(p2, vec3(1.0), 0.6) * star * tw * (0.25 + 0.15 * uBandHigh) / (1.0 + float(layer));
    }
    col += p1 * 0.04 * kick;
  }
  // a quiet ground: never bright
  col = col / (1.0 + col * 0.6) * 0.8;
  fragColor = vec4(col, 1.0);
}
