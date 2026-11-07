//! The booth's panels — top bar, overviews, waveforms, decks, mixer, crate, stage card,
//! Auto DJ — on the kit (ui::kit), where ui::layout puts them.
use std::hash::{Hash, Hasher};

use eframe::egui::{self, Align2, Color32, CornerRadius, Mesh, Painter, Rect, Sense, Shape, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::theme;
use wo_deskcore::parts::{Part, Stems};
use wo_deskcore::{Desk, Record, Shelf, ShowHand, Snapshot, Style, Transition};

use crate::paint::{alpha, band, col, label_sized, label_width, mmss, pad_colour, pad_name, white};
use crate::show::Page;
use crate::ui::icons::Icon;
use crate::ui::kit::{self, Btn, alpha_of};
use crate::ui::motion::{self, Ease};
use crate::ui::tokens::{self as t, Tone, mix};
use crate::{App, Overlay, Sort};

/// A crate row's height.
const ROW: f32 = 36.0;

impl App {
    /// The whole booth over the glass, for this frame's snapshot.
    pub(crate) fn draw(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, full: Rect, s: &Snapshot) {
        let l = crate::ui::layout(full);
        self.top_bar(desk, ui, p, l.top, s);
        self.overviews(desk, ui, p, l.overview, s);
        // the page under them fades in when it changes
        let k = motion::appear(ui.ctx(), egui::Id::unique(("page", self.page as u8)), motion::EMPHASIS);
        let mut pp = p.clone();
        pp.multiply_opacity(k);
        ui.multiply_opacity(k);
        let p = &pp;
        if self.page == Page::Show {
            self.show_page(desk, ui, p, l.page, s);
            ui.set_opacity(1.0);
            return;
        }
        if self.plan_open {
            self.plan(desk, ui, p, l.waves, s);
        } else {
            self.waves(desk, ui, p, l.waves, s);
        }
        for d in 0..2 {
            self.deck(desk, ui, p, l.decks[d], s, d);
        }
        self.mixer(desk, ui, p, l.mixer, s);
        self.crate_(desk, ui, p, l.crate_, s);
        self.stage_card(desk, ui, p, l.stage);
        self.auto_dj(desk, ui, p, l.auto, s);
        ui.set_opacity(1.0);
        self.drag_ghost(desk, ui);
    }

    fn top_bar(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        kit::panel(p, r, false);
        // the mark: the one loud thing
        let logo = Rect::from_min_size(pos2(r.left() + 9.0, r.center().y - 17.0), vec2(104.0, 34.0));
        p.rect_filled(logo, CornerRadius::same(7), col(theme::RED));
        let w = kit::text(p, pos2(logo.left() + 10.0, logo.center().y + 1.0), Align2::LEFT_CENTER, "WET", 27.0, "mark", Color32::WHITE);
        let ball = Rect::from_min_size(pos2(w.right() + 1.0, logo.center().y - 11.0), vec2(22.0, 22.0));
        p.image(self.ball.id(), ball, Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)), Color32::WHITE);
        kit::text(p, pos2(ball.right() + 1.0, logo.center().y + 1.0), Align2::LEFT_CENTER, "WL", 27.0, "mark", Color32::WHITE);

        // the rooms, an underline gliding to the one up
        let mut x = logo.right() + 18.0;
        let mut here = None;
        for (i, (word, page)) in [("Booth", Page::Booth), ("Show", Page::Show)].into_iter().enumerate() {
            let tr = Rect::from_min_size(pos2(x, r.top()), vec2(label_width(p, word, 13.0) + 32.0, r.height()));
            let resp = ui.interact(tr, ui.scope_id().with(("tab", i)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
            let h = motion::tween_bool(ui.ctx(), resp.id.with("h"), resp.hovered(), motion::QUICK, motion::STANDARD);
            let on = motion::tween_bool(ui.ctx(), resp.id.with("on"), self.page == page, motion::STANDARD, motion::STANDARD);
            label_sized(p, tr.center(), Align2::CENTER_CENTER, word, 13.0, mix(mix(Color32::from_rgb(0x8D, 0x91, 0x9B), t::soft(), h), t::text(), on));
            if resp.clicked() {
                self.page = page;
            }
            if self.page == page {
                here = Some(tr);
            }
            x = tr.right();
        }
        if let Some(tr) = here {
            let ux = motion::spring(ui.ctx(), ui.scope_id().with("tab-x"), tr.left() + 12.0, 0.2);
            let uw = motion::spring(ui.ctx(), ui.scope_id().with("tab-w"), tr.width() - 24.0, 0.2);
            p.rect_filled(Rect::from_min_size(pos2(ux, r.bottom() - 3.0), vec2(uw, 2.5)), CornerRadius::same(1), col(theme::RED));
        }

        // the middle: the master's tempo, its deck, a dot on its beat; the set's time
        let m = s.decks.iter().position(|d| d.master).unwrap_or(0);
        let mid = r.center();
        let bpm = kit::text(p, pos2(mid.x - 4.0, mid.y), Align2::RIGHT_CENTER, &format!("{:.2}", s.master_bpm), t::DISPLAY_M, "mono-semi", t::text());
        kit::label(p, pos2(bpm.left() - 10.0, mid.y), Align2::RIGHT_CENTER, "Master");
        let chip = kit::deck_chip(p, pos2(bpm.right() + 10.0, mid.y), m);
        let v = &s.decks[m];
        let pulse = if v.playing && v.bpm > 1.0 {
            let (_, lines) = desk.waveform(m, v.heard, 400.0, 40.0, 100.0);
            let phase = lines.beats.iter().chain(lines.bars.iter()).filter(|&&x| x <= 200.0).map(|x| (200.0 - x) / 100.0).fold(f32::MAX, f32::min);
            let secs = phase * 60.0 / v.bpm as f32;
            (1.0 - secs / 0.12).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let dot_c = pos2(chip.right() + 13.0, mid.y);
        p.circle_filled(dot_c, 6.0, alpha_of(t::deck(m), 0.22 * pulse));
        p.circle_filled(dot_c, 3.5, mix(Color32::from_rgb(0x3A, 0x3E, 0x47), t::tint(m), if v.playing { 0.35 + 0.65 * pulse } else { 0.0 }));
        let set = s.set_seconds as u64;
        let st = kit::label(p, pos2(dot_c.x + 30.0, mid.y), Align2::LEFT_CENTER, "Set");
        kit::text(p, pos2(st.right() + 8.0, mid.y), Align2::LEFT_CENTER, &format!("{}:{:02}:{:02}", set / 3600, set / 60 % 60, set % 60), 14.0, "mono", t::soft());

        // the right: settings, keys, one status pill, the Auto DJ
        let y = r.center().y;
        let mut rx = r.right() - 9.0;
        let gear = Rect::from_min_size(pos2(rx - 32.0, y - 16.0), vec2(32.0, 32.0));
        if Btn::new("").icon(Icon::Settings).quiet().on(self.overlay == Some(Overlay::Settings)).show(ui, p, gear, "settings").on_hover_text("Settings  (Ctrl ,)").clicked() {
            self.overlay = if self.overlay == Some(Overlay::Settings) { None } else { Some(Overlay::Settings) };
        }
        let keys = Rect::from_min_size(pos2(gear.left() - 36.0, y - 16.0), vec2(32.0, 32.0));
        if Btn::new("").icon(Icon::Keys).quiet().on(self.overlay == Some(Overlay::Keys)).show(ui, p, keys, "keys").on_hover_text("The keys  (?)").clicked() {
            self.overlay = if self.overlay == Some(Overlay::Keys) { None } else { Some(Overlay::Keys) };
        }
        rx = keys.left() - 12.0;
        let pill = self.status_pill(desk, ui, p, pos2(rx, y), s);
        let auto = Rect::from_min_size(pos2(pill.left() - 12.0 - 108.0, y - 16.0), vec2(108.0, 32.0));
        if Btn::new("Auto DJ").icon(Icon::Dot).tone(Tone::Ok).on(s.auto).show(ui, p, auto, "auto").on_hover_text("The Auto DJ mixes the next record in  (A)").clicked() {
            desk.set_auto(!s.auto);
        }
    }

    /// The house, the controllers, the stage and the sound's load as one pill, its right
    /// edge at `right`; the details on hover.
    fn status_pill(&self, desk: &Desk, ui: &mut Ui, p: &Painter, right: egui::Pos2, s: &Snapshot) -> Rect {
        let house = desk.house().map(|(sv, u)| (sv.trim_start_matches("https://").to_owned(), u.map(str::to_owned)));
        let controllers = desk.controllers();
        let stage = desk.stage();
        let pct = (s.load.average * 100.0).round();
        let words = format!("{pct:.0}%");
        let dots: Vec<(Color32, &str)> = vec![
            (if house.is_some() { t::ok() } else { t::faint() }, "House"),
            (
                if controllers.is_empty() {
                    t::faint()
                } else if controllers.iter().all(|c| c.trouble.is_none()) {
                    t::ok()
                } else {
                    t::warm()
                },
                "Gear",
            ),
            (
                if stage.stages > 0 {
                    t::ok()
                } else if stage.starting {
                    t::warm()
                } else {
                    t::faint()
                },
                "Stage",
            ),
        ];
        let mut w = 14.0;
        for (_, word) in &dots {
            w += 13.0 + label_width(p, word, 10.5) + 12.0;
        }
        let dsp_w = label_width(p, "DSP", 10.5) + 8.0 + 34.0;
        w += dsp_w + 6.0;
        let r = Rect::from_min_size(pos2(right.x - w, right.y - 15.0), vec2(w, 30.0));
        let resp = ui.interact(r, ui.scope_id().with("status"), Sense::hover());
        let h = motion::tween_bool(ui.ctx(), resp.id.with("h"), resp.hovered(), motion::QUICK, motion::STANDARD);
        p.rect(r, CornerRadius::same(15), mix(Color32::from_white_alpha(7), Color32::from_white_alpha(14), h), Stroke::new(1.0, mix(t::edge_rest(), t::edge_hover(), h)), StrokeKind::Inside);
        let mut x = r.left() + 14.0;
        for (c, word) in &dots {
            kit::dot(p, pos2(x + 3.5, r.center().y), *c, 3.0);
            let l = label_sized(p, pos2(x + 13.0, r.center().y), Align2::LEFT_CENTER, word, 10.5, t::muted());
            x = l.right() + 12.0;
        }
        let l = label_sized(p, pos2(x, r.center().y), Align2::LEFT_CENTER, "DSP", 10.5, t::label());
        let hot = s.load.average > 0.7;
        kit::text(p, pos2(l.right() + 8.0, r.center().y), Align2::LEFT_CENTER, &words, 11.5, "mono", if hot { t::warm() } else { t::soft() });
        resp.on_hover_ui(|ui| {
            ui.set_min_width(260.0);
            let line = |ui: &mut Ui, head: &str, body: String| {
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new(head).color(t::label()).size(11.0));
                    ui.label(egui::RichText::new(body).color(t::text()).size(12.5));
                });
            };
            line(ui, "House", match &house {
                Some((sv, Some(u))) => format!("{u} at {sv}"),
                Some((sv, None)) => sv.clone(),
                None => "not signed in".into(),
            });
            if controllers.is_empty() {
                line(ui, "Gear", "no controller found".into());
            }
            for c in &controllers {
                line(ui, "Gear", match &c.trouble {
                    None => format!("{} · {}", c.name, c.layout),
                    Some(why) => format!("{}: {why}", c.name),
                });
            }
            line(ui, "Stage", if stage.stages > 0 {
                format!("showing{}", if stage.rust { " (Rust)" } else { "" })
            } else if stage.starting {
                "starting…".into()
            } else {
                "closed".into()
            });
            line(ui, "DSP", format!("{pct:.0}% of the sound's time, {:.0}% at worst; {} late", s.load.worst * 100.0, s.load.late));
        });
        r
    }

    pub(crate) fn overviews(&self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        kit::panel(p, r, true);
        for d in 0..2 {
            let y = r.top() + 10.0 + d as f32 * 25.0;
            kit::deck_chip(p, pos2(r.left() + 12.0, y + 10.0), d);
            let bar = Rect::from_min_max(pos2(r.left() + 42.0, y), pos2(r.right() - 96.0, y + 20.0));
            let v = &s.decks[d];
            let len = v.length.max(1.0);
            let cols = desk.overview(d, (bar.width() / 3.0) as usize);
            let mut mesh = Mesh::default();
            band(&mut mesh, bar.left(), 3.0, bar.center().y, cols.iter().map(|c| c[0] * 9.5 + 0.8), alpha(theme::DECKS[d], 0.85));
            p.add(mesh);
            let at = bar.left() + bar.width() * (v.heard / len).clamp(0.0, 1.0) as f32;
            // what was heard, dimmed, with a soft edge up to the playhead
            let edge = 18.0f32.min(at - bar.left());
            p.rect_filled(Rect::from_min_max(bar.min, pos2(at - edge, bar.bottom())), CornerRadius::ZERO, alpha(theme::GROUND, 0.55));
            if edge > 0.0 {
                let mut g = Mesh::default();
                let (c0, c1) = (alpha(theme::GROUND, 0.55), alpha(theme::GROUND, 0.0));
                g.colored_vertex(pos2(at - edge, bar.top()), c0);
                g.colored_vertex(pos2(at, bar.top()), c1);
                g.colored_vertex(pos2(at, bar.bottom()), c1);
                g.colored_vertex(pos2(at - edge, bar.bottom()), c0);
                g.add_triangle(0, 1, 2);
                g.add_triangle(0, 2, 3);
                p.add(g);
            }
            if let Some((a, b)) = v.looped {
                let xa = bar.left() + bar.width() * (a / len) as f32;
                let xb = bar.left() + bar.width() * (b / len) as f32;
                p.rect_filled(Rect::from_min_max(pos2(xa, bar.top()), pos2(xb.max(xa + 2.0), bar.bottom())), CornerRadius::same(2), alpha(theme::DECKS[d], 0.3));
            }
            for pad in v.pads.iter().flatten() {
                let x = bar.left() + bar.width() * (pad.at / len) as f32;
                let c = col(pad_colour(pad.auto));
                p.rect_filled(Rect::from_min_size(pos2(x - 1.0, bar.top()), vec2(2.0, bar.height())), CornerRadius::ZERO, alpha_of(c, 0.9));
            }
            p.rect_filled(Rect::from_min_size(pos2(at - 3.0, bar.top() - 1.0), vec2(6.0, 22.0)), CornerRadius::same(2), white(0.12));
            p.rect_filled(Rect::from_min_size(pos2(at - 1.0, bar.top() - 1.0), vec2(2.0, 22.0)), CornerRadius::ZERO, Color32::WHITE);
            // hover: a ghost playhead and its time; a click (or a drag let go) goes there
            let resp = ui.interact(bar.expand2(vec2(0.0, 2.0)), ui.scope_id().with(("overview", d)), Sense::click_and_drag()).on_hover_cursor(egui::CursorIcon::PointingHand);
            let ghost = resp.hover_pos().or(resp.interact_pointer_pos()).filter(|_| resp.hovered() || resp.dragged()).map(|pos| pos.x.clamp(bar.left(), bar.right()));
            let time_at = |x: f32| (x - bar.left()) as f64 / bar.width() as f64 * len;
            match ghost {
                Some(x) => {
                    p.rect_filled(Rect::from_min_size(pos2(x - 0.75, bar.top()), vec2(1.5, bar.height())), CornerRadius::ZERO, white(0.5));
                    kit::text(p, pos2(r.right() - 12.0, y + 10.0), Align2::RIGHT_CENTER, &format!("→ {}", mmss(time_at(x))), 12.0, "mono", t::high());
                    if (resp.clicked() || resp.drag_stopped()) && v.length > 0.0 {
                        desk.seek_to(d, time_at(x));
                    }
                }
                None => {
                    kit::text(p, pos2(r.right() - 12.0, y + 10.0), Align2::RIGHT_CENTER, &format!("−{}", mmss(v.length - v.heard)), 12.0, "mono", t::muted());
                }
            }
        }
    }

    fn waves(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        kit::panel(p, r, true);
        let clip = p.with_clip_rect(r.shrink(1.0));
        // scroll over the waveforms zooms them
        let over = ui.interact(r, ui.scope_id().with("waves"), Sense::hover());
        if over.hovered() {
            let dy = ui.input(|i| i.smooth_scroll_delta.y);
            if dy.abs() > 0.1 {
                self.zoom = (self.zoom * 1.0015f32.powf(dy)).clamp(40.0, 320.0);
            }
        }
        let zoom = motion::spring(ui.ctx(), ui.scope_id().with("zoom"), self.zoom, 0.16);
        let phase_h = 16.0;
        let lane_h = (r.height() - 16.0 - phase_h) / 2.0;
        for d in 0..2 {
            let w = Rect::from_min_size(pos2(r.left(), r.top() + 8.0 + d as f32 * (lane_h + phase_h)), vec2(r.width(), lane_h));
            let v = &s.decks[d];
            let (cols, lines) = desk.waveform(d, v.heard, w.width(), 3.0, zoom);
            for x in &lines.beats {
                clip.line_segment([pos2(w.left() + x, w.top()), pos2(w.left() + x, w.bottom())], Stroke::new(1.0, white(0.08)));
            }
            for x in &lines.bars {
                clip.line_segment([pos2(w.left() + x, w.top()), pos2(w.left() + x, w.bottom())], Stroke::new(1.5, white(0.24)));
            }
            // a record loaded grows from the centre line
            let grow = motion::appear(ui.ctx(), ui.scope_id().with(("wave", d, v.record.id)), 0.32);
            let a = (w.height() / 2.0 - 4.0) * grow;
            let mid = w.center().y;
            let mut mesh = Mesh::default();
            band(&mut mesh, w.left(), 3.0, mid, cols.iter().map(|c| c[0] * a * 0.92), alpha(theme::DECKS[d], 0.92));
            band(&mut mesh, w.left(), 3.0, mid, cols.iter().map(|c| c[1] * a * 0.55), alpha(theme::TINTS[d], 0.9));
            band(&mut mesh, w.left(), 3.0, mid, cols.iter().map(|c| c[2] * a * 0.3), alpha(theme::HIGH, 0.85));
            clip.add(mesh);
            // the loop on it
            let looped = motion::tween_bool(ui.ctx(), ui.scope_id().with(("looped", d)), v.looped.is_some(), motion::STANDARD, motion::STANDARD);
            if let Some((a0, b0)) = v.looped.or_else(|| (looped > 0.0).then_some((0.0, 0.0))).filter(|(a, b)| b > a) {
                let base = if v.rate > 0.0 { v.bpm / v.rate } else { v.bpm };
                let px = zoom as f64 * base / 60.0;
                let xa = w.center().x + ((a0 - v.heard) * px) as f32;
                let xb = w.center().x + ((b0 - v.heard) * px) as f32;
                let lr = Rect::from_min_max(pos2(xa, w.top()), pos2(xb, w.bottom()));
                clip.rect_filled(lr, CornerRadius::ZERO, alpha(theme::DECKS[d], 0.14 * looped));
                for x in [xa, xb] {
                    clip.rect_filled(Rect::from_min_size(pos2(x - 1.0, w.top()), vec2(2.0, w.height())), CornerRadius::ZERO, alpha(theme::DECKS[d], 0.85 * looped));
                }
            }
            clip.rect_filled(Rect::from_min_max(w.min, pos2(w.center().x, w.bottom())), CornerRadius::ZERO, alpha(theme::GROUND, 0.38));
            for (x, i, pad) in &lines.pads {
                let c = col(pad_colour(pad.auto));
                let x = w.left() + x;
                clip.rect_filled(Rect::from_min_size(pos2(x - 1.0, w.top()), vec2(2.0, w.height())), CornerRadius::ZERO, c);
                clip.add(Shape::convex_polygon(vec![pos2(x - 1.0, w.top()), pos2(x + 11.0, w.top()), pos2(x - 1.0, w.top() + 11.0)], c, Stroke::NONE));
                label_sized(&clip, pos2(x + 14.0, w.top() + 5.0), Align2::LEFT_TOP, &format!("{} {}", i + 1, pad_name(pad.auto)), 10.5, c);
            }
            clip.rect_filled(Rect::from_center_size(pos2(w.center().x, mid), vec2(6.0, w.height())), CornerRadius::ZERO, white(0.1));
            clip.rect_filled(Rect::from_center_size(pos2(w.center().x, mid), vec2(2.0, w.height())), CornerRadius::ZERO, Color32::WHITE);
            // the lane's tab: its deck and how it is
            let state = if v.decoded <= 0.0 {
                "Loading…".to_owned()
            } else if v.decoded < 1.0 {
                format!("Loading {:.0}%", v.decoded * 100.0)
            } else if v.master && v.playing {
                "Master".to_owned()
            } else if v.synced {
                "In step".to_owned()
            } else if v.playing {
                "Playing".to_owned()
            } else {
                "Parked".to_owned()
            };
            let tab = Rect::from_min_size(pos2(w.left() + 10.0, w.top() + 6.0), vec2(36.0 + label_width(p, &state, 10.5), 24.0));
            kit::glass_tab(p, tab);
            kit::deck_chip(p, pos2(tab.left() + 4.0, tab.center().y), d);
            label_sized(p, pos2(tab.left() + 30.0, tab.center().y), Align2::LEFT_CENTER, &state, 10.5, t::soft());
        }
        // between the lanes: how far apart the beats are, while both play in step
        let f = s.decks.iter().find(|d| d.synced && d.playing).filter(|_| s.decks.iter().all(|d| d.playing));
        let shown = motion::tween_bool(ui.ctx(), ui.scope_id().with("phase"), f.is_some(), motion::STANDARD, motion::STANDARD);
        if shown > 0.01 {
            let ms = f.map_or(0.0, |f| f.phase_ms as f32);
            let c = pos2(r.center().x, r.top() + 8.0 + lane_h + phase_h / 2.0);
            let track = Rect::from_center_size(c, vec2(160.0, 4.0));
            let pill = Rect::from_center_size(c, vec2(300.0, 16.0));
            p.rect_filled(pill, CornerRadius::same(8), alpha(theme::GROUND, 0.88 * shown));
            label_sized(p, pos2(pill.left() + 10.0, c.y), Align2::LEFT_CENTER, "Phase", 10.0, alpha_of(t::label(), shown));
            p.rect_filled(track, CornerRadius::same(2), alpha_of(col(theme::EDGE), shown));
            p.rect_filled(Rect::from_center_size(c, vec2(1.0, 8.0)), CornerRadius::ZERO, white(0.3 * shown));
            let off = motion::spring(ui.ctx(), ui.scope_id().with("phase-x"), (ms / 20.0).clamp(-1.0, 1.0) * 78.0, 0.2);
            let ok = ms.abs() < 5.0;
            p.rect_filled(Rect::from_center_size(pos2(c.x + off, c.y), vec2(4.0, 10.0)), CornerRadius::same(2), alpha_of(if ok { t::ok() } else { t::warm() }, shown));
            kit::text(p, pos2(pill.right() - 10.0, c.y), Align2::RIGHT_CENTER, &format!("{ms:+.1} ms"), 10.5, "mono", alpha_of(Color32::from_rgb(0xCF, 0xF5, 0xDF), shown));
        }
    }

    fn deck(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        kit::panel(p, r, false);
        let v = &s.decks[d];
        let inner = r.shrink(t::INSET);
        let ctx = ui.ctx().clone();

        // a record dragged from the crate: this deck lights where it can take it
        if let Some(rec) = egui::DragAndDrop::payload::<Record>(&ctx) {
            let over = ctx.pointer_latest_pos().is_some_and(|pos| r.contains(pos));
            let ok = !v.playing && rec.playable();
            let k = motion::tween_bool(&ctx, ui.scope_id().with(("drop", d)), over && ok, 0.12, 0.12);
            p.rect_stroke(r, CornerRadius::same(t::R_PANEL), Stroke::new(1.0 + 1.5 * k, alpha_of(t::deck(d), if ok { 0.3 + 0.6 * k } else { 0.12 })), StrokeKind::Inside);
            if over && ok && ctx.input(|i| i.pointer.any_released()) {
                desk.load_by_hand(d, (*rec).clone());
                egui::DragAndDrop::clear_payload(&ctx);
                self.toasts.say(format!("{} on deck {}", rec.title, ["A", "B"][d]), Tone::Deck(d));
            }
        }

        // the header: sleeve, deck, title, artist; the readouts (smaller in a narrow deck)
        let compact = inner.width() < 600.0;
        let side = if compact { 60.0 } else { 72.0 };
        let sleeve = Rect::from_min_size(inner.min, vec2(side, side));
        let cover = self.sleeves.of(&ctx, desk, &v.record);
        kit::sleeve(ui, p, sleeve, cover, &v.record.initials(), col(theme::sleeve(v.record.id)), 8, ("sleeve", d, v.record.id));
        if v.decoded < 1.0 {
            let bar = Rect::from_min_size(pos2(sleeve.left() + 6.0, sleeve.bottom() - 8.0), vec2(sleeve.width() - 12.0, 3.0));
            p.rect_filled(bar, CornerRadius::same(1), Color32::from_black_alpha(140));
            p.rect_filled(Rect::from_min_size(bar.min, vec2(bar.width() * v.decoded, 3.0)), CornerRadius::same(1), t::tint(d));
        }
        let (time_size, bpm_size) = if compact { (17.0, 24.0) } else { (t::DISPLAY_M, t::DISPLAY_L) };
        let left = kit::text(p, pos2(inner.right(), inner.top() + 15.0), Align2::RIGHT_CENTER, &format!("−{}", mmss(v.length - v.heard)), time_size, "mono", t::text());
        kit::text(p, pos2(inner.right(), inner.top() + 44.0), Align2::RIGHT_CENTER, &mmss(v.heard), 12.0, "mono", t::label());
        let sep = left.left().min(inner.right() - if compact { 84.0 } else { 112.0 }) - 14.0;
        p.line_segment([pos2(sep, inner.top() + 8.0), pos2(sep, inner.top() + 56.0)], Stroke::new(1.0, col(theme::EDGE)));
        let bpm = kit::text(p, pos2(sep - 14.0, inner.top() + 18.0), Align2::RIGHT_CENTER, &format!("{:.2}", v.bpm), bpm_size, "mono-semi", t::text());
        let pitch = (v.rate - 1.0) * 100.0;
        kit::text(p, pos2(sep - 14.0, inner.top() + 47.0), Align2::RIGHT_CENTER, &format!("{pitch:+.2}%  {}", if v.record.key.is_empty() { "—" } else { &v.record.key }), 12.0, "mono", t::muted());
        // title and artist rise into place when a record loads
        let k = motion::appear(&ctx, ui.scope_id().with(("title", d, v.record.id)), motion::EMPHASIS);
        let dy = 6.0 * (1.0 - k);
        let x = sleeve.right() + 16.0;
        let chip = kit::deck_chip(p, pos2(x, inner.top() + 18.0), d);
        let room = bpm.left() - chip.right() - 28.0;
        kit::clipped(p, pos2(chip.right() + 10.0, inner.top() + 18.0 + dy), &v.record.title, t::TITLE, "semi", alpha_of(t::text(), k), room);
        kit::clipped(p, pos2(x, inner.top() + 45.0 + dy), &v.record.artist, t::BODY, "", alpha_of(t::muted(), k), bpm.left() - x - 28.0);
        // what is known of the record: lit where it is there
        let mut mx = x;
        for (i, (word, tip)) in [("STEMS", "Its stems: the parts and the stem moves"), ("BEATS", "Its beat grid"), ("FORM", "Its sections: intro, drops, breakdowns"), ("VOICE", "Where it sings")].into_iter().enumerate() {
            let c = if v.marks[i] { t::soft() } else { alpha_of(t::faint(), 0.6) };
            let r = kit::text(p, pos2(mx, inner.top() + 66.0), Align2::LEFT_CENTER, word, 8.5, "mono-semi", c);
            ui.interact(r.expand(2.0), ui.scope_id().with(("mark", d, i)), Sense::hover()).on_hover_text(format!("{tip}: {}", if v.marks[i] { "here" } else { "not known" }));
            mx = r.right() + 8.0;
        }

        // the body: transport | hot cues | pitch; the loop row under it
        let body = Rect::from_min_max(pos2(inner.left(), inner.top() + 72.0 + 16.0), inner.max);
        let pitch_r = Rect::from_min_max(pos2(body.right() - 48.0, body.top()), body.max);
        let main = Rect::from_min_max(body.min, pos2(pitch_r.left() - 16.0, body.bottom() - 26.0 - 12.0));
        let loop_r = Rect::from_min_max(pos2(body.left(), main.bottom() + 12.0), pos2(pitch_r.left() - 16.0, body.bottom()));
        self.transport(desk, ui, p, Rect::from_min_size(main.min, vec2(160.0, main.height())), s, d);
        self.pads(desk, ui, p, Rect::from_min_max(pos2(main.left() + 176.0, main.top()), main.max), s, d);
        self.loop_row(desk, ui, p, loop_r, s, d);
        self.pitch(desk, ui, p, pitch_r, s, d);
    }

    fn transport(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        let (bw, g) = ((r.width() - 8.0) / 2.0, 8.0);
        let small = ((r.height() - 44.0 - 3.0 * g) / 3.0).clamp(24.0, 30.0);
        let cell = |c: usize, y: f32, h: f32| Rect::from_min_size(pos2(r.left() + c as f32 * (bw + g), r.top() + y), vec2(bw, h));
        // CUE acts on press and on release (a preview runs while it is held)
        let cue_r = cell(0, 0.0, 44.0);
        let (cue_id, cue) = kit::held(ui, cue_r, (d, "cue"));
        let down = cue.is_pointer_button_down_on();
        if down && !self.cue_held[d] {
            desk.cue_down(d);
        } else if !down && self.cue_held[d] {
            desk.cue_up(d);
        }
        self.cue_held[d] = down;
        let on_cue = v.cue.is_some_and(|c| (c - v.heard).abs() < 0.06);
        Btn::new("Cue").icon(Icon::Cue).tone(Tone::Deck(d)).on(down || (on_cue && !v.playing)).size(12.5).paint(ui, p, cue_r, cue_id, &cue);
        let play = Btn::new("").icon(if v.playing { Icon::Pause } else { Icon::Play }).tone(Tone::Deck(d)).on(v.playing);
        if play.show(ui, p, cell(1, 0.0, 44.0), (d, "play")).on_hover_text(["Play A  (1)", "Play B  (2)"][d]).clicked() {
            desk.toggle_play(d);
        }
        let y1 = 44.0 + g;
        if Btn::new("Sync").icon(Icon::Sync).tone(Tone::Ok).on(v.synced).show(ui, p, cell(0, y1, small), (d, "sync")).clicked() {
            desk.toggle_sync(d);
        }
        if Btn::new("Key lock").icon(Icon::Lock).on(v.keylock).show(ui, p, cell(1, y1, small), (d, "kl")).clicked() {
            desk.toggle_keylock(d);
        }
        let y2 = y1 + small + g;
        let killed = v.eq[0] <= 0.01;
        if Btn::new("Bass").icon(Icon::Kill).tone(Tone::Danger).on(killed).show(ui, p, cell(0, y2, small), (d, "kill")).on_hover_text(["The bass off and on  (F)", "The bass off and on  (G)"][d]).clicked() {
            desk.kill(d, 0);
        }
        if Btn::new("Brake").icon(Icon::Brake).quiet().show(ui, p, cell(1, y2, small), (d, "brake")).clicked() {
            desk.brake(d);
        }
        // the nudges bend the record while held
        let y3 = y2 + small + g;
        let mut nudge = 0i8;
        for (k, (word, icon, dir)) in [("Nudge", Icon::ChevronLeft, -1i8), ("Nudge", Icon::ChevronRight, 1)].into_iter().enumerate() {
            let nr = cell(k, y3, small);
            let (id, resp) = kit::held(ui, nr, (d, "nudge", k));
            let down = resp.is_pointer_button_down_on();
            if down {
                nudge = dir;
            }
            Btn::new(word).icon(icon).tone(Tone::Deck(d)).on(down).quiet().paint(ui, p, nr, id, &resp);
        }
        if nudge != self.nudge_held[d] {
            desk.nudge(d, nudge);
            self.nudge_held[d] = nudge;
        }
    }

    /// The hot cues: a click sets an empty one or jumps to a set one; shift- or right-click
    /// clears. Under them, the record's parts.
    fn pads(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        kit::section(p, r.left_top(), Align2::LEFT_TOP, "Hot cues");
        let top = r.top() + 22.0;
        let g = 8.0;
        let parts_h = 26.0;
        let parts_r = Rect::from_min_max(pos2(r.left(), r.bottom() - parts_h), r.max);
        let pw = (r.width() - 3.0 * g) / 4.0;
        let ph = ((parts_r.top() - 10.0 - top - g) / 2.0).min(64.0);
        self.parts(desk, ui, p, parts_r, s, d);
        let shift = ui.input(|i| i.modifiers.shift);
        for i in 0..8 {
            let pr = Rect::from_min_size(pos2(r.left() + (i % 4) as f32 * (pw + g), top + (i / 4) as f32 * (ph + g)), vec2(pw, ph));
            let set = v.pads[i].map(|pad| (pad_name(pad.auto), col(pad_colour(pad.auto))));
            let resp = kit::pad(ui, p, pr, i + 1, set, self.pad_fired[d][i], (d, "pad", i));
            let resp = resp.on_hover_text(if set.is_some() { "Jump here · shift- or right-click clears" } else { "Set a cue here" });
            match v.pads[i] {
                Some(_) if resp.secondary_clicked() || (resp.clicked() && shift) => desk.clear_pad(d, i),
                Some(_) if resp.clicked() => {
                    self.pad_fired[d][i] += 1;
                    desk.pad(d, i);
                }
                None if resp.clicked() && !shift => {
                    self.pad_fired[d][i] += 1;
                    desk.pad(d, i);
                }
                _ => {}
            }
        }
    }

    /// The record's parts (v1's parts pads): the whole record, or its stems — drums, the
    /// music without them, no voice, the voice alone. A part asked for before the stems
    /// are on the deck plays the moment they are.
    fn parts(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        let ready = v.stems.ready();
        let usable = !matches!(v.stems, Stems::None | Stems::Never);
        let names: Vec<&str> = Part::ALL.iter().map(|p| p.word()).collect();
        let chosen = Part::ALL.iter().position(|p| *p == v.part);
        // where the stems are, at the row's right above it
        let (word, tone) = match &v.stems {
            Stems::None => ("", t::faint()),
            Stems::Asking => ("asking for the parts", t::faint()),
            Stems::Making => ("the parts are being made", t::warm()),
            Stems::Never => ("no parts for this record", t::faint()),
            Stems::Ready => ("", t::faint()),
            Stems::Failed(_) => ("the parts could not be had", t::warm()),
        };
        if !word.is_empty() {
            kit::text(p, pos2(r.right(), r.top() - 6.0), Align2::RIGHT_BOTTOM, word, 11.0, "", tone);
        }
        let seg = kit::segmented(ui, p, r, &names, chosen, Tone::Deck(d), (d, "parts"));
        // the stems' parts faint until they are on the deck
        if !ready {
            p.rect_filled(r, CornerRadius::same(t::R_CONTROL), Color32::from_black_alpha(if usable { 70 } else { 120 }));
        }
        if let Some(i) = seg.filter(|_| usable || Part::ALL[seg.unwrap()] == Part::Whole) {
            desk.set_part(d, Part::ALL[i]);
        }
        let tip = match &v.stems {
            Stems::Failed(why) => format!("The parts could not be had: {why}"),
            Stems::Never => "This record is not taken apart (too long)".into(),
            _ => "The whole record, or its parts: the drums, the music without them, no voice, the voice alone".into(),
        };
        ui.interact(r, ui.scope_id().with((d, "parts-tip")), Sense::hover()).on_hover_text(tip);
    }

    /// The loop: a length from the bar (again lets go), IN / OUT, half and double; jumps.
    fn loop_row(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        let lengths = [("¼", 0.25), ("½", 0.5), ("1", 1.0), ("2", 2.0), ("4", 4.0), ("8", 8.0), ("16", 16.0), ("32", 32.0)];
        crate::ui::icons::paint(p, Rect::from_center_size(pos2(r.left() + 9.0, r.center().y), vec2(16.0, 16.0)), Icon::Loop, t::label());
        let jumps = r.width() >= 430.0;
        let buttons_w = 4.0 * 34.0 + 3.0 * 4.0;
        let jumps_w = if jumps { 2.0 * 30.0 + 4.0 + 10.0 } else { 0.0 };
        let seg_w = (r.width() - 26.0 - 10.0 - buttons_w - jumps_w).clamp(160.0, 300.0);
        let seg = Rect::from_min_size(pos2(r.left() + 26.0, r.top()), vec2(seg_w, r.height()));
        let chosen = v.looped.and(v.loop_beats).and_then(|b| lengths.iter().position(|l| l.1 == b));
        let names: Vec<&str> = lengths.iter().map(|l| l.0).collect();
        if let Some(i) = kit::segmented(ui, p, seg, &names, chosen, Tone::Deck(d), (d, "loops")) {
            desk.loop_beats(d, lengths[i].1);
        }
        let mut x = seg.right() + 10.0;
        let looped_by_hand = v.looped.is_some() && v.loop_beats.is_none();
        for (word, on, act) in [("In", v.loop_open, 0), ("Out", looped_by_hand, 1), ("½", false, 2), ("×2", false, 3)] {
            let br = Rect::from_min_size(pos2(x, r.top()), vec2(34.0, r.height()));
            if Btn::new(word).tone(Tone::Deck(d)).on(on).size(11.0).show(ui, p, br, (d, "loopbtn", act)).clicked() {
                match act {
                    0 => desk.loop_in(d),
                    1 => desk.loop_out(d),
                    2 => desk.halve_loop(d),
                    _ => desk.double_loop(d),
                }
            }
            x = br.right() + 4.0;
        }
        if jumps {
            x += 6.0;
            for (icon, beats, k) in [(Icon::Back4, -4.0, 0), (Icon::Ahead4, 4.0, 1)] {
                let br = Rect::from_min_size(pos2(x, r.top()), vec2(30.0, r.height()));
                if Btn::new("").icon(icon).quiet().show(ui, p, br, (d, "jump", k)).on_hover_text(if k == 0 { "Back 4 beats" } else { "Ahead 4 beats" }).clicked() {
                    desk.jump(d, beats);
                }
                x = br.right() + 4.0;
            }
        }
    }

    /// The pitch fader: Technics way round (up is slower), a detent mark at the centre,
    /// double-click centres; the range above it cycles ±8 / 16 / 50.
    fn pitch(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        let range = Rect::from_min_size(pos2(r.left() + 2.0, r.top()), vec2(r.width() - 4.0, 20.0));
        if kit::chip(ui, p, range, &format!("±{:.0}", v.range * 100.0), false, Tone::Neutral, true, (d, "range")).on_hover_text("The fader's range").clicked() {
            desk.cycle_range(d);
        }
        let pf = Rect::from_min_max(pos2(r.left(), range.bottom() + 12.0), pos2(r.right(), r.bottom() - 22.0));
        let resp = ui.interact(pf, ui.scope_id().with((d, "pitch")), Sense::click_and_drag()).on_hover_cursor(egui::CursorIcon::ResizeVertical);
        let h = motion::tween_bool(ui.ctx(), resp.id.with("h"), resp.hovered() || resp.dragged(), motion::QUICK, motion::STANDARD);
        let travel = pf.height() / 2.0 - 9.0;
        p.rect_filled(Rect::from_center_size(pf.center(), vec2(4.0, pf.height())), CornerRadius::same(2), col(theme::LINE));
        for k in [-1.0f32, -0.5, 0.5, 1.0] {
            let y = pf.center().y + k * travel;
            p.line_segment([pos2(pf.center().x - 6.0, y), pos2(pf.center().x - 3.0, y)], Stroke::new(1.0, white(0.16)));
            p.line_segment([pos2(pf.center().x + 3.0, y), pos2(pf.center().x + 6.0, y)], Stroke::new(1.0, white(0.16)));
        }
        let zero = v.pitch.abs() < 1e-3;
        p.line_segment([pos2(pf.left() + 6.0, pf.center().y), pos2(pf.right() - 6.0, pf.center().y)], Stroke::new(1.0, if zero { alpha_of(t::ok(), 0.8) } else { Color32::from_rgb(0x4A, 0x4E, 0x57) }));
        if resp.double_clicked() {
            desk.set_pitch(d, 0.0);
        } else if resp.dragged() {
            desk.set_pitch(d, v.pitch + (resp.drag_delta().y / travel) as f64);
        }
        let py = motion::spring(ui.ctx(), resp.id.with("v"), pf.center().y + v.pitch as f32 * travel, 0.05);
        let cap = Rect::from_center_size(pos2(pf.center().x, py), vec2(38.0, 18.0));
        p.add(t::shadow(2).as_shape(cap, CornerRadius::same(4)));
        p.rect(cap, CornerRadius::same(4), mix(col(theme::CAP), t::high(), h), Stroke::new(1.0, Color32::from_black_alpha(60)), StrokeKind::Inside);
        p.line_segment([pos2(cap.left() + 7.0, cap.center().y), pos2(cap.right() - 7.0, cap.center().y)], Stroke::new(1.5, Color32::from_rgb(0x55, 0x59, 0x62)));
        let pitch = (v.rate - 1.0) * 100.0;
        kit::text(p, pos2(r.center().x, r.bottom()), Align2::CENTER_BOTTOM, &format!("{pitch:+.1}%"), 11.0, "mono", if zero { t::muted() } else { t::soft() });
    }

    fn mixer(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        kit::panel(p, r, false);
        let inner = r.shrink2(vec2(t::INSET, 14.0));
        let names = ["Gain", "High", "Mid", "Low", "Filter"];
        let cf_h = 30.0;
        let strip_bottom = inner.bottom() - cf_h - 16.0;
        let step = ((strip_bottom - inner.top() - 4.0) / 5.0).min(54.0);
        for d in 0..2 {
            let v = &s.decks[d];
            let side = if d == 0 { 1.0 } else { -1.0 };
            let edge = if d == 0 { inner.left() } else { inner.right() };
            let knobs_x = edge + side * 21.0;
            for (i, name) in names.iter().enumerate() {
                let c = pos2(knobs_x, inner.top() + 16.0 + i as f32 * step);
                let (val, bip, color) = match i {
                    0 => (v.gain, false, Color32::from_rgb(0x9D, 0xA1, 0xAA)),
                    1 => (v.eq[2], true, t::deck(d)),
                    2 => (v.eq[1], true, t::deck(d)),
                    3 => (v.eq[0], true, t::deck(d)),
                    _ => (v.filter, true, Color32::from_rgb(0x9D, 0xA1, 0xAA)),
                };
                if let Some(nv) = kit::knob(ui, p, c, val, color, bip, 0.5, (d, "knob", i)) {
                    match i {
                        0 => desk.set_gain(d, nv),
                        1 => desk.set_eq(d, 2, nv),
                        2 => desk.set_eq(d, 1, nv),
                        3 => desk.set_eq(d, 0, nv),
                        _ => desk.set_filter(d, nv),
                    }
                }
                label_sized(p, pos2(c.x, c.y + 17.0), Align2::CENTER_TOP, name, 9.5, t::label());
            }
            // the channel fader beside its knobs, its meter on the inside
            let fx = edge + side * 72.0;
            kit::deck_chip(p, pos2(fx - 10.0, inner.top() + 6.0), d);
            let top = inner.top() + 26.0;
            let fr = Rect::from_min_max(pos2(fx - 17.0, top), pos2(fx + 17.0, strip_bottom));
            if let Some(nv) = kit::vfader(ui, p, fr, v.fader, t::deck(d), (d, "fader")) {
                desk.set_fader(d, nv);
            }
            let level = (1.0 + 20.0 * v.peak.max(1e-6).log10() / 48.0).clamp(0.0, 1.0);
            let mx = fx + side * 30.0 - 3.0;
            kit::meter(ui, p, Rect::from_min_max(pos2(mx, top + 2.0), pos2(mx + 6.0, strip_bottom - 2.0)), level, 18, (d, "meter"));
        }
        // the master, as heard
        let mc = inner.center().x;
        kit::label(p, pos2(mc, inner.top() + 6.0), Align2::CENTER_CENTER, "Master");
        let top = inner.top() + 28.0;
        let lvl = (1.0 + 20.0 * s.decks[0].peak.max(s.decks[1].peak).max(1e-6).log10() / 48.0).clamp(0.0, 1.0);
        kit::meter(ui, p, Rect::from_min_max(pos2(mc - 9.0, top), pos2(mc - 2.0, strip_bottom - 2.0)), lvl, 18, "master-l");
        kit::meter(ui, p, Rect::from_min_max(pos2(mc + 2.0, top), pos2(mc + 9.0, strip_bottom - 2.0)), lvl * 0.97, 18, "master-r");
        // the crossfader: a hand on it takes over from the Auto DJ
        let cf = Rect::from_min_max(pos2(inner.left() + 22.0, inner.bottom() - cf_h), pos2(inner.right() - 22.0, inner.bottom()));
        kit::deck_chip(p, pos2(inner.left() - 2.0, cf.center().y), 0);
        kit::deck_chip(p, pos2(inner.right() - 18.0, cf.center().y), 1);
        if let Some(x) = kit::crossfader(ui, p, cf.shrink2(vec2(6.0, 0.0)), s.crossfader, "xf") {
            desk.set_auto(false);
            desk.set_crossfader(x);
        }
    }

    fn crate_(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        kit::panel(p, r, true);
        let tree = Rect::from_min_max(r.min, pos2(r.left() + 232.0, r.bottom()));
        p.line_segment([pos2(tree.right(), r.top() + 12.0), pos2(tree.right(), r.bottom() - 12.0)], Stroke::new(1.0, white(0.06)));
        self.shelves(desk, ui, p, tree);
        let main = Rect::from_min_max(pos2(tree.right(), r.top()), r.max);

        // search
        let field = Rect::from_min_size(pos2(main.left() + 14.0, main.top() + 10.0), vec2((main.width() * 0.45).clamp(240.0, 380.0), 32.0));
        let hint = if desk.house().is_some() { "Search the house" } else { "Search these records" };
        let typed = kit::field(ui, p, field, &mut self.search, hint, Some(Icon::Search), false, "search");
        if !self.search.is_empty() {
            let x = Rect::from_center_size(pos2(field.right() - 16.0, field.center().y), vec2(22.0, 22.0));
            if Btn::new("").icon(Icon::Close).quiet().show(ui, p, x, "search-clear").clicked() {
                self.search.clear();
                self.search_at = Some(std::time::Instant::now());
            }
        }
        // the house is asked once typing pauses (or on Enter), not on every key
        if typed.changed() {
            self.search_at = Some(std::time::Instant::now());
        }
        let enter = typed.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
        let paused = self.search_at.is_some_and(|t| t.elapsed().as_millis() > 350);
        if desk.house().is_some() && (enter || paused) && self.search != self.searched {
            self.searched = self.search.clone();
            desk.open_shelf(Shelf::Search(self.search.clone()));
            self.search_at = None;
        }
        // what the list is
        let lib = desk.library();
        let words = match desk.house() {
            Some(_) => {
                let name = match &lib.shelf {
                    Shelf::All => "All records".to_owned(),
                    Shelf::Playlist { name, .. } => name.clone(),
                    Shelf::Search(q) => format!("“{q}”"),
                    Shelf::Fits { title, .. } => format!("Fits {title}"),
                    Shelf::Queue => "The queue".to_owned(),
                };
                let n = if lib.loading { "…".to_owned() } else { thousands(lib.total) };
                format!("{name} · {n}")
            }
            None => "Records on this computer".to_owned(),
        };
        let shelf_key = format!("{:?}{}", lib.shelf, lib.loading);
        let room = main.right() - field.right() - 40.0;
        let g = p.layout(words, egui::FontId::new(13.0, crate::paint::family("")), t::muted(), room);
        p.galley(pos2(main.right() - 16.0 - g.size().x.min(room), field.center().y - g.size().y / 2.0), g, t::muted());

        // the header: click a heading to sort by it, again the other way round (a narrow
        // crate drops the fit, then the time)
        let cols = Cols::for_width(main.width());
        let cx = cols.x;
        let clip = p.with_clip_rect(main.shrink(1.0));
        let p = &clip;
        let hy = main.top() + 62.0;
        let heads: [(&str, Option<Sort>, usize, bool); 8] = [
            ("#", None, 0, false),
            ("", None, 1, false),
            ("Title", Some(Sort::Title), 2, false),
            ("Artist", Some(Sort::Artist), 3, false),
            ("BPM", Some(Sort::Bpm), 5, true),
            ("Key", Some(Sort::Key), 5, false),
            ("Time", None, 7, true),
            ("Fits", Some(Sort::Fits), 7, false),
        ];
        for (i, (h, sort, at, right)) in heads.into_iter().enumerate() {
            if h.is_empty() || (h == "Time" && !cols.time) || (h == "Fits" && !cols.fits) {
                continue;
            }
            let x = main.left() + cx[at] - if right { 12.0 } else { 0.0 };
            let anchor = if right { Align2::RIGHT_CENTER } else { Align2::LEFT_CENTER };
            let on = sort.is_some_and(|s| s == self.sort.0);
            let w = label_width(p, h, 10.5);
            let hr = anchor.anchor_size(pos2(x, hy), vec2(w + 14.0, 22.0));
            let resp = sort.map(|_| ui.interact(hr, ui.scope_id().with(("head", i)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand));
            let hov = resp.as_ref().is_some_and(|r| r.hovered());
            let tr = label_sized(p, pos2(x, hy), anchor, h, 10.5, if on { t::soft() } else if hov { t::muted() } else { t::label() });
            if on {
                let ax = if right { tr.left() - 8.0 } else { tr.right() + 7.0 };
                let (a, b) = if self.sort.1 { (-1.0, 1.0) } else { (1.0, -1.0) };
                p.add(Shape::convex_polygon(vec![pos2(ax - 3.5, hy + 2.0 * a), pos2(ax + 3.5, hy + 2.0 * a), pos2(ax, hy + 2.0 * b)], t::soft(), Stroke::NONE));
            }
            if let (Some(sort), Some(resp)) = (sort, resp)
                && resp.clicked()
            {
                self.sort = if self.sort.0 == sort { (sort, !self.sort.1) } else { (sort, false) };
            }
        }
        p.line_segment([pos2(main.left(), hy + 14.0), pos2(main.right(), hy + 14.0)], Stroke::new(1.0, white(0.08)));
        let list = Rect::from_min_max(pos2(main.left(), hy + 15.0), pos2(main.right(), main.bottom() - 4.0));
        let mut rows = desk.rows(&self.search, s.master_bpm);
        match self.sort {
            (Sort::Fits, false) => {}
            (Sort::Fits, true) => rows.reverse(),
            (by, back) => {
                rows.sort_by(|a, b| {
                    let (a, b) = (&a.record, &b.record);
                    let o = match by {
                        Sort::Title => a.title.to_lowercase().cmp(&b.title.to_lowercase()),
                        Sort::Artist => a.artist.to_lowercase().cmp(&b.artist.to_lowercase()),
                        Sort::Bpm => a.bpm.total_cmp(&b.bpm),
                        _ => camelot(&a.key).cmp(&camelot(&b.key)),
                    };
                    if back { o.reverse() } else { o }
                });
            }
        }
        // a controller's browse moves the cursor, its LOAD loads the row under it (never
        // onto a deck that is playing)
        let mut scroll_to = None;
        for a in desk.take_crate_actions() {
            match a {
                wo_control::Action::Browse(_, dy) if !rows.is_empty() => {
                    self.cursor = (self.cursor as i64 + dy as i64).clamp(0, rows.len() as i64 - 1) as usize;
                    scroll_to = Some(self.cursor);
                }
                wo_control::Action::Load(d) => {
                    if let Some(row) = rows.get(self.cursor)
                        && row.record.playable()
                        && row.on_deck.is_none()
                        && !s.decks[d].playing
                    {
                        desk.load_by_hand(d, row.record.clone());
                    }
                }
                _ => {}
            }
        }
        self.cursor = self.cursor.min(rows.len().saturating_sub(1));
        // a new list fades in, row after row
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        (shelf_key, &self.searched, self.sort, rows.len().min(1)).hash(&mut hasher);
        let list_id = ui.scope_id().with(("list", hasher.finish()));
        let since = motion::since(ui.ctx(), list_id);
        if since < 0.3 {
            ui.ctx().request_repaint();
        }
        let reduced = motion::reduced(ui.ctx());
        let row_k = |i: usize| if reduced { 1.0 } else { Ease::Out.at((since - i.min(8) as f32 * 0.012) / motion::STANDARD) };

        let mut load: Option<Record> = None;
        let mut queue_it: Option<Record> = None;
        let mut unqueue: Option<i64> = None;
        let mut load_on: Option<(usize, Record)> = None;
        let mut near_end = false;
        let mut add_to: Option<(i64, Record)> = None;
        let lists: Vec<(i64, String)> = desk.library().playlists.iter().map(|l| (l.id, l.name.clone())).collect();
        let on_queue = desk.library().shelf == Shelf::Queue;
        let free_decks: [bool; 2] = [!s.decks[0].playing, !s.decks[1].playing];
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(list));
        let mut area = egui::ScrollArea::vertical().id_salt("crate").auto_shrink([false, false]).min_scrolled_height(0.0).max_height(list.height().max(0.0));
        if let Some(i) = scroll_to {
            area = area.vertical_scroll_offset((i as f32 * ROW - list.height() / 2.0).max(0.0));
        }
        let cursor = self.cursor;
        let mut clicked = None;
        let ctx = ui.ctx().clone();
        area.show_rows(&mut child, ROW, rows.len(), |ui, range| {
            near_end = range.end + 30 >= rows.len();
            let first = range.start;
            let mut origin = None;
            for i in range {
                let row = &rows[i];
                let (rr, resp) = ui.allocate_exact_size(vec2(list.width(), ROW), Sense::click_and_drag());
                origin.get_or_insert(rr.top() - (i - first) as f32 * ROW - first as f32 * ROW);
                let p = ui.painter().clone();
                let k = row_k(i - first);
                let mut p = p;
                p.multiply_opacity(k);
                let h = motion::tween_bool(&ctx, resp.id.with("h"), resp.hovered(), motion::QUICK, motion::STANDARD);
                if h > 0.0 && i != cursor {
                    p.rect_filled(rr.shrink2(vec2(6.0, 1.0)), CornerRadius::same(t::R_CONTROL), white(0.045 * h));
                }
                if resp.clicked() {
                    clicked = Some(i);
                }
                let playable = row.record.playable() && row.on_deck.is_none();
                if playable {
                    resp.dnd_set_drag_payload(row.record.clone());
                }
                let y = rr.center().y + 4.0 * (1.0 - k);
                let at = |c: usize| rr.left() + cx[c];
                kit::text(&p, pos2(at(0), y), Align2::LEFT_CENTER, &(i + 1).to_string(), 11.0, "mono", t::label());
                let sl = Rect::from_min_size(pos2(at(1), y - 14.0), vec2(28.0, 28.0));
                let tex = self.sleeves.of(&ctx, desk, &row.record);
                kit::sleeve(ui, &p, sl, tex, &row.record.initials(), col(theme::sleeve(row.record.id)), 4, ("row-sleeve", row.record.id));
                let mut tx = at(2);
                if let Some(d) = row.on_deck {
                    let c = kit::deck_chip(&p, pos2(tx, y), d);
                    tx = c.right() + 8.0;
                }
                let ink = if row.on_deck.is_some() { t::muted() } else if row.record.playable() { t::text() } else { t::muted() };
                kit::clipped(&p, pos2(tx, y), &row.record.title, 13.0, "", ink, at(3) - tx - 12.0);
                kit::clipped(&p, pos2(at(3), y), &row.record.artist, 13.0, "", t::muted(), at(4) - at(3) - 12.0);
                kit::text(&p, pos2(at(5) - 12.0, y), Align2::RIGHT_CENTER, &format!("{:.2}", row.record.bpm), 12.0, "mono", t::text());
                kit::text(&p, pos2(at(5), y), Align2::LEFT_CENTER, &row.record.key, 12.0, "mono", t::muted());
                if cols.time {
                    kit::text(&p, pos2(at(7) - 12.0, y), Align2::RIGHT_CENTER, &format!("{}:{:02}", row.record.seconds / 60, row.record.seconds % 60), 12.0, "mono", t::muted());
                }
                if row.on_deck.is_none() && cols.fits {
                    let bar = Rect::from_min_size(pos2(at(7), y - 2.0), vec2(64.0, 4.0));
                    p.rect_filled(bar, CornerRadius::same(2), col(theme::LINE));
                    let fit = row.fits as f32 / 100.0;
                    p.rect_filled(Rect::from_min_size(bar.min, vec2(64.0 * fit, 4.0)), CornerRadius::same(2), mix(Color32::from_rgb(0x6A, 0x6E, 0x77), t::ok(), (fit - 0.6).max(0.0) / 0.4));
                    kit::text(&p, pos2(bar.right() + 8.0, y), Align2::LEFT_CENTER, &row.fits.to_string(), 11.0, "mono", t::muted());
                }
                if resp.double_clicked() && playable {
                    load = Some(row.record.clone());
                }
                // a hand on a record: queue it, or put it on a deck that is free
                let rec = row.record.clone();
                resp.context_menu(|ui| {
                    if on_queue {
                        if ui.button("Out of the queue").clicked() {
                            unqueue = Some(rec.id);
                            ui.close();
                        }
                    } else if ui.add_enabled(rec.playable(), egui::Button::new("Queue it for the Auto DJ")).clicked() {
                        queue_it = Some(rec.clone());
                        ui.close();
                    }
                    if !lists.is_empty() && rec.id > 0 {
                        ui.menu_button("Add to a playlist", |ui| {
                            for (pid, name) in lists.iter() {
                                if ui.button(name).clicked() {
                                    add_to = Some((*pid, rec.clone()));
                                    ui.close();
                                }
                            }
                        });
                    }
                    for d in 0..2 {
                        if ui.add_enabled(playable && free_decks[d], egui::Button::new(format!("On deck {}", ["A", "B"][d]))).clicked() {
                            load_on = Some((d, rec.clone()));
                            ui.close();
                        }
                    }
                });
            }
            // the cursor: one highlight that glides between rows
            if let Some(o) = origin
                && !rows.is_empty()
            {
                let gy = motion::spring(&ctx, ui.scope_id().with("cursor"), cursor as f32 * ROW, 0.14);
                let hr = Rect::from_min_size(pos2(list.left() + 6.0, o + gy + 1.0), vec2(list.width() - 12.0, ROW - 2.0));
                if hr.intersects(ui.clip_rect()) {
                    let p = ui.painter();
                    p.rect(hr, CornerRadius::same(t::R_CONTROL), white(0.07), Stroke::new(1.0, white(0.1)), StrokeKind::Inside);
                    p.rect_filled(Rect::from_min_size(pos2(hr.left() + 1.0, hr.top() + 8.0), vec2(2.5, hr.height() - 16.0)), CornerRadius::same(1), t::soft());
                }
            }
        });
        if rows.is_empty() && !desk.library().loading {
            let why = if self.search.is_empty() { "Nothing on this shelf" } else { "Nothing found" };
            kit::hint(p, list.center(), Align2::CENTER_CENTER, why);
        }
        if let Some(i) = clicked {
            self.cursor = i;
        }
        if let Some(r) = queue_it {
            self.toasts.say(format!("{} queued", r.title), Tone::Neutral);
            desk.queue_add(r);
        }
        if let Some(id) = unqueue {
            desk.queue_remove(id);
        }
        if let Some((pid, r)) = add_to {
            self.toasts.say(format!("{} added", r.title), Tone::Neutral);
            desk.add_to_playlist(pid, &r);
        }
        if let Some((d, r)) = load_on {
            self.toasts.say(format!("{} on deck {}", r.title, ["A", "B"][d]), Tone::Deck(d));
            desk.load_by_hand(d, r);
        }
        // the whole library comes a page at a time: the next as the end comes into view
        if near_end {
            desk.more_rows();
        }
        if let Some(rec) = load
            && s.mix.is_none()
        {
            let free = s.decks.iter().position(|d| !d.master).unwrap_or(1);
            if !s.decks[free].playing {
                self.toasts.say(format!("{} on deck {}", rec.title, ["A", "B"][free]), Tone::Deck(free));
                desk.load_by_hand(free, rec);
            }
        }
    }

    /// The record being dragged to a deck, following the pointer.
    fn drag_ghost(&mut self, desk: &mut Desk, ui: &mut Ui) {
        let ctx = ui.ctx().clone();
        let Some(rec) = egui::DragAndDrop::payload::<Record>(&ctx) else { return };
        let Some(pos) = ctx.pointer_latest_pos() else { return };
        if ctx.input(|i| i.pointer.any_released()) {
            egui::DragAndDrop::clear_payload(&ctx);
        }
        ctx.set_cursor_icon(egui::CursorIcon::Grabbing);
        let p = ctx.layer_painter(egui::LayerId::new(egui::Order::Tooltip, egui::Id::unique("drag")));
        let w = 260.0;
        let r = Rect::from_min_size(pos + vec2(14.0, 10.0), vec2(w, 44.0));
        p.add(t::shadow(2).as_shape(r, CornerRadius::same(t::R_PAD)));
        p.rect(r, CornerRadius::same(t::R_PAD), Color32::from_rgba_unmultiplied(20, 21, 27, 240), Stroke::new(1.0, white(0.14)), StrokeKind::Inside);
        let sl = Rect::from_min_size(r.min + vec2(6.0, 6.0), vec2(32.0, 32.0));
        let tex = self.sleeves.of(&ctx, desk, &rec);
        kit::sleeve(ui, &p, sl, tex, &rec.initials(), col(theme::sleeve(rec.id)), 4, ("ghost", rec.id));
        kit::clipped(&p, pos2(sl.right() + 10.0, r.top() + 15.0), &rec.title, 13.0, "semi", t::text(), w - 56.0);
        kit::clipped(&p, pos2(sl.right() + 10.0, r.top() + 31.0), &rec.artist, 12.0, "", t::muted(), w - 56.0);
    }

    /// The crate's left column: the house's shelves, or the sign-in.
    fn shelves(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, tree: Rect) {
        let Some((server, user)) = desk.house().map(|(s, u)| (s.to_owned(), u.map(str::to_owned))) else {
            return self.sign_in(desk, ui, p, tree);
        };
        let lib = desk.library();
        let (shelf, total, lists) = (lib.shelf.clone(), lib.total, lib.playlists.clone());
        let mut open = None;
        kit::section(p, pos2(tree.left() + 18.0, tree.top() + 16.0), Align2::LEFT_TOP, "Library");
        let ctx = ui.ctx().clone();
        // painted with the ui's own painter, so rows in the scrolling list are clipped by it
        let row = |ui: &mut Ui, y: f32, name: &str, n: String, on: bool, id: i64| -> bool {
            let p = ui.painter().clone();
            let rr = Rect::from_min_size(pos2(tree.left() + 10.0, y), vec2(tree.width() - 20.0, 30.0));
            let resp = ui.interact(rr, ui.scope_id().with(("shelf", id)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
            let h = motion::tween_bool(&ctx, resp.id.with("h"), resp.hovered(), motion::QUICK, motion::STANDARD);
            let o = motion::tween_bool(&ctx, resp.id.with("on"), on, motion::STANDARD, motion::STANDARD);
            if h + o > 0.0 {
                p.rect_filled(rr, CornerRadius::same(t::R_CONTROL), white(0.04 * h + 0.07 * o));
            }
            if o > 0.0 {
                p.rect_filled(Rect::from_min_size(pos2(rr.left() + 1.0, rr.top() + 8.0), vec2(2.5, rr.height() - 16.0)), CornerRadius::same(1), alpha_of(t::soft(), o));
            }
            let ink = mix(Color32::from_rgb(0xB9, 0xBC, 0xC4), t::text(), o.max(h));
            kit::clipped(&p, pos2(rr.left() + 12.0, rr.center().y), name, 13.0, "", ink, rr.width() - 60.0);
            kit::text(&p, pos2(rr.right() - 8.0, rr.center().y), Align2::RIGHT_CENTER, &n, 11.0, "mono", t::faint());
            resp.clicked()
        };
        let all_n = if shelf == Shelf::All { thousands(total) } else { String::new() };
        if row(ui, tree.top() + 38.0, "All records", all_n, shelf == Shelf::All, -1) {
            open = Some(Shelf::All);
        }
        // the house's best fits for the record playing; the hand's queue
        if row(ui, tree.top() + 70.0, "Fits the master", String::new(), matches!(shelf, Shelf::Fits { .. }), -2) {
            self.fits_asked = true;
        }
        let queued = desk.queue().len();
        if row(ui, tree.top() + 102.0, "Queue", if queued > 0 { queued.to_string() } else { String::new() }, shelf == Shelf::Queue, -3) {
            open = Some(Shelf::Queue);
        }
        kit::section(p, pos2(tree.left() + 18.0, tree.top() + 148.0), Align2::LEFT_TOP, "Playlists");
        let list = Rect::from_min_max(pos2(tree.left(), tree.top() + 168.0), pos2(tree.right(), tree.bottom() - 46.0));
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(list));
        egui::ScrollArea::vertical().id_salt("playlists").auto_shrink([false, false]).min_scrolled_height(0.0).max_height(list.height().max(0.0)).show_rows(&mut child, 32.0, lists.len(), |ui, range| {
            for i in range {
                let l = &lists[i];
                let (rr, _) = ui.allocate_exact_size(vec2(list.width(), 32.0), Sense::hover());
                let on = matches!(&shelf, Shelf::Playlist { id, .. } if *id == l.id);
                if row(ui, rr.top(), &l.name, l.items.to_string(), on, l.id) {
                    open = Some(Shelf::Playlist { id: l.id, name: l.name.clone() });
                }
            }
        });
        p.line_segment([pos2(tree.left() + 14.0, tree.bottom() - 44.0), pos2(tree.right() - 14.0, tree.bottom() - 44.0)], Stroke::new(1.0, white(0.06)));
        let who = user.unwrap_or_else(|| server.trim_start_matches("https://").to_owned());
        kit::dot(p, pos2(tree.left() + 21.0, tree.bottom() - 22.0), t::ok(), 3.0);
        kit::clipped(p, pos2(tree.left() + 32.0, tree.bottom() - 22.0), &who, 12.0, "", t::muted(), tree.width() - 130.0);
        let out = Rect::from_min_size(pos2(tree.right() - 88.0, tree.bottom() - 35.0), vec2(76.0, 26.0));
        if Btn::new("Sign out").quiet().size(11.0).show(ui, p, out, "sign-out").on_hover_text(server.clone()).clicked() {
            desk.sign_out();
        }
        if self.fits_asked {
            self.fits_asked = false;
            self.search.clear();
            self.searched.clear();
            desk.open_fits();
        }
        if let Some(s) = open {
            self.search.clear();
            self.searched.clear();
            desk.open_shelf(s);
        }
    }

    /// Signing in to the house: its address, a name, a password — or the WetOwl app's own
    /// sign-in where this computer has one.
    fn sign_in(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, tree: Rect) {
        let x = tree.left() + 14.0;
        let w = tree.width() - 28.0;
        kit::section(p, pos2(x + 4.0, tree.top() + 16.0), Align2::LEFT_TOP, "The house");
        kit::hint(p, pos2(x + 4.0, tree.top() + 38.0), Align2::LEFT_TOP, "Sign in for its records");
        let mut y = tree.top() + 64.0;
        let lib = desk.library();
        let busy = lib.signing_in;
        let mut go = false;
        for (hint, which, icon) in [("House address", 0, Icon::Screen), ("Name", 1, Icon::Dot), ("Password", 2, Icon::Lock)] {
            let fr = Rect::from_min_size(pos2(x, y), vec2(w, 30.0));
            let value = match which {
                0 => &mut self.form.0,
                1 => &mut self.form.1,
                _ => &mut self.form.2,
            };
            let resp = kit::field(ui, p, fr, value, hint, (which != 1).then_some(icon), which == 2, ("sign-in", which));
            if which == 2 && resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                go = true;
            }
            y += 36.0;
        }
        let gr = Rect::from_min_size(pos2(x, y + 2.0), vec2(w, 32.0));
        if Btn::new(if busy { "Signing in…" } else { "Sign in" }).tone(Tone::Ok).on(true).enabled(!busy).show(ui, p, gr, "sign-in").clicked() {
            go = true;
        }
        if go && !busy {
            let (server, user, pass) = self.form.clone();
            desk.sign_in(&server, &user, &pass);
        }
        y += 42.0;
        if self.app_sign_in && y + 30.0 < tree.bottom() {
            let app = Rect::from_min_size(pos2(x, y), vec2(w, 30.0));
            if Btn::new("Use the WetOwl app's").quiet().size(11.0).show(ui, p, app, "app-sign-in").clicked() {
                desk.use_app_sign_in();
            }
        }
    }

    /// The show's window, small: its picture under a glass caption, and four hands.
    fn stage_card(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        kit::panel(p, r, false);
        let inner = r.shrink(t::INSET);
        let v = desk.stage();
        let on = v.stages > 0;
        kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Stage");
        let (dot, word) = match (on, v.starting) {
            (true, _) => (t::ok(), "Showing"),
            (false, true) => (t::warm(), "Starting…"),
            _ => (t::faint(), "Closed"),
        };
        let w = label_sized(p, pos2(inner.right(), inner.top() + 6.0), Align2::RIGHT_CENTER, word, 10.5, t::muted());
        kit::dot(p, pos2(w.left() - 9.0, w.center().y), dot, 3.0);
        let buttons = 30.0 + 8.0 + 30.0;
        let room = inner.height() - 26.0 - buttons - 10.0;
        let pic_h = inner.width() * 9.0 / 16.0;
        let scene = match (on, v.untold) {
            (true, true) => "an older stage: it says nothing of its scene".to_owned(),
            (true, false) => v.told.look.clone().or(v.scene.clone()).unwrap_or_else(|| "—".into()),
            _ => "—".into(),
        };
        if room >= pic_h {
            let pic = Rect::from_min_size(pos2(inner.left(), inner.top() + 26.0), vec2(inner.width(), pic_h));
            p.rect_filled(pic, CornerRadius::same(t::R_PAD), Color32::BLACK);
            match (&self.stage_pic, on) {
                (Some((_, tex)), true) => {
                    p.add(egui::epaint::RectShape::filled(pic, CornerRadius::same(t::R_PAD), Color32::WHITE).with_texture(tex.id(), Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0))));
                    // the caption on glass over the picture's foot
                    let cap = Rect::from_min_max(pos2(pic.left() + 6.0, pic.bottom() - 30.0), pos2(pic.right() - 6.0, pic.bottom() - 6.0));
                    kit::glass_tab(p, cap);
                    let held = if v.held { label_sized(p, pos2(cap.right() - 8.0, cap.center().y), Align2::RIGHT_CENTER, "Held", 10.0, t::warm()).left() } else { cap.right() };
                    kit::clipped(p, pos2(cap.left() + 8.0, cap.center().y), &scene, 11.5, "", t::text(), held - cap.left() - 16.0);
                }
                _ => {
                    let (say, ink) = match (&v.trouble, v.starting) {
                        (Some(why), _) => (why.clone(), t::warm()),
                        (None, true) => ("The stage window is opening".to_owned(), t::muted()),
                        (None, false) => ("The show, in a window of its own".to_owned(), t::faint()),
                    };
                    let g = p.layout(say, egui::FontId::new(12.0, crate::paint::family("")), ink, pic.width() - 32.0);
                    p.galley(pic.center() - g.size() / 2.0, g, ink);
                }
            }
            p.rect_stroke(pic, CornerRadius::same(t::R_PAD), Stroke::new(1.0, white(0.08)), StrokeKind::Inside);
            // the picture opens the Show page, where the show is played
            if ui.interact(pic, ui.scope_id().with("stage-pic"), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand).on_hover_text("The Show page  (K)").clicked() {
                self.page = Page::Show;
            }
        } else {
            kit::clipped(p, pos2(inner.left(), inner.top() + 36.0), &scene, 13.0, "", if on { t::text() } else { t::faint() }, inner.width());
        }
        // the hands: they go to the stage's director
        let bw = (inner.width() - 3.0 * 6.0) / 4.0;
        let hy = inner.bottom() - buttons;
        let hands: [(&str, Icon, Tone, bool, ShowHand); 4] = [
            ("Hit", Icon::Bolt, Tone::Neutral, false, ShowHand::Hit),
            ("Next", Icon::Next, Tone::Neutral, false, ShowHand::Next),
            ("Hold", Icon::Lock, Tone::Neutral, v.held, ShowHand::Hold(!v.held)),
            ("Black", Icon::Power, Tone::Danger, v.blackout, ShowHand::Blackout(!v.blackout)),
        ];
        for (i, (name, icon, tone, lit, hand)) in hands.into_iter().enumerate() {
            let br = Rect::from_min_size(pos2(inner.left() + i as f32 * (bw + 6.0), hy), vec2(bw, 30.0));
            if Btn::new(name).icon(icon).tone(tone).on(lit).enabled(on).size(11.0).show(ui, p, br, ("show", i)).clicked() {
                desk.show(hand);
            }
        }
        let open = Rect::from_min_size(pos2(inner.left(), inner.bottom() - 30.0), vec2(inner.width(), 30.0));
        let word = if on || v.starting { "Close the stage" } else { "Open the stage" };
        if Btn::new(word).icon(Icon::Screen).quiet().show(ui, p, open, "stage-open").clicked() {
            if on || v.starting {
                desk.close_stage();
            } else {
                desk.open_stage();
            }
        }
    }

    pub(crate) fn auto_dj(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        kit::panel(p, r, false);
        let inner = r.shrink(t::INSET);
        kit::section(p, pos2(inner.left(), inner.top() + 2.0), Align2::LEFT_TOP, "Auto DJ");
        // the style it mixes in
        let styles = [Style::Easy, Style::Normal, Style::Bold];
        let seg = Rect::from_min_size(pos2(inner.right() - 186.0, inner.top() - 3.0), vec2(186.0, 24.0));
        if let Some(i) = kit::segmented(ui, p, seg, &["Easy", "Normal", "Bold"], styles.iter().position(|&st| st == desk.style), Tone::Neutral, "style") {
            desk.style = styles[i];
        }
        // under the card: the hands on the move, the room's word, the last mix's thumb
        let last = desk.last_mix();
        let below = 36.0 + 36.0 + if last.is_some() { 36.0 } else { 0.0 };
        let card_h = (inner.height() - 30.0 - below).max(120.0);
        let card = Rect::from_min_size(pos2(inner.left(), inner.top() + 30.0), vec2(inner.width(), card_h));
        p.rect(card, CornerRadius::same(t::R_PAD), white(0.035), Stroke::new(1.0, white(0.06)), StrokeKind::Inside);
        let c = card.shrink(12.0);
        let master = s.decks.iter().position(|d| d.master).unwrap_or(0);
        let (from, to) = s.mix.as_ref().map(|m| (m.from, m.to)).unwrap_or((master, 1 - master));
        let a = kit::deck_chip(p, pos2(c.left(), c.top() + 9.0), from);
        crate::ui::icons::paint(p, Rect::from_center_size(pos2(a.right() + 12.0, c.top() + 9.0), vec2(12.0, 12.0)), Icon::ChevronRight, t::muted());
        let b = kit::deck_chip(p, pos2(a.right() + 24.0, c.top() + 9.0), to);
        let (what, status) = match (s.auto, s.mix.clone()) {
            (false, _) => ("Paused".to_owned(), "".to_owned()),
            (true, None) => ("Listening".to_owned(), if s.decks[master].playing { "planning…" } else { "play a deck" }.to_owned()),
            (true, Some(m)) => (
                format!("{} · {} bar{}", m.kind.word(), m.bars, if m.bars == 1 { "" } else { "s" }),
                if m.mixing { format!("bar {:.0} / {}", m.bar.floor() + 1.0, m.bars) } else { format!("in {}:{:02}", m.starts_in as u64 / 60, m.starts_in as u64 % 60) },
            ),
        };
        let set_b = Rect::from_min_size(pos2(c.right() - 52.0 - 46.0, c.top() - 2.0), vec2(44.0, 22.0));
        let set_on = desk.set_view().playing;
        if Btn::new("Set").on(set_on).quiet().size(10.0).show(ui, p, set_b, "set-open").on_hover_text("Plan a set: the house picks and orders the records").clicked() {
            self.overlay = Some(crate::Overlay::Set);
        }
        let plan_b = Rect::from_min_size(pos2(c.right() - 52.0, c.top() - 2.0), vec2(52.0, 22.0));
        if Btn::new("Plan").on(self.plan_open).quiet().size(10.0).show(ui, p, plan_b, "plan-open").on_hover_text("The move drawn out, with a hand on it  (P)").clicked() {
            self.plan_open = !self.plan_open;
        }
        let st = kit::text(p, pos2(set_b.left() - 8.0, c.top() + 9.0), Align2::RIGHT_CENTER, &status, 12.0, "mono", t::muted());
        kit::clipped(p, pos2(b.right() + 10.0, c.top() + 9.0), &what, 13.0, "semi", t::text(), st.left() - b.right() - 20.0);
        // the mix as a timeline: the two levels crossing over the bars, the bass changing
        // hands, a playhead
        // the move, what is coming, or what it has done (tabs at the right of the second
        // line); why the planner chose it, in its words, at its left
        let tabs = Rect::from_min_size(pos2(c.right() - 168.0, c.top() + 24.0), vec2(168.0, 20.0));
        if let Some(i) = kit::segmented(ui, p, tabs, &["Move", "Next", "Log"], Some(self.auto_tab), Tone::Neutral, "auto-tab") {
            self.auto_tab = i;
        }
        let why = s.mix.as_ref().map(|m| m.why.clone()).filter(|w| !w.is_empty() && s.auto);
        if let Some(w) = &why {
            kit::clipped(p, pos2(c.left(), tabs.center().y), w, 11.5, "", t::label(), tabs.left() - c.left() - 10.0);
            ui.interact(Rect::from_min_max(pos2(c.left(), c.top()), pos2(tabs.left() - 4.0, tabs.bottom())), ui.scope_id().with("why"), Sense::hover()).on_hover_text(w.as_str());
        }
        let buttons_y = c.bottom() - 30.0;
        let area = Rect::from_min_max(pos2(c.left(), tabs.bottom() + 6.0), pos2(c.right(), buttons_y - 8.0));
        match self.auto_tab {
            0 if area.height() >= 24.0 => self.timeline(ui, p, area, s, from, to),
            1 => self.up_next(desk, ui, p, area, s),
            2 => auto_log(desk, p, area),
            _ => {}
        }
        let planned = s.mix.as_ref().is_some_and(|m| !m.mixing);
        let bw = (c.width() - 16.0) / 3.0;
        let at = |i: f32| Rect::from_min_size(pos2(c.left() + i * (bw + 8.0), buttons_y), vec2(bw, 30.0));
        if Btn::new("Mix now").icon(Icon::Next).enabled(planned && s.auto).size(11.0).show(ui, p, at(0.0), "mix-now").on_hover_text("Start the mix on the next bar  (M)").clicked() {
            desk.mix_now();
        }
        if Btn::new("Not that").icon(Icon::Shuffle).enabled(planned && s.auto).size(11.0).show(ui, p, at(1.0), "not-that").on_hover_text("Another record next  (S)").clicked() {
            desk.not_that();
        }
        if Btn::new(if s.auto { "Pause" } else { "Paused" }).icon(Icon::Pause).on(!s.auto).size(11.0).show(ui, p, at(2.0), "pause").clicked() {
            desk.set_auto(!s.auto);
        }
        // the hands on the planned move: skip, later, sooner, longer; undo
        let hy = card.bottom() + 10.0;
        let can_undo = desk.can_undo();
        let hands: [(&str, Icon, bool, &str); 5] = [
            ("Skip", Icon::Next, planned && s.auto, "Into the next record at the next bar, quickly"),
            ("Later", Icon::ChevronRight, planned && s.auto, "Not now: two phrases later"),
            ("Sooner", Icon::ChevronLeft, planned && s.auto, "A phrase sooner"),
            ("Longer", Icon::Plus, planned && s.auto, "The move twice as long"),
            ("Undo", Icon::Undo, can_undo.is_some(), "Go back on the last thing the Auto DJ changed"),
        ];
        let hw = (inner.width() - 4.0 * 6.0) / 5.0;
        for (i, (word, icon, on, tip)) in hands.into_iter().enumerate() {
            let br = Rect::from_min_size(pos2(inner.left() + i as f32 * (hw + 6.0), hy), vec2(hw, 26.0));
            let tip = if word == "Undo" { can_undo.as_ref().map_or(tip.to_owned(), |w| format!("Undo: {w}")) } else { tip.to_owned() };
            if Btn::new(word).icon(icon).enabled(on).quiet().size(10.5).show(ui, p, br, ("auto-hand", i)).on_hover_text(tip).clicked() {
                match i {
                    0 => desk.skip(),
                    1 => desk.later(2),
                    2 => desk.later(-1),
                    3 => desk.longer(),
                    _ => desk.undo(),
                }
            }
        }
        // the room's word on the next records: less or more energy, more like this one,
        // something different (lit while it holds; a second press takes it back)
        let steer = desk.steer();
        let ry = hy + 26.0 + 10.0;
        kit::section(p, pos2(inner.left(), ry + 13.0), Align2::LEFT_CENTER, "Room");
        let words: [(&str, bool); 4] = [
            (if steer.energy < 0.0 { "Less ·" } else { "Less" }, steer.energy < 0.0),
            (if steer.energy > 0.0 { "More ·" } else { "More" }, steer.energy > 0.0),
            ("Like this", steer.like.is_some()),
            ("Different", steer.different),
        ];
        let mut x = inner.left() + 52.0;
        for (i, (word, on)) in words.into_iter().enumerate() {
            let w = kit::chip_width(p, word);
            let cr = Rect::from_min_size(pos2(x, ry), vec2(w, 26.0));
            if kit::chip(ui, p, cr, word, on, Tone::Neutral, s.auto, ("room", i)).clicked() {
                match (i, on) {
                    (0, _) => desk.more_energy(-1),
                    (1, _) => desk.more_energy(1),
                    (2, false) => desk.more_like_this(),
                    (3, false) => desk.something_different(),
                    _ => desk.steer_neutral(),
                }
            }
            x = cr.right() + 6.0;
        }
        // the last transition, and a thumb on it
        let y0 = ry + 26.0 + 10.0;
        if let Some(last) = last {
            let ty = y0 + 13.0;
            let up = Rect::from_min_size(pos2(inner.right() - 2.0 * 84.0 - 6.0, y0), vec2(84.0, 26.0));
            let down = Rect::from_min_size(pos2(inner.right() - 84.0, y0), vec2(84.0, 26.0));
            let what = format!("Last: {} · {}", last.kind.word(), last.to.title);
            kit::clipped(p, pos2(inner.left(), ty), &what, 12.0, "", t::muted(), up.left() - inner.left() - 10.0);
            let rated = last.rating;
            if Btn::new("Good one").icon(Icon::Heart).on(rated == Some(1)).enabled(rated.is_none()).size(10.5).show(ui, p, up, "rate-up").on_hover_text("Tell the Auto DJ this mix worked").clicked() {
                desk.rate(1);
            }
            if Btn::new("So-so").on(rated == Some(-1)).enabled(rated.is_none()).quiet().size(10.5).show(ui, p, down, "rate-down").on_hover_text("Tell the Auto DJ this mix did not").clicked() {
                desk.rate(-1);
            }
        }
    }

    /// What the Auto DJ would play next, best first (the house's choices, steered), with
    /// why each on hover.
    fn up_next(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, area: Rect, s: &Snapshot) {
        if s.up_next.is_empty() {
            kit::hint(p, area.left_top() + vec2(0.0, 6.0), Align2::LEFT_TOP, "Nothing lined up yet");
            return;
        }
        let ctx = ui.ctx().clone();
        let row = 32.0;
        let room = (area.height() / row).floor().max(0.0) as usize;
        for (i, rec) in s.up_next.iter().take(room).enumerate() {
            let y = area.top() + i as f32 * row;
            let k = motion::appear(&ctx, ui.scope_id().with(("next", rec.id)), motion::EMPHASIS);
            let mut p = p.clone();
            p.multiply_opacity(k);
            let sl = Rect::from_min_size(pos2(area.left(), y + 2.0), vec2(26.0, 26.0));
            let tex = self.sleeves.of(&ctx, desk, rec);
            kit::sleeve(ui, &p, sl, tex, &rec.initials(), col(theme::sleeve(rec.id)), 3, ("next-sleeve", rec.id));
            let meta = if rec.key.is_empty() { format!("{:.0}", rec.bpm) } else { format!("{:.0}  {}", rec.bpm, rec.key) };
            let m = kit::text(&p, pos2(area.right(), y + 15.0), Align2::RIGHT_CENTER, &meta, 11.0, "mono", t::muted());
            let w = m.left() - sl.right() - 18.0;
            kit::clipped(&p, pos2(sl.right() + 8.0, y + 9.0), &rec.title, 12.5, "", t::text(), w);
            kit::clipped(&p, pos2(sl.right() + 8.0, y + 23.0), &rec.artist, 11.0, "", t::muted(), w);
            if let Some(why) = desk.choice_why(rec.id) {
                ui.interact(Rect::from_min_max(pos2(area.left(), y), pos2(area.right(), y + row)), ui.scope_id().with(("next-why", rec.id)), Sense::hover()).on_hover_text(why);
            }
        }
    }

    /// The transition drawn: each deck's level over the bars as the mix will move it, the
    /// bass's change of hands, the bars, and where it is.
    fn timeline(&self, ui: &Ui, p: &Painter, r: Rect, s: &Snapshot, from: usize, to: usize) {
        p.rect_filled(r, CornerRadius::same(t::R_CONTROL), Color32::from_black_alpha(60));
        let Some(m) = s.mix.clone().filter(|_| s.auto) else {
            let say = if s.auto { "Each mix chosen from key, tempo and the phrases" } else { "The Auto DJ is paused: the decks are yours" };
            kit::hint(p, r.center(), Align2::CENTER_CENTER, say);
            return;
        };
        let bars = m.bars.max(1);
        let dim = if m.mixing { 1.0 } else { 0.5 };
        for b in 0..=bars {
            let x = r.left() + r.width() * b as f32 / bars as f32;
            let major = b % 4 == 0;
            if bars <= 64 || major {
                p.line_segment([pos2(x, r.bottom() - if major { 7.0 } else { 4.0 }), pos2(x, r.bottom())], Stroke::new(1.0, white(if major { 0.22 } else { 0.1 })));
            }
        }
        let n = 48;
        let curve = |level: &dyn Fn((f32, f32)) -> f32, color: Color32| {
            let pts: Vec<egui::Pos2> = (0..=n)
                .map(|i| {
                    let k = i as f64 / n as f64;
                    let lv = wo_deskcore::mix_levels_at(m.kind, m.bars, k);
                    pos2(r.left() + r.width() * k as f32, r.bottom() - 6.0 - (r.height() - 12.0) * level(lv))
                })
                .collect();
            let mut fill = Mesh::default();
            for (i, q) in pts.iter().enumerate() {
                fill.colored_vertex(*q, alpha_of(color, 0.16 * dim));
                fill.colored_vertex(pos2(q.x, r.bottom() - 6.0), alpha_of(color, 0.0));
                if i > 0 {
                    let k = 2 * (i as u32 - 1);
                    fill.add_triangle(k, k + 1, k + 2);
                    fill.add_triangle(k + 1, k + 3, k + 2);
                }
            }
            p.add(fill);
            p.add(Shape::line(pts, Stroke::new(1.6, alpha_of(color, 0.95 * dim))));
        };
        curve(&|lv| lv.0, t::deck(from));
        curve(&|lv| lv.1, t::deck(to));
        if let Some(sw) = m.swap_bar {
            let x = r.left() + r.width() * (sw / bars as f64) as f32;
            p.line_segment([pos2(x, r.top() + 4.0), pos2(x, r.bottom() - 4.0)], Stroke::new(1.0, white(0.5 * dim)));
            // (on the move's last bar the word goes the other side of its line)
            let (lx, anchor) = if x > r.right() - 40.0 { (x - 5.0, Align2::RIGHT_TOP) } else { (x + 5.0, Align2::LEFT_TOP) };
            label_sized(p, pos2(lx, r.top() + 4.0), anchor, "Bass", 9.5, alpha_of(t::soft(), dim));
        } else if m.kind == Transition::Cut {
            label_sized(p, pos2(r.left() + 6.0, r.top() + 4.0), Align2::LEFT_TOP, "On the one", 9.5, alpha_of(t::soft(), dim));
        }
        if m.mixing {
            let k = (m.bar / bars as f64).clamp(0.0, 1.0) as f32;
            let x = motion::spring(ui.ctx(), ui.scope_id().with("mix-x"), r.left() + r.width() * k, 0.08);
            p.rect_filled(Rect::from_min_max(pos2(x - 1.0, r.top()), pos2(x + 1.0, r.bottom())), CornerRadius::ZERO, Color32::WHITE);
            p.rect_filled(Rect::from_min_max(pos2(x - 4.0, r.top()), pos2(x + 4.0, r.bottom())), CornerRadius::ZERO, white(0.08));
        }
    }
}

