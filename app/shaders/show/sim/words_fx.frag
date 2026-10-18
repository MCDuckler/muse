#version 460 core
#include <flutter/runtime_effect.glsl>

// The words' finish (ui/show/show_words.dart), over the two pictures the sim drew —
// the glyphs in colour on nothing (uGlyphs: the alpha is the letters' coverage) and
// the plates (uPlates: black where the ground must not show, a panel, a band):
//
//   * a glitch: a few bands of rows slid sideways for the instant a snare lasts;
//   * a chromatic split: the reds and the blues pulled apart on a drop's kick;
//   * a wave through a hook line in a drop;
//   * a wipe: a new line uncovered from the left, its edge lit;
//   * a halo: the coverage dilated into a soft dark rim round every letter, so the
//     type reads over any MilkDrop preset; where the ground is MilkDrop in contrast
//     (uSoft) the rim fades into what the blend would show, and the join is unseen;
//   * the stencil (mode 2): every pixel is the figure — black paper, and inside the
//     letters the ground itself (uGround, zoomed a touch on the beat), or a flowing
//     gradient of the palette where there is none; the unsung letters dimmer; a rim
//     of the accent on the beat.
//
// And it decides which pixels are the figure. The blend (under.frag, coverage 0)
// reads a pixel at alpha 254/255 as the figure, shown as drawn, and any other as the
// paper, blended with the ground the rig's way: so a letter and its halo and a plate
// go out at 254/255, and the paper between them at 1 and black, which under MilkDrop
// in contrast is the preset itself.
//
// uMode: 1 poster, 2 stencil, 3 typewriter, 4 kinetic, 5 ribbon.

uniform vec2 uResolution;
uniform float uMode;
uniform float uTime;
uniform float uKick;
uniform float uSnare;
uniform float uTop;
uniform float uLow;
uniform float uBeat;
uniform float uBarSaw;
uniform float uHalo;       // the rim's reach, pixels
uniform float uHaloK;      // how much of it, 0..1
uniform float uSplit;      // the split, pixels
uniform float uGlitch;     // 0..1
uniform float uWave;       // 0..1
uniform float uWipe;       // -1 none; else the wipe's edge, 0..1 of the width
uniform float uHasGround;  // 1: uGround holds the ground's picture
uniform float uSoft;       // 1: the ground is MilkDrop in contrast — the halo may fade into it
uniform float uFit;        // the ground picture's aspect (16/9), 0 for the stage's own size
uniform vec3 uInk;         // the accent: the stencil's rim, the gradient's first colour
uniform vec3 uInk2;        // the gradient's second
uniform vec3 uPaper;       // the paper inside the figure
uniform float uDim;        // the stencil: how much of the ground in an unsung letter
uniform sampler2D uGlyphs;
uniform sampler2D uPlates;
uniform sampler2D uGround;

out vec4 fragColor;

const float FIGURE = 254.0 / 255.0;

float hash(float x) { return fract(sin(x * 12.9898) * 43758.5453); }

// The ground, filled and cropped to the stage where its aspect is not the stage's.
vec3 groundAt(vec2 uv) {
  if (uFit > 0.5) {
    float stage = uResolution.x / uResolution.y;
    vec2 fit = stage > uFit ? vec2(1.0, uFit / stage) : vec2(stage / uFit, 1.0);
    uv = clamp((uv - 0.5) * fit + 0.5, 0.0, 1.0);
  }
  return texture(uGround, uv).rgb;
}

