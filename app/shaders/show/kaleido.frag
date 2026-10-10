#version 460 core
#include <flutter/runtime_effect.glsl>

// Kaleido: the cover art in a kaleidoscope. Soft-edged petals that turn slowly with
// the bar and breathe on the kick; the segments change with the phrase; the picture
// is pulled a little towards the palette and darkened at the edges, so it reads as
// light on a wall rather than a picture pasted on.

uniform vec2 uResolution;
uniform float uTime;
uniform float uBeat;
uniform float uBar;
uniform float uPhrase;
uniform float uEnergy;
uniform float uIntensity;
uniform float uKick;
uniform float uLow;
uniform float uMid;
uniform float uHigh;
uniform float uAir;
uniform float uOnset;
uniform float uHue;
uniform float uHue2;
uniform float uDropNear;
uniform float uBuild;
uniform float uHit;
uniform float uVocal;
uniform float uM1;
uniform float uM2;
uniform float uM3;
uniform float uM4;
// The dynamics (state/show/show_dynamics.dart): the hits, which snap to 1 and fall
// in a fifth of a second; the grid's own ramps; the exposure; the bands against
// the record's own loud.
uniform float uHitKick;
uniform float uHitSnare;
uniform float uHitTop;
uniform float uBeatDecay;
uniform float uBarDecay;
uniform float uBarSaw;
uniform float uPhraseSaw;
uniform float uDownbeat;
uniform float uExposure;
uniform float uBandLow;
uniform float uBandMid;
uniform float uBandHigh;
uniform float uBarIndex;   // the bar, counted from the record's first downbeat
uniform sampler2D uCover;

out vec4 fragColor;

vec3 hsl(float h, float s, float l) {
  vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
  vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0);
  vec3 rgb = mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
  return l + (rgb - 0.5) * (1.0 - abs(2.0 * l - 1.0));
}

// The cover, read through a mirror fold so its edges meet themselves, slightly
// blurred by four taps so a hard cover goes soft.
vec3 cover(vec2 p) {
  vec2 t = abs(fract(p * 0.5 + 0.5) * 2.0 - 1.0);
  vec2 e = vec2(0.004, 0.0);
  return (texture(uCover, t + e.xy).rgb + texture(uCover, t - e.xy).rgb
      + texture(uCover, t + e.yx).rgb + texture(uCover, t - e.yx).rgb) * 0.25;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = (frag - 0.5 * uResolution) / uResolution.y;
  float r = length(uv);
  float a = atan(uv.y, uv.x);
  // Segments: 6, 8, 10 or 12 by the phrase's bar (uM1 holds them at 8).
  float seg = mix(6.0 + 2.0 * floor(mod(uPhrase * 4.0, 4.0)), 8.0, uM1);
  float wedge = 6.2831 / seg;
  float turn = uBar * 0.35 + uTime * 0.02;
  float am = mod(a + turn, wedge);
  float edge = abs(am - wedge * 0.5);
  am = edge;
  float zoom = 0.85 + 0.12 * uKick + 0.1 * uHit + 0.04 * sin(uBar * 6.2831);
  vec2 p = vec2(cos(am + turn * 0.3), sin(am + turn * 0.3)) * r * zoom * 1.6;
  vec3 col = cover(p);

  // Softened seams: the petal edges dim and blur into one another.
  float seam = smoothstep(0.0, 0.08, wedge * 0.5 - edge);
  col *= 0.7 + 0.3 * seam;

  // Pulled a little towards the palette, lit by the bands.
  float lum = dot(col, vec3(0.299, 0.587, 0.114));
  vec3 tint = mix(hsl(uHue, 0.6, 0.5), hsl(uHue2, 0.6, 0.6), smoothstep(0.0, 1.0, r));
  col = mix(col, tint * (0.3 + 1.0 * lum), 0.5);
  col *= 0.35 + 0.35 * uLow + 0.15 * uHigh * lum;

  // The middle glows softly; the rim goes dark.
  col += tint * exp(-r * r * 30.0) * 0.2 * (0.5 + uKick);
  col *= smoothstep(1.3, 0.3, r);
  col *= 0.5 + 0.5 * uIntensity;
  fragColor = vec4(col, 1.0);
}
