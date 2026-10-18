#version 460 core
#include <flutter/runtime_effect.glsl>

// Kinetic: geometry, all in. Shapes drawn as distance fields — circles, polygons,
// stars, rings, and lines of laser — in eight compositions that the phrase chooses
// and crossfades between over its first bar:
//
//   ORBIT    a ring of shapes circling, the ring turning a step a beat, each shape
//            turning a quarter on its own beats;
//   SPIRAL   a phyllotaxis — shapes at the golden angle, a wave of scale running out
//            from the middle over every beat;
//   LATTICE  a hex field of small shapes, a wave crossing it over the bar, the field
//            swirled round the middle on alternate bars;
//   RINGS    polygon outlines one inside the other, drawn as lasers, turning against
//            each other a step at a time, each on its own beats;
//   MANDALA  a few shapes folded into eight wedges and twisted by the bass, the fold
//            turning a step a beat;
//   BURST    shapes flung from the middle on every beat and fading as they go;
//   BEAMS    a fan of laser beams from one head — on the floor, in the middle, on the
//            ceiling — each beam swinging and flaring on its own beats, the fan
//            mirrored when the phrase says so;
//   TUNNEL   a laser grid in perspective, floor and ceiling, rolling toward the eye
//            with the bar, every line lit on its own beats.
//
// Motion follows the beat grid, eased: a step takes the first part of a beat and then
// rests, a swell rises over a twentieth of a beat and falls over the rest, so nothing
// snaps. Every element has its own two beats of the bar (its number and the record's
// salt decide which), takes the kick fully on those and only a little on the others,
// so the picture pulses in parts, never as one block. A shape keeps its sides — a
// hexagon is a hexagon for the phrase — and what changes between phrases crossfades.
// The snare flares the lines and trades the colours for the instant it lasts, the top
// end sparkles the outlines, the downbeat blends the two colours over, a build draws
// everything into the middle until the drop flings it out, a breakdown slows every
// motion to a drift. Edges anti-aliased by pixel, every line a hot core with a soft
// glow, and the light rolled off at the top (a knee), so a crowd of lines in the
// middle is bright, not a white ball.

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

// ------------------------------------------------------------------ the beat, eased
// The beat's phase (0..1) and its number in the bar, from the bar's saw.
float beatPh() { return fract(uBarSaw * 4.0); }
float beatN() { return floor(uBarSaw * 4.0); }
// A step: moves over the first part of the beat, rests for the remainder.
float eased(float ph) { return smoothstep(0.0, 0.45, ph); }
// A swell: up over a twentieth of a beat, down over the rest.
float swell(float ph) { return smoothstep(0.0, 0.05, ph) * (1.0 - smoothstep(0.05, 0.9, ph)); }
// The beats counted since the record began, the newest eased in: the whole
// picture's stepping motions count this.
float stepAll() { return uBarIndex * 4.0 + beatN() + eased(beatPh()); }

// Element [i]'s beats: the odd or the even ones of the bar.
float parity(float i, float salt) { return mod(floor(i * 3.0 + salt), 2.0); }
float mine(float i, float salt) { return mod(beatN(), 2.0) == parity(i, salt) ? 1.0 : 0.0; }
// How many of its beats element [i] has had — the bars so far and this one — the
// newest eased in: what its own stepping motions count.
float steps(float i, float salt) {
  float k = parity(i, salt);
  float b = beatN();
  float before = step(k + 0.5, b) + step(k + 2.5, b);
  return 2.0 * uBarIndex + before + mine(i, salt) * eased(beatPh());
}
// The kick's swell for element [i]: full on its beats, a little on the others, and
// as high as the kick is hard ([amp]).
float pop(float i, float salt, float amp) { return swell(beatPh()) * amp * mix(0.15, 1.0, mine(i, salt)); }

// ------------------------------------------------------------------ shapes
float sdPoly(vec2 p, float n, float r) {
  float a = atan(p.y, p.x);
  float seg = TAU / n;
  return cos(floor(0.5 + a / seg) * seg - a) * length(p) - r;
}

float sdStar(vec2 p, float r, float n, float inner) {
  float a = atan(p.y, p.x);
  float seg = TAU / n;
  float k = abs(mod(a, seg) - seg * 0.5) / (seg * 0.5);
  return length(p) - mix(r, r * inner, k);
}

// [kind] 0 a circle, 1 a polygon of [sides], 2 a star of [sides] points, 3 a ring.
float sd(vec2 p, float kind, float r, float sides) {
  if (kind < 0.5) return length(p) - r;
  if (kind < 1.5) return sdPoly(p, sides, r);
  if (kind < 2.5) return sdStar(p, r, sides, 0.5);
  return abs(length(p) - r) - r * 0.16;
}

