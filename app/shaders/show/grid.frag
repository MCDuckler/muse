#version 460 core
#include <flutter/runtime_effect.glsl>

// Grid: a horizon at night. A floor of lines in perspective running at the beat, a
// sun behind the horizon cut by bands that rise with the bar, a ridge of hills
// against it, stars; the kick lifts the floor, the bass thickens the lines, the
// voice and the top lift the sun. The booth's own vector language, blown up.

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

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash(i), b = hash(i + vec2(1, 0)), c = hash(i + vec2(0, 1)), d = hash(i + vec2(1, 1));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec3 hsl(float h, float s, float l) {
  vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
  vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0);
  vec3 rgb = mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
  return l + (rgb - 0.5) * (1.0 - abs(2.0 * l - 1.0));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = (frag - 0.5 * uResolution) / uResolution.y;
  // FlutterFragCoord's y grows downwards: "up" is negative uv.y.
  float horizon = -0.06 - 0.05 * uKick;
  float y = uv.y - horizon;  // positive below the horizon
  vec3 primary = hsl(uHue, 0.75, 0.55);
  vec3 secondary = hsl(uHue2, 0.7, 0.55);
  vec3 warm = hsl(uHue2 + 0.05, 0.8, 0.65);

  // The sky: dark, a touch of the secondary low down.
  vec3 col = vec3(0.003, 0.004, 0.01) + secondary * 0.05 * exp(-max(-y, 0.0) * 4.0);

  // Stars.
  vec2 sp = uv * 80.0;
  vec2 cell = floor(sp);
  if (y < 0.0 && hash(cell) > 0.985) {
    vec2 centre = cell + 0.5 + 0.5 * (vec2(hash(cell + 7.0), hash(cell + 13.0)) - 0.5);
    float d = length(sp - centre);
    col += vec3(0.8, 0.85, 1.0) * exp(-d * d * 22.0) * (0.4 + 0.6 * uAir) * 0.8;
  }

  // The sun: a disc behind the horizon, cut by dark bands that rise with the bar,
  // lifted by the voice and the top.
  vec2 sunAt = vec2(0.0, horizon - 0.12 - 0.05 * uVocal);
  float sr = length(uv - sunAt);
  float sun = smoothstep(0.26, 0.24, sr);
  float cuts = smoothstep(0.35, 0.65, 0.5 + 0.5 * sin((uv.y - horizon) * 60.0 - uBar * 6.2831 * 2.0));
  cuts = mix(1.0, cuts, smoothstep(horizon - 0.26, horizon, uv.y));
  vec3 sunCol = mix(warm, secondary, smoothstep(horizon - 0.26, horizon, uv.y));
  col += sunCol * sun * cuts * (0.9 + 0.4 * uHigh) * step(uv.y, horizon);
  col += sunCol * exp(-sr * sr * 14.0) * 0.25 * (0.6 + 0.4 * uVocal);

  // Hills: a ridge against the sun.
  float ridge = horizon - 0.02 - 0.08 * noise(vec2(uv.x * 3.0 + 10.0, 0.0)) - 0.03 * noise(vec2(uv.x * 9.0, 2.0));
  float hill = smoothstep(ridge - 0.003, ridge + 0.003, uv.y) * step(uv.y, horizon);
  col = mix(col, vec3(0.002, 0.002, 0.006), hill);

  // The floor.
  if (y > 0.001) {
    float depth = 1.0 / y;
    float x = uv.x * depth;
    float z = depth * 0.25 - uBeat;
    float wide = 0.035 + 0.06 * uLow;
    float across = smoothstep(0.5 - wide, 0.5, abs(fract(z) - 0.5));
    float along = smoothstep(0.5 - wide * 0.6, 0.5, abs(fract(x * 0.5) - 0.5));
    float line = max(across, along);
    float fade = smoothstep(40.0, 3.0, depth);
    vec3 floorCol = mix(primary, secondary, smoothstep(2.0, 20.0, depth));
    col = vec3(0.004, 0.003, 0.008) + floorCol * line * fade * (0.6 + 0.5 * uEnergy) * 1.2;
    // The sun's light on the floor near the horizon.
    col += sunCol * exp(-y * 14.0) * 0.18;
  }

  // The horizon's own glow.
  col += secondary * exp(-abs(y) * 26.0) * 0.35 * (0.5 + 0.5 * uHigh);
  // A flash that is the hit.
  col += warm * uHit * exp(-sr * sr * 8.0) * 0.8;

  col *= 0.5 + 0.5 * uIntensity;
  fragColor = vec4(col, 1.0);
}
