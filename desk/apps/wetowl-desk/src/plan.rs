//! The plan view (P): what the Auto DJ is about to do, drawn out, with a hand on it —
//! v1's console_plan.dart. The two records as two lanes on one ruler of bars, lined up
//! the way the mix lines them up, the move's curves over them; beside them the moves the
//! planner weighed, its length, the out and in a phrase either way.
use eframe::egui::{Align2, Color32, CornerRadius, Painter, Rect, Sense, Shape, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::plan_view::{Lane, PlanView};
use wo_deskcore::{Desk, Snapshot};

use crate::App;
use crate::paint::white;
use crate::ui::icons::Icon;
use crate::ui::kit::{self, Btn, alpha_of};
use crate::ui::tokens::{self as t, Tone};

/// The voice's colour on a lane, and the stems' (drums, rest, voice).
const VOICE: Color32 = Color32::from_rgb(0xF2, 0xC9, 0x4C);
const STEMS: [Color32; 3] = [Color32::from_rgb(0xE8, 0x5D, 0x4A), Color32::from_rgb(0x5F, 0xB3, 0xF0), VOICE];

impl App {
    pub(crate) fn plan(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, _s: &Snapshot) {
        kit::panel(p, r, false);
        let inner = r.shrink(t::INSET);
        let Some(v) = desk.plan_view() else {
            kit::section(p, inner.left_top(), Align2::LEFT_TOP, "The plan");
            kit::hint(p, inner.center(), Align2::CENTER_CENTER, "Nothing planned yet: the Auto DJ plans once a record plays and the next is on its deck  ·  P back to the waveforms");
            return;
        };
        let side_w = (inner.width() * 0.3).clamp(300.0, 460.0);
        let lanes_r = Rect::from_min_max(inner.min, pos2(inner.right() - side_w - 20.0, inner.bottom()));
        let side_r = Rect::from_min_max(pos2(lanes_r.right() + 20.0, inner.top()), inner.max);
        self.plan_lanes(ui, p, lanes_r, &v);
        self.plan_side(desk, ui, p, side_r, &v);
    }

    fn plan_lanes(&self, ui: &Ui, p: &Painter, r: Rect, v: &PlanView) {
        // the header: the move, its reason
        let head = format!("{} → {}  ·  {} · {} bars", ["A", "B"][v.from], ["A", "B"][v.to], v.kind.word(), v.bars);
        let hr = kit::text(p, pos2(r.left(), r.top() + 8.0), Align2::LEFT_CENTER, &head, 13.0, "semi", t::text());
        kit::clipped(p, pos2(hr.right() + 14.0, r.top() + 8.0), &v.why, 11.5, "", t::label(), r.right() - hr.right() - 14.0);
        // the ruler: bars from −context to bars + context
        let (lo, hi) = (-v.context, v.bars as f64 + v.context);
        let body = Rect::from_min_max(pos2(r.left(), r.top() + 24.0), r.max);
        let x = |b: f64| body.left() + body.width() * ((b - lo) / (hi - lo)) as f32;
        let ruler_h = 16.0;
        let lane_h = (body.height() - ruler_h - 8.0) / 2.0;
        let lane_a = Rect::from_min_size(body.min, vec2(body.width(), lane_h));
        let ruler = Rect::from_min_size(pos2(body.left(), lane_a.bottom() + 4.0), vec2(body.width(), ruler_h));
        let lane_b = Rect::from_min_size(pos2(body.left(), ruler.bottom() + 4.0), vec2(body.width(), lane_h));
        // the move's bars lit across both lanes
        let mv = Rect::from_min_max(pos2(x(0.0), lane_a.top()), pos2(x(v.bars as f64), lane_b.bottom()));
        p.rect_filled(mv, CornerRadius::same(4), white(0.035));
        p.rect_stroke(mv, CornerRadius::same(4), Stroke::new(1.0, white(0.12)), StrokeKind::Inside);
        // ruler ticks: every bar, a number every four
        let mut b = lo.ceil();
        while b <= hi {
            let major = (b as i64).rem_euclid(4) == 0;
            let xx = x(b);
            p.line_segment([pos2(xx, ruler.center().y - if major { 5.0 } else { 2.0 }), pos2(xx, ruler.center().y + if major { 5.0 } else { 2.0 })], Stroke::new(1.0, white(if major { 0.3 } else { 0.12 })));
            if major && (b as i64).rem_euclid(if v.bars > 32 { 16 } else { 8 }) == 0 {
                kit::text(p, pos2(xx + 3.0, ruler.center().y), Align2::LEFT_CENTER, &format!("{}", b as i64), 9.5, "mono", t::faint());
            }
            b += 1.0;
        }
        self.lane(p, lane_a, &v.lanes[0], v.from, &x, lo, hi);
        self.lane(p, lane_b, &v.lanes[1], v.to, &x, lo, hi);
        // the move over them: each side's level; its bass (dashed when out); the stems
        let curve = |lane: Rect, pick: &dyn Fn(&wo_deskcore::plan_view::Curve) -> f32, c: Color32, w: f32| {
            let pts: Vec<_> = v.curves.iter().map(|cv| pos2(x(cv.k * v.bars as f64), lane.bottom() - 4.0 - (lane.height() - 8.0) * pick(cv).clamp(0.0, 1.0))).collect();
            p.add(Shape::line(pts, Stroke::new(w, c)));
        };
        curve(lane_a, &|c| c.from, alpha_of(t::deck(v.from), 0.95), 2.0);
        curve(lane_b, &|c| c.to, alpha_of(t::deck(v.to), 0.95), 2.0);
        let bass = |db: f32| ((db + 40.0) / 40.0).clamp(0.0, 1.0);
        curve(lane_a, &|c| bass(c.from_low) * 0.5, white(0.35), 1.0);
        curve(lane_b, &|c| bass(c.to_low) * 0.5, white(0.35), 1.0);
        for (i, sc) in STEMS.iter().enumerate() {
            if v.curves.iter().any(|c| c.from_stems.is_some()) {
                curve(lane_a, &|c| c.from_stems.map_or(1.0, |s| s[i]) * (0.94 - 0.04 * i as f32), alpha_of(*sc, 0.7), 1.2);
            }
            if v.curves.iter().any(|c| c.to_stems.is_some()) {
                curve(lane_b, &|c| c.to_stems.map_or(1.0, |s| s[i]) * (0.94 - 0.04 * i as f32), alpha_of(*sc, 0.7), 1.2);
            }
        }
        // the filter: a shade where it takes a side's top or bottom away
        for (lane, pick) in [(lane_a, 0usize), (lane_b, 1)] {
            for w in v.curves.windows(2) {
                let f = if pick == 0 { w[0].from_filter } else { w[0].to_filter };
                if f.abs() < 0.05 {
                    continue;
                }
                let (x0, x1) = (x(w[0].k * v.bars as f64), x(w[1].k * v.bars as f64));
                let h = lane.height() * f.abs() * 0.8;
                let rr = if f > 0.0 { Rect::from_min_max(pos2(x0, lane.bottom() - h), pos2(x1, lane.bottom())) } else { Rect::from_min_max(pos2(x0, lane.top()), pos2(x1, lane.top() + h)) };
                p.rect_filled(rr, CornerRadius::ZERO, Color32::from_black_alpha(70));
            }
        }
        // where the move is
        if v.mixing {
            let xx = x(v.progress * v.bars as f64);
            p.line_segment([pos2(xx, lane_a.top()), pos2(xx, lane_b.bottom())], Stroke::new(1.5, Color32::WHITE));
        }
        let _ = ui;
    }

    /// One record's lane: how hard each bar hits, its voice, phrases, drops, sections, hook.
    fn lane(&self, p: &Painter, r: Rect, l: &Lane, d: usize, x: &dyn Fn(f64) -> f32, lo: f64, hi: f64) {
        p.rect_filled(r, CornerRadius::same(4), Color32::from_black_alpha(60));
        let clip = p.with_clip_rect(r);
        // the bars, by loudness
        let tone = t::deck(d);
        for (i, &(b, db)) in l.bars_db.iter().enumerate() {
            let next = l.bars_db.get(i + 1).map_or(b + 1.0, |n| n.0);
            if next < lo || b > hi {
                continue;
            }
            let k = ((db + 30.0) / 26.0).clamp(0.05, 1.0) as f32;
            let h = (r.height() - 14.0) * k;
            let br = Rect::from_min_max(pos2(x(b) + 0.5, r.bottom() - 6.0 - h), pos2(x(next) - 0.5, r.bottom() - 6.0));
            clip.rect_filled(br, CornerRadius::same(1), alpha_of(tone, 0.22));
        }
        // the sections, faint labels along the top
        for (label, a, b) in &l.sections {
            if *b < lo || *a > hi {
                continue;
            }
            let xa = x(*a).max(r.left());
            clip.line_segment([pos2(x(*a), r.top()), pos2(x(*a), r.bottom())], Stroke::new(1.0, white(0.08)));
            kit::text(&clip, pos2(xa + 4.0, r.top() + 8.0), Align2::LEFT_CENTER, label, 9.5, "", t::faint());
        }
        // phrases
        for &ph in l.phrases.iter().filter(|&&b| b >= lo && b <= hi) {
            clip.line_segment([pos2(x(ph), r.top() + 14.0), pos2(x(ph), r.bottom())], Stroke::new(1.0, white(0.16)));
        }
        // the voice: a strip along the bottom
        for &s in l.sung.iter().filter(|&&b| b >= lo - 1.0 && b <= hi) {
            clip.rect_filled(Rect::from_min_max(pos2(x(s) + 0.5, r.bottom() - 5.0), pos2(x(s + 1.0) - 0.5, r.bottom() - 1.0)), CornerRadius::ZERO, alpha_of(VOICE, 0.85));
        }
        // drops and the hook
        for &dr in l.drops.iter().filter(|&&b| b >= lo && b <= hi) {
            clip.line_segment([pos2(x(dr), r.top()), pos2(x(dr), r.bottom())], Stroke::new(1.5, alpha_of(t::red(), 0.8)));
            kit::text(&clip, pos2(x(dr) + 3.0, r.top() + 20.0), Align2::LEFT_CENTER, "DROP", 9.0, "mono-semi", t::red());
        }
        if let Some(&h) = l.hook.iter().find(|&&b| b >= lo && b <= hi) {
            let words = l.hook_words.clone().unwrap_or_else(|| "hook".into());
            kit::clipped(&clip, pos2(x(h) + 3.0, r.bottom() - 12.0), &format!("“{words}”"), 10.0, "", alpha_of(VOICE, 0.9), 220.0);
        }
        // where it is now
        if l.now >= lo && l.now <= hi {
            clip.line_segment([pos2(x(l.now), r.top()), pos2(x(l.now), r.bottom())], Stroke::new(1.0, white(0.7)));
        }
        // whose lane
        let chip = kit::deck_chip(p, pos2(r.left() + 6.0, r.top() + 10.0), d);
        kit::clipped(p, pos2(chip.right() + 8.0, r.top() + 10.0), &l.record.title, 11.5, "semi", t::soft(), 260.0);
    }

    fn plan_side(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, v: &PlanView) {
        let steer = !v.mixing;
        // its length
        kit::section(p, pos2(r.left(), r.top() + 8.0), Align2::LEFT_CENTER, "Bars");
        let lengths = [4u32, 8, 16, 32, 64];
        let names: Vec<String> = lengths.iter().map(|b| b.to_string()).collect();
        let names: Vec<&str> = names.iter().map(String::as_str).collect();
        let seg = Rect::from_min_size(pos2(r.left() + 46.0, r.top() - 3.0), vec2(200.0, 22.0));
        if let Some(i) = kit::segmented(ui, p, seg, &names, lengths.iter().position(|&b| b == v.bars), Tone::Neutral, "plan-bars")
            && steer
        {
            desk.set_bars(lengths[i]);
        }
        let auto = Rect::from_min_size(pos2(r.right() - 70.0, r.top() - 3.0), vec2(70.0, 22.0));
        if Btn::new("Auto").icon(Icon::Dice).enabled(steer).quiet().size(10.0).show(ui, p, auto, "plan-auto").on_hover_text("Back to the Auto DJ's own choice").clicked() {
            desk.let_the_planner_choose();
        }
        // out and in a phrase either way
        let row_y = r.top() + 26.0;
        for (i, (word, tip)) in [("Out", "The old record goes out"), ("In", "The new record comes in")].into_iter().enumerate() {
            let x0 = r.left() + i as f32 * (r.width() / 2.0);
            kit::text(p, pos2(x0, row_y + 11.0), Align2::LEFT_CENTER, word, 11.0, "mono-semi", t::label());
            for (j, (icon, dir)) in [(Icon::ChevronLeft, -1), (Icon::ChevronRight, 1)].into_iter().enumerate() {
                let br = Rect::from_min_size(pos2(x0 + 34.0 + j as f32 * 36.0, row_y), vec2(32.0, 22.0));
                let what = format!("{tip} a phrase {}", if dir < 0 { "sooner" } else { "later" });
                if Btn::new("").icon(icon).enabled(steer).quiet().show(ui, p, br, ("plan-nudge", i, j)).on_hover_text(what).clicked() {
                    if i == 0 { desk.nudge_out(dir) } else { desk.nudge_in(dir) }
                }
            }
        }
        // the moves the planner weighed, best first
        let list_top = row_y + 32.0;
        kit::section(p, pos2(r.left(), list_top), Align2::LEFT_TOP, "What it weighed");
        let top_score = v.options.iter().map(|o| o.score).fold(0.01f64, f64::max);
        let row_h = 22.0;
        let rows = ((r.bottom() - list_top - 20.0) / row_h).floor().max(0.0) as usize;
        for (i, o) in v.options.iter().take(rows).enumerate() {
            let y = list_top + 20.0 + i as f32 * row_h;
            let rr = Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), row_h - 2.0));
            let resp = ui.interact(rr, ui.scope_id().with(("plan-option", i)), if steer { Sense::click() } else { Sense::hover() });
            if o.chosen {
                p.rect_filled(rr, CornerRadius::same(4), alpha_of(t::deck(v.to), 0.18));
            } else if resp.hovered() && steer {
                p.rect_filled(rr, CornerRadius::same(4), white(0.05));
            }
            let sb = Rect::from_min_size(pos2(rr.left() + 4.0, rr.center().y - 2.0), vec2(36.0 * (o.score.max(0.0) / top_score) as f32, 4.0));
            p.rect_filled(sb, CornerRadius::same(2), white(0.35));
            let name = format!("{} · {}", o.kind.word(), o.bars);
            let nr = kit::text(p, pos2(rr.left() + 46.0, rr.center().y), Align2::LEFT_CENTER, &name, 11.5, if o.chosen { "semi" } else { "" }, if o.chosen { t::text() } else { t::soft() });
            kit::clipped(p, pos2(nr.right() + 10.0, rr.center().y), &o.why, 10.5, "", t::label(), rr.right() - nr.right() - 14.0);
            let resp = resp.on_hover_text(&o.why);
            if resp.clicked() && steer && !o.chosen {
                desk.steer_option(i);
            }
        }
    }
}
