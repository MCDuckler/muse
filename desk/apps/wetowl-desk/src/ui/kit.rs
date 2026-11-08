//! The kit: every control the Desk draws, each owning its look, its states (rest, hover,
//! pressed, on, disabled) and its motion; panels only place them. Painted by hand over the
//! glass, as before, but in one place.
// a painted control takes its place, its value, its look and its id: many arguments
#![allow(clippy::too_many_arguments)]
use eframe::egui::{
    self, Align2, Color32, CornerRadius, FontId, Id, Painter, Pos2, Rect, Response, Sense, Shape, Stroke, StrokeKind, TextureId, Ui, epaint::RectShape,
    pos2, vec2,
};
use wo_deskcore::theme;

use super::fit;
use super::icons::{self, Icon};
use super::motion::{self, Ease};
use super::tokens::{self as t, Tone, mix};
use crate::paint::{alpha, col, family, label_job, label_sized, label_width};

/// A panel: elevation 1, glass (or dense glass for data), its edge and one inner highlight.
pub fn panel(p: &Painter, r: Rect, dense: bool) {
    fit::panel(r);
    let cr = CornerRadius::same(t::R_PANEL);
    p.add(t::shadow(1).as_shape(r, cr));
    let fill = col(if dense { theme::GLASS_DENSE } else { theme::GLASS_PANEL });
    p.rect(r, cr, fill, Stroke::new(1.0, col(theme::GLASS_EDGE)), StrokeKind::Inside);
    p.line_segment([pos2(r.left() + 12.0, r.top() + 1.5), pos2(r.right() - 12.0, r.top() + 1.5)], Stroke::new(1.0, col(theme::GLASS_HIGHLIGHT)));
}

/// A section's title: condensed caps, in `soft` — a step above a label.
pub fn section(p: &Painter, pos: Pos2, anchor: Align2, s: &str) -> Rect {
    label_sized(p, pos, anchor, s, t::SECTION, t::soft())
}

/// A field's label: condensed caps, 11 px, the glass's faint.
pub fn label(p: &Painter, pos: Pos2, anchor: Align2, s: &str) -> Rect {
    label_sized(p, pos, anchor, s, t::LABEL, t::label())
}

/// A hint: sentence case, Inter 12, faint.
pub fn hint(p: &Painter, pos: Pos2, anchor: Align2, s: &str) -> Rect {
    p.text(pos, anchor, s, FontId::new(t::HINT, family("")), t::faint())
}

/// Text in a font family, sized and coloured.
pub fn text(p: &Painter, pos: Pos2, anchor: Align2, s: &str, size: f32, fam: &str, c: Color32) -> Rect {
    p.text(pos, anchor, s, FontId::new(size, family(fam)), c)
}

/// One line cut to `room` with an ellipsis; its rect.
pub fn clipped(p: &Painter, pos: Pos2, s: &str, size: f32, fam: &str, c: Color32, room: f32) -> Rect {
    let mut job = egui::text::LayoutJob::single_section(s.to_owned(), egui::TextFormat { font_id: FontId::new(size, family(fam)), color: c, ..Default::default() });
    job.wrap = egui::text::TextWrapping { max_width: room.max(10.0), max_rows: 1, break_anywhere: true, overflow_character: Some('…') };
    let g = p.layout_job(job);
    let r = Rect::from_min_size(pos2(pos.x, pos.y - g.size().y / 2.0), g.size());
    p.galley(r.min, g, c);
    r
}

/// The hover and press of `resp` as eased 0..1s, and whether it is pressed now.
fn states(ui: &Ui, id: Id, resp: &Response, enabled: bool) -> (f32, f32, bool) {
    let ctx = ui.ctx();
    let hovered = enabled && resp.hovered();
    let pressed = enabled && resp.is_pointer_button_down_on();
    let h = motion::tween_bool(ctx, id.with("h"), hovered, motion::QUICK, motion::STANDARD);
    let pr = motion::tween_bool(ctx, id.with("p"), pressed, 0.06, 0.14);
    (h, pr, pressed)
}

/// A button.
#[derive(Clone, Copy)]
pub struct Btn<'a> {
    text: &'a str,
    icon: Option<Icon>,
    tone: Tone,
    on: bool,
    enabled: bool,
    sub: Option<&'a str>,
    quiet: bool,
    accent: bool,
    size: f32,
    /// The icon alone, its word on hover (a row whose words do not all fit).
    bare: bool,
}

impl<'a> Btn<'a> {
    pub fn new(text: &'a str) -> Self {
        Btn { text, icon: None, tone: Tone::Neutral, on: false, enabled: true, sub: None, quiet: false, accent: false, size: 11.5, bare: false }
    }
    pub fn icon(mut self, i: Icon) -> Self {
        self.icon = Some(i);
        self
    }
    pub fn tone(mut self, t: Tone) -> Self {
        self.tone = t;
        self
    }
    pub fn on(mut self, on: bool) -> Self {
        self.on = on;
        self
    }
    pub fn enabled(mut self, e: bool) -> Self {
        self.enabled = e;
        self
    }
    /// A line under the word (the judge's buttons).
    pub fn sub(mut self, s: &'a str) -> Self {
        self.sub = Some(s);
        self
    }
    /// No fill at rest: a secondary action.
    pub fn quiet(mut self) -> Self {
        self.quiet = true;
        self
    }
    /// Its tone shown a little at rest too (NEVER and KEEP: the judging's two ends).
    pub fn accent(mut self, a: bool) -> Self {
        self.accent = a;
        self
    }
    /// The icon alone (when `b`), its word on hover: for a row of buttons that go bare
    /// together when one of them would have to (see [Btn::fits]).
    pub fn bare(mut self, b: bool) -> Self {
        self.bare = b && self.icon.is_some();
        self
    }
    /// Whether its icon and word fit `r` together (true for a button with no icon).
    pub fn fits(&self, p: &Painter, r: Rect) -> bool {
        self.icon.is_none() || self.text.is_empty() || fit::caps(p, self.text, self.size, self.text_room(r)).is_some()
    }
    /// The word's size (11.5 by default; the big transport and perform buttons larger).
    pub fn size(mut self, s: f32) -> Self {
        self.size = s;
        self
    }

