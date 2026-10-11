#version 460 core
#include <flutter/runtime_effect.glsl>

// The meme edit's finish (ui/show/show_meme.dart): what a phone editor does to a
// clip after the cut, over the picture the edit composed. In the order an editor
// stacks them:
//
//   glitch    rows of the picture shoved sideways (a datamosh, on a hit);
//   bulge     the middle swollen, as a "bass boosted" edit does on the kick;
//   pixel     blocks that resolve (the crunch on a cut);
//   blur      a zoom blur from a point and a smear along a line (the whip on a cut);
//   split     red and blue pulled apart (the snare);
//   fry       deep-fried: sharpened, oversaturated, contrasty, orange, posterised,
//             with JPEG blocks crawling in it;
//   mono      black and white, hard contrast (the phonk edit);
//   pastel    blacks lifted, shadows to violet and lights to pink (the vaporwave);
//   scan      scan lines and a VHS tracking band wandering up the frame;
//   night     a trail camera's infrared: grey-green, noisy, scan-lined;
//   tint      a wash of one colour (the build's alarm red);
//   impact    an anime impact frame: black and white, inverted, hard;
//   invert, vignette, flash.
//
// Everything is 0 when off. The picture comes in upright (a toImageSync image).

uniform vec2 uResolution;
uniform float uTime;
uniform float uFry;
uniform float uSplit;       // share of the width
uniform float uSplitAngle;  // radians
uniform float uBlur;        // zoom blur, share of the distance to uBlurAt
uniform vec2 uBlurAt;       // 0..1
uniform vec2 uSmear;        // directional smear, in uv
uniform float uPixel;       // block size in pixels; under 1.5 is off
uniform float uImpact;
uniform float uInvert;
uniform float uNight;
uniform float uFlash;
uniform float uTintHue;
uniform float uTint;
uniform float uVignette;
uniform float uBulge;
uniform float uMono;
uniform float uPastel;
uniform float uScan;
uniform float uGlitch;
uniform sampler2D uImage;

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

vec3 grab(vec2 uv) {
  if (uPixel > 1.5) {
    vec2 px = uPixel / uResolution;
    uv = (floor(uv / px) + 0.5) * px;
  }
  uv = clamp(uv, vec2(0.0), vec2(1.0));
  if (uSplit < 0.0005) return texture(uImage, uv).rgb;
  vec2 d = vec2(cos(uSplitAngle), sin(uSplitAngle)) * uSplit;
  return vec3(texture(uImage, clamp(uv + d, vec2(0.0), vec2(1.0))).r,
              texture(uImage, uv).g,
              texture(uImage, clamp(uv - d, vec2(0.0), vec2(1.0))).b);
}

