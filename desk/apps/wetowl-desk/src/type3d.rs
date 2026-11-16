//! The 3D text's own part of its scene page (v1: show_room_type3d.dart, the TEXT tab): what it
//! says, line by line; when the next line comes and how it turns into it; the face; the
//! motions, looks and bends a phrase picks from; the colours; the knobs. Each change is kept
//! in this Desk's show at once (ShowEdit::Type3d) and on the stage while the text is on.
use eframe::egui::{self, Align2, Color32, CornerRadius, FontId, Painter, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::type3d::{TypeChange, TypeColour, TypeDeform, TypeFont, TypeLook, TypeMotion, TypeSpec, TypeTurn};
use wo_deskcore::{Desk, ShowEdit};

use crate::App;
use crate::rotation::head;
use crate::ui::kit;
use crate::ui::tokens::{self as t, Tone};

const HEAD: f32 = 34.0;
const LABEL_W: f32 = 74.0;
const CHIP_H: f32 = 24.0;

/// Chips in rows from `at`, wrapping at `right`: each word, whether on; the one clicked, and
/// the height taken.
fn chips(ui: &mut Ui, p: &Painter, at: egui::Pos2, right: f32, words: &[(&str, bool)], id: &str) -> (Option<usize>, f32) {
    let (mut x, mut y) = (at.x, at.y);
    let mut hit = None;
    for (i, (w, on)) in words.iter().enumerate() {
        let cw = kit::chip_width(p, w);
        if x + cw > right && x > at.x {
            x = at.x;
            y += CHIP_H + 6.0;
        }
        if kit::chip(ui, p, Rect::from_min_size(pos2(x, y), vec2(cw, CHIP_H)), w, *on, Tone::Neutral, true, (id, i)).clicked() {
            hit = Some(i);
        }
        x += cw + 6.0;
    }
    (hit, y + CHIP_H - at.y)
}

/// `all` in their order with `x` in `set` switched; never the last one of a set that may not
/// be empty.
fn toggled<T: Copy + PartialEq>(all: &[T], set: &[T], x: T, may_empty: bool) -> Option<Vec<T>> {
    let on = set.contains(&x);
    if on && set.len() == 1 && !may_empty {
        return None;
    }
    Some(all.iter().copied().filter(|a| if *a == x { !on } else { set.contains(a) }).collect())
}

fn title(s: &str) -> String {
    let mut c = s.chars();
    c.next().map_or(String::new(), |f| f.to_uppercase().chain(c).collect())
}

impl App {
    /// The 3D text's part of the page from `r`'s top, `r` wide; its height.
    pub(crate) fn type3d_editor(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) -> f32 {
        let spec = desk.show_type3d();
        let mut next: Option<TypeSpec> = None;
        let mut y = r.top();
        let two = r.width() >= 900.0;
        let gap = 28.0;
        let col_w = if two { (r.width() - gap) / 2.0 } else { r.width() };

        // ---- the words, and when and how they change
        head(p, r, y, "The words", "a line at a time, the next on the change · {title} and {artist}: the record's own");
        y += HEAD;
        let box_h = 112.0;
        let br = Rect::from_min_size(pos2(r.left(), y), vec2(col_w, box_h));
        let id = ui.scope_id().with("type3d-lines");
        let focused = ui.memory(|m| m.has_focus(id));
        let joined = spec.lines.join("\n");
        let buf = &mut self.scene_ui.type_lines;
        if !focused && *buf != joined {
            *buf = joined;
        }
        p.rect(br, CornerRadius::same(t::R_CONTROL + 1), Color32::from_white_alpha(if focused { 14 } else { 8 }), Stroke::new(1.0, t::edge_rest()), StrokeKind::Inside);
        let edit = egui::TextEdit::multiline(buf)
            .id(id)
            .hint_text(egui::RichText::new("WETOWL\n{title}\n{artist}").color(t::faint()))
            .frame(egui::Frame::NONE)
            .font(FontId::monospace(t::BODY))
            .text_color(t::text())
            .desired_width(col_w - 20.0);
        if ui.put(br.shrink2(vec2(10.0, 8.0)), edit).changed() {
            let lines: Vec<String> = self.scene_ui.type_lines.lines().map(str::to_owned).collect();
            next = Some(TypeSpec { lines, ..spec.clone() });
        }
        // beside (or under) the words: the change, the turn, the colours
        let (sx, mut sy) = if two { (r.left() + col_w + gap, y) } else { (r.left(), y + box_h + 12.0) };
        let seg = |ui: &mut Ui, sy: &mut f32, word: &str, tip: &str, items: &[&str], chosen: usize, id: &str| -> Option<usize> {
            let lr = kit::section(p, pos2(sx, *sy + 13.0), Align2::LEFT_CENTER, word);
            ui.interact(lr, ui.scope_id().with((id, "tip")), Sense::hover()).on_hover_text(tip);
            let at = Rect::from_min_size(pos2(sx + LABEL_W, *sy), vec2((col_w - LABEL_W).min(items.len() as f32 * 70.0), 26.0));
            *sy += 34.0;
            kit::segmented(ui, p, at, items, Some(chosen), Tone::Neutral, id)
        };
        let changes = ["Beat", "Bar", "2 bars", "Phrase", "8 bars", "Never"];
        if let Some(i) = seg(ui, &mut sy, "Next line", "When the next line comes: every beat, bar, two bars, phrase (four bars), eight bars; Never holds the first", &changes, spec.change.index(), "t3-change") {
            next = Some(TypeSpec { change: TypeChange::ALL[i], ..next.unwrap_or_else(|| spec.clone()) });
        }
        let turns = ["Morph", "Flip", "Glitch"];
        if let Some(i) = seg(ui, &mut sy, "Turn", "How one line becomes the next: its letters flowing into the next, turned over edge-on, or cut over in torn bands", &turns, spec.turn.index(), "t3-turn") {
            next = Some(TypeSpec { turn: TypeTurn::ALL[i], ..next.unwrap_or_else(|| spec.clone()) });
        }
        let colours: Vec<String> = TypeColour::ALL.iter().map(|c| title(c.name())).collect();
        let colours: Vec<&str> = colours.iter().map(String::as_str).collect();
        if let Some(i) = seg(ui, &mut sy, "Colours", "The record's palette, or a fixed set: face, sides and rim", &colours, spec.colour.index(), "t3-colour") {
            next = Some(TypeSpec { colour: TypeColour::ALL[i], ..next.unwrap_or_else(|| spec.clone()) });
        }
        y = if two { (y + box_h).max(sy) } else { sy } + 10.0;

        // ---- the face
        head(p, r, y, "The face", "the letters' typeface");
        y += HEAD;
        let words: Vec<(&str, bool)> = TypeFont::ALL.iter().map(|f| (f.label(), *f == spec.font)).collect();
        let (hit, h) = chips(ui, p, pos2(r.left(), y), r.right(), &words, "t3-font");
        if let Some(i) = hit {
            next = Some(TypeSpec { font: TypeFont::ALL[i], ..next.unwrap_or_else(|| spec.clone()) });
        }
        y += h + 16.0;

        // ---- what a phrase picks from
        head(p, r, y, "Each phrase picks", "a motion and a look of those on, and two bends (shatter on the drop whenever it is on)");
        y += HEAD;
        let lr = kit::section(p, pos2(r.left(), y + CHIP_H / 2.0), Align2::LEFT_CENTER, "Motions");
        ui.interact(lr, ui.scope_id().with("t3-motions-tip"), Sense::hover()).on_hover_text("How the letters move; the calm ones in a quiet part, the ones that move a lot the harder the music");
        let words: Vec<(&str, bool)> = TypeMotion::ALL.iter().map(|m| (m.name(), spec.motions.contains(m))).collect();
        let (hit, h) = chips(ui, p, pos2(r.left() + LABEL_W, y), r.right(), &words, "t3-motion");
        if let Some(i) = hit {
            let base = next.clone().unwrap_or_else(|| spec.clone());
            if let Some(m) = toggled(TypeMotion::ALL, &base.motions, TypeMotion::ALL[i], false) {
                next = Some(TypeSpec { motions: m, ..base });
            }
        }
        y += h + 8.0;
        let lr = kit::section(p, pos2(r.left(), y + CHIP_H / 2.0), Align2::LEFT_CENTER, "Looks");
        ui.interact(lr, ui.scope_id().with("t3-looks-tip"), Sense::hover()).on_hover_text("What the letters are made of (glass bends the background behind it)");
        let words: Vec<(&str, bool)> = TypeLook::ALL.iter().map(|l| (l.name(), spec.looks.contains(l))).collect();
        let (hit, h) = chips(ui, p, pos2(r.left() + LABEL_W, y), r.right(), &words, "t3-look");
        if let Some(i) = hit {
            let base = next.clone().unwrap_or_else(|| spec.clone());
            if let Some(l) = toggled(TypeLook::ALL, &base.looks, TypeLook::ALL[i], false) {
                next = Some(TypeSpec { looks: l, ..base });
            }
        }
        y += h + 8.0;
        let lr = kit::section(p, pos2(r.left(), y + CHIP_H / 2.0), Align2::LEFT_CENTER, "Bends");
        ui.interact(lr, ui.scope_id().with("t3-bends-tip"), Sense::hover()).on_hover_text(
            "How the music bends them: inflate (kick), ripple (bass), melt (quiet), slice (snare), shatter (drop), wobble (hats), squash (kick), arc (bar), stack, repeat. None on: the letters as cut",
        );
        let words: Vec<(&str, bool)> = TypeDeform::ALL.iter().map(|d| (d.name(), spec.deforms.contains(d))).collect();
        let (hit, h) = chips(ui, p, pos2(r.left() + LABEL_W, y), r.right(), &words, "t3-bend");
        if let Some(i) = hit {
            let base = next.clone().unwrap_or_else(|| spec.clone());
            if let Some(d) = toggled(TypeDeform::ALL, &base.deforms, TypeDeform::ALL[i], true) {
                next = Some(TypeSpec { deforms: d, ..base });
            }
        }
        y += h + 16.0;

        // ---- the knobs, 0..3 (1 as drawn)
        head(p, r, y, "Knobs", "1 is as drawn · drag; a double click for 1");
        y += HEAD;
        let knobs: [(&str, f64, &str); 7] = [
            ("Size", spec.size, "How big the letters are"),
            ("Depth", spec.depth, "How deep they are extruded (the bass breathes it)"),
            ("Bevel", spec.bevel, "How rounded their edges"),
            ("Speed", spec.speed, "How fast the motions run (the ones on the beat stay on it)"),
            ("Beat", spec.beat, "How hard the kick and the snare push them"),
            ("Glow", spec.glow, "How much they glow"),
            ("Bend", spec.bend, "How far the music bends them"),
        ];
        let kw = (r.width().min(620.0) / knobs.len() as f32).max(64.0);
        let (lo, hi) = wo_deskcore::type3d::KNOB_RANGE;
        for (i, (word, v, tip)) in knobs.iter().enumerate() {
            let c = pos2(r.left() + kw * (i as f32 + 0.5), y + 24.0);
            let k = ((v - lo) / (hi - lo)) as f32;
            let rest = ((1.0 - lo) / (hi - lo)) as f32;
            let picked = kit::knob(ui, p, c, k, t::text(), false, rest, ("t3-knob", i));
            ui.interact(Rect::from_center_size(c, vec2(44.0, 44.0)), ui.scope_id().with(("t3-knob-tip", i)), Sense::hover()).on_hover_text(*tip);
            kit::section(p, pos2(c.x, c.y + 30.0), Align2::CENTER_CENTER, word);
            kit::text(p, pos2(c.x, c.y + 46.0), Align2::CENTER_CENTER, &format!("{v:.2}×"), 11.0, "mono", t::muted());
            if let Some(nk) = picked
                && (nk - k).abs() > 1e-4
            {
                let nv = (lo + nk as f64 * (hi - lo)).clamp(lo, hi);
                let mut s = next.clone().unwrap_or_else(|| spec.clone());
                match i {
                    0 => s.size = nv,
                    1 => s.depth = nv,
                    2 => s.bevel = nv,
                    3 => s.speed = nv,
                    4 => s.beat = nv,
                    5 => s.glow = nv,
                    _ => s.bend = nv,
                }
                next = Some(s);
            }
        }
        y += 70.0;
        if spec != TypeSpec::default() {
            let br = Rect::from_min_size(pos2(r.left(), y), vec2(140.0, 26.0));
            if kit::Btn::new("As shipped").quiet().size(11.0).show(ui, p, br, "t3-reset").on_hover_text("Every word, face, motion, look, bend and knob back as shipped").clicked() {
                self.scene_ui.type_lines.clear();
                next = Some(TypeSpec::default());
            }
            y += 34.0;
        }
        if let Some(s) = next
            && s != spec
        {
            desk.show_edit(ShowEdit::Type3d(s));
        }
        y - r.top()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_set_keeps_one_unless_it_may_be_empty() {
        let all = TypeLook::ALL;
        assert_eq!(toggled(all, &[TypeLook::Neon], TypeLook::Neon, false), None);
        assert_eq!(toggled(all, &[TypeLook::Neon], TypeLook::Chrome, false), Some(vec![TypeLook::Chrome, TypeLook::Neon]));
        assert_eq!(toggled(TypeDeform::ALL, &[TypeDeform::Arc], TypeDeform::Arc, true), Some(vec![]));
    }
}
