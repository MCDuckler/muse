//! The Show page's Rotation (v1: show_room_rotation.dart): how often everything comes over a
//! night, where the Desk directs (the Rust stage). On the left the scenes, each a level with
//! its share of the night, and the director's temper; on the right the rows every scene
//! shares — backgrounds, masks, blends, effects — the effects' knobs, and which masks and
//! blends each background takes. A small picture of the stage stays up while it is edited.
//! Every change is kept in the Desk's show.json.
use eframe::egui::{self, Align2, Color32, CornerRadius, Painter, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::{Desk, FinishView, LEVEL_STEPS, RotationRow, RotationView, ShowEdit, ShowMix, TransformSet, TuneRow, level_word, share_word};

use crate::App;
use crate::paint::{label_sized, white};
use crate::ui::kit;
use crate::ui::tokens::{self as t, Tone};

const ROW: f32 = 30.0;
const HEAD: f32 = 34.0;

/// An effect's knob: its word, value, rest, how it is set, its tip.
type Knob = (&'static str, f64, f64, fn(&TransformSet, f64) -> TransformSet, &'static str);
/// The finish's knobs and the blend's strength.
const FINISH_H: f32 = 64.0 + 36.0;

/// A level as the slider's place: the steps evenly along it.
fn step_k(level: f64) -> f32 {
    let i = LEVEL_STEPS.iter().enumerate().min_by(|a, b| (a.1 - level).abs().total_cmp(&(b.1 - level).abs())).map_or(0, |(i, _)| i);
    i as f32 / (LEVEL_STEPS.len() - 1) as f32
}

fn level_of(k: f32) -> f64 {
    LEVEL_STEPS[(k * (LEVEL_STEPS.len() - 1) as f32).round() as usize]
}

impl App {
    pub(crate) fn rotation_room(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        if let Some(id) = self.show_scene.clone() {
            self.scene_room(desk, ui, p, r, &id);
            return;
        }
        kit::panel(p, r, false);
        let Some(rot) = desk.show_rotation() else {
            let c = r.center();
            kit::text(p, c - vec2(0.0, 12.0), Align2::CENTER_CENTER, "The rotation is the Rust stage's: the Desk directs it", t::BODY + 2.0, "", t::soft());
            kit::hint(p, c + vec2(0.0, 14.0), Align2::CENTER_CENTER, "Choose it under Screen → Stage");
            return;
        };
        if rot.working {
            ui.ctx().request_repaint_after(std::time::Duration::from_millis(40));
        }
        let inner = r.shrink(t::INSET);
        let area = Rect::from_min_max(pos2(r.left() + 2.0, inner.top() - 6.0), pos2(r.right() - 2.0, r.bottom() - 4.0));
        let two = inner.width() >= 860.0;
        let gap = 28.0;
        let col_w = if two { (inner.width() - gap) / 2.0 } else { inner.width() };
        let pic_h = (col_w * 9.0 / 16.0).min(220.0);
        let a_h = pic_h + 18.0 + HEAD + rot.scenes.len() as f32 * ROW + 20.0 + HEAD + 4.0 * 36.0 + 20.0 + HEAD + FINISH_H;
        let b_h: f32 = rot.shared.iter().map(|(_, _, _, rows)| HEAD + rows.len() as f32 * ROW + 10.0).sum::<f32>() + HEAD + 3.0 * 70.0 + 20.0 + HEAD + 24.0 + rot.takes.len() as f32 * 26.0 + 20.0;
        let h = if two { a_h.max(b_h) } else { a_h + b_h };
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(area));
        egui::ScrollArea::vertical().id_salt("rotation").auto_shrink([false, false]).show(&mut child, |ui| {
            let (all, _) = ui.allocate_exact_size(vec2(area.width() - 10.0, h + 8.0), Sense::hover());
            let p = ui.painter().clone();
            let a = Rect::from_min_size(pos2(inner.left(), all.top() + 6.0), vec2(col_w, a_h));
            let b = if two { Rect::from_min_size(pos2(inner.left() + col_w + gap, all.top() + 6.0), vec2(col_w, b_h)) } else { Rect::from_min_size(pos2(inner.left(), a.bottom()), vec2(col_w, b_h)) };
            let fin = desk.show_finish();
            self.rotation_scenes(desk, ui, &p, a, pic_h, &rot, &fin);
            self.rotation_shared(desk, ui, &p, b, &rot, &fin);
        });
    }

    /// The left: the stage small, the scenes, the director's temper.
    #[allow(clippy::too_many_arguments)]
    fn rotation_scenes(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, pic_h: f32, rot: &RotationView, fin: &FinishView) {
        // the stage, small, so what a change does shows
        let pic = Rect::from_min_size(r.min, vec2(pic_h * 16.0 / 9.0, pic_h));
        let cr = CornerRadius::same(t::R_PAD);
        p.rect_filled(pic, cr, Color32::BLACK);
        if let Some((_, tex)) = &self.stage_pic
            && desk.stage().stages > 0
        {
            p.add(egui::epaint::RectShape::filled(pic, cr, Color32::WHITE).with_texture(tex.id(), Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0))));
        } else {
            kit::hint(p, pic.center(), Align2::CENTER_CENTER, "The stage is closed");
        }
        p.rect_stroke(pic, cr, Stroke::new(1.0, white(0.08)), StrokeKind::Inside);
        if let Some(look) = desk.stage().told.look {
            kit::clipped(p, pos2(pic.right() + 14.0, pic.top() + 10.0), "On now", 11.0, "", t::faint(), r.right() - pic.right() - 14.0);
            let g = p.layout(look, egui::FontId::new(13.0, crate::paint::family("")), t::text(), (r.right() - pic.right() - 14.0).max(60.0));
            p.galley(pos2(pic.right() + 14.0, pic.top() + 22.0), g, t::text());
        }
        let mut y = pic.bottom() + 18.0;
        head(p, r, y, "Scenes", "how often each comes against the others · the music says when");
        y += HEAD;
        for (i, row) in rot.scenes.iter().enumerate() {
            let rr = Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), ROW));
            match level_row(ui, p, rr, row, ("scene", i), true) {
                Some(RowEdit::Level(v)) => desk.show_edit(ShowEdit::SceneLevel(row.key.clone(), v)),
                Some(RowEdit::On(on)) => desk.show_edit(ShowEdit::SceneOn(row.key.clone(), on)),
                Some(RowEdit::Open) => self.show_scene = Some(row.key.clone()),
                None => {}
            }
            y += ROW;
        }
        y += 20.0;
        head(p, r, y, "The director", "its temper");
        y += HEAD;
        let label_w = 130.0;
        let slider = |ui: &mut Ui, y: f32, word: &str, k: f32, left: &str, right: &str, tip: &str, rest: f32, id: &str| {
            let lr = kit::section(p, pos2(r.left(), y + 15.0), Align2::LEFT_CENTER, word);
            ui.interact(lr, ui.scope_id().with(("tip", id)), Sense::hover()).on_hover_text(tip);
            kit::hint(p, pos2(r.left() + label_w, y + 15.0), Align2::LEFT_CENTER, left);
            let sr = Rect::from_min_max(pos2(r.left() + label_w + 40.0, y + 4.0), pos2(r.right() - 56.0, y + 26.0));
            kit::text(p, pos2(r.right(), y + 15.0), Align2::RIGHT_CENTER, right, 11.0, "mono", t::muted());
            kit::hslider(ui, p, sr, k, true, rest, ("dir", id))
        };
        if let Some(k) = slider(ui, y, "Calm · busy", ((rot.bias + 1.0) / 2.0) as f32, "calm", &format!("{:+.0}", rot.bias * 100.0), "The energy it matches the scenes and looks against, moved a quarter either way. A double click: in the middle", 0.5, "bias") {
            desk.show_edit(ShowEdit::Bias(k as f64 * 2.0 - 1.0));
        }
        y += 36.0;
        if let Some(k) = slider(ui, y, "Mosh changes", rot.mosh as f32, "never", &format!("{:.0} %", rot.mosh * 100.0), "How many changes of scene are datamoshed into instead of cut or dissolved (MOSH: one now)", 0.35, "mosh") {
            desk.show_edit(ShowEdit::Mosh(k as f64));
        }
        y += 36.0;
        let lr = kit::section(p, pos2(r.left(), y + 15.0), Align2::LEFT_CENTER, "Dark beat");
        ui.interact(lr, ui.scope_id().with("tip-dark"), Sense::hover()).on_hover_text("The beat before a drop goes black");
        let seg = Rect::from_min_size(pos2(r.left() + label_w, y + 2.0), vec2(150.0, 26.0));
        if let Some(i) = kit::segmented(ui, p, seg, &["Off", "Black"], Some(rot.dark_beat as usize), Tone::Neutral, "dark-beat") {
            desk.show_edit(ShowEdit::DarkBeat(i == 1));
        }
        y += 36.0;
        let lr = kit::section(p, pos2(r.left(), y + 15.0), Align2::LEFT_CENTER, "Taught");
        ui.interact(lr, ui.scope_id().with("tip-taught"), Sense::hover()).on_hover_text("A NEXT in a look's first bars: that look a little less; a favourite with three stars or more: its kind a little more");
        let words = match rot.taught {
            0 => "NEXT has taught it nothing yet".to_owned(),
            1 => "NEXT taught it 1 look to come less".to_owned(),
            n => format!("NEXT taught it {n} looks to come less"),
        };
        kit::clipped(p, pos2(r.left() + label_w, y + 15.0), &words, 12.5, "", t::soft(), r.width() - label_w - 100.0);
        if rot.taught > 0 {
            let br = Rect::from_min_size(pos2(r.right() - 90.0, y + 2.0), vec2(90.0, 26.0));
            if kit::Btn::new("Forget it").quiet().size(11.0).show(ui, p, br, "forget-taste").on_hover_text("What NEXT taught it, forgotten").clicked() {
                desk.show_edit(ShowEdit::ForgetTaste);
            }
        }
        y += 36.0 + 20.0;
        finish(desk, ui, p, Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), HEAD + FINISH_H)), fin);
    }

    /// The right: the rows every scene shares, the effects' knobs, what each background takes.
    fn rotation_shared(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, rot: &RotationView, fin: &FinishView) {
        let mut y = r.top();
        for (axis, title, hint, rows) in &rot.shared {
            head(p, r, y, title, hint);
            y += HEAD;
            for (i, row) in rows.iter().enumerate() {
                let rr = Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), ROW));
                match level_row(ui, p, rr, row, (axis.as_str(), i), false) {
                    Some(RowEdit::Level(v)) => desk.show_edit(ShowEdit::SharedLevel(axis.clone(), row.key.clone(), v)),
                    Some(RowEdit::On(on)) => desk.show_edit(ShowEdit::SharedOn(axis.clone(), row.key.clone(), on)),
                    _ => {}
                }
                y += ROW;
            }
            y += 10.0;
        }

        // the effects' knobs
        head(p, r, y, "Their knobs", "the kaleidoscope's mirrors, the datamosh's grain · a double click: as shipped");
        y += HEAD;
        let tr = &rot.transform;
        let shipped = TransformSet::default();
        let mut next: Option<TransformSet> = None;
        let label_w = 116.0;
        kit::section(p, pos2(r.left(), y + 20.0), Align2::LEFT_CENTER, "Kaleidoscope");
        let seg = Rect::from_min_size(pos2(r.left() + label_w, y + 7.0), vec2(150.0, 26.0));
        let counts = ["1", "2", "3", "4", "5", "6"];
        if let Some(i) = kit::segmented(ui, p, seg, &counts, Some((tr.count.clamp(1, 6) - 1) as usize), Tone::Neutral, "mirrors") {
            next = Some(TransformSet { count: i as i64 + 1, ..*tr });
        }
        kit::hint(p, pos2(seg.center().x, seg.bottom() + 12.0), Align2::CENTER_CENTER, "mirrors");
        let knobs: [Knob; 4] = [
            ("Turn", tr.turn, shipped.turn, |t, v| TransformSet { turn: v, ..*t }, "The mirrors turned"),
            ("Line", tr.line, shipped.line, |t, v| TransformSet { line: v, ..*t }, "How much of the mirrors' edges shows"),
            ("Differs", tr.differ, shipped.differ, |t, v| TransformSet { differ: v, ..*t }, "How far the reflections' light and colour are from the original's"),
            ("Amount", tr.amount, shipped.amount, |t, v| TransformSet { amount: v, ..*t }, "How much of the reflections"),
        ];
        let kx = seg.right() + 34.0;
        for (i, (word, v, rest, set, tip)) in knobs.into_iter().enumerate() {
            let c = pos2(kx + i as f32 * 58.0, y + 20.0);
            if c.x + 24.0 > r.right() {
                break;
            }
            if let Some(nv) = kit::knob(ui, p, c, v as f32, t::text(), false, rest as f32, ("kal", i)) {
                next = Some(set(tr, nv as f64));
            }
            ui.interact(Rect::from_center_size(c, vec2(40.0, 40.0)), ui.scope_id().with(("kal-tip", i)), Sense::hover()).on_hover_text(format!("{tip}: {:.0} %", v * 100.0));
            label_sized(p, pos2(c.x, c.y + 29.0), Align2::CENTER_CENTER, word, 10.0, t::muted());
        }
        y += 52.0;
        let blends = [("Normal", ShowMix::Normal), ("Add", ShowMix::Add), ("Screen", ShowMix::Screen), ("Contrast", ShowMix::Contrast)];
        kit::hint(p, pos2(r.left() + 12.0, y + 13.0), Align2::LEFT_CENTER, "its blend");
        let seg = Rect::from_min_size(pos2(r.left() + label_w, y), vec2((r.width() - label_w).min(320.0), 26.0));
        let words: Vec<&str> = blends.iter().map(|(w, _)| *w).collect();
        if let Some(i) = kit::segmented(ui, p, seg, &words, blends.iter().position(|(_, m)| *m == tr.blend), Tone::Neutral, "kal-blend") {
            next = Some(TransformSet { blend: blends[i].1, ..*tr });
        }
        y += 40.0;
        kit::section(p, pos2(r.left(), y + 20.0), Align2::LEFT_CENTER, "Datamosh");
        let knobs: [Knob; 3] = [
            ("Grain", tr.grain, shipped.grain, |t, v| TransformSet { grain: v, ..*t }, "How blocky: a smooth melt … a codec's grain, its blocks and colour bleed"),
            ("Melt", tr.melt, shipped.melt, |t, v| TransformSet { melt: v, ..*t }, "How long its smears hold before the picture comes through"),
            ("Keys", tr.keys, shipped.keys, |t, v| TransformSet { keys: v, ..*t }, "How often the picture is let through: patches on the bars, whole on a key frame"),
        ];
        for (i, (word, v, rest, set, tip)) in knobs.into_iter().enumerate() {
            let c = pos2(r.left() + label_w + 20.0 + i as f32 * 58.0, y + 20.0);
            if let Some(nv) = kit::knob(ui, p, c, v as f32, t::text(), false, rest as f32, ("mosh", i)) {
                next = Some(set(tr, nv as f64));
            }
            ui.interact(Rect::from_center_size(c, vec2(40.0, 40.0)), ui.scope_id().with(("mosh-tip", i)), Sense::hover()).on_hover_text(format!("{tip}: {:.0} %", v * 100.0));
            label_sized(p, pos2(c.x, c.y + 29.0), Align2::CENTER_CENTER, word, 10.0, t::muted());
        }
        if let Some(t) = next {
            desk.show_edit(ShowEdit::Transform(t));
        }
        y += 70.0;
        kit::section(p, pos2(r.left(), y + 20.0), Align2::LEFT_CENTER, "Slit-scan");
        tune_knobs(desk, ui, p, pos2(r.left() + label_w + 20.0, y + 20.0), &fin.slit, "slit");
        y += 70.0;

        // what each background takes
        head(p, r, y, "What each background takes", "a NEVER: that background never with that mask or blend");
        y += HEAD;
        let name_w = 110.0;
        let cw = ((r.width() - name_w) / rot.takes_cols.len() as f32).min(80.0);
        for (i, c) in rot.takes_cols.iter().enumerate() {
            label_sized(p, pos2(r.left() + name_w + (i as f32 + 0.5) * cw, y + 10.0), Align2::CENTER_CENTER, c, 9.5, t::muted());
        }
        y += 24.0;
        for (key, name, yes) in &rot.takes {
            kit::clipped(p, pos2(r.left(), y + 11.0), name, 12.0, "", t::soft(), name_w - 8.0);
            for (i, on) in yes.iter().enumerate() {
                let cr = Rect::from_center_size(pos2(r.left() + name_w + (i as f32 + 0.5) * cw, y + 11.0), vec2(cw - 8.0, 20.0));
                let (word, tone) = if *on { ("Yes", Tone::Neutral) } else { ("Never", Tone::Danger) };
                if kit::chip(ui, p, cr, word, !*on, tone, true, ("takes", key, i)).on_hover_text(format!("{name} with {}: {}", rot.takes_cols[i], if *on { "it may — click: never" } else { "never — click: it may" })).clicked() {
                    desk.show_edit(ShowEdit::Takes(key.clone(), rot.takes_cols[i].clone(), !on));
                }
            }
            y += 26.0;
        }
    }
}

