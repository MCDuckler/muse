#version 460 core
#include <flutter/runtime_effect.glsl>

// The 3D type (ui/show/show_type3d.dart): a line of words extruded into solid
// letters, turned in space, bent by the music, ray-marched — on either stage, from the
// same floats.
//
// The letters are signed distance fields, two of them (uSdf, uSdfB: sixteen bits in
// red and green, 0.5 on the outline, more outside, less inside, uRange / uRangeB
// object units for every 0.5) each over a rectangle uHalf / uHalfB across and high
// (half extents, the padding in it). uMix goes from the one to the other: by blending
// the distances (uMixMode 0, a morph: the letters flow into the next ones) or band by
// band (1, a glitch: horizontal slices cut over in a scattered order). They are
// extruded uDepth either side of the plane and rounded by uBevel, turned by uRot*
// (the rows of the world→object turn), stood at uPos before a camera at the origin
// looking down −z (focal uFov).
//
// Bent, every one at its own strength (0: none), each the music's:
//   wave     a wave along it (uWave, its phase uWavePhase);   twist   wrung (uTwist);
//   uDeformA inflate (puffed up, rounder) · ripple (rings out from the middle, in
//            depth) · the ripple's phase · melt (dripping down, column by column);
//   uDeformB slice (bands torn sideways) · shatter (cells flown apart) · wobble (a
//            liquid wobble through it) · squash (flattened and widened);
//   uDeformC arc (curved along its length) · stack (echoes behind it) · the echoes'
//            gap · repeat (rows of it above and below, scrolling up; its strength
//            the rows' pitch, 0 none).
// uSeed scatters what is scattered (the drips, the cells, the slices' order).
//
// What it is made of (uLook):
//   0 chrome      a mirror of a purple studio, tinted by the ink, a fresnel rim;
//   1 neon        dark letters, their outlines tubes of light, a halo;
//   2 solid       faces in the ink down to uInk2, sides in uInk2, a highlight;
//   3 outline     the edges alone in light, the ground through the faces;
//   4 hologram    a see-through light, lit by the depth it passes through, scanned;
//   5 iridescent  a foil: a thin film's colours turning with the angle;
//   6 glass       clear glass bending what is behind it (uGround, where uGroundOn;
//                 the studio else), its colours split at the edges;
//   7 aurora      a soft gradient of the three colours flowing through it;
//   8 pop         flat print colours, a black outline, halftone dots in the shade;
//   9 stripes     black and ink bands sweeping through it, op art;
//  10 mercury     liquid metal, its surface moving.
//
// Read from behind (or upside down) the letters would be mirrored: uMirror (±1 each
// way) turns them back, switched while they are edge-on, where it does not show.
//
// The beat: uKick flares the light and the halo, uFlash (the snare) whitens the rim
// for its instant. uGlow the halo round the letters (the closest the ray passed).
// The alpha is the coverage: the letters, and the halo as far as it reaches; the
// colour premultiplied by it where uPremul (a canvas), straight otherwise (the native
// stage's blend reads the coverage).

uniform vec2 uResolution;
uniform float uTime;
uniform vec3 uRotX;
uniform vec3 uRotY;
uniform vec3 uRotZ;
uniform vec3 uPos;
uniform vec2 uHalf;
uniform vec2 uHalfB;
uniform float uRange;
uniform float uRangeB;
uniform float uMix;
uniform float uMixMode;
uniform float uSeed;
uniform float uDepth;
uniform float uBevel;
uniform float uWave;
uniform float uWavePhase;
uniform float uTwist;
uniform vec4 uDeformA;
uniform vec4 uDeformB;
uniform vec4 uDeformC;
uniform float uLook;
uniform vec3 uInk;
uniform vec3 uInk2;
uniform vec3 uRim;
uniform float uGlow;
uniform float uKick;
uniform float uFlash;
uniform float uFov;
uniform vec2 uMirror;
uniform float uGroundOn;
uniform float uPremul;
uniform sampler2D uSdf;
uniform sampler2D uSdfB;
uniform sampler2D uGround;

out vec4 fragColor;

