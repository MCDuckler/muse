#version 460 core
#include <flutter/runtime_effect.glsl>

// The fluid as light: the dye, read with four taps so it is smooth at any size, lit
// a little where the flow is fast, with a touch of the secondary in the motion so
// the swirls read even where the dye is thin.

uniform vec2 uResolution;   // the dye's size
uniform float uGain;
uniform float uVmax;
uniform float uGlowR;
uniform float uGlowG;
uniform float uGlowB;
uniform sampler2D uDye;
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

vec3 smoothDye(vec2 uv) {
  vec2 st = uv * uResolution - 0.5;
  vec2 i = floor(st), f = st - i;
  vec2 px = 1.0 / uResolution;
  vec2 o = (i + 0.5) * px;
  vec3 a = texture(uDye, clamp(o, 0.0, 1.0)).rgb;
  vec3 b = texture(uDye, clamp(o + vec2(px.x, 0.0), 0.0, 1.0)).rgb;
  vec3 c = texture(uDye, clamp(o + vec2(0.0, px.y), 0.0, 1.0)).rgb;
  vec3 d = texture(uDye, clamp(o + px, 0.0, 1.0)).rgb;
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec3 dye = smoothDye(uv);
  vec2 v = unpack2(texture(uVel, uv).rgb) * 2.0 - 1.0;
  float speed = clamp(length(v) * 1.5, 0.0, 1.0);
  vec3 col = dye * uGain * (0.8 + 0.6 * speed);
  col += vec3(uGlowR, uGlowG, uGlowB) * speed * speed * 0.3;
  fragColor = vec4(col, 1.0);
}
