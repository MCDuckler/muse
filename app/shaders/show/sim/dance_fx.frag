#version 460 core
#include <flutter/runtime_effect.glsl>

// The stylised dancer's finish (ui/show/show_dance.dart), over the picture it drew:
//
//   1  ascii    the picture in cells of text: each cell's brightness picks a glyph
//               from a ramp (uAtlas, uGlyphs side by side, light to dense), drawn in
//               the ink, or toward the picture's own colour by uTint. On the kick
//               (uPop) the glyphs swell a little, brighten and step one denser,
//               most at the middle of the figure (uPopAt), less out from it;
//   2  dither   one bit: ordered (Bayer 8×8) dithering of the picture's brightness
//               in blocks of uCell pixels, light parts the ink, dark parts the paper;
//               the kick lifts the brightness a touch.
//   3  contour  a topographic map of the picture's light: lines of equal brightness,
//               a step each, coloured from the ink to its echo by height, drifting
//               uphill with time; the kick thickens them.
//   4  halftone two inks screened at two angles (a riso print) on dark paper, each
//               dot as big as the light there; the kick knocks the second ink out of
//               register.
//   5  thermal  a heat camera: the light as a false-colour ramp, black through
//               violet, red and yellow to white, with a faint scan and a hot halo.
//   6  lines    the picture as a ridgeline plot: horizontal lines a cell apart, each
//               lifted by the light along it, the nearer hiding the farther.
//   7  fisheye  the picture (drawn through a very wide straight lens, tan of its half
//               height's angle in uTint) bent into an equidistant fisheye: uCell the
//               angle at the top edge (radians), a circle of black past what the
//               straight lens saw; the kick swells it a touch.
//
// The picture comes in upright (a toImageSync image).

uniform vec2 uResolution;
uniform float uMode;
uniform float uCell;   // ascii: a cell's height; dither: a block's side, pixels
uniform vec3 uInk;
uniform vec3 uPaper;
uniform float uTint;
uniform float uGlyphs;
uniform float uPop;    // 0..1, the kick's decay
uniform vec2 uPopAt;   // where the swell starts, 0..1
uniform float uTime;   // seconds (the contour's drift, the thermal's scan)
uniform float uCoverageOut; // 1: the alpha out is the coverage — the glyphs, the dots, the lines
                            // are the figure, the paper between them is not (under.frag);
                            // 0: alpha 1, as a canvas keeps it
uniform float uWeight;  // the treatment's knobs (state/show/show_tune.dart), each a
uniform float uSpacing; // multiplier on the look as drawn; 0 is 1 (a stage that does
uniform float uHeight;  // not set them draws as it always has)
uniform float uGain;
uniform float uSize;
uniform sampler2D uImage;
uniform sampler2D uAtlas;

out vec4 fragColor;

// The alpha a treatment writes: 1 the coverage itself (the native stage's frame);
// 2 marked, the canvas's way (a canvas keeps no coverage below 1): 254/255 where the
// figure is, whole elsewhere — under.frag's band; 0 whole everywhere.
float covOut(float c) {
  if (uCoverageOut > 1.5) return c > 0.5 ? 254.0 / 255.0 : 1.0;
  return uCoverageOut > 0.5 ? c : 1.0;
}

float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

float knob(float v) { return v > 0.0 ? v : 1.0; }

float bayer2(vec2 a) {
  a = floor(a);
  return fract(a.x / 2.0 + a.y * a.y * 0.75);
}
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
float bayer8(vec2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }

// The picture's light at px, through the gain knob.
vec3 at(vec2 px) { return texture(uImage, px / uResolution).rgb * knob(uGain); }

// The light round px, softened over a few pixels (the contour wants smooth heights).
float soft(vec2 px, float r) {
  return (lum(at(px)) * 2.0 + lum(at(px + vec2(r, 0.0))) + lum(at(px - vec2(r, 0.0))) + lum(at(px + vec2(0.0, r))) +
          lum(at(px - vec2(0.0, r)))) / 6.0;
}

