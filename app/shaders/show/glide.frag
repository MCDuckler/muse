#version 460 core
#include <flutter/runtime_effect.glsl>

// Glide: twelve shapes that land on the beat. Every beat each shape has a place in a
// formation — a ring, a grid, two rings, a triangle, a square, a line, a spiral, a
// cross, a hexagon, a scatter, a figure of eight, a chevron — and between beats it
// glides from the one place to the next, eased in and out, so it arrives exactly as
// the beat lands and sits there a moment before it leaves again.
//
// Everything is a function of the beat's number, never of the clock: where shape i
// is on beat j depends only on i and j (and the record's salt), so the glide from
// beat j to j+1 is continuous through every bar and phrase change. Per bar: the
// formation, and how the shapes trade places on it (stepping round, or shuffled
// across it), and whether they move every beat or every other. Per phrase: the mix
// of shapes (circles alone, circles and squares, triangles and rings, ...), each
// shape's kind morphing into its next one during the move over the phrase's line.
//
// On landing a small pop (more with the kick); the snare brightens the outlines;
// a build pulls the formation in; a breakdown stretches the glides over the whole
// beat. Lit as Kinetic's shapes are — soft fill, bright edge — with a slighter glow.

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
const float N = 12.0;

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
float sdPolyN(vec2 p, float n, float r) {
  float a = atan(p.y, p.x);
  float seg = TAU / n;
  return cos(floor(0.5 + a / seg) * seg - a) * length(p) - r;
}

float sdBox(vec2 p, float r) {
  vec2 d = abs(p) - vec2(r * 0.82);
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r * 0.06;
}

// Six kinds: circle, square, triangle, diamond, ring, hexagon.
float sdKind(vec2 p, float kind, float r) {
  if (kind < 0.5) return length(p) - r;
  if (kind < 1.5) return sdBox(p, r);
  if (kind < 2.5) return sdPolyN(rot(TAU / 4.0) * p, 3.0, r * 0.62);
  if (kind < 3.5) return sdPolyN(p, 4.0, r * 0.78);
  if (kind < 4.5) return abs(length(p) - r * 0.8) - r * 0.2;
  return sdPolyN(p, 6.0, r * 0.9);
}

// Kinetic's light, with a slighter glow: a soft fill, a bright edge, a halo.
vec3 light(float d, float px, vec3 ink, float core) {
  float fill = 1.0 - smoothstep(-px, px, d);
  float edge = 1.0 - smoothstep(0.0, 2.2 * px, abs(d));
  float glow = exp(-max(d, 0.0) / (14.0 * px)) * 0.28;
  return ink * (fill * (0.3 + 0.45 * core) + glow) + mix(ink, vec3(1.0), 0.55 + 0.45 * core) * edge * 0.9;
}

// ------------------------------------------------------------------ formations
// Slot s of twelve in formation f: a place, in units of the screen's height.
vec2 perimeter(float s, float corners, float r, float turn) {
  // Twelve points round a regular polygon, evenly by length.
  float t = s / N * corners;
  float side = floor(t), f = t - side;
  float a0 = side / corners * TAU + turn, a1 = (side + 1.0) / corners * TAU + turn;
  return mix(vec2(cos(a0), sin(a0)), vec2(cos(a1), sin(a1)), f) * r;
}

vec2 formation(float f, float s, float barN, float salt) {
  if (f < 0.5) { float a = s / N * TAU; return vec2(cos(a), sin(a)) * 0.32; }                       // ring
  if (f < 1.5) return vec2((mod(s, 4.0) - 1.5) * 0.21, (floor(s / 4.0) - 1.0) * 0.21);             // grid
  if (f < 2.5) {                                                                                      // two rings
    float inner = step(s, 5.5);
    float a = mod(s, 6.0) / 6.0 * TAU + inner * TAU / 12.0;
    return vec2(cos(a), sin(a)) * mix(0.36, 0.16, inner);
  }
  if (f < 3.5) return perimeter(s, 3.0, 0.36, TAU / 4.0);                                            // triangle
  if (f < 4.5) return perimeter(s, 4.0, 0.36, TAU / 8.0);                                            // square
  if (f < 5.5) return vec2((s - 5.5) * 0.105, 0.05 * sin(s * 1.7));                                  // line
  if (f < 6.5) { float a = s * 0.95; return vec2(cos(a), sin(a)) * (0.05 + 0.028 * s); }            // spiral
  if (f < 7.5) {                                                                                      // cross
    float arm = mod(s, 4.0), k = floor(s / 4.0) + 1.0;
    return rot(arm * TAU / 4.0) * vec2(k * 0.12, 0.0);
  }
  if (f < 8.5) return perimeter(s, 6.0, 0.34, 0.0);                                                  // hexagon
  if (f < 9.5) return (vec2(hash(vec2(s, barN + salt)), hash(vec2(s + 7.0, barN - salt))) - 0.5) * vec2(1.25, 0.72);  // scatter
  if (f < 10.5) { float a = s / N * TAU; return vec2(sin(a) * 0.42, sin(2.0 * a) * 0.2); }          // figure of eight
  return vec2((s - 5.5) * 0.085, abs(s - 5.5) * 0.045 - 0.12);                                       // chevron
}

// How big the shapes are in each formation (crowded ones smaller).
float formationSize(float f) {
  if (f > 0.5 && f < 1.5) return 0.055;
  if (f > 4.5 && f < 7.5) return 0.04;
  if (f > 10.5) return 0.04;
  return 0.05;
}

