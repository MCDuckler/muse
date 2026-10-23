#version 460 core
#include <flutter/runtime_effect.glsl>

// The murmuration's finish (ui/show/show_flock.dart), over the flock's light drawn
// bright on black. The same hand as the dancer's (dance_fx.frag), with a scope added:
//
//   1  ascii    cells of text: each cell's brightness picks a glyph from a ramp (uAtlas,
//               uGlyphs side by side, light to dense), in the ink or toward the light's
//               own colour by uTint. On the kick (uPop) the glyphs swell a little,
//               brighten and step one denser, most at the flock's middle (uPopAt);
//   2  dither   one bit: ordered (Bayer 8×8) dithering in blocks of uCell pixels, light
//               the ink, dark the paper; the kick lifts the brightness a touch;
//   3  contour  a topographic map of the flock's thickness: lines of equal brightness,
//               coloured from the ink to its echo by height, drifting with time; the kick
//               thickens them;
//   4  halftone two inks screened at two angles on dark paper; the kick knocks the
//               second out of register;
//   5  thermal  a heat camera's false colour, black through violet, red, yellow, white,
//               with a faint scan and a hot halo;
//   6  lines    a ridgeline plot: lines a cell apart, lifted by the light along them;
//   7  radar    a scope: rings and a cross in the ink round the middle, the sweep one
//               turn a bar (uSweep), the birds lit as it passes and fading behind it,
//               a little of them always;
//   8  sky      a dusk: a wash from uPaper at the top to uInk at the horizon (uTint
//               of the height down), a band of ground under it, dithered so it does
//               not band; a sun at uPopAt, uCell pixels across, flaring on the kick;
//               the picture (the birds, drawn on nothing) laid over it.
//
// The picture comes in upright (a toImageSync image), premultiplied.

uniform vec2 uResolution;
uniform float uMode;
uniform float uCell;   // ascii: a cell's height; dither: a block's side, pixels
uniform vec3 uInk;
uniform vec3 uPaper;
uniform float uTint;
uniform float uGlyphs;
uniform float uPop;    // 0..1, the kick's decay
uniform vec2 uPopAt;   // the flock's middle, 0..1
uniform float uTime;   // seconds
uniform float uSweep;  // the bar, 0..1
uniform float uWeight;  // the treatment's knobs (state/show/show_tune.dart), each a
uniform float uSpacing; // multiplier on the look as drawn; 0 is 1 (a stage that does
uniform float uHeight;  // not set them draws as it always has)
uniform float uGain;
uniform float uSize;
uniform sampler2D uImage;
uniform sampler2D uAtlas;

out vec4 fragColor;

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

