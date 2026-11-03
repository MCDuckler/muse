//! The looks over the figure (v1: the native stage's stage.cpp treatPass / ghostPass and fx.h's
//! Slit and Mosh), on wgpu:
//!
//! - [Treat]: a style of sim/dance_fx.frag over the figure (ascii, dither, contour, halftone,
//!   thermal, lines, crt), the ascii's glyphs from the ramp made once (assets/glyphs.png);
//! - [Ghosts]: the kaleidoscope (shaders/show/ghosts.frag);
//! - [Slit]: the slit-scan — the figure's last frames kept in a ring of pictures, and each part
//!   of the picture taken from a frame further back than the next (the rows, the columns, out
//!   from the middle, a wave, bands, out from the middle line);
//! - [Mosh]: the datamosh — a change of scene with its key frame lost: the last picture of
//!   the scene being left dragged along the new one's motion (found block by block, as a
//!   codec's P-frames find it, read as a smooth field carried on frame to frame), the new
//!   picture's change let in slowly and the new picture breaking through in patches; or held
//!   on and on over whatever is drawn, healed and taken whole as the hands (the mosh clock) say,
//!   and whole again when it goes to mud.
//!
//! The scene shaders are the .frag files; the slit-scan's and the mosh's passes are the stage's
//! own, in WGSL, ported from fx.h's GLSL ES. There a pass's `uv` and `gl_FragCoord` run up
//! from the bottom row (GL's way); here down from the top. Where a pass's picture depends on
//! where it is rather than on what is there (the slit-scan's shapes, the mosh's swirl), it is
//! worked out the GL way up, so the two stages draw it the same way round (held side by side
//! by examples/native_twin.rs: the native stage's mosh drips down, not up).
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use wo_show::mosh::MoshDrive;
use wo_show::treat::{FxDraw, Kaleido, SlitDraw};

use crate::stage::{FIT, Own, Target, WORK, clear, copy_into, sized, sized_as};
use crate::{Arena, Gpu, Pass, values_by};

/// The ramp's glyphs, light to dense, side by side (assets/make_glyphs.py).
const GLYPHS_PNG: &[u8] = include_bytes!("../assets/glyphs.png");
pub const GLYPH_COUNT: u32 = 10;

/// The ascii's glyphs as a texture.
fn glyphs(gpu: &Gpu) -> wgpu::TextureView {
    let img = image::load_from_memory_with_format(GLYPHS_PNG, image::ImageFormat::Png).expect("the shipped glyphs").to_rgba8();
    crate::upload(gpu, img.width(), img.height(), img.as_raw()).create_view(&Default::default())
}

/// A style of dance_fx.frag over the figure.
pub struct Treat {
    pass: Pass,
    glyphs: wgpu::TextureView,
    count: u32,
}

impl Treat {
    pub fn new(gpu: &Gpu) -> Result<Treat, String> {
        let f = wo_shaders::fit_shipped("sim/dance_fx.frag").map_err(|t| t.to_string())?;
        Ok(Treat { pass: Pass::new(gpu, &f, WORK), glyphs: glyphs(gpu), count: GLYPH_COUNT })
    }

    /// Another ramp: `count` glyphs side by side in `rgba` (`w`×`h`), light to dense.
    pub fn set_glyphs(&mut self, gpu: &Gpu, w: u32, h: u32, rgba: &[u8], count: u32) {
        self.glyphs = crate::upload(gpu, w, h, rgba).create_view(&Default::default());
        self.count = count.max(1);
    }

    /// `src` through the style into `dst` (both the working size), the kick's swell `pop`,
    /// `time` seconds of the stage's clock.
    #[allow(clippy::too_many_arguments)]
    pub fn draw(&self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, src: &Target, dst: &Target, d: &FxDraw, pop: f32, time: f32) {
        let p = wo_dance::cmd::Post { mode: d.mode, cell: d.cell(src.h as f32), ink: d.ink, paper: d.paper, tint: d.tint, glyphs: self.count, pop, pop_at: [0.5, 0.5], time, knobs: d.knobs };
        // the alpha stays 1, as a scene's is (the blend reads its own coverage)
        self.draw_post(gpu, enc, arena, src, dst, &p, 1.0, 0.0);
    }

    /// `src` through a finish into `dst`: `p`'s cell in pixels of `src` times `cell_k`, the
    /// alpha out the coverage where `coverage_out` is 1 (the dancers': the glyphs, the dots,
    /// the lines are the figure), else 1.
    #[allow(clippy::too_many_arguments)]
    pub fn draw_post(&self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, src: &Target, dst: &Target, p: &wo_dance::cmd::Post, cell_k: f32, coverage_out: f32) {
        let (w, h) = (src.w as f32, src.h as f32);
        let v = values_by(self.pass.floats(), |name, _| match name {
            "uResolution" => vec![w, h],
            "uMode" => vec![p.mode as f32],
            "uCell" => vec![p.cell * cell_k],
            "uInk" => p.ink.to_vec(),
            "uPaper" => p.paper.to_vec(),
            "uTint" => vec![p.tint],
            "uGlyphs" => vec![if p.glyphs > 0 { p.glyphs as f32 } else { self.count as f32 }],
            "uPop" => vec![p.pop],
            "uPopAt" => p.pop_at.to_vec(),
            "uTime" => vec![p.time],
            "uCoverageOut" => vec![coverage_out],
            "uWeight" => vec![p.knobs[0]],
            "uSpacing" => vec![p.knobs[1]],
            "uHeight" => vec![p.knobs[2]],
            "uGain" => vec![p.knobs[3]],
            "uSize" => vec![p.knobs[4]],
            _ => vec![],
        });
        self.pass.draw_in(gpu, enc, arena, &dst.view, &v, &[&src.view, &self.glyphs]);
    }
}