// A shape's light: a soft fill, a hot edge, a glow — by its distance, in pixels.
vec3 light(float d, float px, vec3 ink, float hot) {
  float fill = 1.0 - smoothstep(-px, px, d);
  float w = px * (1.1 + 1.0 * hot);
  float edge = exp(-d * d / (2.0 * w * w));
  float glow = exp(-max(d, 0.0) / (px * (12.0 + 10.0 * hot))) * (0.22 + 0.25 * hot);
  return ink * (fill * (0.25 + 0.45 * hot) + glow) + mix(ink, vec3(1.0), 0.5 + 0.5 * hot) * edge;
}

// A line's light: a hot core and a glow, about the distance to it.
vec3 laser(float d, float px, vec3 ink, float hot) {
  float w = px * (1.0 + 1.3 * hot);
  float core = exp(-d * d / (2.0 * w * w));
  float glow = exp(-d / (px * (9.0 + 12.0 * hot))) * (0.22 + 0.3 * hot);
  return mix(ink, vec3(1.0), 0.45 + 0.55 * hot) * core + ink * glow;
}

// A laser from head [o] along [ang]: fading along its length, a soft dot behind.
vec3 beam(vec2 p, vec2 o, float ang, float px, vec3 ink, float hot) {
  vec2 dir = vec2(cos(ang), sin(ang));
  vec2 q = p - o;
  float t = dot(q, dir);
  float d = t > 0.0 ? abs(q.x * dir.y - q.y * dir.x) : length(q);
  float along = 0.45 + 0.55 * exp(-max(t, 0.0) * 1.1);
  return laser(d, px, ink, hot) * along;
}

// ------------------------------------------------------------------ compositions

vec3 orbit(vec2 p, float px, vec3 c1, vec3 c2, float salt, float phraseN, float amp, float calm) {
  float n = 6.0 + floor(hash(vec2(phraseN, salt)) * 7.0);
  float sides = 3.0 + floor(hash(vec2(phraseN, salt + 3.0)) * 5.0);
  float tilt = 0.65 + 0.35 * sin(uPhraseSaw * TAU);
  // The ring turns half a slot a beat, eased, and drifts.
  float spin = stepAll() * TAU / n * 0.5 * calm + uTime * 0.04 * calm;
  vec3 col = vec3(0.0);
  for (float i = 0.0; i < 12.0; i++) {
    if (i >= n) break;
    float a = i / n * TAU + spin;
    float mp = pop(i, salt, amp);
    float r = 0.33 + 0.03 * mp;
    vec2 at = vec2(cos(a) * r, sin(a) * r * tilt);
    float kind = mod(i + floor(hash(vec2(phraseN, salt + 4.0)) * 4.0), 4.0);
    float size = 0.055 + 0.02 * hash(vec2(i, phraseN)) + 0.03 * mp;
    // Each shape turns a quarter on its own beats.
    vec2 q = rot(steps(i, salt) * TAU * 0.125 + uTime * 0.1) * (p - at);
    float d = sd(q, kind, size, sides);
    col += light(d, px, mix(c1, c2, i / n), mp);
  }
  return col;
}

vec3 spiral(vec2 p, float px, vec3 c1, vec3 c2, float salt, float phraseN, float amp, float calm) {
  float golden = 2.39996323;
  float turn = stepAll() * 0.08 * calm + uTime * 0.03;
  float kind = floor(hash(vec2(phraseN, salt + 5.0)) * 3.0);
  float sides = 3.0 + floor(hash(vec2(phraseN, salt + 6.0)) * 5.0);
  // The wave runs out from the middle over the beat and is gone by its end; the
  // shapes at its radius swell — fully those whose beat it is.
  float ph = beatPh();
  float waveR = 0.56 * smoothstep(0.0, 0.75, ph);
  float waveK = 1.0 - smoothstep(0.55, 1.0, ph);
  vec3 col = vec3(0.0);
  for (float i = 1.0; i <= 42.0; i++) {
    float rr = 0.082 * sqrt(i) * (1.0 - 0.35 * uBuild);
    float a = i * golden + turn;
    vec2 at = vec2(cos(a), sin(a)) * rr;
    float w = exp(-abs(rr - waveR) * 9.0) * waveK;
    float mp = amp * w * mix(0.15, 1.0, mine(i, salt));
    float size = 0.016 + 0.016 * (1.0 - i / 42.0) + 0.028 * mp + 0.008 * uBandHigh * step(0.6, hash(vec2(i, salt + 8.0)));
    float d = sd(rot(a + steps(i, salt) * TAU * 0.125) * (p - at), kind, size, sides);
    col += light(d, px, mix(c1, c2, i / 42.0), mp) * 0.8;
  }
  return col;
}

