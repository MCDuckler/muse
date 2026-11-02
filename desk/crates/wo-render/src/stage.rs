//! The show's frame drawn the native stage's way (v1: app/native/stage/src/stage.cpp frame()),
//! on wgpu:
//!
//! 1. the ground under the figure, where the look blends one: black, white, a wash of the
//!    palette, MilkDrop's picture or the cover fitted to the stage (P3: given as textures),
//!    or a field (a scene shader drawn whole), into its own picture;
//! 2. the figure — the scene's .frag as wo-shaders fits it — at the working size into a
//!    half-float picture; the scene being left beside it, under a dissolve;
//! 3. the particles, added to the figure's light;
//! 4. the blend of figure and ground (shaders/show/under.frag);
//! 5. the trails (shaders/show/feedback.frag over last frame's picture, in floating point,
//!    so a trail fades all the way out);
//! 6. the bloom: halved five times with a 13-tap filter, brought back up with a tent;
//! 7. the finish at the output's size: the bloom added as light, the fringe and the
//!    vignette, the film curve, the grain, the strobe and the blackout, and a dither so the
//!    8 bits out show no bands.
//!
//! The stage's own passes (bloom, finish, wash, fitting a picture, particles) are WGSL; the
//! show's are the .frag files (plan §6.4). Not yet: the datamosh, the treatments and the
//! transformations (P4).
use std::borrow::Cow;
use std::collections::HashMap;

use wo_show::frame::{GroundDraw, StageFrame};

use crate::particles::{Inputs, Particles};
use crate::{Arena, Gpu, Pass, values_by};

/// The working pictures: half floats, so the trails and the bloom keep their light.
pub const WORK: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;

/// The common block's names after uResolution, in order (shaders/show/common.glsl).
pub const COMMON_NAMES: [&str; 35] = [
    "uTime", "uBeat", "uBar", "uPhrase", "uEnergy", "uIntensity", "uKick", "uLow", "uMid", "uHigh", "uAir", "uOnset", "uHue", "uHue2",
    "uDropNear", "uBuild", "uHit", "uVocal", "uM1", "uM2", "uM3", "uM4", "uHitKick", "uHitSnare", "uHitTop", "uBeatDecay", "uBarDecay",
    "uBarSaw", "uPhraseSaw", "uDownbeat", "uExposure", "uBandLow", "uBandMid", "uBandHigh", "uBarIndex",
];

/// A scene shader's floats: uResolution, the packed uP0..uP7, and the rest of the common
/// block by name.
pub fn scene_values(floats: &[wo_shaders::Float], w: f32, h: f32, common: &[f32; 35]) -> Vec<f32> {
    values_by(floats, |name, comps| {
        if name == "uResolution" {
            return vec![w, h];
        }
        if let Some(k) = name.strip_prefix("uP").and_then(|n| n.parse::<usize>().ok()).filter(|k| comps == 4 && 4 * k + 4 <= 35) {
            return common[4 * k..4 * k + 4].to_vec();
        }
        COMMON_NAMES.iter().position(|n| *n == name).map(|i| vec![common[i]]).unwrap_or_default()
    })
}

const VERTEX: &str = "
struct VOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex fn vs(@builtin(vertex_index) i: u32) -> VOut {
    let p = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
    var o: VOut;
    o.pos = vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = vec2<f32>(p.x, 1.0 - p.y);
    return o;
}
";

/// Jimenez's 13-tap downsample (Call of Duty: Advanced Warfare's bloom); on the first level
/// the bright parts only, with a soft knee.
const DOWN: &str = "
struct U { texel: vec2<f32>, first: f32, pad: f32 };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;
fn s(uv: vec2<f32>, o: vec2<f32>) -> vec3<f32> { return textureSampleLevel(src, smp, uv + o * u.texel, 0.0).rgb; }
@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    let uv = v.uv;
    let a = s(uv, vec2(-2.0, 2.0)); let b = s(uv, vec2(0.0, 2.0)); let c = s(uv, vec2(2.0, 2.0));
    let d = s(uv, vec2(-2.0, 0.0)); let e = s(uv, vec2(0.0, 0.0)); let f = s(uv, vec2(2.0, 0.0));
    let g = s(uv, vec2(-2.0, -2.0)); let h = s(uv, vec2(0.0, -2.0)); let i = s(uv, vec2(2.0, -2.0));
    let j = s(uv, vec2(-1.0, 1.0)); let k = s(uv, vec2(1.0, 1.0)); let l = s(uv, vec2(-1.0, -1.0)); let m = s(uv, vec2(1.0, -1.0));
    var col = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    if (u.first > 0.5) {
        let lum = max(col.r, max(col.g, col.b));
        col *= smoothstep(0.35, 0.9, lum);
    }
    return vec4<f32>(col, 1.0);
}
";