/// The finish over every scene (v1: SETTINGS' THE FINISH): trails, bloom, the film curve,
/// grain, the corners — a knob turned makes it the hands' over every scene; and how strong the
/// blend of every scene with its background is.
fn finish(desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, fin: &FinishView) {
    head(p, r, r.top(), "The finish", if fin.mine { "yours over every scene · kept, and in a set" } else { "the scene on's own · a knob turned: yours over every scene" });
    if fin.mine {
        let br = Rect::from_min_size(pos2(r.right() - 130.0, r.top() + 1.0), vec2(130.0, 24.0));
        if kit::Btn::new("Each scene's own").quiet().size(10.5).show(ui, p, br, "finish-own").on_hover_text("Each scene with the finish it was made with").clicked() {
            desk.show_edit(ShowEdit::Finish(None));
        }
    }
    let f = fin.finish.clone().unwrap_or_default();
    let shipped = wo_deskcore::RigFinish::default();
    type Set = fn(&wo_deskcore::RigFinish, f64) -> wo_deskcore::RigFinish;
    let knobs: [(&str, f64, f64, f64, Set, &str); 5] = [
        ("Trails", f.trails, shipped.trails, 0.9, |f, v| wo_deskcore::RigFinish { trails: v, ..f.clone() }, "How much of the last frame lingers"),
        ("Bloom", f.bloom, shipped.bloom, 1.5, |f, v| wo_deskcore::RigFinish { bloom: v, ..f.clone() }, "The glow round bright things"),
        ("Tone", f.tone, shipped.tone, 1.0, |f, v| wo_deskcore::RigFinish { tone: v, ..f.clone() }, "The film curve (none: the picture as drawn)"),
        ("Grain", f.grain, shipped.grain, 1.0, |f, v| wo_deskcore::RigFinish { grain: v, ..f.clone() }, "Film grain"),
        ("Vignette", f.vignette, shipped.vignette, 1.0, |f, v| wo_deskcore::RigFinish { vignette: v, ..f.clone() }, "The corners darkened"),
    ];
    let y = r.top() + HEAD;
    for (i, (word, v, rest, max, set, tip)) in knobs.into_iter().enumerate() {
        let c = pos2(r.left() + 22.0 + i as f32 * 62.0, y + 20.0);
        let color = if fin.mine { t::text() } else { t::muted() };
        if let Some(k) = kit::knob(ui, p, c, (v / max) as f32, color, false, (rest / max) as f32, ("finish", i)) {
            desk.show_edit(ShowEdit::Finish(Some(set(&f, k as f64 * max))));
        }
        ui.interact(Rect::from_center_size(c, vec2(40.0, 40.0)), ui.scope_id().with(("finish-tip", i)), Sense::hover()).on_hover_text(format!("{tip}: {:.0} %", v / max * 100.0));
        label_sized(p, pos2(c.x, c.y + 29.0), Align2::CENTER_CENTER, word, 10.0, t::muted());
    }
    let y = y + 64.0;
    let lr = kit::section(p, pos2(r.left(), y + 15.0), Align2::LEFT_CENTER, "Blend");
    ui.interact(lr, ui.scope_id().with("tip-strength"), Sense::hover()).on_hover_text("How strong every scene's blend with its background is: none, the scene as drawn");
    let sr = Rect::from_min_max(pos2(r.left() + 170.0, y + 4.0), pos2(r.right() - 56.0, y + 26.0));
    kit::hint(p, pos2(r.left() + 130.0, y + 15.0), Align2::LEFT_CENTER, "none");
    kit::text(p, pos2(r.right(), y + 15.0), Align2::RIGHT_CENTER, &format!("{:.0} %", fin.strength * 100.0), 11.0, "mono", t::muted());
    if let Some(k) = kit::hslider(ui, p, sr, fin.strength as f32, true, 1.0, "strength") {
        desk.show_edit(ShowEdit::Strength(k as f64));
    }
}