vec3 lattice(vec2 p, float px, vec3 c1, vec3 c2, float salt, float phraseN, float amp, float calm) {
  p = rot(uTime * 0.04 * calm) * p;
  // The swirl, on alternate bars, eased in and out over the bar's first and last
  // beat: every shape turned by its distance from the middle — the field itself
  // stays put, so no shape is bent.
  float swirlOn = mod(uBarIndex, 2.0) < 1.0 ? 1.0 : 0.0;
  float ease = smoothstep(0.0, 0.25, uBarSaw) * (1.0 - smoothstep(0.75, 1.0, uBarSaw));
  float swirl = mix(1.0 - ease, ease, swirlOn);
  float cellsize = 0.11 - 0.03 * uBuild;
  vec2 g1 = p / cellsize;
  vec2 c1a = floor(g1) + 0.5;
  vec2 g2 = p / cellsize + vec2(0.5, 0.5);
  vec2 c2a = floor(g2);
  vec2 ca = c1a * cellsize, cb = c2a * cellsize;
  vec2 centre = length(p - ca) < length(p - cb) ? ca : cb;
  float dist = length(centre);
  float wave = 0.5 + 0.5 * cos((dist * 6.0 - uBarSaw * 2.0) * TAU * 0.5);
  // Each cell its own number, so its own beats.
  float ci = floor(hash(centre * 7.0 + salt) * 64.0);
  float mp = pop(ci, salt, amp);
  float size = cellsize * (0.2 + 0.2 * wave + 0.12 * mp);
  float kind = floor(hash(vec2(phraseN, salt + 9.0)) * 4.0);
  float sides = 3.0 + floor(hash(vec2(phraseN, salt + 10.0)) * 5.0);
  float ang = steps(ci, salt) * TAU * 0.125 + dist * (3.0 + 4.0 * uBandLow) * swirl * calm;
  float d = sd(rot(ang) * (p - centre), kind, size, sides);
  return light(d, px, mix(c1, c2, wave), mp * wave) * (0.3 + 0.4 * wave);
}

vec3 rings(vec2 p, float px, vec3 c1, vec3 c2, float salt, float phraseN, float amp, float calm) {
  float sides = 3.0 + floor(hash(vec2(phraseN, salt + 2.0)) * 6.0);
  vec3 col = vec3(0.0);
  for (float i = 0.0; i < 7.0; i++) {
    float k = i / 7.0;
    float mp = pop(i, salt, amp);
    float r = (0.07 + 0.065 * i) * (1.0 + 0.08 * mp) * (1.0 - 0.4 * uBuild * k);
    // Each turns half a side on its own beats, the odd ones the other way, and drifts.
    float dir = mod(i, 2.0) < 1.0 ? 1.0 : -1.0;
    float a = dir * (steps(i, salt) * TAU / sides * 0.5 + uTime * 0.06) * calm;
    float d = abs(sdPoly(rot(a) * p, sides, r));
    col += laser(d, px, mix(c1, c2, k), mp) * (1.0 - 0.07 * i);
  }
  return col;
}

vec3 mandala(vec2 p, float px, vec3 c1, vec3 c2, float salt, float phraseN, float amp, float calm) {
  float a = atan(p.y, p.x), r = length(p);
  float seg = TAU / 8.0;
  // The fold turns a quarter wedge a beat, eased.
  a = abs(mod(a + stepAll() * seg * 0.25 * calm, seg) - seg * 0.5);
  a += r * (1.5 + 4.0 * uBandLow) * (0.3 + 0.7 * calm);
  vec2 q = vec2(cos(a), sin(a)) * r;
  float sides = 3.0 + floor(hash(vec2(phraseN, salt + 12.0)) * 5.0);
  vec3 col = vec3(0.0);
  for (float i = 0.0; i < 4.0; i++) {
    vec2 at = vec2(0.12 + 0.11 * i, 0.03 * sin(uTime * 0.7 + i));
    float kind = mod(i + floor(hash(vec2(phraseN, salt + 7.0)) * 4.0), 4.0);
    float mp = pop(i, salt, amp);
    float size = 0.05 + 0.015 * i + 0.03 * mp;
    float d = sd(rot(steps(i, salt) * TAU * 0.125 + uTime * 0.1 * (1.0 + 0.5 * i)) * (q - at), kind, size, sides);
    col += light(d, px, mix(c1, c2, i / 3.0), mp);
  }
  return col;
}

