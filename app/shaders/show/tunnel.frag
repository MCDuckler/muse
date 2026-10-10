#version 460 core
#include <flutter/runtime_effect.glsl>

// Tunnel: for the drive and the drop. A tube of light rushing past, faster with the
// energy, its walls in the primary and the far end in the secondary, fogged with
// distance; the kick lights the walls from the centre; long streaks of light run
// along it on the top end.

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

float fbm(vec2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    a *= 0.5;
  }
  return v;
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
  // The centre wanders a little with the phrase.
  uv += 0.06 * vec2(sin(uPhrase * 6.2831), cos(uPhrase * 6.2831 * 0.5)) * uM1;
  float r = length(uv);
  float a = atan(uv.y, uv.x);
  float depth = 1.0 / (r + 0.06);
  float speed = 0.6 + 2.6 * uEnergy;
  float kick = uKick * (0.5 + 0.5 * uEnergy) + uHit;
  float d = depth * 0.3 - uTime * speed;

  vec3 primary = hsl(uHue, 0.7, 0.5);
  vec3 secondary = hsl(uHue2, 0.65, 0.6);
  vec3 warm = hsl(uHue + 0.08, 0.5, 0.75);

  // The walls: noise read round a circle (not along the angle, which seams) and
  // along the depth; folded into panels by the bar.
  vec2 ring = vec2(cos(a), sin(a));
  float n = fbm(ring * 2.4 + vec2(d * 1.6, -d * 1.0));
  float panels = 0.5 + 0.5 * sin(depth * 2.4 - uBar * 6.2831 * 2.0 + n * 2.0);
  float wall = smoothstep(0.15, 0.95, n * (0.5 + 0.5 * panels));

  // Fog: the far end dissolves into the secondary.
  // Only the far end fogs: the walls near the eye stay their own colour.
  float fog = smoothstep(4.0, 14.0, depth);
  vec3 col = mix(primary * wall * 1.1, secondary * 0.5, fog * 0.9);
  // The walls dim with distance before the fog takes them.
  col *= mix(1.0, 0.4, smoothstep(2.0, 10.0, depth));

  // Streaks of light along the tunnel, with the top end.
  float streaks = pow(0.5 + 0.5 * sin(a * 18.0 + n * 6.0), 12.0) * (0.3 + 0.7 * uHigh);
  col += warm * streaks * 0.18 * smoothstep(0.9, 0.1, r);

  // The kick: the walls lit from the centre, falling away outward.
  col += warm * kick * 0.5 * smoothstep(0.9, 0.0, r) * (0.4 + 0.6 * wall);
  // A bright far end that breathes with the low end.
  col += secondary * exp(-r * r * 40.0) * (0.3 + 0.5 * uLow);

  col *= smoothstep(1.6, 0.35, r);
  col *= 0.35 + 0.35 * uIntensity;
  fragColor = vec4(col, 1.0);
}
