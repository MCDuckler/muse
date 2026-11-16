//! Stills of the dancers for posters: the scans in a pose from their move bank, on a white
//! floor that runs into a white sky, through a wide (or fisheye) lens, with the sun's shadow
//! and a contact shadow under the feet.
//!   cargo run --release -p wo-render --example poster_shots -- shots <spec.json> <out dir> [only name]
//!   cargo run --release -p wo-render --example poster_shots -- browse <who> <out.png> [cells] [moves filter]
//!
//! A spec is a list of shots:
//!   {"name": "..", "size": 2048,
//!    "dancers": [{"who": "chris", "move": "mx_hh_..", "beat": 1.25, "at": [0, 0], "yaw": 0, "raw": false}],
//!    "eye": [x, y, z], "look": [x, y, z], "roll": 0, "fov": 110, "lens": 0.5}
//! Metres, z up; a dancer at yaw 0 faces −y. `lens` 1 = rectilinear, 0.5 = stereographic,
//! → 0 = equidistant fisheye; `fov` is the full angle across the picture's middle.
//! Optional: "sun" (the light's way down), "shadow", "contact", "key", "fill", "ambient", "bg".
use std::path::{Path, PathBuf};

use serde_json::Value;
use wgpu::util::DeviceExt;
use wo_dance::Rig;
use wo_render::Gpu;

const SHADER: &str = "
struct U {
    eye: vec4<f32>, right: vec4<f32>, up: vec4<f32>, fwd: vec4<f32>,
    lens: vec4<f32>,        // f, a, near, far
    key: vec4<f32>,         // xyz toward the key, w its strength
    key_colour: vec4<f32>,  // w the fill's strength
    fill: vec4<f32>,        // w the ambient
    sun: vec4<f32>,         // xy the shadow's slope (sun.xy / sun.z), z its strength, w the contact's
    frame: vec4<f32>,       // the crop: xy its middle, z the zoom
    mode: vec4<f32>,        // x: 0 body, 1 sun shadow, 2 contact shadow
};
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var skin_t: texture_2d<f32>;
@group(0) @binding(2) var skin_s: sampler;
struct VIn { @location(0) pos: vec3<f32>, @location(1) nrm: vec3<f32>, @location(2) uv: vec2<f32> };
struct VOut { @builtin(position) clip: vec4<f32>, @location(0) pos: vec3<f32>, @location(1) nrm: vec3<f32>, @location(2) uv: vec2<f32>, @location(3) h: f32 };
fn project(w: vec3<f32>) -> vec4<f32> {
    let d = w - u.eye.xyz;
    let v = vec3<f32>(dot(d, u.right.xyz), dot(d, u.up.xyz), dot(d, u.fwd.xyz));
    let dist = max(length(v), 1e-4);
    let side = length(v.xy);
    let th = atan2(side, v.z);
    let a = u.lens.y;
    let r = u.lens.x * tan(min(a * th, 1.55)) / a;
    var xy = vec2<f32>(0.0);
    if (side > 1e-6) { xy = v.xy / side * r; }
    xy = (xy - u.frame.xy) * u.frame.z;
    let z = clamp((dist - u.lens.z) / (u.lens.w - u.lens.z), 0.0, 1.0);
    return vec4<f32>(xy * dist, z * dist, dist);
}
@vertex fn vs(v: VIn) -> VOut {
    var o: VOut;
    var w = v.pos;
    let mode = i32(u.mode.x + 0.5);
    o.h = w.z;
    if (mode == 1) { w = vec3<f32>(w.xy - u.sun.xy * w.z, 0.0); }
    if (mode == 2) { w = vec3<f32>(w.xy, 0.0); }
    o.pos = w;
    o.nrm = v.nrm;
    o.uv = v.uv;
    o.clip = project(w);
    return o;
}
@fragment fn fs(i: VOut) -> @location(0) vec4<f32> {
    let mode = i32(u.mode.x + 0.5);
    // floor seen edge-on (far off, near the horizon) keeps no shadow: a fisheye squeezes it into arcs
    let graze = smoothstep(0.06, 0.25, u.eye.z / max(length(u.eye.xyz - i.pos), 1e-3));
    if (mode == 1) {
        // a shadow fades as what casts it is further off the floor
        let k = u.sun.z * graze * mix(1.0, 0.55, clamp(i.h / 1.8, 0.0, 1.0));
        return vec4<f32>(1.0 - k, 1.0, 1.0, 1.0);
    }
    if (mode == 2) {
        return vec4<f32>(1.0, 1.0 - u.sun.w * mix(0.8, 1.0, graze) * exp(-max(i.h, 0.0) / 0.09), 1.0, 1.0);
    }
    let tex = textureSample(skin_t, skin_s, i.uv).rgb;
    var n = normalize(i.nrm);
    let vw = normalize(u.eye.xyz - i.pos);
    if (dot(n, vw) < 0.0) { n = -n; }
    let kd = normalize(u.key.xyz);
    let diff = max(dot(n, kd), 0.0);
    let fill = max(0.5 - 0.5 * (n.x * kd.x + n.y * kd.y) * 0.8 - 0.2 * n.z, 0.0);
    var col = vec3<f32>(u.fill.w) + u.key.w * diff * u.key_colour.rgb + u.key_colour.w * fill * u.fill.rgb;
    col = min(col, vec3<f32>(1.0)) * tex;
    return vec4<f32>(col, 1.0);
}
";