/// The kaleidoscope.
pub struct Ghosts {
    pass: Pass,
}

impl Ghosts {
    pub fn new(gpu: &Gpu) -> Result<Ghosts, String> {
        let f = wo_shaders::fit_shipped("ghosts.frag").map_err(|t| t.to_string())?;
        Ok(Ghosts { pass: Pass::new(gpu, &f, WORK) })
    }

    pub fn draw(&self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, src: &Target, dst: &Target, k: &Kaleido) {
        let v = values_by(self.pass.floats(), |name, _| match name {
            "uResolution" => vec![src.w as f32, src.h as f32],
            "uCount" => vec![k.count as f32],
            "uDiffer" => vec![k.differ],
            "uTurn" => vec![k.turn],
            "uLine" => vec![k.line],
            "uBlend" => vec![k.blend as f32],
            "uAmount" => vec![k.amount],
            _ => vec![],
        });
        self.pass.draw_in(gpu, enc, arena, &dst.view, &v, &[&src.view]);
    }
}

// ------------------------------------------------------------------ the slit-scan

const SLIT: &str = "
struct U { res: vec2<f32>, head: f32, layers: f32, filled: f32, span: f32, shape: f32, time: f32, kick: f32, flip: f32, pad0: f32, pad1: f32 };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var now_t: texture_2d<f32>;
@group(0) @binding(2) var s0: sampler;
@group(0) @binding(3) var hist: texture_2d_array<f32>;
@group(0) @binding(4) var s1: sampler;
fn delay(uv: vec2<f32>) -> f32 {
    let s = i32(u.shape + 0.5);
    let a = u.res.x / u.res.y;
    var d: f32;
    if (s == 1) { d = uv.x; }                                                       // the columns
    else if (s == 2) { d = length((uv - 0.5) * vec2<f32>(a, 1.0)) * 1.25; }          // out from the middle
    else if (s == 3) { d = 0.5 + 0.5 * sin(uv.y * 7.0 + uv.x * 2.0 - u.time * 1.1); } // a wave
    else if (s == 4) { d = floor(uv.y * 9.0) / 8.0; }                               // bands
    else if (s == 5) { d = abs(uv.x - 0.5) * 2.0; }                                 // out from the middle line
    else { d = 1.0 - uv.y; }                                                        // the rows, the top the oldest
    if (u.flip > 0.5) { d = 1.0 - d; }
    return clamp(d, 0.0, 1.0);
}
fn gmod(x: f32, y: f32) -> f32 { return x - y * floor(x / y); }
fn layer(uv: vec2<f32>, back: f32) -> vec4<f32> {
    let i = i32(round(gmod(u.head - back + u.layers * 4.0, u.layers)));
    return textureSampleLevel(hist, s1, uv, i, 0.0);
}
@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    let uv = v.uv;
    let span = min(u.span * (1.0 + 0.25 * u.kick), u.filled - 1.0);
    // the shapes as GL lays them out (its first row the bottom)
    let d = delay(vec2<f32>(uv.x, 1.0 - uv.y)) * max(span, 0.0);
    let i = floor(d);
    let f = d - i;
    if (i < 0.5) {
        return mix(textureSampleLevel(now_t, s0, uv, 0.0), layer(uv, 1.0), f);
    }
    return mix(layer(uv, i), layer(uv, i + 1.0), f);
}
";

/// The slit-scan's ring of the figure's last frames, at half the working size (960×540 at
/// most), 8 bits a channel as v1's.
pub struct Slit {
    pass: Own,
    keep: Own,
    ring: Option<(wgpu::Texture, wgpu::TextureView, Vec<wgpu::TextureView>)>,
    size: (u32, u32),
    head: i64,
    filled: u32,
    last_frame: i64,
    frames: i64,
}

impl Slit {
    pub const LAYERS: u32 = 40;

    pub fn new(gpu: &Gpu) -> Slit {
        Slit {
            pass: Own::with(gpu, "slit-scan", SLIT, &[wgpu::TextureViewDimension::D2, wgpu::TextureViewDimension::D2Array], WORK, None),
            keep: Own::new(gpu, "slit-scan's ring", FIT, 1, wgpu::TextureFormat::Rgba8Unorm, None),
            ring: None,
            size: (0, 0),
            head: -1,
            filled: 0,
            last_frame: -10,
            frames: 0,
        }
    }

