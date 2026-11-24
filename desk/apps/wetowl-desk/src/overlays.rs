//! What comes over the page: the keys and the settings, as modals over a deeper scrim.
use eframe::egui::{self, Align2, Color32, CornerRadius, Painter, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::Desk;

use crate::paint::white;
use crate::ui::icons::Icon;
use crate::ui::kit::{self, Btn};
use crate::ui::motion;
use crate::ui::tokens::{self as t, Tone};
use crate::{App, Overlay};
use wo_deskcore::{DeskLayout, WaveStyle};

/// The keys, by where they act.
const KEYS: [(&str, &[(&str, &str)]); 4] = [
    ("Decks", &[("1 2", "Play A / B"), ("Q W", "Sync A / B"), ("Z X", "Start A / B in step"), ("F G", "The bass off and on, A / B"), ("[ ]", "A 16-beat loop on A / B"), ("F1–F8 ⇧", "The board's pads (BOARD)")]),
    ("Mixer and Auto DJ", &[("← →", "The crossfader"), ("⇧← ⇧→", "Nudge the master"), ("A", "The Auto DJ on and off"), ("M Space", "Mix now"), ("S N", "Not that: another record next"), ("P", "The plan: the move drawn out")]),
    ("Show", &[("K", "The Show page and the booth"), ("H B", "A hit · the blackout"), (", .", "The scene before / after"), ("J", "Mosh into the next"), ("L V", "Hold the scene · freeze")]),
    ("Desk", &[("?", "These keys"), ("Ctrl ,", "The settings"), ("C", "The stage and the Auto DJ folded away"), ("Ctrl L", "The WetOwl's layout or rekordbox's"), ("E", "The effects (rekordbox's)"), ("+ −", "The waveforms zoomed in / out"), ("Esc", "Close what is over the page")]),
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
            Overlay::Keys => vec2(780.0, 500.0),
            Overlay::Settings => vec2((full.width() - 80.0).clamp(620.0, 1120.0), 660.0),
            Overlay::Set => vec2((full.width() - 80.0).min(1180.0), (full.height() - 80.0).min(720.0)),
            Overlay::Controllers => vec2((full.width() - 80.0).min(1080.0), (full.height() - 80.0).min(680.0)),
            Overlay::Fx => vec2((full.width() - 80.0).min(1340.0), 150.0),
            Overlay::Rekordbox => vec2((full.width() - 80.0).clamp(620.0, 980.0), (full.height() - 80.0).min(700.0)),
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
                Overlay::Set => "Plan a set",
                Overlay::Controllers => "Controllers",
                Overlay::Fx => "Effects",
                Overlay::Rekordbox => "Follow rekordbox",
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
                Overlay::Set => self.set_page(desk, ui, &pp, body),
                Overlay::Controllers => self.controllers_page(desk, ui, &pp, body),
                Overlay::Fx => self.fx_panel(desk, ui, &pp, Rect::from_min_size(body.min, vec2(body.width(), 64.0))),
                Overlay::Rekordbox => self.rekordbox_page(desk, ui, &pp, body),
            }
        });
    }

    fn settings(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, whole: Rect) {
        let ctx = ui.ctx().clone();
        // two columns where there is room: the sound and the booth on the right
        let two = whole.width() >= 1000.0;
        let r = if two { Rect::from_min_size(whole.min, vec2(572.0, whole.height())) } else { whole };
        if two {
            let right = Rect::from_min_max(pos2(r.right() + 36.0, whole.top()), whole.max);
            p.line_segment([pos2(r.right() + 18.0, whole.top()), pos2(r.right() + 18.0, whole.bottom() - 24.0)], Stroke::new(1.0, white(0.06)));
            self.sound_settings(desk, ui, p, right);
        }
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
        y += 52.0;
        row(p, y, "Records' labels", "How much of a record its label covers");
        let labels = [0.22f32, 0.31, 0.5, 0.9];
        let at = labels.iter().position(|l| (l - self.prefs.disc_label).abs() < 0.03);
        if let Some(i) = kit::segmented(ui, p, seg_r(y, 300.0), &["Small", "Usual", "Large", "Picture"], at, Tone::Neutral, "set-label") {
            self.prefs.disc_label = labels[i];
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
        let more = Rect::from_min_size(pos2(r.right() - 120.0, y), vec2(120.0, 28.0));
        if Btn::new("Controllers…").size(11.0).show(ui, p, more, "set-controllers").on_hover_text("What is plugged in, its controls, and the monitor").clicked() {
            self.overlay = Some(Overlay::Controllers);
        }
        for (i, c) in controllers.iter().take(2).enumerate() {
            let cy = y + 13.0 + i as f32 * 22.0;
            crate::ui::icons::paint(p, Rect::from_center_size(pos2(x + 6.0, cy), vec2(13.0, 13.0)), Icon::Controller, if c.trouble.is_none() { t::ok() } else { t::warm() });
            let words = match &c.trouble {
                None => format!("{} · {}", c.name, c.layout),
                Some(why) => format!("{}: {why}", c.name),
            };
            kit::clipped(p, pos2(x + 16.0, cy), &words, 13.0, "", t::soft(), r.right() - x - 16.0);
        }
        y += 52.0;
        row(p, y, "rekordbox", "");
        let follow_words = match desk.following() {
            Some(v) => crate::rekordbox::summary(&v).1,
            None => "Off: the show can follow rekordbox".to_owned(),
        };
        kit::clipped(p, pos2(x, y + 13.0), &follow_words, 13.0, "", t::soft(), r.right() - x - 130.0);
        let rb = Rect::from_min_size(pos2(r.right() - 120.0, y), vec2(120.0, 28.0));
        if Btn::new("rekordbox…").size(11.0).show(ui, p, rb, "set-rekordbox").on_hover_text("Follow a set played in rekordbox: on and off, what it needs").clicked() {
            self.overlay = Some(Overlay::Rekordbox);
        }
        y += 44.0;
        row(p, y, "The house", "");
        match desk.house().map(|(s, u)| (s.trim_start_matches("https://").to_owned(), u.map(str::to_owned))) {
            Some((server, user)) => {
                let who = user.map(|u| format!("{u} at {server}")).unwrap_or(server);
                crate::ui::icons::paint(p, Rect::from_center_size(pos2(x + 6.0, y + 13.0), vec2(13.0, 13.0)), Icon::House, t::ok());
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
        if !two {
            kit::hint(p, pos2(r.left(), r.bottom() - 26.0), Align2::LEFT_BOTTOM, "Sound and headphones: a wider window shows them here");
        }
        // the build, and keeping it up to date
        let bw = 150.0;
        let state = self.updates.as_ref().map(wo_update::Updater::state);
        let words = format!("WetOwl Desk {} · {} · {}", env!("CARGO_PKG_VERSION"), wo_update::this_build().words(), state.as_ref().map_or_else(|| "updates off".into(), wo_update::State::words));
        let room = r.width() - if state.as_ref().is_some_and(|s| !matches!(s, wo_update::State::Off(_))) { bw + 12.0 } else { 0.0 };
        kit::clipped(p, pos2(r.left(), r.bottom() - 14.0), &words, t::HINT, "", t::faint(), room);
        if let (Some(u), Some(s)) = (&self.updates, &state)
            && !matches!(s, wo_update::State::Off(_))
        {
            let b = Rect::from_min_size(pos2(r.right() - bw, r.bottom() - 28.0), vec2(bw, 26.0));
            let ready = matches!(s, wo_update::State::Ready(_));
            let busy = matches!(s, wo_update::State::Checking | wo_update::State::Fetching(..));
            let word = if ready { "Restart now" } else { "Check for updates" };
            let resp = Btn::new(word).accent(ready).enabled(!busy).size(11.0).show(ui, p, b, "set-update");
            if resp.on_hover_text(s.words()).clicked() {
                if ready {
                    if u.restart() {
                        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                    }
                } else {
                    u.check_now();
                }
            }
        }
        if changed {
            self.save_prefs(&ctx);
        }
    }
}

/// The keys as keycaps, grouped.
fn keys(p: &Painter, r: Rect) {
    let col_w = (r.width() - 32.0) / 2.0;
    // each column's groups one under the other, as tall as they are
    let mut col_y = [r.top(); 2];
    for (g, (group, rows)) in KEYS.iter().enumerate() {
        let x = r.left() + (g % 2) as f32 * (col_w + 32.0);
        let y0 = col_y[g % 2];
        col_y[g % 2] = y0 + 34.0 + rows.len() as f32 * 32.0 + 18.0;
        kit::section(p, pos2(x, y0), Align2::LEFT_TOP, group);
        for (i, (k, what)) in rows.iter().enumerate() {
            let y = y0 + 34.0 + i as f32 * 32.0;
            let mut kx = x;
            for cap in k.split(' ') {
                kx = keycap(p, pos2(kx, y), cap).right() + 5.0;
            }
            kit::clipped(p, pos2(x + 128.0, y), what, 13.0, "", t::muted(), col_w - 128.0);
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

/// An output's channel pairs, as words: "1/2", "3/4", …
fn pairs(channels: u32) -> Vec<(u32, String)> {
    (0..(channels.max(2) / 2)).map(|i| (i * 2, format!("{}/{}", i * 2 + 1, i * 2 + 2))).collect()
}

impl App {
    /// Where the sound goes, and the headphones; and the booth's side panels.
    fn sound_settings(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let v = desk.audio_view();
        let mut y = r.top();
        let label_w = 120.0;
        let row = |p: &Painter, y: f32, name: &str| {
            kit::text(p, pos2(r.left(), y + 13.0), Align2::LEFT_CENTER, name, t::BODY, "", t::text());
        };
        let x = r.left() + label_w;
        let w = r.right() - x;
        let words = |p: &Painter, y: f32, s: &str, c: Color32| -> f32 {
            let g = p.layout(s.to_owned(), egui::FontId::new(12.0, crate::paint::family("")), c, w);
            let h = g.size().y;
            p.galley(pos2(x, y), g, c);
            h
        };
        kit::section(p, pos2(r.left(), y), Align2::LEFT_TOP, "Sound");
        y += 26.0;
        row(p, y, "Where it goes");
        let chosen = Some((!v.prefs.auto) as usize);
        if let Some(i) = kit::segmented(ui, p, Rect::from_min_size(pos2(x, y), vec2(w.min(300.0), 28.0)), &["Automatic", "Chosen"], chosen, Tone::Neutral, "set-sound-auto") {
            // chosen: what is routed now, to start from
            let start = v.route.clone().unwrap_or_default();
            desk.set_audio_choice(i == 0, if i == 0 { v.prefs.route.clone() } else { start });
        }
        y += 38.0;
        let names: Vec<String> = v.outputs.iter().map(|o| o.name.clone()).collect();
        let channels_of = |name: &Option<String>| -> u32 {
            match name {
                Some(n) => v.outputs.iter().find(|o| &o.name == n).map_or(2, |o| o.channels.max(2)),
                None => v.outputs.iter().find(|o| o.is_default).map_or(2, |o| o.channels.max(2)),
            }
        };
        if v.prefs.auto {
            if let Some(why) = &v.why {
                y += words(p, y, why, t::soft()) + 10.0;
            }
        } else {
            let mut route = v.prefs.route.clone();
            let mut changed = false;
            let own = "The system's own".to_owned();
            // the master: an output and its pair
            row(p, y, "Master");
            let mut child = ui.new_child(egui::UiBuilder::new().max_rect(Rect::from_min_size(pos2(x, y + 2.0), vec2(w, 26.0))));
            child.horizontal(|ui| {
                egui::ComboBox::from_id_salt("set-master-out").width(w - 110.0).selected_text(route.master.clone().unwrap_or(own.clone())).show_ui(ui, |ui| {
                    if ui.selectable_label(route.master.is_none(), &own).clicked() {
                        route.master = None;
                        route.master_ch = 0;
                        changed = true;
                    }
                    for n in &names {
                        if ui.selectable_label(route.master.as_ref() == Some(n), n).clicked() {
                            route.master = Some(n.clone());
                            route.master_ch = 0;
                            changed = true;
                        }
                    }
                });
                let ps = pairs(channels_of(&route.master));
                let now = ps.iter().find(|(c, _)| *c == route.master_ch).map_or("1/2".to_owned(), |p| p.1.clone());
                egui::ComboBox::from_id_salt("set-master-ch").width(80.0).selected_text(now).show_ui(ui, |ui| {
                    for (c, word) in &ps {
                        if ui.selectable_label(route.master_ch == *c, word).clicked() {
                            route.master_ch = *c;
                            changed = true;
                        }
                    }
                });
            });
            y += 38.0;
            // the headphones: none, split, or an output and its pair
            row(p, y, "Headphones");
            let mut child = ui.new_child(egui::UiBuilder::new().max_rect(Rect::from_min_size(pos2(x, y + 2.0), vec2(w, 26.0))));
            child.horizontal(|ui| {
                let shown = match &route.cue {
                    wo_deskcore::audio::Cue::None => "None".to_owned(),
                    wo_deskcore::audio::Cue::Split => "Split: left ear, master right".to_owned(),
                    wo_deskcore::audio::Cue::Device { name, .. } => name.clone().unwrap_or(own.clone()),
                };
                egui::ComboBox::from_id_salt("set-cue-out").width(w - 110.0).selected_text(shown).show_ui(ui, |ui| {
                    if ui.selectable_label(route.cue == wo_deskcore::audio::Cue::None, "None").clicked() {
                        route.cue = wo_deskcore::audio::Cue::None;
                        changed = true;
                    }
                    if ui.selectable_label(route.cue == wo_deskcore::audio::Cue::Split, "Split: left ear, master right").on_hover_text("One stereo jack and a splitter cable: the headphones in the left, the master (mono) in the right").clicked() {
                        route.cue = wo_deskcore::audio::Cue::Split;
                        changed = true;
                    }
                    for n in std::iter::once(None).chain(names.iter().cloned().map(Some)) {
                        let word = n.clone().unwrap_or(own.clone());
                        let on = matches!(&route.cue, wo_deskcore::audio::Cue::Device { name, .. } if *name == n);
                        if ui.selectable_label(on, word).clicked() {
                            // the master's own output: its next pair
                            let ch = if n == route.master { route.master_ch + 2 } else { 0 };
                            route.cue = wo_deskcore::audio::Cue::Device { name: n, ch };
                            changed = true;
                        }
                    }
                });
                if let wo_deskcore::audio::Cue::Device { name, ch } = &mut route.cue {
                    let ps = pairs(channels_of(name));
                    let now = ps.iter().find(|(c, _)| c == ch).map_or(format!("{}/{}", *ch + 1, *ch + 2), |p| p.1.clone());
                    egui::ComboBox::from_id_salt("set-cue-ch").width(80.0).selected_text(now).show_ui(ui, |ui| {
                        for (c, word) in &ps {
                            if ui.selectable_label(*ch == *c, word).clicked() {
                                *ch = *c;
                                changed = true;
                            }
                        }
                    });
                }
            });
            y += 40.0;
            if changed {
                desk.set_audio_choice(false, route);
            }
        }
        // how it is
        let st = v.state;
        let master = v.route.as_ref().and_then(|r| r.master.clone()).unwrap_or("the system's own output".into());
        let phones = match st.cue {
            wo_deskcore::audio::CueAt::Nowhere => "no headphones".to_owned(),
            wo_deskcore::audio::CueAt::Split => "the headphones split: left ear, master right".to_owned(),
            wo_deskcore::audio::CueAt::SameDevice => match v.route.as_ref().map(|r| &r.cue) {
                Some(wo_deskcore::audio::Cue::Device { ch, .. }) => format!("the headphones on its {}/{}", ch + 1, ch + 2),
                _ => "the headphones on it too".to_owned(),
            },
            wo_deskcore::audio::CueAt::SecondCard => "the headphones on a second card".to_owned(),
        };
        let now = format!("Now: {master} ({} channels), {phones}", st.channels);
        y += words(p, y, &now, t::muted()) + 6.0;
        if let Some(said) = &v.said {
            y += words(p, y, said, t::warm()) + 6.0;
        }
        if st.gaps > 0 && st.cue == wo_deskcore::audio::CueAt::SecondCard {
            y += words(p, y, &format!("The headphones' card ran dry {} times", st.gaps), t::warm()) + 6.0;
        }
        if v.headphones {
            let how = if v.console_mixes {
                "A deck's headphones button (CUE on the console) puts it in them, before its fader. The console's own HEADPHONES knobs blend them with the master."
            } else {
                "A deck's headphones button (CUE on the console) puts it in them, before its fader. The mixer's Cue · Mst knob blends them with the master; Phones is their level."
            };
            y += words(p, y, how, t::faint()) + 6.0;
        }
        y += 18.0;
        kit::section(p, pos2(r.left(), y), Align2::LEFT_TOP, "Booth");
        y += 26.0;
        let (stage_on, auto_on) = self.side_panels();
        row(p, y, "Show's picture");
        if let Some(i) = kit::segmented(ui, p, Rect::from_min_size(pos2(x, y), vec2(w.min(300.0), 28.0)), &["Shown", "Hidden"], Some(!stage_on as usize), Tone::Neutral, "set-side-stage") {
            if (i == 0) != stage_on {
                self.toggle_stage_panel(ui.ctx());
            }
        }
        y += 34.0;
        row(p, y, "Auto DJ panel");
        if let Some(i) = kit::segmented(ui, p, Rect::from_min_size(pos2(x, y), vec2(w.min(300.0), 28.0)), &["Shown", "Hidden"], Some(!auto_on as usize), Tone::Neutral, "set-side-auto") {
            if (i == 0) != auto_on {
                self.toggle_auto_dj_panel(ui.ctx());
            }
        }
        y += 34.0;
        y += words(p, y, "Beside the crate, each on its own (this layout's Auto DJ panel: rekordbox's has it hidden at first). C on the keyboard folds every side panel away and back.", t::faint()) + 16.0;
        row(p, y, "Crossfader");
        let i = Some((self.prefs.xf_assign() == [wo_deskcore::XfSide::Thru; 2]) as usize);
        // Auto Gain beside it (rekordbox's Mixer tab has the two together)
        let half = (w.min(300.0) - 12.0) / 2.0;
        let ag_x = x + half + 12.0;
        kit::text(p, pos2(ag_x, y - 9.0), Align2::LEFT_CENTER, "Auto Gain", 10.5, "", t::faint());
        let ag = Rect::from_min_size(pos2(ag_x, y), vec2(half, 28.0));
        if let Some(i) = kit::segmented(ui, p, ag, &["On", "Off"], Some(!self.prefs.auto_gain as usize), Tone::Neutral, "set-auto-gain") {
            self.prefs.auto_gain = i == 0;
            desk.set_auto_gain_on(self.prefs.auto_gain);
            self.save_prefs(ui.ctx());
        }
        ui.interact(ag, ui.scope_id().with("set-auto-gain-tip"), egui::Sense::hover()).on_hover_text(
            "Auto Gain, as rekordbox's: every record measured for its loudness (EBU R128) as it loads — a stick's all at once when it goes in — and its deck turned so all play equally loud (−14 LUFS). Each deck shows its value under TRIM: drag it to set it for that record (kept), double-click for the measured one. The master's limiter keeps a record turned up from clipping.",
        );
        if let Some(i) = kit::segmented(ui, p, Rect::from_min_size(pos2(x, y), vec2(half, 28.0)), &["On", "Off"], i, Tone::Neutral, "set-crossfader") {
            self.prefs.crossfader_off = false;
            self.prefs.crossfader_assign = if i == 1 { [wo_deskcore::XfSide::Thru; 2] } else { wo_deskcore::XfSide::USUAL };
            desk.set_crossfader_assign(self.prefs.crossfader_assign);
            self.save_prefs(ui.ctx());
        }
        y += 34.0;
        y += words(p, y, "Off, as in rekordbox with both channels assigned THRU: the channel faders do the mixing; the crossfader on screen, the keys and the controller's do nothing. The Auto DJ still mixes its own way. Each deck's side is also set by the 1 / 2 buttons beside the crossfader in rekordbox's layout.", t::faint()) + 16.0;
        row(p, y, "Tempo return");
        let secs = [2.0, 4.0, 8.0, 16.0, 32.0, 64.0];
        let at = secs.iter().position(|s| (s - desk.tempo_return_secs()).abs() < 0.01);
        if let Some(i) = kit::segmented(ui, p, Rect::from_min_size(pos2(x, y), vec2(w.min(340.0), 28.0)), &["2 s", "4", "8", "16", "32", "64 s"], at, Tone::Neutral, "set-tempo-return") {
            desk.set_tempo_return_secs(secs[i]);
            self.prefs.tempo_return_secs = desk.tempo_return_secs();
            self.save_prefs(ui.ctx());
        }
        y += 34.0;
        y += words(p, y, "How long a deck's 0 % button (under its tempo fader) takes it back to the record's own tempo, eased so the room does not hear it turn. A hand on the fader meanwhile stops it there.", t::faint()) + 22.0;

        kit::section(p, pos2(r.left(), y), Align2::LEFT_TOP, "Waveforms and layout");
        y += 26.0;
        let seg = |y: f32, most: f32| Rect::from_min_size(pos2(x, y), vec2(w.min(most), 28.0));
        row(p, y, "Layout");
        let layouts = [DeskLayout::WetOwl, DeskLayout::Club];
        let at = layouts.iter().position(|l| *l == self.prefs.layout);
        if let Some(i) = kit::segmented(ui, p, seg(y, 300.0), &["WetOwl", "rekordbox"], at, Tone::Neutral, "set-layout") {
            self.prefs.layout = layouts[i];
            self.save_prefs(ui.ctx());
        }
        y += 40.0;
        row(p, y, "Colours");
        let at = WaveStyle::ALL.iter().position(|w| *w == self.prefs.wave_style);
        if let Some(i) = kit::segmented(ui, p, seg(y, 340.0), &WaveStyle::ALL.map(WaveStyle::name), at, Tone::Neutral, "set-wave") {
            self.prefs.wave_style = WaveStyle::ALL[i];
            self.save_prefs(ui.ctx());
        }
        y += 40.0;
        row(p, y, "Bar groups");
        if let Some(i) = kit::segmented(ui, p, seg(y, 300.0), &["Marked", "Beats only"], Some(!self.prefs.bar_groups as usize), Tone::Neutral, "set-groups") {
            self.prefs.bar_groups = i == 0;
            self.save_prefs(ui.ctx());
        }
        y += 34.0;
        words(p, y, "rekordbox's layout and its waveform colours (3Band, RGB, Blue); a rekordbox stick's records show rekordbox's own waveforms. Ctrl L swaps the layout.", t::faint());
    }
}
