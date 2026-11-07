//! The pictures a scene's page shows its looks by (v1: show_room_stills.dart): the figures'
//! baked stills (app/assets/show/stills) blended with a background's picture the stage's own
//! way — shaders/show/under.frag, here on the CPU, small — and kept as textures until the
//! page is left. MilkDrop's and the wash's are stand-ins (v1's), the rest their thumbnails.
use std::collections::HashMap;

use eframe::egui::{self, ColorImage, TextureHandle, TextureOptions};

macro_rules! assets {
    ($($name:literal => $path:literal),* $(,)?) => {
        /// The baked pictures, by name.
        fn asset(name: &str) -> Option<&'static [u8]> {
            match name {
                $($name => Some(include_bytes!(concat!("../../../../app/assets/show/", $path))),)*
                _ => None,
            }
        }
    };
}

assets! {
    "dancers.plain" => "stills/dancers.plain.png",
    "dancers.mono" => "stills/dancers.mono.png",
    "dancers.trails" => "stills/dancers.trails.png",
    "dancers.ascii" => "stills/dancers.ascii.png",
    "dancers.dither" => "stills/dancers.dither.png",
    "dancers.chrono" => "stills/dancers.chrono.png",
    "dancers.contour" => "stills/dancers.contour.png",
    "dancers.halftone" => "stills/dancers.halftone.png",
    "dancers.thermal" => "stills/dancers.thermal.png",
    "dancers.lines" => "stills/dancers.lines.png",
    "dancers.disco" => "stills/dancers.disco.png",
    "dancers.crt" => "stills/dancers.crt.png",
    "dancers.slit" => "stills/dancers.slit.png",
    "dancers.dust" => "stills/dancers.dust.png",
    "kinetic" => "stills/kinetic.png",
    "flash" => "stills/flash.png",
    "blocks" => "stills/blocks.png",
    "glide" => "stills/glide.png",
    "field" => "stills/field.png",
    "none" => "thumbs/milk.webp",
    "ground.pulse.grid" => "thumbs/pulse-grid.webp",
    "ground.pulse.rays" => "thumbs/pulse-rays.webp",
    "ground.pulse.smoke" => "thumbs/pulse-smoke.webp",
    "ground.pulse.stars" => "thumbs/pulse-stars.webp",
    "ground.field.drift" => "thumbs/drift.webp",
}

const BALL: &[u8] = include_bytes!("../../../bakeoff/ball.png");

/// A picture, RGBA, straight alpha.
#[derive(Clone)]
struct Pic {
    w: usize,
    h: usize,
    px: Vec<[f32; 4]>,
}

impl Pic {
    fn decode(bytes: &[u8]) -> Option<Pic> {
        let img = image::load_from_memory(bytes).ok()?.to_rgba8();
        let (w, h) = (img.width() as usize, img.height() as usize);
        Some(Pic { w, h, px: img.pixels().map(|p| [p[0] as f32 / 255.0, p[1] as f32 / 255.0, p[2] as f32 / 255.0, p[3] as f32 / 255.0]).collect() })
    }

    fn at(&self, u: f32, v: f32) -> [f32; 4] {
        let x = ((u * self.w as f32) as usize).min(self.w - 1);
        let y = ((v * self.h as f32) as usize).min(self.h - 1);
        self.px[y * self.w + x]
    }

    fn painted(w: usize, h: usize, f: impl Fn(f32, f32) -> [f32; 3]) -> Pic {
        let mut px = Vec::with_capacity(w * h);
        for y in 0..h {
            for x in 0..w {
                let c = f((x as f32 + 0.5) / w as f32, (y as f32 + 0.5) / h as f32);
                px.push([c[0], c[1], c[2], 1.0]);
            }
        }
        Pic { w, h, px }
    }
}

/// MilkDrop's picture while it is not running (v1: _milkStandIn): busy, saturated colour on
/// dark, a preset's rings.
fn milk_stand_in() -> Pic {
    let blobs: [(f32, f32, f32, [f32; 3]); 5] = [
        (30.0, 25.0, 55.0, [0.88, 0.13, 0.48]),
        (120.0, 30.0, 50.0, [0.13, 0.75, 0.88]),
        (80.0, 70.0, 45.0, [0.94, 0.63, 0.13]),
        (140.0, 80.0, 35.0, [0.44, 0.19, 0.94]),
        (15.0, 80.0, 30.0, [0.19, 0.88, 0.44]),
    ];
    Pic::painted(160, 90, |u, v| {
        let (x, y) = (u * 160.0, v * 90.0);
        let mut c = [0.04, 0.024, 0.125];
        for (bx, by, r, col) in blobs {
            let d = ((x - bx).powi(2) + (y - by).powi(2)).sqrt();
            let a = (1.0 - d / r).max(0.0) * 0.85;
            for i in 0..3 {
                c[i] += col[i] * a;
            }
        }
        let d = ((x - 80.0).powi(2) + (y - 45.0).powi(2)).sqrt();
        let ring = (1..=5).any(|i| (d - i as f32 * 11.0).abs() < 0.75);
        if ring {
            for v in &mut c {
                *v = *v * 0.67 + 0.33;
            }
        }
        c.map(|v| v.min(1.0))
    })
}