    /// The figure in `src` drawn out along its time into `dst`; `frame` the stage's frame
    /// count (a gap: what is in the ring is another picture), `kick` the kick's decay.
    #[allow(clippy::too_many_arguments)]
    pub fn draw(&mut self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, smp: &wgpu::Sampler, src: &Target, dst: &Target, s: &SlitDraw, kick: f32, time: f32, frame: i64) {
        let (w, h) = ((src.w / 2).clamp(16, 960), (src.h / 2).clamp(9, 540));
        if self.size != (w, h) || self.ring.is_none() {
            let t = gpu.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("slit-scan's ring"),
                size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: Self::LAYERS },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            });
            let all = t.create_view(&wgpu::TextureViewDescriptor { dimension: Some(wgpu::TextureViewDimension::D2Array), ..Default::default() });
            let layers = (0..Self::LAYERS)
                .map(|i| {
                    t.create_view(&wgpu::TextureViewDescriptor {
                        dimension: Some(wgpu::TextureViewDimension::D2),
                        base_array_layer: i,
                        array_layer_count: Some(1),
                        ..Default::default()
                    })
                })
                .collect();
            self.ring = Some((t, all, layers));
            self.size = (w, h);
            self.head = -1;
            self.filled = 0;
        }
        if frame - self.last_frame > 3 {
            self.head = -1;
            self.filled = 0;
            self.frames = 0;
        }
        self.last_frame = frame;
        // frames a layer: the spacing knob × 2 (1..4)
        let every = (s.slower * 2.0).round().clamp(1.0, 4.0) as i64;
        let (_, all, layers) = self.ring.as_ref().unwrap();
        if self.frames % every == 0 {
            self.head = (self.head + 1) % Self::LAYERS as i64;
            self.filled = (self.filled + 1).min(Self::LAYERS);
            self.keep.draw(gpu, enc, arena, smp, &layers[self.head as usize], &[w as f32, h as f32, 0.0, 0.0], &[&src.view], false);
        }
        self.frames += 1;
        let span = (Self::LAYERS - 1) as f32 * s.reach.clamp(0.1, 1.0);
        let fl = [src.w as f32, src.h as f32, self.head as f32, Self::LAYERS as f32, self.filled as f32, span, s.shape, time, kick, if s.flip { 1.0 } else { 0.0 }, 0.0, 0.0];
        self.pass.draw(gpu, enc, arena, smp, &dst.view, &fl, &[&src.view, all], false);
    }
}

// ------------------------------------------------------------------ the datamosh

const HASH: &str = "
fn hash12(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    var f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash12(i), hash12(i + vec2<f32>(1.0, 0.0)), f.x), mix(hash12(i + vec2<f32>(0.0, 1.0)), hash12(i + vec2<f32>(1.0, 1.0)), f.x), f.y);
}
";

/// The new picture's brightness at a quarter of its size, four taps a texel.
const MOSH_LUMA: &str = "
struct U { texel: vec2<f32>, pad: vec2<f32> };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;
fn l(uv: vec2<f32>, o: vec2<f32>) -> f32 { return dot(textureSampleLevel(src, smp, uv + o * u.texel, 0.0).rgb, vec3<f32>(0.299, 0.587, 0.114)); }
@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    let uv = v.uv;
    return vec4<f32>((l(uv, vec2(-1.0, -1.0)) + l(uv, vec2(1.0, -1.0)) + l(uv, vec2(-1.0, 1.0)) + l(uv, vec2(1.0, 1.0))) * 0.25, 0.0, 0.0, 1.0);
}
";

/// The motion, a block of 16 pixels (4 of the quarter picture) at a time: where in the last
/// frame this block's picture was, searched ±4 quarter pixels, a little against moving at all.
const MOSH_MATCH: &str = "
struct U { size: vec2<f32>, pad: vec2<f32> };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var now_t: texture_2d<f32>;
@group(0) @binding(2) var s0: sampler;
@group(0) @binding(3) var prev_t: texture_2d<f32>;
@group(0) @binding(4) var s1: sampler;
fn sad(b: vec2<i32>, d: vec2<i32>) -> f32 {
    var s = 0.0;
    let hi = vec2<i32>(u.size) - 1;
    for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
            let p = b + vec2<i32>(x, y);
            let q = clamp(p + d, vec2<i32>(0), hi);
            s += abs(textureLoad(now_t, p, 0).r - textureLoad(prev_t, q, 0).r);
        }
    }
    return s;
}
@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    let b = vec2<i32>(v.pos.xy) * 4;
    var best = sad(b, vec2<i32>(0)) - 0.02;
    var at = vec2<i32>(0);
    for (var y = -4; y <= 4; y++) {
        for (var x = -4; x <= 4; x++) {
            if (x == 0 && y == 0) { continue; }
            let s = sad(b, vec2<i32>(x, y)) + 0.004 * f32(abs(x) + abs(y));
            if (s < best) { best = s; at = vec2<i32>(x, y); }
        }
    }
    return vec4<f32>(vec2<f32>(at), best / 16.0, 1.0);
}
";

