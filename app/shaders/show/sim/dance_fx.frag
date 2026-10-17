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
uniform sampler2D uImage;
uniform sampler2D uAtlas;

out vec4 fragColor;

float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

float bayer2(vec2 a) {
  a = floor(a);
  return fract(a.x / 2.0 + a.y * a.y * 0.75);
}
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
float bayer8(vec2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }

void main() {
  vec2 fc = FlutterFragCoord().xy;
  if (uMode < 1.5) {
    vec2 cell = vec2(uCell * 0.6, uCell);
    vec2 c = floor(fc / cell);
    // the cell's brightness: four taps inside it
    vec3 col = texture(uImage, (c + vec2(0.25, 0.25)) * cell / uResolution).rgb;
    col += texture(uImage, (c + vec2(0.75, 0.25)) * cell / uResolution).rgb;
    col += texture(uImage, (c + vec2(0.25, 0.75)) * cell / uResolution).rgb;
    col += texture(uImage, (c + vec2(0.75, 0.75)) * cell / uResolution).rgb;
    col *= 0.25;
    float l = lum(col);
    // the kick's swell, strongest near uPopAt and a moment later further out
    vec2 d = ((c + 0.5) * cell / uResolution - uPopAt) * vec2(uResolution.x / uResolution.y, 1.0);
    float pop = uPop * clamp(1.0 - length(d) * 1.4, 0.0, 1.0);
    float on = step(0.02, l);
    float idx = floor(clamp(l * 1.1 + pop * 0.12 * on, 0.0, 0.999) * uGlyphs);
    vec2 f = (fract(fc / cell) - 0.5) / (1.0 + 0.22 * pop * on) + 0.5;
    float inside = step(0.0, f.x) * step(f.x, 1.0) * step(0.0, f.y) * step(f.y, 1.0);
    float g = texture(uAtlas, vec2((idx + clamp(f.x, 0.0, 1.0)) / uGlyphs, clamp(f.y, 0.0, 1.0))).a * inside;
    vec3 own = col / max(l, 0.25) * 0.85;
    vec3 ink = mix(uInk, own, uTint) * (1.0 + 0.35 * pop);
    fragColor = vec4(mix(uPaper, ink, g), 1.0);
  } else {
    float px = max(1.0, uCell);
    vec2 b = floor(fc / px);
    vec3 col = texture(uImage, (b + 0.5) * px / uResolution).rgb;
    float l = lum(col) * (1.0 + 0.12 * uPop);
    float t = bayer8(b);
    fragColor = vec4(mix(uPaper, uInk, step(t * 0.92 + 0.04, l)), 1.0);
  }
}
