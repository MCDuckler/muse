#version 460 core
#include <flutter/runtime_effect.glsl>

// One direction of a separable blur, for the bloom: run once across with a bright
// threshold, once down without. Thirteen taps, spread wide — the bloom is drawn at a
// quarter of the working size, so a wide, soft glow costs little.

uniform vec2 uResolution;
uniform vec2 uDir;        // (1,0) or (0,1), in texels
uniform float uThreshold; // below this a pixel adds nothing (the across pass)
uniform float uSpread;    // texels between taps

uniform sampler2D uSrc;

out vec4 fragColor;

vec3 bright(vec3 c) {
  float l = dot(c, vec3(0.299, 0.587, 0.114));
  // A soft knee: what is just under the threshold still glows a little.
  return c * smoothstep(uThreshold - 0.2, uThreshold + 0.25, l);
}

vec3 tap(vec2 uv) { return bright(texture(uSrc, clamp(uv, 0.0, 1.0)).rgb); }

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec2 step = uDir * uSpread / uResolution;
  // Gaussian weights for thirteen taps, spelt out: SkSL has no array initialisers.
  vec3 acc = tap(uv) * 0.1964;
  acc += (tap(uv + step * 1.0) + tap(uv - step * 1.0)) * 0.1747;
  acc += (tap(uv + step * 2.0) + tap(uv - step * 2.0)) * 0.1210;
  acc += (tap(uv + step * 3.0) + tap(uv - step * 3.0)) * 0.0654;
  acc += (tap(uv + step * 4.0) + tap(uv - step * 4.0)) * 0.0276;
  acc += (tap(uv + step * 5.0) + tap(uv - step * 5.0)) * 0.0091;
  acc += (tap(uv + step * 6.0) + tap(uv - step * 6.0)) * 0.0023;
  fragColor = vec4(acc, 1.0);
}