/// The motion as a smooth field, a quarter of the picture: the blocks' motion read between
/// them, a little of the picture's own flow (Horn and Schunck, one step), the last frame's
/// field carried on; a swirl where the new scene is still, a push out on the kick.
const MOSH_FIELD: &str = "
struct U { size: vec2<f32>, kick: f32, fresh: f32, time: f32, seed: f32, swirl: f32, pad: f32 };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var mv_t: texture_2d<f32>;
@group(0) @binding(2) var s0: sampler;
@group(0) @binding(3) var field_t: texture_2d<f32>;
@group(0) @binding(4) var s1: sampler;
@group(0) @binding(5) var now_t: texture_2d<f32>;
@group(0) @binding(6) var s2: sampler;
@group(0) @binding(7) var prev_t: texture_2d<f32>;
@group(0) @binding(8) var s3: sampler;
HASH
fn swirl(uv: vec2<f32>) -> vec2<f32> {
    let p = uv * vec2<f32>(2.6, 1.6) + vec2<f32>(u.seed, u.time * 0.15);
    let e = 0.05;
    let n = noise(p) + 0.5 * noise(p * 2.1 + 7.0);
    let nx = noise(p + vec2<f32>(e, 0.0)) + 0.5 * noise((p + vec2<f32>(e, 0.0)) * 2.1 + 7.0);
    let ny = noise(p + vec2<f32>(0.0, e)) + 0.5 * noise((p + vec2<f32>(0.0, e)) * 2.1 + 7.0);
    return vec2<f32>(ny - n, -(nx - n)) / e;
}
fn mv_at(q: vec2<f32>) -> vec2<f32> {
    let b = q / 4.0 - 0.5;
    let i = vec2<i32>(floor(b));
    let f = fract(b);
    let hi = vec2<i32>(textureDimensions(mv_t)) - 1;
    let a = textureLoad(mv_t, clamp(i, vec2<i32>(0), hi), 0).xy;
    let c = textureLoad(mv_t, clamp(i + vec2<i32>(1, 0), vec2<i32>(0), hi), 0).xy;
    let d = textureLoad(mv_t, clamp(i + vec2<i32>(0, 1), vec2<i32>(0), hi), 0).xy;
    let e = textureLoad(mv_t, clamp(i + vec2<i32>(1, 1), vec2<i32>(0), hi), 0).xy;
    return mix(mix(a, c, f.x), mix(d, e, f.x), f.y);
}
fn at(t: texture_2d<f32>, s: sampler, uv: vec2<f32>) -> f32 { return textureSampleLevel(t, s, uv, 0.0).r; }
@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    let q = v.pos.xy;
    let uv = v.uv;
    var m = (mv_at(q) * 2.0 + mv_at(q + vec2<f32>(3.0, 0.0)) + mv_at(q - vec2<f32>(3.0, 0.0)) + mv_at(q + vec2<f32>(0.0, 3.0)) + mv_at(q - vec2<f32>(0.0, 3.0))) / 6.0;
    let t = 1.0 / u.size;
    let it = at(now_t, s2, uv) - at(prev_t, s3, uv);
    let g = vec2<f32>(at(now_t, s2, uv + vec2<f32>(t.x, 0.0)) - at(now_t, s2, uv - vec2<f32>(t.x, 0.0)),
                      at(now_t, s2, uv + vec2<f32>(0.0, t.y)) - at(now_t, s2, uv - vec2<f32>(0.0, t.y))) * 0.5;
    m += clamp(-it * g / (dot(g, g) + 0.004), vec2<f32>(-3.0), vec2<f32>(3.0)) * 0.6;
    let still = 1.0 - smoothstep(0.3, 2.0, length(m));
    // the swirl as GL turns it (its rows up from the bottom), turned back to ours
    let sw = swirl(vec2<f32>(uv.x, 1.0 - uv.y));
    m += vec2<f32>(sw.x, -sw.y) * u.swirl * still;
    m += (uv - 0.5) * u.kick * 6.0;
    let back = uv + m * t;
    let was = (textureSampleLevel(field_t, s1, back, 0.0).xy * 4.0 + textureSampleLevel(field_t, s1, back + vec2<f32>(t.x, 0.0), 0.0).xy
             + textureSampleLevel(field_t, s1, back - vec2<f32>(t.x, 0.0), 0.0).xy + textureSampleLevel(field_t, s1, back + vec2<f32>(0.0, t.y), 0.0).xy
             + textureSampleLevel(field_t, s1, back - vec2<f32>(0.0, t.y), 0.0).xy) / 8.0;
    var f = mix(was, m, u.fresh);
    f *= 1.0 + u.kick * 0.5;
    return vec4<f32>(clamp(f, vec2<f32>(-24.0), vec2<f32>(24.0)), 0.0, 1.0);
}
";

