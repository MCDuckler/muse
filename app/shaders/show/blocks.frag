#version 460 core
#include <flutter/runtime_effect.glsl>

// Blocks: the geometric idea taken as far as it goes. Hard-edged shapes on a grid, two
// colours and white, and everything about them decided by the music —
//
//   the PHRASE picks the composition: a random field, a checkerboard, concentric
//     squares, rows wiped across the bar, diagonal stripes, four-fold mirror, a
//     cascade that fills over the bar, rings of squares running outward — and the
//     cell's style: solid, hollow, a cross, a dot;
//   the BAR rolls the arrangement again (which cells, how big, where);
//   the BEAT steps the grid's turn and the stripes' phase, and dims between beats;
//   the KICK widens the cells and lights the field; the SNARE inverts it; the TOP
//     scatters slivers; the DOWNBEAT goes white for a flash; a BUILD packs the grid
//     denser towards the drop and a breakdown thins it; the hands' hit wipes to white.
//
// Nothing here is drawn twice the same: eight compositions × four styles × a new
// roll every bar, on the record's own grid.

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

// A cell's shape, in its own square (f = 0..1 across the cell): solid, hollow, a
// cross, a dot — [style] 0..3 — with [w] how much of the cell it fills.
float shape(vec2 f, float style, float w) {
  vec2 d = abs(f - 0.5) * 2.0;        // 0 at the middle, 1 at the edge
  float box = step(max(d.x, d.y), w);
  if (style < 0.5) return box;
  if (style < 1.5) return box * (1.0 - step(max(d.x, d.y), w - 0.28));
  if (style < 2.5) return box * max(step(d.x, 0.22), step(d.y, 0.22));
  return step(length(d), w * 0.9);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  float aspect = uResolution.x / uResolution.y;
  vec3 primary = hsl(uHue, 1.0, 0.5);
  vec3 secondary = hsl(uHue2, 1.0, 0.55);

  // The phrase and the bar, as numbers to roll from; the record's salt on both.
  float barN = uBarIndex;
  float phraseN = floor(uBarIndex / 4.0);
  float salt = floor(uM1 * 97.0);
  float comp = floor(hash(vec2(phraseN, 7.0 + salt)) * 8.0);     // the composition
  float style = floor(hash(vec2(phraseN, 13.0 + salt)) * 4.0);   // the cell's style
  float rollB = hash(vec2(barN, 3.0 + salt));

  // The grid: how many cells, denser up a build, thinner in a breakdown; turned a
  // step on each beat where the phrase says so.
  float cells = 4.0 + floor(rollB * 5.0) + floor(3.0 * uBuild) - floor(2.0 * (1.0 - uEnergy));
  cells = max(3.0, cells);
  float turnStep = step(0.6, hash(vec2(phraseN, 19.0 + salt))) * floor(uBarSaw * 4.0) * 0.7854;
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
  p = rot(turnStep) * p;
  // Four-fold mirror on composition 5.
  if (comp == 5.0) p = abs(p);
  vec2 g = p * cells;
  vec2 cell = floor(g);
  vec2 f = fract(g);

  // What is lit, by composition.
  float lit = 0.0;
  float w = 0.55 + 0.35 * hash(cell + barN + salt) + 0.3 * uHitKick;
  if (comp == 0.0) {
    // A random field: each cell on or off this bar.
    lit = step(0.5, hash(cell * 1.7 + barN + salt));
  } else if (comp == 1.0) {
    // A checkerboard, inverted every beat.
    float chk = mod(cell.x + cell.y + floor(uBarSaw * 4.0), 2.0);
    lit = chk;
    w = 0.95;
  } else if (comp == 2.0) {
    // Concentric squares stepping outward on the beat.
    float ring = floor(max(abs(p.x), abs(p.y)) * cells * 0.5 - floor(uBarSaw * 4.0));
    lit = mod(ring, 2.0);
    w = 1.0;
    f = fract(vec2(max(abs(p.x), abs(p.y)) * cells * 0.5));
  } else if (comp == 3.0) {
    // Rows wiped across the bar: the whole field on, dim, and the row at the scan
    // bright — the other way round on alternate bars (columns).
    float rows = cells;
    float along = mod(barN, 2.0) < 1.0 ? uv.y : uv.x;
    float row = floor(along * rows);
    float at = floor(uBarSaw * rows);
    lit = (row == at ? 1.0 : 0.45) * step(0.25, hash(vec2(row, barN + salt)));
    w = 0.9;
  } else if (comp == 4.0) {
    // Diagonal stripes, their phase stepping with the beat.
    float s = fract((p.x + p.y) * cells * 0.35 - floor(uBarSaw * 4.0) * 0.25);
    lit = step(0.5, s);
    w = 1.0;
    f = vec2(fract(s * 2.0));
  } else if (comp == 5.0) {
    // Four-fold mirror of a random field.
    lit = step(0.45, hash(cell * 2.3 + barN + salt));
  } else if (comp == 6.0) {
    // A cascade: cells come on one by one over the bar, in a random order, and all go
    // out on the next.
    lit = step(hash(cell * 3.1 + barN + salt), uBarSaw);
  } else {
    // Rings of squares running outward from the middle, one a beat.
    float d = max(abs(p.x), abs(p.y));
    float ring = fract(d * 3.0 - uBarSaw * 4.0 * 0.5);
    lit = step(0.6, ring) * step(0.3, hash(cell + barN + salt));
    w = 0.9;
  }

  // The stripes and the rings are bands, whatever the phrase's style: hollow they
  // are only lines.
  float st = (comp == 2.0 || comp == 4.0) ? 0.0 : style;
  float sh = shape(f, st, clamp(w, 0.2, 1.0));
  float field = lit * sh;

  // The beat dims the field between the hits; the kick lights it.
  float pulse = 0.55 + 0.45 * uBeatDecay;
  vec3 ink = primary;
  // Some cells in the secondary, by the bar.
  float second = step(0.7, hash(cell * 5.3 + barN * 0.5 + salt));
  ink = mix(ink, secondary, second);
  vec3 col = ink * field * pulse;

  // The snare: the field inverted, hard, for an instant.
  float inv = step(0.5, uHitSnare);
  col = mix(col, (1.0 - field) * secondary * 0.9, inv * uHitSnare);

  // The top end: thin slivers.
  float topHit = smoothstep(0.45, 1.0, uHitTop);
  float sliver = step(0.985 - 0.012 * topHit, hash(vec2(floor(uv.x * 140.0), floor(uTime * 24.0)))) * topHit;
  col += secondary * sliver;

  // The kick: the field lit in the secondary, and a thin frame.
  col = mix(col, secondary * 1.2 * field, uHitKick * 0.65);
  float edge = step(min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)), 0.006) * uHitKick;
  col += secondary * edge;
  // The downbeat: white for a flash. A hit from the hands: white over everything.
  col = mix(col, vec3(1.0) * max(field, 0.15), uDownbeat * 0.6);
  col = mix(col, vec3(1.0), uHit * 0.8);
  // A build: the frame fills with the primary at the very end.
  col += primary * smoothstep(0.9, 1.0, uDropNear) * 0.5;

  col *= uExposure * 1.4;
  fragColor = vec4(col, 1.0);
}
