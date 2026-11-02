#version 460 core
#include <flutter/runtime_effect.glsl>

// Flash: for the drop. Hard-edged, two colours, no softness, and every bar of the
// grid a new arrangement — a cut, not a slide. A few big bars across the frame,
// mirrored about the middle on most bars; a scan-line that crosses the frame over
// the bar, so there is motion between the hits; the field dims between beats and
// snaps back on each; the kick's hit widens the bars and lights the field for a
// fifth of a second; the snare throws the halves apart; the top end scatters thin
// slivers; the exposure rides the loudness. Black between: no glow, no grey.

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

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

vec3 hsl(float h, float s, float l) {
  vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
  vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0);
  vec3 rgb = mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
  return l + (rgb - 0.5) * (1.0 - abs(2.0 * l - 1.0));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec3 primary = hsl(uHue, 1.0, 0.5);
  vec3 secondary = hsl(uHue2, 1.0, 0.55);

  // The bar's number: a new arrangement each bar, from it.
  float barN = uBarIndex;
  float seed = hash(vec2(barN, 1.0));
  // Mirrored about the middle on most bars.
  float x = seed > 0.25 ? abs(uv.x - 0.5) * 2.0 : uv.x;

  // The bars: four to eight lanes, each lit or not, each a block of some height
  // placed somewhere, wider on the kick.
  float count = 4.0 + floor(seed * 5.0);
  float lane = floor(x * count);
  float within = fract(x * count);
  float on = step(0.4, hash(vec2(lane, barN)));
  float w = 0.3 + 0.45 * hash(vec2(lane * 7.0, barN + 2.0)) + 0.3 * uHitKick;
  float top = hash(vec2(lane * 3.0, barN + 4.0)) * 0.6;
  float height = 0.25 + 0.6 * hash(vec2(lane * 5.0, barN + 6.0));
  float inBlock = step(top, uv.y) * step(uv.y, top + height);
  float bar = on * step(within, w) * inBlock;

  // The scan-line, over the bar.
  float scanX = seed > 0.5 ? uBarSaw : 1.0 - uBarSaw;
  float scan = smoothstep(0.012, 0.0, abs(uv.x - scanX));
  float scanned = step(uv.x, scanX) * step(0.5, seed) + step(scanX, uv.x) * step(seed, 0.5);

  // The field dims between the beats and snaps back on each.
  float pulse = 0.5 + 0.5 * uBeatDecay;
  vec3 col = primary * bar * pulse * (0.7 + 0.3 * scanned);
  col += secondary * scan * (0.4 + 0.6 * uBandLow);

  // The snare: the halves thrown apart for an instant, in the secondary.
  float halfY = step(0.5, uv.y);
  float thrown = step(0.5, hash(vec2(floor(uTime * 30.0), halfY))) * uHitSnare;
  col = mix(col, secondary * bar, thrown * 0.9);

  // The top end: thin slivers.
  float sliver = step(0.985 - 0.012 * uHitTop, hash(vec2(floor(uv.x * 120.0), floor(uTime * 24.0)))) * uHitTop;
  col += secondary * sliver * 0.9;

  // The kick: the bars lit in the secondary, and a thin frame round the picture.
  col = mix(col, secondary * 1.2 * bar, uHitKick * 0.7);
  float edge = step(min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)), 0.006) * uHitKick;
  col += secondary * edge;
  // The downbeat: the bars go white for a flash.
  col = mix(col, vec3(1.0) * bar, uDownbeat * 0.5);
  // A hit from the hands: white.
  col = mix(col, vec3(1.0), uHit * 0.8);

  col *= uExposure * 1.4;
  fragColor = vec4(col, 1.0);
}