/// One frame of the mosh: the old picture dragged along the field and smeared down it, block
/// by block where it moves; the colour dragged further and coarser than the light; the new
/// picture's change let in slowly and coarse; the new picture breaking through in patches.
const MOSH_STEP: &str = "
struct U { res: vec2<f32>, k: f32, strength: f32, kick: f32, have_prev: f32, seed: f32, glitch: f32, fade: f32, pad0: f32, pad1: f32, pad2: f32 };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var old_t: texture_2d<f32>;
@group(0) @binding(2) var s0: sampler;
@group(0) @binding(3) var now_t: texture_2d<f32>;
@group(0) @binding(4) var s1: sampler;
@group(0) @binding(5) var prev_t: texture_2d<f32>;
@group(0) @binding(6) var s2: sampler;
@group(0) @binding(7) var mv_t: texture_2d<f32>;
@group(0) @binding(8) var s3: sampler;
@group(0) @binding(9) var field_t: texture_2d<f32>;
@group(0) @binding(10) var s4: sampler;
@group(0) @binding(11) var luma_t: texture_2d<f32>;
@group(0) @binding(12) var s5: sampler;
HASH
fn to_ycc(c: vec3<f32>) -> vec3<f32> { return vec3<f32>(dot(c, vec3<f32>(0.25, 0.5, 0.25)), dot(c, vec3<f32>(0.5, 0.0, -0.5)), dot(c, vec3<f32>(-0.25, 0.5, -0.25))); }
fn to_rgb(y: vec3<f32>) -> vec3<f32> { return vec3<f32>(y.x + y.y - y.z, y.x + y.z, y.x - y.y - y.z); }
fn old(uv: vec2<f32>) -> vec3<f32> { return textureSampleLevel(old_t, s0, uv, 0.0).rgb; }
@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    let px = v.pos.xy;
    let uv = px / u.res;
    let r = 1.0 / u.res;
    let scale = u.res.x / f32(textureDimensions(field_t).x);
    let bs = 4.0 * scale;
    let cell = floor(px / bs);
    let split = step(0.6, hash12(cell + u.seed * 0.37));
    let sub = floor(px / (bs * 0.5));
    let block_at = mix(cell * bs + bs * 0.5, sub * bs * 0.5 + bs * 0.25, split);
    let field = textureSampleLevel(field_t, s4, uv, 0.0).xy * scale * u.have_prev;
    let block_field = textureSampleLevel(field_t, s4, block_at * r, 0.0).xy * scale * u.have_prev;
    let hi = vec2<i32>(textureDimensions(mv_t)) - 1;
    let block = textureLoad(mv_t, clamp(vec2<i32>(px / bs), vec2<i32>(0), hi), 0).xy * scale * u.have_prev;
    let moving = smoothstep(0.3, 2.0, length(block_field));
    let blocky = u.glitch * mix(0.15, 0.85, moving);
    var mv = mix(field, mix(block_field, block, 0.35), blocky);
    let wild = step(1.0 - u.glitch * (0.12 + 0.3 * u.kick), hash12(cell + floor(u.k * 9.0) + u.seed));
    mv *= (1.4 + 0.8 * u.strength) * (1.0 + wild * 2.2);
    let lt = 1.0 / vec2<f32>(textureDimensions(luma_t));
    let slope = vec2<f32>(textureSampleLevel(luma_t, s5, uv + vec2<f32>(lt.x, 0.0), 0.0).r - textureSampleLevel(luma_t, s5, uv - vec2<f32>(lt.x, 0.0), 0.0).r,
                          textureSampleLevel(luma_t, s5, uv + vec2<f32>(0.0, lt.y), 0.0).r - textureSampleLevel(luma_t, s5, uv - vec2<f32>(0.0, lt.y), 0.0).r);
    mv += slope * 14.0 * u.strength * (1.0 - u.k);
    let a = old(uv + mv * r);
    let b = old(uv + mv * 0.5 * r);
    let c = old(uv + mv * 1.6 * r);
    let d = old(uv + mv * 2.4 * r);
    var o = mix(a * 0.4 + b * 0.3 + c * 0.2 + d * 0.1, max(a, b), 0.2);
    let chroma_at = mix(uv, (floor(px / 4.0) * 4.0 + 2.0) * r, u.glitch) + mv * (1.0 + 0.6 * u.glitch) * r;
    var ycc = to_ycc(o);
    let cc = mix(ycc.yz, to_ycc(old(chroma_at)).yz, 0.5 + 0.4 * u.glitch);
    ycc = vec3<f32>(ycc.x, cc);
    o = to_rgb(ycc) * u.fade;
    let now = textureSampleLevel(now_t, s1, uv, 0.0).rgb;
    var res = (now - textureSampleLevel(prev_t, s2, uv + mv * r, 0.0).rgb) * u.have_prev;
    let rb = (floor(px / 8.0) * 8.0 + 4.0) * r;
    var res_block = (textureSampleLevel(now_t, s1, rb, 0.0).rgb - textureSampleLevel(prev_t, s2, rb + mv * r, 0.0).rgb) * u.have_prev;
    res_block = floor(res_block * 6.0 + 0.5) / 6.0;
    res = mix(res, res_block, u.glitch * 0.7);
    var col = o + res * smoothstep(0.08, 0.6, u.k) * (0.7 + 0.3 * u.strength);
    let n_at = mix(uv, (cell * bs + bs * 0.5) * r, u.glitch * 0.8);
    var n = noise(n_at * vec2<f32>(4.0, 2.4) + u.seed) * 0.65 + noise(n_at * vec2<f32>(11.0, 6.5) - u.seed) * 0.35;
    n -= clamp(length(field) * 0.05, 0.0, 0.25);
    let stuck = step(1.0 - 0.07 * u.glitch, hash12(cell * 1.7 + u.seed));
    n += stuck * 0.6;
    let edge = u.k * 1.45 - 0.42;
    let soft = mix(0.1, 0.02, u.glitch);
    let reveal = 1.0 - smoothstep(edge - soft, edge + soft, n);
    col = mix(col, now, reveal);
    col = mix(col, now, smoothstep(0.9, 1.0, u.k));
    return vec4<f32>(clamp(col, vec3<f32>(0.0), vec3<f32>(8.0)), 1.0);
}
";

