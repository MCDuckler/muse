#version 460 core
#include <flutter/runtime_effect.glsl>

// Ghosts: the figure as it is drawn (its style with it) copied round the middle of the
// stage like a kaleidoscope — uCount places a turn apart, every other one mirrored, so
// the copies meet edge to edge — and the original over them, whole: where the original
// is lit, it is what is seen; the ghosts fill the dark round it (each pixel the
// brighter of the original and the brightest copy there, colour and alpha together).
//
// uDiffer is how far the copies are from the original: 0 the same size, light and
// colour; toward 1 smaller (so the ring of them gathers round the middle), dimmer, each
// turned a step further round the colour wheel, and the whole ring turning slowly.

uniform vec2 uResolution;
uniform float uCount;   // the copies and the original together (2..12)
uniform float uDiffer;  // 0..1
uniform float uTime;    // seconds: the ring's slow turn
uniform float uKick;    // 0..1: the ring breathes out a touch on the kick
uniform sampler2D uImage;

out vec4 fragColor;

const float TAU = 6.2831853;

mat2 rot(float a) {
  float s = sin(a), c = cos(a);
  return mat2(c, -s, s, c);
}

// A colour turned [a] (turns) round the wheel, its lightness kept (YIQ).
vec3 hueTurn(vec3 c, float a) {
  float y = dot(c, vec3(0.299, 0.587, 0.114));
  float i = dot(c, vec3(0.596, -0.274, -0.322));
  float q = dot(c, vec3(0.211, -0.523, 0.312));
  float h = a * TAU;
  float ci = cos(h), si = sin(h);
  float i2 = i * ci - q * si;
  float q2 = i * si + q * ci;
  return vec3(y + 0.956 * i2 + 0.621 * q2, y - 0.272 * i2 - 0.647 * q2, y - 1.106 * i2 + 1.703 * q2);
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  vec2 uv = fc / uResolution;
  vec4 orig = texture(uImage, uv);
  float aspect = uResolution.x / uResolution.y;
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
  int n = int(clamp(uCount, 0.0, 12.0) + 0.5);
  float d = clamp(uDiffer, 0.0, 1.0);
  // Smaller as they differ; a breath out on the kick.
  float scale = (1.0 - 0.45 * d) * (1.0 + 0.04 * uKick);
  float light = 1.0 - 0.7 * d;
  float spin = uTime * 0.06 * d;
  // The brightest copy here, its colour and its alpha together: the stages read the
  // alpha as which pixels are the figure (a ghost of the figure is figure too).
  vec4 ghost = vec4(0.0);
  float best = -1.0;
  for (int k = 1; k < 12; k++) {
    if (k >= n) continue;
    float a = TAU * float(k) / float(n) + spin;
    vec2 q = rot(-a) * p / scale;
    // Every other copy mirrored: a kaleidoscope's, not a fan's.
    if (mod(float(k), 2.0) > 0.5) q.x = -q.x;
    vec2 s = q / vec2(aspect, 1.0) + 0.5;
    if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0) continue;
    vec4 c = texture(uImage, s);
    vec3 rgb = max(mix(c.rgb, hueTurn(c.rgb, float(k) * 0.09), d), vec3(0.0)) * light;
    float l = dot(rgb, vec3(0.299, 0.587, 0.114));
    if (l > best) {
      best = l;
      ghost = vec4(rgb, c.a);
    }
  }
  // The original wherever it is the brighter: whole, never under a ghost.
  float lo = dot(orig.rgb, vec3(0.299, 0.587, 0.114));
  fragColor = best > lo + 0.004 ? ghost : orig;
}
