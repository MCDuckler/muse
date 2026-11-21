//! The BOARD page: the soundboard's sixteen pads of a bank (v1's board room, plain), its
//! banks, its fader, STOP ALL; a pad pressed with the mouse or F1–F8 (⇧: the lower two
//! rows), held for a hold pad. Right-click (or click an empty pad) opens the pad's card:
//! how it plays, and its sound from the house shelf, the account's own or the kit.
use eframe::egui::{self, Align2, Color32, CornerRadius, Painter, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::Desk;
use wo_deskcore::board::{self, Colour, Mode, Pad, Quantise};

use crate::App;
use crate::club::{self, LINE, MUTED, RAISED, TEXT, button, words};
use crate::ui::kit;

/// What the board page keeps between frames.
#[derive(Default)]
pub(crate) struct BoardUi {
    /// The pad held by the mouse (a hold pad stops when it is let go).
    held: Option<(usize, usize)>,
    /// The pad whose card is open.
    pub(crate) edit: Option<(usize, usize)>,
    find: String,
    /// The keys holding pads, and which.
    pub(crate) keys: Vec<(egui::Key, (usize, usize))>,
}

pub(crate) fn colour(c: Colour) -> Color32 {
    let rgb = |v: u32| Color32::from_rgb((v >> 16) as u8, (v >> 8) as u8, v as u8);
    match c {
        Colour::A => rgb(0x1C70DE),
        Colour::B => rgb(0xE8822A),
        Colour::Accent => rgb(0xE5394A),
        Colour::Teal => rgb(0x1FB5A8),
        Colour::Violet => rgb(0x8B5CF6),
        Colour::Orange => rgb(0xF5B30B),
        Colour::White => rgb(0xDADADF),
        Colour::Grey => rgb(0x6B6B73),
    }
}

/// The kit's sounds (rendered by the Desk, every board has them).
const KIT: [(i64, &str); 5] = [(-1, "Riser · 4 bars"), (-2, "Sweep up"), (-3, "Sweep down"), (-4, "Hydrant"), (-5, "Impact")];

const FKEYS: [egui::Key; 8] = [egui::Key::F1, egui::Key::F2, egui::Key::F3, egui::Key::F4, egui::Key::F5, egui::Key::F6, egui::Key::F7, egui::Key::F8];

/// A pad's key: F1–F8 the top two rows, ⇧F1–F8 the lower two.
fn key_word(i: usize) -> String {
    if i < 8 { format!("F{}", i + 1) } else { format!("⇧F{}", i - 7) }
}

impl App {
    /// F1–F8 (⇧: pads 9–16) pressed and let go, on whatever page: the board's bank up.
    pub(crate) fn board_keys(&mut self, desk: &mut Desk, ui: &Ui) {
        let events: Vec<(egui::Key, bool, bool)> = ui.input(|i| {
            i.events
                .iter()
                .filter_map(|e| match e {
                    egui::Event::Key { key, pressed, repeat: false, modifiers, .. } if FKEYS.contains(key) => Some((*key, *pressed, modifiers.shift)),
                    _ => None,
                })
                .collect()
        });
        for (key, pressed, shift) in events {
            if pressed {
                let i = FKEYS.iter().position(|k| *k == key).unwrap() + if shift { 8 } else { 0 };
                let at = (desk.board_view().bank, i);
                desk.board_press(at.0, at.1);
                self.board.keys.push((key, at));
            } else {
                while let Some(n) = self.board.keys.iter().position(|(k, _)| *k == key) {
                    let (_, (b, p)) = self.board.keys.remove(n);
                    desk.board_release(b, p);
                }
            }
        }
    }

    pub(crate) fn board_page(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let v = desk.board_view();
        club::panel(p, r);
        let inner = r.shrink(10.0);
        // the bar: banks, the fader, stop all, what is said
        let bar = Rect::from_min_size(inner.min, vec2(inner.width(), 28.0));
        let mut x = bar.left();
        for (i, name) in v.banks.iter().enumerate() {
            let word = if name.is_empty() { ["A", "B", "C", "D"][i].to_owned() } else { name.clone() };
            let w = (kit::chip_width(p, &word) + 18.0).clamp(44.0, 140.0);
            if button(ui, p, Rect::from_min_size(pos2(x, bar.top()), vec2(w, 26.0)), &word, v.bank == i, club::LIT, ("board-bank", i)).on_hover_text("The bank on the pads and F1–F8").clicked() {
                desk.board_set_bank(i);
            }
            x += w + 4.0;
        }
        let stop = Rect::from_min_size(pos2(bar.right() - 96.0, bar.top()), vec2(96.0, 26.0));
        if button(ui, p, stop, "STOP ALL", v.sounding > 0, club::CUE, "board-stop").on_hover_text("Every pad quiet").clicked() {
            desk.board_stop_all();
        }
        let lvl = Rect::from_min_size(pos2(stop.left() - 16.0 - 180.0, bar.top()), vec2(180.0, 26.0));
        words(p, pos2(lvl.left() - 6.0, lvl.center().y), Align2::RIGHT_CENTER, "LEVEL", 10.0, "", MUTED);
        if let Some(l) = kit::hslider(ui, p, lvl, v.level, true, 0.8, "board-level") {
            desk.board_set_level(l);
        }
        let said_room = (lvl.left() - 54.0 - x - 12.0).max(0.0);
        let said = v.said.clone().unwrap_or_else(|| "F1–F8 · ⇧F1–F8 · right-click a pad to set it".into());
        kit::clipped(p, pos2(x + 12.0, bar.center().y - 7.0), &said, 11.0, "", if v.said.is_some() { club::CUE } else { MUTED }, said_room);

        // the pads, and the card beside them when one is open
        let body = Rect::from_min_max(pos2(inner.left(), bar.bottom() + 10.0), inner.max);
        let card_w = if self.board.edit.is_some() { (body.width() * 0.36).clamp(300.0, 440.0) } else { 0.0 };
        let grid = Rect::from_min_max(body.min, pos2(body.right() - if card_w > 0.0 { card_w + 10.0 } else { 0.0 }, body.bottom()));
        let gap = 8.0;
        let side = ((grid.width() - 3.0 * gap) / 4.0).min((grid.height() - 3.0 * gap) / 4.0).max(20.0);
        let origin = pos2(grid.center().x - (4.0 * side + 3.0 * gap) / 2.0, grid.top());
        let (down, up) = ui.input(|i| (i.pointer.primary_pressed(), i.pointer.primary_released()));
        if up && let Some((b, pd)) = self.board.held.take() {
            desk.board_release(b, pd);
        }
        for (i, pv) in v.pads.iter().enumerate() {
            let pr = Rect::from_min_size(origin + vec2((i % 4) as f32 * (side + gap), (i / 4) as f32 * (side + gap)), vec2(side, side));
            let resp = ui.interact(pr, ui.scope_id().with(("board-pad", i)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
            self.pad_face(p, pr, i, pv, self.board.edit == Some((v.bank, i)));
            if resp.secondary_clicked() || (pv.pad.is_none() && resp.clicked()) {
                self.board.edit = Some((v.bank, i));
            } else if down && resp.hovered() && pv.pad.is_some() {
                desk.board_press(v.bank, i);
                self.board.held = Some((v.bank, i));
            }
        }
        if v.sounding > 0 {
            ui.ctx().request_repaint();
        }
        if let Some(at) = self.board.edit {
            let card = Rect::from_min_max(pos2(body.right() - card_w, body.top()), body.max);
            self.pad_card(desk, ui, p, card, at);
        }
    }

    fn pad_face(&self, p: &Painter, r: Rect, i: usize, pv: &board::PadView, editing: bool) {
        let cr = CornerRadius::same(6);
        let Some(pad) = &pv.pad else {
            p.rect(r, cr, Color32::from_rgb(0x16, 0x16, 0x18), Stroke::new(1.0, if editing { TEXT } else { LINE }), StrokeKind::Inside);
            words(p, r.center(), Align2::CENTER_CENTER, "+", 22.0, "", Color32::from_rgb(0x50, 0x50, 0x56));
            words(p, r.left_top() + vec2(8.0, 6.0), Align2::LEFT_TOP, &key_word(i), 10.0, "", Color32::from_rgb(0x50, 0x50, 0x56));
            return;
        };
        let c = colour(pad.colour);
        let lit = pv.lit.is_some();
        let fill = if lit { c } else { kit::alpha_of(c, if pv.ready { 0.22 } else { 0.1 }) };
        p.rect(r, cr, fill, Stroke::new(if editing { 2.0 } else { 1.0 }, if editing { TEXT } else { kit::alpha_of(c, 0.7) }), StrokeKind::Inside);
        let ink = if lit && pad.colour != Colour::Grey { Color32::from_rgb(0x10, 0x10, 0x12) } else { TEXT };
        // how far through
        if let Some(k) = pv.lit {
            let bar = Rect::from_min_size(pos2(r.left() + 6.0, r.bottom() - 9.0), vec2((r.width() - 12.0) * k, 4.0));
            p.rect_filled(bar, CornerRadius::same(2), Color32::from_black_alpha(140));
        }
        let size = (r.width() / 9.0).clamp(10.0, 17.0);
        let name = if pad.name.is_empty() { format!("#{}", pad.sample) } else { pad.name.clone() };
        kit::clipped_at(p, r.center(), Align2::CENTER_CENTER, &name, size, "", ink, r.width() - 14.0);
        let small = kit::alpha_of(ink, 0.7);
        words(p, r.left_top() + vec2(8.0, 6.0), Align2::LEFT_TOP, &key_word(i), 10.0, "", small);
        let mut tags = vec![];
        if pad.mode != Mode::OneShot {
            tags.push(pad.mode.word().to_owned());
        }
        if pad.quantise != Quantise::Off {
            tags.push(format!("on {}", pad.quantise.word()));
        }
        if pad.choke > 0 {
            tags.push(format!("choke {}", pad.choke));
        }
        if pad.duck > 0.0 {
            tags.push("duck".into());
        }
        kit::clipped_at(p, pos2(r.left() + 8.0, r.bottom() - 13.0), Align2::LEFT_BOTTOM, &tags.join(" · "), 9.5, "", small, r.width() - 16.0);
        if let Some(e) = &pv.failed {
            p.circle_filled(r.right_top() + vec2(-10.0, 10.0), 4.0, club::CUE);
            let _ = e;
        } else if !pv.ready {
            words(p, r.right_top() + vec2(-8.0, 6.0), Align2::RIGHT_TOP, "…", 11.0, "", small);
        }
    }

    /// The open pad's card: how it plays; the sounds to put on it.
    fn pad_card(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, (bank, i): (usize, usize)) {
        p.rect(r, CornerRadius::same(4), club::GROUND, Stroke::new(1.0, LINE), StrokeKind::Inside);
        let inner = r.shrink(10.0);
        let mut y = inner.top();
        let pad = desk.board_doc().pad(bank, i).cloned();
        words(p, pos2(inner.left(), y + 9.0), Align2::LEFT_CENTER, &format!("PAD {} · {}", i + 1, key_word(i)), 11.0, "", MUTED);
        if button(ui, p, Rect::from_min_size(pos2(inner.right() - 26.0, y), vec2(26.0, 20.0)), "✕", false, club::LIT, "board-card-close").on_hover_text("Close").clicked() {
            self.board.edit = None;
            return;
        }
        y += 28.0;
        let row = |y: f32| Rect::from_min_size(pos2(inner.left() + 64.0, y), vec2(inner.width() - 64.0, 22.0));
        let label = |p: &Painter, y: f32, s: &str| {
            words(p, pos2(inner.left(), y + 11.0), Align2::LEFT_CENTER, s, 10.0, "", MUTED);
        };
        if let Some(mut pd) = pad.clone() {
            let mut changed = false;
            label(p, y, "NAME");
            let mut name = pd.name.clone();
            let nr = row(y);
            let resp = ui.put(nr, egui::TextEdit::singleline(&mut name).id(ui.scope_id().with(("board-name", bank, i))).char_limit(24));
            if resp.changed() {
                pd.name = name.to_uppercase();
                changed = true;
            }
            y += 30.0;
            label(p, y, "PLAYS");
            let modes: Vec<&str> = Mode::ALL.iter().map(|m| m.word()).collect();
            if let Some(n) = kit::segmented(ui, p, row(y), &modes, Mode::ALL.iter().position(|m| *m == pd.mode), crate::ui::tokens::Tone::Deck(0), "board-mode") {
                pd.mode = Mode::ALL[n];
                changed = true;
            }
            y += 30.0;
            label(p, y, "STARTS");
            let qs: Vec<&str> = Quantise::ALL.iter().map(|q| q.word()).collect();
            if let Some(n) = kit::segmented(ui, p, row(y), &qs, Quantise::ALL.iter().position(|q| *q == pd.quantise), crate::ui::tokens::Tone::Deck(0), "board-q") {
                pd.quantise = Quantise::ALL[n];
                changed = true;
            }
            y += 30.0;
            label(p, y, "CHOKE");
            if let Some(n) = kit::segmented(ui, p, row(y), &["–", "1", "2", "3", "4"], Some(pd.choke as usize), crate::ui::tokens::Tone::Deck(0), "board-choke") {
                pd.choke = n as u8;
                changed = true;
            }
            y += 30.0;
            label(p, y, "COLOUR");
            let cr = row(y);
            let sw = cr.width() / 8.0;
            for (n, c) in Colour::ALL.iter().enumerate() {
                let s = Rect::from_min_size(pos2(cr.left() + n as f32 * sw, cr.top()), vec2(sw - 4.0, 22.0));
                let resp = ui.interact(s, ui.scope_id().with(("board-colour", n)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
                p.rect(s, CornerRadius::same(3), colour(*c), Stroke::new(if pd.colour == *c { 2.0 } else { 0.0 }, TEXT), StrokeKind::Outside);
                if resp.clicked() {
                    pd.colour = *c;
                    changed = true;
                }
            }
            y += 30.0;
            label(p, y, "GAIN");
            if let Some(g) = kit::hslider(ui, p, row(y), pd.gain / 1.5, true, 1.0 / 1.5, "board-gain") {
                pd.gain = g * 1.5;
                changed = true;
            }
            y += 30.0;
            label(p, y, "DUCK");
            if let Some(d) = kit::hslider(ui, p, row(y), pd.duck, true, 0.0, "board-duck").map(|d| if d < 0.03 { 0.0 } else { d }) {
                pd.duck = d;
                changed = true;
            }
            y += 30.0;
            if button(ui, p, Rect::from_min_size(pos2(inner.left(), y), vec2(110.0, 22.0)), "CLEAR PAD", false, club::CUE, "board-clear").clicked() {
                desk.board_set_pad(bank, i, None);
                return;
            }
            if changed {
                desk.board_set_pad(bank, i, Some(pd));
            }
            y += 34.0;
        }
        // the sounds
        p.line_segment([pos2(inner.left(), y - 6.0), pos2(inner.right(), y - 6.0)], Stroke::new(1.0, LINE));
        words(p, pos2(inner.left(), y + 9.0), Align2::LEFT_CENTER, if pad.is_some() { "CHANGE SOUND" } else { "PUT A SOUND ON IT" }, 10.0, "", MUTED);
        y += 22.0;
        kit::field(ui, p, Rect::from_min_size(pos2(inner.left(), y), vec2(inner.width(), 30.0)), &mut self.board.find, "Find a sound", Some(crate::ui::icons::Icon::Search), false, "board-find");
        y += 38.0;
        let list = Rect::from_min_max(pos2(inner.left(), y), inner.max);
        if list.height() < 30.0 {
            return;
        }
        let q = self.board.find.to_lowercase();
        let mut rows: Vec<(i64, String, Option<String>, bool)> = KIT.iter().map(|(id, n)| (*id, (*n).to_owned(), Some("Kit".to_owned()), false)).collect();
        let shelf_words = match desk.board_shelf() {
            Some(Ok(all)) => {
                rows.extend(all.iter().map(|s| (s.id, s.name.clone(), if s.house { s.group.clone().or(Some("House".into())) } else { Some("Mine".into()) }, true)));
                None
            }
            Some(Err(e)) => Some(format!("The house's sounds: {e}")),
            None => Some("Asking the house for its sounds…".to_owned()),
        };
        rows.retain(|(_, n, g, _)| q.is_empty() || n.to_lowercase().contains(&q) || g.as_deref().is_some_and(|g| g.to_lowercase().contains(&q)));
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(list));
        let mut chosen = None;
        let mut hear = None;
        egui::ScrollArea::vertical().id_salt("board-sounds").auto_shrink([false, false]).show_rows(&mut child, 26.0, rows.len() + 1, |ui, range| {
            for n in range {
                let (rr, _) = ui.allocate_exact_size(vec2(ui.available_width(), 26.0), Sense::hover());
                let pp = &ui.painter().clone();
                if n == rows.len() {
                    if let Some(w) = &shelf_words {
                        kit::clipped(pp, pos2(rr.left() + 4.0, rr.top() + 6.0), w, 11.0, "", MUTED, rr.width() - 8.0);
                    }
                    continue;
                }
                let (id, name, group, _) = &rows[n];
                let row = ui.interact(Rect::from_min_max(rr.min, pos2(rr.right() - 34.0, rr.bottom())), ui.scope_id().with(("board-row", id)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
                if row.hovered() {
                    pp.rect_filled(rr, CornerRadius::same(3), RAISED);
                }
                let gw = 90.0;
                kit::clipped(pp, pos2(rr.left() + 6.0, rr.top() + 6.0), name, 12.0, "", TEXT, rr.width() - gw - 46.0);
                kit::clipped_at(pp, pos2(rr.right() - 40.0, rr.center().y), Align2::RIGHT_CENTER, group.as_deref().unwrap_or(""), 10.0, "", MUTED, gw);
                let play = Rect::from_center_size(pos2(rr.right() - 16.0, rr.center().y), vec2(26.0, 20.0));
                if button(ui, pp, play, "▶", false, club::LIT, ("board-hear", id)).on_hover_text("Hear it (again: stop)").clicked() {
                    hear = Some(*id);
                }
                if row.clicked() {
                    chosen = Some((*id, name.clone()));
                }
            }
        });
        if let Some(id) = hear {
            desk.board_audition(id);
        }
        if let Some((id, name)) = chosen {
            // a new sound keeps how the pad plays; its words are the sound's
            let pd = match pad {
                Some(old) => Pad { sample: id, name: Pad::new(id, &name).name, in_ms: 0, out_ms: None, ..old },
                None => Pad::new(id, &name),
            };
            desk.board_set_pad(bank, i, Some(pd));
        }
    }
}