float hash1(float n) { return fract(sin(n * 127.1 + uSeed * 3.7) * 43758.5453); }
vec3 hash3(vec2 c) {
  return fract(sin(vec3(dot(c, vec2(127.1, 311.7)), dot(c, vec2(269.5, 183.3)), dot(c, vec2(419.2, 371.9))) + uSeed) * 43758.5453);
}

// One field at q (object units), signed: the picture's, and past its edge the
// distance to the rectangle on top of the most it says. (One function a sampler: a
// sampler handed to a function is not every compiler's.)
float decode(vec2 hl) { return (hl.r * 65280.0 + hl.g * 255.0) / 65535.0; }
float fieldA(vec2 q) {
  vec2 uv = vec2(q.x / (2.0 * uHalf.x) + 0.5, 0.5 - q.y / (2.0 * uHalf.y));
  return (decode(texture(uSdf, clamp(uv, 0.0, 1.0)).rg) - 0.5) * 2.0 * uRange + length(max(abs(q) - uHalf, 0.0));
}
float fieldB(vec2 q) {
  vec2 uv = vec2(q.x / (2.0 * uHalfB.x) + 0.5, 0.5 - q.y / (2.0 * uHalfB.y));
  return (decode(texture(uSdfB, clamp(uv, 0.0, 1.0)).rg) - 0.5) * 2.0 * uRangeB + length(max(abs(q) - uHalfB, 0.0));
}

// The letters' outline at q: the one, the other, or on the way between.
float sdText(vec2 q) {
  q *= uMirror;
  if (uMix <= 0.0) return fieldA(q);
  if (uMix >= 1.0) return fieldB(q);
  float a = fieldA(q), b = fieldB(q);
  if (uMixMode > 0.5) {
    // the glitch: each band over at its own moment
    float band = floor(q.y * 14.0);
    return hash1(band) < uMix ? b : a;
  }
  // the morph: the distances blended, the middle of it swollen a touch so the
  // shapes flow through one another rather than thinning out
  return mix(a, b, uMix) - 0.05 * uMix * (1.0 - uMix);
}

// The object's space bent, every bend at its strength.
vec3 bend(vec3 p) {
  float inflate = uDeformA.x, ripple = uDeformA.y, ripplePhase = uDeformA.z, melt = uDeformA.w;
  float slice = uDeformB.x, shatter = uDeformB.y, wobble = uDeformB.z, squash = uDeformB.w;
  float arc = uDeformC.x;
  // rows of it above and below, scrolling (each row its own way)
  if (uDeformC.w > 0.0) {
    float pitch = uDeformC.w;
    float row = floor((p.y + pitch * 0.5 + uTime * 0.25 * pitch) / pitch);
    p.y = mod(p.y + pitch * 0.5 + uTime * 0.25 * pitch, pitch) - pitch * 0.5;
    p.x += (mod(row, 2.0) * 2.0 - 1.0) * uTime * 0.12 * pitch;
    p.x = mod(p.x + uHalf.x * 1.15, uHalf.x * 2.3) - uHalf.x * 1.15;
  }
  // shattered: cells of the plane flown apart, out of it most
  if (shatter > 0.0) {
    vec2 cell = floor(p.xy * 4.5);
    vec3 off = (hash3(cell) - 0.5) * vec3(0.7, 0.7, 3.0);
    p -= off * shatter;
  }
  // arced along its length
  if (arc != 0.0) {
    float a = arc * p.x;
    float c = cos(a), s = sin(a);
    p.xy = vec2(c * p.x - s * p.y, s * p.x + c * p.y);
  }
  // squashed: flatter and wider
  p.x /= 1.0 + 0.25 * squash;
  p.y /= 1.0 - 0.35 * squash;
  // the wave, the wring
  p.y -= uWave * sin(p.x * 3.2 + uWavePhase);
  p.z -= uWave * 0.6 * cos(p.x * 2.4 + uWavePhase * 0.8);
  if (uTwist != 0.0) {
    float a = uTwist * p.x;
    float c = cos(a), s = sin(a);
    p.yz = vec2(c * p.y - s * p.z, s * p.y + c * p.z);
  }
  // torn: bands pulled sideways
  if (slice > 0.0) p.x += slice * (hash1(floor(p.y * 9.0) + 17.0) - 0.5) * 0.9;
  // melting: the lower it is the further it hangs, column by column
  if (melt > 0.0) {
    float drip = 0.55 + 0.45 * sin(p.x * 9.0 + uSeed) * sin(p.x * 23.0 + 1.7 + uSeed * 0.3);
    p.y += melt * drip * smoothstep(0.4, -1.2, p.y);
  }
  // a wobble through it, liquid
  if (wobble > 0.0) {
    p += wobble * 0.06 * vec3(sin(p.y * 6.0 + uTime * 3.1), sin(p.x * 5.0 + uTime * 2.3), sin((p.x + p.y) * 4.0 + uTime * 2.0));
  }
  // rings out from the middle, in depth
  if (ripple > 0.0) {
    float r = length(p.xy);
    p.z += ripple * 0.12 * sin(r * 13.0 - ripplePhase) * exp(-r * 0.6);
  }
  return p;
}

