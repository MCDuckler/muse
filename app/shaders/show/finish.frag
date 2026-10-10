#version 460 core
#include <flutter/runtime_effect.glsl>

// The last pass, onto the screen. The scene (with its trails) and the bloom are
// summed as light — they may well be brighter than white — and brought back to the
// screen through a filmic curve, so a bright room rolls off instead of clipping to
// a flat white; a touch of colour fringing at the corners; a vignette; a fine grain
// that moves, which breaks the banding a dark gradient would show and reads as film;
// the crossfade to the next scene where one is coming; the strobe and the blackout
// over everything.

uniform vec2 uResolution;
uniform float uStrobe;       // 0..1 white over everything
uniform float uBlackout;     // 1 is black
uniform float uFringe;       // chromatic aberration at the corner, in uv
uniform float uVignette;     // 0..1
uniform float uBloomAmount;  // how much of the bloom
uniform float uMixK;         // 0 all uBase, 1 all uNext
uniform float uTime;         // for the grain
uniform float uGrain;        // 0..1, how much grain
uniform sampler2D uBase;
uniform sampler2D uBloom;
uniform sampler2D uNext;

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

// ACES, Narkowicz's fit: the curve every game uses, because it looks like film.
vec3 aces(vec3 x) {
  const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec2 c = uv - 0.5;
  float r2 = dot(c, c);
  vec2 off = c * uFringe * r2 * 4.0;
  vec3 base = vec3(
      texture(uBase, uv + off).r,
      texture(uBase, uv).g,
      texture(uBase, uv - off).b);
  vec3 next = texture(uNext, uv).rgb;
  // The scenes cross as light, eased, so neither dips dark half way.
  float k = smoothstep(0.0, 1.0, uMixK);
  base = mix(base, next, k);
  vec3 bloom = texture(uBloom, uv).rgb;
  vec3 light = base + bloom * uBloomAmount;
  // The vignette falls on the light, before the curve, so the corners darken
  // the way a lens does.
  light *= 1.0 - smoothstep(0.35, 1.0, sqrt(r2) * 1.414) * 0.75 * uVignette;
  vec3 col = aces(light * 1.1);
  // Grain, finer than a pixel of the working size and moving every frame.
  float g = hash(FlutterFragCoord().xy + fract(uTime * 7.31) * 100.0) - 0.5;
  col += g * uGrain * (0.06 + 0.06 * (1.0 - dot(col, vec3(0.333))));
  col = mix(col, vec3(1.0), uStrobe);
  col *= 1.0 - uBlackout;
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