float luma(vec3 c) {
  return dot(c, vec3(0.299, 0.587, 0.114));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uResolution;
  float aspect = uResolution.x / uResolution.y;

  // The glitch: bands of rows shoved left or right, a few of them, changing fast.
  if (uGlitch > 0.001) {
    float band = floor(uv.y * 14.0 + hash(vec2(floor(uTime * 24.0), 3.0)) * 14.0);
    float on = step(1.0 - uGlitch * 0.5, hash(vec2(band, floor(uTime * 24.0))));
    uv.x += on * (hash(vec2(band, floor(uTime * 24.0) + 7.0)) - 0.5) * 0.25 * uGlitch;
    uv.x = fract(uv.x);
  }

  // The tracking band: a stripe wandering up the frame, the rows in it pulled aside.
  if (uScan > 0.001) {
    float y = fract(uTime * 0.23);
    float band = smoothstep(0.03, 0.0, abs(uv.y - y)) * uScan;
    uv.x += band * (hash(vec2(floor(uv.y * 200.0), floor(uTime * 30.0))) - 0.5) * 0.08;
  }

  // The bulge: the middle magnified, falling off to nothing at the edge of a disc.
  if (uBulge > 0.001) {
    vec2 d = uv - 0.5;
    float r = length(d * vec2(aspect, 1.0));
    float k = 1.0 - uBulge * 0.45 * pow(max(0.0, 1.0 - r / 0.75), 2.0);
    uv = 0.5 + d * k;
  }

  vec3 col;
  if (uBlur + abs(uSmear.x) + abs(uSmear.y) < 0.0008) {
    col = grab(uv);
  } else {
    col = vec3(0.0);
    float total = 0.0;
    for (int i = 0; i < 10; i++) {
      float t = float(i) / 9.0;
      vec2 o = (uv - uBlurAt) * uBlur * t + uSmear * (t - 0.5);
      float w = 1.0 - 0.5 * t;
      col += grab(uv - o) * w;
      total += w;
    }
    col /= total;
  }

  // Deep-fried.
  if (uFry > 0.005) {
    vec2 px = 1.5 / uResolution;
    vec3 nb = (texture(uImage, clamp(uv + vec2(px.x, 0.0), vec2(0.0), vec2(1.0))).rgb +
               texture(uImage, clamp(uv - vec2(px.x, 0.0), vec2(0.0), vec2(1.0))).rgb +
               texture(uImage, clamp(uv + vec2(0.0, px.y), vec2(0.0), vec2(1.0))).rgb +
               texture(uImage, clamp(uv - vec2(0.0, px.y), vec2(0.0), vec2(1.0))).rgb) * 0.25;
    col += (col - nb) * uFry * 3.0;
    float l = luma(col);
    col = mix(vec3(l), col, 1.0 + uFry * 1.9);
    col = (col - 0.5) * (1.0 + uFry * 0.8) + 0.5 + uFry * 0.05;
    col *= vec3(1.0 + 0.22 * uFry, 1.0 + 0.04 * uFry, 1.0 - 0.32 * uFry);
    col = clamp(col, 0.0, 1.0);
    float levels = mix(24.0, 5.0, uFry);
    vec3 poster = floor(col * levels + 0.5) / levels;
    col = mix(col, poster, smoothstep(0.25, 0.9, uFry));
    vec2 block = floor(frag / 8.0);
    col += (hash(block + floor(uTime * 12.0)) - 0.5) * 0.09 * uFry;
  }

  // Black and white, hard: the phonk edit's look.
  if (uMono > 0.005) {
    float l = luma(col);
    l = clamp((l - 0.45) * (1.0 + 0.7 * uMono) + 0.5, 0.0, 1.0);
    l += (hash(frag + fract(uTime * 5.3) * 97.0) - 0.5) * 0.1 * uMono;
    col = mix(col, vec3(l), uMono);
  }

  // The vaporwave: blacks lifted to violet, whites to pink, a cyan cast in the middle.
  if (uPastel > 0.005) {
    vec3 shadow = vec3(0.24, 0.08, 0.42), mid = vec3(0.35, 0.85, 0.95), light = vec3(1.0, 0.72, 0.88);
    float l = luma(col);
    vec3 graded = l < 0.5 ? mix(shadow, mid, l * 2.0) : mix(mid, light, (l - 0.5) * 2.0);
    col = mix(col, mix(col, graded, 0.62), uPastel);
  }

  // Scan lines.
  if (uScan > 0.005) {
    col *= 1.0 - uScan * 0.22 * (0.5 + 0.5 * sin(frag.y * 3.14159));
    col += (hash(frag + fract(uTime * 3.7) * 61.0) - 0.5) * 0.08 * uScan;
  }

  // The trail camera at night.
  if (uNight > 0.005) {
    float l = pow(clamp(luma(col), 0.0, 1.0), 0.75) * 1.12;
    vec3 ir = mix(vec3(l), vec3(0.78, 1.0, 0.82) * l, 0.55);
    ir += (hash(frag + fract(uTime * 9.17) * 311.0) - 0.5) * 0.16;
    ir *= 0.93 + 0.07 * sin(frag.y * 1.7 + uTime * 30.0);
    col = mix(col, ir, uNight);
  }

  if (uTint > 0.005) {
    vec3 tc = hsl(uTintHue, 1.0, 0.5);
    col = mix(col, luma(col) * tc * 1.9, uTint);
  }

  if (uImpact > 0.005) {
    float b = smoothstep(0.42, 0.5, luma(col));
    col = mix(col, vec3(1.0 - b), uImpact);
  }

  col = mix(col, 1.0 - col, uInvert);
  col *= 1.0 - uVignette * smoothstep(0.35, 0.95, length((uv - 0.5) * vec2(aspect, 1.0)) / aspect * 1.6);
  col = mix(col, vec3(1.0), clamp(uFlash, 0.0, 1.0));
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
