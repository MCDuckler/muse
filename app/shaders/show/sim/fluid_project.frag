#version 460 core
#include <flutter/runtime_effect.glsl>

// Step four: the pressure's gradient taken off the velocity, which leaves a flow
// that neither piles up nor thins out — the swirls come from this.

uniform vec2 uResolution;
uniform float uVmax;
uniform sampler2D uVel;
uniform sampler2D uPressure;

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

float p(vec2 uv) { return unpack1(texture(uPressure, clamp(uv, 0.0, 1.0)).rgb) * 2.0 - 1.0; }

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec2 px = 1.0 / uResolution;
  vec2 v = (unpack2(texture(uVel, uv).rgb) * 2.0 - 1.0) * uVmax;
  vec2 grad = vec2(p(uv + vec2(px.x, 0.0)) - p(uv - vec2(px.x, 0.0)), p(uv + vec2(0.0, px.y)) - p(uv - vec2(0.0, px.y)));
  v -= grad * 0.5 * uVmax;
  fragColor = vec4(pack2(v / uVmax * 0.5 + 0.5), 1.0);
}
