#version 460 core
#include <flutter/runtime_effect.glsl>

// Kinetic: geometry, all in. Shapes drawn as distance fields — circles, polygons
// that morph from three sides to eight, stars, rings — set out in six compositions
// that the phrase chooses and morphs between over its first bar:
//
//   ORBIT      a ring of shapes circling with the bar, breathing with the beat, each
//              a different polygon, the ring tilting into an ellipse by the phrase;
//   SPIRAL     a phyllotaxis — shapes at the golden angle, a wave of scale running
//              out from the middle on every kick;
//   LATTICE    a hex field of small shapes, a wave crossing it over the bar, the
//              field folded six ways on alternate bars;
//   NESTED     polygons inside polygons, turning against each other, sides changing
//              with the bar, the whole stack expanding on the kick;
//   MANDALA    a few big shapes folded into eight wedges and twisted, the twist
//              driven by the bass;
//   BURST      shapes flung from the middle on every beat and fading as they go.
//
// Over all of it: the kick pops every shape a step bigger and whitens its core, the
// snare spins the whole picture a quarter turn for an instant and throws its halves
// apart, the top end sparkles the outlines, the downbeat swaps the two colours, a
// build draws everything into the middle until the drop flings it out, a breakdown
// slows every motion to a drift. Edges anti-aliased by pixel, every shape with a soft
// glow — so it reads as light.

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

out vec4 fragColor;

const float TAU = 6.2831853;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

vec3 hsl(float h, float s, float l) {
  vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
  vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0);
  vec3 rgb = mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
  return l + (rgb - 0.5) * (1.0 - abs(2.0 * l - 1.0));
}

mat2 rot(float a) {
  float s = sin(a), c = cos(a);
  return mat2(c, -s, s, c);
}

// ------------------------------------------------------------------ shapes
// A regular polygon of [n] sides, radius [r]. [n] whole: with a fraction of a side
// the segments no longer tile the circle and the field tears along one radius — a
// seam that turns with the shape. Fractional sides morph in [sdPolyMorph].
float sdPolyN(vec2 p, float n, float r) {
  float a = atan(p.y, p.x);
  float seg = TAU / n;
  float d = cos(floor(0.5 + a / seg) * seg - a) * length(p);
  return d - r;
}

// Between [n] and the next whole number of sides, by the fraction: two polygons that
// each tile the circle, blended — no seam.
float sdPoly(vec2 p, float n, float r) {
  float lo = floor(n), f = n - lo;
  if (f < 0.001) return sdPolyN(p, lo, r);
  return mix(sdPolyN(p, lo, r), sdPolyN(p, lo + 1.0, r), f);
}

float sdStar(vec2 p, float r, float n, float inner) {
  float a = atan(p.y, p.x);
  float seg = TAU / n;
  float k = abs(mod(a, seg) - seg * 0.5) / (seg * 0.5);   // 0 at a point, 1 between
  float rr = mix(r, r * inner, k);
  return length(p) - rr;
}

// One shape by [kind] (0..3: circle, polygon, star, ring), morphing with [m].
float sd(vec2 p, float kind, float r, float m) {
  if (kind < 0.5) return length(p) - r;
  if (kind < 1.5) return sdPoly(p, 3.0 + 5.0 * m, r);
  if (kind < 2.5) return sdStar(p, r, 4.0 + floor(m * 4.0), 0.45 + 0.3 * m);
  return abs(length(p) - r) - r * 0.18;
}

// The shape's light: a soft fill, a bright edge, a glow — by distance in pixels.
vec3 light(float d, float px, vec3 ink, float core) {
  float fill = 1.0 - smoothstep(-px, px, d);
  float edge = 1.0 - smoothstep(0.0, 2.5 * px, abs(d));
  float glow = exp(-max(d, 0.0) / (18.0 * px)) * 0.5;
  return ink * (fill * (0.35 + 0.5 * core) + glow) + mix(ink, vec3(1.0), 0.6 + 0.4 * core) * edge;
}

// ------------------------------------------------------------------ compositions
// Each takes the point and the moment and answers the light there.

vec3 orbit(vec2 p, float px, vec3 c1, vec3 c2, float salt, float barN, float kickPop, float calm) {
  float n = 6.0 + floor(hash(vec2(barN, salt)) * 7.0);
  float tilt = 0.55 + 0.45 * sin(uPhraseSaw * TAU);
  float spin = uBarSaw * TAU / 4.0 * calm + uTime * 0.1 * calm;
  vec3 col = vec3(0.0);
  for (float i = 0.0; i < 12.0; i++) {
    if (i >= n) break;
    float a = i / n * TAU + spin;
    float r = 0.33 + 0.05 * uBeatDecay;
    vec2 at = vec2(cos(a) * r, sin(a) * r * tilt);
    float kind = mod(i + floor(hash(vec2(barN, salt + 3.0)) * 4.0), 4.0);
    float size = 0.055 + 0.02 * hash(vec2(i, barN)) + 0.03 * kickPop;
    vec2 q = rot(a + uTime * 0.5) * (p - at);
    float d = sd(q, kind, size, fract(uPhraseSaw + i / n));
    col += light(d, px, mix(c1, c2, i / n), kickPop);
  }
  return col;
}

