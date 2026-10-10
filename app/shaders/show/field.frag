#version 460 core
#include <flutter/runtime_effect.glsl>

// The spike's base layer: a tunnel of noise that runs faster with the energy and
// breathes with the beat. Nothing here is final art — it is enough shader work per
// pixel (an fbm of four octaves) to stand in for a real scene while the passes
// around it are measured.

uniform vec2 uResolution;
uniform float uTime;
uniform float uBeat;    // 0..1 through the beat
uniform float uBar;     // 0..1 through the bar
uniform float uEnergy;  // 0..1
uniform float uHue;     // 0..1, turns

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash(i), b = hash(i + vec2(1, 0)), c = hash(i + vec2(0, 1)), d = hash(i + vec2(1, 1));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    a *= 0.5;
  }
  return v;
}

vec3 hsv(float h, float s, float v) {
  vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
  vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0);
  return v * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = (frag - 0.5 * uResolution) / uResolution.y;
  float r = length(uv);
  float a = atan(uv.y, uv.x);
  // The kick: a short pop at the start of every beat, bigger with the energy.
  float kick = exp(-uBeat * 9.0) * (0.3 + 0.7 * uEnergy);
  float depth = 1.0 / (r + 0.08);
  float speed = 0.6 + 2.4 * uEnergy;
  vec2 tunnel = vec2(a * 3.0 / 6.2831, depth * 0.35 - uTime * speed);
  float n = fbm(tunnel * vec2(4.0, 2.0) + vec2(0.0, kick * 0.5));
  float rings = 0.5 + 0.5 * sin(depth * 3.0 - uTime * speed * 4.0 + n * 3.0);
  float glow = smoothstep(0.0, 1.0, n * rings) * (0.5 + 0.5 * uEnergy);
  // Warmer at the top than the bottom: a picture that is not its own mirror image,
  // so a pass that samples it upside down shows (a seam across the middle).
  float hue = fract(uHue + depth * 0.02 + uBar * 0.1 + uv.y * 0.2);
  vec3 col = hsv(hue, 0.75, glow) + kick * vec3(0.9, 0.95, 1.0) * smoothstep(0.6, 0.0, r);
  col *= smoothstep(1.4, 0.3, r);
  fragColor = vec4(col, 1.0);
}
