//! The tokens as egui colours and fonts, labels, and the words for a
//! record's times and pads (the controls themselves: ui::kit).
use std::sync::Arc;

use eframe::egui::{self, Align2, Color32, FontFamily, FontId, Painter, Pos2, Rect, TextFormat, text::LayoutJob};
use wo_deskcore::PadKind;
use wo_deskcore::theme::{self, Rgba};

pub(crate) fn col(v: Rgba) -> Color32 {
    Color32::from_rgba_unmultiplied(v[0], v[1], v[2], v[3])
}

pub(crate) fn alpha(v: Rgba, a: f32) -> Color32 {
    Color32::from_rgba_unmultiplied(v[0], v[1], v[2], (a * 255.0) as u8)
}

pub(crate) fn white(a: f32) -> Color32 {
    Color32::from_white_alpha((a * 255.0) as u8)
}

pub(crate) fn family(name: &str) -> FontFamily {
    match name {
        "" => FontFamily::Proportional,
        "mono" => FontFamily::Monospace,
        n => FontFamily::Name(n.into()),
    }
}

pub(crate) fn fonts(ctx: &egui::Context) {
    let mut f = egui::FontDefinitions::default();
    for (name, bytes) in [
        ("inter", theme::fonts::INTER),
        ("inter-semi", theme::fonts::INTER_SEMI),
        ("mono", theme::fonts::MONO),
        ("mono-semi", theme::fonts::MONO_SEMI),
        ("label", theme::fonts::LABEL),
        ("mark", theme::fonts::MARK),
    ] {
        f.font_data.insert(name.into(), Arc::new(egui::FontData::from_static(bytes)));
    }
    f.families.entry(FontFamily::Proportional).or_default().insert(0, "inter".into());
    f.families.entry(FontFamily::Monospace).or_default().insert(0, "mono".into());
    for (fam, font) in [("semi", "inter-semi"), ("label", "label"), ("mono-semi", "mono-semi"), ("mark", "mark")] {
        f.families.insert(FontFamily::Name(fam.into()), vec![font.into(), "inter".into()]);
    }
    ctx.set_fonts(f);
}

/// A caps label's layout: Archivo condensed, upper case, `spacing` (a share of the size)
/// between letters — none after the last, so it centres true.
pub(crate) fn label_job(s: &str, size: f32, spacing: f32, color: Color32) -> LayoutJob {
    let mut job = LayoutJob::default();
    // (the condensed face's word space is narrower than its letters' gaps: doubled)
    let up = s.to_uppercase().replace(' ', "  ");
    let font = FontId::new(size, family("label"));
    // every letter but the last spaced out (one section, so its spaces stay spaces); the
    // last one not, so the word centres true
    let split = up.char_indices().last().map_or(0, |(i, _)| i);
    if split > 0 {
        job.append(&up[..split], 0.0, TextFormat { font_id: font.clone(), color, extra_letter_spacing: size * spacing, ..Default::default() });
    }
    job.append(&up[split..], 0.0, TextFormat { font_id: font, color, extra_letter_spacing: 0.0, ..Default::default() });
    job
}

/// The letter spacing caps labels are set with, as a share of their size.
pub(crate) const SPACING: f32 = 0.09;

pub(crate) fn label_sized(p: &Painter, pos: Pos2, anchor: Align2, s: &str, size: f32, color: Color32) -> Rect {
    let galley = p.layout_job(label_job(s, size, SPACING, color));
    let r = anchor.anchor_size(pos, galley.size());
    p.galley(r.min, galley, color);
    r
}

/// How wide [label_sized] draws `s`.
pub(crate) fn label_width(p: &Painter, s: &str, size: f32) -> f32 {
    p.layout_job(label_job(s, size, SPACING, Color32::WHITE)).size().x
}

pub(crate) fn mmss(s: f64) -> String {
    let s = s.max(0.0);
    format!("{}:{:04.1}", (s / 60.0) as u32, s % 60.0)
}

/// A pad's word: why the booth placed it, or CUE for one a hand set.
pub(crate) fn pad_name(k: Option<PadKind>) -> &'static str {
    match k {
        Some(PadKind::Intro) => "Intro",
        Some(PadKind::Drop) => "Drop",
        Some(PadKind::Break) => "Break",
        Some(PadKind::Out) => "Out",
        None => "Cue",
    }
}

/// A pad's colour: the booth's by kind, a hand's in plain light grey.
pub(crate) fn pad_colour(k: Option<PadKind>) -> Rgba {
    k.map(theme::pad).unwrap_or(theme::SOFT)
}
