//! A scene's page, from the Rotation (v1: show_room_scene.dart, show_room_grid.dart): how
//! often it comes; its styles, each a level with its knobs; the backgrounds, masks, blends and
//! effects as every scene has them or its own; the grid of its looks, style by background,
//! each square the scene in that style on that background blended the stage's way — a click:
//! never, or back; a right click: less, more, as it was, play it, each mask and blend; its
//! camera's framings; the dancers' moves. PLAY IT puts one of its looks on; COPY FROM makes
//! it like another scene.
use eframe::egui::{self, Align2, Color32, CornerRadius, Painter, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::move_player::{MoveLook, MovePlayer};
use wo_deskcore::{Desk, MovesView, OwnRows, ScenePage, ShowEdit, Square, SquareDo, Variants, level_word, share_word};

use crate::App;
use crate::paint::white;
use crate::rotation::{RowEdit, head, level_row, tune_knobs};
use crate::stills::{StillKey, Stills};
use crate::ui::icons::Icon;
use crate::ui::kit::{self, Btn};
use crate::ui::tokens::{self as t, Tone};

const ROW: f32 = 30.0;
const HEAD: f32 = 34.0;
const NAME_W: f32 = 96.0;
/// The moves' viewer's height; a strip's poses, each so big.
const VIEW_H: f32 = 300.0;
const STRIP_N: usize = 6;
const STRIP_W: f32 = 24.0;
const STRIP_H: f32 = 44.0;

/// The dancers as read on a thread, and their skins' pixels.
type Loaded = (Option<std::sync::Arc<MovePlayer>>, Vec<Option<(u32, u32, Vec<u8>)>>);

/// The page's own state: the grid with the off styles and backgrounds too, the style whose
/// knobs are open, one square's masks and blends open, the moves' filters.
#[derive(Default)]
pub(crate) struct SceneUi {
    pub all: bool,
    pub knobs: Option<String>,
    /// (style, background, effect).
    pub variants: Option<(String, String, String)>,
    pub style: Option<String>,
    pub tier: Option<String>,
    pub duets: bool,
    pub find: String,
    pub stills: Stills,
    /// The scene the page was last drawn for (another: the pictures and the knobs let go).
    pub shown: Option<String>,
    /// Scrolled this far down once (screenshots: --scroll).
    pub scroll: Option<f32>,
    /// The moves' viewer: the dancers (loaded when first watched), their skins, the move
    /// watched and how, the strips drawn so far.
    pub player: Option<Option<std::sync::Arc<MovePlayer>>>,
    /// The dancers being read on a thread (with their skins' pixels).
    pub player_job: Option<std::sync::mpsc::Receiver<Loaded>>,
    pub skin_px: Vec<Option<(u32, u32, Vec<u8>)>>,
    pub skins: Vec<Option<egui::TextureHandle>>,
    pub watch: Option<String>,
    pub beat: f64,
    pub paused: bool,
    pub speed: f64,
    pub look: MoveLook,
    pub mirror: bool,
    pub model: usize,
    pub record_tempo: bool,
    pub strips: std::collections::HashMap<(usize, String), egui::TextureHandle>,
    /// The master's tempo while a record plays (the Show page's, each frame).
    pub tempo: Option<f64>,
}

impl App {
    pub(crate) fn scene_room(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, id: &str) {
        kit::panel(p, r, false);
        let Some(page) = desk.show_scene(id, self.scene_ui.all) else {
            self.show_scene = None;
            return;
        };
        if page.working {
            ui.ctx().request_repaint_after(std::time::Duration::from_millis(40));
        }
        if self.scene_ui.shown.as_deref() != Some(id) {
            self.scene_ui.stills.clear();
            self.scene_ui.knobs = None;
            self.scene_ui.variants = None;
            self.scene_ui.shown = Some(id.to_owned());
        }
        self.scene_ui.stills.frame();
        let inner = r.shrink(t::INSET);
        // the heading: back, the scene, copy from, play it
        let back = Rect::from_min_size(inner.min - vec2(0.0, 6.0), vec2(104.0, 28.0));
        if Btn::new("Rotation").icon(Icon::ChevronLeft).quiet().size(11.0).show(ui, p, back, "scene-back").on_hover_text("Back to every scene").clicked() {
            self.show_scene = None;
            self.scene_ui.variants = None;
            self.scene_ui.stills.clear();
            return;
        }
        let nr = kit::text(p, pos2(back.right() + 16.0, back.center().y), Align2::LEFT_CENTER, &page.name, 19.0, "label", t::high());
        if page.live {
            kit::dot(p, pos2(nr.right() + 10.0, nr.center().y), t::red(), 3.5);
            kit::hint(p, pos2(nr.right() + 20.0, nr.center().y), Align2::LEFT_CENTER, "on now");
        }
        let play = Rect::from_min_size(pos2(inner.right() - 96.0, back.top()), vec2(96.0, 28.0));
        if Btn::new("Play it").icon(Icon::Play).accent(true).size(11.0).show(ui, p, play, "scene-play").on_hover_text("One of its looks on the stage, held until you let go (on the LAND ON)").clicked() {
            desk.show_edit(ShowEdit::PlayScene(page.id.clone()));
        }
        if !page.world && !page.others.is_empty() {
            let copy = Rect::from_min_size(pos2(play.left() - 132.0, back.top()), vec2(124.0, 28.0));
            let resp = Btn::new("Copy from").icon(Icon::ChevronDown).quiet().size(11.0).show(ui, p, copy, "scene-copy").on_hover_text("Make it like another scene: its styles, its own backgrounds, masks and blends, the looks judged");
            egui::Popup::menu(&resp).show(|ui| {
                for (oid, name) in &page.others {
                    if ui.button(format!("Like {name}")).clicked() {
                        desk.show_edit(ShowEdit::CopyFrom(page.id.clone(), oid.clone()));
                    }
                }
            });
        }
        if let Some(said) = &page.said {
            kit::clipped(p, pos2(back.left() + 2.0, back.bottom() + 14.0), said, 12.0, "", t::soft(), inner.width());
        }
        let top = back.bottom() + if page.said.is_some() { 26.0 } else { 10.0 };
        let area = Rect::from_min_max(pos2(r.left() + 2.0, top), pos2(r.right() - 2.0, r.bottom() - 4.0));
        let moves = if page.dancers { Some(desk.show_moves()) } else { None };
        let strength = desk.show_finish().strength;
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(area));
        let mut sa = egui::ScrollArea::vertical().id_salt(("scene", id)).auto_shrink([false, false]);
        if let Some(y) = self.scene_ui.scroll.take() {
            sa = sa.vertical_scroll_offset(y);
        }
        sa.show(&mut child, |ui| {
            let w = area.width() - 10.0 - 2.0 * (t::INSET - 2.0);
            let x0 = area.left() + t::INSET - 2.0;
            let y0 = ui.cursor().top() + 4.0;
            let p = ui.painter().clone();
            let h = self.scene_body(desk, ui, &p, pos2(x0, y0), w, &page, moves.as_ref(), strength);
            ui.allocate_exact_size(vec2(area.width() - 10.0, h + 12.0), Sense::hover());
        });
        if let Some((style, ground, fx)) = self.scene_ui.variants.clone() {
            self.variants_modal(desk, ui, r, &page, &style, &ground, &fx, strength);
        }
    }

    /// The page's body from `at`, `w` wide; its height.
    #[allow(clippy::too_many_arguments)]
    fn scene_body(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, at: egui::Pos2, w: f32, page: &ScenePage, moves: Option<&MovesView>, strength: f64) -> f32 {
        let two = w >= 900.0;
        let gap = 28.0;
        let col_w = if two { (w - gap) / 2.0 } else { w };
        // the left: how often, the styles
        let a = Rect::from_min_size(at, vec2(col_w, 0.0));
        let a_h = self.scene_styles(desk, ui, p, a, page);
        // the right: the backgrounds, masks, blends, effects; the camera
        let b_at = if two { pos2(at.x + col_w + gap, at.y) } else { pos2(at.x, at.y + a_h + 16.0) };
        let b_h = self.scene_rows(desk, ui, p, Rect::from_min_size(b_at, vec2(col_w, 0.0)), page);
        let mut y = if two { at.y + a_h.max(b_h) + 18.0 } else { b_at.y + b_h + 18.0 };
        // the grid of its looks, the whole width
        y += self.looks_grid(desk, ui, p, Rect::from_min_size(pos2(at.x, y), vec2(w, 0.0)), page, strength) + 18.0;
        if let Some(m) = moves {
            head(p, Rect::from_min_size(pos2(at.x, y), vec2(w, 0.0)), y, "Who dances", "a name dances alone · one kept out of the mix never leads it");
            y += HEAD;
            let v = desk.stage();
            self.dancers_tab(desk, ui, p, Rect::from_min_size(pos2(at.x, y), vec2(w.min(620.0), 90.0)), &v);
            y += 90.0 + 14.0;
            y += self.moves_list(desk, ui, p, Rect::from_min_size(pos2(at.x, y), vec2(w, 0.0)), m, two);
        }
        y - at.y
    }

    /// How often; its styles, with their knobs. The height.
    fn scene_styles(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, page: &ScenePage) -> f32 {
        let mut y = r.top();
        head(p, r, y, "How often", "against the other scenes · the music says when");
        y += HEAD;
        let rr = Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), ROW));
        match level_row(ui, p, rr, &page.level, "scene-level", false) {
            Some(RowEdit::Level(v)) => desk.show_edit(ShowEdit::SceneLevel(page.id.clone(), v)),
            Some(RowEdit::On(on)) => desk.show_edit(ShowEdit::SceneOn(page.id.clone(), on)),
            _ => {}
        }
        y += ROW;
        if let Some(n) = &page.level.note {
            kit::clipped(p, pos2(r.left() + 18.0, y + 8.0), n, 11.5, "", t::soft(), r.width() - 18.0);
            y += 20.0;
        }
        // when it changes
        y += 14.0;
        head(p, r, y, "When it changes", "a drop may still cut to another");
        y += HEAD;
        let label_w = 130.0;
        let seg_w = (r.width() - label_w).min(360.0);
        let lr = kit::section(p, pos2(r.left(), y + 13.0), Align2::LEFT_CENTER, "Stays at least");
        ui.interact(lr, ui.scope_id().with("tip-stay"), Sense::hover()).on_hover_text("The bars it stays on before a new phrase may change it (the director's own: 8, a long one outlasts half a section too)");
        let stays = [Some(4), None, Some(16), Some(32)];
        let seg = Rect::from_min_size(pos2(r.left() + label_w, y), vec2(seg_w, 26.0));
        if let Some(i) = kit::segmented(ui, p, seg, &["4 bars", "8 · as ever", "16 bars", "32 bars"], stays.iter().position(|s| *s == page.stay).or(Some(1)), Tone::Neutral, "stay") {
            desk.show_edit(ShowEdit::Stay(page.id.clone(), stays[i]));
        }
        y += 34.0;
        let lr = kit::section(p, pos2(r.left(), y + 13.0), Align2::LEFT_CENTER, "Its look changes");
        ui.interact(lr, ui.scope_id().with("tip-turn"), Sense::hover()).on_hover_text("How often its style, background and blend change while it is on: never keeps the look it came on with");
        let turns = [2.0, 1.0, 0.5, 0.0];
        let seg = Rect::from_min_size(pos2(r.left() + label_w, y), vec2(seg_w, 26.0));
        let at = turns.iter().position(|k| (k - page.turn).abs() < 1e-6);
        if let Some(i) = kit::segmented(ui, p, seg, &["Often", "As ever", "Seldom", "Never"], at, Tone::Neutral, "turn") {
            desk.show_edit(ShowEdit::Turn(page.id.clone(), turns[i]));
        }
        y += 34.0;
        if page.styles.is_empty() {
            return y - r.top();
        }
        y += 14.0;
        head(p, r, y, "Styles", "how it is drawn · of its time");
        y += HEAD;
        for (i, s) in page.styles.iter().enumerate() {
            let has_knobs = !s.knobs.is_empty();
            let rr = Rect::from_min_size(pos2(r.left(), y), vec2(r.width() - 34.0, ROW));
            match level_row(ui, p, rr, &s.row, ("style", i), false) {
                Some(RowEdit::Level(v)) => desk.show_edit(ShowEdit::InLevel(page.id.clone(), "style".into(), s.row.key.clone(), v)),
                Some(RowEdit::On(on)) => desk.show_edit(ShowEdit::InOn(page.id.clone(), "style".into(), s.row.key.clone(), on)),
                _ => {}
            }
            let open = self.scene_ui.knobs.as_deref() == Some(s.row.key.as_str());
            if has_knobs {
                let kr = Rect::from_min_size(pos2(r.right() - 28.0, y + 3.0), vec2(28.0, 24.0));
                if Btn::new("").icon(Icon::Settings).on(open).quiet().show(ui, p, kr, ("knobs", i)).on_hover_text("Its knobs").clicked() {
                    self.scene_ui.knobs = if open { None } else { Some(s.row.key.clone()) };
                }
            }
            y += ROW;
            if open && has_knobs {
                tune_knobs(desk, ui, p, pos2(r.left() + 40.0, y + 22.0), &s.knobs, &format!("tune-{}", s.row.key));
                y += 62.0;
            }
        }
        y - r.top()
    }

    /// The backgrounds, masks, blends and effects — as every scene's, or its own; the camera's
    /// framings. The height.
    fn scene_rows(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, page: &ScenePage) -> f32 {
        let mut y = r.top();
        for (k, o) in page.shared.iter().enumerate() {
            y += self.own_rows(desk, ui, p, Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), 0.0)), page, o, k);
        }
        if !page.shots.is_empty() {
            y += 6.0;
            head(p, r, y, "Camera", "how it is framed at each cut, while it is on");
            y += HEAD;
            for (i, row) in page.shots.iter().enumerate() {
                let rr = Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), ROW));
                match level_row(ui, p, rr, row, ("shot", i), false) {
                    Some(RowEdit::Level(v)) => desk.show_edit(ShowEdit::InLevel(page.id.clone(), "shot".into(), row.key.clone(), v)),
                    Some(RowEdit::On(on)) => desk.show_edit(ShowEdit::InOn(page.id.clone(), "shot".into(), row.key.clone(), on)),
                    _ => {}
                }
                y += ROW;
            }
        }
        y - r.top()
    }

    #[allow(clippy::too_many_arguments)]
    fn own_rows(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, page: &ScenePage, o: &OwnRows, k: usize) -> f32 {
        let mut y = r.top();
        let seg_w = 190.0;
        head(p, Rect::from_min_size(r.min, vec2(r.width() - seg_w - 8.0, 0.0)), y, &o.title, &o.hint);
        let seg = Rect::from_min_size(pos2(r.right() - seg_w, y + 2.0), vec2(seg_w, 24.0));
        if let Some(i) = kit::segmented(ui, p, seg, &["As everywhere", "Its own"], Some(usize::from(o.own)), Tone::Neutral, ("own", k)) {
            desk.show_edit(ShowEdit::Own(page.id.clone(), o.axis.clone(), i == 1));
        }
        y += HEAD;
        if !o.own {
            let g = p.layout(o.summary.clone(), egui::FontId::new(12.0, crate::paint::family("")), t::soft(), r.width() - 4.0);
            let h = g.size().y;
            p.galley(pos2(r.left() + 2.0, y), g, t::soft());
            return y + h + 14.0 - r.top();
        }
        for (i, row) in o.rows.iter().enumerate() {
            let rr = Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), ROW));
            match level_row(ui, p, rr, row, (o.axis.as_str(), "own", i), false) {
                Some(RowEdit::Level(v)) => desk.show_edit(ShowEdit::InLevel(page.id.clone(), o.axis.clone(), row.key.clone(), v)),
                Some(RowEdit::On(on)) => desk.show_edit(ShowEdit::InOn(page.id.clone(), o.axis.clone(), row.key.clone(), on)),
                _ => {}
            }
            y += ROW;
        }
        y + 10.0 - r.top()
    }

    /// The grid of its looks: its styles down, the backgrounds across. The height.
    fn looks_grid(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, page: &ScenePage, strength: f64) -> f32 {
        let g = &page.grid;
        let mut y = r.top();
        let hint = if page.world { "each style a world of its own · a click: never, or back" } else { "style × background, blended the stage's way · a click: never, or back · a right click: less, more, each mask and blend" };
        head(p, r, y, "Its looks", hint);
        y += HEAD;
        let cols = g.grounds.len().max(1) as f32;
        let cw = ((r.width() - NAME_W) / cols - 4.0).clamp(64.0, 168.0);
        let ch = cw * 9.0 / 16.0 + 18.0;
        for (i, (_, name, on, here)) in g.grounds.iter().enumerate() {
            let ink = if !on { t::faint() } else if *here { t::text() } else { t::muted() };
            kit::clipped(p, pos2(r.left() + NAME_W + i as f32 * (cw + 4.0), y + 8.0), name, 11.0, "", ink, cw);
        }
        y += 20.0;
        let clip = ui.clip_rect();
        for (si, ((style, name, on), row)) in g.styles.iter().zip(&g.rows).enumerate() {
            kit::clipped(p, pos2(r.left(), y + ch / 2.0 - 8.0), name, 12.5, "", if *on { t::text() } else { t::faint() }, NAME_W - 8.0);
            for (gi, sq) in row.iter().enumerate() {
                let sr = Rect::from_min_size(pos2(r.left() + NAME_W + gi as f32 * (cw + 4.0), y), vec2(cw, ch));
                if !clip.intersects(sr) {
                    continue;
                }
                let resp = self.square(ui, p, sr, page, sq, strength, ("sq", si, gi));
                let what = square_menu(&resp, sq, page.world);
                if resp.clicked() {
                    desk.show_edit(ShowEdit::Square(page.id.clone(), style.clone(), sq.ground.clone(), SquareDo::Tap));
                }
                match what {
                    Some(Menu::Do(d)) => desk.show_edit(ShowEdit::Square(page.id.clone(), style.clone(), sq.ground.clone(), d)),
                    Some(Menu::Each) => self.scene_ui.variants = Some((style.clone(), sq.ground.clone(), "none".into())),
                    None => {}
                }
            }
            y += ch + 4.0;
        }
        y += 4.0;
        if g.hidden > 0 || g.all {
            let words = if g.all { "Only the styles and backgrounds that are on".to_owned() } else { format!("The {} styles and backgrounds that are off too", g.hidden) };
            let br = Rect::from_min_size(pos2(r.left(), y), vec2(300.0, 24.0));
            if Btn::new(&words).quiet().size(10.5).show(ui, p, br, "grid-all").clicked() {
                self.scene_ui.all = !g.all;
            }
            y += 30.0;
        }
        // what the marks mean
        let mut x = r.left();
        for (mark, word) in [("✕", "never (yours)"), ("▨", "cut by the measuring"), ("×½", "less / more (yours)"), ("ııı", "skipped with NEXT"), ("●", "on the stage now")] {
            let m = kit::text(p, pos2(x, y + 8.0), Align2::LEFT_CENTER, mark, 11.0, "", if mark == "●" || mark == "✕" { t::red() } else { t::muted() });
            let wr = kit::text(p, pos2(m.right() + 5.0, y + 8.0), Align2::LEFT_CENTER, word, 11.0, "", t::faint());
            x = wr.right() + 16.0;
        }
        y + 18.0 - r.top()
    }

    /// One square: its picture, its share, its marks.
    #[allow(clippy::too_many_arguments)]
    fn square(&mut self, ui: &mut Ui, p: &Painter, r: Rect, page: &ScenePage, sq: &Square, strength: f64, id: impl std::hash::Hash + std::fmt::Debug) -> egui::Response {
        let resp = ui.interact(r, ui.scope_id().with(id), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
        let cr = CornerRadius::same(5);
        p.rect_filled(r, cr, if resp.hovered() { white(0.06) } else { white(0.03) });
        p.rect_stroke(r, cr, Stroke::new(if sq.live { 1.5 } else { 1.0 }, if sq.live { t::red() } else { white(0.07) }), StrokeKind::Inside);
        let pic = Rect::from_min_max(r.min + vec2(2.0, 2.0), pos2(r.right() - 2.0, r.bottom() - 16.0));
        p.rect_filled(pic, CornerRadius::same(3), Color32::BLACK);
        if Stills::has(&page.figure, &sq.style) {
            let key = StillKey {
                figure: page.figure.clone(),
                style: sq.style.clone(),
                ground: sq.ground.clone(),
                mask: sq.mask.clone(),
                mix: sq.mix.clone(),
                strength: (strength * 100.0).round().clamp(0.0, 100.0) as u8,
            };
            if let Some(tex) = self.scene_ui.stills.get(ui.ctx(), &key) {
                let k = if sq.dead() { 0.18 } else if sq.cut { 0.45 } else { 1.0 };
                p.add(egui::epaint::RectShape::filled(pic, CornerRadius::same(3), Color32::from_gray((255.0 * k) as u8)).with_texture(tex.id(), Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0))));
            }
        } else {
            kit::hint(p, pic.center(), Align2::CENTER_CENTER, "on the stage only");
        }
        if sq.cut {
            let pp = p.with_clip_rect(pic);
            let mut x = pic.left() - pic.height();
            while x < pic.right() {
                pp.line_segment([pos2(x, pic.bottom()), pos2(x + pic.height(), pic.top())], Stroke::new(1.0, white(0.18)));
                x += 6.0;
            }
        }
        if sq.never {
            kit::text(p, pic.center(), Align2::CENTER_CENTER, "✕", 24.0, "", t::red());
        }
        let badge = |at: egui::Pos2, anchor: Align2, s: &str, lit: bool| {
            let g = p.layout_no_wrap(s.to_owned(), egui::FontId::new(9.5, crate::paint::family("label")), if lit { t::red() } else { t::text() });
            let br = anchor.anchor_size(at, g.size() + vec2(6.0, 2.0));
            p.rect_filled(br, CornerRadius::same(3), Color32::from_black_alpha(190));
            p.galley(br.min + vec2(3.0, 1.0), g, t::text());
        };
        if let Some(c) = sq.cell
            && (c - 1.0).abs() > 1e-6
        {
            badge(pic.right_top() + vec2(-2.0, 2.0), Align2::RIGHT_TOP, &level_word(c), true);
        }
        if sq.some_never {
            badge(pic.left_top() + vec2(2.0, 2.0), Align2::LEFT_TOP, "part ✕", false);
        }
        if sq.allowed {
            badge(pic.left_bottom() + vec2(2.0, -2.0), Align2::LEFT_BOTTOM, "allowed", false);
        }
        if sq.live {
            kit::dot(p, pic.right_bottom() - vec2(6.0, 6.0), t::red(), 3.5);
        }
        let dim = sq.dead() || sq.cut || !sq.here;
        kit::text(p, pos2(r.left() + 4.0, r.bottom() - 8.0), Align2::LEFT_CENTER, &sq.word(), 10.5, "mono", if dim { t::faint() } else { t::text() });
        if sq.skipped > 0 {
            let ticks = format!("{}{}", "ı".repeat(sq.skipped.min(5) as usize), if sq.skipped > 5 { "+" } else { "" });
            kit::text(p, pos2(r.right() - 4.0, r.bottom() - 8.0), Align2::RIGHT_CENTER, &ticks, 10.5, "", t::muted());
        }
        let mut tip = vec![sq.words.clone()];
        tip.extend(sq.note.clone());
        if sq.levels_off {
            tip.push("off by its levels (the style or the background)".into());
        }
        if sq.never {
            tip.push("never: yours — a click lets it come".into());
        }
        if sq.some_never {
            tip.push("some of its masks and blends never".into());
        }
        if sq.cut {
            tip.push("cut by the measuring — a click lets it come however it measured".into());
        }
        if sq.some_cut {
            tip.push("some of its masks and blends cut by the measuring".into());
        }
        if let Some(c) = sq.cell {
            tip.push(format!("{} by your hand", level_word(c)));
        }
        if sq.allowed {
            tip.push("comes however it measured".into());
        }
        if sq.skipped > 0 {
            tip.push(format!("skipped with NEXT {}×", sq.skipped));
        }
        if !sq.here {
            tip.push("not here now (no MilkDrop, no cover): nothing of it comes now".into());
        } else if !sq.dead() {
            tip.push(format!("{} of the scene's time", share_word(sq.share)));
        }
        tip.push(format!("a click: {} · a right click: more", if sq.dead() || sq.cut { "let it come" } else { "never" }));
        resp.on_hover_text(tip.join("\n"))
    }

    /// One square's masks and blends under an effect (a world's: its effects), each judged alone.
    #[allow(clippy::too_many_arguments)]
    fn variants_modal(&mut self, desk: &mut Desk, ui: &mut Ui, full: Rect, page: &ScenePage, style: &str, ground: &str, fx: &str, strength: f64) {
        let Some(v) = desk.show_variants(&page.id, style, ground, fx) else {
            self.scene_ui.variants = None;
            return;
        };
        let cols = v.rows.first().map_or(1, Vec::len) as f32;
        let (cw, ch) = (132.0, 132.0 * 9.0 / 16.0 + 18.0);
        let w = 90.0 + cols * (cw + 6.0) + 24.0;
        let h = 120.0 + v.rows.len() as f32 * (ch + 6.0) + 50.0;
        egui::Area::new(egui::Id::unique("scene-variants")).order(egui::Order::Foreground).fixed_pos(full.min).show(ui.ctx(), |ui| {
            let (all, _) = ui.allocate_exact_size(full.size(), Sense::click());
            let p = ui.painter().clone();
            p.rect_filled(all, CornerRadius::ZERO, Color32::from_black_alpha(150));
            let m = kit::modal(&p, all, vec2(w.min(all.width() - 20.0), h.min(all.height() - 20.0)), 1.0);
            ui.interact(m, ui.scope_id().with("block"), Sense::click());
            let inner = m.shrink(18.0);
            kit::text(&p, inner.min, Align2::LEFT_TOP, &v.title, 15.0, "label", t::high());
            kit::hint(&p, inner.min + vec2(0.0, 26.0), Align2::LEFT_TOP, if v.world { "each effect · a click: never, or back · a right click: less, more, play it" } else { "each mask and blend under the effect picked · a click: never, or back · a right click: less, more, play it" });
            let mut y = inner.top() + 50.0;
            if !v.world {
                self.variant_fxs(ui, &p, pos2(inner.left(), y), &v, fx);
                y += 36.0;
                for (i, (_, name)) in v.mixes.iter().enumerate() {
                    kit::clipped(&p, pos2(inner.left() + 90.0 + i as f32 * (cw + 6.0), y + 8.0), name, 11.0, "", t::text(), cw);
                }
                y += 20.0;
            }
            for (ri, row) in v.rows.iter().enumerate() {
                let label = if v.world { String::new() } else { v.masks.get(ri).map(|m| m.1.clone()).unwrap_or_default() };
                kit::clipped(&p, pos2(inner.left(), y + ch / 2.0 - 8.0), &label, 11.5, "", t::text(), 84.0);
                for (ci, sq) in row.iter().enumerate() {
                    let sr = Rect::from_min_size(pos2(inner.left() + 90.0 + ci as f32 * (cw + 6.0), y), vec2(cw, ch));
                    if v.world {
                        kit::clipped(&p, pos2(sr.left(), sr.top() - 10.0), &v.fxs[ci].1, 10.5, "", t::muted(), cw);
                    }
                    let resp = self.square(ui, &p, sr, page, sq, strength, ("var", ri, ci));
                    let what = square_menu(&resp, sq, true);
                    if resp.clicked() {
                        desk.show_edit(ShowEdit::Look(sq.key.clone(), SquareDo::Tap));
                    }
                    if let Some(Menu::Do(d)) = what {
                        desk.show_edit(ShowEdit::Look(sq.key.clone(), d));
                    }
                }
                y += ch + 6.0;
            }
            let done = Rect::from_min_size(pos2(inner.right() - 90.0, inner.bottom() - 28.0), vec2(90.0, 28.0));
            let closed = Btn::new("Done").size(11.0).show(ui, &p, done, "variants-done").clicked();
            let outside = ui.input(|i| i.pointer.any_click()) && ui.input(|i| i.pointer.interact_pos()).is_some_and(|at| !m.contains(at));
            if closed || outside || ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                self.scene_ui.variants = None;
            }
        });
    }

    fn variant_fxs(&mut self, ui: &mut Ui, p: &Painter, at: egui::Pos2, v: &Variants, fx: &str) {
        kit::section(p, pos2(at.x, at.y + 13.0), Align2::LEFT_CENTER, "Effect");
        let mut x = at.x + 90.0;
        for (key, name, share, on) in &v.fxs {
            let word = format!("{name} {}", share_word(*share));
            let cw = kit::chip_width(p, &word) + 8.0;
            let cr = Rect::from_min_size(pos2(x, at.y + 2.0), vec2(cw, 22.0));
            if kit::chip(ui, p, cr, &word, key == fx, Tone::Neutral, *on || key == fx, ("vfx", key)).on_hover_text("The masks and blends under this effect (its share of the scene's time with this style on this background)").clicked()
                && let Some(s) = &mut self.scene_ui.variants
            {
                s.2 = key.clone();
            }
            x += cw + 6.0;
        }
    }

    /// The dancers' moves: every one of the bank — switched off, starred, asked for. The height.
    fn moves_list(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, m: &MovesView, two: bool) -> f32 {
        let mut y = r.top();
        head(p, r, y, "The moves", "the switch keeps one out of the dancing · the star: danced more · ▷: the lead on the stage dances it next");
        y += HEAD;
        if !m.found {
            kit::hint(p, pos2(r.left(), y + 10.0), Align2::LEFT_CENTER, "The dancers are not here (their folder beside the Desk)");
            return y + 24.0 - r.top();
        }
        // the dancers read once, on a thread (a few megabytes and their skins)
        if self.scene_ui.player.is_none() && self.scene_ui.player_job.is_none() {
            let (tx, rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let pl = MovePlayer::load().map(std::sync::Arc::new);
                let skins = pl.as_ref().map(|p| (0..p.models().len()).map(|k| p.skin(k)).collect()).unwrap_or_default();
                let _ = tx.send((pl, skins));
            });
            self.scene_ui.player_job = Some(rx);
        }
        if let Some(rx) = &self.scene_ui.player_job {
            match rx.try_recv() {
                Ok((pl, skins)) => {
                    self.scene_ui.player = Some(pl);
                    self.scene_ui.skin_px = skins;
                    self.scene_ui.player_job = None;
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => ui.ctx().request_repaint_after(std::time::Duration::from_millis(50)),
                Err(_) => self.scene_ui.player_job = None,
            }
        }
        let player = self.scene_ui.player.clone().flatten();
        if player.is_none() && self.scene_ui.player_job.is_some() {
            kit::hint(p, pos2(r.left(), y + 12.0), Align2::LEFT_CENTER, "Reading the dancers…");
            y += 30.0;
        }
        if let Some(pl) = &player {
            y += self.move_viewer(desk, ui, p, Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), VIEW_H)), m, pl) + 14.0;
        }
        // the filters
        let su = &mut self.scene_ui;
        let mut x = r.left();
        let mut styles: Vec<&str> = m.moves.iter().map(|mv| mv.style.as_str()).collect();
        styles.sort_unstable();
        styles.dedup();
        let chip = |ui: &mut Ui, x: &mut f32, word: &str, on: bool, id: (&str, &str)| {
            let w = kit::chip_width(p, word) + 6.0;
            let cr = Rect::from_min_size(pos2(*x, y), vec2(w, 22.0));
            *x += w + 4.0;
            kit::chip(ui, p, cr, word, on, Tone::Neutral, true, id).clicked()
        };
        if chip(ui, &mut x, "All", su.style.is_none(), ("mv-style", "")) {
            su.style = None;
        }
        for s in &styles {
            if chip(ui, &mut x, s, su.style.as_deref() == Some(*s), ("mv-style", s)) {
                su.style = if su.style.as_deref() == Some(*s) { None } else { Some(s.to_string()) };
            }
        }
        x += 10.0;
        for tier in ["low", "mid", "high"] {
            if chip(ui, &mut x, tier, su.tier.as_deref() == Some(tier), ("mv-tier", tier)) {
                su.tier = if su.tier.as_deref() == Some(tier) { None } else { Some(tier.into()) };
            }
        }
        x += 10.0;
        if chip(ui, &mut x, "duets", su.duets, ("mv-duets", "")) {
            su.duets = !su.duets;
        }
        let fr = Rect::from_min_size(pos2((x + 10.0).min(r.right() - 160.0), y - 2.0), vec2(150.0, 26.0));
        kit::field(ui, p, fr, &mut su.find, "find", Some(Icon::Search), false, "mv-find");
        y += 34.0;
        let off = m.moves.iter().filter(|mv| !mv.on).count();
        let stars = m.moves.iter().filter(|mv| mv.star).count();
        kit::hint(p, pos2(r.left(), y + 6.0), Align2::LEFT_CENTER, &format!("{} moves · {off} off · {stars} starred", m.moves.len()));
        y += 20.0;
        let shown: Vec<&wo_deskcore::MoveRow> = m
            .moves
            .iter()
            .filter(|mv| su.style.as_deref().is_none_or(|s| mv.style == s))
            .filter(|mv| su.tier.as_deref().is_none_or(|t| mv.tier == t))
            .filter(|mv| !su.duets || mv.duo.is_some())
            .filter(|mv| su.find.is_empty() || mv.id.contains(su.find.trim()))
            .collect();
        let cols = if two { 2 } else { 1 };
        let gap = 24.0;
        let cw = (r.width() - gap * (cols - 1) as f32) / cols as f32;
        let rh = 52.0;
        let clip = ui.clip_rect();
        let mut made = 0;
        for (i, mv) in shown.iter().enumerate() {
            let (c, row) = (i % cols, i / cols);
            let rr = Rect::from_min_size(pos2(r.left() + c as f32 * (cw + gap), y + row as f32 * rh), vec2(cw, rh - 4.0));
            if !clip.intersects(rr) {
                continue;
            }
            let watched = self.scene_ui.watch.as_deref() == Some(mv.id.as_str());
            if watched {
                p.rect_filled(rr, CornerRadius::same(t::R_CONTROL), white(0.05));
            }
            // its poses, a strip (a few drawn a frame)
            let sr = Rect::from_min_size(pos2(rr.left() + 2.0, rr.top() + 2.0), vec2(STRIP_N as f32 * STRIP_W, STRIP_H));
            let key = (self.scene_ui.model, mv.id.clone());
            if !self.scene_ui.strips.contains_key(&key)
                && made < 3
                && let Some(pl) = &player
            {
                made += 1;
                let px = pl.strip(self.scene_ui.model, &mv.id, STRIP_N, STRIP_W as u32, STRIP_H as u32);
                let img = egui::ColorImage::from_rgba_unmultiplied([STRIP_N * STRIP_W as usize, STRIP_H as usize], &px);
                self.scene_ui.strips.insert(key.clone(), ui.ctx().load_texture(format!("strip {}", mv.id), img, egui::TextureOptions::LINEAR));
            }
            if let Some(tex) = self.scene_ui.strips.get(&key) {
                let tint = if mv.on { Color32::WHITE } else { Color32::from_gray(90) };
                p.add(egui::epaint::RectShape::filled(sr, CornerRadius::ZERO, tint).with_texture(tex.id(), Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0))));
            } else if player.is_some() {
                ui.ctx().request_repaint();
            }
            let tx = sr.right() + 10.0;
            let ink = if mv.on { t::text() } else { t::faint() };
            kit::clipped(p, pos2(tx, rr.top() + 14.0), &mv.id, 12.5, "mono", ink, cw - (tx - rr.left()) - 124.0);
            let meta = format!(
                "{} · {} · {:.0} bpm · {} beats · {:.1}{}",
                mv.style,
                mv.tier,
                mv.bpm,
                mv.beats,
                mv.energy,
                mv.duo.as_ref().map(|d| format!(" · duet {d} {}", if mv.lead { "lead" } else { "partner" })).unwrap_or_default()
            );
            kit::clipped(p, pos2(tx, rr.top() + 32.0), &meta, 11.0, "", t::faint(), cw - (tx - rr.left()) - 124.0);
            let pick = Rect::from_min_max(rr.min, pos2(rr.right() - 120.0, rr.bottom()));
            if ui.interact(pick, ui.scope_id().with(("mv-watch", &mv.id)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand).on_hover_text("Watch it above").clicked() {
                self.scene_ui.watch = Some(mv.id.clone());
                self.scene_ui.beat = 0.0;
            }
            let asked = m.asked.as_deref() == Some(mv.id.as_str());
            let cy = rr.center().y - 12.0;
            let ar = Rect::from_min_size(pos2(rr.right() - 116.0, cy), vec2(28.0, 24.0));
            if Btn::new("").icon(Icon::Play).on(asked).quiet().show(ui, p, ar, ("mv-ask", &mv.id)).on_hover_text(if asked { "Asked for: the lead dances it at the next slot" } else { "The lead on the stage dances it at the next slot" }).clicked() {
                desk.show_edit(ShowEdit::Audition(mv.id.clone()));
            }
            let st = Rect::from_min_size(pos2(rr.right() - 84.0, cy), vec2(28.0, 24.0));
            if Btn::new("").icon(if mv.star { Icon::HeartFull } else { Icon::Heart }).on(mv.star).quiet().show(ui, p, st, ("mv-star", &mv.id)).on_hover_text(if mv.star { "A favourite — plain again" } else { "A favourite: danced more" }).clicked() {
                desk.show_edit(ShowEdit::MoveStar(mv.id.clone(), !mv.star));
            }
            let or = Rect::from_min_size(pos2(rr.right() - 48.0, cy + 2.0), vec2(46.0, 20.0));
            if kit::chip(ui, p, or, if mv.on { "On" } else { "Off" }, mv.on, Tone::Neutral, true, ("mv-on", &mv.id)).on_hover_text(if mv.on { "On: may be danced — click: never" } else { "Off: never danced — click: back" }).clicked() {
                desk.show_edit(ShowEdit::MoveOn(mv.id.clone(), !mv.on));
            }
        }
        let rows = shown.len().div_ceil(cols);
        y + rows as f32 * rh + 8.0 - r.top()
    }
}