const MSAA: u32 = 4;

type V3 = [f64; 3];

fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn cross(a: V3, b: V3) -> V3 {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
fn norm(a: V3) -> V3 {
    let l = (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).sqrt().max(1e-12);
    [a[0] / l, a[1] / l, a[2] / l]
}

fn v3(v: &Value, d: V3) -> V3 {
    v.as_array().map(|a| [0, 1, 2].map(|k| a.get(k).and_then(|x| x.as_f64()).unwrap_or(d[k]))).unwrap_or(d)
}
fn num(v: &Value, key: &str, d: f64) -> f64 {
    v.get(key).and_then(|x| x.as_f64()).unwrap_or(d)
}

fn dance_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/dance")
}

/// How tall the stage draws a body (wo_dance::sim's scale_of).
fn scale_of(rig: &Rig) -> f64 {
    if rig.height <= 0.3 {
        return 1.0;
    }
    match rig.stands {
        Some(s) if s > 0.3 => (s / rig.height).clamp(0.8, 1.2),
        _ => (1.75 / rig.height).clamp(0.8, 1.2),
    }
}

struct Who {
    rig: Rig,
    skin: wgpu::TextureView,
    group: Vec<wgpu::BindGroup>,
}

struct Placed {
    who: usize,
    /// Per mesh: interleaved pos/nrm/uv and the triangles.
    meshes: Vec<(Vec<f32>, Vec<u16>)>,
}

/// A dancer posed: `beat` beats into `move`, turned `yaw` degrees about z, its hips (unless
/// `raw`) over `at`.
fn place(rig: &Rig, mv: usize, beat: f64, at: [f64; 2], yaw: f64, raw: bool, scale: f64) -> Vec<(Vec<f32>, Vec<u16>)> {
    let mut pose = rig.sample(mv, beat);
    if !raw {
        pose.hips[0] = 0.0;
        pose.hips[1] = 0.0;
    }
    let skinning = rig.skinning(&rig.solve(&pose));
    let s = scale_of(rig) * scale;
    let (sn, cs) = yaw.to_radians().sin_cos();
    let mut out = vec![];
    // the lowest point on the floor (a jump stays a jump: only a body under the floor is lifted)
    let mut low = f64::MAX;
    let mut posed = vec![];
    for k in 0..rig.meshes.len() {
        let (pos, nrm) = rig.deform(k, &skinning);
        for z in pos.iter().skip(2).step_by(3) {
            low = low.min(*z as f64 * s);
        }
        posed.push((pos, nrm));
    }
    let lift = if low < 0.0 { -low } else { 0.0 };
    for (k, m) in rig.meshes.iter().enumerate() {
        let (pos, nrm) = &posed[k];
        let mut v: Vec<f32> = Vec::with_capacity(m.corners() * 8);
        for c in 0..m.corners() {
            let i = m.src[c] as usize * 3;
            let (x, y, z) = (pos[i] as f64 * s, pos[i + 1] as f64 * s, pos[i + 2] as f64 * s + lift);
            let (nx, ny, nz) = (nrm[i] as f64, nrm[i + 1] as f64, nrm[i + 2] as f64);
            v.extend_from_slice(&[(x * cs - y * sn + at[0]) as f32, (x * sn + y * cs + at[1]) as f32, z as f32]);
            v.extend_from_slice(&[(nx * cs - ny * sn) as f32, (nx * sn + ny * cs) as f32, nz as f32]);
            v.extend_from_slice(&m.uv[c * 2..c * 2 + 2]);
        }
        out.push((v, m.tris.clone()));
    }
    out
}