// The outline extruded to a depth at z, rounded.
float extrude(float d2, float z, float bev) {
  vec2 w = vec2(d2 + bev, abs(z) - uDepth + bev);
  return min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - bev;
}

// The extruded, rounded letters (and their echoes behind, the same outline deeper
// back: one read of the field for all of them); d2 the outline's distance there.
float sdLetters(vec3 p, out float d2) {
  vec3 q = bend(p);
  float inflate = uDeformA.x;
  d2 = sdText(q.xy) - inflate * 0.05;
  float bev = uBevel + inflate * 0.035;
  float d = extrude(d2, q.z, bev);
  if (uDeformC.y > 0.0) {
    for (int k = 1; k <= 3; k++) {
      if (float(k) > uDeformC.y * 3.0 + 0.5) break;
      d = min(d, extrude(d2, q.z + float(k) * uDeformC.z, bev));
    }
  }
  // squashed space is shorter one way: the distance its shortest
  return d * min(1.0, 1.0 - 0.35 * uDeformB.w);
}

float sdf(vec3 p) {
  float d2;
  return sdLetters(p, d2);
}

vec3 toObject(vec3 v) { return vec3(dot(uRotX, v), dot(uRotY, v), dot(uRotZ, v)); }
vec3 toWorld(vec3 v) { return uRotX * v.x + uRotY * v.y + uRotZ * v.z; }

// The normal by four taps at a tetrahedron's corners.
vec3 normalAt(vec3 p) {
  const float e = 0.006;
  const vec2 k = vec2(1.0, -1.0);
  return normalize(k.xyy * sdf(p + k.xyy * e) + k.yyx * sdf(p + k.yyx * e) + k.yxy * sdf(p + k.yxy * e) + k.xxx * sdf(p + k.xxx * e));
}

// The studio a mirror shows, by direction (world).
vec3 studio(vec3 d) {
  float y = d.y;
  vec3 floorC = mix(vec3(0.03, 0.01, 0.06), uInk2 * 0.25, smoothstep(-1.0, -0.05, y));
  vec3 sky = mix(uRim * 0.9 + vec3(0.25), vec3(0.08, 0.02, 0.18), smoothstep(0.0, 0.7, y));
  vec3 c = y < 0.0 ? floorC : sky;
  c += uRim * 1.6 * exp(-abs(y) * 26.0);
  float strips = smoothstep(0.92, 0.98, abs(sin(atan(d.x, d.z) * 3.0))) * smoothstep(0.35, 0.7, y);
  c += vec3(1.0, 0.95, 1.0) * strips * 1.4;
  c += uInk * 0.6 * smoothstep(0.75, 1.0, -d.z) * smoothstep(-0.2, 0.4, y);
  return c;
}

vec3 rainbow(float h) { return 0.5 + 0.5 * cos(6.2831853 * (h + vec3(0.0, 0.33, 0.67))); }