impl App {
    /// The move watched: played on its own, square on, as the controls say; its facts and its
    /// say beside. The height.
    #[allow(clippy::too_many_arguments)]
    fn move_viewer(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, m: &MovesView, pl: &MovePlayer) -> f32 {
        let su = &mut self.scene_ui;
        if su.speed == 0.0 {
            su.speed = 1.0;
        }
        let id = su.watch.clone().filter(|w| m.moves.iter().any(|mv| mv.id == *w)).or_else(|| m.moves.iter().find(|mv| mv.on).map(|mv| mv.id.clone()));
        let Some(id) = id else { return 0.0 };
        let Some(facts) = pl.facts(&id) else { return 0.0 };
        let mv = m.moves.iter().find(|x| x.id == id);
        // the tempo: the move's own, or the record's (half or double where far off)
        let bpm = match su.tempo.filter(|_| su.record_tempo) {
            Some(mut b) => {
                while b > facts.bpm * 1.45 {
                    b /= 2.0;
                }
                while b < facts.bpm / 1.45 {
                    b *= 2.0;
                }
                b
            }
            None => facts.bpm,
        };
        if !su.paused {
            su.beat = (su.beat + ui.input(|i| i.stable_dt as f64) * bpm / 60.0 * su.speed) % facts.beats.max(1) as f64;
            ui.ctx().request_repaint();
        }
        // the picture
        let view = Rect::from_min_size(r.min, vec2((r.height() * 0.95).min(r.width() * 0.5), r.height()));
        let cr = CornerRadius::same(t::R_PAD);
        p.rect_filled(view, cr, Color32::from_rgb(12, 12, 16));
        let floor = view.bottom() - view.height() * 0.1;
        p.line_segment([pos2(view.left() + 12.0, floor), pos2(view.right() - 12.0, floor)], Stroke::new(1.0, white(0.05)));
        if su.skins.is_empty() {
            su.skins = std::mem::take(&mut su.skin_px)
                .into_iter()
                .enumerate()
                .map(|(k, px)| px.map(|(w, h, rgba)| ui.ctx().load_texture(format!("skin {k}"), egui::ColorImage::from_rgba_unmultiplied([w as usize, h as usize], &rgba), egui::TextureOptions::LINEAR)))
                .collect();
        }
        let clip = p.with_clip_rect(view.intersect(p.clip_rect()));
        for b in pl.bodies(su.model, &id, su.beat, su.mirror, view.width(), view.height()) {
            let tex = match su.look {
                MoveLook::Textured => su.skins.get(b.model).cloned().flatten().map(|t| t.id()),
                _ => None,
            };
            let mut mesh = egui::Mesh::with_texture(tex.unwrap_or_default());
            mesh.vertices = b
                .at
                .iter()
                .zip(&b.uv)
                .zip(&b.light)
                .map(|((a, uv), l)| {
                    let color = match su.look {
                        MoveLook::Textured => Color32::from_gray((255.0 * (0.4 + 0.6 * l)).min(255.0) as u8),
                        MoveLook::Chrome => {
                            let c = 0.12 + 0.88 * l.powi(3);
                            Color32::from_rgb((c * 215.0) as u8, (c * 228.0) as u8, (c * 255.0) as u8)
                        }
                        MoveLook::Silhouette => Color32::from_gray(225),
                    };
                    egui::epaint::Vertex { pos: pos2(view.left() + a[0], view.top() + a[1]), uv: if tex.is_some() { pos2(uv[0], uv[1]) } else { egui::epaint::WHITE_UV }, color }
                })
                .collect();
            mesh.indices = b.tris;
            clip.add(egui::Shape::mesh(mesh));
        }
        kit::text(p, pos2(view.left() + 10.0, view.bottom() - 14.0), Align2::LEFT_CENTER, &format!("beat {:.1} / {}", su.beat + 1.0, facts.beats), 10.5, "mono", t::faint());
        // beside: what it is, how it is shown
        let x = view.right() + 18.0;
        let w = r.right() - x;
        let mut y = r.top();
        kit::text(p, pos2(x, y + 10.0), Align2::LEFT_CENTER, &id, 16.0, "mono", t::high());
        if let Some(mv) = mv {
            let meta = format!(
                "{} · {} tier · {:.0} bpm · {} beats · energy {:.1}{}",
                mv.style,
                mv.tier,
                mv.bpm,
                mv.beats,
                mv.energy,
                mv.duo.as_ref().map(|d| format!(" · duet {d}, the {}", if mv.lead { "lead" } else { "partner" })).unwrap_or_default()
            );
            kit::clipped(p, pos2(x, y + 32.0), &meta, 11.5, "", t::soft(), w);
        }
        y += 50.0;
        let label_w = 70.0;
        let row = |p: &Painter, y: f32, word: &str| {
            kit::section(p, pos2(x, y + 13.0), Align2::LEFT_CENTER, word);
        };
        row(p, y, "Play");
        let pr = Rect::from_min_size(pos2(x + label_w, y), vec2(34.0, 26.0));
        if Btn::new("").icon(if su.paused { Icon::Play } else { Icon::Pause }).show(ui, p, pr, "mv-pause").on_hover_text(if su.paused { "Play" } else { "Pause" }).clicked() {
            su.paused = !su.paused;
        }
        let speeds = [0.5, 1.0, 2.0];
        let seg = Rect::from_min_size(pos2(pr.right() + 8.0, y), vec2(130.0, 26.0));
        if let Some(i) = kit::segmented(ui, p, seg, &["×½", "×1", "×2"], speeds.iter().position(|s| *s == su.speed), Tone::Neutral, "mv-speed") {
            su.speed = speeds[i];
        }
        let tr = Rect::from_min_size(pos2(seg.right() + 8.0, y), vec2(130.0, 26.0));
        let playing = su.tempo.is_some();
        if kit::chip(ui, p, tr, "Record's tempo", su.record_tempo && playing, Tone::Neutral, playing, "mv-tempo")
            .on_hover_text(if playing { "Danced at the record's tempo (half or double time where far off)" } else { "Nothing plays: the move's own tempo" })
            .clicked()
        {
            su.record_tempo = !su.record_tempo;
        }
        y += 34.0;
        row(p, y, "Drawn");
        let seg = Rect::from_min_size(pos2(x + label_w, y), vec2(250.0_f32.min(w - label_w), 26.0));
        let looks = [MoveLook::Textured, MoveLook::Chrome, MoveLook::Silhouette];
        if let Some(i) = kit::segmented(ui, p, seg, &["Skin", "Chrome", "Silhouette"], looks.iter().position(|l| *l == su.look), Tone::Neutral, "mv-look") {
            su.look = looks[i];
        }
        let mr = Rect::from_min_size(pos2(seg.right() + 8.0, y), vec2(84.0, 26.0));
        if kit::chip(ui, p, mr, "Mirrored", su.mirror, Tone::Neutral, true, "mv-mirror").clicked() {
            su.mirror = !su.mirror;
        }
        y += 34.0;
        row(p, y, "Dancer");
        let names: Vec<String> = pl.models().into_iter().map(|(_, n)| n).collect();
        let words: Vec<&str> = names.iter().map(String::as_str).collect();
        let seg = Rect::from_min_size(pos2(x + label_w, y), vec2((words.len() as f32 * 90.0).min(w - label_w), 26.0));
        if let Some(i) = kit::segmented(ui, p, seg, &words, Some(su.model), Tone::Neutral, "mv-model") {
            su.model = i;
        }
        y += 42.0;
        // its say: on the stage now, a favourite, in or out
        if let Some(mv) = mv {
            let asked = m.asked.as_deref() == Some(mv.id.as_str());
            let br = Rect::from_min_size(pos2(x, y), vec2(150.0, 28.0));
            if Btn::new(if asked { "Asked for" } else { "On the stage" }).icon(Icon::Play).on(asked).accent(true).size(11.0).show(ui, p, br, "mv-view-ask").on_hover_text("The lead on the stage dances it at the next slot").clicked() {
                desk.show_edit(ShowEdit::Audition(mv.id.clone()));
            }
            let sr = Rect::from_min_size(pos2(br.right() + 8.0, y), vec2(130.0, 28.0));
            if Btn::new(if mv.star { "A favourite" } else { "Favourite" }).icon(if mv.star { Icon::HeartFull } else { Icon::Heart }).on(mv.star).size(11.0).show(ui, p, sr, "mv-view-star").on_hover_text("A favourite is danced more").clicked() {
                desk.show_edit(ShowEdit::MoveStar(mv.id.clone(), !mv.star));
            }
            let or = Rect::from_min_size(pos2(sr.right() + 8.0, y + 4.0), vec2(80.0, 20.0));
            if kit::chip(ui, p, or, if mv.on { "Danced" } else { "Never" }, mv.on, if mv.on { Tone::Neutral } else { Tone::Danger }, true, "mv-view-on").on_hover_text("Whether the dancers may dance it").clicked() {
                desk.show_edit(ShowEdit::MoveOn(mv.id.clone(), !mv.on));
            }
            y += 40.0;
        }
        kit::clipped(p, pos2(x, y + 8.0), "A strip below: a click watches that move here", 11.0, "", t::faint(), w);
        r.height()
    }
}

