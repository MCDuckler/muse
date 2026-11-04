//! Tokens v2 (plans/wetowl-desk-ui-overhaul.md §3.1): a 4 px spacing grid, one radius per
//! kind of thing, elevations as shadows, the type ladder, and the state colours — over the
//! colours of design/tokens.json (wo_deskcore::theme).
use eframe::egui::{Color32, Shadow};
use wo_deskcore::theme;

use crate::paint::{alpha, col};

/// A panel's inset and the gap between panels (space runs on a 4 px grid).
pub const INSET: f32 = 16.0;
pub const GAP: f32 = 12.0;

// radius, one per kind
pub const R_CONTROL: u8 = 6;
pub const R_PAD: u8 = 8;
pub const R_PANEL: u8 = 12;
pub const R_OVERLAY: u8 = 14;

/// Elevation: 1 a panel, 2 a popover, 3 a modal.
pub fn shadow(level: u8) -> Shadow {
    match level {
        0 => Shadow::NONE,
        1 => Shadow { offset: [0, 8], blur: 24, spread: 0, color: Color32::from_black_alpha(70) },
        2 => Shadow { offset: [0, 12], blur: 32, spread: 0, color: Color32::from_black_alpha(100) },
        _ => Shadow { offset: [0, 24], blur: 64, spread: 0, color: Color32::from_black_alpha(140) },
    }
}

// the type ladder: display (mono readouts) → title → section → body → label → hint
pub const DISPLAY_L: f32 = 30.0;
pub const DISPLAY_M: f32 = 22.0;
pub const TITLE: f32 = 17.0;
pub const SECTION: f32 = 12.0;
pub const BODY: f32 = 13.0;
pub const LABEL: f32 = 11.0;
pub const HINT: f32 = 12.0;

// state colours
pub fn text() -> Color32 {
    col(theme::TEXT)
}
pub fn high() -> Color32 {
    col(theme::HIGH)
}
pub fn soft() -> Color32 {
    col(theme::SOFT)
}
pub fn muted() -> Color32 {
    col(theme::MUTED)
}
pub fn label() -> Color32 {
    col(theme::FAINT_ON_GLASS)
}
pub fn faint() -> Color32 {
    col(theme::FAINT)
}
pub fn deck(d: usize) -> Color32 {
    col(theme::DECKS[d.min(1)])
}
pub fn tint(d: usize) -> Color32 {
    col(theme::TINTS[d.min(1)])
}
pub fn ok() -> Color32 {
    col(theme::OK)
}
pub fn warm() -> Color32 {
    col(theme::WARM)
}
pub fn hot() -> Color32 {
    col(theme::HOT)
}
pub fn red() -> Color32 {
    col(theme::RED)
}
/// The focus ring.
pub fn focus() -> Color32 {
    Color32::from_rgb(0x9F, 0xD3, 0xFF)
}

/// The fills a control mixes between: at rest, hovered, pressed (all over the glass).
pub fn fill_rest() -> Color32 {
    Color32::from_white_alpha(12)
}
pub fn fill_hover() -> Color32 {
    Color32::from_white_alpha(22)
}
pub fn fill_press() -> Color32 {
    Color32::from_white_alpha(6)
}
pub fn edge_rest() -> Color32 {
    Color32::from_white_alpha(24)
}
pub fn edge_hover() -> Color32 {
    Color32::from_white_alpha(40)
}

/// What a lit control is lit as: a plain toggle's on is a brighter neutral (green means in
/// step, red live, blue/orange a deck's).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Tone {
    Neutral,
    Deck(usize),
    Ok,
    Warm,
    Danger,
}

impl Tone {
    /// (fill, edge, ink) when lit.
    pub fn lit(self) -> (Color32, Color32, Color32) {
        match self {
            Tone::Neutral => (alpha(theme::CAP, 0.16), alpha(theme::CAP, 0.5), col(theme::HIGH)),
            Tone::Deck(d) => (alpha(theme::DECKS[d.min(1)], 0.16), alpha(theme::DECKS[d.min(1)], 0.62), col(theme::TINTS[d.min(1)])),
            Tone::Ok => (alpha(theme::OK, 0.15), alpha(theme::OK, 0.6), Color32::from_rgb(0xCF, 0xF5, 0xDF)),
            Tone::Warm => (alpha(theme::WARM, 0.15), alpha(theme::WARM, 0.6), Color32::from_rgb(0xFC, 0xEB, 0xC0)),
            Tone::Danger => (alpha(theme::RED, 0.17), alpha(theme::RED, 0.66), Color32::from_rgb(0xFF, 0xD3, 0xCF)),
        }
    }
}