/// A small picture read back without waiting: copied this frame, mapped once that frame is
/// submitted, read when the GPU says so.
struct Readback {
    target: Option<Target>,
    buf: wgpu::Buffer,
    state: u8,
    done: Arc<AtomicU8>,
}

const LOOK_W: u32 = 32;
const LOOK_H: u32 = 18;
const LOOK_ROW: u32 = 256;

const IDLE: u8 = 0;
const COPIED: u8 = 1;
const MAPPING: u8 = 2;

impl Readback {
    fn new(gpu: &Gpu) -> Readback {
        Readback {
            target: None,
            buf: gpu.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("the mosh's look"),
                size: (LOOK_ROW * LOOK_H) as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            }),
            state: IDLE,
            done: Arc::new(AtomicU8::new(0)),
        }
    }

    /// The light's mean and spread and the colour's mean, of what was read.
    fn look(&self) -> (f64, f64, f64) {
        let data = self.buf.slice(..).get_mapped_range();
        let Ok(data) = data else { return (0.5, 0.5, 0.5) };
        let (mut sum, mut sq, mut chroma) = (0.0, 0.0, 0.0);
        for y in 0..LOOK_H as usize {
            for x in 0..LOOK_W as usize {
                let p = &data[y * LOOK_ROW as usize + x * 4..][..3];
                let [r, g, b] = [p[0], p[1], p[2]].map(|v| v as f64 / 255.0);
                let l = 0.299 * r + 0.587 * g + 0.114 * b;
                sum += l;
                sq += l * l;
                chroma += r.max(g).max(b) - r.min(g).min(b);
            }
        }
        let n = (LOOK_W * LOOK_H) as f64;
        let mean = sum / n;
        (mean, (sq / n - mean * mean).max(0.0).sqrt(), chroma / n)
    }
}

/// The datamosh.
pub struct Mosh {
    luma: Own,
    matcher: Own,
    field: Own,
    step: Own,
    fit: Own,
    fit8: Own,
    a: Option<Target>,
    b: Option<Target>,
    prev: Option<Target>,
    luma_now: Option<Target>,
    luma_prev: Option<Target>,
    mv: Option<Target>,
    field_a: Option<Target>,
    field_b: Option<Target>,
    look1: Option<Target>,
    looks: [Readback; 2],
    pub active: bool,
    pub held: bool,
    have_prev: bool,
    k: f32,
    seconds: f32,
    strength: f32,
    seed: f32,
    mud_key: bool,
    since_look: f32,
    since_start: f32,
    keys_seen: i64,
    /// How many key frames the mud has asked for.
    pub mud_keys: u32,
    /// How much of the codec's grain on a change: 0 a smooth melt, 1 all blocks.
    pub glitch: f32,
}

impl Mosh {
    pub fn new(gpu: &Gpu) -> Mosh {
        let own = |name, body: &str, n| Own::new(gpu, name, &body.replace("HASH", HASH), n, WORK, None);
        Mosh {
            luma: own("the mosh's light", MOSH_LUMA, 1),
            matcher: own("the mosh's motion", MOSH_MATCH, 2),
            field: own("the mosh's field", MOSH_FIELD, 4),
            step: own("the mosh", MOSH_STEP, 6),
            fit: own("the mosh's copy", FIT, 1),
            fit8: Own::new(gpu, "the mosh's look", FIT, 1, wgpu::TextureFormat::Rgba8Unorm, None),
            a: None,
            b: None,
            prev: None,
            luma_now: None,
            luma_prev: None,
            mv: None,
            field_a: None,
            field_b: None,
            look1: None,
            looks: [Readback::new(gpu), Readback::new(gpu)],
            active: false,
            held: false,
            have_prev: false,
            k: 0.0,
            seconds: 1.0,
            strength: 1.0,
            seed: 0.0,
            mud_key: false,
            since_look: 0.0,
            since_start: 0.0,
            keys_seen: 0,
            mud_keys: 0,
            glitch: 0.8,
        }
    }

    /// The moshed picture (while [Mosh::active]).
    pub fn picture(&self) -> Option<&Target> {
        self.a.as_ref()
    }

    /// Before a frame's commands: the looks copied last frame mapped (that frame is
    /// submitted now), and those the GPU has finished with read.
    pub fn poll(&mut self) {
        for r in &mut self.looks {
            if r.state == COPIED {
                r.done.store(0, Ordering::Release);
                let done = r.done.clone();
                r.buf.slice(..).map_async(wgpu::MapMode::Read, move |res| done.store(if res.is_ok() { 1 } else { 2 }, Ordering::Release));
                r.state = MAPPING;
            }
        }
        let [m, s] = &self.looks;
        if m.state == MAPPING && s.state == MAPPING && m.done.load(Ordering::Acquire) != 0 && s.done.load(Ordering::Acquire) != 0 {
            let ok = m.done.load(Ordering::Acquire) == 1 && s.done.load(Ordering::Acquire) == 1;
            if ok && self.held && muddy(m.look(), s.look()) {
                self.mud_key = true;
                self.mud_keys += 1;
            }
            for r in &mut self.looks {
                if r.done.load(Ordering::Acquire) == 1 {
                    r.buf.unmap();
                }
                r.state = IDLE;
            }
        }
    }

