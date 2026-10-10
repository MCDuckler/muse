#version 460 core
#include <flutter/runtime_effect.glsl>

// Build: the ramp to a drop. Rays of light from a point ahead, more and brighter as
// the build rises; the field rushing towards it; an iris closing on it; and in the
// last beats everything goes to white — driven by how far the drop is, not by the
// sound, so it lands exactly on it.

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
  float r = length(uv);
  float a = atan(uv.y, uv.x);
  float up = max(uBuild, uDropNear);
  float up2 = up * up;

  vec3 primary = hsl(uHue, 0.7, 0.5);
  vec3 secondary = hsl(uHue2, 0.6, 0.6);
  vec3 col = vec3(0.0);

  // Rays: angular noise, turning slowly, more of them and sharper as it rises. Read
  // round the circle, so there is no seam where the angle wraps.
  vec2 ring = vec2(cos(a), sin(a));
  float rays = noise(ring * (6.0 + 10.0 * up) + uTime * 0.15);
  rays += 0.5 * noise(ring * (14.0 + 20.0 * up) - uTime * 0.25);
  rays = pow(clamp(rays / 1.5, 0.0, 1.0), 2.0 + 3.0 * up);
  float fall = 1.0 / (1.0 + r * 3.0);
  col += mix(primary, secondary, r) * rays * fall * (0.25 + 1.2 * up2);

  // The field rushing in: specks streaming towards the centre, faster as it rises.
  float speed = 0.3 + 2.5 * up2;
  float z = 1.0 / (r + 0.05) * 0.6 - uTime * speed;
  // Lanes read round the circle, so there is no seam where the angle wraps.
  float lanes = noise(ring * 5.0);
  float specks = smoothstep(0.72, 1.0, noise(vec2(z * 3.0, lanes * 40.0)));
  col += secondary * specks * fall * (0.3 + 0.7 * up) * 0.8;

  // The core: a point of light that grows, with the kick in it.
  float core = exp(-r * r * (60.0 - 50.0 * up2)) * (0.3 + 1.5 * up2 + 0.8 * uKick);
  col += mix(secondary, vec3(1.0), 0.5) * core;

  // The iris: a dark ring closing in on the core as the build rises.
  float iris = 1.0 - smoothstep(0.0, 0.03, abs(r - (0.95 - 0.8 * up)) - 0.01) * 0.6 * up;
  col *= iris;

  // The last beats: to white.
  float white = smoothstep(0.82, 1.0, uDropNear);
  col = mix(col, vec3(1.4), white * white);

  col *= 0.5 + 0.5 * uIntensity;
  fragColor = vec4(col, 1.0);
}