// The light round px, softened over a few pixels.
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
  int mode = int(uMode + 0.5);
  if (mode == 8) {
    // sky
    vec2 uv = fc / uResolution;
    float aspect = uResolution.x / uResolution.y;
    // the horizon where the look puts it, raised or lowered by the height knob
    float hz = clamp(uTint * knob(uHeight), 0.15, 0.97);
    vec3 mid = mix(uPaper, uInk, 0.42) * 0.9;
    vec3 ground = uPaper * 0.3;
    vec3 sky;
    if (uv.y < hz) {
      float t = uv.y / hz;
      sky = t < 0.55 ? mix(uPaper, mid, t / 0.55) : mix(mid, uInk, (t - 0.55) / 0.45);
    } else {
      sky = mix(uInk * 0.45, ground, smoothstep(hz, hz + 0.05, uv.y));
    }
    vec2 d = (uv - uPopAt) * vec2(aspect, 1.0);
    float r = length(d) / (uCell / uResolution.y);
    vec3 sun = mix(uInk, vec3(1.0), 0.55 + 0.4 * uPop);
    float glow = (exp(-r * 0.6) * (0.3 + 0.3 * uPop) + exp(-r * 0.16) * (0.1 + 0.1 * uPop)) * knob(uGain);
    float disc = (1.0 - smoothstep(0.95, 1.05, r)) * (1.0 - smoothstep(hz, hz + 0.004, uv.y));
    sky += sun * glow;
    sky = mix(sky, sun, disc);
    // a hair of ordered dither: the wash is too slow for eight bits
    sky += (bayer8(fc) - 0.5) * (2.5 / 255.0);
    vec4 b = texture(uImage, uv);
    fragColor = vec4(sky * (1.0 - b.a) + b.rgb, 1.0);
    return;
  }
  if (mode == 7) {
    // radar
    vec2 uv = fc / uResolution;
    float aspect = uResolution.x / uResolution.y;
    vec2 d = (uv - 0.5) * vec2(aspect, 1.0);
    float r = length(d);
    float a = atan(d.y, d.x) / 6.2831853 + 0.5;
    float behind = fract(uSweep - a);
    // the afterglow behind the sweep, longer by the size knob; the rings' spacing and
    // the lines' weight by theirs
    float glow = exp(-behind * 4.0 / knob(uSize));
    float gap = 0.16 * knob(uSpacing);
    float wt = knob(uWeight);
    float l = lum(at(fc));
    float birds = l * (0.14 + 1.4 * glow) * (1.0 + 0.3 * uPop);
    // the rings, every 0.16 of the height, and the cross through the middle
    float ring = 0.0;
    for (int i = 1; i <= 12; i++) {
      if (float(i) * gap > 0.66) continue;
      ring += 1.0 - smoothstep(0.0, 0.003 * wt, abs(r - float(i) * gap));
    }
    float cross = (1.0 - smoothstep(0.0, 0.002 * wt, abs(d.x))) + (1.0 - smoothstep(0.0, 0.002 * wt, abs(d.y)));
    // the sweep's own line, thin and bright, a faint afterglow behind it
    float line = exp(-behind * 600.0) * smoothstep(0.01, 0.03, r) * (1.0 - smoothstep(0.62, 0.68, r));
    float inside = 1.0 - smoothstep(0.64, 0.7, r);
    vec3 col = uPaper + uInk * (birds + (ring * 0.09 + cross * 0.04) * inside * min(wt, 2.0) + line * 0.7 + glow * 0.02 * inside);
    fragColor = vec4(col, 1.0);
    return;
  }
  if (mode > 2) {
    if (mode == 3) {
      // contour
      float l = soft(fc, 2.0);
      float bands = 12.0 / knob(uSpacing);
      float h = l * bands - uTime * 0.25;
      float d = abs(fract(h) - 0.5);
      float gx = soft(fc + vec2(1.0, 0.0), 2.0) - l, gy = soft(fc + vec2(0.0, 1.0), 2.0) - l;
      float w = clamp(length(vec2(gx, gy)) * bands, 0.004, 0.25) * (1.1 + 1.6 * uPop) * knob(uWeight);
      float line = smoothstep(0.5 - w * 1.5, 0.5, d) * step(0.012, l);
      vec3 echo = vec3(uInk.b, uInk.r, uInk.g);
      vec3 ink = mix(uInk, echo, fract(floor(l * bands) * 0.37));
      fragColor = vec4(mix(uPaper, ink * (0.7 + 0.6 * l), line), 1.0);
    } else if (mode == 4) {
      // halftone, two inks
      float cell = max(3.0, uCell);
      vec2 off = vec2(1.0, -0.6) * uPop * cell * 0.6;
      float la = lum(at(fc));
      float lb = lum(at(fc - off));
      float a = screenDot(fc, cell, 0.26, la, knob(uWeight));
      float b = screenDot(fc - off, cell, 1.31, lb * 0.9, knob(uWeight));
      vec3 inkB = vec3(uInk.g, uInk.b, uInk.r) * 0.9;
      vec3 col = uPaper + uInk * a + inkB * b * (1.0 - 0.5 * a);
      fragColor = vec4(col, 1.0);
    } else if (mode == 5) {
      // thermal
      float l = soft(fc, 1.5);
      float halo = (soft(fc, 9.0 * knob(uSize)) + soft(fc, 18.0 * knob(uSize))) * 0.5;
      float t = l * 0.85 + halo * 0.45 + uPop * 0.08;
      float scan = 0.94 + 0.06 * sin(fc.y * 1.7 + uTime * 30.0);
      fragColor = vec4(thermal(t) * scan, 1.0);
    } else {
      // ridgelines, nearest first
      float gap = max(4.0, uCell);
      float amp = gap * 7.0 * knob(uHeight);
      // as many lines below as can rise to here
      int n = int(min(24.0, ceil(amp * 1.25 / gap) + 3.0));
      float wt = knob(uWeight);
      float base0 = ceil(fc.y / gap) * gap;
      vec3 col = uPaper;
      float hidden = 0.0;
      for (int i = 23; i >= 0; i--) {
        if (i >= n) continue;
        float base = base0 + float(i) * gap;
        float l = (lum(at(vec2(fc.x, base))) + lum(at(vec2(fc.x - 2.0, base))) + lum(at(vec2(fc.x + 2.0, base)))) / 3.0;
        float ridge = base - amp * l * (1.0 + 0.25 * uPop);
        float d = abs(fc.y - ridge);
        float on = (1.0 - smoothstep(0.6 * wt, (1.6 + uPop) * wt, d)) * (1.0 - hidden);
        col = mix(col, uInk * (0.55 + 0.6 * l), on);
        if (fc.y > ridge - 0.5) hidden = 1.0;
      }
      fragColor = vec4(col, 1.0);
    }
    return;
  }
  if (mode == 1) {
    // a letter's box, and the pitch they are set at (the spacing knob: room between)
    float sp = knob(uSpacing);
    vec2 cell = vec2(uCell * 0.6, uCell) * sp;
    vec2 c = floor(fc / cell);
    vec3 col = texture(uImage, (c + vec2(0.25, 0.25)) * cell / uResolution).rgb;
    col += texture(uImage, (c + vec2(0.75, 0.25)) * cell / uResolution).rgb;
    col += texture(uImage, (c + vec2(0.25, 0.75)) * cell / uResolution).rgb;
    col += texture(uImage, (c + vec2(0.75, 0.75)) * cell / uResolution).rgb;
    col *= 0.25 * knob(uGain);
    float l = lum(col);
    vec2 d = ((c + 0.5) * cell / uResolution - uPopAt) * vec2(uResolution.x / uResolution.y, 1.0);
    float pop = uPop * clamp(1.0 - length(d) * 1.4, 0.0, 1.0);
    float on = step(0.02, l);
    float idx = floor(clamp(l * 1.1 + pop * 0.12 * on, 0.0, 0.999) * uGlyphs);
    vec2 f = (fract(fc / cell) - 0.5) * sp / (1.0 + 0.22 * pop * on) + 0.5;
    float inside = step(0.0, f.x) * step(f.x, 1.0) * step(0.0, f.y) * step(f.y, 1.0);
    float g = texture(uAtlas, vec2((idx + clamp(f.x, 0.0, 1.0)) / uGlyphs, clamp(f.y, 0.0, 1.0))).a * inside;
    vec3 own = col / max(l, 0.25) * 0.85;
    vec3 ink = mix(uInk, own, uTint) * (1.0 + 0.35 * pop);
    fragColor = vec4(mix(uPaper, ink, g), 1.0);
  } else {
    float px = max(1.0, uCell);
    vec2 b = floor(fc / px);
    vec3 col = texture(uImage, (b + 0.5) * px / uResolution).rgb;
    float l = lum(col) * knob(uGain) * (1.0 + 0.12 * uPop);
    float t = bayer8(b);
    fragColor = vec4(mix(uPaper, uInk, step(t * 0.92 + 0.04, l)), 1.0);
  }
}