// Where there is no ground to show: a slow river of the two colours.
vec3 river(vec2 uv) {
  float a = sin(uv.x * 3.1 + uv.y * 1.7 + uTime * 0.6) * 0.5 + 0.5;
  float b = sin(uv.x * 5.3 - uv.y * 2.9 - uTime * 0.9 + uLow * 2.0) * 0.5 + 0.5;
  vec3 c = mix(uInk, uInk2, a);
  return c * (0.55 + 0.45 * b) + vec3(0.12) * pow(b, 6.0);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  int mode = int(uMode + 0.5);

  // The glitch: a few bands of rows pushed sideways, which bands and how far by the
  // moment's hash, so it is never the same slip twice.
  vec2 p = uv;
  if (uGlitch > 0.001) {
    float band = floor(uv.y * 26.0);
    float seed = floor(uTime * 23.0);
    float on = step(0.7, hash(band * 7.13 + seed));
    p.x += on * (hash(band * 3.7 + seed * 1.3) - 0.5) * 0.18 * uGlitch;
  }
  if (uWave > 0.001) p.y += sin(uv.x * 9.0 + uTime * 5.0) * 0.012 * uWave;

  vec4 g = texture(uGlyphs, p);
  if (uSplit > 0.01) {
    vec2 s = vec2(uSplit / uResolution.x, 0.0);
    vec4 gr = texture(uGlyphs, p + s);
    vec4 gb = texture(uGlyphs, p - s);
    g = vec4(gr.r, g.g, gb.b, max(g.a, max(gr.a, gb.a)));
  }

  // The wipe: the glyphs shown left of the edge, the edge a line of the accent.
  float wipe = 1.0;
  float edge = 0.0;
  if (uWipe >= 0.0) {
    wipe = 1.0 - smoothstep(uWipe - 0.005, uWipe + 0.005, uv.x);
    edge = (1.0 - smoothstep(0.0, 0.02, abs(uv.x - uWipe))) * step(0.001, g.a + texture(uGlyphs, vec2(uWipe, p.y)).a * 0.0);
  }
  float cov = g.a * wipe;
  vec3 col = g.rgb * wipe;

  if (mode == 2) {
    // The stencil: the ground through the letters, the lit ones whole, the unsung
    // ones dimmed; the paper black; a rim of the accent that breathes with the beat.
    vec2 z = (uv - 0.5) * (0.94 + 0.04 * uBeat - 0.02 * uKick) + 0.5 + vec2(sin(uTime * 0.17), cos(uTime * 0.13)) * 0.01;
    vec3 inside = uHasGround > 0.5 ? groundAt(z) : river(uv);
    // Lit, from the colour the letter was drawn in (white whole, grey for unsung).
    float lit = cov > 0.002 ? clamp(g.r / max(g.a, 0.002), 0.0, 1.0) : 0.0;
    float show = mix(uDim, 1.0, smoothstep(0.3, 0.95, lit));
    vec2 px = 1.6 / uResolution;
    float rim = 0.0;
    rim = max(rim, abs(cov - texture(uGlyphs, p + vec2(px.x, 0.0)).a));
    rim = max(rim, abs(cov - texture(uGlyphs, p - vec2(px.x, 0.0)).a));
    rim = max(rim, abs(cov - texture(uGlyphs, p + vec2(0.0, px.y)).a));
    rim = max(rim, abs(cov - texture(uGlyphs, p - vec2(0.0, px.y)).a));
    vec3 c = uPaper * (1.0 - cov) + inside * cov * show * (0.85 + 0.35 * uBeat);
    c += uInk * rim * (0.25 + 0.75 * uBeat) * (0.4 + 0.6 * lit);
    fragColor = vec4(c, FIGURE);
    return;
  }

  // The halo: the coverage reached out to a rim round the letters, soft.
  // Three rings of ten taps: sparser, and a small word's halo came out as shifted
  // copies of it rather than a rim.
  float halo = 0.0;
  if (uHaloK > 0.001 && uHalo > 0.1) {
    vec2 r = uHalo / uResolution;
    for (int i = 0; i < 10; i++) {
      float a = float(i) * 0.6283185;
      vec2 o = vec2(cos(a), sin(a)) * r;
      vec2 o2 = vec2(cos(a + 0.31), sin(a + 0.31)) * r * 2.0;
      vec2 o3 = vec2(cos(a + 0.15), sin(a + 0.15)) * r * 3.0;
      halo = max(halo, texture(uGlyphs, p + o).a);
      halo = max(halo, texture(uGlyphs, p + o2).a * 0.6);
      halo = max(halo, texture(uGlyphs, p + o3).a * 0.3);
    }
    halo *= uHaloK * wipe;
  }
  vec4 pl = texture(uPlates, p);
  float plate = max(pl.a, halo);
  float fig = max(step(0.5, cov), step(0.2, plate));

  // What the paper would show under MilkDrop in contrast (the paper is black: the
  // preset itself, at 1.2), for the halo's outer rim to fade into.
  vec3 back = vec3(0.0);
  if (uSoft > 0.5 && uHasGround > 0.5) back = groundAt(uv) * 1.2;
  vec3 plateCol = mix(back, uPaper, smoothstep(0.2, 0.75, plate));
  vec3 outc = plateCol * (1.0 - cov) + col + uInk * edge * 0.8;
  fragColor = vec4(outc * fig, fig > 0.5 ? FIGURE : 1.0);
}