/// The crate's columns: x from the list's left of #, sleeve, title, artist, BPM, key, time,
/// fits; and whether the time and the fit have room.
struct Cols {
    x: [f32; 8],
    time: bool,
    fits: bool,
}

impl Cols {
    fn for_width(w: f32) -> Cols {
        let fits = w >= 820.0;
        let time = w >= 660.0;
        let widths = |t: f32, a: f32| [28.0, 34.0, t, a, 64.0, 48.0, if time { 56.0 } else { 0.0 }, if fits { 110.0 } else { 0.0 }];
        let fixed: f32 = widths(0.0, 0.0).iter().sum::<f32>() + 7.0 * 12.0 + 28.0;
        let flex = (w - fixed).max(160.0);
        let ws = widths(flex * 0.58, flex * 0.42);
        let mut x = [0.0; 8];
        let mut acc = 16.0;
        for i in 0..8 {
            x[i] = acc;
            acc += ws[i] + 12.0;
        }
        Cols { x, time, fits }
    }
}

/// A Camelot key in wheel order ("8A" → (8, 0)); unknown keys last.
fn camelot(k: &str) -> (u8, u8) {
    let n: String = k.chars().take_while(|c| c.is_ascii_digit()).collect();
    match (n.parse::<u8>(), k.chars().last()) {
        (Ok(n), Some('A' | 'a')) => (n, 0),
        (Ok(n), Some('B' | 'b')) => (n, 1),
        _ => (99, 9),
    }
}

