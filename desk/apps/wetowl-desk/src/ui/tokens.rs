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
