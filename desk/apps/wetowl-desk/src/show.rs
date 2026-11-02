//! The Show page (K, or the top bar's Show): the stage's picture large, and the hands
//! that perform the show — v1's PERFORM, sent over the wire to the stage's director
//! (app/lib/src/ui/show/desk_hands.dart):
//!
//!   HIT · NEXT · BACK · MOSH
//!   HOLD · STROBE (while held) · FREEZE · BLACK
//!   NEVER THIS · LESS · MORE · KEEP     (WIDER and UNDO beside what was said)
//!
//! and beside them what the hands hold (LET GO), the sets, and the screen the show
//! fills. The overviews and the Auto DJ stay on the page, so a set runs on while the
//! show is played.
use std::time::{Duration, Instant};

use eframe::egui::{self, Align2, Color32, CornerRadius, FontId, Painter, Rect, Stroke, StrokeKind, pos2, vec2};
use wo_deskcore::theme;
use wo_deskcore::{Desk, ShowHand, Snapshot, StageView};

use crate::App;
use crate::paint::*;

/// Which page is up under the top bar.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Page {
    #[default]
    Booth,
    Show,
}

/// How long what the stage said stays under the picture.
const SAID_FOR: Duration = Duration::from_secs(8);

impl App {
    /// The page under the top bar and the overviews.
    pub(crate) fn show_page(&mut self, desk: &mut Desk, ui: &mut egui::Ui, p: &Painter, main: Rect, s: &Snapshot) {
        let v = desk.stage();
        if v.told.said_n != self.said.0 {
            self.said = (v.told.said_n, Some(Instant::now()));
        }
        let right_w = 520.0;
        let pic = Rect::from_min_max(main.min, pos2(main.right() - right_w - 10.0, main.bottom()));
        let col_x = pic.right() + 10.0;
        let perform = Rect::from_min_size(pos2(col_x, main.top()), vec2(right_w, 232.0));
        let auto = Rect::from_min_max(pos2(col_x, main.bottom() - 300.0), main.max);
        let room = Rect::from_min_max(pos2(col_x, perform.bottom() + 10.0), pos2(main.right(), auto.top() - 10.0));
        self.big_picture(desk, ui, p, pic, &v);
        self.perform(desk, ui, p, perform, &v);
        self.holds_sets_screens(desk, ui, p, room, &v);
        self.auto_dj(desk, ui, p, auto, s);
    }