struct Shot {
    size: u32,
    eye: V3,
    look: V3,
    roll: f64,
    fov: f64,
    lens: f64,
    sun: V3,
    shadow: f64,
    contact: f64,
    key: f64,
    fill: f64,
    ambient: f64,
    bg: [f64; 3],
    blur: f64,
    /// The crop (middle x, y and zoom) that fits the cast.
    frame: [f64; 3],
    fit: Option<f64>,
    nudge: [f64; 2],
}

impl Shot {
    fn of(v: &Value) -> Shot {
        let bg = v.get("bg").and_then(|b| b.as_str()).map(|s| {
            let x = u32::from_str_radix(s.trim_start_matches('#'), 16).unwrap_or(0xffffff);
            [(x >> 16 & 255) as f64 / 255.0, (x >> 8 & 255) as f64 / 255.0, (x & 255) as f64 / 255.0]
        });
        Shot {
            size: num(v, "size", 2048.0) as u32,
            eye: v3(&v["eye"], [0.0, -3.0, 1.0]),
            look: v3(&v["look"], [0.0, 0.0, 1.0]),
            roll: num(v, "roll", 0.0),
            fov: num(v, "fov", 100.0),
            lens: num(v, "lens", 0.5).clamp(0.02, 1.0),
            sun: norm(v3(&v["sun"], [0.35, 0.8, -0.65])),
            shadow: num(v, "shadow", 0.32),
            contact: num(v, "contact", 0.55),
            key: num(v, "key", 0.6),
            fill: num(v, "fill", 0.3),
            ambient: num(v, "ambient", 0.48),
            bg: bg.unwrap_or([1.0; 3]),
            blur: num(v, "blur", 1.0),
            frame: [0.0, 0.0, 1.0],
            fit: if v.get("fit").is_some_and(|f| f.as_bool() == Some(false)) { None } else { Some(num(v, "fit", 0.07)) },
            nudge: { let n = v3(&v["nudge"], [0.0; 3]); [n[0], n[1]] },
        }
    }

    fn basis(&self) -> (V3, V3, V3, f64) {
        let fwd = norm(sub(self.look, self.eye));
        let right0 = norm(cross(fwd, [0.0, 0.0, 1.0]));
        let up0 = cross(right0, fwd);
        let (sn, cs) = self.roll.to_radians().sin_cos();
        let right = [0, 1, 2].map(|k| right0[k] * cs + up0[k] * sn);
        let up = [0, 1, 2].map(|k| up0[k] * cs - right0[k] * sn);
        let a = self.lens;
        let half = (self.fov / 2.0).to_radians();
        let f = a / (a * half).min(1.55).tan();
        (right, up, fwd, f)
    }

    /// Where a point lands on the picture before the crop (the shader's project()).
    fn picture(&self, w: V3) -> [f64; 2] {
        let (right, up, fwd, f) = self.basis();
        let d = sub(w, self.eye);
        let dot = |a: V3, b: V3| a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
        let v = [dot(d, right), dot(d, up), dot(d, fwd)];
        let side = (v[0] * v[0] + v[1] * v[1]).sqrt();
        let th = side.atan2(v[2]);
        let r = f * (self.lens * th).min(1.55).tan() / self.lens;
        if side < 1e-9 { [0.0, 0.0] } else { [v[0] / side * r, v[1] / side * r] }
    }

