#version 460 core
#include <flutter/runtime_effect.glsl>

// Milk: MilkDrop's picture (the wetowl-milk helper's frame) put on the stage with
// the show's own hands over it — a step in on the kick, the palette pulled through
// it as much as the knob says, a flash on the hands' hit, the build tightening
// the frame and the drop throwing it wide. The presets react to the sound on their
// own (and to wo_* where they were written here); this is the show's beat on top,
// so even a preset that only drifts moves with the record.

uniform vec2 uResolution;
// The show's floats, four to a vec4 in the same order (the same setFloat indices,
// the native stage's order too): Metal gives each uniform a buffer slot of its own
// and has 31, so on a Mac every scene past uExposure would not build. The names stay.
uniform vec4 uP0;  // uTime uBeat uBar uPhrase
uniform vec4 uP1;  // uEnergy uIntensity uKick uLow
uniform vec4 uP2;  // uMid uHigh uAir uOnset
uniform vec4 uP3;  // uHue uHue2 uDropNear uBuild
uniform vec4 uP4;  // uHit uVocal uM1 uM2
uniform vec4 uP5;  // uM3 uM4 uHitKick uHitSnare
uniform vec4 uP6;  // uHitTop uBeatDecay uBarDecay uBarSaw
uniform vec4 uP7;  // uPhraseSaw uDownbeat uExposure uBandLow
uniform float uBandMid;
uniform float uBandHigh;
uniform float uBarIndex;
#define uTime uP0.x
#define uBeat uP0.y
#define uBar uP0.z
#define uPhrase uP0.w
#define uEnergy uP1.x
#define uIntensity uP1.y
#define uKick uP1.z
#define uLow uP1.w
#define uMid uP2.x
#define uHigh uP2.y
#define uAir uP2.z
#define uOnset uP2.w
#define uHue uP3.x
#define uHue2 uP3.y
#define uDropNear uP3.z
#define uBuild uP3.w
#define uHit uP4.x
#define uVocal uP4.y
#define uM1 uP4.z
#define uM2 uP4.w
#define uM3 uP5.x
#define uM4 uP5.y
#define uHitKick uP5.z
#define uHitSnare uP5.w
#define uHitTop uP6.x
#define uBeatDecay uP6.y
#define uBarDecay uP6.z
#define uBarSaw uP6.w
#define uPhraseSaw uP7.x
#define uDownbeat uP7.y
#define uExposure uP7.z
#define uBandLow uP7.w
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
  // Black stays black: the tint scales with what is there, never lifts it.
  vec3 tint = mix(hsl(uHue, 0.8, 0.35), hsl(uHue2, 0.7, 0.7), smoothstep(0.1, 0.9, lum));
  col = mix(col, tint * 1.6 * lum, uM1);
  // A flash on the hands' hit, and the top end as a thin sparkle at the edges.
  col = mix(col, vec3(1.0), uHit * 0.6);
  float edge = smoothstep(0.35, 0.5, max(abs(uv.x - 0.5), abs(uv.y - 0.5)));
  col += hsl(uHue2, 0.9, 0.6) * edge * 0.25 * uHitTop;
  col *= 0.8 + 0.3 * uExposure;
  fragColor = vec4(col, 1.0);
}