vec3 burst(vec2 p, float px, vec3 c1, vec3 c2, float salt, float phraseN, float amp, float calm) {
  vec3 col = vec3(0.0);
  float sides = 3.0 + floor(hash(vec2(phraseN, salt + 14.0)) * 5.0);
  float kindBase = floor(hash(vec2(phraseN, salt + 15.0)) * 4.0);
  for (float i = 0.0; i < 14.0; i++) {
    // Four shapes are flung on every beat; each travels as its beat ages.
    float s = mod(i, 4.0);
    float born = uBarIndex * 4.0 + beatN() - s;
    float age = s + beatPh();
    float a = hash(vec2(i, born + salt)) * TAU;
    float speed = 0.12 + 0.1 * hash(vec2(i + 2.0, born));
    // Born a little out from the middle already, so the four of a beat are not one
    // white ball there.
    vec2 at = vec2(cos(a), sin(a)) * ((age + 0.9) * speed * (0.5 + 0.5 * uEnergy)) * calm;
    float fade = exp(-age * 0.8);
    float kind = mod(floor(i / 4.0) + kindBase, 4.0);
    // The newest take the kick: a swell as they are born, eased.
    float mp = amp * exp(-age * 2.5) * smoothstep(0.0, 0.05, age) * mix(0.3, 1.0, mine(i, salt));
    float size = (0.035 + 0.025 * hash(vec2(i, born + 1.0))) * (1.0 + 0.5 * mp) * (0.4 + 0.6 * fade);
    float d = sd(rot(age * 2.0 + a) * (p - at), kind, size, sides);
    col += light(d, px, mix(c1, c2, hash(vec2(i, born + 4.0))), mp) * fade;
  }
  return col;
}

vec3 beams(vec2 p, float px, vec3 c1, vec3 c2, float salt, float phraseN, float amp, float calm) {
  float n = 7.0 + floor(hash(vec2(phraseN, salt + 21.0)) * 6.0);
  // The head: on the floor, in the middle, on the ceiling — and its fan.
  float where = floor(hash(vec2(phraseN, salt + 22.0)) * 3.0);
  vec2 o = vec2(0.0, where < 0.5 ? -0.56 : (where < 1.5 ? 0.0 : 0.56));
  float base = where < 0.5 ? TAU * 0.25 : (where < 1.5 ? 0.0 : -TAU * 0.25);
  float spread = (where < 0.5 || where > 1.5) ? TAU * 0.42 : TAU;
  float mirror = step(0.5, hash(vec2(phraseN, salt + 23.0)));
  vec3 col = vec3(0.0);
  for (float i = 0.0; i < 12.0; i++) {
    if (i >= n) break;
    float k = (i + 0.5) / n - 0.5;
    // Its swing: a step on each of its beats, eased, so the fan sweeps in parts; and
    // a slow sway.
    float swing = sin(steps(i, salt) * TAU * 0.125 + i * 1.7) * 0.2 * calm + 0.04 * sin(uTime * 0.5 + i * 2.1);
    float ang = base + k * spread + swing;
    float hot = pop(i, salt, amp);
    vec3 ink = mix(c1, c2, fract(i * 0.37 + phraseN * 0.13));
    col += beam(p, o, ang, px, ink, hot);
    if (mirror > 0.5) col += beam(vec2(-p.x, p.y), o, ang, px, ink, hot) * 0.7;
  }
  // The head: a hot dot.
  col += mix(c1, vec3(1.0), 0.7) * exp(-length(p - o) / (5.0 * px)) * 0.9;
  return col;
}

vec3 tunnel(vec2 p, float px, vec3 c1, vec3 c2, float salt, float phraseN, float amp, float calm) {
  // The horizon through the middle (the phrase may lift or lower it), the lines
  // running to it; the floor and the ceiling roll toward the eye with the bar.
  float horizon = (hash(vec2(phraseN, salt + 31.0)) - 0.5) * 0.3;
  float y = p.y - horizon;
  float ay = max(abs(y), 0.003);
  float z = 0.14 / ay;
  float roll = (uBarIndex + uBarSaw) * 2.0 * calm;
  float lineN = floor(z - roll);
  float lf = fract(z - roll);
  float dy = min(lf, 1.0 - lf) * ay * ay / 0.14;
  float hot = pop(lineN, salt, amp);
  float fade = smoothstep(0.0, 0.1, ay) * exp(-z * 0.12);
  vec3 ink = mix(c1, c2, mod(lineN, 2.0));
  vec3 col = laser(dy, px, ink, hot) * fade;
  // The cross lines, converging on the vanishing point (x a fixed share of the
  // depth: about half the height apart at the eye), each its own beats too.
  float xs = p.x * z * 14.0;
  float colN = floor(xs + 0.5);
  float dx = abs(fract(xs + 0.5) - 0.5) / (z * 14.0);
  float hotX = pop(colN + 7.0, salt, amp);
  col += laser(dx, px, mix(c2, c1, 0.5), hotX) * fade * 0.8;
  // The horizon: a glowing line.
  col += c1 * exp(-abs(y) / (10.0 * px)) * 0.6;
  return col;
}