/// 12774 → "12,774".
fn thousands(n: i64) -> String {
    let s = n.abs().to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    if n < 0 { format!("-{out}") } else { out }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_sort_round_the_wheel() {
        let mut keys = vec!["10A", "", "1B", "1A", "9B"];
        keys.sort_by_key(|k| camelot(k));
        assert_eq!(keys, ["1A", "1B", "9B", "10A", ""]);
    }

    #[test]
    fn thousands_are_grouped() {
        assert_eq!(thousands(12774), "12,774");
        assert_eq!(thousands(999), "999");
        assert_eq!(thousands(-1000), "-1,000");
    }
}

/// What the Auto DJ has been doing, newest first: the time into the set and the line.
fn auto_log(desk: &Desk, p: &Painter, area: Rect) {
    let log = desk.log();
    if log.is_empty() {
        kit::hint(p, area.left_top() + vec2(0.0, 6.0), Align2::LEFT_TOP, "It writes here as it plans and mixes");
        return;
    }
    let rows = (area.height() / 18.0).floor().max(0.0) as usize;
    for (i, line) in log.iter().take(rows).enumerate() {
        let y = area.top() + i as f32 * 18.0 + 8.0;
        let c = match line.kind {
            wo_deskcore::autodj::LogKind::Trouble => t::warm(),
            wo_deskcore::autodj::LogKind::Hand => t::soft(),
            _ => t::muted(),
        };
        let tr = kit::text(p, pos2(area.left(), y), Align2::LEFT_CENTER, &wo_deskcore::autodj::clock(line.at), 10.5, "mono", t::faint());
        kit::clipped(p, pos2(tr.right() + 8.0, y), &line.text, 11.5, "", c, area.right() - tr.right() - 8.0);
    }
}
