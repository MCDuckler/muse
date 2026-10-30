//! How the booth is painted: the tokens as egui colours and fonts, text and labels, and
//! the controls (buttons, knobs, faders, meters) drawn by hand over the glass.
use std::sync::Arc;

use eframe::egui::{
    self, Align2, Color32, CornerRadius, FontFamily, FontId, Mesh, Painter, Pos2, Rect, Sense, Stroke, StrokeKind, TextFormat, pos2,
    text::LayoutJob, vec2,
};
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

/// Text at `pos` anchored by `anchor`.
pub(crate) fn text(p: &Painter, pos: Pos2, anchor: Align2, s: &str, size: f32, fam: &str, color: Color32) -> Rect {
    p.text(pos, anchor, s, FontId::new(size, family(fam)), color)
}

/// A label: condensed caps, tracked.
pub(crate) fn label(p: &Painter, pos: Pos2, anchor: Align2, s: &str, color: Color32) -> Rect {
    label_sized(p, pos, anchor, s, 11.0, color)
}

pub(crate) fn label_sized(p: &Painter, pos: Pos2, anchor: Align2, s: &str, size: f32, color: Color32) -> Rect {
    let mut job = LayoutJob::default();
    job.append(
        &s.to_uppercase(),
        0.0,
        TextFormat { font_id: FontId::new(size, family("label")), color, extra_letter_spacing: size * 0.09, ..Default::default() },
    );
    let galley = p.layout_job(job);
    let r = anchor.anchor_size(pos, galley.size());
    p.galley(r.min, galley, color);
    r
}

pub(crate) fn panel(p: &Painter, r: Rect, dense: bool) {
    let fill = col(if dense { theme::GLASS_DENSE } else { theme::GLASS_PANEL });
    p.rect(r, CornerRadius::same(10), fill, Stroke::new(1.0, col(theme::GLASS_EDGE)), StrokeKind::Inside);
    p.line_segment([pos2(r.left() + 10.0, r.top() + 1.5), pos2(r.right() - 10.0, r.top() + 1.5)], Stroke::new(1.0, col(theme::GLASS_HIGHLIGHT)));
}

#[derive(Clone, Copy, PartialEq)]
pub(crate) enum Lit {
    No,
    Deck(usize),
    Ok,
}

/// A button, painted; its response.
pub(crate) fn button(ui: &mut egui::Ui, p: &Painter, r: Rect, s: &str, lit: Lit, id: impl std::hash::Hash + std::fmt::Debug) -> egui::Response {
    let resp = ui.interact(r, ui.scope_id().with(id), Sense::click());
    let (bg, edge, ink) = match lit {
        Lit::No => (white(0.05), white(0.11), col(theme::SOFT)),
        Lit::Deck(d) => (alpha(theme::DECKS[d], 0.15), alpha(theme::DECKS[d], 0.6), col(theme::TINTS[d])),
        Lit::Ok => (alpha(theme::OK, 0.15), alpha(theme::OK, 0.6), Color32::from_rgb(0xCF, 0xF5, 0xDF)),
    };
    let bg = if resp.hovered() { bg.gamma_multiply(1.6) } else { bg };
    p.rect(r, CornerRadius::same(6), bg, Stroke::new(1.0, edge), StrokeKind::Inside);
    label_sized(p, r.center(), Align2::CENTER_CENTER, s, 11.5, ink);
    resp
}

/// The two edges of a band, mirrored around `mid`, as one mesh.
pub(crate) fn band(mesh: &mut Mesh, x0: f32, step: f32, mid: f32, amps: impl Iterator<Item = f32>, color: Color32) {
    let base = mesh.vertices.len() as u32;
    let mut n = 0u32;
    for (i, a) in amps.enumerate() {
        let x = x0 + i as f32 * step;
        mesh.colored_vertex(pos2(x, mid - a), color);
        mesh.colored_vertex(pos2(x, mid + a), color);
        if i > 0 {
            let k = base + 2 * (i as u32 - 1);
            mesh.add_triangle(k, k + 1, k + 2);
            mesh.add_triangle(k + 1, k + 3, k + 2);
        }
        n += 1;
    }
    let _ = n;
}

