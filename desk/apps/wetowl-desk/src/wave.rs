//! rekordbox's waveforms, drawn as rekordbox draws them (rekordbox 7's manual and its
//! screenshots: plans/wetowl-desk-rekordbox-look.md §2a), shared by both layouts.
//!
//! A column is a hard-edged bar on a baseline. 3Band lays its three bands over each other
//! from the baseline (the lows blue at the back, the mids amber, the highs near-white in
//! front); RGB is one bar in its colour; BLUE one bar going whiter with the highs. The
//! scrolling lane grows up from a baseline with the phrase band under it (or, as a facing
//! pair, the second deck grows down); the overview grows up from its foot and darkens
//! what has been heard. Over them: rekordbox's grid (grey lines dotted at both ends, red
//! marks on each bar's one), hot cues as lettered squares in their colours, memory cues
//! red ▼, the CUE point an orange ▲, the loop yellow.
use eframe::egui::{Align2, Color32, CornerRadius, FontId, Mesh, Painter, Pos2, Rect, Shape, Stroke, pos2, vec2};
use wo_deskcore::{Lines, PadLook, PhraseKind, RbBin, WaveStyle};

use crate::paint::family;
use crate::tracks::{snap, vline};
use crate::ui::tokens::mix;

const fn rgb(v: u32) -> Color32 {
    Color32::from_rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
}

/// 3Band's colours, sampled off rekordbox 7's own screenshot.
pub(crate) const LOW: Color32 = rgb(0x1F5BE0);
pub(crate) const MID: Color32 = rgb(0xD0912F);
pub(crate) const HIGH: Color32 = rgb(0xF0E6D2);
/// BLUE's ground colour (whiteness takes it toward white).
const BLUE: Color32 = rgb(0x2A78E6);
pub(crate) const LOOP: Color32 = rgb(0xEBBA35);
pub(crate) const MEMORY: Color32 = rgb(0xE0141E);
pub(crate) const CUE_POINT: Color32 = rgb(0xEFA04C);
pub(crate) const BAR_ONE: Color32 = rgb(0xE5202A);
pub(crate) const BEAT_COUNT: Color32 = rgb(0x2E8BE6);

/// rekordbox's hot cue colours by letter ("COLORFUL", as its screenshot shows A–F).
pub(crate) const HOT_CUES: [Color32; 8] = [rgb(0xD83C6E), rgb(0x3C8CD2), rgb(0x78B450), rgb(0x8C5CD2), rgb(0x28A064), rgb(0xD2643C), rgb(0xD2B43C), rgb(0x3CB4C8)];

/// A phrase's colour on rekordbox's phrase band.
pub(crate) fn phrase_colour(k: PhraseKind) -> Color32 {
    match k {
        PhraseKind::Intro => rgb(0xBD4744),
        PhraseKind::Verse => rgb(0x5B6AE0),
        PhraseKind::Bridge => rgb(0xCBC859),
        PhraseKind::Chorus => rgb(0x78B480),
        PhraseKind::Up => rgb(0x9A6AD8),
        PhraseKind::Down => rgb(0x4A55A8),
        PhraseKind::Outro => rgb(0x6E7584),
    }
}

/// A hot cue's colour: rekordbox's own off a stick, else its letter's.
pub(crate) fn hot_cue_colour(i: usize, look: Option<&PadLook>) -> Color32 {
    match look.and_then(|l| l.rgb) {
        Some(v) => rgb(v),
        None => HOT_CUES[i % 8],
    }
}

/// Where a waveform's columns stand.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Anchor {
    /// On a baseline this far down the rect (0..1), growing up.
    Up(f32),
    /// On a baseline this far down, growing down.
    Down(f32),
}

impl Anchor {
    /// The baseline's y and the room the columns have from it.
    fn base(self, r: Rect) -> (f32, f32, f32) {
        match self {
            Anchor::Up(f) => {
                let y = r.top() + r.height() * f;
                (y, y - r.top() - 1.0, -1.0)
            }
            Anchor::Down(f) => {
                let y = r.top() + r.height() * f;
                (y, r.bottom() - y - 1.0, 1.0)
            }
        }
    }

    /// The side of the rect away from the columns (where the phrase band goes): its rect.
    pub(crate) fn under(self, r: Rect) -> Rect {
        let (y, _, dir) = self.base(r);
        if dir < 0.0 { Rect::from_min_max(pos2(r.left(), y), r.max) } else { Rect::from_min_max(r.min, pos2(r.right(), y)) }
    }

