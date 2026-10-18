#version 460 core
#include <flutter/runtime_effect.glsl>

// The blend: the figure layer put together with the ground under it, the rig's way
// (lib/src/state/show/show_rig.dart, RigBlend). The figure layer has two kinds of
// pixel — the figure itself (a body, a glyph, a bird) and its own backdrop (the
// paper, the floor, the wash a scene drew behind it) — and the two may sit on the
// ground differently.
//
// uMode, the way the backdrop sits on the ground (GroundMode, in its order):
//   0 through   dropped: the ground shows there
//   1 over      as drawn: the ground is hidden
//   2 add       the figure layer's light added over the ground (the plain way)
//   3 screen    screened: neither can blow the other out
//   4 dim       the ground at a third, the layer on top in full
//   5 window    the layer is a window: the ground shows through its bright parts
//   6 mask      the ground only where the layer is dark; the layer cuts it out
//   7 frame     the layer in the middle, the ground as the frame round it, breathing
//               with the kick
//   8 bands     the stage in vertical bands, the ground and the layer by turns,
//               stepping with the beat
//   9 flip      the layer over the ground — and the ground over the layer on each kick
//  10 outline   the ground's edges only, as lines under the layer
//  11 contrast  the difference of the two: where they agree is dark
//
// uFigureMode: 0 the figure's own pixels go over the ground as drawn; 1 they are
// blended like the backdrop.
// uCoverage says which pixels are the figure: 0 — the ones drawn at alpha 254/255
// (a canvas keeps no coverage under 1, so the plain dancers draw their bodies so);
// 1 — the alpha is the coverage (a treatment's glyphs, the birds).
// uStrength: how much of the blend, 0..1 (0 is the figure layer as drawn).
// uGroundFit: the ground picture's own aspect (16/9 for MilkDrop's or the camera's,
// 1 for a cover) where it is to be filled and cropped to the stage; 0 where it is the
// stage's own size already.
// uGroundDim: how much of the ground, 0..1.

uniform vec2 uResolution;
uniform float uMode;
uniform float uBeatDecay;
uniform float uBarSaw;
uniform float uHitKick;
uniform float uTime;
uniform float uFigureMode;
uniform float uCoverage;
uniform float uStrength;
uniform float uGroundFit;
uniform float uGroundDim;
uniform sampler2D uScene;
uniform sampler2D uGround;

out vec4 fragColor;

float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

// MilkDrop's picture is 16:9; the stage may not be: filled, cropped.
vec2 groundAt(vec2 uv) {
  if (uGroundFit < 0.5) return uv;
  float stage = uResolution.x / uResolution.y;
  float pic = uGroundFit;
  vec2 fit = stage > pic ? vec2(1.0, pic / stage) : vec2(stage / pic, 1.0);
  return clamp((uv - 0.5) * fit + 0.5, 0.0, 1.0);
}

vec3 ground(vec2 uv) { return texture(uGround, groundAt(uv)).rgb * uGroundDim; }

// The backdrop's way: [s] the layer's pixel, [m] the ground's.
vec3 blendOf(int mode, vec3 s, vec3 m, vec2 uv) {
  float ls = lum(s);
  if (mode == 0) return m;
  if (mode == 1) return s;
  if (mode == 3) return 1.0 - (1.0 - s) * (1.0 - m);
  if (mode == 4) return s + m * 0.33;
  if (mode == 5) return m * smoothstep(0.03, 0.5, ls) * 1.3 + s * 0.15;
  if (mode == 6) return m * (1.0 - smoothstep(0.04, 0.35, ls)) + s;
  if (mode == 7) {
    float inset = 0.16 - 0.03 * uHitKick;
    vec2 d = abs(uv - 0.5);
    float inside = 1.0 - smoothstep(0.5 - inset - 0.01, 0.5 - inset, max(d.x, d.y));
    // The layer drawn into the middle, smaller.
    vec2 inner = (uv - 0.5) / (1.0 - 2.0 * inset) + 0.5;
    vec3 si = texture(uScene, clamp(inner, 0.0, 1.0)).rgb;
    return mix(m, si, inside);
  }
  if (mode == 8) {
    float bands = 6.0;
    float band = floor(uv.x * bands + floor(uBarSaw * 4.0));
    float which = mod(band, 2.0);
    // A soft seam between bands.
    float f = fract(uv.x * bands);
    float seam = smoothstep(0.0, 0.03, f) * smoothstep(1.0, 0.97, f);
    return mix(m, s, which) * (0.85 + 0.15 * seam) + mix(s, m, which) * 0.08;
  }
  if (mode == 9) {
    vec3 sceneOver = s + m * 0.3;
    vec3 milkOver = m + s * 0.3;
    return mix(sceneOver, milkOver, uHitKick);
  }
  if (mode == 10) {
    vec2 px = 1.5 / uResolution;
    float l0 = lum(ground(uv + vec2(px.x, 0.0))) - lum(ground(uv - vec2(px.x, 0.0)));
    float l1 = lum(ground(uv + vec2(0.0, px.y))) - lum(ground(uv - vec2(0.0, px.y)));
    float edge = clamp(length(vec2(l0, l1)) * 6.0, 0.0, 1.0);
    vec3 tint = normalize(m + 0.05) * 1.2;
    return tint * edge * (0.6 + 0.4 * uBeatDecay) + s;
  }
  if (mode == 11) return abs(s - m) * 1.2;
  return s + m;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec4 sa = texture(uScene, uv);
  vec3 s = sa.rgb;
  // The figure's coverage: the alpha (a body at 254/255 counts whole), or the band.
  float cov = uCoverage > 0.5 ? (sa.a >= 0.98 ? 1.0 : clamp(sa.a, 0.0, 1.0)) : step(0.98, sa.a) * step(sa.a, 0.9985);
  vec3 m = ground(uv);
  int mode = int(uMode + 0.5);
  vec3 back = blendOf(mode, s, m, uv);
  vec3 fig = uFigureMode > 0.5 ? back : s;
  vec3 col = mix(back, fig, cov);
  fragColor = vec4(mix(s, col, uStrength), 1.0);
}
