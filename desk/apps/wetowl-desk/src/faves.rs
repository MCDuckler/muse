//! The Show page's favourites and sets (v1: show_room_faves.dart, show_room_snapshots.dart):
//! the favourites as a grid of their pictures — newest or best first, the fewest stars to
//! show, one scene's — a click puts one on the stage, held (again: let go), ◀ ▶ step through
//! them, the stars under each rate it, a right click names or forgets it; the sets as chips,
//! this Desk's and the shared ones, with SAVE, SAVE AS and their menu; a name asked for in a
//! small window of its own.
use std::collections::HashMap;
use std::path::PathBuf;

use eframe::egui::{self, Align2, Color32, CornerRadius, Painter, Pos2, Rect, Sense, Shape, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::{Desk, FaveEdit, FaveRow, SetEdit, SetsView, ShowEdit, ShowHand};

use crate::App;
use crate::paint::white;
use crate::stills::StillKey;
use crate::ui::icons::Icon;
use crate::ui::kit::{self, Btn};
use crate::ui::tokens::{self as t, Tone};

/// The favourites room's own state.
#[derive(Default)]
pub(crate) struct FavesUi {
    /// The most stars first (else the newest).
    pub best: bool,
    /// The fewest stars shown (0: all, the unrated too).
    pub least: u8,
    pub scene: Option<String>,
    /// The pictures read so far (None: none there).
    pics: HashMap<PathBuf, Option<egui::TextureHandle>>,
}

/// What a name is asked for.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum PromptFor {
    SaveAs,
    RenameSet(String),
    RenameFave(String),
}

pub(crate) struct Prompt {
    pub what: PromptFor,
    pub title: String,
    pub hint: String,
    pub text: String,
    /// The field to be focused on the first frame.
    pub fresh: bool,
}

impl Prompt {
    pub fn new(what: PromptFor, title: &str, hint: &str, text: &str) -> Prompt {
        Prompt { what, title: title.into(), hint: hint.into(), text: text.into(), fresh: true }
    }
}

/// A five-pointed star's outline about `c`.
fn star_points(c: Pos2, r: f32) -> Vec<Pos2> {
    (0..10)
        .map(|i| {
            let a = -std::f32::consts::FRAC_PI_2 + i as f32 * std::f32::consts::PI / 5.0;
            let rr = if i % 2 == 0 { r } else { r * 0.45 };
            pos2(c.x + rr * a.cos(), c.y + rr * a.sin())
        })
        .collect()
}

