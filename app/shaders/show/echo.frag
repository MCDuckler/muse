#version 460 core
#include <flutter/runtime_effect.glsl>

// Echo: the room fed back into itself. This frame of the camera laid over the last
// frame of this very picture — zoomed a step, turned a few degrees, its hue walked
// on, faded a little — so the room becomes an infinite corridor of itself. The kick
// is a step in, the bar a turn, the phrase a quarter-turn of hue, the energy how
// much of the past survives; a breakdown slows the corridor to a drift; a hit zooms
// out hard. Where nobody moves the loop settles; where somebody does, they are
// drawn a hundred times over, receding.

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
uniform float uM1;      // the genome: zoom per step
uniform float uM2;      // the genome: turn per bar, radians
uniform float uM3;      // the genome: hue walk per phrase
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
uniform sampler2D uHistory;

out vec4 fragColor;

vec3 turnHue(vec3 c, float t) {
  const mat3 toYIQ = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312);
  const mat3 fromYIQ = mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.621, -0.647, 1.703);
  vec3 yiq = toYIQ * c;
  float s = sin(t), co = cos(t);
  yiq.yz = mat2(co, -s, s, co) * yiq.yz;
  return fromYIQ * yiq;
}

vec3 hsl(float h, float s, float l) {
  vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
  vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0);
  vec3 rgb = mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s);
  return l + (rgb - 0.5) * (1.0 - abs(2.0 * l - 1.0));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  float aspect = uResolution.x / uResolution.y;

  // The past, brought back: a step in on the kick (the genome says how big), a turn
  // that runs over the bar, a hit that throws it outward.
  float zoom = 1.0 + (0.012 + 0.03 * uM1) * (0.4 + 0.6 * uEnergy) + 0.06 * uHitKick - 0.15 * uHit;
  float turn = (0.004 + 0.02 * uM2) * (0.3 + 0.7 * uEnergy) * (uBarSaw < 0.5 ? 1.0 : -1.0) * (uM2 > 0.5 ? 1.0 : -1.0);
  // In a breakdown the corridor drifts rather than runs.
  float calm = 1.0 - 0.7 * (1.0 - uEnergy) * (1.0 - uBandLow);
  zoom = 1.0 + (zoom - 1.0) * calm;
  turn *= calm;
  vec2 c = (uv - 0.5) * vec2(aspect, 1.0);
  float s = sin(turn), co = cos(turn);
  c = mat2(co, -s, s, co) * c / zoom;
  c.x /= aspect;
  vec2 back = c + 0.5;
  vec3 past = texture(uHistory, clamp(back, 0.0, 1.0)).rgb;
  float inside = smoothstep(0.0, 0.01, back.x) * smoothstep(0.0, 0.01, back.y)
      * smoothstep(1.0, 0.99, back.x) * smoothstep(1.0, 0.99, back.y);
  // The hue walks a little every frame — a quarter turn a phrase at most — so the
  // corridor goes through the colours as it recedes.
  past = max(turnHue(past, (0.004 + 0.012 * uM3) * (0.5 + 0.5 * uEnergy)), 0.0) * inside;
  // How much of the frame is the past: at 0.8 the corridor is five steps deep before
  // it fades; a hit wipes it; a still, quiet room lets it run deeper.
  float keep = 0.78 + 0.14 * uEnergy - 0.3 * uHit;

  // The room now, in the palette's light: the camera's picture pulled a little
  // towards the primary where it is dark and the secondary where it is bright.
  vec3 cam = texture(uCamera, uv).rgb;
  // A webcam's picture is flat: a little contrast, the blacks put back.
  cam = clamp((cam - 0.08) * 1.25, 0.0, 1.0);
  cam = pow(cam, vec3(1.15));
  float lum = dot(cam, vec3(0.299, 0.587, 0.114));
  vec3 tint = mix(hsl(uHue, 0.7, 0.35), hsl(uHue2, 0.6, 0.7), lum);
  cam = mix(cam, tint * (0.5 + lum), 0.45);
  // Lifted on the kick, so the room flashes in the corridor.
  cam *= 0.7 + 0.5 * uBeatDecay * uEnergy + 0.4 * uHitKick;

  // The room mixed over its past — a mix, not a sum, so the loop can never flood to
  // white: its fixed point is the room itself. The past darkens a hair each step, so
  // the far end of the corridor goes to black.
  vec3 col = mix(past * 0.975, cam, 1.0 - keep);
  col *= uExposure * 1.15;
  fragColor = vec4(col, 1.0);
}
