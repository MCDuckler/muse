//! The footage's pass: the clip's frame (and the last clip's, under a dissolve) fitted to the
//! stage — filled, whole, or whole over a blurred copy of itself — its light, contrast and
//! colour as the hands set them, tinted with the record's palette where it has little colour
//! of its own, pushed by the kick, and weaving and flickering like old film.
//!
//! Two pictures, one per clip: a new clip goes into the other one, so the last clip's last
//! frame is still there to dissolve from.
use crate::stage::{Own, WORK};
use crate::{Arena, Gpu, wgpu};

pub(crate) const VIDEO: &str = "
struct U {
    res: vec2<f32>, time: f32, kick: f32,
    aspect_a: f32, aspect_b: f32, k: f32, fit: f32,
    tint: f32, dim: f32, contrast: f32, sat: f32,
    punch: f32, film: f32, mirror: f32, pad: f32,
    ink: vec4<f32>, mid: vec4<f32>, paper: vec4<f32>,
};
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var ta: texture_2d<f32>;
@group(0) @binding(2) var sa: sampler;
@group(0) @binding(3) var tb: texture_2d<f32>;
@group(0) @binding(4) var sb: sampler;

fn hash1(x: f32) -> f32 { return fract(sin(x * 91.3458) * 47453.5453); }

// the stage's uv in a picture of aspect `a`: covering the stage (cover) or inside it
fn place(uv: vec2<f32>, a: f32, cover: bool) -> vec2<f32> {
    let stage = u.res.x / u.res.y;
    var s: vec2<f32>;
    if (cover) {
        s = select(vec2<f32>(stage / a, 1.0), vec2<f32>(1.0, a / stage), stage > a);
    } else {
        s = select(vec2<f32>(1.0, a / stage), vec2<f32>(stage / a, 1.0), stage > a);
    }
    return (uv - 0.5) * s + 0.5;
}

fn inside(p: vec2<f32>) -> bool {
    return all(p >= vec2<f32>(0.0)) && all(p <= vec2<f32>(1.0));
}

fn tap(which: i32, p: vec2<f32>) -> vec3<f32> {
    let q = clamp(p, vec2<f32>(0.0), vec2<f32>(1.0));
    if (which == 0) { return textureSampleLevel(ta, sa, q, 0.0).rgb; }
    return textureSampleLevel(tb, sb, q, 0.0).rgb;
}

// a soft copy: twelve taps on two rings
fn blurred(which: i32, p: vec2<f32>) -> vec3<f32> {
    var c = tap(which, p) * 0.2;
    for (var i = 0; i < 12; i = i + 1) {
        let ang = f32(i) * 0.5236 + 0.3;
        let r = select(0.018, 0.04, i % 2 == 1);
        c = c + tap(which, p + vec2<f32>(cos(ang), sin(ang)) * r) * (0.8 / 12.0);
    }
    return c;
}

fn picture(which: i32, uv: vec2<f32>, a: f32) -> vec3<f32> {
    if (u.fit < 0.5) {
        return tap(which, place(uv, a, true));
    }
    let p = place(uv, a, false);
    if (inside(p)) {
        return tap(which, p);
    }
    if (u.fit < 1.5) {
        return vec3<f32>(0.0);
    }
    // whole, over itself filled, blurred and darker
    let q = (place(uv, a, true) - 0.5) * 0.92 + 0.5;
    let b = blurred(which, q);
    let l = dot(b, vec3<f32>(0.2126, 0.7152, 0.0722));
    return mix(vec3<f32>(l), b, 0.6) * 0.6;
}

@fragment fn fs(v: VOut) -> @location(0) vec4<f32> {
    var uv = v.uv;
    if (u.mirror > 0.5) {
        uv.x = 0.5 - abs(uv.x - 0.5);
    }
    // the kick's push: a little nearer
    let push = u.punch * u.kick;
    uv = (uv - 0.5) * (1.0 - 0.035 * push) + 0.5;
    // old film: the frame weaving in the gate, flickering
    let tick = floor(u.time * 18.0);
    uv = uv + vec2<f32>(hash1(tick) - 0.5, hash1(tick + 17.0) - 0.5) * vec2<f32>(0.0025, 0.004) * u.film;
    var c = picture(0, uv, u.aspect_a);
    if (u.k < 1.0) {
        c = mix(picture(1, uv, u.aspect_b), c, u.k);
    }
    c = max((c - 0.45) * u.contrast + 0.45, vec3<f32>(0.0));
    let l = dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
    c = max(mix(vec3<f32>(l), c, u.sat), vec3<f32>(0.0));
    if (u.tint > 0.5 && u.tint < 1.5) {
        // the record's colours by light: deep, the middle's, pale
        let t = smoothstep(0.02, 0.95, l);
        let lo = mix(u.ink.rgb, u.mid.rgb, smoothstep(0.0, 0.5, t));
        c = mix(lo, u.paper.rgb, smoothstep(0.45, 1.0, t)) + vec3<f32>(pow(t, 8.0) * 0.2);
    } else if (u.tint > 1.5 && u.tint < 2.5) {
        c = vec3<f32>(l);
    } else if (u.tint > 2.5) {
        c = vec3<f32>(l) * vec3<f32>(1.08, 0.9, 0.68);
    }
    let flicker = 1.0 + u.film * 0.07 * (hash1(tick + 5.0) - 0.5);
    c = c * u.dim * flicker * (1.0 + 0.3 * push);
    return vec4<f32>(c, 1.0);
}
";

