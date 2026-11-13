//! The Desk's UI foundations (plans/wetowl-desk-ui-overhaul.md §3): the tokens, motion, the
//! icons and the kit; here the layout grid, egui's own widgets in the tokens, the covers as
//! textures, and the toasts.
pub mod fit;
pub mod icons;
pub mod kit;
pub mod motion;
pub mod tokens;

use std::collections::HashMap;
use std::time::{Duration, Instant};

use eframe::egui::{self, Color32, ColorImage, Context, CornerRadius, Rect, Stroke, TextureHandle, TextureId, TextureOptions, Vec2, pos2, vec2};
use wo_deskcore::{Desk, Record, theme};

use crate::paint::alpha;
use tokens::{self as t, Tone};

/// egui's own widgets — text fields, scroll bars, tooltips, popups — in the tokens.
pub fn style(ctx: &Context) {
    ctx.set_theme(egui::Theme::Dark);
    ctx.style_mut_of(egui::Theme::Dark, |s| {
        let v = &mut s.visuals;
        *v = egui::Visuals::dark();
        v.window_fill = Color32::from_rgb(16, 17, 22);
        v.panel_fill = Color32::from_rgb(11, 12, 15);
        v.window_stroke = Stroke::new(1.0, Color32::from_white_alpha(28));
        v.window_corner_radius = CornerRadius::same(t::R_OVERLAY);
        v.menu_corner_radius = CornerRadius::same(t::R_PAD);
        v.window_shadow = t::shadow(3);
        v.popup_shadow = t::shadow(2);
        v.selection.bg_fill = alpha(theme::SOFT, 0.30);
        v.selection.stroke = Stroke::new(1.0, t::high());
        v.text_cursor.stroke = Stroke::new(1.5, t::high());
        v.hyperlink_color = t::focus();
        v.extreme_bg_color = Color32::from_rgb(14, 15, 19);
        v.faint_bg_color = Color32::from_white_alpha(6);
        v.warn_fg_color = t::warm();
        v.error_fg_color = t::hot();
        for w in [&mut v.widgets.noninteractive, &mut v.widgets.inactive, &mut v.widgets.hovered, &mut v.widgets.active, &mut v.widgets.open] {
            w.corner_radius = CornerRadius::same(t::R_CONTROL);
            w.expansion = 0.0;
        }
        v.widgets.noninteractive.fg_stroke = Stroke::new(1.0, t::text());
        v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, Color32::from_white_alpha(24));
        v.widgets.inactive.weak_bg_fill = t::fill_rest();
        v.widgets.inactive.bg_fill = t::fill_rest();
        v.widgets.inactive.fg_stroke = Stroke::new(1.0, t::soft());
        v.widgets.hovered.weak_bg_fill = t::fill_hover();
        v.widgets.hovered.bg_fill = t::fill_hover();
        v.widgets.hovered.bg_stroke = Stroke::new(1.0, t::edge_hover());
        v.widgets.hovered.fg_stroke = Stroke::new(1.0, t::high());
        v.widgets.active.weak_bg_fill = t::fill_press();
        v.widgets.active.bg_fill = t::fill_press();
        v.widgets.active.fg_stroke = Stroke::new(1.0, t::high());
        s.interaction.tooltip_delay = 0.45;
        s.spacing.scroll = egui::style::ScrollStyle { bar_width: 6.0, floating_width: 3.0, ..egui::style::ScrollStyle::floating() };
        s.spacing.tooltip_width = 320.0;
        s.animation_time = motion::STANDARD;
    });
}

/// The smallest window the booth is laid out for, in points: below it the whole of it is
/// zoomed down to fit (a laptop at 125 %), above it the panels grow — a wider crate, taller
/// waveforms — and the type stays at its size.
pub const MIN: Vec2 = vec2(1400.0, 840.0);