    pub(crate) fn grows_down(self) -> bool {
        matches!(self, Anchor::Down(_))
    }
}

fn quad(m: &mut Mesh, x0: f32, x1: f32, y0: f32, y1: f32, c: Color32) {
    let (ya, yb) = if y0 < y1 { (y0, y1) } else { (y1, y0) };
    if yb - ya < 0.01 || x1 <= x0 {
        return;
    }
    let i = m.vertices.len() as u32;
    m.colored_vertex(pos2(x0, ya), c);
    m.colored_vertex(pos2(x1, ya), c);
    m.colored_vertex(pos2(x1, yb), c);
    m.colored_vertex(pos2(x0, yb), c);
    m.add_triangle(i, i + 1, i + 2);
    m.add_triangle(i, i + 2, i + 3);
}

/// RGB's colour of a bin: rekordbox's three 3-bit values as they are, lifted a little
/// (its own are drawn bright on black).
fn rgb_colour(b: &RbBin) -> Color32 {
    let c = b.rgb.map(|v| v.clamp(0.0, 1.0).powf(0.75));
    Color32::from_rgb((c[0] * 255.0) as u8, (c[1] * 255.0) as u8, (c[2] * 255.0) as u8)
}

fn darken(c: Color32, k: f32) -> Color32 {
    if k <= 0.0 {
        return c;
    }
    let l = (c.r() as f32 * 0.3 + c.g() as f32 * 0.55 + c.b() as f32 * 0.15) as u8;
    mix(c, Color32::from_rgb(l / 3, l / 3, l / 3 + 4), k * 0.72)
}

/// How a picture of columns is drawn.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Columns {
    pub style: WaveStyle,
    pub anchor: Anchor,
    /// The heights scaled (an overview of means reads low: rekordbox's previews are drawn
    /// taller than their means).
    pub gain: f32,
    /// A dimmer copy mirrored past the baseline (over the phrase band), this tall.
    pub reflect: f32,
    /// What has been heard darkened, left of this x (over `edge` px).
    pub heard: Option<(f32, f32)>,
}

/// `bins` across `r` from `x0`, `bin_w` apart, as one mesh.
pub(crate) fn columns(p: &Painter, r: Rect, bins: &[Option<RbBin>], x0: f32, bin_w: f32, c: Columns) {
    let (base, room, dir) = c.anchor.base(r);
    let mut m = Mesh::default();
    let mut refl = Mesh::default();
    for (i, b) in bins.iter().enumerate() {
        let Some(b) = b else { continue };
        let xa = x0 + i as f32 * bin_w;
        let xb = xa + bin_w;
        if xb < r.left() || xa > r.right() {
            continue;
        }
        let (xa, xb) = (xa.max(r.left()), xb.min(r.right()));
        let dim = c.heard.map_or(0.0, |(at, edge)| ((at - (xa + xb) / 2.0) / edge).clamp(0.0, 1.0));
        let h = |v: f32| (v * c.gain).clamp(0.0, 1.0) * room;
        let put = |m: &mut Mesh, v: f32, col: Color32, k: f32, d: f32| quad(m, xa, xb, base, base + d * h(v) * k, darken(col, dim));
        match c.style {
            WaveStyle::ThreeBand | WaveStyle::WetOwl => {
                for (v, col) in [(b.bands[0], LOW), (b.bands[1], MID), (b.bands[2], HIGH)] {
                    put(&mut m, v, col, 1.0, dir);
                    if c.reflect > 0.0 {
                        put(&mut refl, v, col, c.reflect, -dir);
                    }
                }
            }
            WaveStyle::Rgb => {
                put(&mut m, b.height, rgb_colour(b), 1.0, dir);
                if c.reflect > 0.0 {
                    put(&mut refl, b.height, rgb_colour(b), c.reflect, -dir);
                }
            }
            WaveStyle::Blue => {
                let col = mix(BLUE, Color32::WHITE, (b.white * 0.95).min(1.0));
                put(&mut m, b.blue, col, 1.0, dir);
                if c.reflect > 0.0 {
                    put(&mut refl, b.blue, col, c.reflect, -dir);
                }
            }
        }
    }
    if c.reflect > 0.0 && !refl.vertices.is_empty() {
        for v in &mut refl.vertices {
            v.color = v.color.gamma_multiply(0.42);
        }
        p.add(Shape::mesh(refl));
    }
    p.add(Shape::mesh(m));
}

