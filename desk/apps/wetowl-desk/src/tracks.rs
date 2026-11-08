//! The tracks: the two waveform lanes and the two overviews over them.
//!
//! The pictures come from the Desk in bins fixed to the record's own columns
//! (`Desk::lane_wave`, `Desk::overview`), so a lane scrolls without re-shaping. Each is one
//! mesh with its own soft edge: the outline is every band's peak, the body the record's RMS,
//! coloured by what it is made of — the deck's colour for the lows, its paler tint for the
//! mids, toward white for the highs — and what has been heard drawn dimmer in the same
//! mesh. Lines sit on whole pixels, so they do not shimmer as they pass.
use eframe::egui::{self, Align2, Color32, CornerRadius, Mesh, Painter, Pos2, Rect, Sense, Shape, Stroke, Ui, pos2, vec2};
use wo_deskcore::{Bin, Desk, DeckView, LaneWave, Snapshot, theme};

use crate::App;
use crate::paint::{col, label_sized, label_width, mmss, pad_colour, pad_name, white};
use crate::ui::icons::{self, Icon};
use crate::ui::kit::{self, alpha_of};
use crate::ui::motion;
use crate::ui::tokens::{self as t, mix};

/// `x` on the screen's own pixels.
pub(crate) fn snap(x: f32, ppp: f32) -> f32 {
    (x * ppp).round() / ppp
}

/// A vertical line one screen pixel wide (or `px`) at `x`, crisp: no feathered edge to
/// flicker as it moves.
pub(crate) fn vline(p: &Painter, x: f32, y0: f32, y1: f32, px: f32, ppp: f32, c: Color32) {
    let x = snap(x, ppp);
    let w = (px / ppp).max(1.0 / ppp);
    p.rect_filled(Rect::from_min_max(pos2(x - w / 2.0, y0), pos2(x + w / 2.0, y1)), CornerRadius::ZERO, c);
}

/// A bin's colours: its body (the lows' deck colour, toward the tint by its mids' share,
/// toward white by its highs') and its outline (the same, darker), heard-dimmed by `past`.
fn colours(d: usize, b: &Bin, past: f32) -> (Color32, Color32) {
    let [lo, mi, hi] = b.rms;
    let all = lo + mi + hi + 1e-3;
    let mut body = mix(col(theme::DECKS[d]), col(theme::TINTS[d]), (mi / all * 0.95).min(0.6));
    body = mix(body, col(theme::HIGH), (hi / all * 0.8).min(0.4));
    let mut outline = mix(col(theme::DECKS[d]), col(theme::GROUND), 0.58);
    if past > 0.0 {
        let grey = |c: Color32| {
            let l = (c.r() as f32 * 0.3 + c.g() as f32 * 0.55 + c.b() as f32 * 0.15) as u8;
            mix(c, Color32::from_rgb(l, l, l), 0.55)
        };
        body = mix(body, mix(grey(body), col(theme::GROUND), 0.5), past);
        outline = mix(outline, mix(grey(outline), col(theme::GROUND), 0.55), past);
    }
    (body, outline)
}

/// Heights of a bin: its outline (the loudest band's peak) and its body (the RMS), 0..1.
fn heights(b: &Bin) -> (f32, f32) {
    let outline = b.peak[0].max(b.peak[1] * 0.92).max(b.peak[2] * 0.8);
    let [lo, mi, hi] = b.rms;
    let body = ((lo * lo + mi * mi * 0.8 + hi * hi * 0.5).sqrt() * 1.08).min(outline);
    (outline, body)
}