/// A knob on a 270° sweep (bipolar ones drawn from 12 o'clock); drag up or down.
pub(crate) fn knob(ui: &mut egui::Ui, p: &Painter, c: Pos2, v: f32, color: Color32, bipolar: bool, id: impl std::hash::Hash + std::fmt::Debug) -> Option<f32> {
    let r = Rect::from_center_size(c, vec2(36.0, 36.0));
    let resp = ui.interact(r, ui.scope_id().with(id), Sense::drag());
    let arc = |a0: f32, a1: f32, color: Color32| {
        let n = 24;
        let pts: Vec<Pos2> = (0..=n).map(|i| {
            let a = (a0 + (a1 - a0) * i as f32 / n as f32).to_radians();
            pos2(c.x + 13.5 * a.cos(), c.y + 13.5 * a.sin())
        }).collect();
        p.add(egui::Shape::line(pts, Stroke::new(2.7, color)));
    };
    arc(135.0, 405.0, col(theme::EDGE));
    let at = 135.0 + 270.0 * v;
    if bipolar { arc(270.0f32.min(at), 270.0f32.max(at), color) } else { arc(135.0, at, color) }
    p.circle(c, 9.5, Color32::from_rgb(0x1E, 0x20, 0x27), Stroke::new(1.0, Color32::from_rgb(0x33, 0x36, 0x3E)));
    let a = at.to_radians();
    p.line_segment([c, pos2(c.x + 8.0 * a.cos(), c.y + 8.0 * a.sin())], Stroke::new(2.0, col(theme::TEXT)));
    resp.dragged().then(|| (v - resp.drag_delta().y * 0.004).clamp(0.0, 1.0))
}

/// A vertical fader: track, cap; drag the cap.
pub(crate) fn vfader(ui: &mut egui::Ui, p: &Painter, r: Rect, v: f32, id: impl std::hash::Hash + std::fmt::Debug) -> Option<f32> {
    let resp = ui.interact(r, ui.scope_id().with(id), Sense::drag());
    p.rect_filled(Rect::from_center_size(r.center(), vec2(4.0, r.height())), CornerRadius::same(2), col(theme::LINE));
    let y = r.bottom() - 9.0 - v * (r.height() - 18.0);
    p.rect_filled(Rect::from_center_size(pos2(r.center().x, y), vec2(30.0, 18.0)), CornerRadius::same(4), col(theme::CAP));
    resp.dragged().then(|| (v - resp.drag_delta().y / (r.height() - 18.0)).clamp(0.0, 1.0))
}

pub(crate) fn meter(p: &Painter, r: Rect, level: f32, n: usize) {
    let h = (r.height() - (n - 1) as f32 * 2.0) / n as f32;
    for i in 0..n {
        let on = (n - i) as f32 / n as f32 <= level;
        let c = if !on { Color32::from_rgb(0x22, 0x25, 0x2C) } else if i < 2 { col(theme::HOT) } else if i < 5 { col(theme::WARM) } else { Color32::from_rgb(0xD7, 0xDA, 0xE0) };
        p.rect_filled(Rect::from_min_size(pos2(r.left(), r.top() + i as f32 * (h + 2.0)), vec2(r.width(), h)), CornerRadius::same(1), c);
    }
}

pub(crate) fn mmss(s: f64) -> String {
    let s = s.max(0.0);
    format!("{}:{:04.1}", (s / 60.0) as u32, s % 60.0)
}

pub(crate) fn pad_name(k: PadKind) -> &'static str {
    match k {
        PadKind::Intro => "Intro",
        PadKind::Drop => "Drop",
        PadKind::Break => "Break",
        PadKind::Out => "Out",
    }
}

/// One line of text cut to `room` px with an ellipsis.
pub(crate) fn clip_text(p: &Painter, pos: Pos2, s: &str, size: f32, color: Color32, room: f32) {
    let font = FontId::new(size, family(""));
    let mut job = LayoutJob::single_section(s.to_owned(), TextFormat { font_id: font, color, ..Default::default() });
    job.wrap = egui::text::TextWrapping { max_width: room.max(10.0), max_rows: 1, break_anywhere: true, overflow_character: Some('…') };
    let g = p.layout_job(job);
    p.galley(pos2(pos.x, pos.y - g.size().y / 2.0), g, color);
}