/// A treatment's knobs in a row from `at` (the first's centre), each to its range; a double
/// click: its rest.
pub(crate) fn tune_knobs(desk: &mut Desk, ui: &mut Ui, p: &Painter, at: egui::Pos2, knobs: &[TuneRow], id: &str) {
    for (i, k) in knobs.iter().enumerate() {
        let c = pos2(at.x + i as f32 * 58.0, at.y);
        let span = (k.max - k.min).max(1e-6);
        let of = |v: f64| ((v - k.min) / span).clamp(0.0, 1.0) as f32;
        if let Some(nv) = kit::knob(ui, p, c, of(k.value), t::text(), false, of(k.rest), (id, i)) {
            let v = k.min + nv as f64 * span;
            desk.show_edit(ShowEdit::Tune(k.key.clone(), if (v - k.rest).abs() < 1e-6 { None } else { Some(v) }));
        }
        ui.interact(Rect::from_center_size(c, vec2(40.0, 40.0)), ui.scope_id().with((id, "tip", i)), Sense::hover()).on_hover_text(format!("{}: ×{:.2}", k.tip, k.value));
        label_sized(p, pos2(c.x, c.y + 29.0), Align2::CENTER_CENTER, &k.label, 10.0, t::muted());
    }
}

/// A section's head: its title, its hint after it, a line under.
pub(crate) fn head(p: &Painter, r: Rect, y: f32, title: &str, hint: &str) {
    let tr = kit::section(p, pos2(r.left(), y + 14.0), Align2::LEFT_CENTER, title);
    kit::clipped(p, pos2(tr.right() + 12.0, y + 14.0), hint, 11.5, "", t::faint(), r.right() - tr.right() - 12.0);
    p.line_segment([pos2(r.left(), y + 28.0), pos2(r.right(), y + 28.0)], Stroke::new(1.0, white(0.06)));
}