/// The wash: the house palette's two colours, dark, top to bottom (v1: _washFor).
fn wash() -> Pic {
    let (a, b) = ([0.55, 0.22, 0.95], [0.95, 0.55, 0.2]);
    Pic::painted(64, 36, |_, v| std::array::from_fn(|i| a[i] * 56.0 / 255.0 * (1.0 - v) + b[i] * 31.0 / 255.0 * v))
}

/// Which pixels of a figure's still are the figure (under.frag's uCoverage): the plain and
/// the mono dancers' marked bodies (0), the light for the rest (2).
fn coverage(figure: &str, style: &str) -> u8 {
    if figure == "dancers" && (style == "plain" || style == "mono") { 0 } else { 2 }
}

fn lum(c: [f32; 4]) -> f32 {
    c[0] * 0.299 + c[1] * 0.587 + c[2] * 0.114
}

fn smoothstep(a: f32, b: f32, x: f32) -> f32 {
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// under.frag, at `w`×`h`: the figure with the ground under it, `mask` (0 none, 1 keyhole, 2
/// inverted), `mix` (0 normal, 1 add, 2 screen, 3 contrast), `how` the coverage, the ground
/// dimmed by `dim` and filled to the picture (cropped).
#[allow(clippy::too_many_arguments)]
fn under(fig: &Pic, ground: Option<&Pic>, mask: u8, mix: u8, how: u8, strength: f32, dim: f32, w: usize, h: usize) -> ColorImage {
    let mut out = Vec::with_capacity(w * h * 4);
    let stage = w as f32 / h as f32;
    let fit = ground.map(|g| {
        let pic = g.w as f32 / g.h as f32;
        if stage > pic { (1.0, pic / stage) } else { (stage / pic, 1.0) }
    });
    for y in 0..h {
        for x in 0..w {
            let (u, v) = ((x as f32 + 0.5) / w as f32, (y as f32 + 0.5) / h as f32);
            let sa = fig.at(u, v);
            let s = [sa[0], sa[1], sa[2]];
            let (cov, f) = if how == 2 {
                (smoothstep(0.02, 0.3, lum(sa)), s)
            } else {
                let cov = if sa[3] >= 0.98 && sa[3] <= 0.9985 { 1.0 } else { 0.0 };
                (cov, s.map(|c| c * cov))
            };
            let m = match (ground, fit) {
                (Some(g), Some((fx, fy))) => {
                    let gc = g.at(((u - 0.5) * fx + 0.5).clamp(0.0, 1.0), ((v - 0.5) * fy + 0.5).clamp(0.0, 1.0));
                    [gc[0] * dim, gc[1] * dim, gc[2] * dim]
                }
                _ => [0.0; 3],
            };
            let g = match mask {
                1 => m.map(|c| c * cov),
                2 => m.map(|c| c * (1.0 - cov)),
                _ => m,
            };
            let col: [f32; 3] = std::array::from_fn(|i| match mix {
                1 => g[i] + f[i],
                2 => 1.0 - (1.0 - g[i]) * (1.0 - f[i].clamp(0.0, 1.0)),
                3 => (f[i].clamp(0.0, 1.0) - g[i]).abs() * 1.2,
                _ if mask == 0 => m[i] * (1.0 - cov) + f[i],
                _ => g[i],
            });
            for i in 0..3 {
                let c = s[i] + (col[i] - s[i]) * strength;
                out.push((c.clamp(0.0, 1.0) * 255.0) as u8);
            }
            out.push(255);
        }
    }
    ColorImage::from_rgba_unmultiplied([w, h], &out)
}

/// A look's picture, by what it is drawn of.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct StillKey {
    pub figure: String,
    pub style: String,
    pub ground: String,
    pub mask: String,
    pub mix: String,
    /// The blend's strength, in hundredths.
    pub strength: u8,
}