/// rekordbox's grid over a lane: every beat a grey line dotted at both ends, each bar's one
/// red-marked at both ends; with `groups`, the WetOwl's two- and four-bar marks (numbered)
/// over it.
pub(crate) fn grid(p: &Painter, r: Rect, l: &Lines, ppp: f32, groups: bool) {
    let x = |lx: f32| r.left() + lx;
    let dot = |bx: f32, c: Color32| {
        let bx = snap(bx, ppp);
        p.rect_filled(Rect::from_center_size(pos2(bx, r.top() + 2.0), vec2(3.0, 3.0)), CornerRadius::same(1), c);
        p.rect_filled(Rect::from_center_size(pos2(bx, r.bottom() - 2.0), vec2(3.0, 3.0)), CornerRadius::same(1), c);
    };
    let thin = (l.beats.len() + l.bars.len() + l.twos.len() + l.fours.len()) as f32 > r.width() / 7.0;
    if !thin {
        for &bx in &l.beats {
            vline(p, x(bx), r.top(), r.bottom(), 1.0, ppp, Color32::from_white_alpha(26));
            dot(x(bx), Color32::from_white_alpha(120));
        }
    }
    let bar = |bx: f32| {
        vline(p, x(bx), r.top(), r.bottom(), 1.0, ppp, Color32::from_white_alpha(46));
        vline(p, x(bx), r.top(), r.top() + 6.0, 2.0, ppp, BAR_ONE);
        vline(p, x(bx), r.bottom() - 6.0, r.bottom(), 2.0, ppp, BAR_ONE);
    };
    for &bx in l.bars.iter().chain(&l.twos).chain(l.fours.iter().map(|f| &f.0)) {
        bar(bx);
    }
    if groups {
        let caps = |bx: f32, len: f32, c: Color32| {
            vline(p, bx, r.top() + 7.0, r.top() + 7.0 + len, 3.0, ppp, c);
            vline(p, bx, r.bottom() - 7.0 - len, r.bottom() - 7.0, 3.0, ppp, c);
        };
        for &bx in &l.twos {
            caps(x(bx), 4.0, Color32::from_white_alpha(90));
        }
        for &(bx, n) in &l.fours {
            caps(x(bx), 7.0, Color32::from_white_alpha(170));
            p.text(pos2(snap(x(bx), ppp) + 5.0, r.bottom() - 9.0), Align2::LEFT_BOTTOM, n.to_string(), FontId::new(9.5, family("mono")), Color32::from_white_alpha(110));
        }
    }
}

/// A hot cue's flag: a small square in its colour with its letter (or number), at the edge
/// the columns grow toward, and its line across the lane; `name` beside it on a tab.
pub(crate) fn hot_cue(p: &Painter, r: Rect, x: f32, tag: &str, name: Option<&str>, c: Color32, down: bool, ppp: f32, k: f32) {
    let x = snap(x, ppp);
    vline(p, x, r.top(), r.bottom(), 1.0, ppp, c.gamma_multiply(0.85 * k));
    let y = if down { r.bottom() - 15.0 } else { r.top() + 1.0 };
    let sq = Rect::from_min_size(pos2(x, y), vec2(14.0, 14.0));
    p.rect_filled(sq, CornerRadius::same(2), c.gamma_multiply(k));
    p.text(sq.center(), Align2::CENTER_CENTER, tag, FontId::new(10.0, family("semi")), Color32::WHITE.gamma_multiply(k));
    if let Some(n) = name.filter(|n| !n.is_empty()) {
        let g = p.layout_no_wrap(n.to_owned(), FontId::new(10.0, family("semi")), Color32::WHITE);
        let tab = Rect::from_min_size(pos2(sq.right(), sq.top()), vec2(g.size().x + 8.0, 14.0));
        p.rect_filled(tab, CornerRadius { nw: 0, ne: 2, sw: 0, se: 2 }, Color32::from_black_alpha((170.0 * k) as u8));
        p.galley(pos2(tab.left() + 4.0, tab.center().y - g.size().y / 2.0), g, Color32::WHITE.gamma_multiply(k));
    }
}