/// A 9-tap tent, added onto the level above.
const UP: &str = "
struct U { texel: vec2<f32>, radius: f32, pad: f32 };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;
fn s(uv: vec2<f32>, o: vec2<f32>) -> vec3<f32> { return textureSampleLevel(src, smp, uv + o * u.texel * u.radius, 0.0).rgb; }
@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    let uv = v.uv;
    let col = s(uv, vec2(0.0)) * 4.0 + (s(uv, vec2(-1.0, 0.0)) + s(uv, vec2(1.0, 0.0)) + s(uv, vec2(0.0, -1.0)) + s(uv, vec2(0.0, 1.0))) * 2.0
        + s(uv, vec2(-1.0, -1.0)) + s(uv, vec2(1.0, -1.0)) + s(uv, vec2(-1.0, 1.0)) + s(uv, vec2(1.0, 1.0));
    return vec4<f32>(col / 16.0, 1.0);
}
";

/// The finish: the scene being left crossed as light, the bloom, the fringe and the vignette,
/// the film curve (ACES, or AgX), the grain, a dither, the strobe's white and the blackout.
const FINISH: &str = "
struct U { res: vec2<f32>, bloom: f32, vignette: f32, grain: f32, tone: f32, fringe: f32, time: f32,
           curve: f32, mixk: f32, white: f32, black: f32 };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var base_t: texture_2d<f32>;