    /// Crops to the cast: its box, `margin` in from the edges, nudged.
    fn fit(&mut self, cast: &[Placed]) {
        let Some(margin) = self.fit else { return };
        let (mut lo, mut hi) = ([f64::MAX; 2], [f64::MIN; 2]);
        for p in cast {
            for (v, _) in &p.meshes {
                for c in v.chunks(8) {
                    let q = self.picture([c[0] as f64, c[1] as f64, c[2] as f64]);
                    for k in 0..2 {
                        lo[k] = lo[k].min(q[k]);
                        hi[k] = hi[k].max(q[k]);
                    }
                }
            }
        }
        let zoom = (2.0 - 2.0 * margin) / (hi[0] - lo[0]).max(hi[1] - lo[1]);
        self.frame = [(lo[0] + hi[0]) / 2.0 - self.nudge[0] / zoom, (lo[1] + hi[1]) / 2.0 - self.nudge[1] / zoom, zoom];
    }

    fn uniforms(&self, mode: f32) -> Vec<f32> {
        let (right, up, fwd, f) = self.basis();
        let a = self.lens;
        let key = [-self.sun[0], -self.sun[1], -self.sun[2]];
        let kc = [1.0, 250.0 / 255.0, 242.0 / 255.0];
        let fc = [200.0 / 255.0, 204.0 / 255.0, 212.0 / 255.0];
        let slope = [self.sun[0] / self.sun[2], self.sun[1] / self.sun[2]];
        let rows: [[f64; 4]; 11] = [
            [self.eye[0], self.eye[1], self.eye[2], 1.0],
            [right[0], right[1], right[2], 0.0],
            [up[0], up[1], up[2], 0.0],
            [fwd[0], fwd[1], fwd[2], 0.0],
            [f, a, 0.05, 60.0],
            [key[0], key[1], key[2], self.key],
            [kc[0], kc[1], kc[2], self.fill],
            [fc[0], fc[1], fc[2], self.ambient],
            [slope[0], slope[1], self.shadow, self.contact],
            [self.frame[0], self.frame[1], self.frame[2], 0.0],
            [mode as f64, 0.0, 0.0, 0.0],
        ];
        rows.iter().flatten().map(|x| *x as f32).collect()
    }
}

struct Painter {
    gpu: Gpu,
    layout: wgpu::BindGroupLayout,
    body: wgpu::RenderPipeline,
    shade: wgpu::RenderPipeline,
    sampler: wgpu::Sampler,
}

