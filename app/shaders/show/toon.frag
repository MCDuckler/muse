#version 460 core
#include <flutter/runtime_effect.glsl>

// Cartoon: after Kali's "Fractal Cartoon" (shadertoy.com/view/XsBXWt, CC BY-NC-SA
// 3.0) — the "Amazing Surface" fractal flown through and drawn like a cartoon: no
// lights, the colour from the surface's normal, the edges found by how the distance
// field bends and drawn dark, a striped sun in a coloured sky, waves on the ground.
// Rewritten for the stage with the record in it: the fold's angle and offsets drift
// with the phrase and lean with the bands, so the architecture is always becoming
// another; the waves rise with the bass; the sun grows with the low end and its rays
// turn with the bar; the sky and the cel colours are the palette; the kick pushes
// the camera in; a breakdown calms it all. No cat.

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

const float DETAIL = 0.0012;

vec3 hsl(float h, float s, float l) {
  vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
  vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0);
  vec3 rgb = mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
  return l + (rgb - 0.5) * (1.0 - abs(2.0 * l - 1.0));
}

mat2 rot(float a) {
  float s = sin(a), c = cos(a);
  return mat2(c, s, -s, c);
}

// The record's hand on the fold, set once a frame.
float gAngle, gLift, gFloor, gWave, gSpeed;
float gDet;
vec3 gCam, gAhead;

// The "Amazing Surface" fold (Kali): a box fold on xz, a lift, a turn, a sphere fold.
vec4 formula(vec4 p) {
  p.xz = abs(p.xz + 1.0) - abs(p.xz - 1.0) - p.xz;
  p.y -= gLift;
  p.xy *= rot(gAngle);
  p = p * 2.0 / clamp(dot(p.xyz, p.xyz), gFloor, 1.0);
  return p;
}

vec3 path(float ti);

float de(vec3 pos) {
  vec3 tpos0 = pos;
  // Waves on the ground, rising with the bass, running at the record's pace.
  pos.y += sin(pos.z - uTime * gSpeed * 6.0) * gWave;
  vec3 tpos = pos;
  tpos.z = abs(3.0 - mod(tpos.z, 6.0));
  vec4 p = vec4(tpos, 1.0);
  for (int i = 0; i < 4; i++) {
    p = formula(p);
  }
  float fr = (length(max(vec2(0.0), p.yz - 1.5)) - 1.0) / p.w;
  // The road: a slab with a groove and sleepers, as in the original.
  float ro = max(abs(pos.x + 1.0) - 0.3, pos.y - 0.35);
  ro = max(ro, -max(abs(pos.x + 1.0) - 0.1, pos.y - 0.5));
  pos.z = abs(0.25 - mod(pos.z, 0.5));
  ro = max(ro, -max(abs(pos.z) - 0.2, pos.y - 0.3));
  ro = max(ro, -max(abs(pos.z) - 0.01, -pos.y + 0.32));
  float d = min(fr, ro);
  // A little clear air round the camera and just ahead of it: the fold morphs
  // with the record, and a world that morphs would otherwise grow across the
  // camera's way. A short capsule, so the world beyond it is left whole.
  vec3 ab = gAhead - gCam;
  float h = clamp(dot(tpos0 - gCam, ab) / dot(ab, ab), 0.0, 1.0);
  // (A signed distance: negative inside the capsule. Written the other way round
  // it turns the whole field into the distance from the camera, and there is
  // nothing to see but the sun.)
  float capsule = length(tpos0 - gCam - ab * h) - 0.18;
  return max(d, -capsule);
}

vec3 path(float ti) {
  ti *= 1.5;
  return vec3(sin(ti), (1.0 - sin(ti * 2.0)) * 0.5, -ti * 5.0) * 0.5;
}

float gEdge = 0.0;
vec3 normalAt(vec3 p) {
  vec3 e = vec3(0.0, gDet * 5.0, 0.0);
  float d1 = de(p - e.yxx), d2 = de(p + e.yxx);
  float d3 = de(p - e.xyx), d4 = de(p + e.xyx);
  float d5 = de(p - e.xxy), d6 = de(p + e.xxy);
  float d = de(p);
  gEdge = abs(d - 0.5 * (d2 + d1)) + abs(d - 0.5 * (d4 + d3)) + abs(d - 0.5 * (d6 + d5));
  gEdge = min(1.0, pow(gEdge, 0.55) * 15.0);
  return normalize(vec3(d1 - d2, d3 - d4, d5 - d6));
}