    /// Drawn in `r` and clicked (or not).
    pub fn show(self, ui: &mut Ui, p: &Painter, r: Rect, id: impl std::hash::Hash + std::fmt::Debug) -> Response {
        let id = ui.scope_id().with(id);
        let resp = ui.interact(r, id, if self.enabled { Sense::click() } else { Sense::hover() });
        fit::inside(if self.text.is_empty() { "an icon button" } else { self.text }, r, ui.clip_rect());
        self.paint(ui, p, r, id, &resp);
        // its word did not fit beside its icon: the word on hover
        let resp = if self.icon_only(p, r) { resp.on_hover_text(self.text) } else { resp };
        if self.enabled { resp.on_hover_cursor(egui::CursorIcon::PointingHand) } else { resp }
    }

    /// The icon's side beside a word, in `r`.
    fn icon_side(r: Rect) -> f32 {
        14.0f32.min(r.height() * 0.5)
    }

    /// The room a word has in `r` (beside the icon, if any).
    fn text_room(&self, r: Rect) -> f32 {
        r.width() - 12.0 - if self.icon.is_some() { Self::icon_side(r) + Self::GAP } else { 0.0 }
    }

    /// Between an icon and its word.
    const GAP: f32 = 6.0;

    /// An icon and a word that do not fit together: the icon alone.
    fn icon_only(&self, p: &Painter, r: Rect) -> bool {
        self.icon.is_some() && !self.text.is_empty() && (self.bare || fit::caps(p, self.text, self.size, self.text_room(r)).is_none())
    }

    /// Drawn for a response that comes from elsewhere (one held down: CUE, a nudge).
    pub fn paint(self, ui: &Ui, p: &Painter, r: Rect, id: Id, resp: &Response) {
        let (h, pr, _) = states(ui, id, resp, self.enabled);
        let on = motion::tween_bool(ui.ctx(), id.with("on"), self.on && self.enabled, motion::STANDARD, motion::STANDARD);
        let (lit_fill, lit_edge, lit_ink) = self.tone.lit();
        let rest = if self.quiet { Color32::TRANSPARENT } else { t::fill_rest() };
        let mut fill = mix(rest, t::fill_hover(), h);
        fill = mix(fill, t::fill_press(), pr * 0.7);
        fill = mix(fill, lit_fill, on);
        let mut edge = mix(if self.quiet { Color32::TRANSPARENT } else { t::edge_rest() }, t::edge_hover(), h);
        edge = mix(edge, lit_edge, on);
        let mut ink = mix(t::soft(), t::high(), h * 0.6);
        if self.accent {
            fill = mix(fill, lit_fill, 0.45);
            edge = mix(edge, lit_edge, 0.5);
            ink = mix(ink, lit_ink, 0.75);
        }
        ink = mix(ink, lit_ink, on);
        if !self.enabled {
            fill = Color32::from_white_alpha(5);
            edge = Color32::from_white_alpha(14);
            ink = t::faint();
        }
        let cr = CornerRadius::same(t::R_CONTROL);
        p.rect(r, cr, fill, Stroke::new(1.0, edge), StrokeKind::Inside);
        // the content sinks a pixel while pressed
        let c = r.center() + vec2(0.0, pr);
        let has_text = !self.text.is_empty();
        let sub_h = if self.sub.is_some() { 8.0 } else { 0.0 };
        let alone = self.icon_only(p, r);
        match (self.icon, has_text && !alone) {
            (Some(i), false) => {
                let s = (r.height() * 0.5).min(20.0);
                icons::paint(p, Rect::from_center_size(c, vec2(s, s)), i, ink);
            }
            (Some(i), true) => {
                let s = Self::icon_side(r);
                let (z, sp) = fit::caps(p, self.text, self.size, self.text_room(r)).unwrap_or((self.size, 0.0));
                let g = p.layout_job(label_job(self.text, z, sp, ink));
                let w = g.size().x + s + Self::GAP;
                let x0 = c.x - w / 2.0;
                icons::paint(p, Rect::from_center_size(pos2(x0 + s / 2.0, c.y - sub_h), vec2(s, s)), i, ink);
                p.galley(pos2(x0 + s + Self::GAP, c.y - sub_h - g.size().y / 2.0), g, ink);
            }
            (None, _) => {
                fit::label(p, pos2(c.x, c.y - sub_h), Align2::CENTER_CENTER, self.text, self.size, ink, self.text_room(r));
            }
        }
        if let Some(s) = self.sub {
            let sub_ink = if self.enabled { mix(t::muted(), lit_ink, on * 0.5) } else { t::faint() };
            let g = p.layout_no_wrap(s.to_owned(), FontId::new(11.0, family("")), sub_ink);
            if g.size().x > r.width() - 8.0 {
                fit::miss(s, g.size().x, r.width() - 8.0);
            }
            clipped(p, pos2(c.x - g.size().x.min(r.width() - 8.0) / 2.0, c.y + 10.0), s, 11.0, "", sub_ink, r.width() - 8.0);
        }
    }
}