/// One band of a mirrored envelope as a mesh with a feathered edge (`f` px) at top and
/// bottom: points (x, half height, colour); a None breaks it.
fn envelope(mesh: &mut Mesh, pts: &[Option<(f32, f32, Color32)>], mid: f32, f: f32) {
    let mut prev: Option<u32> = None;
    for pt in pts {
        let Some((x, a, c)) = *pt else {
            prev = None;
            continue;
        };
        let clear = Color32::from_rgba_premultiplied(0, 0, 0, 0);
        let base = mesh.vertices.len() as u32;
        let a = a.max(0.5);
        mesh.colored_vertex(pos2(x, mid - a - f), clear);
        mesh.colored_vertex(pos2(x, mid - a), c);
        mesh.colored_vertex(pos2(x, mid + a), c);
        mesh.colored_vertex(pos2(x, mid + a + f), clear);
        if let Some(q) = prev {
            for k in 0..3 {
                mesh.add_triangle(q + k, base + k, q + k + 1);
                mesh.add_triangle(q + k + 1, base + k, base + k + 1);
            }
        }
        prev = Some(base);
    }
}

/// Bins drawn across `r` from `x0`, `bin_w` apart, mirrored about `r`'s middle at most `a`
/// high; heard (left of `play`, softly over `edge` px) dimmed.
fn draw_bins(p: &Painter, r: Rect, bins: &[Option<Bin>], x0: f32, bin_w: f32, a: f32, d: usize, play: f32, edge: f32) {
    let past = |x: f32| ((play - x) / edge).clamp(0.0, 1.0);
    let mut outline = Vec::with_capacity(bins.len());
    let mut body = Vec::with_capacity(bins.len());
    for (i, b) in bins.iter().enumerate() {
        let x = x0 + (i as f32 + 0.5) * bin_w;
        if x < r.left() - bin_w || x > r.right() + bin_w {
            outline.push(None);
            body.push(None);
            continue;
        }
        match b {
            Some(b) => {
                let (ho, hb) = heights(b);
                let (cb, co) = colours(d, b, past(x));
                outline.push(Some((x, ho * a, co)));
                body.push(Some((x, hb * a, cb)));
            }
            None => {
                outline.push(None);
                body.push(None);
            }
        }
    }
    let mut mesh = Mesh::default();
    envelope(&mut mesh, &outline, r.center().y, 1.0);
    envelope(&mut mesh, &body, r.center().y, 0.8);
    p.add(Shape::mesh(mesh));
}

/// The playhead: a white line on whole pixels, a soft glow (stronger on the bar's one, as
/// it passes), small marks top and bottom.
fn playhead(p: &Painter, x: f32, top: f32, bottom: f32, pulse: f32, ppp: f32) {
    let x = snap(x, ppp);
    p.rect_filled(Rect::from_min_max(pos2(x - 5.0, top), pos2(x + 5.0, bottom)), CornerRadius::ZERO, white(0.06 + 0.16 * pulse));
    vline(p, x, top, bottom, 2.0, ppp, Color32::WHITE);
    p.add(Shape::convex_polygon(vec![pos2(x - 5.0, top), pos2(x + 5.0, top), pos2(x, top + 5.0)], Color32::WHITE, Stroke::NONE));
    p.add(Shape::convex_polygon(vec![pos2(x - 5.0, bottom), pos2(x, bottom - 5.0), pos2(x + 5.0, bottom)], Color32::WHITE, Stroke::NONE));
}

/// How bright a deck's bar-one glow is now: full on its one, gone 150 ms later.
fn downbeat(desk: &Desk, d: usize, v: &DeckView) -> f32 {
    if !v.playing || v.bpm < 1.0 {
        return 0.0;
    }
    match desk.beat_at(d, v.heard) {
        Some((into, 0)) => (1.0 - (into * 60.0 / v.bpm) as f32 / 0.15).clamp(0.0, 1.0),
        _ => 0.0,
    }
}

/// Faint diagonal lines over [x0, x1) of `r`: where the record is not.
fn hatch(p: &Painter, r: Rect, x0: f32, x1: f32) {
    let (x0, x1) = (x0.max(r.left()), x1.min(r.right()));
    if x1 - x0 < 1.0 {
        return;
    }
    let clip = p.with_clip_rect(Rect::from_min_max(pos2(x0, r.top()), pos2(x1, r.bottom())).intersect(p.clip_rect()));
    let h = r.height();
    let mut x = x0 - h - (x0 % 10.0);
    while x < x1 {
        clip.line_segment([pos2(x, r.bottom()), pos2(x + h, r.top())], Stroke::new(1.0, white(0.035)));
        x += 10.0;
    }
}