/// The zoom for the window: 1, or less where the window is smaller than [MIN].
pub fn fit(ctx: &Context) {
    let native = ctx.native_pixels_per_point().unwrap_or(1.0);
    let zoom = ctx.zoom_factor();
    let px = ctx.content_rect().size() * ctx.pixels_per_point();
    let want = ((px.x / native) / MIN.x).min((px.y / native) / MIN.y).min(1.0);
    if (want - zoom).abs() > 0.01 {
        ctx.set_zoom_factor(want);
    }
}

/// Where the booth's panels sit.
pub struct Layout {
    pub top: Rect,
    pub overview: Rect,
    pub waves: Rect,
    pub decks: [Rect; 2],
    pub mixer: Rect,
    pub crate_: Rect,
    pub stage: Rect,
    pub auto: Rect,
    /// Under the overviews: the Show page's room.
    pub page: Rect,
}

/// The booth's grid for a window: fixed rows for what has a fixed shape (the top bar, the
/// overviews, the decks), the rest shared between waveforms and the crate.
/// `wide`: the stage and the Auto DJ folded away, the crate the whole width.
pub fn layout(full: Rect, wide: bool) -> Layout {
    let (m, g) = (12.0, t::GAP);
    let r = full.shrink(m);
    // a short window (a laptop's): the overviews and the decks a little shorter, the
    // waveforms give way first, so the crate, the stage and the Auto DJ keep their room
    let short = full.height() < 1000.0;
    let top = Rect::from_min_size(r.min, vec2(r.width(), 52.0));
    let overview = Rect::from_min_size(pos2(r.left(), top.bottom() + g), vec2(r.width(), if short { 58.0 } else { 66.0 }));
    let page = Rect::from_min_max(pos2(r.left(), overview.bottom() + g), r.max);
    let mid_h = if short { 300.0 } else { 318.0 };
    // waveforms and the crate share what is left: the waveforms 44 % (30 % when short)
    let free = r.bottom() - overview.bottom() - 3.0 * g - mid_h;
    let waves_h = if short { (free * 0.3).clamp(104.0, 320.0) } else { (free * 0.44).clamp(150.0, 320.0) };
    let waves = Rect::from_min_size(pos2(r.left(), overview.bottom() + g), vec2(r.width(), waves_h));
    let mid = Rect::from_min_size(pos2(r.left(), waves.bottom() + g), vec2(r.width(), mid_h));
    let mixer_w = (r.width() * 0.22).clamp(380.0, 460.0);
    let dw = (r.width() - mixer_w - 2.0 * g) / 2.0;
    let decks = [Rect::from_min_size(mid.min, vec2(dw, mid_h)), Rect::from_min_size(pos2(mid.right() - dw, mid.top()), vec2(dw, mid_h))];
    let mixer = Rect::from_min_max(pos2(decks[0].right() + g, mid.top()), pos2(decks[1].left() - g, mid.bottom()));
    let rest = Rect::from_min_max(pos2(r.left(), mid.bottom() + g), r.max);
    let auto_w = if wide { 0.0 } else { (r.width() * 0.21).clamp(360.0, 440.0) };
    let stage_w = if wide { 0.0 } else { (r.width() * 0.17).clamp(280.0, 360.0) };
    let g_side = if wide { 0.0 } else { g };
    let auto = Rect::from_min_max(pos2(rest.right() - auto_w, rest.top()), rest.max);
    let stage = Rect::from_min_max(pos2(auto.left() - g_side - stage_w, rest.top()), pos2(auto.left() - g_side, rest.bottom()));
    let crate_ = Rect::from_min_max(rest.min, pos2(stage.left() - g_side, rest.bottom()));
    Layout { top, overview, waves, decks, mixer, crate_, stage, auto, page }
}

/// The records' covers as textures (each made once, the oldest let go past [Sleeves::KEPT]).
#[derive(Default)]
pub struct Sleeves {
    tex: HashMap<i64, (TextureHandle, u64)>,
    used: u64,
}

impl Sleeves {
    const KEPT: usize = 160;