@group(0) @binding(2) var s0: sampler;
@group(0) @binding(3) var bloom_t: texture_2d<f32>;
@group(0) @binding(4) var s1: sampler;
@group(0) @binding(5) var from_t: texture_2d<f32>;
@group(0) @binding(6) var s2: sampler;
fn hash(p0: vec2<f32>) -> f32 {
    var p = fract(p0 * vec2<f32>(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
fn aces(x: vec3<f32>) -> vec3<f32> {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), vec3<f32>(0.0), vec3<f32>(1.0));
}
// AgX (Troy Sobotka), the minimal fit by Wrensch: rolls a bright colour off towards white
// instead of skewing its hue.
fn agx_contrast(x: vec3<f32>) -> vec3<f32> {
    let x2 = x * x;
    let x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}
fn agx(v0: vec3<f32>) -> vec3<f32> {
    let m = mat3x3<f32>(vec3<f32>(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
                        vec3<f32>(0.0784335999999992, 0.878468636469772, 0.0784336),
                        vec3<f32>(0.0792237451477643, 0.0791661274605434, 0.879142973793104));
    let mi = mat3x3<f32>(vec3<f32>(1.19687900512017, -0.0528968517574562, -0.0529716355144438),
                         vec3<f32>(-0.0980208811401368, 1.15190312990417, -0.0980434501171241),
                         vec3<f32>(-0.0990297440797205, -0.0989611768448433, 1.15107367264116));
    let lo = -12.47393;
    let hi = 4.026069;
    var v = clamp(log2(max(m * v0, vec3<f32>(1e-10))), vec3<f32>(lo), vec3<f32>(hi));
    v = agx_contrast((v - lo) / (hi - lo));
    return clamp(mi * v, vec3<f32>(0.0), vec3<f32>(1.0));
}
@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    let uv = v.uv;
    let c = uv - 0.5;
    let r2 = dot(c, c);
    let off = c * u.fringe * r2 * 4.0;
    var base = vec3<f32>(textureSampleLevel(base_t, s0, uv + off, 0.0).r, textureSampleLevel(base_t, s0, uv, 0.0).g,
                         textureSampleLevel(base_t, s0, uv - off, 0.0).b);
    // the scenes cross as light, eased, so neither dips dark half way
    if (u.mixk < 1.0) {
        base = mix(textureSampleLevel(from_t, s2, uv, 0.0).rgb, base, smoothstep(0.0, 1.0, u.mixk));
    }
    var light = base + textureSampleLevel(bloom_t, s1, uv, 0.0).rgb * u.bloom;
    light *= 1.0 - smoothstep(0.35, 1.0, sqrt(r2) * 1.414) * 0.75 * u.vignette;
    // the scenes are drawn as display values (written for the Flutter stage's ACES on 8 bits)
    let curved = select(aces(light * 1.1), agx(light * 1.6), u.curve > 0.5);
    var col = mix(clamp(light, vec3<f32>(0.0), vec3<f32>(1.0)), curved, u.tone);
    let px = v.pos.xy;
    let g = hash(px + fract(u.time * 7.31) * 100.0) - 0.5;
    col += g * u.grain * (0.06 + 0.06 * (1.0 - dot(col, vec3<f32>(0.333))));
    // a triangular dither, a step of the 8 bits wide: no bands in a dark gradient
    let d = hash(px * 1.37 + 11.0) + hash(px * 0.71 + 3.0) - 1.0;
    col += d / 255.0;
    col = mix(col, vec3<f32>(1.0), u.white);
    col *= 1.0 - u.black;
    return vec4<f32>(clamp(col, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
";

/// The wash: two of the palette's colours, breathing slowly (the first at the bottom).
const WASH: &str = "
struct U { res: vec2<f32>, time: f32, pad: f32, a: vec4<f32>, b: vec4<f32> };
@group(0) @binding(0) var<uniform> u: U;
@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    let y = 1.0 - v.uv.y;
    let k = smoothstep(0.0, 1.0, y + 0.12 * sin(u.time * 0.07 + v.uv.x * 2.0));
    return vec4<f32>(mix(u.a.rgb, u.b.rgb, k), 1.0);
}
";

/// A picture (MilkDrop's, the cover) filled and cropped to the stage where `fit` is its aspect.
const FIT: &str = "
struct U { res: vec2<f32>, fit: f32, pad: f32 };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;
@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    var uv = v.uv;
    if (u.fit > 0.5) {
        let stage = u.res.x / u.res.y;
        let fit = select(vec2<f32>(stage / u.fit, 1.0), vec2<f32>(1.0, u.fit / stage), stage > u.fit);
        uv = clamp((uv - 0.5) * fit + 0.5, vec2<f32>(0.0), vec2<f32>(1.0));
    }
    return vec4<f32>(textureSampleLevel(src, smp, uv, 0.0).rgb, 1.0);
}
";

/// The soft disc each particle is: white at the middle, 0.55 a quarter out, nothing at the
/// rim, coloured by the instance, added.
const PARTICLE: &str = "
struct U { res: vec2<f32>, pad: vec2<f32> };
@group(0) @binding(0) var<uniform> u: U;
struct PV { @builtin(position) pos: vec4<f32>, @location(0) local: vec2<f32>, @location(1) colour: vec4<f32> };
@vertex fn vs(@builtin(vertex_index) i: u32, @location(0) at: vec4<f32>, @location(1) colour: vec4<f32>) -> PV {
    let corner = vec2<f32>(f32(i & 1u), f32((i >> 1u) & 1u)) * 2.0 - 1.0;
    let ndc = (at.xy + corner * at.z) / u.res * 2.0 - 1.0;
    var o: PV;
    o.pos = vec4<f32>(ndc.x, -ndc.y, 0.0, 1.0);
    o.local = corner;
    o.colour = colour;
    return o;
}
@fragment fn fs(v: PV) -> @location(0) vec4<f32> {
    let r = length(v.local);
    let a = select(mix(0.55, 0.0, clamp((r - 0.25) / 0.75, 0.0, 1.0)), mix(1.0, 0.55, r / 0.25), r < 0.25);
    return vec4<f32>(v.colour.rgb * a * v.colour.a, 1.0);
}
";

/// Light added onto what is there; its alpha left alone.
const ADD: wgpu::BlendState = wgpu::BlendState {
    color: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add },
    alpha: wgpu::BlendComponent { src_factor: wgpu::BlendFactor::Zero, dst_factor: wgpu::BlendFactor::One, operation: wgpu::BlendOperation::Add },
};

fn sampler(gpu: &Gpu) -> wgpu::Sampler {
    gpu.device.create_sampler(&wgpu::SamplerDescriptor {
        label: Some("linear, clamped"),
        mag_filter: wgpu::FilterMode::Linear,
        min_filter: wgpu::FilterMode::Linear,
        ..Default::default()
    })
}

fn layout_entries(block: bool, textures: u32, vertex_block: bool) -> Vec<wgpu::BindGroupLayoutEntry> {
    let mut e = vec![];
    if block {
        e.push(wgpu::BindGroupLayoutEntry {
            binding: 0,
            visibility: if vertex_block { wgpu::ShaderStages::VERTEX_FRAGMENT } else { wgpu::ShaderStages::FRAGMENT },
            ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None },
            count: None,
        });
    }
    for i in 0..textures {
        e.push(wgpu::BindGroupLayoutEntry {
            binding: 1 + 2 * i,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: true }, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false },
            count: None,
        });
        e.push(wgpu::BindGroupLayoutEntry { binding: 2 + 2 * i, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering), count: None });
    }
    e
}