impl Painter {
    fn new() -> Painter {
        let gpu = Gpu::headless().expect("a GPU");
        let d = &gpu.device;
        let module = d.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some("poster"), source: wgpu::ShaderSource::Wgsl(SHADER.into()) });
        let layout = d.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &[
                wgpu::BindGroupLayoutEntry { binding: 0, visibility: wgpu::ShaderStages::VERTEX_FRAGMENT, ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None }, count: None },
                wgpu::BindGroupLayoutEntry { binding: 1, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: true }, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false }, count: None },
                wgpu::BindGroupLayoutEntry { binding: 2, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering), count: None },
            ],
        });
        let pl = d.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &[Some(&layout)], ..Default::default() });
        let buffers = [Some(wgpu::VertexBufferLayout { array_stride: 32, step_mode: wgpu::VertexStepMode::Vertex, attributes: &wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3, 2 => Float32x2] })];
        let make = |blend: Option<wgpu::BlendState>, depth: bool| {
            d.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("poster"),
                layout: Some(&pl),
                vertex: wgpu::VertexState { module: &module, entry_point: Some("vs"), buffers: &buffers, compilation_options: Default::default() },
                fragment: Some(wgpu::FragmentState {
                    module: &module,
                    entry_point: Some("fs"),
                    targets: &[Some(wgpu::ColorTargetState { format: wgpu::TextureFormat::Rgba8Unorm, blend, write_mask: wgpu::ColorWrites::ALL })],
                    compilation_options: Default::default(),
                }),
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: Some(wgpu::DepthStencilState {
                    format: wgpu::TextureFormat::Depth32Float,
                    depth_write_enabled: Some(depth),
                    depth_compare: Some(if depth { wgpu::CompareFunction::Less } else { wgpu::CompareFunction::Always }),
                    stencil: Default::default(),
                    bias: Default::default(),
                }),
                multisample: wgpu::MultisampleState { count: MSAA, ..Default::default() },
                multiview_mask: None,
                cache: None,
            })
        };
        let min = wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Min };
        let body = make(None, true);
        let shade = make(Some(wgpu::BlendState { color: min, alpha: min }), false);
        let sampler = d.create_sampler(&wgpu::SamplerDescriptor { mag_filter: wgpu::FilterMode::Linear, min_filter: wgpu::FilterMode::Linear, ..Default::default() });
        Painter { gpu, layout, body, shade, sampler }
    }

    fn who(&self, name: &str, shot: &Shot) -> Who {
        let rig = Rig::load(&dance_dir().join(name)).expect("the dancer");
        // a sharper skin where the scan folder has one (same atlas as the shipped webp)
        let hi = std::env::var(format!("SKIN_{}", name.to_uppercase())).ok();
        let (w, h, px) = match hi.and_then(|p| image::open(&p).ok()) {
            Some(img) => {
                let i = img.to_rgba8();
                (i.width(), i.height(), i.into_raw())
            }
            None => rig.skin_rgba().expect("the skin"),
        };
        let tex = wo_render::upload(&self.gpu, w, h, &px);
        let view = tex.create_view(&Default::default());
        let mut who = Who { rig, skin: view, group: vec![] };
        self.bind(&mut who, shot);
        who
    }

    /// The uniforms for a shot (body, sun shadow, contact) with this dancer's skin.
    fn bind(&self, who: &mut Who, shot: &Shot) {
        let view = &who.skin;
        who.group = [0.0f32, 1.0, 2.0].iter().map(|&mode| {
            let u = shot.uniforms(mode);
            let ubuf = self.gpu.device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: None, contents: &u.iter().flat_map(|f| f.to_le_bytes()).collect::<Vec<u8>>(), usage: wgpu::BufferUsages::UNIFORM });
            self.gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: None,
                layout: &self.layout,
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: ubuf.as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(view) },
                    wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&self.sampler) },
                ],
            })
        }).collect();
    }

    /// One pass over every placed body: pipeline per kind, cleared to `clear`; read back.
    fn pass(&self, size: u32, cast: &[Placed], who: &[Who], kinds: &[usize], clear: wgpu::Color) -> Vec<u8> {
        let d = &self.gpu.device;
        let ext = wgpu::Extent3d { width: size, height: size, depth_or_array_layers: 1 };
        let ms = d.create_texture(&wgpu::TextureDescriptor { label: None, size: ext, mip_level_count: 1, sample_count: MSAA, dimension: wgpu::TextureDimension::D2, format: wgpu::TextureFormat::Rgba8Unorm, usage: wgpu::TextureUsages::RENDER_ATTACHMENT, view_formats: &[] });
        let depth = d.create_texture(&wgpu::TextureDescriptor { label: None, size: ext, mip_level_count: 1, sample_count: MSAA, dimension: wgpu::TextureDimension::D2, format: wgpu::TextureFormat::Depth32Float, usage: wgpu::TextureUsages::RENDER_ATTACHMENT, view_formats: &[] });
        let target = wo_render::target(&self.gpu, size, size);
        let mut bufs = vec![];
        for p in cast {
            for (v, t) in &p.meshes {
                let vb = d.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: None, contents: &v.iter().flat_map(|f| f.to_le_bytes()).collect::<Vec<u8>>(), usage: wgpu::BufferUsages::VERTEX });
                let mut tb: Vec<u8> = t.iter().flat_map(|i| i.to_le_bytes()).collect();
                tb.resize(tb.len().div_ceil(4) * 4, 0);
                let ib = d.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: None, contents: &tb, usage: wgpu::BufferUsages::INDEX });
                bufs.push((p.who, vb, ib, t.len() as u32));
            }
        }
        let mut enc = d.create_command_encoder(&Default::default());
        {
            let msv = ms.create_view(&Default::default());
            let tv = target.create_view(&Default::default());
            let dv = depth.create_view(&Default::default());
            let mut rp = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment { view: &msv, depth_slice: None, resolve_target: Some(&tv), ops: wgpu::Operations { load: wgpu::LoadOp::Clear(clear), store: wgpu::StoreOp::Discard } })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment { view: &dv, depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Clear(1.0), store: wgpu::StoreOp::Discard }), stencil_ops: None }),
                ..Default::default()
            });
            for &kind in kinds {
                rp.set_pipeline(if kind == 0 { &self.body } else { &self.shade });
                for (w, vb, ib, n) in &bufs {
                    rp.set_bind_group(0, &who[*w].group[kind], &[]);
                    rp.set_vertex_buffer(0, vb.slice(..));
                    rp.set_index_buffer(ib.slice(..), wgpu::IndexFormat::Uint16);
                    rp.draw_indexed(0..*n, 0, 0..1);
                }
            }
        }
        self.gpu.queue.submit([enc.finish()]);
        wo_render::read(&self.gpu, &target)
    }
}

