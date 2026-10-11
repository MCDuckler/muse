#version 460 core
#include <flutter/runtime_effect.glsl>

// Milk: MilkDrop's picture (the wetowl-milk helper's frame) put on the stage with
// the show's own hands over it — a step in on the kick, the palette pulled through
// it as much as the knob says, a flash on the hands' hit, the build tightening
// the frame and the drop throwing it wide. The presets react to the sound on their
// own (and to wo_* where they were written here); this is the show's beat on top,
// so even a preset that only drifts moves with the record.

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
uniform float uM1;      // how much of the palette goes over the picture, 0..1
uniform float uM2;      // how hard the kick steps in, 0..1
uniform float uM3;
uniform float uM4;
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
uniform float uBarIndex;
uniform sampler2D uMilk;

out vec4 fragColor;

vec3 hsl(float h, float s, float l) {
  vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
  vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0);
  vec3 rgb = mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
  return l + (rgb - 0.5) * (1.0 - abs(2.0 * l - 1.0));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  // The kick: a step in, the build: a slow tightening, the hit and the drop: wide.
  float zoom = 1.0 + 0.06 * uM2 * uHitKick + 0.08 * uBuild - 0.1 * uHit - 0.05 * smoothstep(0.9, 1.0, uDropNear);
  vec2 c = (uv - 0.5) / zoom + 0.5;
  // The picture is 16:9; the stage may not be: the picture fills it, cropped.
  float stage = uResolution.x / uResolution.y;
  float pic = 16.0 / 9.0;
  vec2 fit = stage > pic ? vec2(1.0, pic / stage) : vec2(stage / pic, 1.0);
  vec2 t = (c - 0.5) * fit + 0.5;
  vec3 col = texture(uMilk, clamp(t, 0.0, 1.0)).rgb;
  // The palette through it: the primary where it is dark, the secondary where
  // it is bright, as much as the knob says.
  float lum = dot(col, vec3(0.299, 0.587, 0.114));
  vec3 tint = mix(hsl(uHue, 0.8, 0.35), hsl(uHue2, 0.7, 0.7), smoothstep(0.1, 0.9, lum));
  col = mix(col, tint * (0.3 + 1.4 * lum), uM1);
  // A flash on the hands' hit, and the top end as a thin sparkle at the edges.
  col = mix(col, vec3(1.0), uHit * 0.6);
  float edge = smoothstep(0.35, 0.5, max(abs(uv.x - 0.5), abs(uv.y - 0.5)));
  col += hsl(uHue2, 0.9, 0.6) * edge * 0.25 * uHitTop;
  col *= 0.85 + 0.3 * uExposure;
  fragColor = vec4(col, 1.0);
}
