#version 460 core
#include <flutter/runtime_effect.glsl>

// The kaleidoscope: uCount mirrors through the middle of the stage (2 and no turn:
// one horizontal, one vertical), turned by uTurn, cutting it into twice as many
// wedges. As in a real one, one wedge is what is between the mirrors — here the one
// the figure lights most (each wedge's middle looked at, the same answer for every
// pixel of a frame) — and every other wedge shows it reflected, every other one
// mirrored, cut off at the wedge's edges. As big as the original and still; and
// always under the original: wherever the original draws anything it is what is
// seen, whole; the reflections only fill what it leaves dark. uLine draws the mirrors'
// edges over the reflections.
//
// uDiffer is how far the reflections' light and colour are from the original's: 0 its
// twins; toward 1 dimmer, each turned a step further round the colour wheel.

uniform vec2 uResolution;
uniform float uCount;   // the mirrors (1..6)
uniform float uDiffer;  // 0..1
uniform float uTurn;    // the mirrors' turn, radians
uniform float uLine;    // 0..1: how much of the mirrors' edges is drawn
uniform sampler2D uImage;

out vec4 fragColor;

const float TAU = 6.2831853;

float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

// A colour turned [a] (turns) round the wheel, its lightness kept (YIQ).
vec3 hueTurn(vec3 c, float a) {
  float y = lum(c);
  float i = dot(c, vec3(0.596, -0.274, -0.322));
  float q = dot(c, vec3(0.211, -0.523, 0.312));
  float h = a * TAU;
  float ci = cos(h), si = sin(h);
  float i2 = i * ci - q * si;
  float q2 = i * si + q * ci;
  return vec3(y + 0.956 * i2 + 0.621 * q2, y - 0.272 * i2 - 0.647 * q2, y - 1.106 * i2 + 1.703 * q2);
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  vec2 uv = fc / uResolution;
  vec4 orig = texture(uImage, uv);
  float aspect = uResolution.x / uResolution.y;
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
  float m = floor(clamp(uCount, 1.0, 6.0) + 0.5);
  float d = clamp(uDiffer, 0.0, 1.0);
  float wedge = 3.14159265 / m;
  float r = length(p);
  float a = atan(p.y, p.x) - uTurn;
  float n = 2.0 * m;
  // The wedge between the mirrors: the one the figure lights most along its middle.
  float source = 0.0, most = -1.0;
  for (int k = 0; k < 12; k++) {
    float fk = float(k);
    if (fk >= n) continue;
    float mid = (fk + 0.5) * wedge + uTurn;
    float lit = 0.0;
    for (int i = 1; i <= 3; i++) {
      vec2 t = float(i) * 0.13 * vec2(cos(mid), sin(mid));
      vec2 tu = t / vec2(aspect, 1.0) + 0.5;
      if (tu.x >= 0.0 && tu.x <= 1.0 && tu.y >= 0.0 && tu.y <= 1.0) lit += lum(texture(uImage, tu).rgb);
    }
    if (lit > most + 1e-4) {
      most = lit;
      source = fk;
    }
  }
  // This wedge and where in it; the source's point that the mirrors show here: turned
  // there an even number of wedges away, reflected an odd.
  float k = floor(a / wedge);
  float local = a - k * wedge;
  float apart = mod(source - k, n);
  float src = source * wedge + (mod(apart, 2.0) > 0.5 ? wedge - local : local);
  vec2 q = r * vec2(cos(src + uTurn), sin(src + uTurn));
  vec2 s = q / vec2(aspect, 1.0) + 0.5;
  float inside = step(0.0, s.x) * step(s.x, 1.0) * step(0.0, s.y) * step(s.y, 1.0);
  vec4 c = texture(uImage, clamp(s, 0.0, 1.0)) * inside;
  vec3 rgb = max(mix(c.rgb, hueTurn(c.rgb, apart * 0.09), d), vec3(0.0)) * (1.0 - 0.7 * d);
  vec4 ghost = vec4(rgb, c.a);
  float best = lum(rgb);
  // The mirrors' edges, a pixel or so wide, over the reflections.
  float edge = r * min(local, wedge - local) * uResolution.y;
  float line = (1.0 - smoothstep(0.6, 1.8, edge)) * clamp(uLine, 0.0, 1.0) * step(0.004, r);
  // The original on top wherever it draws anything (its light, or its coverage band:
  // alpha 254/255 on the Flutter stage, the dancers' coverage on the native one); the
  // reflections only in its dark, and only where they are brighter than that dark.
  float lo = lum(orig.rgb);
  float figure = max(smoothstep(0.02, 0.07, lo), step(0.5, orig.a) * step(orig.a, 0.999));
  vec4 under = best > lo ? ghost : orig;
  under.rgb = mix(under.rgb, vec3(0.85), line * 0.8);
  under.a = max(under.a, line);
  fragColor = mix(under, orig, figure);
}