/// A box blur three times over (≈ gaussian) of one channel, radius in pixels.
fn blur(ch: &mut [f32], n: usize, r: usize) {
    if r == 0 {
        return;
    }
    let line = |from: &[f32], to: &mut [f32], along: bool| {
        for l in 0..n {
            let at = |i: usize| if along { l * n + i } else { i * n + l };
            // edges clamped: the window starts with r copies of the first pixel
            let mut acc = from[at(0)] * r as f32;
            for i in 0..=r {
                acc += from[at(i.min(n - 1))];
            }
            for i in 0..n {
                to[at(i)] = acc / (2 * r + 1) as f32;
                acc += from[at((i + r + 1).min(n - 1))] - from[at(i.saturating_sub(r))];
            }
        }
    };
    let mut tmp = vec![0f32; ch.len()];
    for _ in 0..3 {
        line(ch, &mut tmp, true);
        line(&tmp, ch, false);
    }
}

fn shoot(p: &Painter, spec: &Value, out: &Path) {
    let mut shot = Shot::of(spec);
    let n = shot.size as usize;
    let mut names: Vec<String> = vec![];
    let mut who: Vec<Who> = vec![];
    let mut cast = vec![];
    for d in spec["dancers"].as_array().expect("dancers") {
        let name = d["who"].as_str().unwrap_or("chris").to_string();
        let w = match names.iter().position(|x| *x == name) {
            Some(i) => i,
            None => {
                who.push(p.who(&name, &shot));
                names.push(name.clone());
                who.len() - 1
            }
        };
        let rig = &who[w].rig;
        let mv_id = d["move"].as_str().unwrap_or("long22");
        let mv = rig.move_by_id(mv_id).unwrap_or_else(|| panic!("no move {mv_id}"));
        let at = d.get("at").and_then(|a| a.as_array()).map(|a| [a[0].as_f64().unwrap(), a[1].as_f64().unwrap()]).unwrap_or([0.0, 0.0]);
        let meshes = place(rig, mv, num(d, "beat", 0.0), at, num(d, "yaw", 0.0), d.get("raw").and_then(|x| x.as_bool()).unwrap_or(false), num(d, "scale", 1.0));
        cast.push(Placed { who: w, meshes });
    }
    shot.fit(&cast);
    for w in who.iter_mut() {
        p.bind(w, &shot);
    }
    let white = wgpu::Color { r: 1.0, g: 1.0, b: 1.0, a: 1.0 };
    let shadow = p.pass(shot.size, &cast, &who, &[1, 2], white);
    let fig = p.pass(shot.size, &cast, &who, &[0], wgpu::Color { r: 0.0, g: 0.0, b: 0.0, a: 0.0 });
    let mut sun: Vec<f32> = shadow.chunks(4).map(|c| c[0] as f32 / 255.0).collect();
    let mut con: Vec<f32> = shadow.chunks(4).map(|c| c[1] as f32 / 255.0).collect();
    let unit = n as f64 / 2048.0 * shot.blur;
    blur(&mut sun, n, (6.0 * unit) as usize);
    blur(&mut con, n, (14.0 * unit) as usize);
    let mut img = image::RgbImage::new(n as u32, n as u32);
    for i in 0..n * n {
        let a = fig[i * 4 + 3] as f64 / 255.0;
        let k = (sun[i] * con[i]) as f64;
        let px = [0, 1, 2].map(|c| {
            let bg = shot.bg[c] * k;
            let v = fig[i * 4 + c] as f64 / 255.0 + bg * (1.0 - a);
            (v.clamp(0.0, 1.0) * 255.0).round() as u8
        });
        img.put_pixel((i % n) as u32, (i / n) as u32, image::Rgb(px));
    }
    img.save(out).unwrap();
}

