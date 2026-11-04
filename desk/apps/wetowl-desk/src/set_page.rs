//! PLAN A SET (v1's set_planner_page.dart): where the records come from, how the set
//! should go, and the set the house builds from that — every record with how well it
//! follows the one before and why — to play, build again, or let go of.
use eframe::egui::{Align2, Color32, CornerRadius, Painter, Rect, Sense, Shape, Stroke, Ui, pos2, vec2};
use wo_deskcore::Desk;
use wo_deskcore::set::{Arc, Keys};

use crate::App;
use crate::paint::{mmss, white};
use crate::ui::icons::Icon;
use crate::ui::kit::{self, Btn, alpha_of};
use crate::ui::tokens::{self as t, Tone};

impl App {
    pub(crate) fn set_page(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let left = Rect::from_min_size(r.min, vec2(360.0, r.height()));
        let right = Rect::from_min_max(pos2(left.right() + 28.0, r.top()), r.max);
        self.set_controls(desk, ui, p, left);
        self.set_list(desk, ui, p, right);
    }

    fn set_controls(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let mut y = r.top();
        let row = |p: &Painter, y: f32, word: &str| {
            kit::section(p, pos2(r.left(), y + 11.0), Align2::LEFT_CENTER, word);
        };
        // where from: the library, or one playlist
        row(p, y, "From");
        y += 26.0;
        let lists = desk.library().playlists.clone();
        let mut x = r.left();
        let mut chips: Vec<(String, Option<(i64, String)>)> = vec![("The library".into(), None)];
        chips.extend(lists.iter().take(10).map(|l| (l.name.clone(), Some((l.id, l.name.clone())))));
        for (i, (word, which)) in chips.into_iter().enumerate() {
            let w = kit::chip_width(p, &word).min(r.width());
            if x + w > r.right() {
                x = r.left();
                y += 32.0;
            }
            let cr = Rect::from_min_size(pos2(x, y), vec2(w, 26.0));
            let on = self.set_shape.playlist.as_ref().map(|p| p.0) == which.as_ref().map(|p| p.0);
            if kit::chip(ui, p, cr, &word, on, Tone::Neutral, true, ("set-from", i)).clicked() {
                self.set_shape.playlist = which;
            }
            x = cr.right() + 6.0;
        }
        y += 40.0;
        // how long
        row(p, y, "Length");
        let tracks = [8u32, 12, 16, 24, 32];
        let names: Vec<String> = tracks.iter().map(|n| format!("{n}")).collect();
        let names: Vec<&str> = names.iter().map(String::as_str).collect();
        let seg = Rect::from_min_size(pos2(r.left() + 90.0, y), vec2(r.width() - 90.0, 24.0));
        let chosen = self.set_shape.minutes.is_none().then(|| tracks.iter().position(|&n| n == self.set_shape.tracks)).flatten();
        if let Some(i) = kit::segmented(ui, p, seg, &names, chosen, Tone::Neutral, "set-tracks") {
            self.set_shape.tracks = tracks[i];
            self.set_shape.minutes = None;
        }
        y += 30.0;
        let mins = [30.0, 60.0, 90.0, 120.0];
        let seg = Rect::from_min_size(pos2(r.left() + 90.0, y), vec2(r.width() - 90.0, 24.0));
        kit::hint(p, pos2(r.left(), y + 12.0), Align2::LEFT_CENTER, "or minutes");
        let chosen = self.set_shape.minutes.and_then(|m| mins.iter().position(|&x| x == m));
        if let Some(i) = kit::segmented(ui, p, seg, &["30", "60", "90", "120"], chosen, Tone::Neutral, "set-minutes") {
            self.set_shape.minutes = Some(mins[i]);
        }
        y += 40.0;
        // its energy over time
        row(p, y, "Energy");
        y += 26.0;
        let mut x = r.left();
        for (i, a) in Arc::ALL.into_iter().enumerate() {
            let w = kit::chip_width(p, a.word());
            if x + w > r.right() {
                x = r.left();
                y += 32.0;
            }
            let cr = Rect::from_min_size(pos2(x, y), vec2(w, 26.0));
            if kit::chip(ui, p, cr, a.word(), self.set_shape.arc == a, Tone::Neutral, true, ("set-arc", i)).clicked() {
                self.set_shape.arc = a;
            }
            x = cr.right() + 6.0;
        }
        y += 34.0;
        let curve = Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), 46.0));
        p.rect_filled(curve, CornerRadius::same(4), Color32::from_black_alpha(60));
        let pts: Vec<_> = (0..=40).map(|i| {
            let k = i as f64 / 40.0;
            pos2(curve.left() + curve.width() * k as f32, curve.bottom() - 4.0 - (curve.height() - 8.0) * self.set_shape.arc.at(k) as f32)
        }).collect();
        p.add(Shape::line(pts, Stroke::new(2.0, t::warm())));
        y += 58.0;
        // keys, variety, familiarity
        row(p, y, "Keys");
        let seg = Rect::from_min_size(pos2(r.left() + 90.0, y), vec2(r.width() - 90.0, 24.0));
        let keys = [Keys::Strict, Keys::Loose, Keys::Any];
        if let Some(i) = kit::segmented(ui, p, seg, &["Never clash", "Loose", "Any"], keys.iter().position(|&k| k == self.set_shape.keys), Tone::Neutral, "set-keys") {
            self.set_shape.keys = keys[i];
        }
        y += 32.0;
        let three = [0.15, 0.5, 0.85];
        let at = |v: f64| three.iter().position(|&x| (x - v).abs() < 0.01);
        row(p, y, "Next to");
        let seg = Rect::from_min_size(pos2(r.left() + 90.0, y), vec2(r.width() - 90.0, 24.0));
        if let Some(i) = kit::segmented(ui, p, seg, &["Unlike", "As judged", "Alike"], at(self.set_shape.smooth), Tone::Neutral, "set-smooth") {
            self.set_shape.smooth = three[i];
        }
        y += 32.0;
        row(p, y, "Records");
        let seg = Rect::from_min_size(pos2(r.left() + 90.0, y), vec2(r.width() - 90.0, 24.0));
        if let Some(i) = kit::segmented(ui, p, seg, &["Favourites", "Mixed", "Fresh"], at(self.set_shape.fresh), Tone::Neutral, "set-fresh") {
            self.set_shape.fresh = three[i];
        }
        y += 32.0;
        let cr = Rect::from_min_size(pos2(r.left() + 90.0, y), vec2(kit::chip_width(p, "Taken apart first"), 26.0));
        if kit::chip(ui, p, cr, "Taken apart first", self.set_shape.stems, Tone::Neutral, true, "set-stems").on_hover_text("Records whose stems are made first: the stem moves need them").clicked() {
            self.set_shape.stems = !self.set_shape.stems;
        }
        // build; play it, or let it go
        let v = desk.set_view();
        let by = r.bottom() - 36.0;
        let bw = (r.width() - 8.0) / 2.0;
        let build = Rect::from_min_size(pos2(r.left(), by), vec2(bw, 36.0));
        let go = Rect::from_min_size(pos2(r.left() + bw + 8.0, by), vec2(bw, 36.0));
        if Btn::new(if v.set.is_some() { "Build again" } else { "Build the set" }).icon(Icon::Layers).tone(Tone::Ok).enabled(!v.building).show(ui, p, build, "set-build").clicked() {
            desk.build_set(self.set_shape.clone());
        }
        if v.playing {
            if Btn::new("Let it go").icon(Icon::Close).show(ui, p, go, "set-stop").on_hover_text("The Auto DJ chooses for itself again").clicked() {
                desk.stop_set();
            }
        } else if Btn::new("Play this set").icon(Icon::Play).tone(Tone::Deck(0)).enabled(v.set.is_some()).show(ui, p, go, "set-play").clicked() {
            desk.play_set();
        }
    }

    fn set_list(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let v = desk.set_view();
        if v.building {
            kit::hint(p, r.center(), Align2::CENTER_CENTER, "The house is building it…");
            return;
        }
        if let Some(e) = &v.error {
            kit::text(p, pos2(r.left(), r.top() + 10.0), Align2::LEFT_CENTER, e, 13.0, "", t::warm());
        }
        let Some(set) = v.set else {
            kit::hint(p, r.center(), Align2::CENTER_CENTER, "Choose how it should go, then build it: the house picks and orders the records");
            return;
        };
        let n = set.slots.len().max(1);
        // the energy: the shape's wish (line) and what each record brings (dots)
        let chart = Rect::from_min_size(pos2(r.left(), r.top() + 22.0), vec2(r.width(), 64.0));
        kit::section(p, r.left_top(), Align2::LEFT_TOP, &format!("{} records{}", set.slots.len(), if v.playing { "  ·  playing" } else { "" }));
        let total = set.slots.last().map_or(0.0, |s| s.at + s.record.seconds as f64);
        kit::text(p, pos2(r.right(), r.top() + 6.0), Align2::RIGHT_CENTER, &mmss(total), 12.0, "mono", t::muted());
        p.rect_filled(chart, CornerRadius::same(4), Color32::from_black_alpha(60));
        let xi = |i: usize| chart.left() + 10.0 + (chart.width() - 20.0) * (i as f32 + 0.5) / n as f32;
        let yi = |e: f64| chart.bottom() - 6.0 - (chart.height() - 12.0) * e.clamp(0.0, 1.0) as f32;
        let wish: Vec<_> = set.slots.iter().enumerate().map(|(i, s)| pos2(xi(i), yi(s.target))).collect();
        p.add(Shape::line(wish, Stroke::new(1.5, alpha_of(t::warm(), 0.8))));
        for (i, s) in set.slots.iter().enumerate() {
            if let Some(e) = s.energy {
                p.circle_filled(pos2(xi(i), yi(e)), 3.5, if i < v.at { white(0.35) } else { t::deck(0) });
            }
        }
        // the records
        let row_h = 30.0;
        let top = chart.bottom() + 14.0;
        let rows = ((r.bottom() - top) / row_h).floor().max(0.0) as usize;
        let first = v.at.saturating_sub(2).min(set.slots.len().saturating_sub(rows));
        for (j, s) in set.slots.iter().enumerate().skip(first).take(rows) {
            let y = top + (j - first) as f32 * row_h;
            let rr = Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), row_h - 2.0));
            let played = j < v.at.saturating_sub(1);
            let now = v.playing && j + 1 == v.at;
            if now {
                p.rect_filled(rr, CornerRadius::same(4), alpha_of(t::deck(0), 0.16));
            }
            let fade = if played { 0.45 } else { 1.0 };
            let c = |col: Color32| alpha_of(col, fade);
            kit::text(p, pos2(rr.left() + 4.0, rr.center().y), Align2::LEFT_CENTER, &format!("{:>2}", j + 1), 11.0, "mono", c(t::faint()));
            kit::text(p, pos2(rr.left() + 30.0, rr.center().y), Align2::LEFT_CENTER, &mmss(s.at), 11.0, "mono", c(t::faint()));
            let meta = format!("{}  {}", s.bpm.map_or("—".into(), |b| format!("{b:.0}")), s.camelot.as_deref().unwrap_or(""));
            let mr = kit::text(p, pos2(rr.right() - 70.0, rr.center().y), Align2::RIGHT_CENTER, &meta, 11.0, "mono", c(t::muted()));
            // fit with the one before
            if let Some(f) = s.fit {
                let fb = Rect::from_min_size(pos2(rr.right() - 60.0, rr.center().y - 2.0), vec2(56.0 * f.clamp(0.0, 1.0) as f32, 4.0));
                p.rect_filled(Rect::from_min_size(fb.min, vec2(56.0, 4.0)), CornerRadius::same(2), white(0.08));
                p.rect_filled(fb, CornerRadius::same(2), c(if f >= 0.6 { t::ok() } else if f >= 0.4 { t::warm() } else { t::red() }));
            }
            let room = mr.left() - rr.left() - 90.0;
            let title = format!("{}  ·  {}", s.record.title, s.record.artist);
            kit::clipped(p, pos2(rr.left() + 76.0, rr.center().y), &title, 12.5, if now { "semi" } else { "" }, c(t::text()), room);
            if !s.why.is_empty() {
                ui.interact(rr, ui.scope_id().with(("set-why", j)), Sense::hover()).on_hover_text(&s.why);
            }
        }
    }
}