/// Whether a row of buttons (each with its rect) should go bare together: true when any
/// one's icon and word do not fit.
pub fn bare_row(p: &Painter, row: &[(Btn<'_>, Rect)]) -> bool {
    row.iter().any(|(b, r)| !b.fits(p, *r))
}

/// Whether the pointer is held down on `r` (a control that acts on press and on release).
pub fn held(ui: &mut Ui, r: Rect, id: impl std::hash::Hash + std::fmt::Debug) -> (Id, Response) {
    let id = ui.scope_id().with(id);
    (id, ui.interact(r, id, Sense::click_and_drag()))
}

/// A segmented choice: the segments of `items` in `r`, the chosen one (if any) under a
/// highlight that glides to it. The one clicked.
pub fn segmented(ui: &mut Ui, p: &Painter, r: Rect, items: &[&str], chosen: Option<usize>, tone: Tone, id: impl std::hash::Hash + std::fmt::Debug) -> Option<usize> {
    let items: Vec<(&str, Option<Icon>)> = items.iter().map(|s| (*s, None)).collect();
    segmented_with(ui, p, r, &items, chosen, tone, id)
}

/// A segmented choice whose segments may carry icons: each icon with its word where every
/// word fits beside its icon, else the icons alone (each word on hover).
pub fn segmented_with(ui: &mut Ui, p: &Painter, r: Rect, items: &[(&str, Option<Icon>)], chosen: Option<usize>, tone: Tone, id: impl std::hash::Hash + std::fmt::Debug) -> Option<usize> {
    fit::inside(items.first().map(|i| i.0).unwrap_or("a choice"), r, ui.clip_rect());
    let id = ui.scope_id().with(id);
    let n = items.len().max(1);
    let cr = CornerRadius::same(t::R_CONTROL);
    p.rect(r, cr, Color32::from_white_alpha(8), Stroke::new(1.0, Color32::from_white_alpha(18)), StrokeKind::Inside);
    let w = r.width() / n as f32;
    let some = motion::tween_bool(ui.ctx(), id.with("some"), chosen.is_some(), motion::STANDARD, motion::STANDARD);
    // the highlight stays where it was while it fades out
    let at = ui.ctx().data_mut(|d| {
        let last = d.get_temp_mut_or_insert_with(id.with("last"), || chosen.unwrap_or(0));
        if let Some(c) = chosen {
            *last = c;
        }
        *last
    });
    let x = motion::spring(ui.ctx(), id.with("x"), r.left() + at.min(n - 1) as f32 * w, 0.18);
    let (lit_fill, lit_edge, lit_ink) = tone.lit();
    if some > 0.01 {
        let hl = Rect::from_min_size(pos2(x, r.top()), vec2(w, r.height())).shrink(2.0);
        p.rect(hl, CornerRadius::same(t::R_CONTROL - 1), lit_fill.gamma_multiply(some), Stroke::new(1.0, lit_edge.gamma_multiply(some)), StrokeKind::Inside);
    }
    let is = (r.height() * 0.5).min(14.0);
    let bare = items.iter().any(|(s, i)| i.is_some() && fit::caps(p, s, 11.0, w - 12.0 - is - 5.0).is_none());
    let mut picked = None;
    for (i, (s, icon)) in items.iter().enumerate() {
        let sr = Rect::from_min_size(pos2(r.left() + i as f32 * w, r.top()), vec2(w, r.height()));
        let mut resp = ui.interact(sr, id.with(i), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
        let h = motion::tween_bool(ui.ctx(), id.with(("h", i)), resp.hovered(), motion::QUICK, motion::STANDARD);
        let on = motion::tween_bool(ui.ctx(), id.with(("on", i)), chosen == Some(i), motion::STANDARD, motion::STANDARD);
        let ink = mix(mix(t::label(), t::soft(), h), lit_ink, on);
        match icon {
            Some(ic) if bare => {
                icons::paint(p, Rect::from_center_size(sr.center(), vec2(is + 2.0, is + 2.0)), *ic, ink);
                resp = resp.on_hover_text(*s);
            }
            Some(ic) => {
                let (z, sp) = fit::caps(p, s, 11.0, w - 12.0 - is - 5.0).unwrap_or((11.0, 0.0));
                let g = p.layout_job(label_job(s, z, sp, ink));
                let x0 = sr.center().x - (g.size().x + is + 5.0) / 2.0;
                icons::paint(p, Rect::from_center_size(pos2(x0 + is / 2.0, sr.center().y), vec2(is, is)), *ic, ink);
                p.galley(pos2(x0 + is + 5.0, sr.center().y - g.size().y / 2.0), g, ink);
            }
            None => {
                fit::label(p, sr.center(), Align2::CENTER_CENTER, s, 11.0, ink, w - 8.0);
            }
        }
        if resp.clicked() {
            picked = Some(i);
        }
    }
    picked
}

/// A deck's letter in its colour, as a small chip; its rect.
pub fn deck_chip(p: &Painter, left_center: Pos2, d: usize) -> Rect {
    let r = Rect::from_min_size(pos2(left_center.x, left_center.y - 9.0), vec2(20.0, 18.0));
    p.rect(r, CornerRadius::same(4), alpha_of(t::deck(d), 0.2), Stroke::new(1.0, alpha_of(t::deck(d), 0.55)), StrokeKind::Inside);
    text(p, r.center() + vec2(0.0, 0.5), Align2::CENTER_CENTER, ["A", "B"][d.min(1)], 11.0, "mono-semi", t::tint(d));
    r
}

/// A small glass tab over busy pictures (a waveform's lane, a stage picture's caption).
pub fn glass_tab(p: &Painter, r: Rect) {
    p.add(egui::Shadow { offset: [0, 2], blur: 8, spread: 0, color: Color32::from_black_alpha(90) }.as_shape(r, CornerRadius::same(t::R_CONTROL)));
    p.rect(r, CornerRadius::same(t::R_CONTROL), Color32::from_rgba_unmultiplied(14, 15, 19, 214), Stroke::new(1.0, Color32::from_white_alpha(22)), StrokeKind::Inside);
}

/// A chip: a small pill of words, lit or not.
pub fn chip(ui: &mut Ui, p: &Painter, r: Rect, s: &str, on: bool, tone: Tone, enabled: bool, id: impl std::hash::Hash + std::fmt::Debug) -> Response {
    fit::inside(s, r, ui.clip_rect());
    let id = ui.scope_id().with(id);
    let resp = ui.interact(r, id, if enabled { Sense::click() } else { Sense::hover() });
    let (h, pr, _) = states(ui, id, &resp, enabled);
    let on_t = motion::tween_bool(ui.ctx(), id.with("on"), on && enabled, motion::STANDARD, motion::STANDARD);
    let (lf, le, li) = tone.lit();
    let cr = CornerRadius::same((r.height() / 2.0) as u8);
    let fill = mix(mix(mix(Color32::from_white_alpha(6), t::fill_hover(), h), t::fill_press(), pr), lf, on_t);
    let edge = mix(mix(Color32::from_white_alpha(20), t::edge_hover(), h), le, on_t);
    let ink = if enabled { mix(mix(t::muted(), t::text(), h), li, on_t) } else { t::faint() };
    p.rect(r, cr, fill, Stroke::new(1.0, edge), StrokeKind::Inside);
    fit::label(p, r.center(), Align2::CENTER_CENTER, s, 11.0, ink, r.width() - 12.0);
    if enabled { resp.on_hover_cursor(egui::CursorIcon::PointingHand) } else { resp }
}

/// How wide a chip of `s` is.
pub fn chip_width(p: &Painter, s: &str) -> f32 {
    label_width(p, s, 11.0) + 24.0
}

/// A hot cue pad: its number, its name and colour where it is set (a "+" on hover where it
/// is not); a press flashes it. `fired` counts its presses (a new count flashes).
pub fn pad(ui: &mut Ui, p: &Painter, r: Rect, n: usize, set: Option<(&str, Color32)>, fired: u64, id: impl std::hash::Hash + std::fmt::Debug) -> Response {
    let id = ui.scope_id().with(id);
    let resp = ui.interact(r, id, Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
    let (h, pr, _) = states(ui, id, &resp, true);
    let set_t = motion::tween_bool(ui.ctx(), id.with("set"), set.is_some(), motion::STANDARD, motion::STANDARD);
    let fl = motion::flash(ui.ctx(), id.with("fl"), fired, 0.26);
    let cr = CornerRadius::same(t::R_PAD);
    // narrow pads (a small window) keep their colour and word, losing the number
    let pc = p.with_clip_rect(r.shrink(2.0));
    let narrow = r.width() < 64.0;
    match set {
        Some((name, c)) => {
            let fill = alpha_of(c, 0.13 + 0.1 * h + 0.35 * fl - 0.04 * pr);
            p.rect(r, cr, mix(Color32::TRANSPARENT, fill, set_t), Stroke::new(1.0, alpha_of(c, 0.5 + 0.25 * h)), StrokeKind::Inside);
            if narrow {
                fit::label(&pc, r.center(), Align2::CENTER_CENTER, name, 10.5, t::text(), r.width() - 8.0);
            } else {
                let num = text(&pc, pos2(r.left() + 10.0, r.center().y), Align2::LEFT_CENTER, &n.to_string(), 11.0, "mono", Color32::from_white_alpha(200));
                fit::label(&pc, pos2(num.right() + 7.0, r.center().y), Align2::LEFT_CENTER, name, 11.5, t::text(), r.right() - 8.0 - num.right() - 7.0);
            }
        }
        None => {
            p.rect(r, cr, Color32::from_white_alpha((4.0 + 10.0 * h) as u8), Stroke::new(1.0, Color32::from_white_alpha((18.0 + 22.0 * h) as u8)), StrokeKind::Inside);
            let at = if narrow { pos2(r.center().x, r.center().y) } else { pos2(r.left() + 10.0, r.center().y) };
            text(&pc, at, if narrow { Align2::CENTER_CENTER } else { Align2::LEFT_CENTER }, &n.to_string(), 11.0, "mono", mix(t::faint(), Color32::TRANSPARENT, h));
            if h > 0.01 {
                icons::paint(p, Rect::from_center_size(r.center() + vec2(if narrow { 0.0 } else { 8.0 }, 0.0), vec2(14.0, 14.0)), Icon::Plus, Color32::from_white_alpha((150.0 * h) as u8));
            }
        }
    }
    resp
}

pub fn alpha_of(c: Color32, a: f32) -> Color32 {
    let [r, g, b, _] = c.to_srgba_unmultiplied();
    Color32::from_rgba_unmultiplied(r, g, b, (a.clamp(0.0, 1.0) * 255.0) as u8)
}

/// A knob on a 270° sweep (bipolar from 12 o'clock); drag up or down, double-click to `rest`.
/// Its picture follows the value on a spring, so a controller's steps glide.
pub fn knob(ui: &mut Ui, p: &Painter, c: Pos2, v: f32, color: Color32, bipolar: bool, rest: f32, id: impl std::hash::Hash + std::fmt::Debug) -> Option<f32> {
    knob_with(ui, p, c, v, color, bipolar, rest, id, |_| String::new())
}

/// A knob whose value `tag` puts into words on a small tab above it while a hand is on it.
pub fn knob_with(ui: &mut Ui, p: &Painter, c: Pos2, v: f32, color: Color32, bipolar: bool, rest: f32, id: impl std::hash::Hash + std::fmt::Debug, tag: impl Fn(f32) -> String) -> Option<f32> {
    let id = ui.scope_id().with(id);
    let r = Rect::from_center_size(c, vec2(38.0, 38.0));
    let resp = ui.interact(r, id, Sense::click_and_drag()).on_hover_cursor(egui::CursorIcon::ResizeVertical);
    let h = motion::tween_bool(ui.ctx(), id.with("h"), resp.hovered() || resp.dragged(), motion::QUICK, motion::STANDARD);
    let shown = motion::spring(ui.ctx(), id.with("v"), v, 0.06);
    let arc = |a0: f32, a1: f32, color: Color32, w: f32| {
        let n = ((a1 - a0).abs() / 270.0 * 28.0).ceil().max(2.0) as usize;
        let pts: Vec<Pos2> = (0..=n)
            .map(|i| {
                let a = (a0 + (a1 - a0) * i as f32 / n as f32).to_radians();
                pos2(c.x + 14.5 * a.cos(), c.y + 14.5 * a.sin())
            })
            .collect();
        p.add(Shape::line(pts, Stroke::new(w, color)));
    };
    arc(135.0, 405.0, mix(col(theme::LINE), Color32::from_rgb(0x34, 0x37, 0x40), h), 3.0);
    let at = 135.0 + 270.0 * shown;
    if bipolar {
        // the detent at 12 o'clock
        p.line_segment([pos2(c.x, c.y - 17.5), pos2(c.x, c.y - 19.5)], Stroke::new(1.5, Color32::from_white_alpha(90)));
        if (at - 270.0).abs() > 0.5 {
            arc(270.0f32.min(at), 270.0f32.max(at), color, 3.0);
        }
    } else {
        arc(135.0, at, color, 3.0);
    }
    // the cap: a little light from above, a soft shadow under
    p.circle_filled(c + vec2(0.0, 1.5), 11.0, Color32::from_black_alpha(90));
    p.circle(c, 10.5, mix(Color32::from_rgb(0x1F, 0x21, 0x28), Color32::from_rgb(0x28, 0x2B, 0x33), h), Stroke::new(1.0, Color32::from_rgb(0x3A, 0x3D, 0x46)));
    p.circle_filled(c - vec2(0.0, 3.0), 6.5, Color32::from_white_alpha(7));
    let a = at.to_radians();
    p.line_segment([pos2(c.x + 3.5 * a.cos(), c.y + 3.5 * a.sin()), pos2(c.x + 9.0 * a.cos(), c.y + 9.0 * a.sin())], Stroke::new(2.0, t::text()));
    let words = tag(v);
    if !words.is_empty() && (resp.dragged() || resp.hovered()) {
        let g = p.layout_no_wrap(words, FontId::new(11.0, family("mono")), t::text());
        let tr = Rect::from_center_size(pos2(c.x, c.y - 30.0), g.size() + vec2(12.0, 6.0));
        let fp = p.clone().with_layer_id(egui::LayerId::new(egui::Order::Tooltip, id.with("tag")));
        glass_tab(&fp, tr);
        fp.galley(tr.center() - g.size() / 2.0, g, t::text());
    }
    if resp.double_clicked() {
        return Some(rest);
    }
    resp.dragged().then(|| (v - resp.drag_delta().y * 0.004).clamp(0.0, 1.0))
}

/// A vertical fader: a track, the level below the cap, the cap on a spring; drag the cap.
pub fn vfader(ui: &mut Ui, p: &Painter, r: Rect, v: f32, color: Color32, id: impl std::hash::Hash + std::fmt::Debug) -> Option<f32> {
    let id = ui.scope_id().with(id);
    let resp = ui.interact(r, id, Sense::drag()).on_hover_cursor(egui::CursorIcon::ResizeVertical);
    let shown = motion::spring(ui.ctx(), id.with("v"), v, 0.05);
    let h = motion::tween_bool(ui.ctx(), id.with("h"), resp.hovered() || resp.dragged(), motion::QUICK, motion::STANDARD);
    let track = Rect::from_center_size(r.center(), vec2(4.0, r.height() - 10.0));
    p.rect_filled(track, CornerRadius::same(2), col(theme::LINE));
    let y = r.bottom() - 10.0 - shown * (r.height() - 20.0);
    p.rect_filled(Rect::from_min_max(pos2(track.left(), y), track.max), CornerRadius::same(2), alpha_of(color, 0.55));
    let cap = Rect::from_center_size(pos2(r.center().x, y), vec2(32.0, 18.0));
    p.add(t::shadow(2).as_shape(cap, CornerRadius::same(4)));
    p.rect(cap, CornerRadius::same(4), mix(col(theme::CAP), t::high(), h), Stroke::new(1.0, Color32::from_black_alpha(60)), StrokeKind::Inside);
    p.line_segment([pos2(cap.left() + 6.0, cap.center().y), pos2(cap.right() - 6.0, cap.center().y)], Stroke::new(1.5, Color32::from_rgb(0x55, 0x59, 0x62)));
    resp.dragged().then(|| (v - resp.drag_delta().y / (r.height() - 20.0)).clamp(0.0, 1.0))
}

/// The crossfader: a track shaded towards the deck it leans to, the cap on a spring.
pub fn crossfader(ui: &mut Ui, p: &Painter, r: Rect, x: f32, id: impl std::hash::Hash + std::fmt::Debug) -> Option<f32> {
    let id = ui.scope_id().with(id);
    let resp = ui.interact(r, id, Sense::click_and_drag()).on_hover_cursor(egui::CursorIcon::ResizeHorizontal);
    let shown = motion::spring(ui.ctx(), id.with("x"), x, 0.05);
    let h = motion::tween_bool(ui.ctx(), id.with("h"), resp.hovered() || resp.dragged(), motion::QUICK, motion::STANDARD);
    let track = Rect::from_center_size(r.center(), vec2(r.width() - 28.0, 4.0));
    p.rect_filled(track, CornerRadius::same(2), col(theme::LINE));
    let cx = track.left() + shown * track.width();
    let mid = track.center().x;
    if (cx - mid).abs() > 1.0 {
        let lean = if cx < mid { t::deck(0) } else { t::deck(1) };
        p.rect_filled(Rect::from_min_max(pos2(cx.min(mid), track.top()), pos2(cx.max(mid), track.bottom())), CornerRadius::same(2), alpha_of(lean, 0.6));
    }
    // the middle: a detent that flashes as the cap crosses it
    let side = ui.ctx().data_mut(|d| {
        let was = d.get_temp_mut_or_insert_with(id.with("side"), || (x >= 0.5, 0u64));
        if (x >= 0.5) != was.0 && (x - 0.5).abs() > 0.004 {
            *was = (x >= 0.5, was.1 + 1);
        }
        was.1
    });
    let fl = motion::flash(ui.ctx(), id.with("detent"), side, 0.2);
    p.line_segment([pos2(mid, r.top() + 4.0), pos2(mid, r.bottom() - 4.0)], Stroke::new(1.0 + fl, mix(Color32::from_rgb(0x4A, 0x4E, 0x57), t::high(), fl)));
    let cap = Rect::from_center_size(pos2(cx, r.center().y), vec2(30.0, 22.0));
    p.add(t::shadow(2).as_shape(cap, CornerRadius::same(4)));
    p.rect(cap, CornerRadius::same(4), mix(col(theme::CAP), t::high(), h), Stroke::new(1.0, Color32::from_black_alpha(60)), StrokeKind::Inside);
    p.line_segment([pos2(cap.center().x, cap.top() + 5.0), pos2(cap.center().x, cap.bottom() - 5.0)], Stroke::new(1.5, Color32::from_rgb(0x55, 0x59, 0x62)));
    if resp.double_clicked() {
        return Some(0.5);
    }
    resp.dragged().then(|| (x + resp.drag_delta().x / track.width()).clamp(0.0, 1.0))
}

/// A level slider: a thin track, filled to the value, a small round cap; click or drag to set
/// (0..1; the caller snaps it to steps). `on` false: drawn faint, still usable. A double click
/// gives `rest`.
pub fn hslider(ui: &mut Ui, p: &Painter, r: Rect, k: f32, on: bool, rest: f32, id: impl std::hash::Hash + std::fmt::Debug) -> Option<f32> {
    let id = ui.scope_id().with(id);
    let resp = ui.interact(r, id, Sense::click_and_drag()).on_hover_cursor(egui::CursorIcon::ResizeHorizontal);
    let shown = motion::spring(ui.ctx(), id.with("k"), k.clamp(0.0, 1.0), 0.05);
    let h = motion::tween_bool(ui.ctx(), id.with("h"), resp.hovered() || resp.dragged(), motion::QUICK, motion::STANDARD);
    let track = Rect::from_center_size(r.center(), vec2(r.width() - 14.0, 3.0));
    p.rect_filled(track, CornerRadius::same(2), col(theme::LINE));
    let cx = track.left() + shown * track.width();
    let fill = if on { mix(alpha_of(t::text(), 0.55), t::text(), h) } else { alpha_of(t::soft(), 0.3) };
    p.rect_filled(Rect::from_min_max(track.min, pos2(cx, track.bottom())), CornerRadius::same(2), fill);
    p.circle(pos2(cx, r.center().y), 5.5 + 1.0 * h, if on { mix(col(theme::CAP), t::high(), h) } else { col(theme::CAP) }, Stroke::new(1.0, Color32::from_black_alpha(80)));
    if resp.double_clicked() {
        return Some(rest);
    }
    let at = |x: f32| ((x - track.left()) / track.width()).clamp(0.0, 1.0);
    if resp.dragged() || resp.clicked() {
        return resp.interact_pointer_pos().map(|pos| at(pos.x));
    }
    None
}

/// A level meter of `n` segments: up at once, down over 300 ms, the peak held a second; a
/// level at full scale lights the clip mark over it, held until it is clicked.
pub fn meter(ui: &mut Ui, p: &Painter, r: Rect, level: f32, n: usize, id: impl std::hash::Hash + std::fmt::Debug) {
    let ctx = ui.ctx().clone();
    let id = ui.scope_id().with(id);
    let now = ctx.input(|i| i.time);
    let (mut shown, mut peak, mut peak_at, mut at, mut clip) = ctx.data(|d| d.get_temp::<(f32, f32, f64, f64, bool)>(id)).unwrap_or((0.0, 0.0, now, now, false));
    let dt = (now - at).clamp(0.0, 0.1) as f32;
    at = now;
    shown = if level >= shown { level } else { (shown - dt / 0.3).max(level) };
    if level >= peak {
        peak = level;
        peak_at = now;
    } else if now - peak_at > 1.0 {
        peak = (peak - dt / 0.4).max(shown);
    }
    if level >= 0.999 {
        clip = true;
    }
    let mark = Rect::from_min_size(pos2(r.left(), r.top() - 7.0), vec2(r.width(), 4.0));
    if clip && ui.interact(mark.expand(4.0), id.with("clip"), Sense::click()).on_hover_text("It reached full scale: a click clears it").clicked() {
        clip = false;
    }
    ctx.data_mut(|d| d.insert_temp(id, (shown, peak, peak_at, at, clip)));
    if shown > 0.0 || peak > 0.0 {
        ctx.request_repaint();
    }
    p.rect_filled(mark, CornerRadius::same(1), if clip { col(theme::HOT) } else { Color32::from_rgb(0x22, 0x25, 0x2C) });
    let gap = 2.0;
    let h = (r.height() - (n - 1) as f32 * gap) / n as f32;
    let peak_i = ((1.0 - peak) * n as f32).floor() as usize;
    for i in 0..n {
        let on = (n - i) as f32 / n as f32 <= shown + 1e-4;
        let hot = if i < 2 { col(theme::HOT) } else if i < 5 { col(theme::WARM) } else { Color32::from_rgb(0xB4, 0xB9, 0xC4) };
        let c = if on || (i == peak_i.min(n - 1) && peak > 0.02) { hot } else { Color32::from_rgb(0x20, 0x23, 0x2A) };
        p.rect_filled(Rect::from_min_size(pos2(r.left(), r.top() + i as f32 * (h + gap)), vec2(r.width(), h)), CornerRadius::same(1), c);
    }
}

/// A record's sleeve: its cover where there is one (faded in), else its initials on its
/// colour.
pub fn sleeve(ui: &Ui, p: &Painter, r: Rect, cover: Option<TextureId>, initials: &str, colour: Color32, radius: u8, id: impl std::hash::Hash + std::fmt::Debug) {
    let cr = CornerRadius::same(radius);
    let shown = motion::tween_bool(ui.ctx(), ui.scope_id().with(id), cover.is_some(), motion::EMPHASIS, 0.0);
    if shown < 1.0 {
        p.rect_filled(r, cr, colour);
        text(p, r.center(), Align2::CENTER_CENTER, initials, (r.height() * 0.36).clamp(10.0, 24.0), "mark", Color32::from_white_alpha(224));
    }
    if let Some(tex) = cover {
        let a = (shown * 255.0) as u8;
        p.add(RectShape::filled(r, cr, Color32::from_white_alpha(a)).with_texture(tex, Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0))));
    }
    p.rect_stroke(r, cr, Stroke::new(1.0, Color32::from_white_alpha(18)), StrokeKind::Inside);
}

/// A text field over the glass: its frame lights while typed in; an icon at its left.
pub fn field(ui: &mut Ui, p: &Painter, r: Rect, value: &mut String, hint_s: &str, icon: Option<Icon>, password: bool, id: impl std::hash::Hash + std::fmt::Debug) -> Response {
    fit::inside(hint_s, r, ui.clip_rect());
    let id = ui.scope_id().with(id);
    let focused = ui.memory(|m| m.has_focus(id));
    let f = motion::tween_bool(ui.ctx(), id.with("f"), focused, motion::STANDARD, motion::STANDARD);
    let cr = CornerRadius::same(t::R_CONTROL + 1);
    p.rect(r, cr, mix(Color32::from_white_alpha(8), Color32::from_white_alpha(14), f), Stroke::new(1.0, mix(t::edge_rest(), alpha(theme::SOFT, 0.55), f)), StrokeKind::Inside);
    let mut left = r.left() + 10.0;
    if let Some(i) = icon {
        icons::paint(p, Rect::from_center_size(pos2(r.left() + 18.0, r.center().y), vec2(15.0, 15.0)), i, mix(t::faint(), t::soft(), f));
        left = r.left() + 32.0;
    }
    let edit = Rect::from_min_max(pos2(left, r.top() + 6.0), pos2(r.right() - 10.0, r.bottom() - 6.0));
    ui.put(
        edit,
        egui::TextEdit::singleline(value).id(id).hint_text(egui::RichText::new(hint_s).color(t::faint())).password(password).frame(egui::Frame::NONE).font(FontId::new(t::BODY, family(""))).text_color(t::text()),
    )
}

/// How a status is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    /// Not there (not signed in, nothing plugged in, closed).
    Off,
    /// There and well.
    On,
    /// On its way: a short arc circles it.
    Busy,
    /// There, with trouble: warm, with a small badge.
    Trouble,
}

/// A status as an icon in the square `r`: lit when on, outlined and faint when off, a short
/// arc circling it while busy, warm with a badge in trouble — never a dot and a word.
pub fn status(ui: &Ui, p: &Painter, r: Rect, icon: Icon, state: State, id: impl std::hash::Hash + std::fmt::Debug) {
    let ctx = ui.ctx();
    let id = ui.scope_id().with(id);
    let on = motion::tween_bool(ctx, id.with("on"), state == State::On, motion::STANDARD, motion::STANDARD);
    let warm = motion::tween_bool(ctx, id.with("warm"), state == State::Trouble, motion::STANDARD, motion::STANDARD);
    let ink = mix(mix(alpha_of(t::faint(), 0.7), t::soft(), on), t::warm(), warm);
    let side = r.width().min(r.height()) * 0.56;
    icons::paint(p, Rect::from_center_size(r.center(), vec2(side, side)), icon, ink);
    if state == State::Busy {
        let t0 = ctx.input(|i| i.time) as f32;
        let a0 = (t0 * 1.6).fract() * std::f32::consts::TAU;
        let rad = r.width().min(r.height()) / 2.0 - 1.5;
        let pts: Vec<Pos2> = (0..=16).map(|i| {
            let a = a0 + i as f32 / 16.0 * 1.6;
            pos2(r.center().x + rad * a.cos(), r.center().y + rad * a.sin())
        }).collect();
        p.add(Shape::line(pts, Stroke::new(1.5, t::warm())));
        ctx.request_repaint();
    }
    if warm > 0.01 {
        let c = r.right_top() + vec2(-6.0, 6.0);
        p.circle_filled(c, 4.5 * warm, t::warm());
        p.line_segment([c + vec2(0.0, -2.2), c + vec2(0.0, 0.6)], Stroke::new(1.3, alpha_of(col(theme::GROUND), warm)));
        p.circle_filled(c + vec2(0.0, 2.1), 0.7, alpha_of(col(theme::GROUND), warm));
    }
}

/// The tally: `words` in white caps on red (on the stage now, on air). Its rect, from its
/// left middle.
pub fn tally(p: &Painter, left_center: Pos2, words: &str) -> Rect {
    let w = label_width(p, words, 9.5) + 12.0;
    let r = Rect::from_min_size(pos2(left_center.x, left_center.y - 8.0), vec2(w, 16.0));
    p.rect_filled(r, CornerRadius::same(3), t::red());
    label_sized(p, r.center(), Align2::CENTER_CENTER, words, 9.5, Color32::WHITE);
    r
}

/// "On the stage now", small: the live icon in red, centred at `c`.
pub fn on_air(p: &Painter, c: Pos2, side: f32) {
    p.circle_filled(c, side * 0.62, Color32::from_black_alpha(150));
    icons::paint(p, Rect::from_center_size(c, vec2(side, side)), Icon::Live, t::red());
}

/// Someone's initial in a ring, centred at `c`.
pub fn avatar(p: &Painter, c: Pos2, r: f32, name: &str) {
    p.circle(c, r, alpha_of(t::soft(), 0.14), Stroke::new(1.0, alpha_of(t::soft(), 0.4)));
    let first: String = name.chars().filter(|c| c.is_alphanumeric()).take(1).flat_map(char::to_uppercase).collect();
    text(p, c + vec2(0.0, 0.5), Align2::CENTER_CENTER, &first, r * 1.05, "semi", t::text());
}

/// The modal frame: the scrim over everything and a card rising into the middle, `k` its
/// shown share (0..1). The card's rect.
pub fn modal(p: &Painter, full: Rect, size: egui::Vec2, k: f32) -> Rect {
    fit::panel(Rect::from_center_size(full.center(), size));
    let e = Ease::Out.at(k);
    p.rect_filled(full, CornerRadius::ZERO, Color32::from_black_alpha((140.0 * e) as u8));
    let s = 0.98 + 0.02 * e;
    let card = Rect::from_center_size(full.center() + vec2(0.0, 8.0 * (1.0 - e)), size * s);
    p.add(t::shadow(3).as_shape(card, CornerRadius::same(t::R_OVERLAY)));
    let a = |v: u8| ((v as f32) * e) as u8;
    p.rect(card, CornerRadius::same(t::R_OVERLAY), Color32::from_rgba_unmultiplied(16, 17, 22, a(246)), Stroke::new(1.0, Color32::from_white_alpha(a(28))), StrokeKind::Inside);
    card
}

/// A toast: words at the bottom middle, rising in and fading out by `k`.
pub fn toast(p: &Painter, full: Rect, n: usize, words: &str, tone: Tone, k: f32) {
    let e = Ease::Out.at(k);
    let g = p.layout_no_wrap(words.to_owned(), FontId::new(t::BODY, family("")), t::text());
    let w = g.size().x + 50.0;
    let r = Rect::from_center_size(pos2(full.center().x, full.bottom() - 40.0 - n as f32 * 48.0 + 12.0 * (1.0 - e)), vec2(w, 38.0));
    p.add(t::shadow(2).as_shape(r, CornerRadius::same(19)));
    let (_, edge, ink) = tone.lit();
    let a = (e * 255.0) as u8;
    p.rect(r, CornerRadius::same(19), Color32::from_rgba_unmultiplied(20, 21, 27, a), Stroke::new(1.0, alpha_of(edge, e * 0.8)), StrokeKind::Inside);
    let (icon, ic) = match tone {
        Tone::Ok => (Icon::CheckCircle, t::ok()),
        Tone::Danger => (Icon::Alert, t::hot()),
        Tone::Warm => (Icon::Alert, t::warm()),
        Tone::Deck(d) => (Icon::Disc, t::tint(d)),
        Tone::Neutral => (Icon::Info, ink),
    };
    icons::paint(p, Rect::from_center_size(pos2(r.left() + 20.0, r.center().y), vec2(15.0, 15.0)), icon, alpha_of(ic, e));
    p.galley(pos2(r.left() + 34.0, r.center().y - g.size().y / 2.0), g, alpha_of(t::text(), e));
}