/// Five stars from `at` (the first's centre), `n` lit: a click on one rates it so (on the one
/// lit last: none). The rating clicked, if one was.
pub(crate) fn stars(ui: &mut Ui, p: &Painter, at: Pos2, n: u8, r: f32, id: impl std::hash::Hash + std::fmt::Debug + Copy) -> Option<u8> {
    let mut out = None;
    let step = r * 2.4;
    let all = Rect::from_min_max(at - vec2(r, r), at + vec2(step * 4.0 + r, r));
    let hover = ui.interact(all.expand(2.0), ui.scope_id().with(("stars", id)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
    let over = hover.hover_pos().map(|h| (((h.x - all.left()) / step).floor() as i32).clamp(0, 4) as u8 + 1);
    if hover.clicked()
        && let Some(k) = over
    {
        out = Some(if k == n { 0 } else { k });
    }
    for i in 0..5u8 {
        let c = at + vec2(i as f32 * step, 0.0);
        let lit = i < over.unwrap_or(n);
        let pts = star_points(c, r);
        if lit {
            let col = if over.is_some() { Color32::from_rgb(0xFF, 0xD8, 0x7A) } else { Color32::from_rgb(0xF5, 0xC4, 0x4A) };
            // a star is not convex: drawn as a fan of its five points round the middle
            for k in 0..5 {
                let tri = vec![c, pts[k * 2], pts[(k * 2 + 1) % 10]];
                p.add(Shape::convex_polygon(tri, col, Stroke::NONE));
                let tri = vec![c, pts[(k * 2 + 1) % 10], pts[(k * 2 + 2) % 10]];
                p.add(Shape::convex_polygon(tri, col, Stroke::NONE));
            }
        } else {
            let mut ring = pts.clone();
            ring.push(pts[0]);
            p.add(Shape::line(ring, Stroke::new(1.0, white(0.3))));
        }
    }
    out
}

impl App {
    /// The favourites: a grid of their pictures, filtered and stepped through.
    pub(crate) fn faves_room(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        kit::panel(p, r, false);
        let view = desk.show_faves();
        let inner = r.shrink(t::INSET);
        let fu = &mut self.faves_ui;
        let mut shown: Vec<&FaveRow> = view.faves.iter().filter(|f| f.stars >= fu.least && fu.scene.as_ref().is_none_or(|s| *s == f.scene)).collect();
        if fu.best {
            shown.sort_by(|a, b| b.stars.cmp(&a.stars).then(b.at.cmp(&a.at)));
        }
        // the heading: how many, newest or best, the stars, ◀ ▶
        let mut y = inner.top() - 4.0;
        let count = if shown.len() == view.faves.len() { format!("{}", view.faves.len()) } else { format!("{} of {}", shown.len(), view.faves.len()) };
        let hr = kit::section(p, pos2(inner.left(), y + 13.0), Align2::LEFT_CENTER, "Favourites");
        kit::text(p, pos2(hr.right() + 8.0, y + 13.0), Align2::LEFT_CENTER, &count, 11.0, "mono", t::muted());
        let mut x = hr.right() + 60.0;
        let seg = Rect::from_min_size(pos2(x, y), vec2(150.0, 26.0));
        if let Some(i) = kit::segmented(ui, p, seg, &["Newest", "Best"], Some(usize::from(fu.best)), Tone::Neutral, "faves-order") {
            fu.best = i == 1;
        }
        x = seg.right() + 14.0;
        for n in 0..=5u8 {
            let word = if n == 0 { "All".to_owned() } else { format!("{}{}", "★".repeat(n as usize), if n < 5 { "+" } else { "" }) };
            let w = kit::chip_width(p, &word) + 4.0;
            let cr = Rect::from_min_size(pos2(x, y + 2.0), vec2(w, 22.0));
            if kit::chip(ui, p, cr, &word, fu.least == n, Tone::Neutral, true, ("least", n)).on_hover_text(if n == 0 { "Every one, the unrated too".to_owned() } else { format!("Only those with {n} star{} or more", if n == 1 { "" } else { "s" }) }).clicked() {
                fu.least = n;
            }
            x += w + 4.0;
        }
        let step = |by: i32, shown: &[&FaveRow]| -> Option<String> {
            if shown.is_empty() {
                return None;
            }
            let i = shown.iter().position(|f| Some(&f.id) == view.on.as_ref());
            let n = shown.len() as i32;
            let k = match i {
                None if by > 0 => 0,
                None => n - 1,
                Some(i) => (i as i32 + by).rem_euclid(n),
            };
            Some(shown[k as usize].id.clone())
        };
        let nr = Rect::from_min_size(pos2(inner.right() - 30.0, y), vec2(30.0, 26.0));
        let pr = Rect::from_min_size(pos2(nr.left() - 34.0, y), vec2(30.0, 26.0));
        if Btn::new("").icon(Icon::ChevronLeft).enabled(!shown.is_empty()).show(ui, p, pr, "fave-prev").on_hover_text("The one before, on the stage").clicked()
            && let Some(id) = step(-1, &shown)
        {
            desk.show(ShowHand::Fave(id));
        }
        if Btn::new("").icon(Icon::ChevronRight).enabled(!shown.is_empty()).show(ui, p, nr, "fave-next").on_hover_text("The next one, on the stage").clicked()
            && let Some(id) = step(1, &shown)
        {
            desk.show(ShowHand::Fave(id));
        }
        y += 34.0;
        // one scene's only
        if view.scenes.len() > 1 {
            let mut x = inner.left();
            let mut chip = |ui: &mut Ui, word: &str, on: bool, id: &str| {
                let w = kit::chip_width(p, word) + 4.0;
                let cr = Rect::from_min_size(pos2(x, y), vec2(w, 22.0));
                x += w + 4.0;
                kit::chip(ui, p, cr, word, on, Tone::Neutral, true, ("fave-scene", id.to_owned())).clicked()
            };
            if chip(ui, "Any scene", fu.scene.is_none(), "") {
                fu.scene = None;
            }
            for (id, name) in &view.scenes {
                if chip(ui, name, fu.scene.as_ref() == Some(id), id) {
                    fu.scene = if fu.scene.as_ref() == Some(id) { None } else { Some(id.clone()) };
                }
            }
            y += 30.0;
        }
        // the one on, held; the last one forgotten
        if let Some(on) = view.on.as_ref().and_then(|id| view.faves.iter().find(|f| &f.id == id)) {
            kit::on_air(p, pos2(inner.left() + 6.0, y + 12.0), 12.0);
            kit::clipped(p, pos2(inner.left() + 16.0, y + 12.0), &format!("On the stage, held: {}", on.title), 12.5, "", t::text(), inner.width() - 130.0);
            let br = Rect::from_min_size(pos2(inner.right() - 100.0, y), vec2(100.0, 24.0));
            if Btn::new("Let go").size(11.0).tone(Tone::Danger).accent(true).show(ui, p, br, "fave-let-go").on_hover_text("Back to the rotation").clicked() {
                desk.show(ShowHand::LetGo);
            }
            y += 32.0;
        }
        if let Some(u) = &view.undo {
            kit::clipped(p, pos2(inner.left(), y + 12.0), u, 12.0, "", t::soft(), inner.width() - 100.0);
            let br = Rect::from_min_size(pos2(inner.right() - 84.0, y), vec2(84.0, 24.0));
            if Btn::new("Undo").icon(Icon::Undo).quiet().size(11.0).show(ui, p, br, "fave-undo").clicked() {
                desk.show_edit(ShowEdit::Fave(FaveEdit::Undo));
            }
            y += 32.0;
        }
        let area = Rect::from_min_max(pos2(r.left() + 2.0, y + 4.0), pos2(r.right() - 2.0, r.bottom() - 4.0));
        if view.faves.is_empty() {
            kit::hint(p, area.center() - vec2(0.0, 10.0), Align2::CENTER_CENTER, "Nothing kept yet. KEEP (Judge the look) keeps what is on the stage as it is —");
            kit::hint(p, area.center() + vec2(0.0, 10.0), Align2::CENTER_CENTER, "the combination, the MilkDrop preset, the camera");
            return;
        }
        if shown.is_empty() {
            kit::hint(p, area.center(), Align2::CENTER_CENTER, "None with these stars");
            return;
        }
        // the grid
        let gap = 10.0;
        let w = area.width() - 2.0 * (t::INSET - 2.0) - 10.0;
        let cols = (((w + gap) / (190.0 + gap)).floor() as usize).max(1);
        let tw = (w - gap * (cols - 1) as f32) / cols as f32;
        let th = tw * 9.0 / 16.0 + 50.0;
        let strength = desk.show_finish().strength;
        let shown: Vec<FaveRow> = shown.into_iter().cloned().collect();
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(area));
        egui::ScrollArea::vertical().id_salt("faves").auto_shrink([false, false]).show(&mut child, |ui| {
            let top = ui.cursor().top() + 4.0;
            let x0 = area.left() + t::INSET - 2.0;
            let p = ui.painter().clone();
            let clip = ui.clip_rect();
            self.scene_ui.stills.frame();
            for (i, f) in shown.iter().enumerate() {
                let tr = Rect::from_min_size(pos2(x0 + (i % cols) as f32 * (tw + gap), top + (i / cols) as f32 * (th + gap)), vec2(tw, th));
                if !clip.intersects(tr) {
                    continue;
                }
                self.fave_tile(desk, ui, &p, tr, f, view.on.as_deref() == Some(f.id.as_str()), strength);
            }
            let rows = shown.len().div_ceil(cols);
            ui.allocate_exact_size(vec2(area.width() - 10.0, rows as f32 * (th + gap) + 8.0), Sense::hover());
        });
    }

    #[allow(clippy::too_many_arguments)]
    fn fave_tile(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, f: &FaveRow, on: bool, strength: f64) {
        let resp = ui.interact(r, ui.scope_id().with(("fave-tile", &f.id)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
        let cr = CornerRadius::same(6);
        p.rect_filled(r, cr, if resp.hovered() { white(0.06) } else { white(0.03) });
        p.rect_stroke(r, cr, Stroke::new(if on { 1.5 } else { 1.0 }, if on { t::red() } else { white(0.07) }), StrokeKind::Inside);
        let pic = Rect::from_min_size(r.min + vec2(3.0, 3.0), vec2(r.width() - 6.0, (r.width() - 6.0) * 9.0 / 16.0));
        p.rect_filled(pic, CornerRadius::same(4), Color32::BLACK);
        // its picture as kept; else the look's still
        let tex = match &f.picture {
            Some(path) => self
                .faves_ui
                .pics
                .entry(path.clone())
                .or_insert_with(|| {
                    let img = image::open(path).ok()?.to_rgba8();
                    let ci = egui::ColorImage::from_rgba_unmultiplied([img.width() as usize, img.height() as usize], img.as_raw());
                    Some(ui.ctx().load_texture(format!("fave {}", path.display()), ci, egui::TextureOptions::LINEAR))
                })
                .clone(),
            None => {
                let key = StillKey { figure: f.figure.clone(), style: f.style.clone(), ground: f.ground.clone(), mask: f.mask.clone(), mix: f.mix.clone(), strength: (strength * 100.0).round().clamp(0.0, 100.0) as u8 };
                crate::stills::Stills::has(&f.figure, &f.style).then(|| self.scene_ui.stills.get(ui.ctx(), &key)).flatten()
            }
        };
        if let Some(tex) = tex {
            p.add(egui::epaint::RectShape::filled(pic, CornerRadius::same(4), Color32::WHITE).with_texture(tex.id(), Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0))));
        }
        if on {
            kit::on_air(p, pic.right_top() + vec2(-11.0, 11.0), 13.0);
        }
        kit::clipped(p, pos2(r.left() + 8.0, pic.bottom() + 14.0), &f.title, 12.5, "", if on { t::high() } else { t::text() }, r.width() - 16.0);
        if let Some(n) = stars(ui, p, pos2(r.left() + 14.0, pic.bottom() + 34.0), f.stars, 6.5, ("fave", f.id.as_str())) {
            desk.show_edit(ShowEdit::Fave(FaveEdit::Stars(f.id.clone(), n)));
        }
        let resp = resp.on_hover_text(format!("{}\n{}", f.words, if on { "A click: let go" } else { "A click: on the stage, held · a right click: name it, forget it" }));
        if resp.clicked() {
            desk.show(if on { ShowHand::LetGo } else { ShowHand::Fave(f.id.clone()) });
        }
        resp.context_menu(|ui| {
            if ui.button("Name it…").clicked() {
                self.prompt = Some(Prompt::new(PromptFor::RenameFave(f.id.clone()), "Name it", "A name of your own for this favourite", &f.title));
                ui.close();
            }
            if ui.button("Forget it").clicked() {
                desk.show_edit(ShowEdit::Fave(FaveEdit::Forget(f.id.clone())));
                ui.close();
            }
        });
    }

    /// The sets: this Desk's and the shared ones, SAVE, SAVE AS, their menu; a shared one
    /// saved over since, said; UNDO.
    pub(crate) fn sets_panel(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let v: SetsView = desk.show_sets();
        let mut x = r.left();
        let mut y = r.top();
        let row_h = 28.0;
        let chip = |ui: &mut Ui, x: &mut f32, y: &mut f32, word: &str, on: bool, id: &str, tip: String| {
            let w = kit::chip_width(p, word) + 6.0;
            if *x + w > r.right() - 4.0 && *x > r.left() {
                *x = r.left();
                *y += row_h;
            }
            let cr = Rect::from_min_size(pos2(*x, *y), vec2(w, 24.0));
            *x += w + 5.0;
            kit::chip(ui, p, cr, word, on, Tone::Neutral, true, ("set", id.to_owned())).on_hover_text(tip).clicked()
        };
        let mark = |s: bool, n: &str, on: bool| format!("{}{n}{}", if s { "👥 " } else { "" }, if on && v.changed { " •" } else { "" });
        if chip(ui, &mut x, &mut y, &mark(false, "As shipped", v.on.is_none()), v.on.is_none(), "", "No set: the show as the app came".into()) && v.on.is_some() {
            desk.show_edit(ShowEdit::Set(SetEdit::Use(None)));
        }
        for s in &v.sets {
            let tip = if s.shared {
                format!("Shared by {}{}", if s.mine { "you".to_owned() } else { s.owner.clone().unwrap_or_else(|| "someone".into()) }, s.updated_by.as_ref().map(|u| format!(", last saved by {u}")).unwrap_or_default())
            } else {
                "On this Desk".to_owned()
            };
            if chip(ui, &mut x, &mut y, &mark(s.shared, &s.name, s.on), s.on, &s.id, tip) && !s.on {
                desk.show_edit(ShowEdit::Set(SetEdit::Use(Some(s.id.clone()))));
            }
        }
        if v.loading {
            kit::text(p, pos2(x + 4.0, y + 12.0), Align2::LEFT_CENTER, "…", 13.0, "", t::faint());
        }
        y += row_h + 6.0;
        // SAVE, SAVE AS, the menu
        let save = Rect::from_min_size(pos2(r.left(), y), vec2(90.0, 26.0));
        let can = v.on.is_some() && v.changed;
        let tip = match &v.on {
            None => "Switch to a set or SAVE AS one first".to_owned(),
            Some(s) if s.shared => format!("The show as it is over {}, for everyone", s.name),
            Some(s) => format!("The show as it is over {}", s.name),
        };
        if Btn::new("Save").accent(can).enabled(can).size(11.0).show(ui, p, save, "set-save").on_hover_text(tip).clicked() {
            desk.show_edit(ShowEdit::Set(SetEdit::Save));
        }
        let save_as = Rect::from_min_size(pos2(save.right() + 6.0, y), vec2(100.0, 26.0));
        if Btn::new("Save as…").size(11.0).show(ui, p, save_as, "set-save-as").on_hover_text("The show as it is, kept as a new set: how often everything comes, the effects, the temper, the knobs, the finish").clicked() {
            self.prompt = Some(Prompt::new(PromptFor::SaveAs, "Save the show as a set", "Switch back to it in a tap", ""));
        }
        let more = Rect::from_min_size(pos2(save_as.right() + 6.0, y), vec2(34.0, 26.0));
        let resp = Btn::new("⋯").size(13.0).show(ui, p, more, "set-more").on_hover_text("Rename, share, forget");
        let on = v.on.clone();
        egui::Popup::menu(&resp).show(|ui| {
            if let Some(s) = &on {
                if !s.shared && ui.button(format!("Rename {}…", s.name)).clicked() {
                    self.prompt = Some(Prompt::new(PromptFor::RenameSet(s.id.clone()), "Rename", "", &s.name));
                }
                if !s.shared && ui.add_enabled(v.house, egui::Button::new("Share it with everyone")).on_disabled_hover_text("Sign in to the house first").clicked() {
                    desk.show_edit(ShowEdit::Set(SetEdit::Share(s.id.clone())));
                }
                if s.shared && s.mine && ui.button("Keep it on this Desk only").clicked() {
                    desk.show_edit(ShowEdit::Set(SetEdit::Unshare(s.id.clone())));
                }
                if !s.shared && ui.button(format!("Forget {}", s.name)).clicked() {
                    desk.show_edit(ShowEdit::Set(SetEdit::Forget(s.id.clone())));
                }
                ui.separator();
            }
            if ui.add_enabled(v.house, egui::Button::new("List the shared ones again")).clicked() {
                desk.show_edit(ShowEdit::Set(SetEdit::Reload));
            }
        });
        y += 34.0;
        // a shared one saved over since; UNDO; what was said; why the house could not
        if let Some((name, by)) = &v.conflict {
            kit::clipped(p, pos2(r.left(), y + 12.0), &format!("{} saved {name} since you switched to it", by.as_deref().unwrap_or("Someone")), 12.0, "", t::text(), r.width() - 220.0);
            let a = Rect::from_min_size(pos2(r.right() - 214.0, y), vec2(104.0, 24.0));
            if Btn::new("Take theirs").size(10.5).show(ui, p, a, "set-theirs").clicked() {
                desk.show_edit(ShowEdit::Set(SetEdit::TakeTheirs));
            }
            let b = Rect::from_min_size(pos2(r.right() - 104.0, y), vec2(104.0, 24.0));
            if Btn::new("Save over it").tone(Tone::Danger).accent(true).size(10.5).show(ui, p, b, "set-ours").clicked() {
                desk.show_edit(ShowEdit::Set(SetEdit::SaveOver));
            }
            y += 30.0;
        }
        if let Some(u) = &v.undo {
            kit::clipped(p, pos2(r.left(), y + 12.0), u, 12.0, "", t::soft(), r.width() - 96.0);
            let br = Rect::from_min_size(pos2(r.right() - 84.0, y), vec2(84.0, 24.0));
            if Btn::new("Undo").icon(Icon::Undo).quiet().size(11.0).show(ui, p, br, "set-undo").clicked() {
                desk.show_edit(ShowEdit::Set(SetEdit::Undo));
            }
            y += 30.0;
        }
        let note = v.trouble.clone().or(v.said.clone()).or_else(|| (!v.house).then(|| "Signed in to the house, the shared sets are here too".to_owned()));
        if let Some(n) = note {
            kit::clipped(p, pos2(r.left(), y + 10.0), &n, 11.5, "", if v.trouble.is_some() { t::red() } else { t::faint() }, r.width());
        }
    }

    /// A name asked for, in a window over everything: Enter or OK keeps it, Esc lets it go.
    pub(crate) fn prompt_window(&mut self, desk: &mut Desk, ctx: &egui::Context, full: Rect) {
        let Some(pr) = &mut self.prompt else { return };
        let mut done: Option<bool> = None;
        egui::Area::new(egui::Id::unique("prompt")).order(egui::Order::Foreground).fixed_pos(full.min).show(ctx, |ui| {
            let (all, _) = ui.allocate_exact_size(full.size(), Sense::click());
            let p = ui.painter().clone();
            let card = kit::modal(&p, all, vec2(420.0, 168.0), 1.0);
            ui.interact(card, ui.scope_id().with("prompt-card"), Sense::click());
            let inner = card.shrink(20.0);
            kit::text(&p, inner.min, Align2::LEFT_TOP, &pr.title, 15.0, "label", t::high());
            if !pr.hint.is_empty() {
                kit::hint(&p, inner.min + vec2(0.0, 26.0), Align2::LEFT_TOP, &pr.hint);
            }
            let fr = Rect::from_min_size(pos2(inner.left(), inner.top() + 50.0), vec2(inner.width(), 32.0));
            let resp = kit::field(ui, &p, fr, &mut pr.text, "Name", None, false, "prompt-field");
            if pr.fresh {
                resp.request_focus();
                pr.fresh = false;
            }
            let ok = Rect::from_min_size(pos2(inner.right() - 90.0, inner.bottom() - 30.0), vec2(90.0, 30.0));
            let cancel = Rect::from_min_size(pos2(ok.left() - 98.0, ok.top()), vec2(90.0, 30.0));
            let enter = ui.input(|i| i.key_pressed(egui::Key::Enter));
            if Btn::new("OK").accent(true).enabled(!pr.text.trim().is_empty()).size(11.0).show(ui, &p, ok, "prompt-ok").clicked() || (enter && !pr.text.trim().is_empty()) {
                done = Some(true);
            }
            if Btn::new("Cancel").quiet().size(11.0).show(ui, &p, cancel, "prompt-cancel").clicked() || ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                done = Some(false);
            }
        });
        if let Some(keep) = done {
            let pr = self.prompt.take().expect("asked");
            if keep {
                let name = pr.text.trim().to_owned();
                desk.show_edit(match pr.what {
                    PromptFor::SaveAs => ShowEdit::Set(SetEdit::SaveAs(name)),
                    PromptFor::RenameSet(id) => ShowEdit::Set(SetEdit::Rename(id, name)),
                    PromptFor::RenameFave(id) => ShowEdit::Fave(FaveEdit::Rename(id, name)),
                });
            }
        }
    }
}