/// One of the stage's own full-screen passes (WGSL).
struct Own {
    name: &'static str,
    pipeline: wgpu::RenderPipeline,
    layout: wgpu::BindGroupLayout,
    textures: u32,
}

impl Own {
    fn new(gpu: &Gpu, name: &'static str, body: &str, textures: u32, format: wgpu::TextureFormat, blend: Option<wgpu::BlendState>) -> Own {
        let d = &gpu.device;
        let module = d.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some(name), source: wgpu::ShaderSource::Wgsl(Cow::Owned(format!("{VERTEX}{body}"))) });
        let layout = d.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some(name), entries: &layout_entries(true, textures, false) });
        let pl = d.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: Some(name), bind_group_layouts: &[Some(&layout)], ..Default::default() });
        let pipeline = d.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(name),
            layout: Some(&pl),
            vertex: wgpu::VertexState { module: &module, entry_point: Some("vs"), buffers: &[], compilation_options: Default::default() },
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs"),
                targets: &[Some(wgpu::ColorTargetState { format, blend, write_mask: wgpu::ColorWrites::ALL })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });
        Own { name, pipeline, layout, textures }
    }

    #[allow(clippy::too_many_arguments)]
    fn draw(&self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, smp: &wgpu::Sampler, target: &wgpu::TextureView, floats: &[f32], textures: &[&wgpu::TextureView], load: bool) {
        debug_assert_eq!(textures.len() as u32, self.textures, "{}", self.name);
        let bytes: Vec<u8> = floats.iter().flat_map(|f| f.to_le_bytes()).collect();
        let Some(binding) = arena.push(&bytes) else { return };
        let mut entries = vec![wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Buffer(binding) }];
        for (i, t) in textures.iter().enumerate() {
            entries.push(wgpu::BindGroupEntry { binding: 1 + 2 * i as u32, resource: wgpu::BindingResource::TextureView(t) });
            entries.push(wgpu::BindGroupEntry { binding: 2 + 2 * i as u32, resource: wgpu::BindingResource::Sampler(smp) });
        }
        let group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor { label: Some(self.name), layout: &self.layout, entries: &entries });
        let mut rp = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some(self.name),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: if load { wgpu::LoadOp::Load } else { wgpu::LoadOp::Clear(wgpu::Color::BLACK) }, store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        rp.set_pipeline(&self.pipeline);
        rp.set_bind_group(0, &group, &[]);
        rp.draw(0..3, 0..1);
    }
}

/// A working picture.
pub struct Target {
    pub texture: wgpu::Texture,
    pub view: wgpu::TextureView,
    pub w: u32,
    pub h: u32,
}

impl Target {
    pub fn new(gpu: &Gpu, w: u32, h: u32, format: wgpu::TextureFormat, label: &str) -> Target {
        let texture = gpu.device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let view = texture.create_view(&Default::default());
        Target { texture, view, w, h }
    }
}

/// `slot` at `w`×`h` (made afresh at a new size).
fn sized<'a>(gpu: &Gpu, slot: &'a mut Option<Target>, w: u32, h: u32, label: &str) -> &'a Target {
    if slot.as_ref().is_none_or(|t| t.w != w || t.h != h) {
        *slot = Some(Target::new(gpu, w, h, WORK, label));
    }
    slot.as_ref().unwrap()
}

fn clear(enc: &mut wgpu::CommandEncoder, view: &wgpu::TextureView, c: wgpu::Color) {
    enc.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("clear"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view,
            depth_slice: None,
            resolve_target: None,
            ops: wgpu::Operations { load: wgpu::LoadOp::Clear(c), store: wgpu::StoreOp::Store },
        })],
        ..Default::default()
    });
}

/// How the last frame went: its working size, how many particles, what could not be drawn.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Drawn {
    pub work: (u32, u32),
    pub particles: usize,
    /// A shader the frame asked for that the stage does not have.
    pub missing: Option<String>,
}

/// The stage's renderer: its passes, its pictures between frames.
pub struct Stage {
    out_format: wgpu::TextureFormat,
    passes: HashMap<String, Pass>,
    under: Pass,
    feedback: Pass,
    down: Own,
    up: Own,
    finish: Own,
    finish_thumb: Own,
    wash: Own,
    fit: Own,
    particle: wgpu::RenderPipeline,
    particle_layout: wgpu::BindGroupLayout,
    particle_buf: Option<wgpu::Buffer>,
    sampler: wgpu::Sampler,
    arena: Arena,
    black: wgpu::TextureView,
    work: Option<Target>,
    scratch: Option<Target>,
    ground: Option<Target>,
    leaving: Option<Target>,
    trail_a: Option<Target>,
    trail_b: Option<Target>,
    bloom: [Option<Target>; 5],
    trail_scene: Option<String>,
    particle_scene: Option<String>,
    particles: Vec<Particles>,
    held: Option<StageFrame>,
    /// The working size as a share of the output's.
    pub scale: f32,
    /// The film curve: AgX (true) or ACES.
    pub agx: bool,
    /// MilkDrop's picture (16:9) and the record's cover (square), where the stage has them.
    pub milk: Option<wgpu::TextureView>,
    pub cover: Option<wgpu::TextureView>,
    pub drawn: Drawn,
}