/// A section's colour on an overview: drops red, breaks violet, builds warm, the ends
/// teal (the pads' own colours); the rest none.
fn section_colour(label: &str) -> Option<Color32> {
    let l = label.to_ascii_lowercase();
    let c = if l.contains("drop") || l.contains("chorus") {
        theme::RED
    } else if l.contains("break") {
        theme::PAD_BREAK
    } else if l.contains("build") {
        theme::WARM
    } else if l.contains("intro") || l.contains("outro") {
        theme::PAD_INTRO
    } else {
        return None;
    };
    Some(col(c))
}

/// An overview kept: its record, its width in bins, how much of the record had come in.
pub(crate) type OverviewKept = Option<(i64, usize, usize, Vec<Option<Bin>>)>;

impl App {
    /// The two overviews: each whole record, its sections under it, what was heard dimmed,
    /// every second bar ticked, pads as notches, the loop, the playhead; hover shows where,
    /// a click goes there.
    pub(crate) fn overviews(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        kit::panel(p, r, true);
        let ppp = ui.ctx().pixels_per_point();
        let strip_h = 22.0;
        let gap = (r.height() - 2.0 * strip_h) / 3.0;
        for d in 0..2 {
            let y = r.top() + gap + d as f32 * (strip_h + gap * 0.5);
            kit::deck_chip(p, pos2(r.left() + 12.0, y + strip_h / 2.0), d);
            let bar = Rect::from_min_max(pos2(r.left() + 42.0, y), pos2(r.right() - 96.0, y + strip_h));
            let v = &s.decks[d];
            let len = v.length.max(1.0);
            let n = (bar.width() / 2.0).max(1.0) as usize;
            let key = (v.record.id, n, desk.wave_len(d));
            let fresh = matches!(&self.overview_kept[d], Some((id, m, w, _)) if (*id, *m, *w) == key);
            if !fresh {
                self.overview_kept[d] = Some((key.0, key.1, key.2, desk.overview(d, n)));
            }
            let bins = &self.overview_kept[d].as_ref().unwrap().3;
            let x_of = |t: f64| bar.left() + bar.width() * (t / len).clamp(0.0, 1.0) as f32;
            let clip = p.with_clip_rect(bar.expand2(vec2(2.0, 3.0)));
            // the record's form under it
            for (label, a, b) in desk.form(d).sections {
                if let Some(c) = section_colour(&label) {
                    clip.rect_filled(Rect::from_min_max(pos2(x_of(a), bar.top()), pos2(x_of(b), bar.bottom())), CornerRadius::same(2), alpha_of(c, 0.09));
                }
            }
            let at = x_of(v.heard);
            let k = motion::appear(ui.ctx(), ui.scope_id().with(("overview-in", d, v.record.id)), motion::EMPHASIS);
            let mut cp = clip.clone();
            cp.multiply_opacity(k);
            draw_bins(&cp, bar, bins, bar.left(), bar.width() / n as f32, strip_h / 2.0 - 1.0, d, at, 16.0);
            // every second bar: ticks at the edges, taller where a four-bar group starts (the
            // twos left out where they would crowd, then the fours)
            let twos = desk.two_bars(d);
            if let (Some(a), Some(b)) = (twos.first(), twos.last())
                && twos.len() > 1
            {
                let apart = (x_of(b.0) - x_of(a.0)) / (twos.len() - 1) as f32;
                for &(at, four) in &twos {
                    let (h, c) = if four { (5.0, white(0.5)) } else { (3.0, white(0.3)) };
                    if apart * if four { 2.0 } else { 1.0 } < 4.0 {
                        continue;
                    }
                    let tx = x_of(at);
                    vline(&cp, tx, bar.top(), bar.top() + h, 1.0, ppp, c);
                    vline(&cp, tx, bar.bottom() - h, bar.bottom(), 1.0, ppp, c);
                }
            }
            if let Some((a, b)) = v.looped {
                let (xa, xb) = (x_of(a), x_of(b).max(x_of(a) + 2.0));
                clip.rect_filled(Rect::from_min_max(pos2(xa, bar.top()), pos2(xb, bar.bottom())), CornerRadius::same(2), alpha_of(t::deck(d), 0.22));
                for x in [xa, xb] {
                    vline(&clip, x, bar.top(), bar.bottom(), 1.0, ppp, alpha_of(t::tint(d), 0.9));
                }
            }
            for pad in v.pads.iter().flatten() {
                let x = snap(x_of(pad.at), ppp);
                let c = col(pad_colour(pad.auto));
                vline(&clip, x, bar.top(), bar.bottom(), 1.0, ppp, alpha_of(c, 0.45));
                clip.add(Shape::convex_polygon(vec![pos2(x - 4.0, bar.top() - 2.0), pos2(x + 4.0, bar.top() - 2.0), pos2(x, bar.top() + 4.0)], c, Stroke::NONE));
            }
            playhead(&clip, at, bar.top() - 2.0, bar.bottom() + 2.0, 0.0, ppp);
            // hover: a ghost playhead and its time; a click (or a drag let go) goes there
            let resp = ui.interact(bar.expand2(vec2(0.0, 2.0)), ui.scope_id().with(("overview", d)), Sense::click_and_drag()).on_hover_cursor(egui::CursorIcon::PointingHand);
            let ghost = resp.hover_pos().or(resp.interact_pointer_pos()).filter(|_| resp.hovered() || resp.dragged()).map(|pos| pos.x.clamp(bar.left(), bar.right()));
            let time_at = |x: f32| (x - bar.left()) as f64 / bar.width() as f64 * len;
            match ghost {
                Some(x) => {
                    vline(&clip, x, bar.top(), bar.bottom(), 1.0, ppp, white(0.55));
                    kit::text(p, pos2(r.right() - 12.0, y + strip_h / 2.0), Align2::RIGHT_CENTER, &format!("→ {}", mmss(time_at(x))), 12.0, "mono", t::high());
                    if (resp.clicked() || resp.drag_stopped()) && v.length > 0.0 {
                        desk.seek_to(d, time_at(x));
                    }
                }
                None => {
                    let left = v.length - v.heard;
                    // the last half minute: warm
                    let ink = if v.length > 0.0 && left < 30.0 && v.playing { t::warm() } else { t::muted() };
                    kit::text(p, pos2(r.right() - 12.0, y + strip_h / 2.0), Align2::RIGHT_CENTER, &format!("−{}", mmss(left)), 12.0, "mono", ink);
                }
            }
        }
    }

