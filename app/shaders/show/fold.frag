#version 460 core
#include <flutter/runtime_effect.glsl>

// Fold: the room through a kaleidoscope. The camera folded into mirrored wedges —
// six to twelve, the phrase (or the record's genome) says — turning with the bar,
// breathing out on the kick, the wedge seams softened so it reads as a mandala
// and not a test card; the motion map lights the wedges where somebody moves, in
// the secondary. The trails (the scene's post) keep every kick's bloom for a bar.

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
uniform sampler2D uCamera;
uniform sampler2D uMotion;

out vec4 fragColor;

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
  float seg = uM1 > 0.0 ? 6.0 + floor(uM1 * 6.99) : 6.0 + 2.0 * floor(mod(uPhraseSaw * 4.0, 4.0));
  float wedge = 6.2831853 / seg;
  float turn = uBarSaw * 0.5 * (0.3 + 0.7 * uEnergy) + uTime * 0.03;
  float am = mod(a + turn, wedge);
  float edge = abs(am - wedge * 0.5);
  // The camera read along the wedge, breathing out on the kick, from a point that
  // walks round its middle so the mandala is never the same picture twice.
  float zoom = 0.75 - 0.15 * uHitKick - 0.1 * uHit + 0.03 * sin(uBar * 6.2831);
  vec2 centre = vec2(0.5) + 0.08 * vec2(sin(uTime * 0.11), cos(uTime * 0.07));
  vec2 p = vec2(cos(edge), sin(edge)) * r * zoom;
  vec2 t = centre + p * vec2(9.0 / 16.0, 1.0);
  t = abs(fract(t * 0.5 + 0.5) * 2.0 - 1.0);  // mirrored, so the edges meet themselves
  vec3 col = texture(uCamera, t).rgb;
  col = clamp((col - 0.06) * 1.2, 0.0, 1.0);
  float moved = texture(uMotion, t).r;
  // The seams softened.
  float seam = smoothstep(0.0, 0.06, wedge * 0.5 - edge);
  col *= 0.75 + 0.25 * seam;
  // Pulled towards the palette; what moves lights up in the secondary.
  float lum = dot(col, vec3(0.299, 0.587, 0.114));
  vec3 tint = mix(hsl(uHue, 0.6, 0.4), hsl(uHue2, 0.6, 0.7), smoothstep(0.0, 1.0, r));
  col = mix(col, tint * (0.4 + 1.1 * lum), 0.4);
  col += hsl(uHue2, 0.9, 0.6) * moved * (0.6 + 0.8 * uBandHigh);
  col *= 0.6 + 0.5 * uBeatDecay * uEnergy + 0.3 * uHitKick;
  col *= smoothstep(1.35, 0.4, r);
  col *= uExposure * 1.3;
  fragColor = vec4(col, 1.0);
}