#[derive(Default)]
pub(crate) struct Stills {
    pics: HashMap<String, Option<Pic>>,
    made: HashMap<StillKey, Option<TextureHandle>>,
    /// Until when this frame may make more (a few milliseconds' worth: the page stays smooth).
    until: Option<std::time::Instant>,
}

impl Stills {
    fn pic(&mut self, name: &str) -> Option<&Pic> {
        if !self.pics.contains_key(name) {
            let p = match name {
                "ground.white" => Some(Pic::painted(16, 9, |_, _| [1.0; 3])),
                "ground.wash" => Some(wash()),
                "ground.milk" => Some(milk_stand_in()),
                "ground.cover" => Pic::decode(BALL),
                _ => asset(name).and_then(Pic::decode),
            };
            self.pics.insert(name.to_owned(), p);
        }
        self.pics.get(name).and_then(Option::as_ref)
    }

    /// A new frame: a few more may be made.
    pub(crate) fn frame(&mut self) {
        self.until = Some(std::time::Instant::now() + std::time::Duration::from_millis(4));
    }

    /// Whether the figure has a still in this style (the dancers' viewports draw on the stage
    /// only).
    pub(crate) fn has(figure: &str, style: &str) -> bool {
        asset(&Self::figure_name(figure, style)).is_some()
    }

    fn figure_name(figure: &str, style: &str) -> String {
        if figure == "dancers" { format!("dancers.{style}") } else { figure.to_owned() }
    }

    /// The look's picture: made now (a few a frame) or kept; None while it waits, or where
    /// there is no still.
    pub(crate) fn get(&mut self, ctx: &egui::Context, k: &StillKey) -> Option<TextureHandle> {
        if let Some(t) = self.made.get(k) {
            return t.clone();
        }
        if self.until.is_none_or(|u| std::time::Instant::now() > u) {
            ctx.request_repaint();
            return None;
        }
        let fig_name = Self::figure_name(&k.figure, &k.style);
        let ground_name = format!("ground.{}", k.ground);
        let ground = if matches!(k.ground.as_str(), "black" | "own") { None } else { self.pic(&ground_name).cloned() };
        let tex = self.pic(&fig_name).cloned().map(|fig| {
            let dim = match k.ground.as_str() {
                "field.drift" => 0.6,
                "cover" => 0.6,
                _ => 1.0,
            };
            let mask = match k.mask.as_str() {
                "keyhole" => 1,
                "inverted" => 2,
                _ => 0,
            };
            let mix = match k.mix.as_str() {
                "add" => 1,
                "screen" => 2,
                "contrast" => 3,
                _ => 0,
            };
            let plain = mask == 0 && mix == 0;
            let img = if ground.is_none() && plain {
                under(&fig, None, 0, 0, coverage(&k.figure, &k.style), 0.0, 0.0, 192, 108)
            } else {
                under(&fig, ground.as_ref(), mask, mix, coverage(&k.figure, &k.style), k.strength as f32 / 100.0, dim, 192, 108)
            };
            ctx.load_texture(format!("still {k:?}"), img, TextureOptions::LINEAR)
        });
        self.made.insert(k.clone(), tex.clone());
        tex
    }

    /// The page left: the pictures let go.
    pub(crate) fn clear(&mut self) {
        self.made.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_still_decodes_and_blends() {
        let mut s = Stills::default();
        for n in ["dancers.plain", "dancers.ascii", "kinetic", "field", "none", "ground.pulse.grid", "ground.field.drift", "ground.cover", "ground.milk", "ground.wash"] {
            assert!(s.pic(n).is_some(), "{n}");
        }
        assert!(Stills::has("dancers", "trails") && !Stills::has("dancers", "viewports"));
        let fig = s.pic("kinetic").unwrap().clone();
        let white = s.pic("ground.white").unwrap().clone();
        // contrast on white: where the figure is dark, near white; keyhole on white: black round it
        let img = under(&fig, Some(&white), 1, 0, 2, 1.0, 1.0, 64, 36);
        let dark = img.pixels.iter().filter(|p| p.r() < 10 && p.g() < 10 && p.b() < 10).count();
        assert!(dark > 64 * 36 / 4, "the keyhole: black where no figure is ({dark})");
        let img = under(&fig, Some(&white), 0, 0, 2, 1.0, 1.0, 64, 36);
        let light = img.pixels.iter().filter(|p| p.r() > 200).count();
        assert!(light > 64 * 36 / 4, "no mask: the white shows round the figure ({light})");
    }
}