    /// The two waveform lanes, the phase between them.
    pub(crate) fn waves(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, s: &Snapshot) {
        kit::panel(p, r, true);
        let ppp = ui.ctx().pixels_per_point();
        // scroll over the waveforms zooms them
        let over = ui.interact(r, ui.scope_id().with("waves"), Sense::hover());
        if over.hovered() {
            let dy = ui.input(|i| i.smooth_scroll_delta.y);
            if dy.abs() > 0.1 {
                self.zoom = (self.zoom * 1.0015f32.powf(dy)).clamp(40.0, 320.0);
            }
        }
        let zoom = motion::spring(ui.ctx(), ui.scope_id().with("zoom"), self.zoom, 0.16);
        let phase_h = 18.0;
        let lane_h = (r.height() - 12.0 - phase_h) / 2.0;
        let inner = r.shrink2(vec2(1.0, 0.0));
        for d in 0..2 {
            let w = Rect::from_min_size(pos2(inner.left(), r.top() + 6.0 + d as f32 * (lane_h + phase_h)), vec2(inner.width(), lane_h));
            let v = &s.decks[d];
            let lw = desk.lane_wave(d, v.heard, w.width(), 3.0, zoom);
            self.wave_lane(desk, ui, p, w, &lw, v, d, ppp);
        }
        // the hairline and the phase between the lanes
        let c = pos2(r.center().x, r.top() + 6.0 + lane_h + phase_h / 2.0);
        p.line_segment([pos2(r.left() + 12.0, c.y), pos2(c.x - 150.0, c.y)], Stroke::new(1.0, white(0.05)));
        p.line_segment([pos2(c.x + 150.0, c.y), pos2(r.right() - 12.0, c.y)], Stroke::new(1.0, white(0.05)));
        self.phase(ui, p, c, s);
    }