vec3 compose(float which, vec2 p, float px, vec3 c1, vec3 c2, float salt, float phraseN, float amp, float calm) {
  if (which < 0.5) return orbit(p, px, c1, c2, salt, phraseN, amp, calm);
  if (which < 1.5) return spiral(p, px, c1, c2, salt, phraseN, amp, calm);
  if (which < 2.5) return lattice(p, px, c1, c2, salt, phraseN, amp, calm);
  if (which < 3.5) return rings(p, px, c1, c2, salt, phraseN, amp, calm);
  if (which < 4.5) return mandala(p, px, c1, c2, salt, phraseN, amp, calm);
  if (which < 5.5) return burst(p, px, c1, c2, salt, phraseN, amp, calm);
  if (which < 6.5) return beams(p, px, c1, c2, salt, phraseN, amp, calm);
  return tunnel(p, px, c1, c2, salt, phraseN, amp, calm);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 p = (frag - 0.5 * uResolution) / uResolution.y;
  float px = 1.0 / uResolution.y;

  float salt = floor(uM1 * 89.0);
  float phraseN = floor(uBarIndex / 4.0);
  float comp = floor(hash(vec2(phraseN, 11.0 + salt)) * 8.0);
  float compBefore = floor(hash(vec2(phraseN - 1.0, 11.0 + salt)) * 8.0);
  // A breakdown slows every motion to a drift; a drop runs.
  float calm = 0.35 + 0.65 * uEnergy;
  // How hard the kick lands: the swells' height.
  float amp = 0.5 + 0.5 * clamp(uHitKick + 0.5 * uHit, 0.0, 1.0);

  // The downbeat blends the colours over and back.
  vec3 c1 = hsl(uHue, 0.85, 0.55), c2 = hsl(uHue2, 0.85, 0.6);
  float swap = smoothstep(0.2, 0.8, uDownbeat);
  vec3 ink1 = mix(c1, c2, swap), ink2 = mix(c2, c1, swap);

  // A build draws the picture in; the drop flings it back out.
  p *= 1.0 + 0.5 * uBuild - 0.25 * smoothstep(0.9, 1.0, uDropNear);
  // A slow breathing of the whole, with the bar.
  p *= 1.0 + 0.03 * sin(uBar * TAU) * calm;

  // The composition, crossfaded from the one before over the first bar of the phrase.
  vec3 now = compose(comp, p, px, ink1, ink2, salt, phraseN, amp, calm);
  float into = smoothstep(0.0, 1.0, uPhraseSaw * 4.0);
  vec3 col = now;
  if (into < 1.0 && compBefore != comp) {
    vec3 was = compose(compBefore, p * (1.0 + 0.3 * into), px, ink1, ink2, salt, phraseN - 1.0, amp, calm);
    col = mix(was * (1.0 - into), now, into);
  }

  // The snare: the lines flare and the colours trade, for the instant it lasts.
  float snare = uHitSnare;
  col = mix(col, col.brg, snare * 0.5) * (1.0 + 0.4 * snare);
  // A faint glow of the primary in the middle, so the dark is not flat.
  col += ink1 * exp(-length(p) * 3.0) * 0.05 * (0.5 + 0.5 * uBandLow);
  // The top end: sparkle on the outlines.
  float topHit = smoothstep(0.45, 1.0, uHitTop);
  col += vec3(1.0) * step(0.97, hash(frag * 0.5 + floor(uTime * 20.0))) * topHit * 0.6 * step(0.08, length(col));
  // The knee: bright, never a white ball where many lines meet.
  col = col / (1.0 + 0.4 * col);
  // The hands' hit: white.
  col = mix(col, vec3(1.0), uHit * 0.6);
  col *= uExposure * 1.25;
  fragColor = vec4(col, 1.0);
}