vec3 spiral(vec2 p, float px, vec3 c1, vec3 c2, float salt, float barN, float kickPop, float calm) {
  float golden = 2.39996323;
  float turn = uBarSaw * 0.5 * calm + uTime * 0.05;
  vec3 col = vec3(0.0);
  float count = 42.0;
  // The kick's wave runs out from the middle: shapes at the wave's radius swell.
  for (float i = 1.0; i <= 42.0; i++) {
    float rr = 0.082 * sqrt(i) * (1.0 - 0.35 * uBuild);
    float a = i * golden + turn;
    vec2 at = vec2(cos(a), sin(a)) * rr;
    float w = exp(-abs(rr - 0.5 * uBeatDecay) * 9.0) * 0.5;
    float size = 0.016 + 0.016 * (1.0 - i / count) + 0.025 * kickPop * w + 0.01 * uBandHigh;
    float kind = floor(hash(vec2(barN, salt + 5.0)) * 3.0);
    float d = sd(rot(a) * (p - at), kind, size, fract(i / 7.0 + uPhraseSaw));
    col += light(d, px, mix(c1, c2, i / count), kickPop * w) * 0.8;
  }
  return col;
}

vec3 lattice(vec2 p, float px, vec3 c1, vec3 c2, float salt, float barN, float kickPop, float calm) {
  // Six-way fold on alternate bars.
  if (mod(barN, 2.0) < 1.0) {
    float a = atan(p.y, p.x), r = length(p);
    float seg = TAU / 6.0;
    a = abs(mod(a, seg) - seg * 0.5);
    p = vec2(cos(a), sin(a)) * r;
  }
  p = rot(uTime * 0.04 * calm) * p;
  float cellsize = 0.11 - 0.03 * uBuild;
  // A hex lattice: two offset square grids, the nearer centre wins.
  vec2 g1 = p / cellsize;
  vec2 c1a = floor(g1) + 0.5;
  vec2 g2 = p / cellsize + vec2(0.5, 0.5);
  vec2 c2a = floor(g2) - 0.5 + 0.5;
  vec2 ca = c1a * cellsize, cb = (c2a - 0.5 + 0.5) * cellsize;
  vec2 centre = length(p - ca) < length(p - cb) ? ca : cb;
  float dist = length(centre);
  // The wave crossing the field over the bar.
  float wave = 0.5 + 0.5 * cos((dist * 6.0 - uBarSaw * 2.0) * TAU * 0.5);
  float size = cellsize * (0.18 + 0.22 * wave + 0.12 * kickPop);
  float kind = floor(hash(vec2(barN, salt + 9.0)) * 4.0);
  float d = sd(rot(uBarSaw * TAU * 0.25 + dist * 3.0) * (p - centre), kind, size, wave);
  return light(d, px, mix(c1, c2, wave), kickPop * wave) * (0.25 + 0.4 * wave);
}

vec3 nested(vec2 p, float px, vec3 c1, vec3 c2, float salt, float barN, float kickPop, float calm) {
  vec3 col = vec3(0.0);
  float sides = 3.0 + floor(hash(vec2(barN, salt + 2.0)) * 5.0);
  float layers = 7.0;
  for (float i = 0.0; i < 7.0; i++) {
    float k = i / layers;
    float r = (0.07 + 0.065 * i) * (1.0 + 0.12 * kickPop) * (1.0 - 0.4 * uBuild * k);
    float a = (mod(i, 2.0) < 1.0 ? 1.0 : -1.0) * (uBarSaw * TAU * 0.25 + uTime * 0.15) * calm + uHitSnare * 0.8;
    float d = abs(sdPoly(rot(a) * p, sides + k * 2.0 * sin(uPhraseSaw * TAU), r)) - 0.003;
    col += light(d, px, mix(c1, c2, k), kickPop) * (0.9 - 0.08 * i);
  }
  return col;
}

vec3 mandala(vec2 p, float px, vec3 c1, vec3 c2, float salt, float barN, float kickPop, float calm) {
  float a = atan(p.y, p.x), r = length(p);
  float seg = TAU / 8.0;
  a = abs(mod(a + uBarSaw * seg * calm, seg) - seg * 0.5);
  // The twist: the bass turns the wedge with the radius.
  a += r * (1.5 + 4.0 * uBandLow) * (0.3 + 0.7 * calm);
  vec2 q = vec2(cos(a), sin(a)) * r;
  vec3 col = vec3(0.0);
  for (float i = 0.0; i < 4.0; i++) {
    vec2 at = vec2(0.12 + 0.11 * i, 0.03 * sin(uTime * 0.7 + i));
    float kind = mod(i + floor(hash(vec2(barN, salt + 7.0)) * 4.0), 4.0);
    float size = 0.05 + 0.015 * i + 0.03 * kickPop;
    float d = sd(rot(uTime * (0.3 + 0.2 * i) + i) * (q - at), kind, size, fract(uPhraseSaw * 2.0 + i * 0.25));
    col += light(d, px, mix(c1, c2, i / 3.0), kickPop);
  }
  return col;
}

