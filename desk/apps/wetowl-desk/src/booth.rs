//! The booth's panels — top bar, overviews, waveforms, decks, mixer, crate, stage card,
//! Auto DJ — on the kit (ui::kit), where ui::layout puts them.
use std::hash::{Hash, Hasher};

use eframe::egui::{self, Align2, Color32, CornerRadius, Mesh, Painter, Rect, Sense, Shape, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::theme;
use wo_deskcore::parts::{Part, Stems};
use wo_deskcore::{Desk, Record, Shelf, ShowHand, Snapshot, Style, Transition};

use crate::paint::{col, label_sized, label_width, mmss, pad_colour, pad_name, white};
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
        self.flights(desk, ui);
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
        // the master's beat in its bar: four steps, the one lit on the beat
        let beat = v.playing.then(|| desk.beat_at(m, v.heard)).flatten();
        let mut bx = chip.right() + 12.0;
        for i in 0..4 {
            let r4 = Rect::from_min_size(pos2(bx, mid.y - 6.0), vec2(5.0, 12.0));
            let (lit, k) = match beat {
                Some((into, b)) if b == i => (true, (1.0 - (into * 60.0 / v.bpm.max(1.0)) as f32 / 0.18).clamp(0.0, 1.0)),
                _ => (false, 0.0),
            };
            let base = if v.playing { Color32::from_rgb(0x3A, 0x3E, 0x47) } else { Color32::from_rgb(0x2A, 0x2D, 0x34) };
            let on = if i == 0 { t::tint(m) } else { t::deck(m) };
            p.rect_filled(r4, CornerRadius::same(2), if lit { mix(alpha_of(on, 0.55), on, k) } else { base });
            bx = r4.right() + 3.0;
        }
        let dot_c = pos2(bx - 3.0, mid.y);
        let set = s.set_seconds as u64;
        let st = kit::label(p, pos2(dot_c.x + 30.0, mid.y), Align2::LEFT_CENTER, "Set");
        kit::text(p, pos2(st.right() + 8.0, mid.y), Align2::LEFT_CENTER, &format!("{}:{:02}:{:02}", set / 3600, set / 60 % 60, set % 60), 14.0, "mono", t::soft());

        // the right: settings, keys; the house, the gear and the stage as icons (each as it
        // is, its detail on hover); the Auto DJ
        let y = r.center().y;
        let gear = Rect::from_min_size(pos2(r.right() - 9.0 - 32.0, y - 16.0), vec2(32.0, 32.0));
        if Btn::new("").icon(Icon::Settings).quiet().on(self.overlay == Some(Overlay::Settings)).show(ui, p, gear, "settings").on_hover_text("Settings  (Ctrl ,)").clicked() {
            self.overlay = if self.overlay == Some(Overlay::Settings) { None } else { Some(Overlay::Settings) };
        }
        let keys = Rect::from_min_size(pos2(gear.left() - 36.0, y - 16.0), vec2(32.0, 32.0));
        if Btn::new("").icon(Icon::Keys).quiet().on(self.overlay == Some(Overlay::Keys)).show(ui, p, keys, "keys").on_hover_text("The keys  (?)").clicked() {
            self.overlay = if self.overlay == Some(Overlay::Keys) { None } else { Some(Overlay::Keys) };
        }
        let div = keys.left() - 10.0;
        p.line_segment([pos2(div, y - 11.0), pos2(div, y + 11.0)], Stroke::new(1.0, white(0.1)));
        let left = self.status_icons(desk, ui, p, pos2(div - 10.0, y), s);
        let auto = Rect::from_min_size(pos2(left - 14.0 - 118.0, y - 16.0), vec2(118.0, 32.0));
        if Btn::new("Auto DJ").icon(Icon::AutoMix).tone(Tone::Ok).on(s.auto).show(ui, p, auto, "auto").on_hover_text("The Auto DJ mixes the next record in  (A)").clicked() {
            desk.set_auto(!s.auto);
        }
        // a mix under way: its progress along the button's foot, in the deck it goes to
        if let Some(m) = s.mix.as_ref().filter(|m| m.mixing && s.auto) {
            let k = (m.bar / m.bars.max(1) as f64).clamp(0.0, 1.0) as f32;
            let x = motion::spring(ui.ctx(), ui.scope_id().with("auto-foot"), auto.left() + 6.0 + (auto.width() - 12.0) * k, 0.1);
            p.rect_filled(Rect::from_min_max(pos2(auto.left() + 6.0, auto.bottom() - 4.0), pos2(x, auto.bottom() - 2.0)), CornerRadius::same(1), t::deck(m.to));
        }
    }

    /// The house, the controllers and the stage as icons, right to left from `right`; the
    /// sound's load too while it works hard. Their left edge.
    fn status_icons(&mut self, desk: &Desk, ui: &mut Ui, p: &Painter, right: egui::Pos2, s: &Snapshot) -> f32 {
        use crate::ui::kit::State;
        let house = desk.house().map(|(sv, u)| (sv.trim_start_matches("https://").to_owned(), u.map(str::to_owned)));
        let controllers = desk.controllers();
        let stage = desk.stage();
        let lib = desk.library();
        let mut x = right.x;
        let mut item = |icon: Icon, state: State, tip: String, key: &str| -> bool {
            let rr = Rect::from_min_size(pos2(x - 30.0, right.y - 15.0), vec2(30.0, 30.0));
            let clicked = Btn::new("").quiet().show(ui, p, rr, ("status", key)).on_hover_text(tip).clicked();
            kit::status(ui, p, rr, icon, state, ("status-icon", key));
            x = rr.left() - 4.0;
            clicked
        };
        // the stage: open (lit), opening (busy), in trouble, closed
        let (st, tip) = if stage.trouble.is_some() {
            (State::Trouble, format!("The stage: {}", stage.trouble.clone().unwrap_or_default()))
        } else if stage.stages > 0 {
            (State::On, format!("The stage is showing{}  ·  a click: the Show page", if stage.rust { " (the Rust one)" } else { "" }))
        } else if stage.starting {
            (State::Busy, "The stage window is opening".to_owned())
        } else {
            (State::Off, "The stage is closed  ·  a click: the Show page".to_owned())
        };
        if item(Icon::Screen, st, tip, "stage") {
            self.page = Page::Show;
        }
        // the controllers
        let (st, tip) = if controllers.is_empty() {
            (State::Off, "No controller found  ·  a click: the controllers".to_owned())
        } else {
            let lines: Vec<String> = controllers.iter().map(|c| match &c.trouble { None => format!("{} · {}", c.name, c.layout), Some(why) => format!("{}: {why}", c.name) }).collect();
            (if controllers.iter().all(|c| c.trouble.is_none()) { State::On } else { State::Trouble }, format!("{}\na click: the controllers", lines.join("\n")))
        };
        if item(Icon::Controller, st, tip, "gear") {
            self.overlay = Some(Overlay::Controllers);
        }
        // the house
        let (st, tip) = match &house {
            _ if lib.signing_in => (State::Busy, "Signing in…".to_owned()),
            Some((sv, Some(u))) => (State::On, format!("Signed in to the house: {u} at {sv}")),
            Some((sv, None)) => (State::On, format!("Signed in to the house at {sv}")),
            None => (State::Off, "Not signed in to the house: the crate's left column signs in".to_owned()),
        };
        if item(Icon::House, st, tip, "house") {
            self.overlay = Some(Overlay::Settings);
        }
        // the sound's load: only while it works hard
        let pct = (s.load.average * 100.0).round();
        let hot = s.load.average > 0.6 || s.load.worst > 0.95;
        let tip = format!("The sound is working hard: {pct:.0}% of its time, {:.0}% at worst; {} late", s.load.worst * 100.0, s.load.late);
        if hot {
            item(Icon::Gauge, State::Trouble, tip.clone(), "dsp");
        }
        if hot {
            let tr = kit::text(p, pos2(x - 2.0, right.y), Align2::RIGHT_CENTER, &format!("{pct:.0}%"), 11.5, "mono", t::warm());
            x = tr.left() - 2.0;
            ui.interact(tr, ui.scope_id().with("dsp-tip"), Sense::hover()).on_hover_text(tip);
        }
        x
    }

    fn deck(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        kit::panel(p, r, false);
        let v = &s.decks[d];
        let inner = r.shrink(t::INSET);
        let ctx = ui.ctx().clone();
        // on air: the panel's top edge lit in the deck's colour by how much of it the room hears
        let air = motion::spring(&ctx, ui.scope_id().with(("air", d)), v.audible, 0.08);
        if air > 0.01 {
            let y = r.top() + 1.5;
            let mut g = Mesh::default();
            let (c0, c1) = (alpha_of(t::deck(d), 0.0), alpha_of(t::deck(d), 0.9 * air));
            let (x0, x1) = (r.left() + 14.0, r.right() - 14.0);
            let xm = (x0 + x1) / 2.0;
            for (x, c) in [(x0, c0), (xm, c1), (x1, c0)] {
                g.colored_vertex(pos2(x, y - 1.0), c);
                g.colored_vertex(pos2(x, y + 1.0), c);
            }
            g.add_triangle(0, 1, 2);
            g.add_triangle(1, 3, 2);
            g.add_triangle(2, 3, 4);
            g.add_triangle(3, 5, 4);
            p.add(g);
        }

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

        // a wide deck: the platter large in a column of its own; a narrow one: small, in the
        // header, where a sleeve would be
        let wide = inner.width() >= 600.0;
        let head_h = if wide { 52.0 } else { 72.0 };
        let mut x = inner.left();
        if !wide {
            let pr = Rect::from_min_size(inner.min, vec2(72.0, 72.0));
            self.platter(desk, ui, p, pr, v, d, true);
            self.platter_at[d] = pr;
            x = pr.right() + 14.0;
        }
        // the readouts at the right: tempo and pitch · key; the time left and gone
        let (time_size, bpm_size) = if wide { (t::DISPLAY_M, t::DISPLAY_L) } else { (17.0, 24.0) };
        let (y1, y2) = if wide { (inner.top() + 14.0, inner.top() + 40.0) } else { (inner.top() + 15.0, inner.top() + 44.0) };
        let left = kit::text(p, pos2(inner.right(), y1), Align2::RIGHT_CENTER, &format!("−{}", mmss(v.length - v.heard)), time_size, "mono", if v.playing && v.length > 0.0 && v.length - v.heard < 30.0 { t::warm() } else { t::text() });
        kit::text(p, pos2(inner.right(), y2), Align2::RIGHT_CENTER, &mmss(v.heard), 12.0, "mono", t::label());
        let sep = left.left().min(inner.right() - if wide { 112.0 } else { 84.0 }) - 14.0;
        p.line_segment([pos2(sep, inner.top() + 4.0), pos2(sep, inner.top() + head_h - 8.0)], Stroke::new(1.0, col(theme::EDGE)));
        let bpm = kit::text(p, pos2(sep - 14.0, y1 + 2.0), Align2::RIGHT_CENTER, &format!("{:.2}", v.bpm), bpm_size, "mono-semi", t::text());
        let pitch = (v.rate - 1.0) * 100.0;
        let key_w = self.key_chip(p, pos2(sep - 14.0, y2), v, s, d);
        kit::text(p, pos2(sep - 14.0 - key_w - 8.0, y2), Align2::RIGHT_CENTER, &format!("{pitch:+.2}%"), 12.0, "mono", if pitch.abs() < 0.005 { t::muted() } else { t::soft() });
        // title and artist rise into place when a record loads
        let k = motion::appear(&ctx, ui.scope_id().with(("title", d, v.record.id)), motion::EMPHASIS);
        let dy = 6.0 * (1.0 - k);
        let chip = kit::deck_chip(p, pos2(x, y1 + 1.0), d);
        let room = bpm.left() - chip.right() - 28.0;
        let empty = !v.record.playable();
        let title = if empty { "No record" } else { v.record.title.as_str() };
        let tr = kit::clipped(p, pos2(chip.right() + 10.0, y1 + 1.0 + dy), title, t::TITLE, "semi", alpha_of(if empty { t::faint() } else { t::text() }, k), room);
        if tr.width() >= room - 1.0 {
            ui.interact(tr, ui.scope_id().with(("title-tip", d)), Sense::hover()).on_hover_text(format!("{} — {}", v.record.title, v.record.artist));
        }
        // the artist, and what is known of the record: four icons, lit where it is there
        let marks_w = 4.0 * 19.0;
        let ar = kit::clipped(p, pos2(x, y2 + dy), &v.record.artist, t::BODY, "", alpha_of(t::muted(), k), (bpm.left() - x - 28.0 - marks_w).max(40.0));
        if !empty {
            let mut mx = if v.record.artist.is_empty() { x } else { ar.right() + 12.0 };
            for (i, (icon, tip)) in [(Icon::Layers, "Its stems: the parts and the stem moves"), (Icon::Grid, "Its beat grid"), (Icon::Sections, "Its sections: intro, drops, breakdowns"), (Icon::Mic, "Where it sings")].into_iter().enumerate() {
                let ir = Rect::from_center_size(pos2(mx + 7.0, y2), vec2(13.0, 13.0));
                crate::ui::icons::paint(p, ir, icon, if v.marks[i] { t::soft() } else { alpha_of(t::faint(), 0.45) });
                ui.interact(ir.expand(3.0), ui.scope_id().with(("mark", d, i)), Sense::hover()).on_hover_text(format!("{tip}: {}", if v.marks[i] { "here" } else { "not known" }));
                mx = ir.right() + 6.0;
            }
        }
        // what is on its way to this deck (v1's deck_coming): the record being put on, or the
        // Auto DJ's next, chosen and waiting for this deck to be free
        let coming = if v.loading {
            Some(("Loading".to_owned(), t::warm(), "Being put on: its audio and its analysis on their way".to_owned()))
        } else if s.auto && !v.master && s.mix.is_none() {
            s.up_next.first().filter(|n| n.id != v.record.id).map(|n| (format!("Next · {}", n.title), t::soft(), format!("The Auto DJ's next: {} — {}; it goes on this deck once it is free", n.title, n.artist)))
        } else {
            None
        };

        // the body: transport | platter | hot cues, parts, loop | pitch
        let body = Rect::from_min_max(pos2(inner.left(), inner.top() + head_h + 12.0), inner.max);
        let pitch_r = Rect::from_min_max(pos2(body.right() - if wide { 44.0 } else { 40.0 }, body.top()), body.max);
        let trans_r = Rect::from_min_size(body.min, vec2(if wide { 84.0 } else { 72.0 }, body.height()));
        let mut x = trans_r.right() + 14.0;
        let mut coming_at = None;
        if wide {
            let side = (pitch_r.left() - 12.0 - x - 340.0).min(body.height()).max(120.0);
            let pr = Rect::from_center_size(pos2(x + side / 2.0, body.center().y), vec2(side, side));
            self.platter(desk, ui, p, pr, v, d, false);
            self.platter_at[d] = pr;
            coming_at = Some(pos2(pr.center().x, pr.bottom() - 12.0));
            x = pr.right() + 14.0;
        } else if let Some((w, c, _)) = &coming {
            coming_at = None;
            let _ = (w, c);
        }
        if let Some((words, ink, tip)) = coming {
            match coming_at {
                Some(at) => {
                    crate::platter::coming_tab(p, at, &words.to_uppercase(), ink);
                    ui.interact(Rect::from_center_size(at, vec2(120.0, 20.0)), ui.scope_id().with(("coming", d)), Sense::hover()).on_hover_text(tip);
                }
                None => {
                    let wr = kit::clipped(p, pos2(x - 14.0 - 72.0 + 86.0, inner.top() + 64.0), &words, 11.0, "", ink, bpm.left() - x - 20.0);
                    ui.interact(wr, ui.scope_id().with(("coming", d)), Sense::hover()).on_hover_text(tip);
                }
            }
        }
        let right = Rect::from_min_max(pos2(x, body.top()), pos2(pitch_r.left() - 12.0, body.bottom()));
        let rows_h = 26.0 + 8.0 + 26.0;
        let pads_r = Rect::from_min_max(right.min, pos2(right.right(), right.bottom() - rows_h - 10.0));
        let loop_r = Rect::from_min_max(pos2(right.left(), right.bottom() - rows_h), right.max);
        self.transport(desk, ui, p, trans_r, s, d, wide);
        self.pads(desk, ui, p, pads_r, s, d);
        self.loop_row(desk, ui, p, loop_r, s, d);
        self.pitch(desk, ui, p, pitch_r, s, d);
    }

    /// The key as a chip in its colour on the Camelot wheel, its edge green where it mixes
    /// with the other deck's (the same, one round, or its relative); its width. Right-aligned
    /// at `right_center`.
    fn key_chip(&self, p: &Painter, right_center: egui::Pos2, v: &wo_deskcore::DeckView, s: &Snapshot, d: usize) -> f32 {
        let key = v.record.key.as_str();
        if key.is_empty() {
            return kit::text(p, right_center, Align2::RIGHT_CENTER, "—", 12.0, "mono", t::faint()).width();
        }
        let g = p.layout_no_wrap(key.to_owned(), egui::FontId::new(11.5, crate::paint::family("mono-semi")), t::text());
        let r = Align2::RIGHT_CENTER.anchor_size(right_center, vec2(g.size().x + 12.0, 18.0));
        let (n, ab) = camelot(key);
        let hue = if n <= 12 { ((n as f32 - 1.0) / 12.0 * 360.0 + 20.0) % 360.0 } else { 0.0 };
        let c = if n <= 12 { egui::ecolor::Hsva::new(hue / 360.0, if ab == 1 { 0.45 } else { 0.62 }, 0.92, 1.0).into() } else { t::soft() };
        let other = &s.decks[1 - d];
        let fits = other.record.playable() && {
            let (m, mb) = camelot(&other.record.key);
            m <= 12 && n <= 12 && ((m == n) || (mb == ab && (m % 12 + 1 == n || n % 12 + 1 == m)))
        };
        p.rect(r, CornerRadius::same(4), alpha_of(c, 0.16), Stroke::new(1.0, if fits { t::ok() } else { alpha_of(c, 0.5) }), StrokeKind::Inside);
        p.galley(pos2(r.center().x - g.size().x / 2.0, r.center().y - g.size().y / 2.0), g, c);
        r.width()
    }

    /// CUE and PLAY large; SYNC, KEY LOCK, the bass's kill and BRAKE as icon toggles (the
    /// nudge is the platter's: a drag on it).
    #[allow(clippy::too_many_arguments)]
    fn transport(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize, wide: bool) {
        let v = &s.decks[d];
        let g = 8.0;
        let small = if wide { 36.0 } else { 30.0 };
        let big = ((r.height() - 3.0 * g - 2.0 * small) / 2.0).clamp(36.0, 56.0);
        let top = r.top() + (r.height() - (2.0 * big + 2.0 * small + 3.0 * g)) / 2.0;
        // CUE acts on press and on release (a preview runs while it is held)
        let cue_r = Rect::from_min_size(pos2(r.left(), top), vec2(r.width(), big));
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
        let play_r = Rect::from_min_size(pos2(r.left(), cue_r.bottom() + g), vec2(r.width(), big));
        // PLAY's icon turns into PAUSE and back
        let k = motion::tween_bool(ui.ctx(), ui.scope_id().with(("playing", d)), v.playing, motion::STANDARD, motion::STANDARD);
        let play = Btn::new("").tone(Tone::Deck(d)).on(v.playing);
        let resp = play.show(ui, p, play_r, (d, "play")).on_hover_text(["Play A  (1)", "Play B  (2)"][d]);
        let ink = mix(t::soft(), t::tint(d), k);
        play_pause(p, play_r.center(), (big * 0.24).min(11.0), k, ink);
        if resp.clicked() {
            desk.toggle_play(d);
        }
        let killed = v.eq[0] <= 0.01;
        let cell = |i: usize| {
            let w = (r.width() - g) / 2.0;
            Rect::from_min_size(pos2(r.left() + (i % 2) as f32 * (w + g), play_r.bottom() + g + (i / 2) as f32 * (small + g)), vec2(w, small))
        };
        let toggles: [(&str, Icon, Tone, bool, String); 4] = [
            ("Sync", Icon::Sync, Tone::Ok, v.synced, format!("Sync: in step with the other deck  ({})", ["Q", "W"][d])),
            ("Key lock", Icon::Lock, Tone::Neutral, v.keylock, "Key lock: its key stays as its tempo moves".to_owned()),
            ("Bass", Icon::Kill, Tone::Danger, killed, format!("The bass off and on  ({})", ["F", "G"][d])),
            ("Brake", Icon::Brake, Tone::Neutral, false, "Brake: the record runs down to a stop".to_owned()),
        ];
        for (i, (word, icon, tone, on, tip)) in toggles.into_iter().enumerate() {
            if Btn::new(word).icon(icon).tone(tone).on(on).bare(true).show(ui, p, cell(i), (d, "toggle", i)).on_hover_text(tip).clicked() {
                match i {
                    0 => desk.toggle_sync(d),
                    1 => desk.toggle_keylock(d),
                    2 => desk.kill(d, 0),
                    _ => desk.brake(d),
                }
            }
        }
    }

    /// The hot cues: a click sets an empty one or jumps to a set one; shift- or right-click
    /// clears. Under them, the record's parts.
    fn pads(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        let top = r.top();
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
        let icons = [Icon::Disc, Icon::Drum, Icon::Note, Icon::MicOff, Icon::Mic];
        let items: Vec<(&str, Option<Icon>)> = names.iter().enumerate().map(|(i, n)| (*n, icons.get(i).copied())).collect();
        let seg = kit::segmented_with(ui, p, r, &items, chosen, Tone::Deck(d), (d, "parts"));
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

    /// The loop: a length from the bar (again lets go); under it IN / OUT, half and double,
    /// and the jumps.
    fn loop_row(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        let lengths = [("¼", 0.25), ("½", 0.5), ("1", 1.0), ("2", 2.0), ("4", 4.0), ("8", 8.0), ("16", 16.0), ("32", 32.0)];
        let row1 = Rect::from_min_size(r.min, vec2(r.width(), 26.0));
        let row2 = Rect::from_min_max(pos2(r.left(), r.bottom() - 26.0), r.max);
        crate::ui::icons::paint(p, Rect::from_center_size(pos2(row1.left() + 9.0, row1.center().y), vec2(16.0, 16.0)), Icon::Loop, if v.looped.is_some() { t::tint(d) } else { t::label() });
        let seg = Rect::from_min_max(pos2(row1.left() + 26.0, row1.top()), row1.max);
        let chosen = v.looped.and(v.loop_beats).and_then(|b| lengths.iter().position(|l| l.1 == b));
        let names: Vec<&str> = lengths.iter().map(|l| l.0).collect();
        if let Some(i) = kit::segmented(ui, p, seg, &names, chosen, Tone::Deck(d), (d, "loops")) {
            desk.loop_beats(d, lengths[i].1);
        }
        let looped_by_hand = v.looped.is_some() && v.loop_beats.is_none();
        let jumps_w = 2.0 * 34.0 + 4.0;
        let bw = ((row2.width() - jumps_w - 12.0 - 3.0 * 4.0) / 4.0).min(52.0);
        let mut x = row2.left();
        for (word, on, act, tip) in [("In", v.loop_open, 0, "A loop's start here"), ("Out", looped_by_hand, 1, "Its end here: it loops"), ("½", false, 2, "The loop half as long"), ("×2", false, 3, "The loop twice as long")] {
            let br = Rect::from_min_size(pos2(x, row2.top()), vec2(bw, row2.height()));
            if Btn::new(word).tone(Tone::Deck(d)).on(on).size(11.0).show(ui, p, br, (d, "loopbtn", act)).on_hover_text(tip).clicked() {
                match act {
                    0 => desk.loop_in(d),
                    1 => desk.loop_out(d),
                    2 => desk.halve_loop(d),
                    _ => desk.double_loop(d),
                }
            }
            x = br.right() + 4.0;
        }
        let mut x = row2.right() - jumps_w;
        for (icon, beats, k) in [(Icon::Back4, -4.0, 0), (Icon::Ahead4, 4.0, 1)] {
            let br = Rect::from_min_size(pos2(x, row2.top()), vec2(34.0, row2.height()));
            if Btn::new("").icon(icon).quiet().show(ui, p, br, (d, "jump", k)).on_hover_text(if k == 0 { "Back 4 beats" } else { "Ahead 4 beats" }).clicked() {
                desk.jump(d, beats);
            }
            x = br.right() + 4.0;
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
        let level = |pk: f32| (1.0 + 20.0 * pk.max(1e-6).log10() / 48.0).clamp(0.0, 1.0);
        let db = |v: f32| if v >= 0.5 { (v - 0.5) * 12.0 } else { -40.0 * ((0.5 - v) * 2.0).powf(1.5) };
        for d in 0..2 {
            let v = &s.decks[d];
            let side = if d == 0 { 1.0 } else { -1.0 };
            let edge = if d == 0 { inner.left() } else { inner.right() };
            let knobs_x = edge + side * 22.0;
            for (i, name) in names.iter().enumerate() {
                let c = pos2(knobs_x, inner.top() + 16.0 + i as f32 * step);
                let (val, bip, color) = match i {
                    0 => (v.gain, false, Color32::from_rgb(0x9D, 0xA1, 0xAA)),
                    1 => (v.eq[2], true, t::deck(d)),
                    2 => (v.eq[1], true, t::deck(d)),
                    3 => (v.eq[0], true, t::deck(d)),
                    _ => (v.filter, true, Color32::from_rgb(0x9D, 0xA1, 0xAA)),
                };
                let tag = move |x: f32| match i {
                    0 => format!("{:+.1} dB", (x - 0.5) * 24.0),
                    4 => {
                        let k = (x - 0.5) * 2.0;
                        if k.abs() < 0.04 { "off".to_owned() } else if k < 0.0 { format!("low-pass {:.0}%", -k * 100.0) } else { format!("high-pass {:.0}%", k * 100.0) }
                    }
                    _ if x <= 0.01 => "killed".to_owned(),
                    _ => format!("{:+.1} dB", db(x)),
                };
                if let Some(nv) = kit::knob_with(ui, p, c, val, color, bip, 0.5, (d, "knob", i), tag) {
                    match i {
                        0 => desk.set_gain(d, nv),
                        1 => desk.set_eq(d, 2, nv),
                        2 => desk.set_eq(d, 1, nv),
                        3 => desk.set_eq(d, 0, nv),
                        _ => desk.set_filter(d, nv),
                    }
                }
                label_sized(p, pos2(c.x, c.y + 17.0), Align2::CENTER_TOP, name, 9.5, t::label());
                // the bands' kills beside their knobs
                if (1..=3).contains(&i) {
                    let band = 3 - i;
                    let killed = v.eq[band] <= 0.01;
                    let kr = Rect::from_center_size(pos2(edge + side * 56.0, c.y), vec2(22.0, 22.0));
                    let word = ["The lows", "The mids", "The highs"][band];
                    let keys = if band == 0 { format!("  ({})", ["F", "G"][d]) } else { String::new() };
                    if Btn::new("").icon(Icon::Kill).tone(Tone::Danger).on(killed).quiet().show(ui, p, kr, (d, "kill", band)).on_hover_text(format!("{word} off and on{keys}")).clicked() {
                        desk.kill(d, band);
                    }
                }
            }
            // the channel fader, its meter on the inside
            let fx = edge + side * 100.0;
            kit::deck_chip(p, pos2(fx - 10.0, inner.top() + 6.0), d);
            let top = inner.top() + 26.0;
            let fr = Rect::from_min_max(pos2(fx - 17.0, top), pos2(fx + 17.0, strip_bottom));
            if let Some(nv) = kit::vfader(ui, p, fr, v.fader, t::deck(d), (d, "fader")) {
                desk.set_fader(d, nv);
            }
            let mx = fx + side * 27.0 - 3.0;
            kit::meter(ui, p, Rect::from_min_max(pos2(mx, top + 8.0), pos2(mx + 6.0, strip_bottom - 2.0)), level(v.peak), 18, (d, "meter"));
        }
        // the master: each side as the decks give it, a scale beside it
        let mc = inner.center().x;
        kit::label(p, pos2(mc, inner.top() + 6.0), Align2::CENTER_CENTER, "Master");
        let top = inner.top() + 34.0;
        let (l, rr) = (s.decks[0].peak_lr.0.max(s.decks[1].peak_lr.0), s.decks[0].peak_lr.1.max(s.decks[1].peak_lr.1));
        let mr = Rect::from_min_max(pos2(mc - 9.0, top), pos2(mc - 2.0, strip_bottom - 2.0));
        kit::meter(ui, p, mr, level(l), 18, "master-l");
        kit::meter(ui, p, Rect::from_min_max(pos2(mc + 2.0, top), pos2(mc + 9.0, strip_bottom - 2.0)), level(rr), 18, "master-r");
        for (dbv, word) in [(0.0f32, "0"), (-6.0, "6"), (-12.0, "12"), (-24.0, "24"), (-36.0, "36")] {
            let k = 1.0 + dbv / 48.0;
            let y = mr.bottom() - k * mr.height();
            kit::text(p, pos2(mc - 15.0, y), Align2::RIGHT_CENTER, word, 8.5, "mono", t::faint());
        }
        // the crossfader: a hand on it takes over from the Auto DJ
        let cf = Rect::from_min_max(pos2(inner.left() + 22.0, inner.bottom() - cf_h), pos2(inner.right() - 22.0, inner.bottom()));
        kit::deck_chip(p, pos2(inner.left() - 2.0, cf.center().y), 0);
        kit::deck_chip(p, pos2(inner.right() - 18.0, cf.center().y), 1);
        if let Some(x) = kit::crossfader(ui, p, cf.shrink2(vec2(6.0, 0.0)), s.crossfader, "xf") {
            desk.set_auto(false);
            desk.set_crossfader(x);
        }
    }

    /// The crate's strip for the shelf open: a playlist mixed or queued whole; the similar
    /// ones this person's, a mix, or new to them; the record on a deck checked by ear.
    fn crate_strip(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, shelf: &Shelf, s: &Snapshot) {
        match shelf {
            Shelf::Playlist { name, .. } => {
                let mix = Rect::from_min_size(r.min, vec2(104.0, r.height()));
                if Btn::new("Mix it").icon(Icon::Play).accent(true).size(11.0).show(ui, p, mix, "mix-it").on_hover_text(format!("The Auto DJ mixes {name} from now, in its order (the queue you had kept after it)")).clicked() {
                    desk.mix_shelf();
                    self.toasts.say(format!("Mixing {name}"), Tone::Ok);
                }
                let all = Rect::from_min_size(pos2(mix.right() + 8.0, r.top()), vec2(112.0, r.height()));
                if Btn::new("Queue all").icon(Icon::Plus).size(11.0).show(ui, p, all, "queue-all").on_hover_text("Its records at the end of the queue").clicked() {
                    let n = desk.queue_shelf();
                    self.toasts.say(format!("{n} queued"), Tone::Neutral);
                }
            }
            Shelf::Similar { fresh, seeds, .. } => {
                let seg = Rect::from_min_size(r.min, vec2(210.0, r.height()));
                let freshes = [0u8, 50, 100];
                let at = freshes.iter().position(|f| f == fresh);
                if let Some(i) = kit::segmented(ui, p, seg, &["Mine", "Mix", "New"], at, Tone::Neutral, "similar-fresh") {
                    self.similar_fresh = freshes[i];
                    self.similar_asked = Some(freshes[i]);
                }
                let again = Rect::from_min_size(pos2(seg.right() + 8.0, r.top()), vec2(34.0, r.height()));
                if Btn::new("").icon(Icon::Undo).size(11.0).show(ui, p, again, "similar-again").on_hover_text("Ask again, for what is on now").clicked() {
                    self.similar_asked = Some(*fresh);
                }
                let words = if seeds.is_empty() { "Nothing on the decks or in the queue yet".to_owned() } else { "Like the records on the decks and the next in the queue · a right click: not for me".to_owned() };
                kit::clipped(p, pos2(again.right() + 12.0, r.center().y), &words, 11.5, "", t::faint(), r.right() - again.right() - 12.0);
            }
            Shelf::Check => {
                // a record of the list on a deck, not checked yet: its pads, and what its grid is like
                let lib = desk.library();
                let ids: Vec<i64> = lib.rows.iter().map(|r| r.id).collect();
                let on = (0..2).find(|&d| ids.contains(&s.decks[d].record.id) && !lib.checked.contains_key(&s.decks[d].record.id) && s.decks[d].record.id > 0);
                match on {
                    Some(d) => {
                        let v = &s.decks[d];
                        let pad = |n: usize| match v.pads[n - 1] {
                            Some(p) => format!("{n} {} {}:{:02}", if p.auto.is_some() { "booth" } else { "yours" }, (p.at / 60.0) as i64, (p.at % 60.0) as i64),
                            None => format!("{n} —"),
                        };
                        let lr = kit::text(p, pos2(r.left(), r.center().y), Align2::LEFT_CENTER, &format!("Deck {} · pads {} · {}", ["A", "B"][d], pad(1), pad(4)), 11.0, "mono", t::deck(d));
                        let mut x = lr.right() + 12.0;
                        for (g, word, tip) in wo_deskcore::GRID_VERDICTS {
                            let w = label_width(p, word, 10.5) + 18.0;
                            if x + w > r.right() {
                                break;
                            }
                            let br = Rect::from_min_size(pos2(x, r.top()), vec2(w, r.height()));
                            if Btn::new(word).size(10.5).show(ui, p, br, ("verdict", *g)).on_hover_text(*tip).clicked() {
                                desk.check(d, g);
                                self.toasts.say(format!("Checked: {}", wo_deskcore::verdict_word(Some(g))), Tone::Ok);
                            }
                            x += w + 5.0;
                        }
                    }
                    None => {
                        kit::clipped(
                            p,
                            pos2(r.left(), r.center().y),
                            "Load one. Put pad 1 where it is on and pad 4 where you would leave it, then say what its grid is like",
                            11.5,
                            "",
                            t::faint(),
                            r.width(),
                        );
                    }
                }
            }
            _ => {}
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
                    Shelf::Similar { .. } => "Like what is on".to_owned(),
                    Shelf::Check => format!("Check by ear · {} done", lib.checked.len()),
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
        let strip = matches!(lib.shelf, Shelf::Playlist { .. } | Shelf::Similar { .. } | Shelf::Check) && desk.house().is_some();
        if strip {
            let shelf = lib.shelf.clone();
            self.crate_strip(desk, ui, p, Rect::from_min_size(pos2(main.left() + 14.0, main.top() + 48.0), vec2(main.width() - 28.0, 26.0)), &shelf, s);
        }
        let hy = main.top() + if strip { 92.0 } else { 62.0 };
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
        // where the loaded row's sleeve was (it flies from there to the deck)
        let mut from: Option<Rect> = None;
        let mut queue_it: Option<Record> = None;
        let mut unqueue: Option<i64> = None;
        let mut load_on: Option<(usize, Record)> = None;
        let mut near_end = false;
        let mut add_to: Option<(i64, Record)> = None;
        let lists: Vec<(i64, String)> = desk.library().playlists.iter().map(|l| (l.id, l.name.clone())).collect();
        let on_queue = desk.library().shelf == Shelf::Queue;
        let on_similar = matches!(desk.library().shelf, Shelf::Similar { .. });
        let on_check = desk.library().shelf == Shelf::Check;
        let checked_ids: Vec<i64> = desk.library().checked.keys().copied().collect();
        let mut dismiss: Option<i64> = None;
        let mut uncheck: Option<i64> = None;
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
                    // playing: three bars that move with what it plays
                    if s.decks[d].playing {
                        let lvl = (1.0 + 20.0 * s.decks[d].peak.max(1e-6).log10() / 48.0).clamp(0.0, 1.0);
                        let shown = motion::spring(&ctx, ui.scope_id().with(("air-bars", d)), lvl, 0.12);
                        for (i, k) in [0.7f32, 1.0, 0.55].into_iter().enumerate() {
                            let h = 3.0 + 9.0 * (shown * k).clamp(0.0, 1.0);
                            p.rect_filled(Rect::from_min_max(pos2(tx + i as f32 * 4.0, y + 6.0 - h), pos2(tx + i as f32 * 4.0 + 2.5, y + 6.0)), CornerRadius::same(1), t::tint(d));
                        }
                        tx += 18.0;
                    }
                }
                let ink = if row.on_deck.is_some() { t::muted() } else if row.record.playable() { t::text() } else { t::muted() };
                kit::clipped(&p, pos2(tx, y), &row.record.title, 13.0, "", ink, at(3) - tx - 12.0);
                match &row.note {
                    Some(n) => {
                        let ar = kit::clipped(&p, pos2(at(3), y - 7.0), &row.record.artist, 12.0, "", t::muted(), at(4) - at(3) - 12.0);
                        let _ = ar;
                        kit::clipped(&p, pos2(at(3), y + 8.0), n, 10.5, "", t::faint(), at(4) - at(3) - 12.0);
                    }
                    None => {
                        kit::clipped(&p, pos2(at(3), y), &row.record.artist, 13.0, "", t::muted(), at(4) - at(3) - 12.0);
                    }
                }
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
                    from = Some(sl);
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
                    if on_similar && ui.button("Not for me: never offered again").clicked() {
                        dismiss = Some(rec.id);
                        ui.close();
                    }
                    if on_check && checked_ids.contains(&rec.id) && ui.button("Check it again").clicked() {
                        uncheck = Some(rec.id);
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
                            from = Some(sl);
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
        // the list fades out at its foot where more is below, and under its head when scrolled
        let fade = |y0: f32, y1: f32, top_solid: bool| {
            let mut g = Mesh::default();
            let solid = Color32::from_rgba_unmultiplied(11, 12, 16, 230);
            let clear = Color32::from_rgba_unmultiplied(11, 12, 16, 0);
            let (a, b) = if top_solid { (solid, clear) } else { (clear, solid) };
            g.colored_vertex(pos2(list.left() + 1.0, y0), a);
            g.colored_vertex(pos2(list.right() - 1.0, y0), a);
            g.colored_vertex(pos2(list.right() - 1.0, y1), b);
            g.colored_vertex(pos2(list.left() + 1.0, y1), b);
            g.add_triangle(0, 1, 2);
            g.add_triangle(0, 2, 3);
            p.add(g);
        };
        if rows.len() as f32 * ROW > list.height() {
            fade(list.bottom() - 18.0, list.bottom(), false);
        }
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
        if let Some(id) = dismiss {
            desk.dismiss(id);
        }
        if let Some(id) = uncheck {
            desk.uncheck(id);
        }
        if let Some((pid, r)) = add_to {
            self.toasts.say(format!("{} added", r.title), Tone::Neutral);
            desk.add_to_playlist(pid, &r);
        }
        if let Some((d, r)) = load_on {
            self.toasts.say(format!("{} on deck {}", r.title, ["A", "B"][d]), Tone::Deck(d));
            if let Some(f) = from {
                self.flights.push((r.clone(), f, d, std::time::Instant::now()));
            }
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
                if let Some(f) = from {
                    self.flights.push((rec.clone(), f, free, std::time::Instant::now()));
                }
                desk.load_by_hand(free, rec);
            }
        }
    }

    /// Records on their way from the crate to a deck: each sleeve flies on a curve from its
    /// row to the platter, shrinking into it.
    pub(crate) fn flights(&mut self, desk: &mut Desk, ui: &mut Ui) {
        const FOR: f32 = 0.3;
        self.flights.retain(|f| f.3.elapsed().as_secs_f32() < FOR);
        if self.flights.is_empty() || motion::reduced(ui.ctx()) {
            self.flights.clear();
            return;
        }
        let ctx = ui.ctx().clone();
        ctx.request_repaint();
        let p = ctx.layer_painter(egui::LayerId::new(egui::Order::Tooltip, egui::Id::unique("flights")));
        for (rec, from, d, at) in self.flights.clone() {
            let k = Ease::InOut.at(at.elapsed().as_secs_f32() / FOR);
            let to = self.platter_at[d];
            if to.width() < 1.0 {
                continue;
            }
            let side = from.width() + (to.width() * 0.62 - from.width()) * k;
            let (a, b) = (from.center(), to.center());
            // a little arc over the straight line
            let lift = -60.0 * (4.0 * k * (1.0 - k));
            let c = pos2(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k + lift);
            let r = Rect::from_center_size(c, vec2(side, side));
            let mut fp = p.clone();
            fp.multiply_opacity(1.0 - (k - 0.75).max(0.0) * 4.0);
            fp.add(t::shadow(2).as_shape(r, CornerRadius::same(4)));
            let tex = self.sleeves.of(&ctx, desk, &rec);
            kit::sleeve(ui, &fp, r, tex, &rec.initials(), col(theme::sleeve(rec.id)), 4, ("flight", rec.id));
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
            let rr = Rect::from_min_size(pos2(tree.left() + 10.0, y), vec2(tree.width() - 20.0, 27.0));
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
        if row(ui, tree.top() + 66.0, "Fits the master", String::new(), matches!(shelf, Shelf::Fits { .. }), -2) {
            self.fits_asked = true;
        }
        let queued = desk.queue().len();
        if row(ui, tree.top() + 94.0, "Queue", if queued > 0 { queued.to_string() } else { String::new() }, shelf == Shelf::Queue, -3) {
            open = Some(Shelf::Queue);
        }
        // like what is on; the records to check by ear
        if row(ui, tree.top() + 122.0, "Similar", String::new(), matches!(shelf, Shelf::Similar { .. }), -4) {
            self.similar_asked = Some(self.similar_fresh);
        }
        if row(ui, tree.top() + 150.0, "Check by ear", String::new(), shelf == Shelf::Check, -5) {
            open = Some(Shelf::Check);
        }
        kit::section(p, pos2(tree.left() + 18.0, tree.top() + 186.0), Align2::LEFT_TOP, "Playlists");
        let list = Rect::from_min_max(pos2(tree.left(), tree.top() + 204.0), pos2(tree.right(), tree.bottom() - 46.0));
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(list));
        egui::ScrollArea::vertical().id_salt("playlists").auto_shrink([false, false]).min_scrolled_height(0.0).max_height(list.height().max(0.0)).show_rows(&mut child, 28.0, lists.len(), |ui, range| {
            for i in range {
                let l = &lists[i];
                let (rr, _) = ui.allocate_exact_size(vec2(list.width(), 28.0), Sense::hover());
                let on = matches!(&shelf, Shelf::Playlist { id, .. } if *id == l.id);
                if row(ui, rr.top(), &l.name, l.items.to_string(), on, l.id) {
                    open = Some(Shelf::Playlist { id: l.id, name: l.name.clone() });
                }
                // the pinned ones (first in the list) marked
                if l.pinned.unwrap_or(false) {
                    crate::ui::icons::paint(ui.painter(), Rect::from_center_size(pos2(rr.left() + 14.0, rr.center().y), vec2(10.0, 10.0)), Icon::Pin, t::muted());
                }
            }
        });
        p.line_segment([pos2(tree.left() + 14.0, tree.bottom() - 44.0), pos2(tree.right() - 14.0, tree.bottom() - 44.0)], Stroke::new(1.0, white(0.06)));
        let who = user.unwrap_or_else(|| server.trim_start_matches("https://").to_owned());
        kit::avatar(p, pos2(tree.left() + 26.0, tree.bottom() - 22.0), 10.0, &who);
        kit::clipped(p, pos2(tree.left() + 44.0, tree.bottom() - 22.0), &who, 12.5, "", t::soft(), tree.width() - 44.0 - 50.0);
        let out = Rect::from_min_size(pos2(tree.right() - 44.0, tree.bottom() - 35.0), vec2(30.0, 26.0));
        if Btn::new("").icon(Icon::LogOut).quiet().show(ui, p, out, "sign-out").on_hover_text(format!("Sign out of {server}")).clicked() {
            desk.sign_out();
        }
        if self.fits_asked {
            self.fits_asked = false;
            self.search.clear();
            self.searched.clear();
            desk.open_fits();
        }
        if let Some(f) = self.similar_asked.take() {
            self.search.clear();
            self.searched.clear();
            desk.open_similar(f);
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
        for (hint, which, icon) in [("House address", 0, Icon::House), ("Name", 1, Icon::User), ("Password", 2, Icon::Lock)] {
            let fr = Rect::from_min_size(pos2(x, y), vec2(w, 30.0));
            let value = match which {
                0 => &mut self.form.0,
                1 => &mut self.form.1,
                _ => &mut self.form.2,
            };
            let resp = kit::field(ui, p, fr, value, hint, Some(icon), which == 2, ("sign-in", which));
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
            if Btn::new("Use the app's sign-in").quiet().size(11.0).show(ui, p, app, "app-sign-in").clicked() {
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
        // on the stage now: the tally; opening: the screen with its arc; closed: nothing to say
        if on {
            let w = crate::paint::label_width(p, "Live", 9.5) + 12.0;
            kit::tally(p, pos2(inner.right() - w, inner.top() + 6.0), "Live");
        } else if v.starting {
            kit::status(ui, p, Rect::from_center_size(pos2(inner.right() - 11.0, inner.top() + 6.0), vec2(22.0, 22.0)), Icon::Screen, kit::State::Busy, "stage-busy");
        }
        let buttons = 30.0 + 8.0 + 30.0;
        let room = inner.height() - 26.0 - buttons - 10.0;
        // the picture as large as the card lets it be, 16:9
        let pic_size = if inner.width() * 9.0 / 16.0 <= room { vec2(inner.width(), inner.width() * 9.0 / 16.0) } else { vec2(room * 16.0 / 9.0, room) };
        let scene = match (on, v.untold) {
            (true, true) => "an older stage: it says nothing of its scene".to_owned(),
            (true, false) => v.told.look.clone().or(v.scene.clone()).unwrap_or_else(|| "—".into()),
            _ => "—".into(),
        };
        if pic_size.y >= 60.0 {
            let pic = Rect::from_min_size(pos2(inner.center().x - pic_size.x / 2.0, inner.top() + 26.0), pic_size);
            match (&self.stage_pic, on) {
                (Some((_, tex)), true) => {
                    p.rect_filled(pic, CornerRadius::same(t::R_PAD), Color32::BLACK);
                    p.add(egui::epaint::RectShape::filled(pic, CornerRadius::same(t::R_PAD), Color32::WHITE).with_texture(tex.id(), Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0))));
                    // the caption on glass over the picture's foot
                    let cap = Rect::from_min_max(pos2(pic.left() + 6.0, pic.bottom() - 30.0), pos2(pic.right() - 6.0, pic.bottom() - 6.0));
                    kit::glass_tab(p, cap);
                    let held = if v.held { label_sized(p, pos2(cap.right() - 8.0, cap.center().y), Align2::RIGHT_CENTER, "Held", 10.0, t::warm()).left() } else { cap.right() };
                    kit::clipped(p, pos2(cap.left() + 8.0, cap.center().y), &scene, 11.5, "", t::text(), held - cap.left() - 16.0);
                    p.rect_stroke(pic, CornerRadius::same(t::R_PAD), Stroke::new(1.0, white(0.08)), StrokeKind::Inside);
                }
                _ => {
                    // no show: a screen's outline, dashed, and what to do
                    p.rect_filled(pic, CornerRadius::same(t::R_PAD), Color32::from_black_alpha(70));
                    dashed_rect(p, pic.shrink(1.0), white(0.14));
                    let (say, ink) = match (&v.trouble, v.starting) {
                        (Some(why), _) => (why.clone(), t::warm()),
                        (None, true) => ("The stage window is opening".to_owned(), t::muted()),
                        (None, false) => ("The show, in a window of its own".to_owned(), t::faint()),
                    };
                    crate::ui::icons::paint(p, Rect::from_center_size(pic.center() - vec2(0.0, 12.0), vec2(22.0, 22.0)), Icon::Screen, alpha_of(t::faint(), 0.7));
                    let mut job = egui::text::LayoutJob::simple(say, egui::FontId::new(12.0, crate::paint::family("")), ink, pic.width() - 24.0);
                    job.halign = egui::Align::Center;
                    let g = p.layout_job(job);
                    p.galley(pos2(pic.center().x, pic.center().y + 6.0), g, ink);
                }
            }
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
        let hand_r = |i: usize| Rect::from_min_size(pos2(inner.left() + i as f32 * (bw + 6.0), hy), vec2(bw, 30.0));
        let bare = kit::bare_row(p, &hands.iter().enumerate().map(|(i, (w, ic, ..))| (Btn::new(w).icon(*ic).size(11.0), hand_r(i))).collect::<Vec<_>>());
        for (i, (name, icon, tone, lit, hand)) in hands.into_iter().enumerate() {
            let br = hand_r(i);
            if Btn::new(name).icon(icon).tone(tone).on(lit).enabled(on).size(11.0).bare(bare).show(ui, p, br, ("show", i)).clicked() {
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
        let seg_w = (inner.width() - 90.0).min(186.0);
        let seg = Rect::from_min_size(pos2(inner.right() - seg_w, inner.top() - 3.0), vec2(seg_w, 24.0));
        if let Some(i) = kit::segmented(ui, p, seg, &["Easy", "Normal", "Bold"], styles.iter().position(|&st| st == desk.style), Tone::Neutral, "style") {
            desk.style = styles[i];
        }
        // under the card: the hands on the move, the room's word, the last mix's thumb — the
        // room and the thumb on one row where the panel is short
        let last = desk.last_mix();
        let avail = inner.height() - 30.0;
        let mut below = if last.is_some() { 108.0 } else { 72.0 };
        let merged = last.is_some() && avail - below < 150.0;
        if merged {
            below -= 36.0;
        }
        let card_h = (avail - below).max(64.0);
        let card = Rect::from_min_size(pos2(inner.left(), inner.top() + 30.0), vec2(inner.width(), card_h));
        p.rect(card, CornerRadius::same(t::R_PAD), white(0.035), Stroke::new(1.0, white(0.06)), StrokeKind::Inside);
        let c = card.shrink(12.0);
        let master = s.decks.iter().position(|d| d.master).unwrap_or(0);
        let (from, to) = s.mix.as_ref().map(|m| (m.from, m.to)).unwrap_or((master, 1 - master));
        let a = kit::deck_chip(p, pos2(c.left(), c.top() + 9.0), from);
        // under way: the arrow lights on each beat of the record going out
        let beat = s.mix.as_ref().filter(|m| m.mixing && s.auto).and_then(|_| {
            let v = &s.decks[from];
            desk.beat_at(from, v.heard).map(|(into, _)| (1.0 - (into * 60.0 / v.bpm.max(1.0)) as f32 / 0.2).clamp(0.0, 1.0))
        });
        let arrow = match beat {
            Some(k) => mix(t::soft(), t::tint(to), k),
            None => t::muted(),
        };
        crate::ui::icons::paint(p, Rect::from_center_size(pos2(a.right() + 12.0, c.top() + 9.0), vec2(12.0, 12.0)), Icon::ChevronRight, arrow);
        let b = kit::deck_chip(p, pos2(a.right() + 24.0, c.top() + 9.0), to);
        let (what, status) = match (s.auto, s.mix.clone()) {
            (false, _) => ("Paused".to_owned(), "".to_owned()),
            (true, None) => ("Listening".to_owned(), if s.decks[master].playing { "planning…" } else { "play a deck" }.to_owned()),
            (true, Some(m)) => (
                format!("{} · {} bar{}", m.kind.word(), m.bars, if m.bars == 1 { "" } else { "s" }),
                if m.mixing { format!("bar {:.0} / {}", m.bar.floor() + 1.0, m.bars) } else { format!("in {}:{:02}", m.starts_in as u64 / 60, m.starts_in as u64 % 60) },
            ),
        };
        // the set's page and the plan view: icons, their words on hover
        let plan_b = Rect::from_min_size(pos2(c.right() - 28.0, c.top() - 2.0), vec2(28.0, 22.0));
        if Btn::new("").icon(Icon::Timeline).on(self.plan_open).quiet().show(ui, p, plan_b, "plan-open").on_hover_text("The plan: the move drawn out, with a hand on it  (P)").clicked() {
            self.plan_open = !self.plan_open;
        }
        let set_b = Rect::from_min_size(pos2(plan_b.left() - 32.0, c.top() - 2.0), vec2(28.0, 22.0));
        let set_on = desk.set_view().playing;
        if Btn::new("").icon(Icon::List).on(set_on).quiet().show(ui, p, set_b, "set-open").on_hover_text("Plan a set: the house picks and orders the records").clicked() {
            self.overlay = Some(crate::Overlay::Set);
        }
        let st = kit::text(p, pos2(set_b.left() - 8.0, c.top() + 9.0), Align2::RIGHT_CENTER, &status, 12.0, "mono", t::muted());
        kit::clipped(p, pos2(b.right() + 10.0, c.top() + 9.0), &what, 13.0, "semi", t::text(), st.left() - b.right() - 20.0);
        let buttons_y = c.bottom() - 30.0;
        // the move, what is coming, or what it has done (tabs at the right of the second
        // line); why the planner chose it, in its words, at its left — where there is room
        if buttons_y - (c.top() + 24.0) >= 28.0 {
            let tabs_w = (c.width() * 0.5).min(168.0);
            let tabs = Rect::from_min_size(pos2(c.right() - tabs_w, c.top() + 24.0), vec2(tabs_w, 20.0));
            if let Some(i) = kit::segmented(ui, p, tabs, &["Move", "Next", "Log"], Some(self.auto_tab), Tone::Neutral, "auto-tab") {
                self.auto_tab = i;
            }
            let why = s.mix.as_ref().map(|m| m.why.clone()).filter(|w| !w.is_empty() && s.auto);
            if let Some(w) = &why {
                kit::clipped(p, pos2(c.left(), tabs.center().y), w, 11.5, "", t::label(), tabs.left() - c.left() - 10.0);
                ui.interact(Rect::from_min_max(pos2(c.left(), c.top()), pos2(tabs.left() - 4.0, tabs.bottom())), ui.scope_id().with("why"), Sense::hover()).on_hover_text(w.as_str());
            }
            let area = Rect::from_min_max(pos2(c.left(), tabs.bottom() + 6.0), pos2(c.right(), buttons_y - 8.0));
            match self.auto_tab {
                0 if area.height() >= 24.0 => self.timeline(ui, p, area, s, from, to),
                1 if area.height() >= 24.0 => self.up_next(desk, ui, p, area, s),
                2 if area.height() >= 18.0 => auto_log(desk, p, area),
                _ => {}
            }
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
        if Btn::new(if s.auto { "Pause" } else { "Paused" }).icon(Icon::Pause).on(!s.auto).size(11.0).show(ui, p, at(2.0), "pause").on_hover_text("The Auto DJ stops mixing; the decks are yours  (A)").clicked() {
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
        let hand_r = |i: usize| Rect::from_min_size(pos2(inner.left() + i as f32 * (hw + 6.0), hy), vec2(hw, 26.0));
        let bare = kit::bare_row(p, &hands.iter().enumerate().map(|(i, (w, ic, ..))| (Btn::new(w).icon(*ic).size(10.5), hand_r(i))).collect::<Vec<_>>());
        for (i, (word, icon, on, tip)) in hands.into_iter().enumerate() {
            let br = hand_r(i);
            let tip = if word == "Undo" { can_undo.as_ref().map_or(tip.to_owned(), |w| format!("Undo: {w}")) } else { tip.to_owned() };
            if Btn::new(word).icon(icon).enabled(on).quiet().size(10.5).bare(bare).show(ui, p, br, ("auto-hand", i)).on_hover_text(tip).clicked() {
                match i {
                    0 => desk.skip(),
                    1 => desk.later(2),
                    2 => desk.later(-1),
                    3 => desk.longer(),
                    _ => desk.undo(),
                }
            }
        }
        // the room's word on the next records: less or more energy (pips for how far), more
        // like this one, something different — lit while it holds; again takes it back
        let steer = desk.steer();
        let ry = hy + 26.0 + 10.0;
        let room_l = kit::section(p, pos2(inner.left(), ry + 13.0), Align2::LEFT_CENTER, "Room");
        let thumbs_w = if merged { 2.0 * 30.0 + 6.0 + 10.0 } else { 0.0 };
        let x0 = room_l.right() + 12.0;
        let rw = (inner.right() - thumbs_w - x0 - 3.0 * 6.0) / 4.0;
        let pips = ((steer.energy.abs() / 0.12).ceil() as usize).min(3);
        let words: [(&str, Icon, bool, &str); 4] = [
            ("Less", Icon::ArrowDown, steer.energy < 0.0, "Less energy in the next records (again: less still)"),
            ("More", Icon::ArrowUp, steer.energy > 0.0, "More energy in the next records (again: more still)"),
            ("Like this", Icon::Similar, steer.like.is_some(), "More like the record playing (again: as before)"),
            ("Different", Icon::Shuffle, steer.different, "Something different from it (again: as before)"),
        ];
        let room_r = |i: usize| Rect::from_min_size(pos2(x0 + i as f32 * (rw + 6.0), ry), vec2(rw, 26.0));
        let bare = kit::bare_row(p, &words.iter().enumerate().map(|(i, (w, ic, ..))| (Btn::new(w).icon(*ic).size(10.5), room_r(i))).collect::<Vec<_>>());
        for (i, (word, icon, on, tip)) in words.into_iter().enumerate() {
            let cr = room_r(i);
            if Btn::new(word).icon(icon).on(on).quiet().enabled(s.auto).size(10.5).bare(bare).show(ui, p, cr, ("room", i)).on_hover_text(tip).clicked() {
                match (i, on) {
                    (0, _) => desk.more_energy(-1),
                    (1, _) => desk.more_energy(1),
                    (2, false) => desk.more_like_this(),
                    (3, false) => desk.something_different(),
                    _ => desk.steer_neutral(),
                }
            }
            if on && i < 2 {
                for k in 0..pips {
                    p.circle_filled(pos2(cr.center().x + (k as f32 - (pips as f32 - 1.0) / 2.0) * 6.0, cr.bottom() - 3.0), 1.5, t::high());
                }
            }
        }
        // the last transition, and a thumb on it
        if let Some(last) = last {
            let rated = last.rating;
            let (up, down) = if merged {
                (Rect::from_min_size(pos2(inner.right() - 66.0, ry), vec2(30.0, 26.0)), Rect::from_min_size(pos2(inner.right() - 30.0, ry), vec2(30.0, 26.0)))
            } else {
                let y0 = ry + 26.0 + 10.0;
                let up = Rect::from_min_size(pos2(inner.right() - 2.0 * 84.0 - 6.0, y0), vec2(84.0, 26.0));
                let what = format!("Last: {} · {}", last.kind.word(), last.to.title);
                kit::clipped(p, pos2(inner.left(), y0 + 13.0), &what, 12.0, "", t::muted(), up.left() - inner.left() - 10.0);
                (up, Rect::from_min_size(pos2(inner.right() - 84.0, y0), vec2(84.0, 26.0)))
            };
            let about = format!("{} into {}", last.kind.word(), last.to.title);
            let good = Btn::new(if merged { "" } else { "Good one" }).icon(if rated == Some(1) { Icon::HeartFull } else { Icon::Heart }).on(rated == Some(1)).enabled(rated.is_none()).size(10.5);
            if good.show(ui, p, up, "rate-up").on_hover_text(format!("The last mix worked: {about}")).clicked() {
                desk.rate(1);
            }
            let meh = Btn::new(if merged { "" } else { "So-so" }).icon(Icon::ThumbDown).on(rated == Some(-1)).enabled(rated.is_none()).quiet().size(10.5);
            if meh.show(ui, p, down, "rate-down").on_hover_text(format!("The last mix did not work: {about}")).clicked() {
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
            // the bass changing hands: a flash as the mix passes it
            let passed = (m.mixing && m.bar >= sw) as u64;
            let fl = motion::flash(ui.ctx(), ui.scope_id().with(("swap", m.to, m.bars)), passed, 0.3);
            p.line_segment([pos2(x, r.top() + 4.0), pos2(x, r.bottom() - 4.0)], Stroke::new(1.0 + 2.0 * fl, mix(white(0.5 * dim), t::tint(to), fl)));
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

/// PLAY's icon at `c`, `r` its half size: a triangle at `k` 0, two bars at 1, between them
/// in between (each bar the triangle's half, squared off).
fn play_pause(p: &Painter, c: egui::Pos2, r: f32, k: f32, ink: Color32) {
    let k = Ease::InOut.at(k);
    let lerp = |a: egui::Pos2, b: egui::Pos2| pos2(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k);
    // the triangle's halves, and the bars they become
    let tri_top = [pos2(c.x - r * 0.62, c.y - r), pos2(c.x + r * 0.95, c.y), pos2(c.x + r * 0.95, c.y), pos2(c.x - r * 0.62, c.y)];
    let bar_l = [pos2(c.x - r * 0.75, c.y - r * 0.9), pos2(c.x - r * 0.2, c.y - r * 0.9), pos2(c.x - r * 0.2, c.y + r * 0.9), pos2(c.x - r * 0.75, c.y + r * 0.9)];
    let tri_bot = [pos2(c.x - r * 0.62, c.y), pos2(c.x + r * 0.95, c.y), pos2(c.x + r * 0.95, c.y), pos2(c.x - r * 0.62, c.y + r)];
    let bar_r = [pos2(c.x + r * 0.2, c.y - r * 0.9), pos2(c.x + r * 0.75, c.y - r * 0.9), pos2(c.x + r * 0.75, c.y + r * 0.9), pos2(c.x + r * 0.2, c.y + r * 0.9)];
    for (a, b) in [(tri_top, bar_l), (tri_bot, bar_r)] {
        let pts: Vec<egui::Pos2> = (0..4).map(|i| lerp(a[i], b[i])).collect();
        p.add(Shape::convex_polygon(pts, ink, Stroke::NONE));
    }
}

/// A rectangle's outline in dashes (a place for something not there).
fn dashed_rect(p: &Painter, r: Rect, c: Color32) {
    let dash = 6.0;
    let gap = 5.0;
    let edge = |a: egui::Pos2, b: egui::Pos2| {
        let len = (b - a).length();
        let dir = (b - a) / len.max(1.0);
        let mut t = 0.0;
        while t < len {
            let e = (t + dash).min(len);
            p.line_segment([a + dir * t, a + dir * e], Stroke::new(1.0, c));
            t += dash + gap;
        }
    };
    let r = r.shrink(4.0);
    edge(r.left_top(), r.right_top());
    edge(r.right_top(), r.right_bottom());
    edge(r.right_bottom(), r.left_bottom());
    edge(r.left_bottom(), r.left_top());
}