/// How the footage is drawn this frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VideoLook {
    /// The pictures' aspects (the clip on, the last clip).
    pub aspect: [f32; 2],
    /// The clip on over the last, 0..1.
    pub k: f32,
    /// 0 fill, 1 fit, 2 fit over itself blurred.
    pub fit: u32,
    /// 0 as it is, 1 the palette's two colours, 2 grey, 3 sepia.
    pub tint: u32,
    pub dim: f32,
    pub contrast: f32,
    pub saturation: f32,
    pub punch: f32,
    pub film: f32,
    pub mirror: bool,
    /// The palette's dark, middle and light for the tint.
    pub ink: [f32; 3],
    pub mid: [f32; 3],
    pub paper: [f32; 3],
}

impl Default for VideoLook {
    fn default() -> Self {
        VideoLook { aspect: [16.0 / 9.0; 2], k: 1.0, fit: 0, tint: 0, dim: 1.0, contrast: 1.0, saturation: 1.0, punch: 0.0, film: 0.0, mirror: false, ink: [0.02; 3], mid: [0.4; 3], paper: [0.95; 3] }
    }
}

/// The palette (primary, secondary, accent) as the duotone's three: the primary deep, the
/// secondary in the middle, the accent pale.
pub fn tones(palette: &[[f32; 3]; 3]) -> [[f32; 3]; 3] {
    [palette[0].map(|c| c * 0.22), palette[1].map(|c| c * 0.75), [0, 1, 2].map(|i| palette[2][i] * 0.7 + 0.3)]
}

/// What the stage draws of the footage: which picture is the clip on, and how.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VideoDraw {
    pub slot: usize,
    pub look: VideoLook,
    /// It is the scene (drawn as the figure), not only the ground.
    pub figure: bool,
}

/// The two pictures and the pass.
pub(crate) struct Video {
    pass: Own,
    slots: [Option<(wgpu::Texture, wgpu::TextureView)>; 2],
}

impl Video {
    pub(crate) fn new(gpu: &Gpu) -> Video {
        Video { pass: Own::new(gpu, "video", VIDEO, 2, WORK, None), slots: [None, None] }
    }

    /// A frame (RGBA, `w`×`h`) into picture `slot`.
    pub(crate) fn frame(&mut self, gpu: &Gpu, slot: usize, w: u32, h: u32, rgba: &[u8]) {
        let s = &mut self.slots[slot.min(1)];
        if s.as_ref().is_none_or(|(t, _)| t.width() != w || t.height() != h) {
            let t = crate::upload(gpu, w, h, rgba);
            let v = t.create_view(&Default::default());
            *s = Some((t, v));
            return;
        }
        let (t, _) = s.as_ref().unwrap();
        gpu.queue.write_texture(
            wgpu::TexelCopyTextureInfo { texture: t, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            rgba,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4 * w), rows_per_image: Some(h) },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        );
    }

    pub(crate) fn has(&self, slot: usize) -> bool {
        self.slots[slot.min(1)].is_some()
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn draw(&self, gpu: &Gpu, enc: &mut wgpu::CommandEncoder, arena: &mut Arena, smp: &wgpu::Sampler, target: &wgpu::TextureView, black: &wgpu::TextureView, d: &VideoDraw, w: f32, h: f32, time: f32, kick: f32) {
        let a = self.slots[d.slot.min(1)].as_ref().map_or(black, |s| &s.1);
        let b = self.slots[1 - d.slot.min(1)].as_ref().map_or(black, |s| &s.1);
        let l = &d.look;
        // without the last clip's picture, no dissolve from it
        let k = if self.slots[1 - d.slot.min(1)].is_some() { l.k } else { 1.0 };
        let f = [
            w,
            h,
            time,
            kick,
            l.aspect[0],
            l.aspect[1],
            k,
            l.fit as f32,
            l.tint as f32,
            l.dim,
            l.contrast,
            l.saturation,
            l.punch,
            l.film,
            if l.mirror { 1.0 } else { 0.0 },
            0.0,
            l.ink[0],
            l.ink[1],
            l.ink[2],
            1.0,
            l.mid[0],
            l.mid[1],
            l.mid[2],
            1.0,
            l.paper[0],
            l.paper[1],
            l.paper[2],
            1.0,
        ];
        self.pass.draw(gpu, enc, arena, smp, target, &f, &[a, b], false);
    }
}
