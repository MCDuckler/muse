//! The Show page (K, or the top bar's Show): the stage's picture large under glass captions,
//! and the hands that perform the show — v1's PERFORM, sent to the stage's director
//! (app/lib/src/ui/show/desk_hands.dart), or taken by the Desk's own director where the
//! stage is the Rust one:
//!
//!   NEVER THIS · WIDER · LESS · MORE · KEEP      (UNDO beside what was said)
//!   HIT · NEXT · BACK · MOSH
//!   HOLD · STROBE (while held) · FREEZE · BLACK
//!
//! and beside them what the hands hold (LET GO), the sets, the screen the show fills, which
//! stage; under the picture what may come next, the favourites, the rotation and MilkDrop.
//! The overviews and the Auto DJ stay on the page, so a set runs on while the show is played.
use std::time::{Duration, Instant};

use eframe::egui::{self, Align2, Color32, CornerRadius, Painter, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::{Desk, MilkHand, ShowBoard, ShowHand, Snapshot, StageView};

use crate::App;
use crate::paint::{label_sized, white};
use crate::ui::icons::Icon;
use crate::ui::kit::{self, Btn, alpha_of};
use crate::ui::motion;
use crate::ui::tokens::{self as t, Tone, mix};

/// Which page is up under the top bar.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Page {
    #[default]
    Booth,
    Show,
    /// Every control of the kit in every state (`--page kit`): the design's review page.
    Kit,
}

/// How long what the stage said stays up.
const SAID_FOR: Duration = Duration::from_secs(8);

impl App {
    /// The page under the top bar and the overviews.
    pub(crate) fn show_page(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, main: Rect, s: &Snapshot) {
        let v = desk.stage();
        if v.told.said_n != self.said.0 {
            self.said = (v.told.said_n, Some(Instant::now()));
        }
        let board = desk.show_board();
        let g = t::GAP;
        let right_w = 520.0;
        let col_x = main.right() - right_w;
        let left = Rect::from_min_max(main.min, pos2(col_x - g, main.bottom()));
        let row_h = (left.height() * 0.24).clamp(160.0, 230.0);
        let pic = Rect::from_min_max(left.min, pos2(left.right(), left.bottom() - row_h - g));
        let row = Rect::from_min_max(pos2(left.left(), pic.bottom() + g), left.max);
        let judge = Rect::from_min_size(pos2(col_x, main.top()), vec2(right_w, 138.0));
        let perform = Rect::from_min_size(pos2(col_x, judge.bottom() + g), vec2(right_w, 136.0));
        let auto_h = (main.height() * 0.34).clamp(200.0, 300.0);
        let auto = Rect::from_min_max(pos2(col_x, main.bottom() - auto_h), main.max);
        let room = Rect::from_min_max(pos2(col_x, perform.bottom() + g), pos2(main.right(), auto.top() - g));
        self.big_picture(desk, ui, p, pic, &v, board.as_ref());
        self.cards(desk, ui, p, row, &v, board.as_ref());
        self.judge(desk, ui, p, judge, &v);
        self.perform(desk, ui, p, perform, &v);
        self.holds_sets_screens(desk, ui, p, room, &v);
        self.auto_dj(desk, ui, p, auto, s);
    }

