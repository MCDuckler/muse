//! rekordbox's effect panel: FX1 and FX2 (each its effect, ON, its beats, LEVEL/DEPTH, AUTO
//! or TAP, the channel it is on), the RELEASE FX (held), the SOUND COLOR FX the channel
//! knobs turn and its PARAMETER. In rekordbox's layout under the decks (the bar's FX), in
//! the WetOwl's over the booth (E).
use eframe::egui::{self, Align2, Color32, CornerRadius, Painter, Rect, Ui, pos2, vec2};
use wo_deskcore::Desk;
use wo_deskcore::beat_fx::{BeatFxKind, ColorFxKind, ReleaseFxKind, Target};

use crate::App;
use crate::club::{self, CUE, LINE, LIT, MUTED, TEXT, button, knob, words};
use crate::ui::fit;
use crate::ui::kit;

/// A beat as rekordbox's buttons write it: 1/16 … 64.
pub(crate) fn beat_words(b: f64) -> String {
    if b >= 1.0 {
        format!("{b}")
    } else if (b - 0.75).abs() < 1e-9 {
        "3/4".to_owned()
    } else {
        format!("1/{}", (1.0 / b).round())
    }
}

impl App {
    /// The panel across `r` (about 64 high).
    pub(crate) fn fx_panel(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        club::panel(p, r);
        let inner = r.shrink2(vec2(8.0, 6.0));
        let w = inner.width();
        let g = 10.0;
        let unit_w = ((w - 3.0 * g) * 0.31).max(300.0);
        let release_w = ((w - 3.0 * g) * 0.16).max(190.0);
        let color_w = (w - 3.0 * g - 2.0 * unit_w - release_w).max(200.0);
        let mut x = inner.left();
        for u in 0..2 {
            let ur = Rect::from_min_size(pos2(x, inner.top()), vec2(unit_w, inner.height()));
            self.fx_unit(desk, ui, p, ur, u);
            x = ur.right() + g;
            p.line_segment([pos2(x - g / 2.0, inner.top() + 2.0), pos2(x - g / 2.0, inner.bottom() - 2.0)], egui::Stroke::new(1.0, LINE));
        }
        let rr = Rect::from_min_size(pos2(x, inner.top()), vec2(release_w, inner.height()));
        self.fx_release(desk, ui, p, rr);
        x = rr.right() + g;
        p.line_segment([pos2(x - g / 2.0, inner.top() + 2.0), pos2(x - g / 2.0, inner.bottom() - 2.0)], egui::Stroke::new(1.0, LINE));
        let cr = Rect::from_min_size(pos2(x, inner.top()), vec2(color_w.min(inner.right() - x), inner.height()));
        self.fx_color(desk, ui, p, cr);
    }