vec3 march(vec3 from, vec3 dir, vec3 skyLow, vec3 skyHigh, vec3 sunCol, vec3 cel1, vec3 cel2, vec3 cel3) {
  vec3 p = from;
  float d = 100.0, tot = 0.0;
  gDet = DETAIL;
  for (int i = 0; i < 110; i++) {
    if (d > gDet && tot < 25.0) {
      p = from + tot * dir;
      d = de(p);
      gDet = DETAIL * exp(0.13 * tot);
      tot += d;
    }
  }
  p -= (gDet - d) * dir;
  vec3 n = normalAt(p);
  // The cel colour: each axis of the normal its own colour of the palette, and the
  // edges dark.
  vec3 an = abs(n);
  vec3 col = (cel1 * (1.0 - an.x) + cel2 * (1.0 - an.y) + cel3 * (1.0 - an.z)) * 0.42;
  col *= max(0.0, 1.0 - gEdge * 0.9);
  tot = clamp(tot, 0.0, 26.0);

  // The sky: a striped sun that grows with the low end and turns with the bar.
  dir.y -= 0.02;
  // The disc grows with the bass and the kick; the rays keep their own reach (at
  // a size under four and a half they would cover the whole sky).
  float sunsize = 7.0 - uBandLow * 1.5 - uHitKick * 1.4;
  float raysize = 2.2 - 0.9 * uHitKick;
  float an2 = atan(dir.x, dir.y) + uBar * 6.2831 * 0.5 + uTime * 0.3;
  float stripe = abs(0.2 - mod(an2, 0.4));
  float s = pow(clamp(1.0 - length(dir.xy) * sunsize - stripe, 0.0, 1.0), 0.1);
  float sb = pow(clamp(1.0 - length(dir.xy) * (sunsize - 0.2) - stripe, 0.0, 1.0), 0.1);
  float sg = pow(clamp(1.0 - length(dir.xy) * raysize - 0.5 * stripe, 0.0, 1.0), 3.0);
  float y = mix(0.45, 1.2, pow(smoothstep(0.0, 1.0, 0.75 - dir.y), 2.0)) * (1.0 - sb * 0.5);
  vec3 backg = mix(skyHigh, skyLow, clamp(dir.y + 0.5, 0.0, 1.0)) * ((1.0 - s) * (1.0 - sg) * y)
      + (1.0 - sb) * sg * sunCol * 1.4;
  backg += sunCol * s * 1.0;
  backg = max(backg, sg * sunCol * 0.8);

  // The distance fades to the sun's colour; past the world is the sky.
  col = mix(sunCol * 0.7, col, exp(-0.004 * tot * tot));
  if (tot > 25.0) col = backg;
  col = pow(max(col, 0.0), vec3(1.3)) * 0.85;
  col = mix(vec3(length(col) * 0.577), col, 0.75);
  return col;
}

vec3 move(inout vec3 dir, float t) {
  vec3 go = path(t);
  vec3 adv = path(t + 0.7);
  vec3 advec = normalize(adv - go);
  float an = adv.x - go.x;
  an *= min(1.0, abs(adv.z - go.z)) * sign(adv.z - go.z) * 0.7;
  dir.xy *= mat2(cos(an), sin(an), -sin(an), cos(an));
  an = advec.y * 1.7;
  dir.yz *= mat2(cos(an), sin(an), -sin(an), cos(an));
  an = atan(advec.x, advec.z);
  dir.xz *= mat2(cos(an), sin(an), -sin(an), cos(an));
  return go;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uResolution * 2.0 - 1.0;
  uv.y = -uv.y;
  uv.y *= uResolution.y / uResolution.x;

  // The record's hand on the world this frame.
  float calm = 0.4 + 0.6 * uEnergy;
  // The fold answers the record in big moves: it jumps a few degrees on every
  // downbeat and settles over the bar, leans with the bass, and the kick's hit
  // kicks it. Smaller, slower things drift with the phrase.
  gAngle = radians(35.0 + 5.0 * sin(uPhrase * 6.2831 + uTime * 0.04)
      + 7.0 * uDownbeat + 3.0 * uBandLow * calm + 2.5 * uHitKick + 4.0 * uM1);
  gLift = 0.25 + 0.04 * sin(uTime * 0.06 + 1.0) + 0.06 * uHitSnare + 0.03 * uBandHigh * calm;
  gFloor = 0.2 + 0.1 * uBuild + 0.08 * uBarDecay * uEnergy + 0.05 * uM2;
  gWave = (0.03 + 0.14 * uBandLow + 0.08 * uHitKick) * calm;
  gSpeed = 0.2 + 0.5 * uEnergy;
  float t = uTime * gSpeed;

  // The sky and the cels, from the palette: the sky in the primary, the sun warm.
  vec3 skyLow = hsl(uHue, 0.8, 0.45);
  vec3 skyHigh = hsl(uHue, 0.7, 0.2);
  vec3 sunCol = hsl(uHue2 + 0.05, 0.85, 0.65);
  vec3 cel1 = hsl(uHue2, 0.65, 0.5);
  vec3 cel2 = hsl(uHue + 0.5, 0.55, 0.5);
  vec3 cel3 = hsl(uHue, 0.5, 0.6);

  // The camera punches in on the kick, rolls with the bar, and is pushed by a hit.
  float fov = 0.9 - 0.2 * uHitKick - 0.1 * uHit;
  vec3 dir = normalize(vec3(uv * fov, 1.0));
  // A tilt with the bar, the original's mouse.
  dir.yz *= rot(-0.05 + 0.04 * sin(uBar * 6.2831) + 0.03 * uHitSnare);
  dir.xy *= rot(0.06 * (uBarSaw - 0.5) * uEnergy + 0.04 * uHitTop);
  dir.xz *= rot(0.1 * uM3);
  gCam = vec3(-1.0, 0.7, 0.0) + path(t);
  gAhead = vec3(-1.0, 0.7, 0.0) + path(t + 0.3);
  vec3 from = vec3(-1.0, 0.7, 0.0) + move(dir, t);
  vec3 col = march(from, dir, skyLow, skyHigh, sunCol, cel1, cel2, cel3);
  // The exposure follows the loudness; the hits flash the whole frame a little.
  col *= uExposure * (0.9 + 0.3 * uHitKick + 0.15 * uHitSnare);
  fragColor = vec4(col, 1.0);
}
