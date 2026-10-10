#version 460 core
#include <flutter/runtime_effect.glsl>

// The fluid, step one: everything carried along by the velocity field (semi-
// Lagrangian: each texel reads where it came from, with four taps by hand so the
// read is smooth whatever the sampler does). Mode 0 moves the velocity itself and
// adds the forces — a push where the kick landed, a slow swirl from noise, damping.
// Mode 1 moves the dye and pours more in where the push was.

uniform vec2 uResolution;
uniform float uDt;
uniform float uDissipation;
uniform float uMode;      // 0 velocity, 1 dye
uniform float uVmax;      // texels a second at full scale
uniform float uForceX;    // where the push is, in uv
uniform float uForceY;
uniform float uForceDX;   // which way, and how hard (texels a second)
uniform float uForceDY;
uniform float uForceR;    // how wide, in uv
uniform float uForceK;    // 0..1, how much of it this frame
uniform float uSwirl;     // the noise field's strength
uniform float uTime;
uniform float uInjR;      // the dye poured in
uniform float uInjG;
uniform float uInjB;
uniform sampler2D uVel;
uniform sampler2D uSrc;

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

// Four taps, weighted: bilinear by hand, in texel space.
vec3 smoothSrc(vec2 uv) {
  vec2 st = uv * uResolution - 0.5;
  vec2 i = floor(st), f = st - i;
  vec2 px = 1.0 / uResolution;
  vec2 o = (i + 0.5) * px;
  vec3 a = texture(uSrc, clamp(o, 0.0, 1.0)).rgb;
  vec3 b = texture(uSrc, clamp(o + vec2(px.x, 0.0), 0.0, 1.0)).rgb;
  vec3 c = texture(uSrc, clamp(o + vec2(0.0, px.y), 0.0, 1.0)).rgb;
  vec3 d = texture(uSrc, clamp(o + px, 0.0, 1.0)).rgb;
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec2 v = vel(uv);
  vec2 back = uv - v * uDt / uResolution;
  vec2 d = uv - vec2(uForceX, uForceY);
  d.x *= uResolution.x / uResolution.y;
  float push = exp(-dot(d, d) / (uForceR * uForceR)) * uForceK;
  if (uMode < 0.5) {
    // Velocity: four taps of the packed value decode badly where the bytes wrap, so
    // the four taps are decoded first and mixed after.
    vec2 st = uv * uResolution - 0.5;
    vec2 i = floor(st), f = st - i;
    vec2 px = 1.0 / uResolution;
    vec2 o = (i + 0.5) * px;
    vec2 bk = back * uResolution - 0.5;
    vec2 bi = floor(bk), bf = bk - bi;
    vec2 bo = (bi + 0.5) * px;
    vec2 a = (unpack2(texture(uSrc, clamp(bo, 0.0, 1.0)).rgb) * 2.0 - 1.0);
    vec2 b = (unpack2(texture(uSrc, clamp(bo + vec2(px.x, 0.0), 0.0, 1.0)).rgb) * 2.0 - 1.0);
    vec2 c = (unpack2(texture(uSrc, clamp(bo + vec2(0.0, px.y), 0.0, 1.0)).rgb) * 2.0 - 1.0);
    vec2 e = (unpack2(texture(uSrc, clamp(bo + px, 0.0, 1.0)).rgb) * 2.0 - 1.0);
    vec2 moved = mix(mix(a, b, bf.x), mix(c, e, bf.x), bf.y) * uVmax;
    moved *= uDissipation;
    moved += vec2(uForceDX, uForceDY) * push;
    // A slow swirl that is never still, so the room keeps turning between hits.
    vec2 q = uv * 3.0 + uTime * 0.07;
    moved += vec2(sin(q.y * 2.1 + uTime * 0.3), cos(q.x * 1.7 - uTime * 0.2)) * uSwirl * uDt;
    // The walls: the flow dies at the edge.
    float wall = smoothstep(0.0, 0.03, uv.x) * smoothstep(1.0, 0.97, uv.x) * smoothstep(0.0, 0.03, uv.y) * smoothstep(1.0, 0.97, uv.y);
    moved *= wall;
    fragColor = vec4(pack2(moved / uVmax * 0.5 + 0.5), 1.0);
  } else {
    vec3 dye = smoothSrc(back) * uDissipation;
    dye += vec3(uInjR, uInjG, uInjB) * push;
    fragColor = vec4(clamp(dye, 0.0, 1.0), 1.0);
  }
}
