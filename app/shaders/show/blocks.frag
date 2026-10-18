#version 460 core
#include <flutter/runtime_effect.glsl>

// Blocks: the geometric idea taken as far as it goes. Hard-edged shapes on a grid, two
// colours and white, and everything about them decided by the music —
//
//   the PHRASE picks the composition: a random field, a checkerboard, concentric
//     squares, rows wiped across the bar, diagonal stripes, four-fold mirror, a
//     cascade that fills over the bar, rings of squares running outward — and the
//     cells' two styles out of eight: solid, hollow, a cross, a dot, a triangle, a
//     bar, a corner, a quarter disc;
//   the BAR rolls the arrangement again (which cells, how big, where), cut in on the
//     bar — clear-cut, nothing blended into anything;
//   the BEAT is each cell's own: on its two beats of the bar (its number and the
//     record's salt decide which) a cell turns its shape a quarter — eased, shrinking
//     to fit its square as it turns — or, in the phrases that do not turn, trades its
//     style for the other, cut. The blocks change; the picture never turns as one;
//   the KICK swells the cells that take it (about half, each bar its own set) and
//     lights them; the SNARE swaps the lit cells' colour; the TOP scatters slivers;
//     the DOWNBEAT lifts the whole a touch; a BUILD packs the grid denser towards the
//     drop and a breakdown thins it; the hands' hit wipes to white.
//
// Cells are shaded a little toward their edges and never quite touch, so a field of
// them is a field of blocks and not one flat pastel sheet.

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
uniform float uM1;      // the genome: a salt on every roll, so each record has its own
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
float beatPh() { return fract(uBarSaw * 4.0); }
float beatN() { return floor(uBarSaw * 4.0); }
// A step: moves over the first part of the beat, rests for the remainder.
float eased(float ph) { return smoothstep(0.0, 0.4, ph); }
// A swell: up over a twentieth of a beat, down over the rest.
float swell(float ph) { return smoothstep(0.0, 0.05, ph) * (1.0 - smoothstep(0.05, 0.85, ph)); }
// Cell [i]'s beats: the odd or the even ones of the bar.
float parity(float i, float salt) { return mod(floor(i * 3.0 + salt), 2.0); }
float mine(float i, float salt) { return mod(beatN(), 2.0) == parity(i, salt) ? 1.0 : 0.0; }
// How many of its beats cell [i] has had, the bars so far and this one, the newest
// eased in: what its turns count.
float steps(float i, float salt) {
  float k = parity(i, salt);
  float b = beatN();
  float before = step(k + 0.5, b) + step(k + 2.5, b);
  return 2.0 * uBarIndex + before + mine(i, salt) * eased(beatPh());
}

// A cell's shape in its own square ([c] = −1..1 across the cell): [style] 0 solid,
// 1 hollow, 2 a cross, 3 a dot, 4 a triangle (the square cut on its diagonal), 5 a
// bar, 6 a corner, 7 a quarter disc from the corner — with [w] how far of the cell
// it reaches. Edges a pixel soft ([aa] in cell units).
float shape(vec2 c, float style, float w, float aa) {
  vec2 d = abs(c);
  float m = max(d.x, d.y);
  float box = 1.0 - smoothstep(w - aa, w + aa, m);
  if (style < 0.5) return box;
  if (style < 1.5) return box * smoothstep(w - 0.3 - aa, w - 0.3 + aa, m);
  if (style < 2.5) return box * max(1.0 - smoothstep(0.24 - aa, 0.24 + aa, d.x), 1.0 - smoothstep(0.24 - aa, 0.24 + aa, d.y));
  if (style < 3.5) return 1.0 - smoothstep(w * 0.85 - aa, w * 0.85 + aa, length(c));
  if (style < 4.5) return box * (1.0 - smoothstep(-aa, aa, c.x + c.y));
  if (style < 5.5) return box * (1.0 - smoothstep(0.4 - aa, 0.4 + aa, d.y));
  if (style < 6.5) {
    float t = 0.6 - w;
    return box * (1.0 - smoothstep(t - aa, t + aa, c.x) * smoothstep(t - aa, t + aa, c.y));
  }
  return 1.0 - smoothstep(w * 1.5 - aa, w * 1.5 + aa, length(c + vec2(w)));
}