// The mix of shapes for a phrase: shape i's kind.
float kindOf(float i, float phraseN, float salt) {
  float mixN = floor(hash(vec2(phraseN, salt + 31.0)) * 8.0);
  if (mixN < 0.5) return 0.0;                                   // circles
  if (mixN < 1.5) return mod(i, 2.0);                           // circles and squares
  if (mixN < 2.5) return mod(i, 2.0) < 0.5 ? 2.0 : 4.0;         // triangles and rings
  if (mixN < 3.5) return mod(i, 3.0) < 1.0 ? 0.0 : 3.0;         // circles and diamonds
  if (mixN < 4.5) return mod(i, 2.0) < 0.5 ? 5.0 : 0.0;         // hexagons and circles
  if (mixN < 5.5) return 1.0 + mod(i, 3.0);                     // squares, triangles, diamonds
  if (mixN < 6.5) return mod(i, 6.0);                           // every kind
  return mod(i, 4.0) < 1.0 ? 4.0 : 0.0;                         // circles with a few rings
}

// Shape i on beat j: where, how big, which way turned, and its colour's place.
struct Pose { vec2 at; float size; float turn; };

Pose poseAt(float i, float j, float salt) {
  float barN = floor(j / 4.0);
  // Every other beat in some bars: those bars hold the odd beats where the even ones
  // put them (so the next glide takes the whole two beats' worth in one).
  float everyOther = step(0.7, hash(vec2(barN, salt + 13.0)));
  float jj = everyOther > 0.5 ? j - mod(j, 2.0) : j;
  float f = floor(hash(vec2(barN, salt + 3.0)) * 12.0);
  // How the twelve trade places beat by beat: stepping round by one, or a whole
  // shuffle (a times i plus b, a prime to twelve, is a reordering).
  float step1 = mod(jj, 4.0);
  float shuffle = step(0.55, hash(vec2(barN, salt + 5.0)));
  float s;
  if (shuffle > 0.5) {
    float pick = floor(hash(vec2(jj, salt + 17.0)) * 4.0);
    float a = pick < 0.5 ? 1.0 : pick < 1.5 ? 5.0 : pick < 2.5 ? 7.0 : 11.0;
    float b = floor(hash(vec2(jj, salt + 19.0)) * N);
    s = mod(i * a + b, N);
  } else {
    float dir = hash(vec2(barN, salt + 23.0)) < 0.5 ? 1.0 : -1.0;
    s = mod(i + dir * (step1 + barN * 4.0), N);
  }
  Pose p;
  p.at = formation(f, s, barN, salt);
  // The whole formation turned a step each beat on some bars.
  float spin = hash(vec2(barN, salt + 29.0));
  if (spin > 0.6) p.at = rot((spin > 0.8 ? 1.0 : -1.0) * jj * TAU / 12.0) * p.at;
  p.size = formationSize(f);
  p.turn = jj * TAU / 8.0 * (mod(i, 2.0) < 0.5 ? 1.0 : -1.0);
  return p;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 p = (frag - 0.5 * uResolution) / uResolution.y;
  float px = 1.0 / uResolution.y;

  float salt = floor(uM1 * 97.0);
  // The beat: its number on the grid and how far through it.
  float beats = uBarIndex * 4.0 + uBarSaw * 4.0;
  float j = floor(beats);
  float frac = beats - j;
  // The glide: leaves late in the beat and lands on the next, eased; the calmer the
  // music, the earlier it leaves — a drift across the whole beat in a breakdown.
  float calm = clamp(uEnergy, 0.0, 1.0);
  float leave = mix(0.0, 0.42, calm);
  float t = smoothstep(leave, 1.0, frac);
  t = t * t * (3.0 - 2.0 * t);
  // The landing: a small pop as it arrives, more with the kick.
  float land = exp(-frac * 7.0);
  float pop = 1.0 + 0.1 * land * (0.4 + 0.6 * calm) + 0.18 * uHitKick;

  float phraseNow = floor(j / 16.0), phraseNext = floor((j + 1.0) / 16.0);
  vec3 c1 = hsl(uHue, 0.8, 0.56), c2 = hsl(uHue2, 0.8, 0.6);
  // A build pulls the formation in; the drop lets it go.
  float pull = 1.0 - 0.35 * uBuild + 0.08 * smoothstep(0.9, 1.0, uDropNear);
  // The whole picture breathing slowly with the bar.
  p *= 1.0 + 0.025 * sin(uBar * TAU);

  vec3 col = vec3(0.0);
  for (float i = 0.0; i < N; i++) {
    Pose a = poseAt(i, j, salt), b = poseAt(i, j + 1.0, salt);
    vec2 at = mix(a.at, b.at, t) * pull;
    float size = mix(a.size, b.size, t) * pop * (0.9 + 0.2 * hash(vec2(i, salt)));
    float turn = mix(a.turn, b.turn, t);
    vec2 q = rot(turn) * (p - at);
    // The kind: this phrase's, morphing into the next phrase's on the move across.
    float k0 = kindOf(i, phraseNow, salt), k1 = kindOf(i, phraseNext, salt);
    float d = sdKind(q, k0, size);
    if (k1 != k0) d = mix(d, sdKind(q, k1, size), t);
    vec3 ink = mix(c1, c2, fract(i / N + 0.25 * floor(j / 4.0)));
    float core = 0.35 * land + 0.5 * uHitKick;
    col += light(d, px, ink, core);
  }
  // The snare: the outlines brighter for its instant (all of them at once is enough
  // of a flash without moving anything off the beat).
  col *= 1.0 + 0.35 * uHitSnare;
  // A faint wash of the primary in the middle, so the dark is not flat.
  col += c1 * exp(-length(p) * 3.0) * 0.04 * (0.5 + 0.5 * uBandLow);
  col = mix(col, vec3(1.0), uHit * 0.5);
  col *= uExposure * 1.15;
  fragColor = vec4(col, 1.0);
}