vec3 burst(vec2 p, float px, vec3 c1, vec3 c2, float salt, float barN, float kickPop, float calm) {
  vec3 col = vec3(0.0);
  float n = 14.0;
  for (float i = 0.0; i < 14.0; i++) {
    // Each shape is flung on its own beat of the last few, and travels as that beat
    // ages: the beat's age is the bar's time less the beat it left on.
    float beatN = floor(uBarIndex * 4.0 + uBarSaw * 4.0);
    float born = beatN - mod(i, 4.0);
    float age = (uBarSaw * 4.0 - mod(born, 4.0));
    age = age < 0.0 ? age + 4.0 : age;
    age = fract(age / 4.0) * 4.0;
    float a = hash(vec2(i, born + salt)) * TAU;
    float speed = 0.12 + 0.1 * hash(vec2(i + 2.0, born));
    vec2 at = vec2(cos(a), sin(a)) * (age * speed * (0.5 + 0.5 * uEnergy)) * calm;
    float fade = exp(-age * 0.8);
    float kind = mod(i, 4.0);
    float size = (0.035 + 0.025 * hash(vec2(i, born + 1.0))) * (1.0 + 0.6 * kickPop) * (0.4 + 0.6 * fade);
    float d = sd(rot(age * 2.0 + a) * (p - at), kind, size, fract(i / 5.0 + uPhraseSaw));
    col += light(d, px, mix(c1, c2, hash(vec2(i, born + 4.0))), kickPop) * fade;
  }
  return col;
}

vec3 compose(float which, vec2 p, float px, vec3 c1, vec3 c2, float salt, float barN, float kickPop, float calm) {
  if (which < 0.5) return orbit(p, px, c1, c2, salt, barN, kickPop, calm);
  if (which < 1.5) return spiral(p, px, c1, c2, salt, barN, kickPop, calm);
  if (which < 2.5) return lattice(p, px, c1, c2, salt, barN, kickPop, calm);
  if (which < 3.5) return nested(p, px, c1, c2, salt, barN, kickPop, calm);
  if (which < 4.5) return mandala(p, px, c1, c2, salt, barN, kickPop, calm);
  return burst(p, px, c1, c2, salt, barN, kickPop, calm);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 p = (frag - 0.5 * uResolution) / uResolution.y;
  float px = 1.0 / uResolution.y;

  float salt = floor(uM1 * 89.0);
  float barN = uBarIndex;
  float phraseN = floor(uBarIndex / 4.0);
  float comp = floor(hash(vec2(phraseN, 11.0 + salt)) * 6.0);
  float compBefore = floor(hash(vec2(phraseN - 1.0, 11.0 + salt)) * 6.0);
  // A breakdown slows every motion to a drift; a drop runs.
  float calm = 0.35 + 0.65 * uEnergy;
  float kickPop = uHitKick + 0.5 * uHit;

  // The downbeat swaps the colours for its flash.
  vec3 c1 = hsl(uHue, 0.85, 0.55), c2 = hsl(uHue2, 0.85, 0.6);
  float swap = step(0.5, uDownbeat);
  vec3 ink1 = mix(c1, c2, swap), ink2 = mix(c2, c1, swap);

  // The snare: a quarter turn and the halves thrown apart, for the instant it lasts.
  float snare = uHitSnare;
  p = rot(snare * TAU * 0.25) * p;
  p.x += (p.y > 0.0 ? 1.0 : -1.0) * snare * 0.12;
  // A build draws the picture in; the drop flings it back out.
  p *= 1.0 + 0.5 * uBuild - 0.25 * smoothstep(0.9, 1.0, uDropNear);
  // A slow breathing of the whole, with the bar.
  p *= 1.0 + 0.03 * sin(uBar * TAU) * calm;

  // The composition, morphed from the one before over the first bar of the phrase.
  vec3 now = compose(comp, p, px, ink1, ink2, salt, barN, kickPop, calm);
  float into = smoothstep(0.0, 1.0, uPhraseSaw * 4.0);
  vec3 col = now;
  if (into < 1.0 && compBefore != comp) {
    vec3 was = compose(compBefore, p * (1.0 + 0.3 * into), px, ink1, ink2, salt, barN, kickPop, calm);
    col = mix(was * (1.0 - into), now, into);
  }

  // A faint glow of the primary in the middle, so the dark is not flat.
  col += ink1 * exp(-length(p) * 3.0) * 0.06 * (0.5 + 0.5 * uBandLow);
  // The top end: sparkle on the outlines.
  float topHit = smoothstep(0.45, 1.0, uHitTop);
  col += vec3(1.0) * step(0.97, hash(frag * 0.5 + floor(uTime * 20.0))) * topHit * 0.6 * step(0.08, length(col));
  // The hands' hit: white.
  col = mix(col, vec3(1.0), uHit * 0.6);
  col *= uExposure * 1.2;
  fragColor = vec4(col, 1.0);
}