/// The shaders a stage builds as it starts: the scenes it draws and the pulse ground.
pub fn stage_shaders() -> Vec<&'static str> {
    let mut v: Vec<&str> = wo_show::scenes::DRAWN.to_vec();
    v.push("pulse");
    v
}

impl Stage {
    /// A stage drawing into `out_format` (a window's surface, or RGBA8 for a shot), its
    /// shaders built now (none waits for a compiler mid-show).
    pub fn new(gpu: &Gpu, out_format: wgpu::TextureFormat) -> Result<Stage, String> {
        let pass = |name: &str| -> Result<Pass, String> {
            let f = wo_shaders::fit_shipped(&format!("{name}.frag")).map_err(|t| t.to_string())?;
            Ok(Pass::new(gpu, &f, WORK))
        };
        let mut passes = HashMap::new();
        for name in stage_shaders() {
            passes.insert(name.to_owned(), pass(name)?);
        }
        let d = &gpu.device;
        let module = d.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some("particles"), source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(PARTICLE)) });
        let particle_layout = d.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("particles"), entries: &layout_entries(true, 0, true) });
        let pl = d.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: Some("particles"), bind_group_layouts: &[Some(&particle_layout)], ..Default::default() });
        let attrs = wgpu::vertex_attr_array![0 => Float32x4, 1 => Float32x4];
        let particle = d.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("particles"),
            layout: Some(&pl),
            vertex: wgpu::VertexState {
                module: &module,
                entry_point: Some("vs"),
                buffers: &[Some(wgpu::VertexBufferLayout { array_stride: 32, step_mode: wgpu::VertexStepMode::Instance, attributes: &attrs })],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some("fs"),
                targets: &[Some(wgpu::ColorTargetState { format: WORK, blend: Some(ADD), write_mask: wgpu::ColorWrites::ALL })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::TriangleStrip, ..Default::default() },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });
        let black = crate::upload(gpu, 1, 1, &[0, 0, 0, 255]).create_view(&Default::default());
        Ok(Stage {
            out_format,
            under: pass("under")?,
            feedback: pass("feedback")?,
            passes,
            down: Own::new(gpu, "bloom down", DOWN, 1, WORK, None),
            up: Own::new(gpu, "bloom up", UP, 1, WORK, Some(ADD)),
            finish: Own::new(gpu, "finish", FINISH, 3, out_format, None),
            finish_thumb: Own::new(gpu, "finish (picture)", FINISH, 3, wgpu::TextureFormat::Rgba8Unorm, None),
            wash: Own::new(gpu, "wash", WASH, 0, WORK, None),
            fit: Own::new(gpu, "fit", FIT, 1, WORK, None),
            particle,
            particle_layout,
            particle_buf: None,
            sampler: sampler(gpu),
            arena: Arena::new(gpu, 64 * 1024),
            black,
            work: None,
            scratch: None,
            ground: None,
            leaving: None,
            trail_a: None,
            trail_b: None,
            bloom: Default::default(),
            trail_scene: None,
            particle_scene: None,
            particles: vec![],
            held: None,
            scale: 1.0,
            agx: false,
            milk: None,
            cover: None,
            drawn: Drawn::default(),
        })
    }

    pub fn out_format(&self) -> wgpu::TextureFormat {
        self.out_format
    }

    /// Whether the stage draws `shader`.
    pub fn has(&self, shader: &str) -> bool {
        self.passes.contains_key(shader)
    }

    /// One frame, `dt` seconds after the last, for an output `out_w`×`out_h`: into `out`
    /// (the stage's output format) and into `thumb` (an RGBA8 picture of any size), each
    /// where given (a hidden window draws only the picture). The commands to submit; the
    /// frame's uniforms are already on their way.
    #[allow(clippy::too_many_arguments)]
    pub fn draw(&mut self, gpu: &Gpu, frame: &StageFrame, dt: f64, out: Option<&wgpu::TextureView>, out_w: u32, out_h: u32, thumb: Option<&wgpu::TextureView>) -> wgpu::CommandBuffer {
        // held still: the frame from before the freeze, the hands' white and black over it
        let f = if frame.freeze {
            let mut h = self.held.get_or_insert_with(|| frame.clone()).clone();
            h.white = frame.white;
            h.black = frame.black;
            h
        } else {
            self.held = None;
            frame.clone()
        };
        let dt = if frame.freeze { 0.0 } else { dt };
        let w = ((out_w as f32 * self.scale).round() as u32).max(8);
        let h = ((out_h as f32 * self.scale).round() as u32).max(8);
        self.arena.begin(gpu);
        self.drawn = Drawn { work: (w, h), ..Default::default() };
        let mut enc = gpu.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("stage") });
        let (wf, hf) = (w as f32, h as f32);

        // 1. the ground, into its own picture
        if f.blend.is_some() {
            sized(gpu, &mut self.ground, w, h, "ground");
            let g = &self.ground.as_ref().unwrap().view;
            match &f.ground {
                GroundDraw::Field(l) => match self.passes.get(&l.shader) {
                    Some(p) => {
                        let v = scene_values(p.floats(), wf, hf, &f.common_with(l.knobs));
                        p.draw_in(gpu, &mut enc, &mut self.arena, g, &v, &[]);
                    }
                    None => {
                        self.drawn.missing = Some(l.shader.clone());
                        clear(&mut enc, g, wgpu::Color::BLACK);
                    }
                },
                GroundDraw::Wash => {
                    let p = f.palette;
                    let (a, b) = (p[0].map(|c| c * 0.22), p[1].map(|c| c * 0.12));
                    self.wash.draw(gpu, &mut enc, &mut self.arena, &self.sampler, g, &[wf, hf, f.common[0], 0.0, a[0], a[1], a[2], 1.0, b[0], b[1], b[2], 1.0], &[], false);
                }
                GroundDraw::White => clear(&mut enc, g, wgpu::Color::WHITE),
                GroundDraw::Milk | GroundDraw::Cover => {
                    let (pic, aspect) = if f.ground == GroundDraw::Milk { (self.milk.as_ref(), 16.0 / 9.0) } else { (self.cover.as_ref(), 1.0) };
                    match pic {
                        Some(pic) => self.fit.draw(gpu, &mut enc, &mut self.arena, &self.sampler, g, &[wf, hf, aspect, 0.0], &[pic], false),
                        None => clear(&mut enc, g, wgpu::Color::BLACK),
                    }
                }
                GroundDraw::Black => clear(&mut enc, g, wgpu::Color::BLACK),
            }
        }

        // 2. the figure, and the scene being left (as drawn: no trails, no particles)
        sized(gpu, &mut self.work, w, h, "work");
        sized(gpu, &mut self.scratch, w, h, "scratch");
        {
            let work = &self.work.as_ref().unwrap().view;
            match f.figure.as_ref().and_then(|l| self.passes.get(&l.shader).map(|p| (l, p))) {
                Some((l, p)) => {
                    let v = scene_values(p.floats(), wf, hf, &f.common);
                    let milk = self.milk.as_ref().unwrap_or(&self.black);
                    let tex: Vec<&wgpu::TextureView> = if l.milk { vec![milk] } else { vec![] };
                    p.draw_in(gpu, &mut enc, &mut self.arena, work, &v, &tex);
                }
                None => {
                    if let Some(l) = &f.figure {
                        self.drawn.missing = Some(l.shader.clone());
                    }
                    clear(&mut enc, work, wgpu::Color::BLACK);
                }
            }
        }
        let leaving = match f.from.as_ref().and_then(|l| self.passes.get(&l.shader).map(|p| (l, p))) {
            Some((l, p)) if f.k < 1.0 => {
                let t = sized(gpu, &mut self.leaving, w, h, "leaving");
                let v = scene_values(p.floats(), wf, hf, &f.common_with(l.knobs));
                let milk = self.milk.as_ref().unwrap_or(&self.black);
                let tex: Vec<&wgpu::TextureView> = if l.milk { vec![milk] } else { vec![] };
                p.draw_in(gpu, &mut enc, &mut self.arena, &t.view, &v, &tex);
                true
            }
            _ => false,
        };

        // 3. the particles, added to the figure's light; a new scene starts them afresh
        if self.particle_scene != f.scene {
            self.particles.clear();
            self.particle_scene = f.scene.clone();
        }
        self.particles.retain(|p| f.particles.iter().any(|k| k == p.kind()));
        for k in &f.particles {
            if !self.particles.iter().any(|p| p.kind() == k) {
                self.particles.push(Particles::new(k));
            }
        }
        if !self.particles.is_empty() {
            let c = &f.common;
            // the common block: uEnergy 4, uKick 6, uHigh 9, uDropNear 14, uBuild 15
            let inputs = Inputs { kick: c[6] as f64, energy: c[4] as f64, build: c[15] as f64, drop_near: c[14] as f64, high: c[9] as f64, primary: f.palette[0], accent: f.palette[2], time: c[0] as f64 };
            let mut inst = vec![];
            for p in &mut self.particles {
                if dt > 0.0 {
                    p.step(&inputs, dt, wf as f64, hf as f64);
                }
                p.instances(&inputs, &mut inst);
            }
            self.drawn.particles = inst.len();
            if !inst.is_empty() {
                let bytes: Vec<u8> = inst.iter().flatten().flat_map(|v| v.to_le_bytes()).collect();
                if self.particle_buf.as_ref().is_none_or(|b| (b.size() as usize) < bytes.len()) {
                    self.particle_buf = Some(gpu.device.create_buffer(&wgpu::BufferDescriptor {
                        label: Some("particles"),
                        size: (bytes.len().next_power_of_two()).max(4096) as u64,
                        usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                        mapped_at_creation: false,
                    }));
                }
                let buf = self.particle_buf.as_ref().unwrap();
                gpu.queue.write_buffer(buf, 0, &bytes);
                let u: Vec<u8> = [wf, hf, 0.0, 0.0].iter().flat_map(|v| v.to_le_bytes()).collect();
                if let Some(binding) = self.arena.push(&u) {
                    let group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("particles"),
                        layout: &self.particle_layout,
                        entries: &[wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Buffer(binding) }],
                    });
                    let mut rp = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some("particles"),
                        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                            view: &self.work.as_ref().unwrap().view,
                            depth_slice: None,
                            resolve_target: None,
                            ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
                        })],
                        ..Default::default()
                    });
                    rp.set_pipeline(&self.particle);
                    rp.set_bind_group(0, &group, &[]);
                    rp.set_vertex_buffer(0, buf.slice(..bytes.len() as u64));
                    rp.draw(0..4, 0..inst.len() as u32);
                }
            }
        }

        // 4. the blend: the figure over the ground, its backdrop the rig's way
        if let Some(b) = f.blend {
            let v = values_by(self.under.floats(), |name, _| match name {
                "uResolution" => vec![wf, hf],
                "uMix" => vec![b.mix as u32 as f32],
                "uMask" => vec![b.mask as u32 as f32],
                "uCoverage" => vec![b.coverage as f32],
                "uStrength" => vec![b.strength],
                "uGroundFit" => vec![0.0],
                "uGroundDim" => vec![f.ground_dim],
                _ => vec![],
            });
            let (work, scratch, ground) = (self.work.as_ref().unwrap(), self.scratch.as_ref().unwrap(), self.ground.as_ref().unwrap());
            self.under.draw_in(gpu, &mut enc, &mut self.arena, &scratch.view, &v, &[&work.view, &ground.view]);
            std::mem::swap(&mut self.work, &mut self.scratch);
        }

        // 5. the trails, with the record's recipe
        let mut current_is_trail = false;
        let same = self.trail_scene == f.scene && self.trail_a.as_ref().is_some_and(|t| t.w == w && t.h == h);
        if f.post.trails > 0.0 && frame.freeze && same {
            // held still: the last trails as they were (fed the same frame again and again,
            // the feedback would brighten a frozen picture)
            current_is_trail = true;
        } else if f.post.trails > 0.0 {
            sized(gpu, &mut self.trail_a, w, h, "trail a");
            sized(gpu, &mut self.trail_b, w, h, "trail b");
            self.trail_scene = f.scene.clone();
            let r = f.recipe;
            let v = values_by(self.feedback.floats(), |name, _| match name {
                "uResolution" => vec![wf, hf],
                "uDecay" => vec![r[0]],
                "uZoom" => vec![r[1]],
                "uRotate" => vec![r[2]],
                "uTint" => vec![r[3]],
                "uTintColour" => vec![r[4], r[5], r[6]],
                "uFold" => vec![r[7]],
                "uWarp" => vec![r[8]],
                "uHueTurn" => vec![r[9]],
                "uShiftX" => vec![r[10]],
                "uShiftY" => vec![r[11]],
                "uTime" => vec![f.common[0]],
                _ => vec![],
            });
            let work = &self.work.as_ref().unwrap().view;
            let prev = if same { &self.trail_a.as_ref().unwrap().view } else { work };
            self.feedback.draw_in(gpu, &mut enc, &mut self.arena, &self.trail_b.as_ref().unwrap().view, &v, &[prev, work]);
            std::mem::swap(&mut self.trail_a, &mut self.trail_b);
            current_is_trail = true;
        } else {
            self.trail_scene = None;
        }
        let current = if current_is_trail { self.trail_a.as_ref().unwrap() } else { self.work.as_ref().unwrap() };

        // 6. the bloom: five levels down, back up
        let (mut bw, mut bh) = (w, h);
        for (i, slot) in self.bloom.iter_mut().enumerate() {
            bw = (bw / 2).max(2);
            bh = (bh / 2).max(2);
            sized(gpu, slot, bw, bh, ["bloom 1", "bloom 2", "bloom 3", "bloom 4", "bloom 5"][i]);
        }
        let mut src = current;
        for i in 0..5 {
            let dst = self.bloom[i].as_ref().unwrap();
            let fl = [1.0 / src.w as f32, 1.0 / src.h as f32, if i == 0 { 1.0 } else { 0.0 }, 0.0];
            self.down.draw(gpu, &mut enc, &mut self.arena, &self.sampler, &dst.view, &fl, &[&src.view], false);
            src = dst;
        }
        for i in (1..5).rev() {
            let (lo, hi) = (self.bloom[i].as_ref().unwrap(), self.bloom[i - 1].as_ref().unwrap());
            self.up.draw(gpu, &mut enc, &mut self.arena, &self.sampler, &hi.view, &[1.0 / lo.w as f32, 1.0 / lo.h as f32, 1.0, 0.0], &[&lo.view], true);
        }

        // 7. the finish, at the output's size (and the picture for the Desk)
        let p = f.post;
        let from = if leaving { &self.leaving.as_ref().unwrap().view } else { &self.black };
        let mixk = if leaving { f.k } else { 1.0 };
        let bloom0 = &self.bloom[0].as_ref().unwrap().view;
        let fl = [out_w as f32, out_h as f32, p.bloom, p.vignette, p.grain, p.tone, p.fringe, f.common[0], if self.agx { 1.0 } else { 0.0 }, mixk, f.white, f.black];
        if let Some(out) = out {
            self.finish.draw(gpu, &mut enc, &mut self.arena, &self.sampler, out, &fl, &[&current.view, bloom0, from], false);
        }
        if let Some(t) = thumb {
            self.finish_thumb.draw(gpu, &mut enc, &mut self.arena, &self.sampler, t, &fl, &[&current.view, bloom0, from], false);
        }
        self.arena.upload(gpu);
        enc.finish()
    }
}

