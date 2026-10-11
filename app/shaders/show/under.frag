#version 460 core
#include <flutter/runtime_effect.glsl>

// Under: a scene's picture put together with MilkDrop's beneath it, one of several
// ways (uMode) — so the two read as two things, not a muddle:
//
//   0 add       the scene's light added over MilkDrop (the plain way)
//   1 screen    screened: neither can blow the other out
//   2 dim       MilkDrop at a third, the scene on top in full
//   3 window    the scene is a window: MilkDrop shows through its bright parts
//   4 mask      MilkDrop only where the scene is dark; the scene cuts it out
//   5 frame     the scene in the middle, MilkDrop as the frame round it, breathing
//               with the kick
//   6 bands     the stage in vertical bands, MilkDrop and the scene by turns,
//               stepping with the beat
//   7 flip      the scene over MilkDrop — and MilkDrop over the scene on each kick
//   8 outline   MilkDrop's edges only, as lines under the scene
//   9 contrast  the difference of the two: where they agree is dark

uniform vec2 uResolution;
uniform float uMode;
uniform float uBeatDecay;
uniform float uBarSaw;
uniform float uHitKick;
uniform float uTime;
uniform sampler2D uScene;
uniform sampler2D uMilk;

out vec4 fragColor;

float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

// MilkDrop's picture is 16:9; the stage may not be: filled, cropped.
vec2 milkAt(vec2 uv) {
  float stage = uResolution.x / uResolution.y;
  float pic = 16.0 / 9.0;
  vec2 fit = stage > pic ? vec2(1.0, pic / stage) : vec2(stage / pic, 1.0);
  return clamp((uv - 0.5) * fit + 0.5, 0.0, 1.0);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec3 s = texture(uScene, uv).rgb;
  vec3 m = texture(uMilk, milkAt(uv)).rgb;
  float ls = lum(s);
  int mode = int(uMode + 0.5);
  vec3 col;
  if (mode == 1) {
    col = 1.0 - (1.0 - s) * (1.0 - m);
  } else if (mode == 2) {
    col = s + m * 0.33;
  } else if (mode == 3) {
    col = m * smoothstep(0.03, 0.5, ls) * 1.3 + s * 0.15;
  } else if (mode == 4) {
    col = m * (1.0 - smoothstep(0.04, 0.35, ls)) + s;
  } else if (mode == 5) {
    float inset = 0.16 - 0.03 * uHitKick;
    vec2 d = abs(uv - 0.5);
    float inside = 1.0 - smoothstep(0.5 - inset - 0.01, 0.5 - inset, max(d.x, d.y));
    // The scene drawn into the middle, smaller.
    vec2 inner = (uv - 0.5) / (1.0 - 2.0 * inset) + 0.5;
    vec3 si = texture(uScene, clamp(inner, 0.0, 1.0)).rgb;
    col = mix(m, si, inside);
  } else if (mode == 6) {
    float bands = 6.0;
    float band = floor(uv.x * bands + floor(uBarSaw * 4.0));
    float which = mod(band, 2.0);
    // A soft seam between bands.
    float f = fract(uv.x * bands);
    float seam = smoothstep(0.0, 0.03, f) * smoothstep(1.0, 0.97, f);
    col = mix(m, s, which) * (0.85 + 0.15 * seam) + mix(s, m, which) * 0.08;
  } else if (mode == 7) {
    vec3 sceneOver = s + m * 0.3;
    vec3 milkOver = m + s * 0.3;
    col = mix(sceneOver, milkOver, uHitKick);
  } else if (mode == 8) {
    vec2 px = 1.5 / uResolution;
    float l0 = lum(texture(uMilk, milkAt(uv + vec2(px.x, 0.0))).rgb) - lum(texture(uMilk, milkAt(uv - vec2(px.x, 0.0))).rgb);
    float l1 = lum(texture(uMilk, milkAt(uv + vec2(0.0, px.y))).rgb) - lum(texture(uMilk, milkAt(uv - vec2(0.0, px.y))).rgb);
    float edge = clamp(length(vec2(l0, l1)) * 6.0, 0.0, 1.0);
    vec3 tint = normalize(m + 0.05) * 1.2;
    col = tint * edge * (0.6 + 0.4 * uBeatDecay) + s;
  } else if (mode == 9) {
    col = abs(s - m) * 1.2;
  } else {
    col = s + m;
  }
  fragColor = vec4(col, 1.0);
}
