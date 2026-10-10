#version 460 core
#include <flutter/runtime_effect.glsl>

// Trails: last frame's picture brought back under this one — and the record's own
// recipe for how. Zoomed and turned a little, folded into mirrored wedges, warped
// by a slow noise, drifted, its hue turned, faded and cooled a touch towards the
// secondary. Fed its own output frame after frame, this is where structure appears
// from nothing: a fold and a zoom make an infinite tunnel of whatever was drawn, a
// turn of the hue makes it rainbow down the depth, a warp makes it breathe. The
// numbers come from the record's genome (show_genome.dart), so every record folds
// its own way.

uniform vec2 uResolution;
uniform float uDecay;   // how much of last frame survives, 0..1
uniform float uZoom;    // per frame, 1.0 = none
uniform float uRotate;  // radians per frame
uniform float uTint;    // 0..1 how far the trail drifts towards uTintColour
uniform vec3 uTintColour;
uniform float uFold;    // mirrored wedges round the middle; under 2 is none
uniform float uWarp;    // the noise warp's strength
uniform float uHueTurn; // radians the hue turns per frame
uniform float uShiftX;  // drift per frame, in uv
uniform float uShiftY;
uniform float uTime;
uniform sampler2D uPrev;
uniform sampler2D uNow;

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

// The hue turned by [t] radians: a rotation in the YIQ plane.
vec3 turnHue(vec3 c, float t) {
  const mat3 toYIQ = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312);
  const mat3 fromYIQ = mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.621, -0.647, 1.703);
  vec3 yiq = toYIQ * c;
  float s = sin(t), co = cos(t);
  yiq.yz = mat2(co, -s, s, co) * yiq.yz;
  return fromYIQ * yiq;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  vec2 c = uv - 0.5;
  float aspect = uResolution.x / uResolution.y;
  c.x *= aspect;
  // The fold: the angle brought into one mirrored wedge.
  if (uFold >= 2.0) {
    float r = length(c);
    float a = atan(c.y, c.x);
    float wedge = 6.2831853 / uFold;
    a = abs(mod(a + wedge * 0.5, wedge) - wedge * 0.5);
    c = vec2(cos(a), sin(a)) * r;
  }
  float s = sin(uRotate), co = cos(uRotate);
  c = mat2(co, -s, s, co) * c / uZoom;
  // The warp: a slow noise that pushes the picture about.
  if (uWarp > 0.0) {
    vec2 q = c * 2.5 + uTime * 0.05;
    c += (vec2(noise(q), noise(q + 17.0)) - 0.5) * uWarp * 0.03;
  }
  c.x /= aspect;
  vec2 back = c + 0.5 + vec2(uShiftX, uShiftY);
  vec3 prev = texture(uPrev, clamp(back, 0.0, 1.0)).rgb * uDecay;
  // Off the edge is dark, softly.
  float inside = smoothstep(0.0, 0.02, back.x) * smoothstep(0.0, 0.02, back.y)
      * smoothstep(1.0, 0.98, back.x) * smoothstep(1.0, 0.98, back.y);
  prev *= inside;
  if (uHueTurn != 0.0) prev = max(turnHue(prev, uHueTurn), 0.0);
  // The trail's colour drifts: light that lingers goes the colour of the room.
  float lum = dot(prev, vec3(0.299, 0.587, 0.114));
  prev = mix(prev, uTintColour * lum, uTint);
  vec3 now = texture(uNow, uv).rgb;
  // Light over light: added — with this frame's share held back by as much as the
  // trail keeps, so a long trail is a long trail and not a brighter room.
  fragColor = vec4(now * (1.0 - 0.6 * uDecay) + prev, 1.0);
}