enum Menu {
    Do(SquareDo),
    Each,
}

/// A square's right-click menu: play it, less, more, never, as it was, let it come however it
/// measured, measured again, each mask and blend (not for one look).
fn square_menu(resp: &egui::Response, sq: &Square, one: bool) -> Option<Menu> {
    let mut out = None;
    resp.context_menu(|ui| {
        let mut item = |ui: &mut Ui, word: &str, enabled: bool, m: Menu| {
            if ui.add_enabled(enabled, egui::Button::new(word)).clicked() {
                out = Some(m);
                ui.close();
            }
        };
        item(ui, &format!("Play it now — {}", sq.words), true, Menu::Do(SquareDo::Play));
        ui.separator();
        let now = sq.cell.map(|c| format!(" — now {}", level_word(c))).unwrap_or_default();
        item(ui, &format!("Less (×½){now}"), !sq.levels_off, Menu::Do(SquareDo::Less));
        item(ui, "More (×2)", !sq.levels_off, Menu::Do(SquareDo::More));
        item(ui, "Never", !sq.levels_off && !sq.never, Menu::Do(SquareDo::Never));
        if sq.cell.is_some() || sq.never || sq.some_never || sq.allowed {
            item(ui, "As it was: the levels alone", true, Menu::Do(SquareDo::Back));
        }
        if !sq.allowed && (sq.cut || sq.some_cut) {
            item(ui, "Let it come however it measured", true, Menu::Do(SquareDo::Allow));
        }
        if sq.allowed {
            item(ui, "Measured again: the ugly ones out", true, Menu::Do(SquareDo::Measure));
        }
        if !one {
            ui.separator();
            item(ui, if sq.ground == "own" { "Each effect…" } else { "Each mask, blend and effect…" }, true, Menu::Each);
        }
    });
    out
}