    fn big_picture(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, v: &StageView, board: Option<&ShowBoard>) {
        kit::panel(p, r, false);
        let inner = r.shrink(10.0);
        let on = v.stages > 0;
        let size = if inner.width() * 9.0 / 16.0 <= inner.height() { vec2(inner.width(), inner.width() * 9.0 / 16.0) } else { vec2(inner.height() * 16.0 / 9.0, inner.height()) };
        let pic = Rect::from_center_size(inner.center(), size);
        let cr = CornerRadius::same(t::R_PAD);
        p.rect_filled(pic, cr, Color32::BLACK);
        let uv = Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0));
        match (&self.stage_pic, on) {
            (Some((_, tex)), true) => {
                p.add(egui::epaint::RectShape::filled(pic, cr, Color32::WHITE).with_texture(tex.id(), uv));
            }
            _ => {
                let (say, ink) = match (&v.trouble, v.starting) {
                    (Some(why), _) => (why.clone(), t::warm()),
                    (None, true) => ("The stage window is opening…".to_owned(), t::muted()),
                    (None, false) => ("The show plays in a window of its own".to_owned(), t::soft()),
                };
                let g = p.layout(say, egui::FontId::new(16.0, crate::paint::family("")), ink, pic.width() - 64.0);
                p.galley(pic.center() - vec2(g.size().x / 2.0, g.size().y + 22.0), g, ink);
                if !v.starting {
                    let br = Rect::from_center_size(pic.center() + vec2(0.0, 20.0), vec2(190.0, 40.0));
                    if Btn::new("Open the stage").icon(Icon::Screen).tone(Tone::Ok).on(true).size(12.5).show(ui, p, br, "show-open-big").clicked() {
                        desk.open_stage();
                    }
                }
            }
        }
        // blackout dims the picture to black
        let black = motion::tween_bool(ui.ctx(), ui.scope_id().with("blackout"), on && v.blackout, 0.18, 0.18);
        if black > 0.0 {
            p.rect_filled(pic, cr, Color32::from_black_alpha((235.0 * black) as u8));
        }
        p.rect_stroke(pic, cr, Stroke::new(1.0, white(0.08)), StrokeKind::Inside);

        // the caption at the top: live, and the look on
        let words = match (on, v.untold) {
            (true, true) => "an older stage: it says nothing of its look".to_owned(),
            (true, false) => v.told.look.clone().or_else(|| v.scene.clone()).unwrap_or_else(|| "—".into()),
            _ => String::new(),
        };
        let (dot, state) = match (on, v.starting) {
            (true, _) if v.blackout => (t::hot(), "Blackout"),
            (true, _) if v.freeze => (t::warm(), "Frozen"),
            (true, _) => (t::red(), "Live"),
            (false, true) => (t::warm(), "Starting"),
            _ => (t::faint(), "Closed"),
        };
        let font = egui::FontId::new(13.0, crate::paint::family(""));
        let ww = if words.is_empty() { 0.0 } else { p.layout_no_wrap(words.clone(), font.clone(), t::text()).size().x.min(pic.width() * 0.6) + 16.0 };
        let sw = crate::paint::label_width(p, state, 10.5);
        let cap = Rect::from_min_size(pic.left_top() + vec2(12.0, 12.0), vec2(30.0 + sw + ww + if v.held { 50.0 } else { 0.0 }, 30.0));
        kit::glass_tab(p, cap);
        kit::dot(p, pos2(cap.left() + 14.0, cap.center().y), dot, 3.5);
        let st = label_sized(p, pos2(cap.left() + 26.0, cap.center().y), Align2::LEFT_CENTER, state, 10.5, t::soft());
        let mut x = st.right() + 10.0;
        if !words.is_empty() {
            kit::clipped(p, pos2(x, cap.center().y), &words, 13.0, "", t::text(), ww - 12.0);
            x += ww;
        }
        if v.held {
            label_sized(p, pos2(x, cap.center().y), Align2::LEFT_CENTER, "Held", 10.5, t::warm());
        }
        // the top right: how it is shown, and the window open or closed
        let ob = Rect::from_min_size(pos2(pic.right() - 12.0 - 150.0, pic.top() + 12.0), vec2(150.0, 30.0));
        let word = if on || v.starting { "Close the stage" } else { "Open the stage" };
        kit::glass_tab(p, ob);
        if Btn::new(word).icon(Icon::Screen).quiet().size(11.0).show(ui, p, ob, "show-stage-open").clicked() {
            if on || v.starting {
                desk.close_stage();
            } else {
                desk.open_stage();
            }
        }
        if on {
            let full = if v.told.full { format!("Full screen{}", v.told.screen.as_ref().map(|s| format!(" · {s}")).unwrap_or_default()) } else { "In a window".to_owned() };
            let fw = crate::paint::label_width(p, &full, 10.5) + 20.0;
            let fr = Rect::from_min_size(pos2(ob.left() - 8.0 - fw, ob.top()), vec2(fw, 30.0));
            kit::glass_tab(p, fr);
            label_sized(p, fr.center(), Align2::CENTER_CENTER, &full, 10.5, t::muted());
        }
        // the foot: what may come next, how long the look has been on, a cut
        if on && let Some(b) = board {
            let bar = Rect::from_min_max(pos2(pic.left() + 12.0, pic.bottom() - 12.0 - 40.0), pos2(pic.right() - 12.0, pic.bottom() - 12.0));
            kit::glass_tab(p, bar);
            let cut = Rect::from_min_size(pos2(bar.right() - 6.0 - 112.0, bar.top() + 6.0), vec2(112.0, 28.0));
            if Btn::new("Cut now").icon(Icon::Next).size(11.0).show(ui, p, cut, "cut-now").on_hover_text("The next look, now  (.)").clicked() {
                desk.show(ShowHand::Next);
            }
            // the phrase it is in: 16 bars
            let pr = Rect::from_min_max(pos2(cut.left() - 14.0 - 140.0, bar.center().y - 2.0), pos2(cut.left() - 14.0, bar.center().y + 2.0));
            p.rect_filled(pr, CornerRadius::same(2), white(0.12));
            let k = (b.bars_on.rem_euclid(16) as f32 + 1.0) / 16.0;
            let kx = motion::spring(ui.ctx(), ui.scope_id().with("phrase"), pr.width() * k, 0.2);
            p.rect_filled(Rect::from_min_size(pr.min, vec2(kx, 4.0)), CornerRadius::same(2), t::soft());
            kit::text(p, pos2(pr.left() - 10.0, bar.center().y), Align2::RIGHT_CENTER, &format!("{} bar{} on", b.bars_on, if b.bars_on == 1 { "" } else { "s" }), 11.5, "mono", t::muted());
            let nl = label_sized(p, pos2(bar.left() + 14.0, bar.center().y), Align2::LEFT_CENTER, "Next", 10.5, t::label());
            let next = b.coming.first().map_or("the director's choice", |c| c.0.as_str());
            kit::clipped(p, pos2(nl.right() + 10.0, bar.center().y), next, 13.0, "", t::text(), pr.left() - 120.0 - nl.right());
        }
    }

    /// Under the picture: what may come, the favourites, the rotation, MilkDrop.
    fn cards(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, v: &StageView, board: Option<&ShowBoard>) {
        // the WetOwl app's stage directs itself: one card saying what the Rust one brings
        if !v.rust {
            kit::panel(p, r, false);
            let inner = r.shrink(t::INSET);
            kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Directed by the Desk");
            let c = inner.center();
            kit::text(p, c - vec2(0.0, 30.0), Align2::CENTER_CENTER, "With the Rust stage the Desk directs the show", t::BODY + 2.0, "", t::soft());
            kit::hint(p, c - vec2(0.0, 6.0), Align2::CENTER_CENTER, "What comes next, your favourites and the rotation show here, and MilkDrop plays on it");
            if v.rust_here {
                let br = Rect::from_center_size(c + vec2(0.0, 34.0), vec2(200.0, 34.0));
                if Btn::new("Use the Rust stage").icon(Icon::Screen).show(ui, p, br, "use-rust").clicked() {
                    desk.set_rust_stage(true);
                }
            } else {
                kit::hint(p, c + vec2(0.0, 30.0), Align2::CENTER_CENTER, "(it is not installed beside this Desk)");
            }
            return;
        }
        let milk = v.rust;
        let n = if milk { 4.0 } else { 3.0 };
        let g = t::GAP;
        let w = (r.width() - (n - 1.0) * g) / n;
        let at = |i: f32| Rect::from_min_size(pos2(r.left() + i * (w + g), r.top()), vec2(w, r.height()));
        let directs = board.is_some();
        let not_here = "Open the stage: the director starts with it";

        // what may come next
        let c = at(0.0);
        kit::panel(p, c, false);
        let inner = c.shrink(t::INSET);
        kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Coming up");
        match board.filter(|_| directs) {
            Some(b) if !b.coming.is_empty() => {
                for (i, (words, share)) in b.coming.iter().enumerate() {
                    let y = inner.top() + 32.0 + i as f32 * 40.0;
                    if y + 30.0 > inner.bottom() {
                        break;
                    }
                    kit::clipped(p, pos2(inner.left(), y + 6.0), words, 13.0, "", if i == 0 { t::text() } else { t::soft() }, inner.width() - 44.0);
                    kit::text(p, pos2(inner.right(), y + 6.0), Align2::RIGHT_CENTER, &format!("{:.0}%", share * 100.0), 11.0, "mono", t::muted());
                    let bar = Rect::from_min_size(pos2(inner.left(), y + 20.0), vec2(inner.width(), 3.0));
                    p.rect_filled(bar, CornerRadius::same(1), white(0.07));
                    p.rect_filled(Rect::from_min_size(bar.min, vec2(bar.width() * share.clamp(0.0, 1.0), 3.0)), CornerRadius::same(1), white(0.35));
                }
            }
            Some(_) => {
                kit::hint(p, inner.center(), Align2::CENTER_CENTER, "The director picks when the stage shows");
            }
            None => {
                kit::hint(p, inner.center(), Align2::CENTER_CENTER, not_here);
            }
        }

        // the favourites: KEEP puts them here; a click puts one on (held)
        let c = at(1.0);
        kit::panel(p, c, false);
        let inner = c.shrink(t::INSET);
        kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Favourites");
        match board.filter(|_| directs) {
            Some(b) if !b.faves.is_empty() => {
                let (h, gap) = (28.0, 6.0);
                let (mut x, mut y) = (inner.left(), inner.top() + 28.0);
                for (id, words) in &b.faves {
                    let short: String = if words.chars().count() > 28 { words.chars().take(27).collect::<String>() + "…" } else { words.clone() };
                    let w = (kit::chip_width(p, &short)).min(inner.width());
                    if x + w > inner.right() && x > inner.left() {
                        x = inner.left();
                        y += h + gap;
                    }
                    if y + h > inner.bottom() {
                        break;
                    }
                    let cr = Rect::from_min_size(pos2(x, y), vec2(w, h));
                    if kit::chip(ui, p, cr, &short, false, Tone::Neutral, v.stages > 0, ("fave", id)).on_hover_text(words).clicked() {
                        desk.show(ShowHand::Fave(id.clone()));
                    }
                    x += w + gap;
                }
            }
            Some(_) => {
                kit::hint(p, inner.center(), Align2::CENTER_CENTER, "KEEP a look to have it here");
            }
            None => {
                kit::hint(p, inner.center(), Align2::CENTER_CENTER, not_here);
            }
        }

        // the rotation: how often each scene comes
        let c = at(2.0);
        kit::panel(p, c, false);
        let inner = c.shrink(t::INSET);
        kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Rotation");
        match board.filter(|_| directs) {
            Some(b) if !b.rotation.is_empty() => {
                let rows = (((inner.height() - 28.0) / 22.0).floor() as usize).max(1);
                let name_w = (inner.width() * 0.42).min(150.0);
                for (i, (name, level)) in b.rotation.iter().take(rows).enumerate() {
                    let y = inner.top() + 36.0 + i as f32 * 22.0;
                    kit::clipped(p, pos2(inner.left(), y), name, 12.0, "", t::soft(), name_w - 8.0);
                    let bar = Rect::from_min_max(pos2(inner.left() + name_w, y - 2.0), pos2(inner.right(), y + 2.0));
                    p.rect_filled(bar, CornerRadius::same(2), white(0.07));
                    let lw = motion::spring(ui.ctx(), ui.scope_id().with(("rot", name)), bar.width() * level.clamp(0.0, 1.0), 0.3);
                    p.rect_filled(Rect::from_min_size(bar.min, vec2(lw, 4.0)), CornerRadius::same(2), mix(white(0.3), t::text(), *level));
                }
            }
            _ => {
                kit::hint(p, inner.center(), Align2::CENTER_CENTER, if directs { "—" } else { not_here });
            }
        }

        if milk {
            self.milk_card(desk, ui, p, at(3.0));
        }
    }

    /// The judging of the look on: never again (wider), less, more, kept; what it said.
    fn judge(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, v: &StageView) {
        kit::panel(p, r, false);
        let inner = r.shrink(t::INSET);
        let on = v.stages > 0;
        // a stage that tells its look takes the judging (an older one only the rest)
        let judges = on && !v.untold && v.told.look.is_some();
        kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Judge the look");
        if on && !judges {
            kit::hint(p, pos2(inner.right(), inner.top() + 6.0), Align2::RIGHT_CENTER, "needs a newer stage");
        }
        let gap = 8.0;
        let bw = (inner.width() - 4.0 * gap) / 5.0;
        let top = inner.top() + 26.0;
        let hands: [(&str, &str, Tone, bool, ShowHand); 5] = [
            ("Never this", "never again", Tone::Danger, judges, ShowHand::Never),
            ("Wider", "reach further", Tone::Neutral, judges && v.told.wider, ShowHand::Wider),
            ("Less", "half as often", Tone::Neutral, judges, ShowHand::Less),
            ("More", "twice as often", Tone::Neutral, judges, ShowHand::More),
            ("Keep", "a favourite", Tone::Ok, judges, ShowHand::Keep),
        ];
        for (i, (word, sub, tone, usable, hand)) in hands.into_iter().enumerate() {
            let br = Rect::from_min_size(pos2(inner.left() + i as f32 * (bw + gap), top), vec2(bw, 54.0));
            let accent = matches!(tone, Tone::Danger | Tone::Ok);
            if Btn::new(word).sub(sub).tone(tone).accent(accent).enabled(usable).show(ui, p, br, ("judge", i)).clicked() {
                desk.show(hand);
            }
        }
        // what the last judging said, with UNDO
        let y = top + 54.0 + 16.0;
        let fresh = self.said.1.is_some_and(|t| t.elapsed() < SAID_FOR);
        let shown = motion::tween_bool(ui.ctx(), ui.scope_id().with("said"), on && fresh && v.told.said.is_some(), motion::EMPHASIS, motion::STANDARD);
        if shown > 0.0 {
            if fresh {
                ui.ctx().request_repaint_after(Duration::from_millis(250));
            }
            let mut right = inner.right();
            if v.told.undo {
                let br = Rect::from_min_size(pos2(inner.right() - 84.0, y - 13.0), vec2(84.0, 26.0));
                if Btn::new("Undo").icon(Icon::Undo).quiet().size(11.0).enabled(shown > 0.5).show(ui, p, br, "show-undo").clicked() {
                    desk.show(ShowHand::Undo);
                }
                right = br.left() - 10.0;
            }
            if let Some(said) = &v.told.said {
                kit::clipped(p, pos2(inner.left(), y + 4.0 * (1.0 - shown)), said, 13.0, "", alpha_of(Color32::from_rgb(0xFC, 0xEB, 0xC0), shown), right - inner.left());
            }
        } else {
            kit::hint(p, pos2(inner.left(), y), Align2::LEFT_CENTER, if judges { "The director learns from these for the rest of the show" } else { "Judging works on a stage that is showing" });
        }
    }

    #[allow(clippy::type_complexity)]
    fn perform(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, v: &StageView) {
        kit::panel(p, r, false);
        let inner = r.shrink(t::INSET);
        let on = v.stages > 0;
        kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Perform");
        let gap = 8.0;
        let bw = (inner.width() - 3.0 * gap) / 4.0;
        let bh = ((inner.height() - 24.0 - gap) / 2.0).min(44.0);
        let at = |row: usize, i: usize| Rect::from_min_size(pos2(inner.left() + i as f32 * (bw + gap), inner.top() + 24.0 + row as f32 * (bh + gap)), vec2(bw, bh));
        let hands: [(&str, Icon, Tone, bool, Option<ShowHand>, &str); 8] = [
            ("Hit", Icon::Bolt, Tone::Neutral, false, Some(ShowHand::Hit), "The flash  (H)"),
            ("Next", Icon::Next, Tone::Neutral, false, Some(ShowHand::Next), "The next scene  (.)"),
            ("Back", Icon::Previous, Tone::Neutral, false, Some(ShowHand::Previous), "The scene before  (,)"),
            ("Mosh", Icon::Layers, Tone::Neutral, false, Some(ShowHand::Mosh), "The next scene, datamoshed in  (J)"),
            ("Hold", Icon::Lock, Tone::Neutral, v.held, Some(ShowHand::Hold(!v.held)), "The scene on, held  (L)"),
            // the strobe acts on press and release: worked below
            ("Strobe", Icon::Eye, Tone::Neutral, self.strobe, None, "The strobe, while held"),
            ("Freeze", Icon::Snow, Tone::Neutral, v.freeze, Some(ShowHand::Freeze(!v.freeze)), "The picture held still  (V)"),
            ("Black", Icon::Power, Tone::Danger, v.blackout, Some(ShowHand::Blackout(!v.blackout)), "Blackout  (B)"),
        ];
        for (i, (word, icon, tone, lit, hand, tip)) in hands.into_iter().enumerate() {
            let br = at(i / 4, i % 4);
            let b = Btn::new(word).icon(icon).tone(tone).on(lit && on).enabled(on).size(11.5);
            if hand.is_none() {
                let (id, resp) = kit::held(ui, br, "show-strobe");
                b.paint(ui, p, br, id, &resp);
                let down = on && resp.is_pointer_button_down_on();
                if down != self.strobe {
                    self.strobe = down;
                    desk.show(ShowHand::Strobe(down));
                }
                continue;
            }
            if b.show(ui, p, br, ("perform", i)).on_hover_text(tip).clicked()
                && let Some(h) = hand
            {
                desk.show(h);
            }
        }
    }

    fn holds_sets_screens(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, v: &StageView) {
        kit::panel(p, r, false);
        let inner = r.shrink(t::INSET);
        let clip = p.with_clip_rect(r);
        let p = &clip;
        let on = v.stages > 0 && !v.untold;
        let label_w = 70.0;
        let mut y = inner.top();

        // what the hands hold
        kit::section(p, pos2(inner.left(), y + 12.0), Align2::LEFT_CENTER, "Held");
        let held = v.told.holds;
        let words = match (on, held) {
            (false, _) => "—".to_owned(),
            (true, 0) => "nothing: the director has it all".to_owned(),
            (true, 1) => "one thing".to_owned(),
            (true, n) => format!("{n} things"),
        };
        kit::clipped(p, pos2(inner.left() + label_w, y + 12.0), &words, 13.0, "", t::muted(), inner.width() - label_w - 120.0);
        if on && held > 0 {
            let br = Rect::from_min_size(pos2(inner.right() - 108.0, y), vec2(108.0, 26.0));
            if Btn::new("Let go all").icon(Icon::Close).size(11.0).show(ui, p, br, "show-letgo").clicked() {
                desk.show(ShowHand::LetGo);
            }
        }
        y += 38.0;

        // the sets
        kit::section(p, pos2(inner.left(), y + 13.0), Align2::LEFT_CENTER, "Set");
        let mut sets: Vec<(String, String)> = vec![(String::new(), "As shipped".to_owned())];
        sets.extend(v.told.sets.iter().map(|s| (s.id.clone(), s.name.clone())));
        let on_set = v.told.set.clone().unwrap_or_default();
        let picked;
        (y, picked) = chips(ui, p, Rect::from_min_max(pos2(inner.left() + label_w, y), inner.max), on, &sets, &on_set, "set");
        if let Some(id) = picked {
            desk.show(ShowHand::Set(id));
        }
        y += 12.0;

        // the screen the show fills
        kit::section(p, pos2(inner.left(), y + 13.0), Align2::LEFT_CENTER, "Screen");
        let mut screens: Vec<(String, String)> = vec![(String::new(), "Window".to_owned())];
        screens.extend(v.told.screens.iter().map(|s| (s.name.clone(), format!("{} {}×{}", s.name, s.w, s.h))));
        let on_screen = if v.told.full { v.told.screen.clone().unwrap_or_else(|| "?".into()) } else { String::new() };
        let shown_on = if v.stages > 0 { on_screen } else { v.kept_screen.clone().unwrap_or_default() };
        let picked;
        (y, picked) = chips(ui, p, Rect::from_min_max(pos2(inner.left() + label_w, y), inner.max), on, &screens, &shown_on, "screen");
        if let Some(name) = picked {
            desk.show(if name.is_empty() { ShowHand::Full(false) } else { ShowHand::Screen(name) });
        }
        if !on && let Some(k) = &v.kept_screen {
            kit::clipped(p, pos2(inner.left() + label_w, y + 12.0), &format!("opens full screen on {k}"), 12.0, "", t::faint(), inner.width() - label_w);
            y += 18.0;
        }

        // which stage: the WetOwl app's, or the Rust one (the Desk directing)
        if v.rust_here {
            y += 12.0;
            kit::section(p, pos2(inner.left(), y + 13.0), Align2::LEFT_CENTER, "Stage");
            let seg = Rect::from_min_size(pos2(inner.left() + label_w, y), vec2((inner.width() - label_w).min(300.0), 26.0));
            let names = ["WetOwl app", &format!("Rust · {} scenes", wo_deskcore::RUST_SCENES.len())];
            if let Some(i) = kit::segmented(ui, p, seg, &names, Some(v.rust as usize), Tone::Neutral, "stage-kind") {
                desk.set_rust_stage(i == 1);
            }
            y += 26.0;
            if v.rust && let Some(why) = &v.why {
                kit::clipped(p, pos2(inner.left() + label_w, y + 14.0), why, 12.0, "", t::faint(), inner.width() - label_w);
            }
        }
    }

    /// MilkDrop on the Rust stage: the preset on, and the hands on it.
    fn milk_card(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        kit::panel(p, r, false);
        let inner = r.shrink(t::INSET);
        kit::section(p, inner.left_top(), Align2::LEFT_TOP, "MilkDrop");
        let m = desk.milk();
        if m.on {
            kit::text(p, pos2(inner.right(), inner.top() + 6.0), Align2::RIGHT_CENTER, &format!("{:.0} fps", m.fps), 11.0, "mono", t::muted());
        }
        let (words, ink) = if m.presets == 0 {
            ("No presets here".to_owned(), t::faint())
        } else if !m.ok {
            ("The stage has no MilkDrop helper (wetowl-milk)".to_owned(), t::faint())
        } else if let Some(tr) = &m.trouble {
            (tr.clone(), t::warm())
        } else {
            (m.preset.clone().unwrap_or_else(|| "—".into()), t::text())
        };
        let g = p.layout(words, egui::FontId::new(13.0, crate::paint::family("")), ink, inner.width());
        let rows = g.rows.len().min(2);
        let clipped = p.with_clip_rect(Rect::from_min_size(pos2(inner.left(), inner.top() + 26.0), vec2(inner.width(), 18.0 * rows as f32 + 2.0)));
        clipped.galley(pos2(inner.left(), inner.top() + 26.0), g, ink);
        if m.presets == 0 || !m.ok {
            return;
        }
        let hands: [(Icon, MilkHand, bool, &str); 8] = [
            (Icon::Previous, MilkHand::Previous, false, "The preset before"),
            (Icon::Next, MilkHand::Next, false, "The next preset"),
            (Icon::Shuffle, MilkHand::Another, false, "Another, at random"),
            (if m.favourite { Icon::HeartFull } else { Icon::Heart }, MilkHand::Favourite, m.favourite, "A favourite: comes more often"),
            (Icon::Close, MilkHand::Off, false, "Never this one again"),
            (Icon::Lock, MilkHand::Lock(!m.locked), m.locked, "Held: the director leaves it on"),
            (Icon::Bolt, MilkHand::Accents(!m.accents), m.accents, "The beat on it (accents)"),
            (Icon::Layers, MilkHand::Release, self.milk_list, "The library"),
        ];
        let n = hands.len() as f32;
        let gap = 4.0;
        let bw = ((inner.width() - (n - 1.0) * gap) / n).min(40.0);
        let y = inner.bottom() - 32.0;
        let mut list_btn = Rect::NOTHING;
        for (i, (icon, hand, lit, tip)) in hands.into_iter().enumerate() {
            let br = Rect::from_min_size(pos2(inner.left() + i as f32 * (bw + gap), y), vec2(bw, 32.0));
            let resp = Btn::new("").icon(icon).on(lit).show(ui, p, br, ("milk", i)).on_hover_text(tip);
            if i == 7 {
                list_btn = br;
                if resp.clicked() {
                    self.milk_list = !self.milk_list;
                }
            } else if resp.clicked() {
                desk.milk_hand(hand);
            }
        }
        self.milk_library(desk, ui, r, list_btn);
    }

    /// MilkDrop's library, over the page by its card: searched, a preset put on (and
    /// held), a favourite or switched off.
    fn milk_library(&mut self, desk: &mut Desk, ui: &mut Ui, card: Rect, button: Rect) {
        let ctx = ui.ctx().clone();
        let k = motion::tween_bool(&ctx, egui::Id::unique("milk-list"), self.milk_list, motion::STANDARD, 0.12);
        if k <= 0.0 {
            return;
        }
        let size = vec2(440.0, 520.0f32.min(card.top() - 80.0).max(300.0));
        let at = pos2((card.right() - size.x).max(12.0), card.top() - size.y - 8.0 + 4.0 * (1.0 - k));
        let area = egui::Area::new(egui::Id::unique("milk-library")).order(egui::Order::Foreground).fixed_pos(at).show(&ctx, |ui| {
            ui.multiply_opacity(k);
            let (r, _) = ui.allocate_exact_size(size, Sense::click());
            let p = ui.painter().clone();
            p.add(t::shadow(2).as_shape(r, CornerRadius::same(t::R_OVERLAY)));
            p.rect(r, CornerRadius::same(t::R_OVERLAY), Color32::from_rgb(16, 17, 22), Stroke::new(1.0, white(0.11)), StrokeKind::Inside);
            let inner = r.shrink(t::INSET);
            kit::section(&p, inner.left_top(), Align2::LEFT_TOP, "MilkDrop presets");
            let close = Rect::from_min_size(pos2(inner.right() - 26.0, inner.top() - 6.0), vec2(26.0, 26.0));
            if Btn::new("").icon(Icon::Close).quiet().show(ui, &p, close, "milk-close").clicked() {
                self.milk_list = false;
            }
            let field = Rect::from_min_size(pos2(inner.left(), inner.top() + 26.0), vec2(inner.width(), 32.0));
            kit::field(ui, &p, field, &mut self.milk_query, "Search the presets", Some(Icon::Search), false, "milk-search");
            let rows = desk.milk_search(&self.milk_query, 1000);
            kit::hint(&p, pos2(inner.left(), field.bottom() + 14.0), Align2::LEFT_CENTER, &format!("{} presets · a click puts one on, held until a drop", rows.len()));
            let list = Rect::from_min_max(pos2(r.left() + 4.0, field.bottom() + 28.0), pos2(r.right() - 4.0, r.bottom() - 8.0));
            let mut child = ui.new_child(egui::UiBuilder::new().max_rect(list));
            egui::ScrollArea::vertical().id_salt("milk-rows").auto_shrink([false, false]).show_rows(&mut child, 30.0, rows.len(), |ui, range| {
                for row in &rows[range] {
                    let (rr, resp) = ui.allocate_exact_size(vec2(list.width(), 30.0), Sense::click());
                    let p = ui.painter().clone();
                    let h = motion::tween_bool(ui.ctx(), resp.id.with("h"), resp.hovered(), motion::QUICK, motion::STANDARD);
                    if row.on {
                        p.rect_filled(rr.shrink2(vec2(6.0, 1.0)), CornerRadius::same(t::R_CONTROL), white(0.08));
                    } else if h > 0.0 {
                        p.rect_filled(rr.shrink2(vec2(6.0, 1.0)), CornerRadius::same(t::R_CONTROL), white(0.045 * h));
                    }
                    let heart = Rect::from_center_size(pos2(rr.left() + 24.0, rr.center().y), vec2(24.0, 24.0));
                    let hr = ui.interact(heart, resp.id.with("fave"), Sense::click()).on_hover_text("A favourite: comes more often");
                    crate::ui::icons::paint(&p, heart.shrink(5.0), if row.favourite { Icon::HeartFull } else { Icon::Heart }, if row.favourite { t::hot() } else if hr.hovered() { t::soft() } else { t::faint() });
                    let off = Rect::from_center_size(pos2(rr.right() - 34.0, rr.center().y), vec2(40.0, 20.0));
                    let or = kit::chip(ui, &p, off, "Off", row.off, Tone::Danger, true, ("off", &row.path)).on_hover_text("Never put on by the director");
                    let ink = if row.off { t::faint() } else if row.on { t::high() } else { t::text() };
                    kit::clipped(&p, pos2(rr.left() + 44.0, rr.center().y), &row.name, 13.0, "", ink, off.left() - rr.left() - 56.0);
                    if hr.clicked() {
                        desk.milk_hand(MilkHand::FavouriteOf(row.path.clone()));
                    } else if or.clicked() {
                        desk.milk_hand(MilkHand::OffOf(row.path.clone()));
                    } else if resp.clicked() {
                        desk.milk_hand(MilkHand::Pick(row.path.clone()));
                    }
                }
            });
        });
        // a click away closes it
        let away = ctx.input(|i| i.pointer.any_pressed()) && ctx.pointer_latest_pos().is_some_and(|pos| !area.response.rect.contains(pos) && !button.contains(pos));
        if self.milk_list && away {
            self.milk_list = false;
        }
    }
}

/// Chips in rows within `r`: (key, words); the one whose key is `on` lit. The bottom of the
/// last row, and the key of a chip clicked.
fn chips(ui: &mut Ui, p: &Painter, r: Rect, usable: bool, items: &[(String, String)], on: &str, id: &str) -> (f32, Option<String>) {
    let mut picked = None;
    let (h, gap) = (26.0, 6.0);
    let (mut x, mut y) = (r.left(), r.top());
    for (key, words) in items {
        let w = kit::chip_width(p, words).min(r.width());
        if x + w > r.right() && x > r.left() {
            x = r.left();
            y += h + gap;
        }
        let cr = Rect::from_min_size(pos2(x, y), vec2(w, h));
        if kit::chip(ui, p, cr, words, key == on, Tone::Neutral, usable, (id, key)).clicked() {
            picked = Some(key.clone());
        }
        x += w + gap;
    }
    (y + h, picked)
}