    /// One unit: [FX1] [ON] ◀ ECHO ▶ … [1][2][M]; ◀ 1 ▶ [AUTO|TAP] LEVEL/DEPTH ——.
    fn fx_unit(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, u: usize) {
        let f = desk.fx_units()[u].clone();
        let h = 22.0;
        let row1 = Rect::from_min_size(r.min, vec2(r.width(), h));
        let row2 = Rect::from_min_size(pos2(r.left(), r.bottom() - h), vec2(r.width(), h));
        words(p, pos2(row1.left(), row1.center().y), Align2::LEFT_CENTER, ["FX1", "FX2"][u], 11.0, "semi", MUTED);
        let on = Rect::from_min_size(pos2(row1.left() + 30.0, row1.top()), vec2(40.0, h));
        if button(ui, p, on, "ON", f.on, LIT, ("fx-on", u)).on_hover_text("The effect on and off (its echoes ring out)").clicked() {
            desk.toggle_fx(u);
        }
        // the effect: ◀ NAME ▶ (the name: the next; right-click: all of them)
        let less = Rect::from_min_size(pos2(on.right() + 8.0, row1.top()), vec2(20.0, h));
        let name_r = Rect::from_min_size(pos2(less.right() + 2.0, row1.top()), vec2(108.0, h));
        let more = Rect::from_min_size(pos2(name_r.right() + 2.0, row1.top()), vec2(20.0, h));
        if button(ui, p, less, "‹", false, LIT, ("fx-prev", u)).clicked() {
            desk.select_fx(u, -1);
        }
        let name = button(ui, p, name_r, f.kind.name(), false, LIT, ("fx-name", u)).on_hover_text("The next effect · right-click: every one");
        if name.clicked() {
            desk.select_fx(u, 1);
        }
        name.context_menu(|ui| {
            for k in BeatFxKind::ALL {
                if ui.selectable_label(k == f.kind, k.name()).clicked() {
                    desk.set_fx_kind(u, k);
                    ui.close();
                }
            }
        });
        if button(ui, p, more, "›", false, LIT, ("fx-next", u)).clicked() {
            desk.select_fx(u, 1);
        }
        // where: 1, 2, the master
        for (i, (word, t)) in [("1", Target::Deck(0)), ("2", Target::Deck(1)), ("M", Target::Master)].into_iter().enumerate() {
            let br = Rect::from_min_size(pos2(row1.right() - (3 - i) as f32 * 26.0, row1.top()), vec2(24.0, h));
            if button(ui, p, br, word, f.target == t, LIT, ("fx-to", u, i)).on_hover_text(match t {
                Target::Deck(d) => format!("On deck {}", d + 1),
                Target::Master => "On the master".to_owned(),
            }).clicked() {
                desk.set_fx_target(u, t);
            }
        }
        // its beats (or, for those without, the reverb's size)
        let mut x = row2.left();
        if f.kind.beats().is_empty() {
            if f.kind == BeatFxKind::Reverb {
                words(p, pos2(x, row2.center().y), Align2::LEFT_CENTER, "SIZE", 9.5, "semi", MUTED);
                let sr = Rect::from_min_size(pos2(x + 32.0, row2.top()), vec2(66.0, h));
                if let Some(v) = kit::hslider(ui, p, sr, f.param, false, 0.5, ("fx-size", u)) {
                    desk.set_fx_param(u, v);
                }
            } else {
                words(p, pos2(x, row2.center().y), Align2::LEFT_CENTER, "LEVEL/DEPTH: THE PITCH", 9.0, "semi", MUTED);
            }
            x += 104.0;
        } else {
            let less = Rect::from_min_size(pos2(x, row2.top()), vec2(20.0, h));
            let val = Rect::from_min_size(pos2(less.right() + 2.0, row2.top()), vec2(44.0, h));
            let more = Rect::from_min_size(pos2(val.right() + 2.0, row2.top()), vec2(20.0, h));
            if button(ui, p, less, "‹", false, LIT, ("fx-b-less", u)).on_hover_text("Fewer beats").clicked() {
                desk.step_fx_beats(u, -1);
            }
            p.rect_filled(val, CornerRadius::same(2), Color32::from_rgb(0x0A, 0x0A, 0x0B));
            words(p, val.center(), Align2::CENTER_CENTER, &beat_words(f.beats), 12.0, "mono-semi", CUE);
            if button(ui, p, more, "›", false, LIT, ("fx-b-more", u)).on_hover_text("More beats").clicked() {
                desk.step_fx_beats(u, 1);
            }
            x = more.right() + 8.0;
        }
        // AUTO (the deck's tempo) or TAP
        let tap_r = Rect::from_min_size(pos2(x, row2.top()), vec2(44.0, h));
        let tapped = f.bpm.is_some();
        let tap_word = match f.bpm {
            Some(b) => format!("{b:.0}"),
            None => "TAP".to_owned(),
        };
        let tap = button(ui, p, tap_r, &tap_word, tapped, CUE, ("fx-tap", u)).on_hover_text(if tapped { "Tapped: tap again, or right-click for AUTO (the deck's tempo)" } else { "AUTO: the deck's tempo · tap in time to set one" });
        if tap.clicked() {
            desk.tap_fx(u);
        }
        if tap.secondary_clicked() {
            desk.auto_fx_tempo(u);
        }
        // LEVEL/DEPTH
        let lx = tap_r.right() + 10.0;
        let lr = Rect::from_min_max(pos2(lx + 34.0, row2.top()), pos2(row2.right() - 34.0, row2.bottom()));
        words(p, pos2(lx, row2.center().y), Align2::LEFT_CENTER, "LEVEL", 9.0, "semi", MUTED);
        if lr.width() > 30.0
            && let Some(v) = kit::hslider(ui, p, lr, f.level, f.on, 0.5, ("fx-level", u))
        {
            desk.set_fx_level(u, v);
        }
        words(p, pos2(row2.right(), row2.center().y), Align2::RIGHT_CENTER, &format!("{:.0}%", f.level * 100.0), 10.5, "mono", TEXT);
        fit::inside("fx unit", Rect::from_min_max(r.min, pos2(lr.right(), r.bottom())), r);
    }