    /// How far apart the beats are, while both play in step: a needle on a short track
    /// (green within 5 ms); dim and still otherwise — always there, never popping in.
    fn phase(&self, ui: &Ui, p: &Painter, c: Pos2, s: &Snapshot) {
        let f = s.decks.iter().find(|d| d.synced && d.playing).filter(|_| s.decks.iter().all(|d| d.playing));
        let live = motion::tween_bool(ui.ctx(), ui.scope_id().with("phase"), f.is_some(), motion::STANDARD, motion::STANDARD);
        let ms = f.map_or(0.0, |f| f.phase_ms as f32);
        let track = Rect::from_center_size(c, vec2(140.0, 3.0));
        label_sized(p, pos2(track.left() - 10.0, c.y), Align2::RIGHT_CENTER, "Phase", 9.5, alpha_of(t::label(), 0.45 + 0.55 * live));
        p.rect_filled(track, CornerRadius::same(2), col(theme::LINE));
        for k in [-1.0f32, -0.5, 0.0, 0.5, 1.0] {
            let h = if k == 0.0 { 9.0 } else { 5.0 };
            p.rect_filled(Rect::from_center_size(pos2(c.x + k * 68.0, c.y), vec2(1.0, h)), CornerRadius::ZERO, white(if k == 0.0 { 0.35 } else { 0.14 }));
        }
        let off = motion::spring(ui.ctx(), ui.scope_id().with("phase-x"), (ms / 20.0).clamp(-1.0, 1.0) * 68.0 * live, 0.2);
        let ok = ms.abs() < 5.0;
        if live > 0.01 {
            p.rect_filled(Rect::from_center_size(pos2(c.x + off, c.y), vec2(4.0, 12.0)), CornerRadius::same(2), alpha_of(if ok { t::ok() } else { t::warm() }, live));
        }
        let words = if f.is_some() { format!("{ms:+.1} ms") } else { "—".to_owned() };
        kit::text(p, pos2(track.right() + 10.0, c.y), Align2::LEFT_CENTER, &words, 10.5, "mono", alpha_of(if ok && f.is_some() { Color32::from_rgb(0xCF, 0xF5, 0xDF) } else { t::muted() }, 0.5 + 0.5 * live));
    }