    fn big_picture(&mut self, desk: &mut Desk, ui: &mut egui::Ui, p: &Painter, r: Rect, v: &StageView) {
        panel(p, r, false);
        let inner = r.shrink(14.0);
        let on = v.stages > 0;
        label(p, inner.left_top(), Align2::LEFT_TOP, "Stage", col(theme::SOFT));
        // open / close, and how it is
        let ob = Rect::from_min_size(pos2(inner.right() - 150.0, inner.top() - 6.0), vec2(150.0, 28.0));
        let word = if on || v.starting { "Close the stage" } else { "Open the stage" };
        if button(ui, p, ob, word, Lit::No, "show-stage-open").clicked() {
            if on || v.starting {
                desk.close_stage();
            } else {
                desk.open_stage();
            }
        }
        let (dot, state) = match (on, v.starting) {
            (true, _) if v.told.full => (col(theme::OK), format!("Full screen{}", v.told.screen.as_ref().map(|s| format!(" on {s}")).unwrap_or_default())),
            (true, _) => (col(theme::OK), "In a window".to_owned()),
            (false, true) => (col(theme::WARM), "Starting…".to_owned()),
            _ => (col(theme::FAINT), "Closed".to_owned()),
        };
        let w = label(p, pos2(ob.left() - 14.0, ob.center().y), Align2::RIGHT_CENTER, &state, col(theme::MUTED));
        p.circle_filled(pos2(w.left() - 8.0, w.center().y), 3.5, dot);

        // the picture, as large as fits above the words under it
        let below = 74.0;
        let top = inner.top() + 34.0;
        let room = vec2(inner.width(), inner.bottom() - below - top);
        let size = if room.x * 9.0 / 16.0 <= room.y { vec2(room.x, room.x * 9.0 / 16.0) } else { vec2(room.y * 16.0 / 9.0, room.y) };
        let pic = Rect::from_min_size(pos2(inner.center().x - size.x / 2.0, top), size);
        p.rect_filled(pic, CornerRadius::same(6), Color32::BLACK);
        match (&self.stage_pic, on) {
            (Some((_, tex)), true) => {
                p.image(tex.id(), pic, Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)), Color32::WHITE);
            }
            _ => {
                let (say, ink) = match (&v.trouble, v.starting) {
                    (Some(why), _) => (why.clone(), col(theme::WARM)),
                    (None, true) => ("The stage window is opening".to_owned(), col(theme::MUTED)),
                    (None, false) => ("The show, in a window of its own: open the stage".to_owned(), col(theme::FAINT_ON_GLASS)),
                };
                let g = p.layout(say, FontId::new(15.0, family("")), ink, pic.width() - 48.0);
                p.galley(pic.center() - g.size() / 2.0, g, ink);
            }
        }
        if v.blackout {
            text(p, pic.left_top() + vec2(14.0, 14.0), Align2::LEFT_TOP, "BLACKOUT", 13.0, "mono-semi", col(theme::HOT));
        } else if v.freeze {
            text(p, pic.left_top() + vec2(14.0, 14.0), Align2::LEFT_TOP, "FROZEN", 13.0, "mono-semi", col(theme::WARM));
        }
        p.rect_stroke(pic, CornerRadius::same(6), Stroke::new(1.0, white(0.08)), StrokeKind::Inside);

        // what is on, in words
        let y = pic.bottom() + 22.0;
        let x0 = inner.left();
        let sc = label(p, pos2(x0, y), Align2::LEFT_CENTER, "On", col(theme::FAINT_ON_GLASS));
        let held_x = if v.held { text(p, pos2(inner.right(), y), Align2::RIGHT_CENTER, "HELD", 12.0, "mono-semi", col(theme::WARM)).left() } else { inner.right() };
        let words = match (on, v.untold) {
            (true, true) => "this WetOwl app's stage is older than the Desk".to_owned(),
            (true, false) => v.told.look.clone().or_else(|| v.scene.clone()).unwrap_or_else(|| "—".into()),
            _ => "—".into(),
        };
        clip_text(p, pos2(sc.right() + 12.0, y), &words, 15.0, col(theme::TEXT), held_x - sc.right() - 28.0);

        // what the stage said of the last judging, with WIDER and UNDO
        let y2 = y + 34.0;
        let fresh = self.said.1.is_some_and(|t| t.elapsed() < SAID_FOR);
        if on && fresh && let Some(said) = &v.told.said {
            let mut bx = inner.right();
            if v.told.undo {
                let br = Rect::from_min_size(pos2(bx - 80.0, y2 - 14.0), vec2(80.0, 28.0));
                if button(ui, p, br, "Undo", Lit::No, "show-undo").clicked() {
                    desk.show(ShowHand::Undo);
                }
                bx = br.left() - 6.0;
            }
            if v.told.wider {
                let br = Rect::from_min_size(pos2(bx - 80.0, y2 - 14.0), vec2(80.0, 28.0));
                if button(ui, p, br, "Wider", Lit::No, "show-wider").clicked() {
                    desk.show(ShowHand::Wider);
                }
                bx = br.left() - 6.0;
            }
            clip_text(p, pos2(x0, y2), said, 13.0, col(theme::WARM), bx - x0 - 12.0);
        }
    }

    fn perform(&mut self, desk: &mut Desk, ui: &mut egui::Ui, p: &Painter, r: Rect, v: &StageView) {
        panel(p, r, false);
        let inner = r.shrink(14.0);
        let on = v.stages > 0;
        // a stage that tells its look takes the judging (an older one only the rest)
        let judges = on && !v.untold && v.told.look.is_some();
        label(p, inner.left_top(), Align2::LEFT_TOP, "Perform", col(theme::SOFT));
        if on && !judges {
            label(p, pos2(inner.right(), inner.top() + 6.0), Align2::RIGHT_CENTER, "judging needs a newer stage", col(theme::FAINT_ON_GLASS));
        }
        let gap = 8.0;
        let bw = (inner.width() - 3.0 * gap) / 4.0;
        let bh = 50.0;
        let at = |row: usize, i: usize| Rect::from_min_size(pos2(inner.left() + i as f32 * (bw + gap), inner.top() + 30.0 + row as f32 * (bh + gap)), vec2(bw, bh));
        let lit = |b: bool| if b && on { Lit::Ok } else { Lit::No };

        let rows: [[(&str, Lit, Option<ShowHand>); 4]; 3] = [
            [
                ("Hit", Lit::No, Some(ShowHand::Hit)),
                ("Next", Lit::No, Some(ShowHand::Next)),
                ("Back", Lit::No, Some(ShowHand::Previous)),
                ("Mosh", Lit::No, Some(ShowHand::Mosh)),
            ],
            [
                ("Hold", lit(v.held), Some(ShowHand::Hold(!v.held))),
                // the strobe acts on press and release: drawn here, worked below
                ("Strobe", lit(self.strobe), None),
                ("Freeze", lit(v.freeze), Some(ShowHand::Freeze(!v.freeze))),
                ("Black", lit(v.blackout), Some(ShowHand::Blackout(!v.blackout))),
            ],
            [
                ("Never this", Lit::No, judges.then_some(ShowHand::Never)),
                ("Less", Lit::No, judges.then_some(ShowHand::Less)),
                ("More", Lit::No, judges.then_some(ShowHand::More)),
                ("Keep", Lit::No, judges.then_some(ShowHand::Keep)),
            ],
        ];
        for (row, hands) in rows.into_iter().enumerate() {
            for (i, (name, l, hand)) in hands.into_iter().enumerate() {
                let br = at(row, i);
                if row == 1 && i == 1 {
                    let resp = held(ui, br, "show-strobe");
                    paint_button(p, br, name, l, resp.hovered());
                    let down = on && resp.is_pointer_button_down_on();
                    if down != self.strobe {
                        self.strobe = down;
                        desk.show(ShowHand::Strobe(down));
                    }
                    continue;
                }
                let usable = on && hand.is_some();
                if !usable {
                    p.rect(br, CornerRadius::same(6), white(0.02), Stroke::new(1.0, white(0.06)), StrokeKind::Inside);
                    label_sized(p, br.center(), Align2::CENTER_CENTER, name, 11.5, col(theme::FAINT));
                    continue;
                }
                if button(ui, p, br, name, l, ("perform", row, i)).clicked()
                    && let Some(h) = hand
                {
                    desk.show(h);
                }
            }
        }
    }

    fn holds_sets_screens(&mut self, desk: &mut Desk, ui: &mut egui::Ui, p: &Painter, r: Rect, v: &StageView) {
        panel(p, r, false);
        let inner = r.shrink(14.0);
        let on = v.stages > 0 && !v.untold;
        let mut y = inner.top();

        // what the hands hold
        label(p, pos2(inner.left(), y + 10.0), Align2::LEFT_CENTER, "Held", col(theme::SOFT));
        let held = v.told.holds;
        let words = match (on, held) {
            (false, _) => "—".to_owned(),
            (true, 0) => "nothing: the director has it all".to_owned(),
            (true, 1) => "one thing".to_owned(),
            (true, n) => format!("{n} things"),
        };
        clip_text(p, pos2(inner.left() + 70.0, y + 10.0), &words, 13.0, col(theme::MUTED), inner.width() - 200.0);
        if on && held > 0 {
            let br = Rect::from_min_size(pos2(inner.right() - 110.0, y - 4.0), vec2(110.0, 28.0));
            if button(ui, p, br, "Let go all", Lit::Ok, "show-letgo").clicked() {
                desk.show(ShowHand::LetGo);
            }
        }
        y += 40.0;

        // the sets
        label(p, pos2(inner.left(), y + 10.0), Align2::LEFT_CENTER, "Sets", col(theme::SOFT));
        let mut sets: Vec<(String, String)> = vec![(String::new(), "As shipped".to_owned())];
        sets.extend(v.told.sets.iter().map(|s| (s.id.clone(), s.name.clone())));
        let on_set = v.told.set.clone().unwrap_or_default();
        let picked;
        (y, picked) = chips(ui, p, Rect::from_min_max(pos2(inner.left() + 70.0, y - 4.0), pos2(inner.right(), inner.bottom())), on, &sets, &on_set, "set");
        if let Some(id) = picked {
            desk.show(ShowHand::Set(id));
        }
        y += 14.0;

        // the screen the show fills
        label(p, pos2(inner.left(), y + 10.0), Align2::LEFT_CENTER, "Screen", col(theme::SOFT));
        let mut screens: Vec<(String, String)> = vec![(String::new(), "Window".to_owned())];
        screens.extend(v.told.screens.iter().map(|s| (s.name.clone(), format!("{} {}×{}", s.name, s.w, s.h))));
        let on_screen = if v.told.full { v.told.screen.clone().unwrap_or_else(|| "?".into()) } else { String::new() };
        let shown_on = if v.stages > 0 { on_screen } else { v.kept_screen.clone().unwrap_or_default() };
        let picked;
        (y, picked) = chips(ui, p, Rect::from_min_max(pos2(inner.left() + 70.0, y - 4.0), pos2(inner.right(), inner.bottom())), on, &screens, &shown_on, "screen");
        if let Some(name) = picked {
            desk.show(if name.is_empty() { ShowHand::Full(false) } else { ShowHand::Screen(name) });
        }
        if !on && let Some(k) = &v.kept_screen {
            clip_text(p, pos2(inner.left() + 70.0, y + 14.0), &format!("opens full screen on {k}"), 12.0, col(theme::FAINT_ON_GLASS), inner.width() - 70.0);
        }
    }
}

/// Chips in rows within `r`: (key, words); the one whose key is `on` lit. Returns the
/// bottom of the last row, and the key of a chip clicked.
fn chips(ui: &mut egui::Ui, p: &Painter, r: Rect, usable: bool, items: &[(String, String)], on: &str, id: &str) -> (f32, Option<String>) {
    let mut picked = None;
    let (h, gap) = (28.0, 6.0);
    let (mut x, mut y) = (r.left(), r.top());
    for (key, words) in items {
        let w = label_width(p, words, 11.5) + 24.0;
        if x + w > r.right() && x > r.left() {
            x = r.left();
            y += h + gap;
        }
        let cr = Rect::from_min_size(pos2(x, y), vec2(w.min(r.width()), h));
        let lit = if usable && key == on { Lit::Ok } else { Lit::No };
        if usable {
            if button(ui, p, cr, words, lit, (id, key)).clicked() {
                picked = Some(key.clone());
            }
        } else {
            p.rect(cr, CornerRadius::same(6), white(0.02), Stroke::new(1.0, white(0.06)), StrokeKind::Inside);
            label_sized(p, cr.center(), Align2::CENTER_CENTER, words, 11.5, col(theme::FAINT));
        }
        x += w + gap;
    }
    (y + h, picked)
}
