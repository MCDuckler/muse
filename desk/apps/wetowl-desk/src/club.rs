//! The booth laid out as rekordbox lays out its PERFORMANCE mode (2 Deck Horizontal,
//! rekordbox 7's manual p.125: plans/wetowl-desk-rekordbox-look.md §2a): a flat bar on
//! top, the two enlarged waveforms stacked across the whole width, the two decks under
//! them with a narrow mixer between, the crossfader and the master in a strip under the
//! decks, the browser filling the rest (the stage and the Auto DJ beside it, where
//! rekordbox puts its video and its extra panels).
//!
//! Matte and opaque, no glass. Every control does what the WetOwl layout's does: the same
//! Desk calls, the crate and the side cards are the WetOwl's own.
use eframe::egui::{self, Align2, Color32, CornerRadius, FontId, Painter, Pos2, Rect, Sense, Shape, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::{Desk, Record, Snapshot, WaveStyle, theme};

use crate::paint::{col, family, mmss};
use crate::show::Page;
use crate::ui::fit;
use crate::ui::icons::{self, Icon};
use crate::ui::kit::{self, Btn};
use crate::ui::motion;
use crate::ui::tokens::{Tone, mix};
use crate::wave::{self, Anchor};
use crate::{App, Overlay};

const fn rgb(v: u32) -> Color32 {
    Color32::from_rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
}

/// rekordbox's greys and lights, sampled off its screenshot.
pub(crate) const GROUND: Color32 = rgb(0x0E0E0F);
pub(crate) const PANEL: Color32 = rgb(0x1B1B1D);
pub(crate) const RAISED: Color32 = rgb(0x262628);
pub(crate) const LINE: Color32 = rgb(0x323234);
pub(crate) const TEXT: Color32 = rgb(0xE8E8EA);
pub(crate) const MUTED: Color32 = rgb(0xA0A0A6);
pub(crate) const LIT: Color32 = rgb(0x1C70DE);
pub(crate) const PLAY: Color32 = rgb(0x2EC16B);
pub(crate) const CUE: Color32 = rgb(0xE59A3E);
pub(crate) const MASTER: Color32 = rgb(0xE8822A);

/// The gap between rekordbox's panels: a hairline.
const G: f32 = 3.0;

/// Where the Club layout puts things.
pub(crate) struct ClubLayout {
    pub top: Rect,
    pub lanes: [Rect; 2],
    pub decks: [Rect; 2],
    pub mixer: Rect,
    pub strip: Rect,
    pub browser: Rect,
    /// The stage and the Auto DJ: none when folded away.
    pub side: Option<Rect>,
}

/// The grid for a window: the rows rekordbox's screenshot has at 1920×1016 (bar 45, the
/// waveforms 145, the decks 270, the strip 40, the browser the rest), scaled to the height.
pub(crate) fn layout(full: Rect, side: bool) -> ClubLayout {
    let r = full.shrink(4.0);
    let h = r.height();
    let top = Rect::from_min_size(r.min, vec2(r.width(), 38.0));
    let lanes_h = (h * 0.15).clamp(112.0, 300.0);
    let lane_h = (lanes_h - G) / 2.0;
    let l0 = Rect::from_min_size(pos2(r.left(), top.bottom() + G), vec2(r.width(), lane_h));
    let l1 = Rect::from_min_size(pos2(r.left(), l0.bottom() + G), vec2(r.width(), lane_h));
    let decks_h = if h < 900.0 { 248.0 } else { 270.0 };
    let deck_top = l1.bottom() + G;
    let mixer_w = 104.0;
    let dw = (r.width() - mixer_w - 2.0 * G) / 2.0;
    let decks = [Rect::from_min_size(pos2(r.left(), deck_top), vec2(dw, decks_h)), Rect::from_min_size(pos2(r.right() - dw, deck_top), vec2(dw, decks_h))];
    let mixer = Rect::from_min_max(pos2(decks[0].right() + G, deck_top), pos2(decks[1].left() - G, deck_top + decks_h));
    let strip = Rect::from_min_size(pos2(r.left(), deck_top + decks_h + G), vec2(r.width(), 40.0));
    let rest = Rect::from_min_max(pos2(r.left(), strip.bottom() + G), r.max);
    let side_w = if side { (r.width() * 0.2).clamp(320.0, 420.0) } else { 0.0 };
    let browser = Rect::from_min_max(rest.min, pos2(rest.right() - if side { side_w + G } else { 0.0 }, rest.bottom()));
    let side = side.then(|| Rect::from_min_max(pos2(rest.right() - side_w, rest.top()), rest.max));
    ClubLayout { top, lanes: [l0, l1], decks, mixer, strip, browser, side }
}

/// A rekordbox panel: flat, opaque, a hairline edge.
pub(crate) fn panel(p: &Painter, r: Rect) {
    fit::panel(r);
    p.rect(r, CornerRadius::same(2), PANEL, Stroke::new(1.0, LINE), StrokeKind::Inside);
}

fn words(p: &Painter, at: Pos2, a: Align2, s: &str, size: f32, fam: &str, c: Color32) -> Rect {
    p.text(at, a, s, FontId::new(size, family(fam)), c)
}

/// A small flat button the rekordbox way: dark, its word light; lit, filled in `lit`.
fn button(ui: &mut Ui, p: &Painter, r: Rect, word: &str, on: bool, lit: Color32, id: impl std::hash::Hash + std::fmt::Debug) -> egui::Response {
    let resp = ui.interact(r, ui.scope_id().with(id), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
    let h = motion::tween_bool(ui.ctx(), resp.id.with("h"), resp.hovered(), motion::QUICK, motion::STANDARD);
    let fill = if on { lit } else { mix(RAISED, rgb(0x34343A), h) };
    p.rect(r, CornerRadius::same(2), fill, Stroke::new(1.0, if on { lit } else { LINE }), StrokeKind::Inside);
    let size = (r.height() * 0.5).clamp(8.5, 11.0);
    fit::label(p, r.center(), Align2::CENTER_CENTER, word, size, if on { Color32::WHITE } else { TEXT }, r.width() - 4.0);
    resp
}

/// A small knob: an arc, a pointer; dragged up and down, double-click to its rest.
fn knob(ui: &mut Ui, p: &Painter, c: Pos2, v: f32, bipolar: bool, rest: f32, id: impl std::hash::Hash + std::fmt::Debug) -> Option<f32> {
    let id = ui.scope_id().with(id);
    let resp = ui.interact(Rect::from_center_size(c, vec2(26.0, 26.0)), id, Sense::click_and_drag()).on_hover_cursor(egui::CursorIcon::ResizeVertical);
    let rr = 9.0;
    let arc = |a0: f32, a1: f32, color: Color32| {
        let n = ((a1 - a0).abs() / 270.0 * 20.0).ceil().max(2.0) as usize;
        let pts: Vec<Pos2> = (0..=n).map(|i| (a0 + (a1 - a0) * i as f32 / n as f32).to_radians()).map(|a| pos2(c.x + (rr + 2.5) * a.cos(), c.y + (rr + 2.5) * a.sin())).collect();
        p.add(Shape::line(pts, Stroke::new(2.0, color)));
    };
    arc(135.0, 405.0, LINE);
    let at = 135.0 + 270.0 * v.clamp(0.0, 1.0);
    if bipolar {
        if (at - 270.0).abs() > 0.5 {
            arc(270.0f32.min(at), 270.0f32.max(at), LIT);
        }
    } else {
        arc(135.0, at, LIT);
    }
    p.circle(c, rr, rgb(0x2C2C30), Stroke::new(1.0, rgb(0x46464C)));
    let a = at.to_radians();
    p.line_segment([pos2(c.x + 2.5 * a.cos(), c.y + 2.5 * a.sin()), pos2(c.x + (rr - 1.0) * a.cos(), c.y + (rr - 1.0) * a.sin())], Stroke::new(1.8, TEXT));
    if resp.double_clicked() {
        return Some(rest);
    }
    resp.dragged().then(|| (v - resp.drag_delta().y * 0.005).clamp(0.0, 1.0))
}

impl App {
    /// The waveforms' colours here: rekordbox's (the WetOwl's own is the other layout's).
    pub(crate) fn wave_style(&self) -> WaveStyle {
        match (self.prefs.layout, self.prefs.wave_style) {
            (wo_deskcore::DeskLayout::Club, WaveStyle::WetOwl) => WaveStyle::ThreeBand,
            (_, s) => s,
        }
    }

    /// The whole booth in rekordbox's layout.
    pub(crate) fn club(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, full: Rect, s: &Snapshot) {
        // matte: the glass's light does not come through
        p.rect_filled(full, CornerRadius::ZERO, GROUND);
        let l = layout(full, !self.prefs.wide_crate);
        self.club_top(desk, ui, p, l.top, s);
        if self.page == Page::Show {
            let page = Rect::from_min_max(pos2(full.left() + 4.0, l.top.bottom() + G), full.max - vec2(4.0, 4.0));
            self.show_page(desk, ui, p, page, s);
            return;
        }
        for d in 0..2 {
            self.club_lane(desk, ui, p, l.lanes[d], s, d);
            self.club_deck(desk, ui, p, l.decks[d], s, d);
        }
        self.club_mixer(desk, ui, p, l.mixer, s);
        self.club_strip(desk, ui, p, l.strip, s);
        self.crate_(desk, ui, p, l.browser, s);
        if let Some(side) = l.side {
            let stage_h = (side.width() * 9.0 / 16.0 + 64.0).min(side.height() * 0.45);
            self.stage_card(desk, ui, p, Rect::from_min_size(side.min, vec2(side.width(), stage_h)));
            self.auto_dj(desk, ui, p, Rect::from_min_max(pos2(side.left(), side.top() + stage_h + G), side.max), s);
        }
        self.drag_ghost(desk, ui);
        self.flights(desk, ui);
    }

    /// The bar on top: the mark, the rooms, the panels' switches; the master's tempo; the
    /// Auto DJ, the house and the gear, the keys, the settings.
    fn club_top(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        p.rect_filled(r, CornerRadius::ZERO, rgb(0x141415));
        fit::panel(r);
        // the mark, small
        let logo = kit::mark(p, self.ball.id(), pos2(r.left() + 6.0, r.center().y), 26.0);
        let mut x = logo.right() + 14.0;
        let y = r.center().y;
        for (word, page) in [("PERFORMANCE", Page::Booth), ("SHOW", Page::Show)] {
            let bw = 92.0;
            if button(ui, p, Rect::from_min_size(pos2(x, y - 11.0), vec2(bw, 22.0)), word, self.page == page, rgb(0x3A3A40), ("club-page", word)).clicked() {
                self.page = page;
            }
            x += bw + 4.0;
        }
        x += 10.0;
        // the side panels, and the way back to the WetOwl's layout
        let side = !self.prefs.wide_crate;
        if button(ui, p, Rect::from_min_size(pos2(x, y - 11.0), vec2(96.0, 22.0)), "STAGE · AUTO", side, rgb(0x3A3A40), "club-side").on_hover_text("The stage and the Auto DJ beside the browser  (C)").clicked() {
            self.toggle_wide_crate(ui.ctx());
        }
        x += 100.0;
        if button(ui, p, Rect::from_min_size(pos2(x, y - 11.0), vec2(96.0, 22.0)), "WETOWL LAYOUT", false, LIT, "club-back").on_hover_text("The WetOwl's own layout  (Ctrl L)").clicked() {
            self.toggle_layout(ui.ctx());
        }
        // the middle: the master's tempo and deck, the set's time
        let m = s.decks.iter().position(|d| d.master).unwrap_or(0);
        let c = r.center();
        let bpm = words(p, pos2(c.x, y), Align2::CENTER_CENTER, &format!("{:.2}", s.master_bpm), 16.0, "mono-semi", TEXT);
        words(p, pos2(bpm.left() - 8.0, y), Align2::RIGHT_CENTER, &format!("MASTER {}", m + 1), 10.0, "semi", MASTER);
        let set = s.set_seconds as u64;
        words(p, pos2(bpm.right() + 12.0, y), Align2::LEFT_CENTER, &format!("{}:{:02}:{:02}", set / 3600, set / 60 % 60, set % 60), 12.0, "mono", MUTED);
        // the right: settings, keys, the house and the gear, the Auto DJ
        let gear = Rect::from_min_size(pos2(r.right() - 30.0, y - 13.0), vec2(26.0, 26.0));
        if Btn::new("").icon(Icon::Settings).quiet().on(self.overlay == Some(Overlay::Settings)).show(ui, p, gear, "club-settings").on_hover_text("Settings  (Ctrl ,)").clicked() {
            self.overlay = if self.overlay == Some(Overlay::Settings) { None } else { Some(Overlay::Settings) };
        }
        let keys = Rect::from_min_size(pos2(gear.left() - 30.0, y - 13.0), vec2(26.0, 26.0));
        if Btn::new("").icon(Icon::Keys).quiet().on(self.overlay == Some(Overlay::Keys)).show(ui, p, keys, "club-keys").on_hover_text("The keys  (?)").clicked() {
            self.overlay = if self.overlay == Some(Overlay::Keys) { None } else { Some(Overlay::Keys) };
        }
        let left = self.status_icons(desk, ui, p, pos2(keys.left() - 10.0, y), s);
        let auto = Rect::from_min_size(pos2(left - 12.0 - 84.0, y - 11.0), vec2(84.0, 22.0));
        if button(ui, p, auto, "AUTO DJ", s.auto, rgb(0x1E8F55), "club-auto").on_hover_text("The Auto DJ mixes the next record in  (A)").clicked() {
            desk.set_auto(!s.auto);
        }
    }

    /// One enlarged waveform: the deck's number at its left (lit while it is the master),
    /// the lane rekordbox's way, a hand on it moves the record.
    fn club_lane(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        p.rect_filled(r, CornerRadius::ZERO, rgb(0x050506));
        fit::panel(r);
        let v = &s.decks[d];
        let num = Rect::from_min_size(r.min, vec2(20.0, r.height()));
        p.rect_filled(num, CornerRadius::ZERO, if v.master { rgb(0x2A2A2E) } else { PANEL });
        words(p, pos2(num.center().x, num.top() + 10.0), Align2::CENTER_CENTER, &(d + 1).to_string(), 13.0, "semi", if v.master { MASTER } else { TEXT });
        if v.decoded < 1.0 && (v.record.id != 0 || v.length > 0.0) {
            let k = v.decoded.max(0.0);
            p.rect_filled(Rect::from_min_size(pos2(num.left() + 4.0, num.bottom() - 6.0), vec2(12.0 * k, 2.0)), CornerRadius::ZERO, LIT);
        }
        let w = Rect::from_min_max(pos2(num.right() + 1.0, r.top()), r.max);
        let ppp = ui.ctx().pixels_per_point();
        let zoom = motion::spring(ui.ctx(), ui.scope_id().with("club-zoom"), self.zoom, 0.16);
        let over = ui.interact(w, ui.scope_id().with(("club-lane-zoom", d)), Sense::hover());
        if over.hovered() {
            let dy = ui.input(|i| i.smooth_scroll_delta.y);
            if dy.abs() > 0.1 {
                self.zoom = (self.zoom * 1.0015f32.powf(dy)).clamp(40.0, 320.0);
            }
        }
        // rekordbox's zoom is by time: the zoom's beat at 128 BPM, the same for both decks
        let px_per_s = zoom as f64 * 128.0 / 60.0;
        let lw = desk.lane_wave_at(d, v.heard, w.width(), 2.0, px_per_s, true);
        self.rb_lane(desk, ui, p, w, &lw, v, d, ppp, Anchor::Up(0.64));
        self.lane_hand(desk, ui, w, &lw, v, d);
    }

    /// A deck rekordbox's way: its record on top (cover, title, artist, tempo, key, the
    /// time left large), its overview and phrases, then its hot cues as a list, the loop
    /// and jumps, CUE and PLAY, the jog ring with the tempo in it, the pitch fader.
    fn club_deck(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        panel(p, r);
        let ctx = ui.ctx().clone();
        let v = &s.decks[d];
        let inner = r.shrink2(vec2(8.0, 6.0));
        // a record dragged from the browser lands here
        if let Some(rec) = egui::DragAndDrop::payload::<Record>(&ctx) {
            let over = ctx.pointer_latest_pos().is_some_and(|pos| r.contains(pos));
            let ok = !v.playing && rec.playable();
            p.rect_stroke(r, CornerRadius::same(2), Stroke::new(if over && ok { 2.0 } else { 1.0 }, if ok { LIT } else { LINE }), StrokeKind::Inside);
            if over && ok && ctx.input(|i| i.pointer.any_released()) {
                desk.load_by_hand(d, (*rec).clone());
                egui::DragAndDrop::clear_payload(&ctx);
                self.toasts.say(format!("{} on deck {}", rec.title, d + 1), Tone::Deck(d));
            }
        }
        // the header
        let hy = inner.top() + 18.0;
        words(p, pos2(inner.left(), inner.top() + 2.0), Align2::LEFT_TOP, &(d + 1).to_string(), 11.0, "semi", MUTED);
        let cover = Rect::from_min_size(pos2(inner.left() + 12.0, inner.top()), vec2(34.0, 34.0));
        let tex = self.sleeves.of(&ctx, desk, &v.record);
        if v.record.playable() {
            kit::sleeve(ui, p, cover, tex, &v.record.initials(), col(theme::sleeve(v.record.id)), 2, ("club-sleeve", d, v.record.id));
        }
        // the right: SYNC and MASTER, the time left large and the time gone
        let br = inner.right();
        let sync = Rect::from_min_size(pos2(br - 70.0, inner.top()), vec2(70.0, 16.0));
        let master = Rect::from_min_size(pos2(br - 70.0, inner.top() + 19.0), vec2(70.0, 16.0));
        if button(ui, p, sync, "BEAT SYNC", v.synced, LIT, ("club-sync", d)).on_hover_text(format!("In step with the other deck  ({})", ["Q", "W"][d])).clicked() {
            desk.toggle_sync(d);
        }
        button(ui, p, master, "MASTER", v.master, MASTER, ("club-master", d)).on_hover_text("The master: the deck the other syncs to and the Auto DJ mixes out of");
        let left = (v.length - v.heard).max(0.0);
        let warn = v.playing && v.length > 0.0 && left < 30.0;
        let gone = words(p, pos2(sync.left() - 10.0, hy), Align2::RIGHT_CENTER, &mmss(v.heard), 12.0, "mono", MUTED);
        let lt = words(p, pos2(gone.left() - 8.0, hy), Align2::RIGHT_CENTER, &format!("-{}", mmss(left)), 20.0, "mono-semi", if warn { CUE } else { TEXT });
        // the middle: title over artist, tempo and key beside
        let tx = cover.right() + 8.0;
        let bpm_w = 110.0;
        let room = (lt.left() - 16.0 - bpm_w - tx).max(60.0);
        let title = if v.record.playable() { v.record.title.as_str() } else { "No record" };
        kit::clipped(p, pos2(tx, inner.top() + 9.0), title, 14.0, "semi", if v.record.playable() { TEXT } else { MUTED }, room);
        kit::clipped(p, pos2(tx, inner.top() + 26.0), &v.record.artist, 11.5, "", MUTED, room);
        let kx = tx + room + 10.0;
        words(p, pos2(kx, inner.top() + 9.0), Align2::LEFT_CENTER, &format!("{:.2}", v.bpm), 13.0, "mono-semi", TEXT);
        words(p, pos2(kx + 58.0, inner.top() + 9.0), Align2::LEFT_CENTER, &v.record.key, 12.0, "semi", MUTED);
        words(p, pos2(kx, inner.top() + 26.0), Align2::LEFT_CENTER, &format!("{:+.1}% ±{:.0}", (v.rate - 1.0) * 100.0, v.range * 100.0), 10.5, "mono", MUTED);

        // the overview, and the phrases under it
        let ov = Rect::from_min_size(pos2(inner.left(), inner.top() + 42.0), vec2(inner.width(), 40.0));
        p.rect_filled(ov, CornerRadius::ZERO, rgb(0x050506));
        self.overview_strip(desk, ui, p, ov.shrink2(vec2(2.0, 5.0)), s, d, None);
        let band = Rect::from_min_size(pos2(inner.left(), ov.bottom() + 1.0), vec2(inner.width(), 14.0));
        let len = v.length.max(1.0);
        let xb = |t: f64| band.left() + 2.0 + (band.width() - 4.0) * (t / len).clamp(0.0, 1.0) as f32;
        let phrases: Vec<_> = desk.phrases(d).into_iter().map(|ph| (xb(ph.start), xb(ph.end), ph)).collect();
        p.rect_filled(band, CornerRadius::ZERO, rgb(0x0A0A0B));
        wave::phrase_band(p, band, &phrases, 0.95, true);

        // the controls
        let body = Rect::from_min_max(pos2(inner.left(), band.bottom() + 8.0), inner.max);
        let pitch_w = 40.0;
        let pitch_r = Rect::from_min_max(pos2(body.right() - pitch_w, body.top()), body.max);
        let jog_side = body.height().min(150.0);
        let jog = Rect::from_min_size(pos2(pitch_r.left() - 8.0 - jog_side, body.top() + (body.height() - jog_side) / 2.0), vec2(jog_side, jog_side));
        let tr = Rect::from_min_size(pos2(jog.left() - 8.0 - 50.0, body.top()), vec2(50.0, body.height()));
        let loops = Rect::from_min_max(pos2(tr.left() - 8.0 - 128.0, body.top()), pos2(tr.left() - 8.0, body.bottom()));
        let cues = Rect::from_min_max(body.min, pos2(loops.left() - 10.0, body.bottom()));
        self.club_cues(desk, ui, p, cues, s, d);
        self.club_loops(desk, ui, p, loops, s, d);
        self.club_transport(desk, ui, p, tr, s, d);
        self.club_jog(desk, ui, p, jog, s, d);
        self.pitch(desk, ui, p, pitch_r, s, d);
    }

    /// The hot cues as rekordbox lists them: A–H in two columns, each its colour's square
    /// and its name (or where it is). A click sets an empty one or jumps to it; a right-
    /// or shift-click clears it.
    fn club_cues(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        let shift = ui.input(|i| i.modifiers.shift);
        let rows = 4;
        let label_h = 16.0;
        let row_h = ((r.height() - label_h - 4.0) / rows as f32).min(26.0);
        let col_w = (r.width() - 6.0) / 2.0;
        for i in 0..8 {
            let cell = Rect::from_min_size(pos2(r.left() + (i / rows) as f32 * (col_w + 6.0), r.top() + (i % rows) as f32 * row_h), vec2(col_w, row_h - 3.0));
            let resp = ui.interact(cell, ui.scope_id().with(("club-cue", d, i)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
            let fired = motion::flash(ui.ctx(), ui.scope_id().with(("club-cue-f", d, i)), self.pad_fired[d][i], 0.25);
            let h = motion::tween_bool(ui.ctx(), resp.id.with("h"), resp.hovered(), motion::QUICK, motion::STANDARD);
            p.rect_filled(cell, CornerRadius::same(2), mix(mix(RAISED, rgb(0x33333A), h), Color32::WHITE, fired * 0.25));
            let letter = (b'A' + i as u8) as char;
            let colour = wave::hot_cue_colour(i, v.looks[i].as_ref());
            let sq = Rect::from_min_size(pos2(cell.left() + 3.0, cell.center().y - 7.0), vec2(14.0, 14.0));
            match v.pads[i] {
                Some(pad) => {
                    p.rect_filled(sq, CornerRadius::same(2), colour);
                    words(p, sq.center(), Align2::CENTER_CENTER, &letter.to_string(), 10.0, "semi", Color32::WHITE);
                    let name = v.looks[i].as_ref().map(|l| l.name.clone()).filter(|n| !n.is_empty()).unwrap_or_else(|| match pad.auto {
                        Some(k) => crate::paint::pad_name(Some(k)).to_uppercase(),
                        None => mmss(pad.at),
                    });
                    kit::clipped(p, pos2(sq.right() + 6.0, cell.center().y), &name, 11.0, "semi", TEXT, cell.right() - sq.right() - 10.0);
                }
                None => {
                    p.rect_stroke(sq, CornerRadius::same(2), Stroke::new(1.0, LINE), StrokeKind::Inside);
                    words(p, sq.center(), Align2::CENTER_CENTER, &letter.to_string(), 10.0, "semi", rgb(0x5A5A60));
                }
            }
            let resp = resp.on_hover_text(if v.pads[i].is_some() { "Jump here · shift- or right-click clears" } else { "A hot cue here" });
            match v.pads[i] {
                Some(_) if resp.secondary_clicked() || (resp.clicked() && shift) => desk.clear_pad(d, i),
                _ if resp.clicked() => {
                    self.pad_fired[d][i] += 1;
                    desk.pad(d, i);
                }
                _ => {}
            }
        }
        words(p, pos2(r.left() + 2.0, r.bottom() - 7.0), Align2::LEFT_CENTER, "HOT CUE", 9.5, "semi", MUTED);
    }

    /// The loop and the jumps: an auto loop of the length shown (‹ › halve and double it),
    /// IN, OUT and EXIT; the jumps back and ahead.
    fn club_loops(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        let len_id = ui.scope_id().with(("club-loop-len", d));
        let mut beats: f64 = ui.ctx().data(|m| m.get_temp(len_id)).unwrap_or(4.0);
        if let Some(b) = v.loop_beats {
            beats = b;
        }
        let rh = 22.0;
        let g = 5.0;
        let row = |i: f32| Rect::from_min_size(pos2(r.left(), r.top() + i * (rh + g)), vec2(r.width(), rh));
        // the length: ‹ n ›
        let r0 = row(0.0);
        let bw = 24.0;
        let less = Rect::from_min_size(r0.min, vec2(bw, rh));
        let more = Rect::from_min_size(pos2(r0.right() - bw, r0.top()), vec2(bw, rh));
        p.rect_filled(Rect::from_min_max(pos2(less.right() + 2.0, r0.top()), pos2(more.left() - 2.0, r0.bottom())), CornerRadius::same(2), rgb(0x0A0A0B));
        let shown = if beats < 1.0 { format!("1/{}", (1.0 / beats).round()) } else { format!("{beats}") };
        words(p, r0.center(), Align2::CENTER_CENTER, &shown, 13.0, "mono-semi", CUE);
        if button(ui, p, less, "‹", false, LIT, ("club-loop-less", d)).clicked() {
            beats = (beats / 2.0).max(0.25);
            if v.looped.is_some() {
                desk.halve_loop(d);
            }
        }
        if button(ui, p, more, "›", false, LIT, ("club-loop-more", d)).clicked() {
            beats = (beats * 2.0).min(32.0);
            if v.looped.is_some() {
                desk.double_loop(d);
            }
        }
        ui.ctx().data_mut(|m| m.insert_temp(len_id, beats));
        // the auto loop, and the hand's: IN, OUT, EXIT
        let r1 = row(1.0);
        if button(ui, p, r1, "AUTO LOOP", v.looped.is_some() && v.loop_beats.is_some(), CUE, ("club-loop", d)).on_hover_text("A loop this many beats long from the bar (again lets go)").clicked() {
            desk.loop_beats(d, beats);
        }
        let r2 = row(2.0);
        let w3 = (r2.width() - 2.0 * 4.0) / 3.0;
        let cell = |i: f32| Rect::from_min_size(pos2(r2.left() + i * (w3 + 4.0), r2.top()), vec2(w3, rh));
        let by_hand = v.looped.is_some() && v.loop_beats.is_none();
        if button(ui, p, cell(0.0), "IN", v.loop_open, CUE, ("club-in", d)).clicked() {
            desk.loop_in(d);
        }
        if button(ui, p, cell(1.0), "OUT", by_hand, CUE, ("club-out", d)).clicked() {
            desk.loop_out(d);
        }
        if button(ui, p, cell(2.0), "EXIT", false, CUE, ("club-exit", d)).clicked() {
            desk.unloop(d);
        }
        // the jumps
        let r3 = row(3.0);
        let w2 = (r3.width() - 4.0) / 2.0;
        if button(ui, p, Rect::from_min_size(r3.min, vec2(w2, rh)), "◀ 4", false, LIT, ("club-back", d)).on_hover_text("Back 4 beats").clicked() {
            desk.jump(d, -4.0);
        }
        if button(ui, p, Rect::from_min_size(pos2(r3.left() + w2 + 4.0, r3.top()), vec2(w2, rh)), "4 ▶", false, LIT, ("club-ahead", d)).on_hover_text("Ahead 4 beats").clicked() {
            desk.jump(d, 4.0);
        }
        let r4 = row(4.0);
        if r4.bottom() <= r.bottom() + 0.5 && button(ui, p, r4, "MT", v.keylock, LIT, ("club-mt", d)).on_hover_text("Master tempo: its key stays as its tempo moves").clicked() {
            desk.toggle_keylock(d);
        }
    }

    /// CUE and PLAY: round, CUE ringed orange, PLAY green; CUE on press and on release.
    fn club_transport(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        let side = (r.width()).min((r.height() - 12.0) / 2.0).min(50.0);
        let cue_c = pos2(r.center().x, r.center().y - side / 2.0 - 4.0);
        let play_c = pos2(r.center().x, r.center().y + side / 2.0 + 4.0);
        let cue_r = Rect::from_center_size(cue_c, vec2(side, side));
        let (_, cue) = kit::held(ui, cue_r, ("club-cue-btn", d));
        let down = cue.is_pointer_button_down_on();
        if down && !self.cue_held[d] {
            desk.cue_down(d);
        } else if !down && self.cue_held[d] {
            desk.cue_up(d);
        }
        self.cue_held[d] = down;
        let on_cue = v.cue.is_some_and(|c| (c - v.heard).abs() < 0.06) && !v.playing;
        let rad = side / 2.0 - 1.0;
        p.circle(cue_c, rad, if down { mix(PANEL, CUE, 0.35) } else { RAISED }, Stroke::new(2.0, if on_cue || down { CUE } else { mix(CUE, PANEL, 0.45) }));
        words(p, cue_c, Align2::CENTER_CENTER, "CUE", 11.0, "semi", if on_cue || down { CUE } else { TEXT });
        let play_r = Rect::from_center_size(play_c, vec2(side, side));
        let resp = ui.interact(play_r, ui.scope_id().with(("club-play", d)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand).on_hover_text(["Play 1  (1)", "Play 2  (2)"][d]);
        p.circle(play_c, rad, if v.playing { mix(PANEL, PLAY, 0.25) } else { RAISED }, Stroke::new(2.0, if v.playing { PLAY } else { mix(PLAY, PANEL, 0.45) }));
        // ▶ / ‖
        let ink = if v.playing { PLAY } else { TEXT };
        if v.playing {
            for dx in [-4.0, 2.0] {
                p.rect_filled(Rect::from_min_size(pos2(play_c.x + dx, play_c.y - 6.0), vec2(3.0, 12.0)), CornerRadius::ZERO, ink);
            }
        } else {
            p.add(Shape::convex_polygon(vec![pos2(play_c.x - 4.0, play_c.y - 7.0), pos2(play_c.x + 7.0, play_c.y), pos2(play_c.x - 4.0, play_c.y + 7.0)], ink, Stroke::NONE));
        }
        if resp.clicked() {
            desk.toggle_play(d);
        }
    }

    /// The jog ring: the record's turn as a mark going round (33⅓ a minute, as the
    /// platter), the CUE point red on the ring, the tempo large in the middle; a hand on the
    /// ring is a hand on the record.
    fn club_jog(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        let v = &s.decks[d];
        let c = r.center();
        let rad = r.width() / 2.0 - 2.0;
        p.circle_filled(c, rad, rgb(0x121214));
        p.circle_stroke(c, rad, Stroke::new(6.0, rgb(0x3A3A3F)));
        p.circle_stroke(c, rad - 9.0, Stroke::new(1.0, LINE));
        // the mark: a turn every 1.8 s of the record
        let turn = (v.heard / 1.8).fract() as f32 * std::f32::consts::TAU - std::f32::consts::FRAC_PI_2;
        let mark = pos2(c.x + rad * turn.cos(), c.y + rad * turn.sin());
        p.circle_filled(mark, 3.5, if v.held { CUE } else { TEXT });
        if let Some(cue) = v.cue {
            let a = (cue / 1.8).fract() as f32 * std::f32::consts::TAU - std::f32::consts::FRAC_PI_2;
            p.circle_filled(pos2(c.x + rad * a.cos(), c.y + rad * a.sin()), 2.5, wave::MEMORY);
        }
        let shown = format!("{:.2}", v.bpm);
        let (whole, frac) = shown.split_once('.').unwrap_or((&shown, "00"));
        let wr = words(p, pos2(c.x + 8.0, c.y - 4.0), Align2::RIGHT_CENTER, whole, (rad * 0.42).clamp(16.0, 26.0), "mono-semi", TEXT);
        words(p, pos2(wr.right(), wr.bottom() - 4.0), Align2::LEFT_BOTTOM, &format!(".{frac}"), (rad * 0.24).clamp(10.0, 15.0), "mono-semi", TEXT);
        words(p, pos2(c.x, c.y + rad * 0.32), Align2::CENTER_CENTER, &format!("{:+.1}%", (v.rate - 1.0) * 100.0), 10.5, "mono", MUTED);
        // the hand: round the ring like the platter
        let resp = ui.interact(r, ui.scope_id().with(("club-jog", d)), Sense::drag()).on_hover_cursor(egui::CursorIcon::Grab);
        let id = ui.scope_id().with(("club-jog-a", d));
        if resp.drag_started() && v.record.playable() {
            desk.scratch(d, true);
        }
        if resp.dragged() && v.record.playable() {
            if let Some(pos) = resp.interact_pointer_pos() {
                let a = (pos.y - c.y).atan2(pos.x - c.x);
                let was: Option<f32> = ui.ctx().data(|m| m.get_temp(id));
                if let Some(was) = was {
                    let mut da = a - was;
                    if da > std::f32::consts::PI {
                        da -= std::f32::consts::TAU;
                    } else if da < -std::f32::consts::PI {
                        da += std::f32::consts::TAU;
                    }
                    desk.scratch_by(d, da as f64 / std::f64::consts::TAU * 1.8);
                }
                ui.ctx().data_mut(|m| m.insert_temp(id, a));
            }
        }
        if resp.drag_stopped() {
            desk.scratch(d, false);
            ui.ctx().data_mut(|m| m.remove::<f32>(id));
        }
    }

    /// The mixer between the decks, rekordbox's narrow one: each channel TRIM, HIGH, MID,
    /// LOW, the filter (CFX), CUE (the headphones), its meter and its fader.
    fn club_mixer(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        panel(p, r);
        let level = |pk: f32| (1.0 + 20.0 * pk.max(1e-6).log10() / 48.0).clamp(0.0, 1.0);
        let phones = desk.audio_view().headphones;
        let names = ["TRIM", "HIGH", "MID", "LOW", "CFX"];
        let col_w = (r.width() - 6.0) / 2.0;
        let step = ((r.height() - 120.0) / 5.0).clamp(26.0, 34.0);
        for d in 0..2 {
            let v = &s.decks[d];
            let cx = r.left() + 3.0 + col_w * (d as f32 + 0.5);
            for (i, name) in names.iter().enumerate() {
                let c = pos2(cx, r.top() + 14.0 + i as f32 * step);
                let (val, bip) = match i {
                    0 => (v.gain, false),
                    1 => (v.eq[2], true),
                    2 => (v.eq[1], true),
                    3 => (v.eq[0], true),
                    _ => (v.filter, true),
                };
                if let Some(nv) = knob(ui, p, c, val, bip, 0.5, ("club-knob", d, i)) {
                    match i {
                        0 => desk.set_gain(d, nv),
                        1 => desk.set_eq(d, 2, nv),
                        2 => desk.set_eq(d, 1, nv),
                        3 => desk.set_eq(d, 0, nv),
                        _ => desk.set_filter(d, nv),
                    }
                }
                words(p, pos2(c.x, c.y + 11.0), Align2::CENTER_TOP, name, 7.0, "semi", MUTED);
            }
            let cue_y = r.top() + 14.0 + 5.0 * step;
            let cue = Rect::from_center_size(pos2(cx, cue_y), vec2(col_w - 8.0, 16.0));
            if phones {
                if button(ui, p, cue, "CUE", v.headphones, CUE, ("club-phones", d)).on_hover_text("In the headphones, before the fader").clicked() {
                    desk.toggle_headphones(d);
                }
            } else {
                words(p, cue.center(), Align2::CENTER_CENTER, &(d + 1).to_string(), 11.0, "semi", MUTED);
            }
            let fr = Rect::from_min_max(pos2(cx - 20.0, cue.bottom() + 4.0), pos2(cx + 8.0, r.bottom() - 2.0));
            if fr.height() > 40.0 {
                if let Some(nv) = kit::vfader(ui, p, fr, v.fader, LIT, ("club-fader", d)) {
                    desk.set_fader(d, nv);
                }
                kit::meter(ui, p, Rect::from_min_max(pos2(cx + 15.0, fr.top() + 8.0), pos2(cx + 19.0, fr.bottom() - 4.0)), level(v.peak), 12, ("club-meter", d));
            }
        }
        p.line_segment([pos2(r.center().x, r.top() + 6.0), pos2(r.center().x, r.bottom() - 6.0)], Stroke::new(1.0, LINE));
    }

    /// The strip under the decks: the crossfader in the middle, the master's meters at the
    /// right, the headphones' blend and level at the left where there are headphones.
    fn club_strip(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        panel(p, r);
        let y = r.center().y;
        let audio = desk.audio_view();
        if audio.headphones && !audio.console_mixes {
            icons::paint(p, Rect::from_center_size(pos2(r.left() + 18.0, y), vec2(16.0, 16.0)), Icon::Headphones, MUTED);
            if let Some(nv) = knob(ui, p, pos2(r.left() + 48.0, y), audio.prefs.head_mix, false, 0.0, "club-head-mix") {
                desk.set_head_mix(nv);
            }
            words(p, pos2(r.left() + 62.0, y), Align2::LEFT_CENTER, "MIX", 9.0, "semi", MUTED);
            if let Some(nv) = knob(ui, p, pos2(r.left() + 104.0, y), audio.prefs.head_level, false, 0.75, "club-head-level") {
                desk.set_head_level(nv);
            }
            words(p, pos2(r.left() + 118.0, y), Align2::LEFT_CENTER, "LEVEL", 9.0, "semi", MUTED);
        }
        let cf = Rect::from_center_size(pos2(r.center().x, y), vec2(220.0, 30.0));
        words(p, pos2(cf.left() - 8.0, y), Align2::RIGHT_CENTER, "1", 11.0, "semi", MUTED);
        words(p, pos2(cf.right() + 8.0, y), Align2::LEFT_CENTER, "2", 11.0, "semi", MUTED);
        if let Some(x) = kit::crossfader(ui, p, cf, s.crossfader, "club-xf") {
            desk.set_auto(false);
            desk.set_crossfader(x);
        }
        // the master: two horizontal meters, as rekordbox's Master Out
        let level = |pk: f32| (1.0 + 20.0 * pk.max(1e-6).log10() / 48.0).clamp(0.0, 1.0);
        let (l, rr) = (s.decks[0].peak_lr.0.max(s.decks[1].peak_lr.0), s.decks[0].peak_lr.1.max(s.decks[1].peak_lr.1));
        let mw = 160.0;
        let mx = r.right() - 12.0 - mw;
        words(p, pos2(mx - 10.0, y), Align2::RIGHT_CENTER, "MASTER OUT", 10.0, "semi", MUTED);
        for (i, lv) in [l, rr].into_iter().enumerate() {
            let bar = Rect::from_min_size(pos2(mx, y - 6.0 + i as f32 * 7.0), vec2(mw, 4.0));
            p.rect_filled(bar, CornerRadius::ZERO, rgb(0x0A0A0B));
            let k = motion::spring(ui.ctx(), ui.scope_id().with(("club-master", i)), level(lv), 0.04);
            let lit = Rect::from_min_size(bar.min, vec2(mw * k, 4.0));
            let c = if k > 0.92 { col(theme::HOT) } else if k > 0.8 { CUE } else { PLAY };
            p.rect_filled(lit, CornerRadius::ZERO, c);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// rekordbox's grid inside every window, nothing overlapping, the side panel folded or
    /// out.
    #[test]
    fn the_club_layout_fits_every_window() {
        for size in [crate::ui::MIN, vec2(1440.0, 860.0), vec2(1920.0, 1080.0), vec2(2560.0, 1440.0), vec2(3840.0, 2160.0)] {
            let full = Rect::from_min_size(pos2(0.0, 0.0), size);
            for side in [true, false] {
                let l = layout(full, side);
                let mut panels = vec![("top", l.top), ("lane 1", l.lanes[0]), ("lane 2", l.lanes[1]), ("deck 1", l.decks[0]), ("deck 2", l.decks[1]), ("mixer", l.mixer), ("strip", l.strip), ("browser", l.browser)];
                if let Some(s) = l.side {
                    panels.push(("side", s));
                }
                for (name, r) in &panels {
                    assert!(full.contains_rect(*r), "{name} leaves the window at {size:?}: {r:?}");
                    assert!(r.width() >= 90.0 && r.height() >= 36.0, "{name} too small at {size:?}: {r:?}");
                }
                for (i, (a, ra)) in panels.iter().enumerate() {
                    for (b, rb) in &panels[i + 1..] {
                        assert!(!ra.shrink(0.5).intersects(rb.shrink(0.5)), "{a} and {b} overlap at {size:?}");
                    }
                }
                assert!(l.browser.height() >= 200.0, "the browser keeps room at {size:?}: {:?}", l.browser);
            }
        }
    }
}
