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