/// `a` to `b` by `t` (sRGB, with alpha).
pub fn mix(a: Color32, b: Color32, t: f32) -> Color32 {
    let t = t.clamp(0.0, 1.0);
    let l = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    let (a, b) = (a.to_srgba_unmultiplied(), b.to_srgba_unmultiplied());
    Color32::from_rgba_unmultiplied(l(a[0], b[0]), l(a[1], b[1]), l(a[2], b[2]), l(a[3], b[3]))
}

/// Contrast (plans/wetowl-desk-ui-overhaul.md §8): every text the kit draws, at 4.5:1 over
/// the brightest the glass gets — a white stage frame, blurred, dimmed and under the scrim —
/// and over the stage picture itself where text sits on a glass tab.
#[cfg(test)]
mod contrast {
    use super::*;

    /// `top` (with its alpha) over the opaque `under`.
    fn over(top: Color32, under: [f32; 3]) -> [f32; 3] {
        let [r, g, b, a] = top.to_srgba_unmultiplied();
        let a = a as f32 / 255.0;
        [r as f32 * a + under[0] * (1.0 - a), g as f32 * a + under[1] * (1.0 - a), b as f32 * a + under[2] * (1.0 - a)]
    }

    fn luminance(c: [f32; 3]) -> f32 {
        let lin = |v: f32| {
            let v = v / 255.0;
            if v <= 0.04045 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
        };
        0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])
    }

    fn ratio(fg: Color32, bg: [f32; 3]) -> f32 {
        let f = luminance(over(fg, bg));
        let b = luminance(bg);
        (f.max(b) + 0.05) / (f.min(b) + 0.05)
    }

    /// The glass at its brightest: what backdrop::glass makes of white, at full light.
    fn brightest_glass() -> [f32; 3] {
        let b = wo_deskcore::backdrop::live(&[255u8; 4 * 64 * 36], 64, 36, 32, 18).unwrap();
        let mut most = [0.0f32; 3];
        for px in b.rgba.chunks(4) {
            let c = [px[0] as f32, px[1] as f32, px[2] as f32];
            if luminance(c) > luminance(most) {
                most = c;
            }
        }
        most
    }

    #[test]
    fn every_text_reads_over_the_brightest_glass() {
        let glass = brightest_glass();
        assert!(luminance(glass) > 0.02, "the glass is lit: {glass:?}");
        let panel = over(col(theme::GLASS_PANEL), glass);
        let dense = over(col(theme::GLASS_DENSE), glass);
        let picture_white = [255.0, 255.0, 255.0];
        let tab = over(Color32::from_rgba_unmultiplied(14, 15, 19, 214), picture_white);
        let row_on = over(Color32::from_white_alpha(18), dense);
        let button = over(fill_rest(), panel);
        let toast = [20.0, 21.0, 27.0];
        let mut fails = vec![];
        let mut check = |what: &str, fg: Color32, bg: [f32; 3]| {
            let r = ratio(fg, bg);
            if r < 4.5 {
                fails.push(format!("{what}: {r:.2}:1"));
            }
        };
        for (where_, bg) in [("panel", panel), ("dense panel", dense)] {
            for (name, c) in [("text", text()), ("soft", soft()), ("muted", muted()), ("label", label()), ("faint", faint()), ("tint A", tint(0)), ("tint B", tint(1)), ("ok", ok()), ("warm", warm()), ("hot", hot())] {
                check(&format!("{name} on the {where_}"), c, bg);
            }
        }
        // on a lit row the faint steps up to the label (the crate's numbers)
        for (name, c) in [("text", text()), ("muted", muted()), ("label", label())] {
            check(&format!("{name} on the crate's cursor row"), c, row_on);
        }
        // over a picture, labels on glass tabs step up to muted
        for (name, c) in [("text", text()), ("soft", soft()), ("muted", muted()), ("warm", warm())] {
            check(&format!("{name} on a glass tab over a white picture"), c, tab);
        }
        check("a button's word", soft(), button);
        for tone in [Tone::Neutral, Tone::Deck(0), Tone::Deck(1), Tone::Ok, Tone::Warm, Tone::Danger] {
            let (fill, _, ink) = tone.lit();
            check(&format!("{tone:?} lit"), ink, over(fill, panel));
        }
        check("a toast", text(), toast);
        assert!(fails.is_empty(), "under 4.5:1 —\n{}", fails.join("\n"));
    }
}
