#version 460 core
#include <flutter/runtime_effect.glsl>

// Fold: the room through a kaleidoscope. The camera folded into mirrored wedges —
// six to twelve, the phrase (or the record's genome) says — turning with the bar,
// breathing out on the kick, the wedge seams softened so it reads as a mandala
// and not a test card; the motion map lights the wedges where somebody moves, in
// the secondary. The trails (the scene's post) keep every kick's bloom for a bar.

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
uniform float uM1;      // the genome: wedges, 0..1 → 6..12 (0 = by the phrase)
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