/// A memory cue: a red ▼ at the edge and a red line.
pub(crate) fn memory_cue(p: &Painter, r: Rect, x: f32, down: bool, ppp: f32) {
    let x = snap(x, ppp);
    vline(p, x, r.top(), r.bottom(), 1.0, ppp, MEMORY.gamma_multiply(0.9));
    let tri = if down { vec![pos2(x - 5.0, r.bottom()), pos2(x + 5.0, r.bottom()), pos2(x, r.bottom() - 7.0)] } else { vec![pos2(x - 5.0, r.top()), pos2(x + 5.0, r.top()), pos2(x, r.top() + 7.0)] };
    p.add(Shape::convex_polygon(tri, MEMORY, Stroke::NONE));
}

/// The CUE point: an orange ▲ on the edge the columns stand on.
pub(crate) fn cue_point(p: &Painter, r: Rect, x: f32, down: bool, ppp: f32) {
    let x = snap(x, ppp);
    let tri = if down { vec![pos2(x - 6.0, r.top()), pos2(x + 6.0, r.top()), pos2(x, r.top() + 8.0)] } else { vec![pos2(x - 6.0, r.bottom()), pos2(x, r.bottom() - 8.0), pos2(x + 6.0, r.bottom())] };
    p.add(Shape::convex_polygon(tri, CUE_POINT, Stroke::NONE));
}

/// A loop: rekordbox's yellow over it, its ends marked.
pub(crate) fn loop_band(p: &Painter, r: Rect, xa: f32, xb: f32, k: f32, ppp: f32) {
    let (xa, xb) = (snap(xa, ppp), snap(xb, ppp));
    p.rect_filled(Rect::from_min_max(pos2(xa, r.top()), pos2(xb, r.bottom())), CornerRadius::ZERO, LOOP.gamma_multiply(0.30 * k));
    for bx in [xa, xb] {
        vline(p, bx, r.top(), r.bottom(), 2.0, ppp, LOOP.gamma_multiply(0.95 * k));
    }
}

/// The phrase band: each phrase its colour, its word at its start where it fits.
pub(crate) fn phrase_band(p: &Painter, band: Rect, phrases: &[(f32, f32, wo_deskcore::Phrase)], alpha: f32, words: bool) {
    let clip = p.with_clip_rect(band.intersect(p.clip_rect()));
    for (xa, xb, ph) in phrases {
        let (xa, xb) = (xa.max(band.left()), xb.min(band.right()));
        if xb - xa < 1.0 {
            continue;
        }
        let c = phrase_colour(ph.kind);
        clip.rect_filled(Rect::from_min_max(pos2(xa + 0.5, band.top()), pos2(xb - 0.5, band.bottom())), CornerRadius::ZERO, c.gamma_multiply(alpha));
        if words && band.height() >= 10.0 && xb - xa > 34.0 {
            let size = (band.height() * 0.62).clamp(8.0, 11.0);
            clip.text(pos2(xa + 4.0, band.center().y), Align2::LEFT_CENTER, ph.label.to_uppercase(), FontId::new(size, family("semi")), Color32::from_black_alpha(200));
        }
    }
}

/// The playhead the rekordbox way: a thin white line.
pub(crate) fn playhead(p: &Painter, x: f32, top: f32, bottom: f32, ppp: f32) {
    vline(p, x, top, bottom, 2.0, ppp, Color32::WHITE);
}

/// rekordbox's beat count over the playhead: "63.2Bars".
pub(crate) fn beat_count(p: &Painter, at: Pos2, bar: i64, beat: usize) {
    let words = format!("{bar}.{beat}Bars");
    let f = FontId::new(13.0, family("semi"));
    p.text(at + vec2(1.0, 1.0), Align2::CENTER_TOP, &words, f.clone(), Color32::from_black_alpha(200));
    p.text(at, Align2::CENTER_TOP, &words, f, BEAT_COUNT);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anchors_put_the_band_on_the_far_side() {
        let r = Rect::from_min_size(pos2(0.0, 0.0), vec2(100.0, 100.0));
        let up = Anchor::Up(0.6);
        let near = |a: Rect, b: Rect| (a.min - b.min).length() + (a.max - b.max).length() < 1e-3;
        assert!(near(up.under(r), Rect::from_min_max(pos2(0.0, 60.0), pos2(100.0, 100.0))));
        let down = Anchor::Down(0.2);
        assert!(near(down.under(r), Rect::from_min_max(pos2(0.0, 0.0), pos2(100.0, 20.0))));
    }

    #[test]
    fn rgb_keeps_its_hue() {
        let b = RbBin { rgb: [0.7, 0.1, 0.0], ..Default::default() };
        let c = rgb_colour(&b);
        assert!(c.r() > 180 && c.g() < 60 && c.b() == 0, "{c:?}");
    }
}
