#version 460 core
#include <flutter/runtime_effect.glsl>

// Step two: how much each texel's neighbours flow apart (the divergence), which
// the pressure will have to undo. Kept as 0.5 + div / (4 uVmax), in 24 bits.

uniform vec2 uResolution;
uniform float uVmax;
uniform sampler2D uVel;

out vec4 fragColor;

vec3 pack2(vec2 v) {
  v = clamp(v, 0.0, 1.0);
  float x = floor(v.x * 4095.0), y = floor(v.y * 4095.0);
  float xh = floor(x / 16.0), xl = x - xh * 16.0;
  float yh = floor(y / 256.0), yl = y - yh * 256.0;
  return vec3(xh, xl * 16.0 + yh, yl) / 255.0;
}
vec2 unpack2(vec3 c) {
  float r = floor(c.r * 255.0 + 0.5), g = floor(c.g * 255.0 + 0.5), b = floor(c.b * 255.0 + 0.5);
  float gh = floor(g / 16.0), gl = g - gh * 16.0;
  return vec2(r * 16.0 + gh, gl * 256.0 + b) / 4095.0;
}
vec3 pack1(float v) {
  v = clamp(v, 0.0, 1.0);
  float x = floor(v * 16777215.0);
  float r = floor(x / 65536.0);
  float g = floor((x - r * 65536.0) / 256.0);
  float b = x - r * 65536.0 - g * 256.0;
  return vec3(r, g, b) / 255.0;
}
float unpack1(vec3 c) {
  vec3 x = floor(c * 255.0 + 0.5);
  return (x.r * 65536.0 + x.g * 256.0 + x.b) / 16777215.0;
}

vec2 vel(vec2 uv) { return (unpack2(texture(uVel, clamp(uv, 0.0, 1.0)).rgb) * 2.0 - 1.0) * uVmax; }

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec2 px = 1.0 / uResolution;
  float div = 0.5 * ((vel(uv + vec2(px.x, 0.0)).x - vel(uv - vec2(px.x, 0.0)).x)
      + (vel(uv + vec2(0.0, px.y)).y - vel(uv - vec2(0.0, px.y)).y));
  fragColor = vec4(pack1(0.5 + div / (4.0 * uVmax)), 1.0);
}