pub(crate) enum RowEdit {
    Level(f64),
    On(bool),
    /// Its name clicked: its page.
    Open,
}

/// A row of the rotation: on now, its name, on or off, its level, the level in words, its
/// share of the night (or why it cannot come).
/// `open`: its name opens its page.
pub(crate) fn level_row(ui: &mut Ui, p: &Painter, r: Rect, row: &RotationRow, id: impl std::hash::Hash + std::fmt::Debug + Copy, open: bool) -> Option<RowEdit> {
    let mut out = None;
    let can = row.note.is_none();
    if row.live {
        p.rect_filled(r.shrink2(vec2(0.0, 1.0)), CornerRadius::same(t::R_CONTROL), white(0.045));
        kit::on_air(p, pos2(r.left() + 8.0, r.center().y), 11.0);
    }
    let ink = if !row.on || !can { t::faint() } else if row.live { t::high() } else { t::text() };
    let name_w = (r.width() * 0.3).clamp(110.0, 170.0);
    let nr = kit::clipped(p, pos2(r.left() + 18.0, r.center().y), &row.name, 13.0, "", ink, name_w - 38.0);
    if open {
        let resp = ui.interact(nr.expand2(vec2(6.0, 6.0)).union(Rect::from_min_size(nr.right_top(), vec2(16.0, nr.height()))), ui.scope_id().with(("open", id)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
        kit::text(p, pos2(nr.right() + 5.0, r.center().y), Align2::LEFT_CENTER, "›", 14.0, "", if resp.hovered() { t::high() } else { t::faint() });
        let resp = resp.on_hover_text(row.note.clone().map_or_else(|| "Its page: its styles, its looks one by one, its camera".to_owned(), |n| format!("{n} — its page: its styles, its looks one by one")));
        if resp.clicked() {
            out = Some(RowEdit::Open);
        }
    } else if let Some(n) = &row.note {
        ui.interact(nr, ui.scope_id().with(("note", id)), Sense::hover()).on_hover_text(n.as_str());
    }
    let chip = Rect::from_min_size(pos2(r.left() + name_w, r.center().y - 10.0), vec2(42.0, 20.0));
    let tip = if row.on { "On — click: never" } else { "Off — click: back on" };
    if kit::chip(ui, p, chip, if row.on { "On" } else { "Off" }, row.on, Tone::Neutral, true, ("on", id)).on_hover_text(tip).clicked() {
        out = Some(RowEdit::On(!row.on));
    }
    let share_w = 64.0;
    let word_w = 44.0;
    let sr = Rect::from_min_max(pos2(chip.right() + 10.0, r.top() + 4.0), pos2(r.right() - share_w - word_w - 8.0, r.bottom() - 4.0));
    if let Some(k) = kit::hslider(ui, p, sr, step_k(row.level), row.on && can, step_k(1.0), ("lvl", id)) {
        let v = level_of(k);
        if (v - row.level).abs() > 1e-9 {
            out = Some(RowEdit::Level(v));
        }
    }
    kit::text(p, pos2(sr.right() + 6.0, r.center().y), Align2::LEFT_CENTER, &level_word(row.level), 11.0, "mono", if row.on { t::muted() } else { t::faint() });
    let (share, sink) = match &row.note {
        Some(_) => ("can't".to_owned(), t::faint()),
        None if !row.on => ("—".to_owned(), t::faint()),
        None => (share_word(row.share), if row.live { t::text() } else { t::soft() }),
    };
    let s = kit::text(p, pos2(r.right(), r.center().y), Align2::RIGHT_CENTER, &share, 11.5, "mono", sink);
    ui.interact(s.expand(4.0), ui.scope_id().with(("share", id)), Sense::hover()).on_hover_text(row.note.clone().unwrap_or_else(|| "Of the night, about (by the plan alone: the music leans every pick)".into()));
    out
}