    /// The RELEASE FX (FX1's): ◀ ECHO ▶, its beats, and RELEASE held.
    fn fx_release(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let f = desk.fx_units()[0].clone();
        let h = 22.0;
        let row1 = Rect::from_min_size(r.min, vec2(r.width(), h));
        let row2 = Rect::from_min_size(pos2(r.left(), r.bottom() - h), vec2(r.width(), h));
        let all = ReleaseFxKind::ALL;
        let i = all.iter().position(|k| *k == f.release).unwrap_or(0) as i32;
        let pick = |dir: i32| all[(i + dir).rem_euclid(all.len() as i32) as usize];
        let name_w = r.width() - 48.0;
        if button(ui, p, Rect::from_min_size(row1.min, vec2(20.0, h)), "‹", false, LIT, "rfx-prev").clicked() {
            desk.set_release_kind(0, pick(-1));
        }
        let nr = Rect::from_min_size(pos2(row1.left() + 22.0, row1.top()), vec2(name_w, h));
        p.rect_filled(nr, CornerRadius::same(2), Color32::from_rgb(0x0A, 0x0A, 0x0B));
        fit::label(p, nr.center(), Align2::CENTER_CENTER, &format!("RELEASE · {}", f.release.name()), 9.5, TEXT, nr.width() - 6.0);
        if button(ui, p, Rect::from_min_size(pos2(nr.right() + 2.0, row1.top()), vec2(20.0, h)), "›", false, LIT, "rfx-next").clicked() {
            desk.set_release_kind(0, pick(1));
        }
        // its beats, and the hold
        let less = Rect::from_min_size(row2.min, vec2(20.0, h));
        let val = Rect::from_min_size(pos2(less.right() + 2.0, row2.top()), vec2(36.0, h));
        let more = Rect::from_min_size(pos2(val.right() + 2.0, row2.top()), vec2(20.0, h));
        if button(ui, p, less, "‹", false, LIT, "rfx-b-less").clicked() {
            desk.set_release_beats(0, f.release_beats / 2.0);
        }
        p.rect_filled(val, CornerRadius::same(2), Color32::from_rgb(0x0A, 0x0A, 0x0B));
        words(p, val.center(), Align2::CENTER_CENTER, &beat_words(f.release_beats), 12.0, "mono-semi", CUE);
        if button(ui, p, more, "›", false, LIT, "rfx-b-more").clicked() {
            desk.set_release_beats(0, f.release_beats * 2.0);
        }
        let hold = Rect::from_min_max(pos2(more.right() + 6.0, row2.top()), row2.max);
        let (_, resp) = kit::held(ui, hold, "rfx-hold");
        let down = resp.is_pointer_button_down_on();
        button(ui, p, hold, "HOLD", down || f.releasing, LIT, "rfx-hold-look").on_hover_text("Held: the release over FX1's deck (and FX1 off); let go: back");
        if down != f.releasing {
            desk.release_fx(0, down);
        }
    }

    /// The SOUND COLOR FX: which the channel knobs turn, and its PARAMETER.
    fn fx_color(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let c = desk.color_fx();
        let h = 22.0;
        let kw = 34.0;
        let cell_w = ((r.width() - kw - 6.0) / 3.0 - 3.0).max(40.0);
        for (i, k) in ColorFxKind::ALL.into_iter().enumerate() {
            let cell = Rect::from_min_size(pos2(r.left() + (i % 3) as f32 * (cell_w + 3.0), if i < 3 { r.top() } else { r.bottom() - h }), vec2(cell_w, h));
            if button(ui, p, cell, k.name(), c.kind == k, CUE, ("cfx", i)).on_hover_text("The channel knobs (CFX) turn this").clicked() {
                desk.set_color_fx(k);
            }
        }
        let kc = pos2(r.right() - kw / 2.0, r.center().y - 4.0);
        if let Some(v) = knob(ui, p, kc, c.param, false, 0.5, "cfx-param") {
            desk.set_color_param(v);
        }
        words(p, pos2(kc.x, r.bottom()), Align2::CENTER_BOTTOM, "PARAM", 7.5, "semi", MUTED);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn beats_in_rekordbox_s_words() {
        assert_eq!(beat_words(0.0625), "1/16");
        assert_eq!(beat_words(0.75), "3/4");
        assert_eq!(beat_words(1.0), "1");
        assert_eq!(beat_words(64.0), "64");
    }
}