    /// A change moshed: the picture being left (`last`, None where `last` is the moshed
    /// picture itself) kept, the mosh starting from it, `w`×`h` the working size.
    #[allow(clippy::too_many_arguments)]
    pub fn begin(&mut self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, smp: &wgpu::Sampler, last: Option<&Target>, w: u32, h: u32, seconds: f32, strength: f32) {
        // held, the new scene's motion moves the moshed picture on as it is: that is the
        // change's mosh already
        if self.held {
            return;
        }
        sized(gpu, &mut self.a, w, h, "mosh a");
        sized(gpu, &mut self.b, w, h, "mosh b");
        // under a mosh already on, the moshed picture goes on being moshed
        if !self.active {
            match last {
                Some(l) => copy_into(gpu, enc, arena, &self.fit, smp, l, self.a.as_ref().unwrap()),
                None => {
                    if self.a.as_ref().is_some_and(|a| a.w != w || a.h != h) {
                        return;
                    }
                }
            }
        }
        self.active = true;
        self.have_prev = false;
        self.k = 0.0;
        self.seconds = seconds.max(0.2);
        self.strength = strength.clamp(0.0, 2.0);
        self.seed += 17.13;
    }

    /// One frame of a change's mosh, `now` the new scene: whether the picture to show is the
    /// moshed one ([Mosh::picture]).
    #[allow(clippy::too_many_arguments)]
    pub fn step(&mut self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, smp: &wgpu::Sampler, now: &Target, dt: f64, kick: f32) -> bool {
        if !self.active || self.held {
            return false;
        }
        if self.a.as_ref().is_none_or(|a| a.w != now.w || a.h != now.h) {
            self.active = false;
            return false;
        }
        let (k, strength, glitch) = (self.k, self.strength, self.glitch);
        self.run(gpu, enc, arena, smp, now, kick, k, strength, glitch, 0.997);
        self.k += (dt / self.seconds as f64) as f32;
        if self.k >= 1.0 {
            self.active = false;
        }
        true
    }

    /// Held from the picture `now` (whole), till let go.
    fn hold(&mut self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, smp: &wgpu::Sampler, now: &Target) {
        sized(gpu, &mut self.a, now.w, now.h, "mosh a");
        sized(gpu, &mut self.b, now.w, now.h, "mosh b");
        copy_into(gpu, enc, arena, &self.fit, smp, now, self.a.as_ref().unwrap());
        self.active = true;
        self.held = true;
        self.have_prev = false;
        self.mud_key = false;
        self.since_look = 0.0;
        self.since_start = 0.0;
        self.seed += 17.13;
    }

    /// Let go of the hold.
    pub fn release(&mut self) {
        if self.held {
            self.active = false;
        }
        self.held = false;
    }