vec3 thermal(float t) {
  t = clamp(t, 0.0, 1.0);
  vec3 c = mix(vec3(0.0, 0.0, 0.02), vec3(0.28, 0.02, 0.45), smoothstep(0.0, 0.22, t));
  c = mix(c, vec3(0.85, 0.08, 0.18), smoothstep(0.18, 0.45, t));
  c = mix(c, vec3(1.0, 0.62, 0.05), smoothstep(0.42, 0.7, t));
  return mix(c, vec3(1.0, 0.98, 0.85), smoothstep(0.68, 0.95, t));
}

// One ink's screen: a dot grid of side `cell` turned by `a`, each dot as big as the
// light `l` there, anti-aliased.
float screenDot(vec2 px, float cell, float a, float l, float size) {
  mat2 r = mat2(cos(a), -sin(a), sin(a), cos(a));
  vec2 q = r * px / cell;
  vec2 f = fract(q) - 0.5;
  float rad = sqrt(clamp(l, 0.0, 1.0)) * 0.62 * size;
  float d = length(f);
  float aa = 0.75 / cell;
  return 1.0 - smoothstep(rad - aa, rad + aa, d);
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  if (uMode > 6.5) {
    // fisheye: a pixel's distance from the middle is its angle off the axis
    vec2 c = (fc - 0.5 * uResolution) / (0.5 * uResolution.y);
    float r = length(c);
    float theta = r * uCell * (1.0 - 0.05 * uPop);
    float rr = tan(min(theta, 1.55)) / uTint;
    vec2 src = 0.5 * uResolution + (r > 1e-5 ? c / r : vec2(0.0)) * rr * 0.5 * uResolution.y;
    vec2 uv = src / uResolution;
    float inside = step(theta, 1.55) * step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
    // the lens's own edge: a soft dark rim, a thin bright ring of flare
    float edge = 1.0 - smoothstep(0.86, 1.0, max(abs(uv.x - 0.5), abs(uv.y - 0.5)) * 2.0);
    vec4 pix = texture(uImage, clamp(uv, 0.0, 1.0));
    vec3 col = pix.rgb * inside * edge;
    col *= 1.0 - 0.35 * smoothstep(0.4, 1.0, theta / 1.4);
    fragColor = vec4(col, uCoverageOut > 0.5 ? pix.a * inside : 1.0);
    return;
  }
  if (uMode > 2.5) {
    if (uMode < 3.5) {
      // contour
      float l = soft(fc, 2.0);
      float bands = 14.0 / knob(uSpacing);
      float h = l * bands - uTime * 0.25;
      float d = abs(fract(h) - 0.5);
      // how fast the height changes per pixel (no fwidth in SkSL), for a line of even
      // width whatever the slope
      float gx = soft(fc + vec2(1.0, 0.0), 2.0) - l, gy = soft(fc + vec2(0.0, 1.0), 2.0) - l;
      float w = clamp(length(vec2(gx, gy)) * bands, 0.004, 0.25) * (1.1 + 1.6 * uPop) * knob(uWeight);
      float line = smoothstep(0.5 - w * 1.5, 0.5, d) * step(0.015, l);
      vec3 echo = vec3(uInk.b, uInk.r, uInk.g);
      vec3 ink = mix(uInk, echo, fract(floor(l * bands) * 0.37));
      fragColor = vec4(mix(uPaper, ink * (0.7 + 0.6 * l), line), covOut(line));
    } else if (uMode < 4.5) {
      // halftone, two inks
      float cell = max(3.0, uCell);
      vec2 off = vec2(1.0, -0.6) * uPop * cell * 0.6;
      float la = lum(at(fc));
      float lb = lum(at(fc - off));
      float a = screenDot(fc, cell, 0.26, la, knob(uWeight));
      float b = screenDot(fc - off, cell, 1.31, lb * 0.9, knob(uWeight));
      vec3 inkB = vec3(uInk.g, uInk.b, uInk.r) * 0.9;
      vec3 col = uPaper + uInk * a + inkB * b * (1.0 - 0.5 * a);
      fragColor = vec4(col, covOut(clamp(a + b * (1.0 - 0.5 * a), 0.0, 1.0)));
    } else if (uMode < 5.5) {
      // thermal
      float l = soft(fc, 1.5);
      float halo = (soft(fc, 9.0 * knob(uSize)) + soft(fc, 18.0 * knob(uSize))) * 0.5;
      float t = l * 0.85 + halo * 0.45 + uPop * 0.08;
      float scan = 0.94 + 0.06 * sin(fc.y * 1.7 + uTime * 30.0);
      fragColor = vec4(thermal(t) * scan, covOut(smoothstep(0.04, 0.3, t)));
    } else {
      // ridgelines, nearest first: a line is drawn where the pixel sits on it, unless
      // a nearer line's ridge already rose over the pixel
      float gap = max(4.0, uCell);
      float amp = gap * 7.0 * knob(uHeight);
      // as many lines below as can rise to here
      int n = int(min(24.0, ceil(amp * 1.25 / gap) + 3.0));
      float wt = knob(uWeight);
      float base0 = ceil(fc.y / gap) * gap;
      vec3 col = uPaper;
      float hidden = 0.0;
      float cov = 0.0;
      for (int i = 23; i >= 0; i--) {
        if (i >= n) continue;
        float base = base0 + float(i) * gap;
        float l = (lum(at(vec2(fc.x, base))) + lum(at(vec2(fc.x - 2.0, base))) + lum(at(vec2(fc.x + 2.0, base)))) / 3.0;
        float ridge = base - amp * l * (1.0 + 0.25 * uPop);
        float d = abs(fc.y - ridge);
        float on = (1.0 - smoothstep(0.6 * wt, (1.6 + uPop) * wt, d)) * (1.0 - hidden);
        // flat lines faint, lifted ones bright: the figures stand out of a quiet sea
        col = mix(col, uInk * (0.06 + 1.1 * smoothstep(0.02, 0.5, l)), on);
        // the lifted lines are the figure; the flat sea is not
        cov = max(cov, on * smoothstep(0.02, 0.3, l));
        // below this ridge, the farther lines are behind its hill
        if (fc.y > ridge - 0.5) hidden = 1.0;
      }
      fragColor = vec4(col, covOut(cov));
    }
    return;
  }
  if (uMode < 1.5) {
    // a letter's box, and the pitch they are set at (the spacing knob: room between)
    float sp = knob(uSpacing);
    vec2 cell = vec2(uCell * 0.6, uCell) * sp;
    vec2 c = floor(fc / cell);
    // the cell's brightness: four taps inside it
    vec3 col = texture(uImage, (c + vec2(0.25, 0.25)) * cell / uResolution).rgb;
    col += texture(uImage, (c + vec2(0.75, 0.25)) * cell / uResolution).rgb;
    col += texture(uImage, (c + vec2(0.25, 0.75)) * cell / uResolution).rgb;
    col += texture(uImage, (c + vec2(0.75, 0.75)) * cell / uResolution).rgb;
    col *= 0.25 * knob(uGain);
    float l = lum(col);
    // the kick's swell, strongest near uPopAt and a moment later further out
    vec2 d = ((c + 0.5) * cell / uResolution - uPopAt) * vec2(uResolution.x / uResolution.y, 1.0);
    float pop = uPop * clamp(1.0 - length(d) * 1.4, 0.0, 1.0);
    float on = step(0.02, l);
    float idx = floor(clamp(l * 1.1 + pop * 0.12 * on, 0.0, 0.999) * uGlyphs);
    vec2 f = (fract(fc / cell) - 0.5) * sp / (1.0 + 0.22 * pop * on) + 0.5;
    float inside = step(0.0, f.x) * step(f.x, 1.0) * step(0.0, f.y) * step(f.y, 1.0);
    float g = texture(uAtlas, vec2((idx + clamp(f.x, 0.0, 1.0)) / uGlyphs, clamp(f.y, 0.0, 1.0))).a * inside;
    vec3 own = col / max(l, 0.25) * 0.85;
    vec3 ink = mix(uInk, own, uTint) * (1.0 + 0.35 * pop);
    fragColor = vec4(mix(uPaper, ink, g), covOut(g));
  } else {
    float px = max(1.0, uCell);
    vec2 b = floor(fc / px);
    vec3 col = texture(uImage, (b + 0.5) * px / uResolution).rgb;
    float l = lum(col) * knob(uGain) * (1.0 + 0.12 * uPop);
    float t = bayer8(b);
    float dot = step(t * 0.92 + 0.04, l);
    fragColor = vec4(mix(uPaper, uInk, dot), covOut(dot));
  }
}
