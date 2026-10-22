#version 460 core
#include <flutter/runtime_effect.glsl>

// The blend: the figure layer put together with the background under it, the
// combination's way (lib/src/state/show/show_combos.dart). The figure layer has two
// kinds of pixel — the figure itself (a body, a glyph, a bird, a shape's light) and
// what is round it, which is the background's: a scene's own paper or wash is not
// drawn over the background.
//
// uMask, where the background shows:
//   0 none      everywhere
//   1 keyhole   only inside the figure (black round it)
//   2 inverted  only round the figure (the figure cut out of it)
// uMix, how the figure and the background meet:
//   0 normal    the figure over the background; under a mask, the mask's shape alone
//   1 add       the two added
//   2 screen    screened: neither can blow the other out
//   3 contrast  the difference: where they agree is dark
// uCoverage, which pixels are the figure: 0 the ones drawn at alpha 254/255 (a canvas
// keeps no coverage under 1, so the plain dancers and the silhouettes mark their
// bodies so); 1 the alpha (the native stage's dancers and birds, the words); 2 the
// light (a shader's picture: bright is figure, dark is the background's).
// uStrength: how much of the blend, 0..1 (0 is the figure layer as drawn).
// uGroundFit: the background picture's own aspect (16/9 for MilkDrop's or the
// camera's, 1 for a cover) where it is to be filled and cropped to the stage; 0 where
// it is the stage's own size already.
// uGroundDim: how much of the background, 0..1.

uniform vec2 uResolution;
uniform float uMix;
uniform float uMask;
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

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec4 sa = texture(uScene, uv);
  vec3 s = sa.rgb;
  int how = int(uCoverage + 0.5);
  float cov;
  vec3 f;
  if (how == 2) {
    // The light is the figure; its picture as it is (dark adds nothing).
    cov = smoothstep(0.02, 0.3, lum(s));
    f = s;
  } else {
    // The alpha (a body at 254/255 counts whole), or the marked band; what is round
    // the figure is dropped.
    cov = how == 1 ? (sa.a >= 0.98 ? 1.0 : clamp(sa.a, 0.0, 1.0)) : step(0.98, sa.a) * step(sa.a, 0.9985);
    f = s * cov;
  }
  vec3 m = texture(uGround, groundAt(uv)).rgb * uGroundDim;
  int mask = int(uMask + 0.5);
  vec3 g = mask == 1 ? m * cov : (mask == 2 ? m * (1.0 - cov) : m);
  int mix_ = int(uMix + 0.5);
  vec3 col;
  if (mix_ == 1) {
    col = g + f;
  } else if (mix_ == 2) {
    col = 1.0 - (1.0 - g) * (1.0 - clamp(f, 0.0, 1.0));
  } else if (mix_ == 3) {
    // The figure's light clamped: a glow above white would cancel the difference.
    col = abs(clamp(f, 0.0, 1.0) - g) * 1.2;
  } else {
    col = mask == 0 ? m * (1.0 - cov) + f : g;
  }
  fragColor = vec4(mix(s, col, uStrength), 1.0);
}