/// The working size let down while frames come late and back up while they are early (v1's
/// native stage's rule): 30 late frames in a row (over 90% of the frame's time) take it down
/// by 15%, to half at most; 300 quick ones (under half) bring it back a step, to `top`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Adapt {
    pub scale: f32,
    pub top: f32,
    late: u32,
    on_time: u32,
}

impl Adapt {
    pub fn new(top: f32) -> Adapt {
        Adapt { scale: top, top, late: 0, on_time: 0 }
    }

    /// A frame that took `took` seconds of a `budget`: the scale for the next.
    pub fn frame(&mut self, took: f64, budget: f64) -> f32 {
        if took > budget * 0.9 {
            self.on_time = 0;
            self.late += 1;
            if self.late >= 30 {
                self.late = 0;
                self.scale = (self.scale * 0.85).max(0.5 * self.top);
            }
        } else if took < budget * 0.5 {
            self.late = 0;
            self.on_time += 1;
            if self.on_time >= 300 && self.scale < self.top {
                self.on_time = 0;
                self.scale = (self.scale / 0.85).min(self.top);
            }
        } else {
            self.late = 0;
        }
        self.scale
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn late_frames_let_the_size_down_and_quick_ones_bring_it_back() {
        let mut a = Adapt::new(1.0);
        let budget = 1.0 / 60.0;
        for _ in 0..29 {
            a.frame(0.020, budget);
        }
        assert_eq!(a.scale, 1.0, "not yet");
        a.frame(0.020, budget);
        assert!((a.scale - 0.85).abs() < 1e-6);
        for _ in 0..300 {
            a.frame(0.020, budget);
        }
        assert_eq!(a.scale, 0.5, "half at most");
        // a frame in between keeps it
        a.frame(0.012, budget);
        assert_eq!(a.scale, 0.5);
        for _ in 0..300 * 6 {
            a.frame(0.004, budget);
        }
        assert_eq!(a.scale, 1.0, "back to the top, no further");
    }
}