/// How much a pose reaches: hands and feet away from the chest, feet apart, hands high.
fn reach(rig: &Rig, mv: usize, beat: f64) -> f64 {
    let pose = rig.sample(mv, beat);
    let world = rig.solve(&pose);
    let at = |n: &str, tip: f64| rig.bone(n).map(|b| Rig::joint_at(&world, b, tip)).unwrap_or([0.0; 3]);
    let chest = at("Chest", 0.5);
    let d = |a: [f64; 3], b: [f64; 3]| ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt();
    let (hl, hr, fl, fr) = (at("Hand_L", 1.0), at("Hand_R", 1.0), at("Foot_L", 1.0), at("Foot_R", 1.0));
    d(hl, chest) + d(hr, chest) + 0.6 * d(fl, fr) + 0.4 * (hl[2].max(hr[2]) - chest[2]).max(0.0) + 0.3 * (fl[2].max(fr[2]) - 0.15).max(0.0)
}

fn browse(p: &Painter, name: &str, out: &Path, cells: usize, filter: Option<&str>) {
    let shot = Shot::of(&serde_json::json!({"size": 256, "eye": [0.0, -4.2, 0.95], "look": [0.0, 0.0, 0.9], "fov": 32, "lens": 1.0}));
    let who = vec![p.who(name, &shot)];
    let rig = &who[0].rig;
    let mut best: Vec<(f64, usize, f64)> = vec![];
    for mv in 0..rig.moves.len() {
        let m = &rig.moves[mv];
        if m.duo.is_some() || filter.is_some_and(|f| !f.split(',').any(|x| m.id.contains(x))) {
            continue;
        }
        let mut top = (0.0, 0.0);
        for k in 0..m.beats * 4 {
            let b = k as f64 / 4.0;
            let r = reach(rig, mv, b);
            if r > top.0 {
                top = (r, b);
            }
        }
        best.push((top.0, mv, top.1));
    }
    best.sort_by(|a, b| b.0.total_cmp(&a.0));
    best.truncate(cells);
    let cols = (cells as f64).sqrt().ceil() as u32;
    let rows = (best.len() as u32).div_ceil(cols);
    let mut sheet = image::RgbImage::from_pixel(cols * 256, rows * 256, image::Rgb([255, 255, 255]));
    for (i, &(r, mv, beat)) in best.iter().enumerate() {
        let cast = vec![Placed { who: 0, meshes: place(rig, mv, beat, [0.0, 0.0], 0.0, false, 1.0) }];
        let fig = p.pass(256, &cast, &who, &[0], wgpu::Color { r: 0.0, g: 0.0, b: 0.0, a: 0.0 });
        for y in 0..256u32 {
            for x in 0..256u32 {
                let o = ((y * 256 + x) * 4) as usize;
                let a = fig[o + 3] as u32;
                let c = [0, 1, 2].map(|c| (fig[o + c] as u32 + 255 * (255 - a) / 255).min(255) as u8);
                let edge = x == 0 || y == 0;
                sheet.put_pixel((i as u32 % cols) * 256 + x, (i as u32 / cols) * 256 + y, image::Rgb(if edge { [200, 200, 200] } else { c }));
            }
        }
        println!("{i:3} {:28} beat {beat:5.2} reach {r:.2}", rig.moves[mv].id);
    }
    sheet.save(out).unwrap();
}

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let p = Painter::new();
    eprintln!("{} on {:?}", p.gpu.info.name, p.gpu.info.backend);
    match a.first().map(String::as_str) {
        Some("shots") => {
            let spec: Value = serde_json::from_str(&std::fs::read_to_string(&a[1]).expect("the spec")).expect("json");
            let dir = PathBuf::from(&a[2]);
            std::fs::create_dir_all(&dir).unwrap();
            for s in spec.as_array().expect("a list of shots") {
                let name = s["name"].as_str().unwrap_or("shot");
                if a.get(3).is_some_and(|o| !o.split(',').any(|x| x == name)) {
                    continue;
                }
                let out = dir.join(format!("{name}.png"));
                shoot(&p, s, &out);
                eprintln!("{}", out.display());
            }
        }
        Some("browse") => browse(&p, &a[1], &PathBuf::from(&a[2]), a.get(3).and_then(|n| n.parse().ok()).unwrap_or(64), a.get(4).map(String::as_str)),
        _ => eprintln!("poster_shots shots <spec.json> <out dir> [names] | browse <who> <out.png> [cells] [filter]"),
    }
}
