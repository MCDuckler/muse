//! What comes over the page: the keys and the settings, as modals over a deeper scrim.
use eframe::egui::{self, Align2, Color32, CornerRadius, Painter, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::Desk;

use crate::paint::white;
use crate::ui::icons::Icon;
use crate::ui::kit::{self, Btn};
use crate::ui::motion;
use crate::ui::tokens::{self as t, Tone};
use crate::{App, Overlay};

/// The keys, by where they act.
const KEYS: [(&str, &[(&str, &str)]); 4] = [
    ("Decks", &[("1 2", "Play A / B"), ("Q W", "Sync A / B"), ("Z X", "Start A / B in step"), ("F G", "The bass off and on, A / B"), ("[ ]", "A 16-beat loop on A / B")]),
    ("Mixer and Auto DJ", &[("← →", "The crossfader"), ("⇧← ⇧→", "Nudge the master"), ("A", "The Auto DJ on and off"), ("M Space", "Mix now"), ("S N", "Not that: another record next")]),
    ("Show", &[("K", "The Show page and the booth"), ("H B", "A hit · the blackout"), (", .", "The scene before / after"), ("J", "Mosh into the next"), ("L V", "Hold the scene · freeze")]),
    ("Desk", &[("?", "These keys"), ("Ctrl ,", "The settings"), ("Esc", "Close what is over the page")]),
];

impl App {
    pub(crate) fn overlays(&mut self, desk: &mut Desk, ui: &mut Ui, full: Rect) {
        let ctx = ui.ctx().clone();
        if self.overlay.is_some() {
            self.overlay_was = self.overlay;
        }
        let k = motion::tween_bool(&ctx, egui::Id::unique("overlay"), self.overlay.is_some(), motion::EMPHASIS, motion::STANDARD);
        let Some(which) = self.overlay.or(self.overlay_was).filter(|_| k > 0.0) else { return };
        let size = match which {
            Overlay::Keys => vec2(760.0, 470.0),
            Overlay::Settings => vec2(600.0, 560.0),
        };
        egui::Area::new(egui::Id::unique("overlay-area")).order(egui::Order::Foreground).fixed_pos(full.min).show(&ctx, |ui| {
            let (all, scrim) = ui.allocate_exact_size(full.size(), Sense::click());
            let p = ui.painter().clone();
            let card = kit::modal(&p, all, size, k);
            if scrim.clicked() && ctx.pointer_interact_pos().is_some_and(|pos| !card.contains(pos)) {
                self.overlay = None;
            }
            let mut pp = p.clone();
            pp.multiply_opacity(k);
            let inner = card.shrink(24.0);
            let title = match which {
                Overlay::Keys => "Keys",
                Overlay::Settings => "Settings",
            };
            kit::text(&pp, inner.left_top() + vec2(0.0, 2.0), Align2::LEFT_TOP, title, t::TITLE, "semi", t::text());
            let close = Rect::from_min_size(pos2(inner.right() - 30.0, inner.top() - 4.0), vec2(30.0, 30.0));
            if Btn::new("").icon(Icon::Close).quiet().show(ui, &pp, close, "overlay-close").on_hover_text("Close  (Esc)").clicked() {
                self.overlay = None;
            }
            let body = Rect::from_min_max(pos2(inner.left(), inner.top() + 44.0), inner.max);
            match which {
                Overlay::Keys => keys(&pp, body),
                Overlay::Settings => self.settings(desk, ui, &pp, body),
            }
        });
    }

    fn settings(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let ctx = ui.ctx().clone();
        let label_w = 150.0;
        let mut y = r.top();
        let row = |p: &Painter, y: f32, name: &str, hint: &str| {
            kit::text(p, pos2(r.left(), y + 13.0), Align2::LEFT_CENTER, name, t::BODY, "", t::text());
            if !hint.is_empty() {
                kit::hint(p, pos2(r.left(), y + 32.0), Align2::LEFT_CENTER, hint);
            }
        };
        let seg_r = |y: f32, w: f32| Rect::from_min_size(pos2(r.left() + label_w + 40.0, y), vec2(w, 28.0));
        let mut changed = false;

        kit::section(p, pos2(r.left(), y), Align2::LEFT_TOP, "Look and feel");
        y += 26.0;
        row(p, y, "Behind the glass", "The live stage, blurred, or a still");
        if let Some(i) = kit::segmented(ui, p, seg_r(y, 240.0), &["Live stage", "Still"], Some(self.prefs.still_backdrop as usize), Tone::Neutral, "set-backdrop") {
            self.prefs.still_backdrop = i == 1;
            changed = true;
        }
        y += 52.0;
        row(p, y, "Its light", "How much of it comes through");
        let lights = [0.6f32, 0.8, 1.0];
        let at = lights.iter().position(|l| (l - self.prefs.backdrop_light).abs() < 0.05);
        if let Some(i) = kit::segmented(ui, p, seg_r(y, 240.0), &["Dim", "Soft", "Full"], at, Tone::Neutral, "set-light") {
            self.prefs.backdrop_light = lights[i];
            changed = true;
        }
        y += 52.0;
        row(p, y, "Motion", "Reduced: fades only, nothing glides");
        if let Some(i) = kit::segmented(ui, p, seg_r(y, 240.0), &["Full", "Reduced"], Some(self.prefs.reduced_motion as usize), Tone::Neutral, "set-motion") {
            self.prefs.reduced_motion = i == 1;
            changed = true;
        }
        y += 64.0;

        kit::section(p, pos2(r.left(), y), Align2::LEFT_TOP, "Stage");
        y += 26.0;
        let v = desk.stage();
        if v.rust_here {
            row(p, y, "The stage", "The Rust one: the Desk directs it");
            let names = ["WetOwl app", "Rust"];
            if let Some(i) = kit::segmented(ui, p, seg_r(y, 240.0), &names, Some(v.rust as usize), Tone::Neutral, "set-stage") {
                desk.set_rust_stage(i == 1);
            }
        } else {
            row(p, y, "The stage", "The WetOwl app's (the Rust stage is not installed here)");
        }
        y += 52.0;
        row(p, y, "Its window", "");
        let word = if v.stages > 0 || v.starting { "Close the stage" } else { "Open the stage" };
        if Btn::new(word).icon(Icon::Screen).show(ui, p, seg_r(y, 240.0), "set-stage-open").clicked() {
            if v.stages > 0 || v.starting {
                desk.close_stage();
            } else {
                desk.open_stage();
            }
        }
        y += 56.0;

        kit::section(p, pos2(r.left(), y), Align2::LEFT_TOP, "Gear and house");
        y += 26.0;
        let controllers = desk.controllers();
        row(p, y, "Controllers", "");
        let x = r.left() + label_w + 40.0;
        if controllers.is_empty() {
            kit::clipped(p, pos2(x, y + 13.0), "None found: plug one in", 13.0, "", t::muted(), r.right() - x);
        }
        for (i, c) in controllers.iter().take(2).enumerate() {
            let cy = y + 13.0 + i as f32 * 22.0;
            kit::dot(p, pos2(x + 4.0, cy), if c.trouble.is_none() { t::ok() } else { t::warm() }, 3.0);
            let words = match &c.trouble {
                None => format!("{} · {}", c.name, c.layout),
                Some(why) => format!("{}: {why}", c.name),
            };
            kit::clipped(p, pos2(x + 16.0, cy), &words, 13.0, "", t::soft(), r.right() - x - 16.0);
        }
        y += 52.0;
        row(p, y, "The house", "");
        match desk.house().map(|(s, u)| (s.trim_start_matches("https://").to_owned(), u.map(str::to_owned))) {
            Some((server, user)) => {
                let who = user.map(|u| format!("{u} at {server}")).unwrap_or(server);
                kit::dot(p, pos2(x + 4.0, y + 13.0), t::ok(), 3.0);
                kit::clipped(p, pos2(x + 16.0, y + 13.0), &who, 13.0, "", t::soft(), r.right() - x - 120.0);
                let out = Rect::from_min_size(pos2(r.right() - 96.0, y), vec2(96.0, 28.0));
                if Btn::new("Sign out").size(11.0).show(ui, p, out, "set-sign-out").clicked() {
                    desk.sign_out();
                }
            }
            None => {
                kit::clipped(p, pos2(x, y + 13.0), "Not signed in: the crate's left column signs in", 13.0, "", t::muted(), r.right() - x);
            }
        }
        kit::hint(p, pos2(r.left(), r.bottom() - 6.0), Align2::LEFT_BOTTOM, &format!("WetOwl Desk {}", env!("CARGO_PKG_VERSION")));
        if changed {
            self.save_prefs(&ctx);
        }
    }
}

/// The keys as keycaps, grouped.
fn keys(p: &Painter, r: Rect) {
    let col_w = (r.width() - 32.0) / 2.0;
    for (g, (group, rows)) in KEYS.iter().enumerate() {
        let x = r.left() + (g % 2) as f32 * (col_w + 32.0);
        let y0 = r.top() + (g / 2) as f32 * 200.0;
        kit::section(p, pos2(x, y0), Align2::LEFT_TOP, group);
        for (i, (k, what)) in rows.iter().enumerate() {
            let y = y0 + 34.0 + i as f32 * 32.0;
            let mut kx = x;
            for cap in k.split(' ') {
                kx = keycap(p, pos2(kx, y), cap).right() + 5.0;
            }
            kit::text(p, pos2(x + 128.0, y), Align2::LEFT_CENTER, what, 13.0, "", t::muted());
        }
    }
}

/// One key, drawn as a cap; its rect.
fn keycap(p: &Painter, left_center: egui::Pos2, k: &str) -> Rect {
    let g = p.layout_no_wrap(k.to_owned(), egui::FontId::new(12.0, crate::paint::family("mono-semi")), t::text());
    let w = (g.size().x + 14.0).max(26.0);
    let r = Rect::from_min_size(pos2(left_center.x, left_center.y - 12.0), vec2(w, 24.0));
    p.rect_filled(r.translate(vec2(0.0, 2.0)), CornerRadius::same(5), Color32::from_black_alpha(120));
    p.rect(r, CornerRadius::same(5), Color32::from_rgb(0x26, 0x28, 0x30), Stroke::new(1.0, white(0.12)), StrokeKind::Inside);
    p.galley(r.center() - g.size() / 2.0, g, t::text());
    r
}