    /// One held frame (the mosh clock's numbers in `d`): the picture to show is the moshed one.
    #[allow(clippy::too_many_arguments)]
    pub fn step_held(&mut self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, smp: &wgpu::Sampler, now: &Target, dt: f64, kick: f32, d: &MoshDrive) {
        if !self.held || self.a.as_ref().is_none_or(|a| a.w != now.w || a.h != now.h) {
            self.hold(gpu, enc, arena, smp, now);
            self.keys_seen = d.keys;
        }
        let key = d.keys != self.keys_seen;
        self.keys_seen = d.keys;
        let whole = key || self.mud_key;
        self.mud_key = false;
        self.since_start += dt as f32;
        // slower to fade than a change's (held a long while, it would go dark)
        let k = if whole { 1.0 } else { d.heal.clamp(0.0, 0.95) };
        self.run(gpu, enc, arena, smp, now, kick, k, d.strength.clamp(0.0, 2.0), d.grain.clamp(0.0, 1.0), 0.9993);
        self.since_look += dt as f32;
        if self.since_look > 0.35 && self.looks.iter().all(|r| r.state == IDLE) {
            self.since_look = 0.0;
            let look1 = sized_as(gpu, &mut self.look1, 128, 72, wgpu::TextureFormat::Rgba8Unorm, "the mosh's look").view.clone();
            for (i, pic) in [self.a.as_ref().unwrap(), now].into_iter().enumerate() {
                self.fit8.draw(gpu, enc, arena, smp, &look1, &[128.0, 72.0, 0.0, 0.0], &[&pic.view], false);
                let r = &mut self.looks[i];
                let t = sized_as(gpu, &mut r.target, LOOK_W, LOOK_H, wgpu::TextureFormat::Rgba8Unorm, "the mosh's look, small");
                let src = self.look1.as_ref().unwrap();
                self.fit8.draw(gpu, enc, arena, smp, &t.view, &[LOOK_W as f32, LOOK_H as f32, 0.0, 0.0], &[&src.view], false);
                enc.copy_texture_to_buffer(
                    t.texture.as_image_copy(),
                    wgpu::TexelCopyBufferInfo { buffer: &r.buf, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(LOOK_ROW), rows_per_image: Some(LOOK_H) } },
                    wgpu::Extent3d { width: LOOK_W, height: LOOK_H, depth_or_array_layers: 1 },
                );
                r.state = COPIED;
            }
        }
    }

    /// The frame's passes: the motion, the field, the step into `a`.
    #[allow(clippy::too_many_arguments)]
    fn run(&mut self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, smp: &wgpu::Sampler, now: &Target, kick: f32, k: f32, strength: f32, grain: f32, fade: f32) {
        let (w, h) = (now.w, now.h);
        let (qw, qh) = ((w / 4).max(4), (h / 4).max(4));
        sized(gpu, &mut self.prev, w, h, "mosh prev");
        sized(gpu, &mut self.luma_now, qw, qh, "mosh light");
        sized(gpu, &mut self.luma_prev, qw, qh, "mosh light before");
        sized(gpu, &mut self.mv, (qw / 4).max(1), (qh / 4).max(1), "mosh motion");
        let fresh_field = self.field_a.as_ref().is_none_or(|f| f.w != qw || f.h != qh) || !self.have_prev;
        sized(gpu, &mut self.field_a, qw, qh, "mosh field a");
        sized(gpu, &mut self.field_b, qw, qh, "mosh field b");
        if fresh_field {
            clear(enc, &self.field_a.as_ref().unwrap().view, wgpu::Color::BLACK);
        }
        let held = self.held;
        self.luma.draw(gpu, enc, arena, smp, &self.luma_now.as_ref().unwrap().view, &[1.0 / w as f32, 1.0 / h as f32, 0.0, 0.0], &[&now.view], false);
        if self.have_prev {
            let (ln, lp, mv) = (self.luma_now.as_ref().unwrap(), self.luma_prev.as_ref().unwrap(), self.mv.as_ref().unwrap());
            self.matcher.draw(gpu, enc, arena, smp, &mv.view, &[qw as f32, qh as f32, 0.0, 0.0], &[&ln.view, &lp.view], false);
            let fl = [
                qw as f32,
                qh as f32,
                kick * strength,
                // how much of the field is this frame's (held: more of it, and less swirl — on
                // and on, carried motion and swirl melt everything into one soup)
                if held { 0.6 } else { 0.3 },
                if held { self.since_start } else { self.k * self.seconds },
                self.seed,
                if held { 0.2 } else { 0.9 },
                0.0,
            ];
            let (fa, fb) = (self.field_a.as_ref().unwrap(), self.field_b.as_ref().unwrap());
            self.field.draw(gpu, enc, arena, smp, &fb.view, &fl, &[&mv.view, &fa.view, &ln.view, &lp.view], false);
            std::mem::swap(&mut self.field_a, &mut self.field_b);
        }
        let fl = [w as f32, h as f32, k, strength, kick, if self.have_prev { 1.0 } else { 0.0 }, self.seed, grain, fade, 0.0, 0.0, 0.0];
        {
            let (a, b, prev, mv, fa, ln) =
                (self.a.as_ref().unwrap(), self.b.as_ref().unwrap(), self.prev.as_ref().unwrap(), self.mv.as_ref().unwrap(), self.field_a.as_ref().unwrap(), self.luma_now.as_ref().unwrap());
            self.step.draw(gpu, enc, arena, smp, &b.view, &fl, &[&a.view, &now.view, &prev.view, &mv.view, &fa.view, &ln.view], false);
        }
        std::mem::swap(&mut self.a, &mut self.b);
        copy_into(gpu, enc, arena, &self.fit, smp, now, self.prev.as_ref().unwrap());
        std::mem::swap(&mut self.luma_now, &mut self.luma_prev);
        self.have_prev = true;
    }
}

/// Whether the moshed picture (`m`: mean light, its spread, the colour) has gone to mud: flat,
/// all but black or white, or gone grey or dark where the scene drawn now (`s`) is not.
fn muddy(m: (f64, f64, f64), s: (f64, f64, f64)) -> bool {
    let (mean, sd, chroma) = m;
    let (s_mean, _, s_chroma) = s;
    sd < 0.045 || mean < 0.012 || mean > 0.93 || (sd < 0.08 && chroma < 0.05) || (s_chroma > 0.08 && chroma < 0.4 * s_chroma) || (s_mean > 0.05 && mean < 0.3 * s_mean)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mud_is_flat_dark_white_or_grey_against_the_scene() {
        let lively = (0.4, 0.2, 0.3);
        assert!(!muddy(lively, lively));
        assert!(muddy((0.4, 0.02, 0.3), lively), "flat");
        assert!(muddy((0.005, 0.1, 0.3), lively), "black");
        assert!(muddy((0.95, 0.1, 0.3), lively), "white");
        assert!(muddy((0.4, 0.2, 0.05), (0.4, 0.2, 0.3)), "grey where the scene has colour");
        assert!(muddy((0.1, 0.2, 0.3), (0.5, 0.2, 0.3)), "dark where the scene is lit");
    }

    #[test]
    fn the_glyphs_are_ten_side_by_side() {
        let img = image::load_from_memory(GLYPHS_PNG).unwrap();
        assert_eq!((img.width(), img.height()), (24 * GLYPH_COUNT, 40));
    }
}
