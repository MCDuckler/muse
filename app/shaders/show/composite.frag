#version 460 core
#include <flutter/runtime_effect.glsl>

// The last pass, onto the screen: the trails plus the bloom, a touch of colour
// fringing at the edges, a vignette, and the strobe over everything.

uniform vec2 uResolution;
uniform float uStrobe;  // 0..1 white over everything
uniform float uFringe;  // chromatic aberration, in uv units at the corner
uniform float uFlip;
uniform sampler2D uBase;
uniform sampler2D uBloom;

out vec4 fragColor;

vec2 flip(vec2 uv) { return mix(uv, vec2(uv.x, 1.0 - uv.y), uFlip); }

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec2 c = uv - 0.5;
  vec2 off = c * uFringe * dot(c, c) * 4.0;
  vec3 base = vec3(
      texture(uBase, flip(uv + off)).r,
      texture(uBase, flip(uv)).g,
      texture(uBase, flip(uv - off)).b);
  vec3 bloom = texture(uBloom, flip(uv)).rgb;
  vec3 col = base + bloom * 0.8;
  col *= 1.0 - smoothstep(0.5, 1.1, length(c)) * 0.7;
  col = mix(col, vec3(1.0), uStrobe);
  fragColor = vec4(col, 1.0);
}