// What is behind the glass at the screen's uv (the ground, or the studio's far wall).
vec3 behind(vec2 uv, vec3 dir) {
  if (uGroundOn > 0.5) return texture(uGround, clamp(uv, 0.0, 1.0)).rgb;
  return studio(dir) * 0.7;
}

vec4 out4(vec3 col, float cov) {
  cov = clamp(cov, 0.0, 1.0);
  return uPremul > 0.5 ? vec4(col, cov) : vec4(col / max(cov, 1e-3), cov);
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  vec2 uv = vec2(fc.x - 0.5 * uResolution.x, 0.5 * uResolution.y - fc.y) / uResolution.y;
  vec3 rd = normalize(vec3(uv, -uFov));
  // Into the object's space: the camera at the origin, the object at uPos.
  vec3 ro = toObject(-uPos);
  vec3 dir = toObject(rd);
  // Its bounding sphere, grown by what bends it: the rays that miss it have nothing
  // to march.
  vec2 halfMax = max(uHalf, uHalfB);
  float bendK = abs(uWave) * 2.5 + abs(uTwist) * 0.5 + uDeformA.w * 1.2 + uDeformB.y * 1.6 + uDeformB.x * 0.5 + uDeformC.y * 0.6;
  // How far the bends stretch space (the echoes and the rows do not: they repeat it).
  float warp = abs(uWave) * 2.5 + abs(uTwist) * 0.5 + uDeformA.w * 0.8 + uDeformB.y * 0.6 + uDeformB.x * 0.3 + uDeformB.z * 0.3 +
               uDeformA.y * 0.4 + abs(uDeformC.x) * 0.5;
  float rad = length(vec3(halfMax, uDepth + uDeformC.y * 3.0 * uDeformC.z)) * (1.0 + bendK) + uGlow * 0.15;
  // repeated, it fills the view: no sphere to keep to
  if (uDeformC.w > 0.0) rad = 1e3;
  float b = dot(ro, dir);
  float c = dot(ro, ro) - rad * rad;
  float h = b * b - c;
  if (h < 0.0) {
    fragColor = vec4(0.0);
    return;
  }
  h = sqrt(h);
  float t = max(-b - h, 0.0);
  float tEnd = -b + h;
  // And the slab the letters stand in (how deep they go, bent, echoed, the halo's
  // reach): a ray is marched only through it, never through the empty room round.
  float zMax = uDepth + uBevel + uDeformA.x * 0.05 + uDeformC.y * 3.0 * uDeformC.z + abs(uWave) * 0.6 + uDeformA.y * 0.12 + uDeformB.y * 1.6 +
               uDeformB.z * 0.06 + max(uRange, uRangeB) + 0.02;
  if (uTwist != 0.0) zMax = max(zMax, halfMax.y * 1.1);
  if (abs(dir.z) > 1e-5) {
    float t1 = (-zMax - ro.z) / dir.z, t2 = (zMax - ro.z) / dir.z;
    t = max(t, min(t1, t2));
    tEnd = min(tEnd, max(t1, t2));
  } else if (abs(ro.z) > zMax) {
    tEnd = -1.0;
  }
  if (t > tEnd) {
    fragColor = vec4(0.0);
    return;
  }
  // Bent space is no longer a true distance: shorter steps the more it is bent.
  float stepK = warp > 0.0 || (uMix > 0.0 && uMix < 1.0) ? max(0.5, 0.88 - warp * 0.5) : 0.9;
  float closest = 1e3;
  bool hit = false;
  int look = int(uLook + 0.5);
  float inside = 0.0;
  // Steps grow with the distance (a pixel's worth there is wider), and a hit is
  // that close.
  for (int i = 0; i < 80; i++) {
    vec3 p = ro + dir * t;
    float d = sdf(p);
    closest = min(closest, d);
    if (look == 4) {
      inside += d < 0.0 ? 0.03 : 0.0;
      t += max(abs(d) * stepK, 0.012);
    } else {
      float eps = 0.0007 * t;
      if (d < eps) {
        hit = true;
        break;
      }
      t += max(d * stepK, eps * 0.5);
    }
    if (t > tEnd) break;
  }

  float range = mix(uRange, uRangeB, clamp(uMix, 0.0, 1.0));
  // The halo fades out before the field's reach (past it every ray is as far).
  float halo = uGlow * exp(-max(closest, 0.0) * 22.0) * (1.0 - smoothstep(0.35 * range, 0.9 * range, closest)) * (0.55 + 0.9 * uKick);
  vec3 glowC = mix(uRim, uInk, 0.35) * halo;
  if (look == 4) {
    float a = clamp(inside * (0.8 + 0.6 * uKick), 0.0, 1.0);
    float scan = 0.75 + 0.25 * sin(fc.y * 1.9 + uTime * 8.0);
    fragColor = out4(mix(uInk, uRim, smoothstep(0.0, 1.0, a)) * a * scan * 1.6 + glowC, a + halo * 0.7);
    return;
  }
  if (!hit) {
    fragColor = out4(glowC, halo * 0.8);
    return;
  }

  vec3 p = ro + dir * t;
  float d2;
  sdLetters(p, d2);
  vec3 q = bend(p);
  vec3 n = normalAt(p);
  vec3 nw = toWorld(n);
  float face = smoothstep(0.55, 0.9, abs(n.z));
  float rim = 1.0 - smoothstep(0.0, 0.035, abs(d2 + uBevel * 0.5));
  float sideEdge = 1.0 - smoothstep(0.0, 0.03, uDepth - abs(q.z));
  vec3 key = normalize(vec3(-0.45, 0.6, 0.65));
  float diff = max(dot(nw, key), 0.0);
  vec3 view = -rd;
  float fres = pow(1.0 - max(dot(nw, view), 0.0), 3.0);
  float spec = pow(max(dot(reflect(-key, nw), view), 0.0), 40.0);
  float down = clamp(0.5 - q.y / (2.0 * max(uHalf.y, 0.1)), 0.0, 1.0);
  vec2 suv = fc / uResolution;
  vec3 col;
  if (look == 0) {
    vec3 env = studio(reflect(rd, nw));
    col = env * mix(vec3(1.0), uInk, 0.35) * (face > 0.5 ? 1.0 : 0.8);
    col += uRim * fres * 0.9 + vec3(1.0) * spec * 0.8;
  } else if (look == 1) {
    vec3 body = vec3(0.025, 0.01, 0.045) + uInk2 * 0.06 * diff;
    float tube = max(rim * face, sideEdge * (1.0 - face));
    vec3 light = mix(uRim, uInk, 0.5 + 0.5 * sin(q.x * 2.0 + uTime));
    col = body + light * tube * (1.6 + 1.4 * uKick) + uInk2 * (1.0 - face) * 0.12;
  } else if (look == 2) {
    vec3 faceC = mix(uInk, uInk2, down * 0.8);
    col = mix(uInk2 * 0.55, faceC, face) * (0.35 + 0.75 * diff) + vec3(1.0) * spec * 0.6 + uRim * fres * 0.5;
  } else if (look == 3) {
    float line = max(rim * face, sideEdge * (1.0 - face) * 0.9);
    float wideRim = 1.0 - smoothstep(0.0, 0.12, abs(d2 + uBevel * 0.5));
    float wideSide = 1.0 - smoothstep(0.0, 0.1, uDepth - abs(q.z));
    float soft = max(wideRim * face, wideSide * (1.0 - face)) * uGlow;
    fragColor = out4(uInk * line * (1.4 + 1.2 * uKick) + mix(uRim, uInk, 0.4) * soft * 0.45 * (1.0 + uKick), max(line, soft * 0.5));
    return;
  } else if (look == 5) {
    // a thin film: its colour by the angle it is seen at, drifting over it
    float film = dot(nw, view);
    vec3 foil = rainbow(film * 1.6 + q.y * 0.3 + q.x * 0.08 + uTime * 0.04);
    foil = mix(foil, foil * mix(vec3(1.0), uInk, 0.4), 0.5);
    vec3 env = studio(reflect(rd, nw));
    col = mix(foil * (0.55 + 0.6 * diff), env, 0.25) + vec3(1.0) * spec * 0.9 + vec3(1.0) * fres * 0.35;
  } else if (look == 6) {
    // glass: what is behind it bent through, its colours split at the edges
    vec3 rr = refract(rd, nw, 1.0 / 1.45);
    vec2 bendUv = (rr.xy - rd.xy) * vec2(-1.0, 1.0) * 0.18;
    float split = 0.012 + 0.03 * fres;
    vec3 back = vec3(behind(suv + bendUv * (1.0 + split * 8.0), rr).r, behind(suv + bendUv, rr).g, behind(suv + bendUv * (1.0 - split * 8.0), rr).b);
    vec3 env = studio(reflect(rd, nw));
    col = back * mix(vec3(1.0), uInk, 0.18) * (0.85 + 0.25 * face);
    col = mix(col, env, fres * 0.6) + vec3(1.0) * spec * 1.2;
    // its edges catch the light
    col += uRim * rim * face * 0.35 + uInk * sideEdge * (1.0 - face) * 0.25;
  } else if (look == 7) {
    // a gradient of the three colours flowing through it
    float f1 = 0.5 + 0.5 * sin(q.x * 1.9 + uTime * 0.55 + sin(q.y * 3.1 + uTime * 0.4) * 1.6);
    float f2 = 0.5 + 0.5 * sin(q.y * 2.7 - uTime * 0.35 + q.z * 4.0 + q.x * 0.7);
    vec3 deep = uInk2 * 0.9, hot = uRim * 1.1;
    vec3 g = mix(mix(deep, hot, f1), mix(hot, uInk, 0.6), f2 * f2);
    float grain = fract(sin(dot(fc, vec2(12.9898, 78.233)) + uTime) * 43758.5453);
    col = g * (0.45 + 0.6 * diff) * (face > 0.5 ? 1.0 : 0.6) + vec3(1.0) * spec * 0.25 + hot * fres * 0.5;
    col += (grain - 0.5) * 0.05;
  } else if (look == 8) {
    // print: flat colours, the shade in dots, a black line round it
    float shade = 1.0 - diff;
    vec2 cell = fract(fc / 7.0) - 0.5;
    float dots = step(length(cell), shade * 0.55);
    vec3 faceC = uInk;
    vec3 sideC = mix(uInk2, uInk2 * 0.35, dots);
    col = mix(sideC, mix(faceC, faceC * 0.75, dots * step(0.55, shade)), face);
    float line = max(rim * face, sideEdge * (1.0 - face));
    line = max(line, smoothstep(0.35, 0.6, fres));
    col = mix(col, vec3(0.02), line);
  } else if (look == 9) {
    // op art: bands across it, black and the ink, sweeping on the beat
    float s = q.y * 24.0 + q.z * 9.0 + (face < 0.5 ? q.x * 12.0 : 0.0) - uTime * 2.2 - uKick * 2.5;
    float band = smoothstep(-0.08, 0.08, sin(s));
    col = mix(vec3(0.01, 0.0, 0.02), mix(uRim, uInk, down) * 1.15, band) * (0.55 + 0.5 * diff) + vec3(1.0) * spec * 0.3 * band;
  } else {
    // mercury: a mirror, its surface never still
    vec3 wob = 0.22 * vec3(sin(q.x * 11.0 + uTime * 1.7), sin(q.y * 13.0 - uTime * 1.3), sin((q.x + q.y) * 8.0 + uTime));
    vec3 n2 = normalize(nw + wob * (0.6 + 0.6 * uKick));
    vec3 env = studio(reflect(rd, n2));
    float l = dot(env, vec3(0.3, 0.5, 0.2));
    col = mix(vec3(l), env, 0.25) * mix(vec3(1.0), uInk, 0.15) * 1.1 + vec3(1.0) * pow(max(dot(reflect(-key, n2), view), 0.0), 60.0);
  }
  // The snare whitens the rim; the kick lifts the light.
  col += vec3(1.0, 0.92, 1.0) * fres * uFlash * 0.8;
  col *= 1.0 + 0.3 * uKick;
  col += glowC * 0.4;
  fragColor = vec4(col, 1.0);
}