// The field for the roll of bar [barN]: how lit each point is, 0..1, with the cells'
// own shading, and the kick's share for the cell there. Returns (field, share).
vec2 fieldAt(vec2 uv, float barN, float salt, float aspect) {
  float phraseN = floor(barN / 4.0);
  float comp = floor(hash(vec2(phraseN, 7.0 + salt)) * 8.0);
  float styleA = floor(hash(vec2(phraseN, 13.0 + salt)) * 8.0);
  float styleB = floor(hash(vec2(phraseN, 17.0 + salt)) * 8.0);
  // Whether this phrase's cells turn on their beats, or trade their style.
  float turning = step(0.4, hash(vec2(phraseN, 19.0 + salt)));
  float rollB = hash(vec2(barN, 3.0 + salt));
  float cells = 4.0 + floor(rollB * 5.0) + floor(3.0 * uBuild) - floor(2.0 * (1.0 - uEnergy));
  cells = max(3.0, cells);
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
  if (comp == 5.0) p = abs(p);
  vec2 g = p * cells;
  vec2 cell = floor(g);
  vec2 f = fract(g);
  float aa = cells / uResolution.y * 2.0;

  // The cell's number (its beats), and which cells take the kick this bar: about
  // half, fully; the rest a little.
  float ci = floor(hash(cell * 4.7 + salt) * 64.0);
  float kickShare = mix(0.25, 1.0, step(0.45, hash(cell * 4.7 + barN * 1.3 + salt)));
  float lit = 0.0;
  float w = 0.55 + 0.33 * hash(cell + barN + salt);
  bool band = false;
  if (comp == 0.0) {
    lit = step(0.5, hash(cell * 1.7 + barN + salt));
  } else if (comp == 1.0) {
    float chk = mod(cell.x + cell.y + floor(uBarSaw * 4.0), 2.0);
    lit = chk;
    w = 0.9;
  } else if (comp == 2.0) {
    float ring = floor(max(abs(p.x), abs(p.y)) * cells * 0.5 - floor(uBarSaw * 4.0));
    lit = mod(ring, 2.0);
    w = 0.95;
    f = fract(vec2(max(abs(p.x), abs(p.y)) * cells * 0.5));
    band = true;
  } else if (comp == 3.0) {
    float rows = cells;
    float along = mod(barN, 2.0) < 1.0 ? uv.y : uv.x;
    float row = floor(along * rows);
    float at = floor(uBarSaw * rows);
    lit = (row == at ? 1.0 : 0.45) * step(0.25, hash(vec2(row, barN + salt)));
    w = 0.88;
  } else if (comp == 4.0) {
    float s = fract((p.x + p.y) * cells * 0.35 - floor(uBarSaw * 4.0) * 0.25);
    lit = step(0.5, s);
    w = 0.95;
    f = vec2(fract(s * 2.0));
    band = true;
  } else if (comp == 5.0) {
    lit = step(0.45, hash(cell * 2.3 + barN + salt));
  } else if (comp == 6.0) {
    // A cascade: cells come on one by one over the bar, each fading in over a tenth
    // of it, and all go out on the next.
    lit = smoothstep(0.0, 0.1, uBarSaw - hash(cell * 3.1 + barN + salt));
  } else {
    float d = max(abs(p.x), abs(p.y));
    float ring = fract(d * 3.0 - uBarSaw * 4.0 * 0.5);
    lit = smoothstep(0.55, 0.65, ring) * step(0.3, hash(cell + barN + salt));
    w = 0.88;
  }

  vec2 c = (f - 0.5) * 2.0;
  float sh;
  if (band) {
    // The stripes and the rings are bands, whatever the phrase's styles.
    sh = shape(c, 0.0, clamp(w, 0.2, 0.93), aa);
  } else {
    // The cell's own beat. Where the phrase turns: a quarter turn, eased, the shape
    // drawn smaller as it turns so it stays in its square. Where it does not: the
    // style traded for the other on the beat, a cut. And the kick's swell for the
    // cells that take it, on their beats.
    float st = steps(ci, salt);
    float ang = turning * st * TAU * 0.25;
    float fit = abs(cos(ang)) + abs(sin(ang));
    c = rot(ang) * c * fit;
    float ww = clamp(w + 0.2 * swell(beatPh()) * kickShare * mix(0.2, 1.0, mine(ci, salt)), 0.2, 0.93);
    float h = floor(hash(cell + phraseN + salt) * 2.0);
    float flip = turning > 0.5 ? h : mod(ceil(st - 0.0001) + h, 2.0);
    sh = shape(c, mix(styleA, styleB, flip), ww, aa);
  }
  // A little darker toward a cell's edge: blocks, not a sheet.
  float inner = 1.0 - 0.22 * clamp(max(abs(c.x), abs(c.y)), 0.0, 1.0);
  return vec2(lit * sh * inner, kickShare);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  float aspect = uResolution.x / uResolution.y;
  vec3 primary = hsl(uHue, 1.0, 0.5);
  vec3 secondary = hsl(uHue2, 1.0, 0.55);

  float barN = uBarIndex;
  float phraseN = floor(uBarIndex / 4.0);
  float salt = floor(uM1 * 97.0);

  // This bar's roll, cut in on the bar: clear-cut, nothing blended.
  vec2 now = fieldAt(uv, barN, salt, aspect);
  float field = now.x;
  float kickShare = now.y;

  // The beat lights the field and lets it dim between the hits, eased both ways.
  float ph = beatPh();
  float pulse = 0.65 + 0.35 * smoothstep(0.0, 0.04, ph) * (1.0 - smoothstep(0.1, 0.9, ph));
  vec3 ink = primary;
  // Some cells in the secondary, by the phrase (stable over its bars).
  vec2 pg = (uv - 0.5) * vec2(aspect, 1.0);
  float second = step(0.7, hash(floor(pg * 6.0) * 5.3 + phraseN + salt));
  ink = mix(ink, secondary, second);
  vec3 col = ink * field * pulse;

  // The snare: the lit cells trade colour, for an instant.
  col = mix(col, mix(secondary, primary, second) * field * 0.9, uHitSnare * 0.7);

  // The top end: thin slivers.
  float topHit = smoothstep(0.45, 1.0, uHitTop);
  float sliver = step(0.985 - 0.012 * topHit, hash(vec2(floor(uv.x * 140.0), floor(uTime * 24.0)))) * topHit;
  col += secondary * sliver * 0.8;

  // The kick: the cells that take it lit in the secondary (their swell is in the field).
  col = mix(col, secondary * 1.15 * field, uHitKick * 0.6 * kickShare);
  // The downbeat: a lift, not a white frame. A hit from the hands: white over everything.
  col = mix(col, vec3(1.0) * field, uDownbeat * 0.3);
  col = mix(col, vec3(1.0), uHit * 0.8);
  // A build: a glow of the primary at the very end.
  col += primary * smoothstep(0.9, 1.0, uDropNear) * 0.3;

  col *= uExposure * 1.25;
  fragColor = vec4(col, 1.0);
}
