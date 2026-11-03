//! The dancers on wgpu (v1: the native stage's dance.h): the scanned bodies skinned on the
//! GPU, with a depth buffer, lit per pixel (or flat, or chrome reflecting a studio), outlines
//! from the shell's back faces, shadows flattened onto the floor or thrown on a wall, a mirror
//! under the floor, the dust; and the stages' 2D art round them (coloured triangles, round
//! points, fills, a clip) — drawn from the commands the dancers' painter writes
//! (wo_dance::cmd). The picture's alpha is the coverage (shaders/show/under.frag): the paper
//! (the first fill over the whole picture) is none, the bodies all.
use std::borrow::Cow;
use std::collections::HashMap;

use wo_dance::cmd::{Blend, Cmd, Dust, Look3};
use wo_dance::sim::Company;
use wo_dance::{M34, clock::Cam, clock::Spot};

use crate::looks::Treat;
use crate::stage::{Target, WORK};
use crate::{Arena, Gpu};

const BODY: &str = "
struct U {
    skin: array<vec4<f32>, 96>,
    model: mat4x4<f32>,
    view_proj: mat4x4<f32>,
    eye: vec4<f32>, right: vec4<f32>, up: vec4<f32>, fwd: vec4<f32>,
    light: vec4<f32>,       // xyz the light (floor: its slope; wall: the lamp), w the wall's y
    key: vec4<f32>,         // xyz toward the key, w its strength
    key_colour: vec4<f32>,  // w the fill's strength
    fill: vec4<f32>,        // w the ambient
    rim: vec4<f32>,         // w the rim's strength
    colour: vec4<f32>,      // the one colour, or the flat one
    p0: vec4<f32>,          // pass (0 body, 1 outline, 2 floor shadow, 3 wall shadow), inflate, flip z, shade
    p1: vec4<f32>,          // rim power, toon, alpha, dim
    p2: vec4<f32>,          // shade flat, textured
};
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var skin_t: texture_2d<f32>;
@group(0) @binding(2) var skin_s: sampler;
struct VIn { @location(0) pos: vec3<f32>, @location(1) nrm: vec3<f32>, @location(2) bones: vec4<u32>, @location(3) weights: vec4<f32>, @location(4) uv: vec2<f32> };
struct VOut { @builtin(position) clip: vec4<f32>, @location(0) pos: vec3<f32>, @location(1) nrm: vec3<f32>, @location(2) uv: vec2<f32> };
@vertex fn vs(v: VIn) -> VOut {
    var r0 = vec4<f32>(0.0); var r1 = vec4<f32>(0.0); var r2 = vec4<f32>(0.0);
    for (var i = 0; i < 4; i++) {
        let w = v.weights[i];
        if (w <= 0.0) { continue; }
        let b = v.bones[i] * 3u;
        r0 += u.skin[b] * w; r1 += u.skin[b + 1u] * w; r2 += u.skin[b + 2u] * w;
    }
    let p = vec4<f32>(v.pos, 1.0);
    let local = vec3<f32>(dot(r0, p), dot(r1, p), dot(r2, p));
    let n = vec3<f32>(dot(r0.xyz, v.nrm), dot(r1.xyz, v.nrm), dot(r2.xyz, v.nrm));
    var world = u.model * vec4<f32>(local, 1.0);
    var wn = normalize((u.model * vec4<f32>(n, 0.0)).xyz);
    let kind = i32(u.p0.x + 0.5);
    if (kind == 1) { world = vec4<f32>(world.xyz + wn * u.p0.y, world.w); }
    if (kind == 2) {
        world = vec4<f32>(world.xy - u.light.xy * world.z, 0.002, world.w);
    } else if (kind == 3) {
        let dy = world.y - u.light.y;
        let t = select((u.light.w - u.light.y) / dy, 1.0, abs(dy) < 1e-3);
        world = vec4<f32>(u.light.x + (world.x - u.light.x) * t, u.light.w - 0.002, u.light.z + (world.z - u.light.z) * t, world.w);
    }
    if (u.p0.z > 0.5) { world.z = -world.z; wn.z = -wn.z; }
    var o: VOut;
    o.pos = world.xyz;
    o.nrm = wn;
    o.uv = v.uv;
    o.clip = u.view_proj * world;
    return o;
}
fn s3(e0: f32, e1: f32, x: f32) -> f32 { let t = clamp((x - e0) / (e1 - e0), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
// the studio chrome reflects: camera space, x right, y up, z toward the eye
fn chrome_env(r: vec3<f32>) -> vec3<f32> {
    var c: vec3<f32>;
    if (r.y >= 0.0) {
        let k = s3(0.0, 0.85, r.y);
        c = vec3<f32>(1.0 - 0.62 * k, 1.0 - 0.58 * k, 1.0 - 0.48 * k);
    } else {
        let k = s3(0.0, -0.35, r.y);
        let band = exp(-((r.y + 0.12) * (r.y + 0.12)) / 0.002) * 0.25;
        c = vec3<f32>(0.05 + 0.5 * (1.0 - k) * (1.0 - k) + band);
    }
    let line = exp(-(r.y * r.y) / 0.0009) * 0.6;
    let l1 = dot(r, normalize(vec3<f32>(-0.45, 0.55, 0.70)));
    let l2 = dot(r, normalize(vec3<f32>(0.85, 0.15, -0.50)));
    let soft = s3(0.93, 0.975, l1) * 1.4 + s3(0.9, 0.96, l2) * 0.9;
    return c + line + soft;
}
@fragment fn fs(i: VOut) -> @location(0) vec4<f32> {
    let tex = textureSampleLevel(skin_t, skin_s, i.uv, 0.0).rgb;
    let shade = i32(round(u.p0.w));
    if (shade < 0) { return u.colour; }
    var n = normalize(i.nrm);
    let v = normalize(u.eye.xyz - i.pos);
    if (dot(n, v) < 0.0) { n = -n; }
    let edge = 1.0 - abs(dot(n, v));
    var col: vec3<f32>;
    if (shade == 3) {
        let r = reflect(-v, n);
        let rc = vec3<f32>(dot(r, u.right.xyz), dot(r, u.up.xyz), -dot(r, u.fwd.xyz));
        let fres = 0.78 + 0.22 * edge * edge;
        col = chrome_env(rc) * fres * u.key_colour.rgb + u.rim.rgb * edge * edge * edge * u.rim.w;
    } else {
        let kd = normalize(u.key.xyz);
        var diff = max(dot(n, kd), 0.0);
        let toon = u.p1.y;
        if (toon > 0.0) { diff = ceil(diff * toon) / toon; }
        let fill = max(0.5 - 0.5 * (n.x * kd.x + n.y * kd.y) * 0.8 - 0.2 * n.z, 0.0);
        col = vec3<f32>(u.fill.w) + u.key.w * diff * u.key_colour.rgb + u.key_colour.w * fill * u.fill.rgb;
        if (shade == 1) {
            let lit = u.p2.x > 0.5 && dot(u.colour.rgb, vec3<f32>(0.2126, 0.7152, 0.0722)) > 0.02;
            col = u.colour.rgb * select(1.0, 0.75 + 0.35 * diff, lit);
        }
        if (u.rim.w > 0.001) {
            var k = pow(edge, u.p1.x) * u.rim.w;
            if (toon > 0.0) { k = select(0.0, u.rim.w, k > 0.35); }
            col += u.rim.rgb * k;
        }
        // the light held to 1, as a canvas holds a vertex colour
        col = min(col, vec3<f32>(1.0));
        if (u.p2.y > 0.5 && shade == 0) { col *= tex; }
    }
    return vec4<f32>(col * u.p1.w, u.p1.z);
}
";

/// The dust: the body as points (quads here: wgpu draws points a pixel wide), skinned as
/// the body is, which leave it when it bursts, drift, rise and swirl, and come back.
const DUST: &str = "
struct U {
    skin: array<vec4<f32>, 96>,
    model: mat4x4<f32>,
    view_proj: mat4x4<f32>,
    eye: vec4<f32>,
    a: vec4<f32>,      // w alpha
    b: vec4<f32>,      // w mode
    p0: vec4<f32>,     // size, focal (pixels), explode, swirl
    p1: vec4<f32>,     // rise, time, shimmer, textured
    size: vec4<f32>,   // the target's width and height
};
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var skin_t: texture_2d<f32>;
@group(0) @binding(2) var skin_s: sampler;
struct VIn { @location(0) pos: vec3<f32>, @location(1) nrm: vec3<f32>, @location(2) bones: vec4<u32>, @location(3) weights: vec4<f32>, @location(4) uv: vec2<f32> };
struct VOut { @builtin(position) clip: vec4<f32>, @location(0) uv: vec2<f32>, @location(1) q: vec2<f32>, @location(2) lkhf: vec4<f32>, @location(3) share: f32 };
fn h11(x: f32) -> f32 { return fract(sin(x * 12.9898 + 4.1414) * 43758.5453); }
fn flow(p: vec3<f32>, t: f32) -> vec3<f32> {
    return vec3<f32>(sin(p.y * 1.7 + t * 0.9) + sin(p.z * 2.3 - t * 0.7),
                     sin(p.z * 1.9 + t * 0.8) + sin(p.x * 2.1 + t * 1.1),
                     sin(p.x * 1.6 - t * 0.6) + sin(p.y * 2.4 + t * 0.5)) * 0.5;
}
@vertex fn vs(v: VIn, @builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> VOut {
    var r0 = vec4<f32>(0.0); var r1 = vec4<f32>(0.0); var r2 = vec4<f32>(0.0);
    for (var i = 0; i < 4; i++) {
        let w = v.weights[i];
        if (w <= 0.0) { continue; }
        let b = v.bones[i] * 3u;
        r0 += u.skin[b] * w; r1 += u.skin[b + 1u] * w; r2 += u.skin[b + 2u] * w;
    }
    let p = vec4<f32>(v.pos, 1.0);
    let local = vec3<f32>(dot(r0, p), dot(r1, p), dot(r2, p));
    let n = vec3<f32>(dot(r0.xyz, v.nrm), dot(r1.xyz, v.nrm), dot(r2.xyz, v.nrm));
    var world = (u.model * vec4<f32>(local, 1.0)).xyz;
    var wn = normalize((u.model * vec4<f32>(n, 0.0)).xyz);
    if (dot(wn, u.eye.xyz - world) < 0.0) { wn = -wn; }
    let id = f32(ii);
    let h1 = h11(id * 0.1234); let h2 = h11(id * 0.731 + 3.1); let h3 = h11(id * 1.917 + 7.7);
    let rnd = normalize(vec3<f32>(h1, h2, h3) - 0.5 + 1e-4);
    let order = clamp(1.0 - world.z / 1.9, 0.0, 1.0) * 0.6 + h2 * 0.4;
    let k = smoothstep(order * 0.7, order * 0.7 + 0.3, u.p0.z);
    var off = (wn * 0.25 + rnd * 0.5) * k * (0.35 + h3);
    off.z += u.p1.x * k * k * (0.4 + h1);
    off += flow(world * 1.3 + rnd * 2.0, u.p1.y * 0.6) * u.p0.w * k * 0.6;
    off += rnd * u.p1.z * 0.012;
    world += off;
    var clip = u.view_proj * vec4<f32>(world, 1.0);
    let px = u.p0.x * u.p0.y / max(clip.w, 0.05);
    let size = clamp(px * (1.0 - 0.3 * k), 1.0, 9.0);
    // GL drew a point of a pixel or so as a whole pixel; a quad that small misses the
    // pixels' middles: drawn two pixels at least, its light spread over them
    let quad = max(size, 2.0);
    let corner = vec2<f32>(f32(vi & 1u), f32((vi >> 1u) & 1u)) * 2.0 - 1.0;
    clip = vec4<f32>(clip.xy + corner * quad / u.size.xy * clip.w, clip.zw);
    var o: VOut;
    o.clip = clip;
    o.uv = v.uv;
    o.q = corner;
    let fade = mix(clamp(pow(px / 2.4, 1.5), 0.1, 1.0), 1.0, k * 0.8);
    o.lkhf = vec4<f32>(max(dot(wn, normalize(vec3<f32>(-0.35, -0.8, 0.65))), 0.0), k, clamp(world.z / 1.9, 0.0, 1.0), fade);
    // a soft disc's light is about 0.45 of its square's; a GL point of a pixel, all of it
    o.share = select(1.0, (size * size) / (quad * quad * 0.45), size < quad);
    return o;
}
@fragment fn fs(i: VOut) -> @location(0) vec4<f32> {
    let tex = textureSampleLevel(skin_t, skin_s, i.uv, 0.0).rgb;
    let r2 = dot(i.q, i.q);
    if (r2 > 1.0) { discard; }
    let soft = 1.0 - r2 * r2;
    let lit = i.lkhf.x; let k = i.lkhf.y; let hgt = i.lkhf.z; let fade = i.lkhf.w;
    let mode = i32(round(u.b.w));
    var col: vec3<f32>;
    if (mode == 0 && u.p1.w > 0.5) { col = tex * (0.6 + 0.6 * lit); }
    else if (mode == 2) { col = mix(u.a.rgb, u.b.rgb, hgt) * (0.55 + 0.6 * lit); }
    else { col = u.a.rgb * (0.45 + 0.75 * lit); }
    col = mix(col, u.b.rgb * 0.9, k * 0.55);
    let a = soft * u.a.w * fade * i.share;
    return vec4<f32>(col * a, a * 3.0);
}
";

/// The stages' 2D: coloured triangles on the picture (pixels, y down).
const FLAT: &str = "
struct U { r: vec4<f32> };
@group(0) @binding(0) var<uniform> u: U;
struct VOut { @builtin(position) clip: vec4<f32>, @location(0) c: vec4<f32> };
@vertex fn vs(@location(0) p: vec2<f32>, @location(1) c: vec4<f32>) -> VOut {
    let ndc = p / u.r.xy * 2.0 - 1.0;
    var o: VOut;
    o.clip = vec4<f32>(ndc.x, -ndc.y, 0.0, 1.0);
    o.c = c;
    return o;
}
@fragment fn fs(i: VOut) -> @location(0) vec4<f32> { return i.c; }
";

/// Soft round points: a quad each, instanced.
const DOTS: &str = "
struct U { r: vec4<f32>, c: vec4<f32> };  // reference size, radius; the colour
@group(0) @binding(0) var<uniform> u: U;
struct VOut { @builtin(position) clip: vec4<f32>, @location(0) l: vec2<f32> };
@vertex fn vs(@builtin(vertex_index) vi: u32, @location(0) at: vec2<f32>) -> VOut {
    let corner = vec2<f32>(f32(vi & 1u), f32((vi >> 1u) & 1u)) * 2.0 - 1.0;
    let ndc = (at + corner * u.r.z) / u.r.xy * 2.0 - 1.0;
    var o: VOut;
    o.clip = vec4<f32>(ndc.x, -ndc.y, 0.0, 1.0);
    o.l = corner;
    return o;
}
@fragment fn fs(i: VOut) -> @location(0) vec4<f32> {
    let a = 1.0 - smoothstep(0.7, 1.0, length(i.l));
    return vec4<f32>(u.c.rgb, u.c.a * a);
}
";

const DEPTH: wgpu::TextureFormat = wgpu::TextureFormat::Depth32Float;

fn blend_state(b: Blend) -> Option<wgpu::BlendState> {
    use wgpu::{BlendComponent as C, BlendFactor as F, BlendOperation as O};
    let c = |src, dst, op| C { src_factor: src, dst_factor: dst, operation: op };
    match b {
        Blend::Over => Some(wgpu::BlendState { color: c(F::SrcAlpha, F::OneMinusSrcAlpha, O::Add), alpha: c(F::One, F::OneMinusSrcAlpha, O::Add) }),
        Blend::Plus => Some(wgpu::BlendState { color: c(F::SrcAlpha, F::One, O::Add), alpha: c(F::SrcAlpha, F::One, O::Add) }),
        Blend::Src => None,
        Blend::Darken => Some(wgpu::BlendState { color: c(F::One, F::One, O::Min), alpha: c(F::One, F::One, O::Min) }),
    }
}

/// Which pipeline: what draws, how it blends, its faces and depth.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Kind {
    Body,
    Flat,
    Dots,
    Dust,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct Key {
    kind: Kind,
    blend: Blend,
    /// Cull the front faces (an outline: the shell's back faces), wound clockwise.
    cull_front: bool,
    cw: bool,
    depth_test: bool,
    depth_write: bool,
}

/// A model's mesh on the GPU: its corners (position, normal, bones, weights, skin place),
/// its triangles, and its points for the dust (built the first time it is dust).
struct GpuMesh {
    vertices: wgpu::Buffer,
    indices: wgpu::Buffer,
    count: u32,
    dust: Option<(wgpu::Buffer, u32)>,
    mesh: wo_dance::Mesh,
}

/// A body posed into a slot this frame.
struct Posed {
    mesh: (&'static str, usize),
    skin: [[f32; 4]; 96],
    model: [f32; 16],
    mirrored: bool,
}

/// The camera as the shaders take it.
#[derive(Clone, Copy)]
struct CamU {
    view_proj: [f32; 16],
    eye: [f32; 3],
    right: [f32; 3],
    up: [f32; 3],
    fwd: [f32; 3],
    focal: f32,
    ref_w: f32,
    ref_h: f32,
}

/// DanceCam as a matrix (dance.h camera()): screen x = cx + focal·(d·right)/z, y (down) =
/// cy − focal·(d·up)/z, z = d·forward; depth 0..1 between 0.05 and 200 m.
fn cam_u(c: &Cam) -> CamU {
    let (r, u, f) = (c.right, c.up, c.f);
    let (w, h) = (c.w as f32, c.h as f32);
    let focal = (c.h / 2.0 / (c.fov / 2.0).tan()) as f32;
    let (cx, cy) = (w / 2.0 + c.shift.0 as f32 * w, h / 2.0 + c.shift.1 as f32 * h);
    let (n, fa) = (0.05f32, 200.0f32);
    let (ax, bx) = (2.0 * focal / w, 2.0 * cx / w - 1.0);
    let (ay, by) = (2.0 * focal / h, 1.0 - 2.0 * cy / h);
    let (az, bz) = (fa / (fa - n), -fa * n / (fa - n));
    let (r, u, f) = ([r.x as f32, r.y as f32, r.z as f32], [u.x as f32, u.y as f32, u.z as f32], [f.x as f32, f.y as f32, f.z as f32]);
    let e = [c.eye.x as f32, c.eye.y as f32, c.eye.z as f32];
    let mut rows = [[0f32; 4]; 4];
    for k in 0..3 {
        rows[0][k] = ax * r[k] + bx * f[k];
        rows[1][k] = ay * u[k] + by * f[k];
        rows[2][k] = az * f[k];
        rows[3][k] = f[k];
    }
    for row in &mut rows {
        row[3] = -(row[0] * e[0] + row[1] * e[1] + row[2] * e[2]);
    }
    rows[2][3] += bz;
    let mut m = [0f32; 16];
    for col in 0..4 {
        for row in 0..4 {
            m[col * 4 + row] = rows[row][col];
        }
    }
    CamU { view_proj: m, eye: e, right: r, up: u, fwd: f, focal, ref_w: w, ref_h: h }
}

/// A spot as a matrix (dance.h spot()): T · R(yaw) · S(scale) · Mirror(x), column-major.
fn spot_matrix(s: &Spot) -> [f32; 16] {
    let (x, y, yaw, k, lift) = (s.x as f32, s.y as f32, s.yaw as f32, s.scale as f32, s.lift as f32);
    let m = if s.mirror { -1.0 } else { 1.0 };
    let (c, sn) = (yaw.cos(), yaw.sin());
    [c * k * m, sn * k * m, 0.0, 0.0, -sn * k, c * k, 0.0, 0.0, 0.0, 0.0, k, 0.0, x, y, lift, 1.0]
}

fn skin_rows(skin: &[M34]) -> [[f32; 4]; 96] {
    let mut out = [[0f32; 4]; 96];
    for (b, m) in skin.iter().take(32).enumerate() {
        for r in 0..3 {
            out[b * 3 + r] = [m[r * 4] as f32, m[r * 4 + 1] as f32, m[r * 4 + 2] as f32, m[r * 4 + 3] as f32];
        }
    }
    out
}

fn bytes(fl: &[f32]) -> Vec<u8> {
    fl.iter().flat_map(|f| f.to_le_bytes()).collect()
}

/// The dancers' renderer: every model's meshes and skins on the GPU, its pipelines.
pub struct Dance {
    meshes: HashMap<(&'static str, usize), GpuMesh>,
    skins: HashMap<&'static str, wgpu::TextureView>,
    white: wgpu::TextureView,
    sampler: wgpu::Sampler,
    pipelines: HashMap<Key, wgpu::RenderPipeline>,
    layouts: HashMap<Kind, wgpu::BindGroupLayout>,
    modules: HashMap<Kind, wgpu::ShaderModule>,
    depth: Option<(wgpu::Texture, wgpu::TextureView, u32, u32)>,
    flat_buf: Option<wgpu::Buffer>,
    /// The bodies drawn last frame (for a test, a log).
    pub bodies: usize,
}

/// One corner: position, normal (f32 ×3 each), bones, weights (u8 ×4 each), skin place (f32 ×2).
const CORNER: u64 = 40;

fn corner_layout(step: wgpu::VertexStepMode) -> wgpu::VertexBufferLayout<'static> {
    const ATTRS: [wgpu::VertexAttribute; 5] = wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3, 2 => Uint8x4, 3 => Unorm8x4, 4 => Float32x2];
    wgpu::VertexBufferLayout { array_stride: CORNER, step_mode: step, attributes: &ATTRS }
}

impl Dance {
    pub fn new(gpu: &Gpu, co: &Company) -> Dance {
        use wgpu::util::DeviceExt;
        let d = &gpu.device;
        let mut meshes = HashMap::new();
        let mut skins = HashMap::new();
        for (name, rig) in &co.rigs {
            for (i, m) in rig.meshes.iter().enumerate() {
                let mut corners = Vec::with_capacity(m.corners() * CORNER as usize);
                for k in 0..m.corners() {
                    let p = m.src[k] as usize;
                    for c in 0..3 {
                        corners.extend_from_slice(&m.pos[p * 3 + c].to_le_bytes());
                    }
                    for c in 0..3 {
                        corners.extend_from_slice(&m.nrm[p * 3 + c].to_le_bytes());
                    }
                    corners.extend_from_slice(&m.bone[p * 4..p * 4 + 4]);
                    corners.extend_from_slice(&m.weight[p * 4..p * 4 + 4]);
                    corners.extend_from_slice(&m.uv[k * 2].to_le_bytes());
                    corners.extend_from_slice(&m.uv[k * 2 + 1].to_le_bytes());
                }
                let vertices = d.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: Some("a dancer's corners"), contents: &corners, usage: wgpu::BufferUsages::VERTEX });
                let mut idx: Vec<u8> = m.tris.iter().flat_map(|t| t.to_le_bytes()).collect();
                // a copy's size a multiple of four
                idx.resize(idx.len().div_ceil(4) * 4, 0);
                let indices = d.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: Some("a dancer's triangles"), contents: &idx, usage: wgpu::BufferUsages::INDEX });
                meshes.insert((*name, i), GpuMesh { vertices, indices, count: m.tris.len() as u32, dust: None, mesh: m.clone() });
            }
            if let Some((w, h, rgba)) = rig.skin_rgba() {
                skins.insert(*name, crate::upload(gpu, w, h, &rgba).create_view(&Default::default()));
            }
        }
        let white = crate::upload(gpu, 1, 1, &[255, 255, 255, 255]).create_view(&Default::default());
        let sampler = crate::stage::sampler(gpu);
        let mut modules = HashMap::new();
        let mut layouts = HashMap::new();
        for (kind, src, tex) in [(Kind::Body, BODY, true), (Kind::Dust, DUST, true), (Kind::Flat, FLAT, false), (Kind::Dots, DOTS, false)] {
            modules.insert(kind, d.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some("dancers"), source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(src)) }));
            let mut e = vec![wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
                count: None,
            }];
            if tex {
                e.push(wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: true }, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false },
                    count: None,
                });
                e.push(wgpu::BindGroupLayoutEntry { binding: 2, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering), count: None });
            }
            layouts.insert(kind, d.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("dancers"), entries: &e }));
        }
        let mut d = Dance { meshes, skins, white, sampler, pipelines: HashMap::new(), layouts, modules, depth: None, flat_buf: None, bodies: 0 };
        // every pipeline a frame may ask for, built now: none waits for a compiler mid-show
        // (Direct3D's stalls a frame for a quarter of a second)
        let all = [Blend::Over, Blend::Plus, Blend::Src, Blend::Darken];
        let mut keys = vec![];
        for b in all {
            keys.push(Key { kind: Kind::Body, blend: b, cull_front: false, cw: false, depth_test: true, depth_write: b != Blend::Plus });
            keys.push(Key { kind: Kind::Flat, blend: b, cull_front: false, cw: false, depth_test: false, depth_write: false });
        }
        for b in [Blend::Over, Blend::Plus] {
            for cw in [false, true] {
                keys.push(Key { kind: Kind::Body, blend: b, cull_front: true, cw, depth_test: true, depth_write: b == Blend::Over });
            }
            keys.push(Key { kind: Kind::Dots, blend: b, cull_front: false, cw: false, depth_test: false, depth_write: false });
        }
        keys.push(Key { kind: Kind::Body, blend: Blend::Darken, cull_front: false, cw: false, depth_test: false, depth_write: false });
        keys.push(Key { kind: Kind::Dust, blend: Blend::Plus, cull_front: false, cw: false, depth_test: false, depth_write: false });
        for k in keys {
            d.pipeline(gpu, k);
        }
        d
    }

    fn pipeline(&mut self, gpu: &Gpu, k: Key) -> &wgpu::RenderPipeline {
        if !self.pipelines.contains_key(&k) {
            let d = &gpu.device;
            let layout = &self.layouts[&k.kind];
            let pl = d.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: Some("dancers"), bind_group_layouts: &[Some(layout)], ..Default::default() });
            let module = &self.modules[&k.kind];
            const FLAT_ATTRS: [wgpu::VertexAttribute; 2] = wgpu::vertex_attr_array![0 => Float32x2, 1 => Float32x4];
            const DOT_ATTRS: [wgpu::VertexAttribute; 1] = wgpu::vertex_attr_array![0 => Float32x2];
            let buffers: Vec<Option<wgpu::VertexBufferLayout>> = match k.kind {
                Kind::Body => vec![Some(corner_layout(wgpu::VertexStepMode::Vertex))],
                Kind::Dust => vec![Some(corner_layout(wgpu::VertexStepMode::Instance))],
                Kind::Flat => vec![Some(wgpu::VertexBufferLayout { array_stride: 24, step_mode: wgpu::VertexStepMode::Vertex, attributes: &FLAT_ATTRS })],
                Kind::Dots => vec![Some(wgpu::VertexBufferLayout { array_stride: 8, step_mode: wgpu::VertexStepMode::Instance, attributes: &DOT_ATTRS })],
            };
            let blend = if k.kind == Kind::Dust {
                Some(wgpu::BlendState { color: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add }, alpha: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add } })
            } else {
                blend_state(k.blend)
            };
            let strip = matches!(k.kind, Kind::Dots | Kind::Dust);
            let p = d.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("dancers"),
                layout: Some(&pl),
                vertex: wgpu::VertexState {
                    module,
                    entry_point: Some("vs"),
                    buffers: &buffers,
                    compilation_options: Default::default(),
                },
                fragment: Some(wgpu::FragmentState {
                    module,
                    entry_point: Some("fs"),
                    targets: &[Some(wgpu::ColorTargetState { format: WORK, blend, write_mask: wgpu::ColorWrites::ALL })],
                    compilation_options: Default::default(),
                }),
                primitive: wgpu::PrimitiveState {
                    topology: if strip { wgpu::PrimitiveTopology::TriangleStrip } else { wgpu::PrimitiveTopology::TriangleList },
                    front_face: if k.cw { wgpu::FrontFace::Cw } else { wgpu::FrontFace::Ccw },
                    cull_mode: k.cull_front.then_some(wgpu::Face::Front),
                    ..Default::default()
                },
                depth_stencil: Some(wgpu::DepthStencilState {
                    format: DEPTH,
                    depth_write_enabled: Some(k.depth_write),
                    depth_compare: Some(if k.depth_test { wgpu::CompareFunction::LessEqual } else { wgpu::CompareFunction::Always }),
                    stencil: Default::default(),
                    bias: Default::default(),
                }),
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            });
            self.pipelines.insert(k, p);
        }
        &self.pipelines[&k]
    }

    /// The dust's points over a mesh's surface: about this many by area, each with the
    /// position, normal, four heaviest bones and the skin place where it lies, shuffled so
    /// any first share is even (dance.h buildDust).
    const DUST_POINTS: usize = 160_000;

    fn build_dust(gpu: &Gpu, gm: &mut GpuMesh) {
        use wgpu::util::DeviceExt;
        if gm.dust.is_some() {
            return;
        }
        let m = &gm.mesh;
        let tris = m.tris.len() / 3;
        let p = |c: u16| {
            let i = m.src[c as usize] as usize * 3;
            [m.pos[i], m.pos[i + 1], m.pos[i + 2]]
        };
        let area: Vec<f32> = (0..tris)
            .map(|t| {
                let (a, b, c) = (p(m.tris[t * 3]), p(m.tris[t * 3 + 1]), p(m.tris[t * 3 + 2]));
                let (u, v) = ([b[0] - a[0], b[1] - a[1], b[2] - a[2]], [c[0] - a[0], c[1] - a[1], c[2] - a[2]]);
                let (x, y, z) = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]);
                0.5 * (x * x + y * y + z * z).sqrt()
            })
            .collect();
        let total: f64 = area.iter().map(|&a| a as f64).sum();
        if total <= 0.0 {
            return;
        }
        let mut seed: u32 = 0x9e37_79b9;
        let mut rnd = || {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (seed >> 8) as f32 / 16_777_216.0
        };
        let mut buf: Vec<u8> = Vec::with_capacity(Self::DUST_POINTS * CORNER as usize);
        for (t, &ar) in area.iter().enumerate() {
            let want = (ar as f64 / total * Self::DUST_POINTS as f64) as f32;
            let k = want as i32 + i32::from(rnd() < want - want.floor());
            let cs = [m.tris[t * 3] as usize, m.tris[t * 3 + 1] as usize, m.tris[t * 3 + 2] as usize];
            for _ in 0..k {
                let (mut bu, mut bv) = (rnd(), rnd());
                if bu + bv > 1.0 {
                    bu = 1.0 - bu;
                    bv = 1.0 - bv;
                }
                let bw = [1.0 - bu - bv, bu, bv];
                let (mut pos, mut nrm, mut uv) = ([0f32; 3], [0f32; 3], [0f32; 2]);
                let mut wsum = [0f32; 256];
                let mut used: Vec<usize> = vec![];
                for q in 0..3 {
                    let pi = m.src[cs[q]] as usize;
                    for d in 0..3 {
                        pos[d] += m.pos[pi * 3 + d] * bw[q];
                        nrm[d] += m.nrm[pi * 3 + d] * bw[q];
                    }
                    uv[0] += m.uv[cs[q] * 2] * bw[q];
                    uv[1] += m.uv[cs[q] * 2 + 1] * bw[q];
                    for e in 0..4 {
                        let bone = m.bone[pi * 4 + e] as usize;
                        let w = m.weight[pi * 4 + e] as f32 / 255.0 * bw[q];
                        if w <= 0.0 {
                            continue;
                        }
                        if wsum[bone] == 0.0 {
                            used.push(bone);
                        }
                        wsum[bone] += w;
                    }
                }
                // the four heaviest, to 255 together
                let (mut bones, mut top) = ([0u8; 4], [0f32; 4]);
                for &bone in &used {
                    let w = wsum[bone];
                    for s in 0..4 {
                        if w > top[s] {
                            for r in (s + 1..4).rev() {
                                top[r] = top[r - 1];
                                bones[r] = bones[r - 1];
                            }
                            top[s] = w;
                            bones[s] = bone as u8;
                            break;
                        }
                    }
                }
                let sum: f32 = top.iter().sum();
                let mut weights = [0u8; 4];
                let mut given = 0i32;
                for s in 0..4 {
                    weights[s] = (if sum > 0.0 { top[s] / sum * 255.0 } else if s == 0 { 255.0 } else { 0.0 }).round() as u8;
                    given += weights[s] as i32;
                }
                weights[0] = (weights[0] as i32 + 255 - given).clamp(0, 255) as u8;
                let nl = (nrm[0] * nrm[0] + nrm[1] * nrm[1] + nrm[2] * nrm[2]).sqrt() + 1e-6;
                for x in &mut nrm {
                    *x /= nl;
                }
                for v in pos.iter().chain(&nrm) {
                    buf.extend_from_slice(&v.to_le_bytes());
                }
                buf.extend_from_slice(&bones);
                buf.extend_from_slice(&weights);
                for v in uv {
                    buf.extend_from_slice(&v.to_le_bytes());
                }
            }
        }
        let n = buf.len() / CORNER as usize;
        for a in (2..=n).rev() {
            let b = ((rnd() * a as f32) as usize) % a;
            if b != a - 1 {
                for q in 0..CORNER as usize {
                    buf.swap((a - 1) * CORNER as usize + q, b * CORNER as usize + q);
                }
            }
        }
        let vb = gpu.device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: Some("a dancer's dust"), contents: &buf, usage: wgpu::BufferUsages::VERTEX });
        gm.dust = Some((vb, n as u32));
    }

    /// The commands into `target` (the working picture), its depth alongside; a finish
    /// through `scratch` and back.
    #[allow(clippy::too_many_arguments)]
    pub fn draw(&mut self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, treat: &Treat, cmds: &[Cmd], target: &Target, scratch: &Target) {
        let (w, h) = (target.w, target.h);
        if self.depth.as_ref().is_none_or(|d| d.2 != w || d.3 != h) {
            let t = gpu.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("the dancers' depth"),
                size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: DEPTH,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            let v = t.create_view(&Default::default());
            self.depth = Some((t, v, w, h));
        }
        // the 2D's triangles and points, all of the frame's in one buffer
        // the first fill over the whole picture is the stage's paper (its backdrop): in its
        // colour but at no coverage, replacing what is there, so the blend can treat it as the
        // ground's to take where the bodies over it are the figure's
        let mut flat: Vec<u8> = vec![];
        let mut flat_at: Vec<(u64, u32, bool)> = vec![];
        let (mut rw, mut rh) = (w as f32, h as f32);
        let mut first = true;
        for c in cmds {
            let start = flat.len() as u64;
            match c {
                Cmd::Camera(c) => (rw, rh) = (c.w as f32, c.h as f32),
                Cmd::Fill { rect, colour, .. } => {
                    let [x0, y0, x1, y1] = *rect;
                    let paper = first && x0 <= 0.0 && y0 <= 0.0 && x1 >= rw && y1 >= rh;
                    let a = if paper { 0.0 } else { colour[3] };
                    for [x, y] in [[x0, y0], [x1, y0], [x1, y1], [x0, y0], [x1, y1], [x0, y1]] {
                        flat.extend(bytes(&[x, y, colour[0], colour[1], colour[2], a]));
                    }
                    flat_at.push((start, 6, paper));
                }
                Cmd::Tris { verts, .. } => {
                    for v in verts {
                        flat.extend(bytes(v));
                    }
                    flat_at.push((start, verts.len() as u32, false));
                }
                Cmd::Points { at, .. } => {
                    for p in at {
                        flat.extend(bytes(p));
                    }
                    flat_at.push((start, at.len() as u32, false));
                }
                _ => {}
            }
            if matches!(c, Cmd::Fill { .. } | Cmd::Tris { .. } | Cmd::Points { .. } | Cmd::Body { .. } | Cmd::Dust { .. }) {
                first = false;
            }
        }
        if !flat.is_empty() {
            if self.flat_buf.as_ref().is_none_or(|b| (b.size() as usize) < flat.len()) {
                self.flat_buf = Some(gpu.device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("the dancers' 2D"),
                    size: (flat.len().next_power_of_two()).max(65536) as u64,
                    usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                    mapped_at_creation: false,
                }));
            }
            gpu.queue.write_buffer(self.flat_buf.as_ref().unwrap(), 0, &flat);
        }
        // the poses, and the meshes the dust needs
        let mut posed: HashMap<usize, Posed> = HashMap::new();
        for c in cmds {
            if let Cmd::Dust { slot, .. } = c
                && let Some(Cmd::Pose { model, mesh, .. }) = cmds.iter().find(|p| matches!(p, Cmd::Pose { slot: s, .. } if s == slot))
                && let Some(gm) = self.meshes.get_mut(&(*model, *mesh))
            {
                Self::build_dust(gpu, gm);
            }
        }
        let mut cam: Option<CamU> = None;
        let mut flat_i = 0usize;
        let mut clear = true;
        let mut clear_depth = true;
        let mut i = 0usize;
        self.bodies = 0;
        while i < cmds.len() {
            // one render pass up to a finish or a depth clear
            let depth_view = self.depth.as_ref().unwrap().1.clone();
            let mut rp = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("the dancers"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &target.view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations { load: if clear { wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT) } else { wgpu::LoadOp::Load }, store: wgpu::StoreOp::Store },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: &depth_view,
                    depth_ops: Some(wgpu::Operations { load: if clear_depth { wgpu::LoadOp::Clear(1.0) } else { wgpu::LoadOp::Load }, store: wgpu::StoreOp::Store }),
                    stencil_ops: None,
                }),
                ..Default::default()
            });
            clear = false;
            clear_depth = false;
            let mut leave: Option<&Cmd> = None;
            while i < cmds.len() {
                let c = &cmds[i];
                i += 1;
                match c {
                    Cmd::Post(_) | Cmd::ClearDepth => {
                        leave = Some(c);
                        break;
                    }
                    Cmd::Camera(c) => cam = Some(cam_u(c)),
                    Cmd::Clip(r) => {
                        let (rw, rh) = cam.map_or((w as f32, h as f32), |c| (c.ref_w, c.ref_h));
                        match r {
                            Some([x0, y0, x1, y1]) => {
                                let (sx, sy) = (w as f32 / rw, h as f32 / rh);
                                let x = (x0 * sx).clamp(0.0, w as f32) as u32;
                                let y = (y0 * sy).clamp(0.0, h as f32) as u32;
                                let xw = ((x1 * sx).clamp(0.0, w as f32) as u32).saturating_sub(x);
                                let yh = ((y1 * sy).clamp(0.0, h as f32) as u32).saturating_sub(y);
                                rp.set_scissor_rect(x, y, xw.max(1), yh.max(1));
                            }
                            None => rp.set_scissor_rect(0, 0, w, h),
                        }
                    }
                    Cmd::Pose { slot, model, mesh, skin, spot } => {
                        let model_m = spot_matrix(spot);
                        posed.insert(*slot, Posed { mesh: (*model, *mesh), skin: skin_rows(skin), model: model_m, mirrored: model_m[0] * model_m[5] - model_m[1] * model_m[4] < 0.0 });
                    }
                    Cmd::Fill { blend, .. } | Cmd::Tris { blend, .. } => {
                        let (at, n, paper) = flat_at[flat_i];
                        flat_i += 1;
                        let b = if paper { Blend::Src } else { *blend };
                        let (rw, rh) = cam.map_or((w as f32, h as f32), |c| (c.ref_w, c.ref_h));
                        let Some(binding) = arena.push(&bytes(&[rw, rh, 0.0, 0.0])) else { continue };
                        let group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
                            label: None,
                            layout: &self.layouts[&Kind::Flat],
                            entries: &[wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Buffer(binding) }],
                        });
                        let key = Key { kind: Kind::Flat, blend: b, cull_front: false, cw: false, depth_test: false, depth_write: false };
                        rp.set_pipeline(self.pipeline(gpu, key));
                        rp.set_bind_group(0, &group, &[]);
                        rp.set_vertex_buffer(0, self.flat_buf.as_ref().unwrap().slice(at..at + n as u64 * 24));
                        rp.draw(0..n, 0..1);
                    }
                    Cmd::Points { radius, colour, blend, .. } => {
                        let (at, n, _) = flat_at[flat_i];
                        flat_i += 1;
                        let (rw, rh) = cam.map_or((w as f32, h as f32), |c| (c.ref_w, c.ref_h));
                        let Some(binding) = arena.push(&bytes(&[rw, rh, *radius, 0.0, colour[0], colour[1], colour[2], colour[3]])) else { continue };
                        let group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
                            label: None,
                            layout: &self.layouts[&Kind::Dots],
                            entries: &[wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Buffer(binding) }],
                        });
                        let key = Key { kind: Kind::Dots, blend: *blend, cull_front: false, cw: false, depth_test: false, depth_write: false };
                        rp.set_pipeline(self.pipeline(gpu, key));
                        rp.set_bind_group(0, &group, &[]);
                        rp.set_vertex_buffer(0, self.flat_buf.as_ref().unwrap().slice(at..at + n as u64 * 8));
                        rp.draw(0..4, 0..n);
                    }
                    Cmd::Body { slot, look, under_floor, blend } => {
                        self.bodies += 1;
                        self.body_pass(gpu, &mut rp, arena, &posed, cam.as_ref(), *slot, BodyPass::Body(look, *under_floor), *blend);
                    }
                    Cmd::Outline { slot, width, colour, blend } => self.body_pass(gpu, &mut rp, arena, &posed, cam.as_ref(), *slot, BodyPass::Outline(*width, *colour), *blend),
                    Cmd::FloorShadow { slot, to_light, colour } => {
                        if to_light.z >= 0.05 {
                            let slope = [(to_light.x / to_light.z) as f32, (to_light.y / to_light.z) as f32, 0.0];
                            self.body_pass(gpu, &mut rp, arena, &posed, cam.as_ref(), *slot, BodyPass::Shadow(2, slope, 0.0, *colour), Blend::Darken);
                        }
                    }
                    Cmd::WallShadow { slot, lamp, wall_y, colour } => {
                        let l = [lamp.x as f32, lamp.y as f32, lamp.z as f32];
                        self.body_pass(gpu, &mut rp, arena, &posed, cam.as_ref(), *slot, BodyPass::Shadow(3, l, *wall_y, *colour), Blend::Darken);
                    }
                    Cmd::Dust { slot, dust } => {
                        self.dust_pass(gpu, &mut rp, arena, &posed, cam.as_ref(), *slot, dust, w, h);
                    }
                }
            }
            drop(rp);
            match leave {
                Some(Cmd::Post(p)) => {
                    let rh = cam.map_or(h as f32, |c| c.ref_h);
                    treat.draw_post(gpu, enc, arena, target, scratch, p, h as f32 / rh, 1.0);
                    enc.copy_texture_to_texture(scratch.texture.as_image_copy(), target.texture.as_image_copy(), target.texture.size());
                }
                Some(Cmd::ClearDepth) => clear_depth = true,
                _ => {}
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn body_pass(&mut self, gpu: &Gpu, rp: &mut wgpu::RenderPass<'_>, arena: &mut Arena, posed: &HashMap<usize, Posed>, cam: Option<&CamU>, slot: usize, pass: BodyPass, blend: Blend) {
        let (Some(p), Some(c)) = (posed.get(&slot), cam) else { return };
        if !self.meshes.contains_key(&p.mesh) {
            return;
        }
        let key = match pass {
            // an added body (an afterimage) does not hide what is behind it
            BodyPass::Body(..) => Key { kind: Kind::Body, blend, cull_front: false, cw: false, depth_test: true, depth_write: blend != Blend::Plus },
            // the shell's back faces only: the outline round the body, behind it
            BodyPass::Outline(..) => Key { kind: Kind::Body, blend, cull_front: true, cw: p.mirrored, depth_test: true, depth_write: blend == Blend::Over },
            // a shadow: flat on its plane, every face, no depth (it lies under the bodies)
            BodyPass::Shadow(..) => Key { kind: Kind::Body, blend: Blend::Darken, cull_front: false, cw: false, depth_test: false, depth_write: false },
        };
        self.pipeline(gpu, key);
        let gm = &self.meshes[&p.mesh];
        let mut fl: Vec<f32> = p.skin.iter().flatten().copied().collect();
        fl.extend_from_slice(&p.model);
        fl.extend_from_slice(&c.view_proj);
        for v in [c.eye, c.right, c.up, c.fwd] {
            fl.extend_from_slice(&[v[0], v[1], v[2], 0.0]);
        }
        let none = Look3::default();
        let (kind, inflate, light, wall_y, colour, look, under) = match pass {
            BodyPass::Body(l, under) => (0.0, 0.0, [0.0; 3], 0.0, l.flat.unwrap_or([0.0; 4]), l, under),
            BodyPass::Outline(width, colour) => (1.0, width, [0.0; 3], 0.0, colour, &none, false),
            BodyPass::Shadow(k, light, wall_y, col) => (k as f32, 0.0, light, wall_y, [col[0], col[1], col[2], 1.0], &none, false),
        };
        let shade = match pass {
            BodyPass::Body(l, _) => {
                if l.chrome {
                    3.0
                } else if l.flat.is_some() {
                    1.0
                } else {
                    0.0
                }
            }
            _ => -1.0,
        };
        let k = look.key;
        fl.extend_from_slice(&[light[0], light[1], light[2], wall_y]);
        fl.extend_from_slice(&[k.x as f32, k.y as f32, k.z as f32, look.key_k]);
        fl.extend_from_slice(&[look.key_colour[0], look.key_colour[1], look.key_colour[2], look.fill_k]);
        fl.extend_from_slice(&[look.fill[0], look.fill[1], look.fill[2], look.ambient]);
        let textured = look.textured && look.flat.is_none() && self.skins.contains_key(p.mesh.0);
        fl.extend_from_slice(&[look.rim[0], look.rim[1], look.rim[2], if textured { 0.0 } else { look.rim_k }]);
        fl.extend_from_slice(&colour);
        fl.extend_from_slice(&[kind, inflate, if under { 1.0 } else { 0.0 }, shade]);
        fl.extend_from_slice(&[look.rim_power, look.toon as f32, look.alpha, look.dim]);
        fl.extend_from_slice(&[if look.shade_flat { 1.0 } else { 0.0 }, if textured { 1.0 } else { 0.0 }, 0.0, 0.0]);
        let Some(binding) = arena.push(&bytes(&fl)) else { return };
        let tex = self.skins.get(p.mesh.0).unwrap_or(&self.white);
        let group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.layouts[&Kind::Body],
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Buffer(binding) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(tex) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.sampler) },
            ],
        });
        rp.set_pipeline(&self.pipelines[&key]);
        let (vertices, indices, count) = (gm.vertices.slice(..), gm.indices.slice(..), gm.count);
        rp.set_bind_group(0, &group, &[]);
        rp.set_vertex_buffer(0, vertices);
        rp.set_index_buffer(indices, wgpu::IndexFormat::Uint16);
        rp.draw_indexed(0..count, 0, 0..1);
    }

    #[allow(clippy::too_many_arguments)]
    fn dust_pass(&mut self, gpu: &Gpu, rp: &mut wgpu::RenderPass<'_>, arena: &mut Arena, posed: &HashMap<usize, Posed>, cam: Option<&CamU>, slot: usize, d: &Dust, w: u32, h: u32) {
        let (Some(p), Some(c)) = (posed.get(&slot), cam) else { return };
        let key = Key { kind: Kind::Dust, blend: Blend::Plus, cull_front: false, cw: false, depth_test: false, depth_write: false };
        self.pipeline(gpu, key);
        let Some(gm) = self.meshes.get(&p.mesh) else { return };
        let Some((buf, total)) = &gm.dust else { return };
        let n = ((*total as f32 * d.density.clamp(0.02, 1.0)).round() as u32).min(*total);
        if n == 0 {
            return;
        }
        let mut fl: Vec<f32> = p.skin.iter().flatten().copied().collect();
        fl.extend_from_slice(&p.model);
        fl.extend_from_slice(&c.view_proj);
        fl.extend_from_slice(&[c.eye[0], c.eye[1], c.eye[2], 0.0]);
        fl.extend_from_slice(&[d.a[0], d.a[1], d.a[2], d.alpha]);
        fl.extend_from_slice(&[d.b[0], d.b[1], d.b[2], d.mode as f32]);
        fl.extend_from_slice(&[d.size, c.focal * h as f32 / c.ref_h, d.explode, d.swirl]);
        let textured = self.skins.contains_key(p.mesh.0);
        fl.extend_from_slice(&[d.rise, d.time, d.shimmer, if textured { 1.0 } else { 0.0 }]);
        fl.extend_from_slice(&[w as f32, h as f32, 0.0, 0.0]);
        let Some(binding) = arena.push(&bytes(&fl)) else { return };
        let tex = self.skins.get(p.mesh.0).unwrap_or(&self.white);
        let group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.layouts[&Kind::Dust],
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Buffer(binding) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(tex) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.sampler) },
            ],
        });
        let buf = buf.slice(..);
        rp.set_pipeline(&self.pipelines[&key]);
        rp.set_bind_group(0, &group, &[]);
        rp.set_vertex_buffer(0, buf);
        rp.draw(0..4, 0..n);
    }
}

enum BodyPass<'a> {
    Body(&'a Look3, bool),
    Outline(f32, [f32; 4]),
    /// 2 the floor (the light's slope), 3 a wall (the lamp, the wall's y).
    Shadow(u32, [f32; 3], f32, [f32; 3]),
}