    /// `r`'s cover where it has one and it has come.
    pub fn of(&mut self, ctx: &Context, desk: &mut Desk, r: &Record) -> Option<TextureId> {
        self.used += 1;
        if let Some((t, at)) = self.tex.get_mut(&r.id) {
            *at = self.used;
            return Some(t.id());
        }
        let c = desk.cover(r)?;
        let img = ColorImage::from_rgba_unmultiplied([c.side as usize, c.side as usize], &c.rgba);
        let t = ctx.load_texture(format!("cover {}", r.id), img, TextureOptions::LINEAR);
        let id = t.id();
        self.tex.insert(r.id, (t, self.used));
        if self.tex.len() > Self::KEPT
            && let Some(old) = self.tex.iter().min_by_key(|(_, (_, at))| *at).map(|(k, _)| *k)
        {
            self.tex.remove(&old);
        }
        Some(id)
    }

    /// Signed out: the covers were the house's.
    pub fn clear(&mut self) {
        self.tex.clear();
    }
}

/// Words that come and go at the bottom of the window: what went wrong, what was done.
#[derive(Default)]
pub struct Toasts {
    up: Vec<(String, Tone, Instant)>,
}

impl Toasts {
    const FOR: Duration = Duration::from_secs(4);
    const IN: f32 = motion::EMPHASIS;
    const OUT: f32 = 0.18;

    pub fn say(&mut self, words: impl Into<String>, tone: Tone) {
        let words = words.into();
        // the same words again: kept up longer, not stacked
        self.up.retain(|(w, ..)| *w != words);
        self.up.push((words, tone, Instant::now()));
        if self.up.len() > 3 {
            self.up.remove(0);
        }
    }

    pub fn draw(&mut self, ctx: &Context, full: Rect) {
        self.up.retain(|(.., at)| at.elapsed() < Self::FOR + Duration::from_secs_f32(Self::OUT));
        if self.up.is_empty() {
            return;
        }
        let p = ctx.layer_painter(egui::LayerId::new(egui::Order::Tooltip, egui::Id::unique("toasts")));
        let n = self.up.len();
        for (i, (words, tone, at)) in self.up.iter().enumerate() {
            let e = at.elapsed().as_secs_f32();
            let k = if motion::reduced(ctx) { 1.0 } else { (e / Self::IN).min(1.0) };
            let gone = ((e - Self::FOR.as_secs_f32()) / Self::OUT).clamp(0.0, 1.0);
            kit::toast(&p, full, n - 1 - i, words, *tone, k * (1.0 - gone));
        }
        ctx.request_repaint_after(Duration::from_millis(50));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The booth's panels inside the window and clear of each other, from the smallest laid
    /// out to 4K.
    #[test]
    fn the_layout_fits_every_window() {
        for size in [MIN, vec2(1440.0, 860.0), vec2(1920.0, 1080.0), vec2(2560.0, 1440.0), vec2(3840.0, 2160.0)] {
            let full = Rect::from_min_size(pos2(0.0, 0.0), size);
            let l = layout(full, false);
            let panels = [("top", l.top), ("overview", l.overview), ("waves", l.waves), ("deck A", l.decks[0]), ("deck B", l.decks[1]), ("mixer", l.mixer), ("crate", l.crate_), ("stage", l.stage), ("auto", l.auto)];
            for (name, r) in panels {
                assert!(full.contains_rect(r), "{name} leaves the window at {size:?}: {r:?}");
                assert!(r.width() >= 200.0 && r.height() >= 48.0, "{name} too small at {size:?}: {r:?}");
            }
            for (i, (a, ra)) in panels.iter().enumerate() {
                for (b, rb) in &panels[i + 1..] {
                    assert!(!ra.shrink(0.5).intersects(rb.shrink(0.5)), "{a} and {b} overlap at {size:?}");
                }
            }
            assert!(full.contains_rect(l.page) && l.page.top() >= l.overview.bottom(), "the Show page's room at {size:?}");
            // the side panels folded away: the crate the whole width under the decks
            let w = layout(full, true);
            assert!(full.contains_rect(w.crate_) && (w.crate_.width() - (w.decks[1].right() - w.decks[0].left())).abs() < 0.5, "the wide crate at {size:?}: {:?}", w.crate_);
        }
    }
}