    /// One lane: where the record is not hatched, the grid (every second bar marked), the
    /// record (as it comes in),
    /// the loop, the pads' flags, the playhead; its glass tab.
    #[allow(clippy::too_many_arguments)]
    fn wave_lane(&mut self, desk: &Desk, ui: &Ui, p: &Painter, w: Rect, lw: &LaneWave, v: &DeckView, d: usize, ppp: f32) {
        let clip = p.with_clip_rect(w.intersect(p.clip_rect()));
        let x = |lx: f32| w.left() + lx;
        let play = w.center().x;
        let loaded = v.record.id != 0 || v.length > 0.0;
        // where the record is not
        if loaded {
            hatch(&clip, w, w.left(), x(lw.start));
            hatch(&clip, w, x(lw.end), w.right());
            if x(lw.start) > w.left() {
                vline(&clip, x(lw.start), w.top(), w.bottom(), 1.0, ppp, white(0.22));
            }
        }
        // the record, fading in when it is put on
        let k = motion::appear(ui.ctx(), ui.scope_id().with(("wave", d, v.record.id)), motion::EMPHASIS);
        let mut wp = clip.clone();
        wp.multiply_opacity(k);
        draw_bins(&wp, w, &lw.bins, w.left() + lw.x0, lw.bin_w, w.height() / 2.0 - 3.0, d, play, 24.0);
        // the grid over it: beats as ticks at the edges, bars faint; every second bar marked
        // (a brighter line, caps at top and bottom), four-bar groups brighter still and
        // numbered
        for &bx in &lw.lines.beats {
            vline(&clip, x(bx), w.top(), w.top() + 5.0, 1.0, ppp, white(0.24));
            vline(&clip, x(bx), w.bottom() - 5.0, w.bottom(), 1.0, ppp, white(0.24));
        }
        for &bx in &lw.lines.bars {
            vline(&clip, x(bx), w.top(), w.bottom(), 1.0, ppp, Color32::from_black_alpha(70));
            vline(&clip, x(bx) + 1.0 / ppp, w.top(), w.bottom(), 1.0, ppp, white(0.06));
        }
        let caps = |bx: f32, len: f32, c: Color32| {
            vline(&clip, bx, w.top(), w.top() + len, 3.0, ppp, c);
            vline(&clip, bx, w.bottom() - len, w.bottom(), 3.0, ppp, c);
        };
        for &bx in &lw.lines.twos {
            vline(&clip, x(bx), w.top(), w.bottom(), 1.0, ppp, white(0.14));
            caps(x(bx), 8.0, white(0.42));
        }
        for &(bx, n) in &lw.lines.fours {
            vline(&clip, x(bx), w.top(), w.bottom(), 1.0, ppp, white(0.26));
            caps(x(bx), 12.0, white(0.7));
            kit::text(&clip, pos2(snap(x(bx), ppp) + 5.0, w.bottom() - 3.0), Align2::LEFT_BOTTOM, &n.to_string(), 9.5, "mono", white(0.4));
        }
        // still coming in: its front edge
        if let Some(a) = lw.arriving.map(x).filter(|a| *a > w.left() && *a < w.right()) {
            let mut g = Mesh::default();
            let (c0, c1) = (alpha_of(t::deck(d), 0.0), alpha_of(t::deck(d), 0.22));
            g.colored_vertex(pos2(a - 28.0, w.top()), c0);
            g.colored_vertex(pos2(a, w.top()), c1);
            g.colored_vertex(pos2(a, w.bottom()), c1);
            g.colored_vertex(pos2(a - 28.0, w.bottom()), c0);
            g.add_triangle(0, 1, 2);
            g.add_triangle(0, 2, 3);
            clip.add(Shape::mesh(g));
            vline(&clip, a, w.top(), w.bottom(), 1.0, ppp, alpha_of(t::tint(d), 0.6));
        }
        // the loop: its band, brackets at in and out, its length on a tab
        let looped = motion::tween_bool(ui.ctx(), ui.scope_id().with(("looped", d)), v.looped.is_some(), motion::STANDARD, motion::STANDARD);
        let kept = ui.ctx().data_mut(|m| {
            let k = m.get_temp_mut_or_insert_with(ui.scope_id().with(("loop-was", d)), || (0.0f64, 0.0f64));
            if let Some(l) = v.looped {
                *k = l;
            }
            *k
        });
        if looped > 0.0 && kept.1 > kept.0 {
            let tx = |t: f64| play + ((t - lw.heard) * lw.px_per_s) as f32;
            let (xa, xb) = (snap(tx(kept.0), ppp), snap(tx(kept.1), ppp));
            clip.rect_filled(Rect::from_min_max(pos2(xa, w.top()), pos2(xb, w.bottom())), CornerRadius::ZERO, alpha_of(t::deck(d), 0.13 * looped));
            for (bx, dir) in [(xa, 1.0f32), (xb, -1.0)] {
                let c = alpha_of(t::tint(d), 0.9 * looped);
                vline(&clip, bx, w.top(), w.bottom(), 2.0, ppp, c);
                clip.line_segment([pos2(bx, w.top() + 1.0), pos2(bx + 6.0 * dir, w.top() + 1.0)], Stroke::new(2.0, c));
                clip.line_segment([pos2(bx, w.bottom() - 1.0), pos2(bx + 6.0 * dir, w.bottom() - 1.0)], Stroke::new(2.0, c));
            }
            if let Some(b) = v.loop_beats {
                let words = loop_words(b);
                let tw = label_width(p, &words, 9.5) + 12.0;
                let tab = Rect::from_min_size(pos2(xa + 8.0, w.top() + 6.0), vec2(tw, 16.0));
                clip.rect_filled(tab, CornerRadius::same(3), alpha_of(t::deck(d), 0.85 * looped));
                label_sized(&clip, tab.center(), Align2::CENTER_CENTER, &words, 9.5, alpha_of(col(theme::GROUND), looped));
            }
        }
        // the pads: a line and a flag with its number and word, dropping in when set
        for (px, i, pad) in &lw.lines.pads {
            let c = col(pad_colour(pad.auto));
            let at = snap(x(*px), ppp);
            let k = motion::appear(ui.ctx(), ui.scope_id().with(("flag", d, *i, (pad.at * 1000.0) as i64)), motion::STANDARD);
            vline(&clip, at, w.top(), w.bottom(), 1.0, ppp, alpha_of(c, 0.75 * k));
            let words = format!("{} {}", i + 1, pad_name(pad.auto));
            let fw = label_width(p, &words, 9.5) + 10.0;
            let flag = Rect::from_min_size(pos2(at, w.top() + 1.0 - 6.0 * (1.0 - k)), vec2(fw, 15.0));
            clip.rect_filled(flag, CornerRadius { nw: 0, ne: 3, sw: 0, se: 3 }, alpha_of(c, k));
            label_sized(&clip, pos2(flag.left() + 5.0, flag.center().y), Align2::LEFT_CENTER, &words, 9.5, alpha_of(col(theme::GROUND), k));
        }
        playhead(&clip, play, w.top(), w.bottom(), downbeat(desk, d, v), ppp);
        // the lane's tab: its deck, how it is
        let (icon, word, lit) = if v.decoded <= 0.0 && loaded {
            (None, "Loading".to_owned(), false)
        } else if v.decoded < 1.0 && loaded {
            (None, format!("Loading {:.0}%", v.decoded * 100.0), false)
        } else if v.master && v.playing {
            (Some(Icon::Play), "Master".to_owned(), true)
        } else if v.synced {
            (Some(Icon::Sync), "In step".to_owned(), false)
        } else if v.playing {
            (Some(Icon::Play), "Playing".to_owned(), false)
        } else {
            (Some(Icon::Pause), "Parked".to_owned(), false)
        };
        let ww = label_width(p, &word, 10.0);
        let tab = Rect::from_min_size(pos2(w.left() + 10.0, w.top() + 7.0), vec2(30.0 + if icon.is_some() { 16.0 } else { 0.0 } + ww + 10.0, 22.0));
        kit::glass_tab(p, tab);
        kit::deck_chip(p, pos2(tab.left() + 3.0, tab.center().y), d);
        let mut tx = tab.left() + 30.0;
        if let Some(i) = icon {
            icons::paint(p, Rect::from_center_size(pos2(tx + 5.0, tab.center().y), vec2(11.0, 11.0)), i, if lit { t::tint(d) } else { t::muted() });
            tx += 16.0;
        }
        label_sized(p, pos2(tx, tab.center().y), Align2::LEFT_CENTER, &word, 10.0, if lit { t::tint(d) } else { t::soft() });
        if v.decoded < 1.0 && loaded {
            let bar = Rect::from_min_size(pos2(tab.left() + 4.0, tab.bottom() - 3.0), vec2((tab.width() - 8.0) * v.decoded.max(0.0), 2.0));
            p.rect_filled(bar, CornerRadius::same(1), t::tint(d));
        }
    }
}

/// A loop's length in words: "¼ beat", "1 beat", "4 beats", "2 bars".
pub(crate) fn loop_words(beats: f64) -> String {
    match beats {
        b if b < 0.3 => "¼ beat".into(),
        b if b < 0.6 => "½ beat".into(),
        b if (b - 1.0).abs() < 1e-6 => "1 beat".into(),
        b if b >= 8.0 && (b / 4.0).fract().abs() < 1e-6 => format!("{} bars", b / 4.0),
        b => format!("{b} beats"),
    }
}
