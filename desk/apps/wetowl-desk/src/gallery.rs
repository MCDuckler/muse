//! The kit's gallery (`--page kit`): every control in each of its states, the icons, the
//! type ladder and the colours — the page the design is reviewed on, and the goldens'
//! subject.
use eframe::egui::{Align2, Color32, CornerRadius, Painter, Rect, Ui, pos2, vec2};
use wo_deskcore::theme;

use crate::App;
use crate::paint::col;
use crate::ui::icons::{self, Icon};
use crate::ui::kit::{self, Btn};
use crate::ui::tokens::{self as t, Tone};

const ICONS: [Icon; 33] = [
    Icon::Play, Icon::Pause, Icon::Cue, Icon::Sync, Icon::Lock, Icon::Loop, Icon::Back4, Icon::Ahead4, Icon::Brake, Icon::Kill, Icon::Search,
    Icon::Settings, Icon::Heart, Icon::HeartFull, Icon::Eye, Icon::Screen, Icon::Plus, Icon::Close, Icon::ChevronLeft, Icon::ChevronRight,
    Icon::ChevronDown, Icon::Check, Icon::Undo, Icon::Bolt, Icon::Next, Icon::Previous, Icon::Snow, Icon::Power, Icon::Shuffle, Icon::Keys,
    Icon::Layers, Icon::Dice, Icon::Dot,
];

pub(crate) fn draw(app: &mut App, ui: &mut Ui, p: &Painter, full: Rect) {
    let r = full.shrink(24.0);
    let col_w = (r.width() - 2.0 * 24.0) / 3.0;
    let panel = |i: usize, y: f32, h: f32| Rect::from_min_size(pos2(r.left() + i as f32 * (col_w + 24.0), r.top() + y), vec2(col_w, h));

    // buttons: each tone at rest, on, disabled; with icons, sub-lines, quiet
    let b = panel(0, 0.0, 330.0);
    kit::panel(p, b, false);
    let inner = b.shrink(t::INSET);
    kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Buttons");
    let tones = [("Neutral", Tone::Neutral), ("Deck A", Tone::Deck(0)), ("Deck B", Tone::Deck(1)), ("Ok", Tone::Ok), ("Warm", Tone::Warm), ("Danger", Tone::Danger)];
    let bw = (inner.width() - 16.0) / 3.0;
    for (i, (name, tone)) in tones.iter().enumerate() {
        let y = inner.top() + 28.0 + i as f32 * 38.0;
        for (k, (on, enabled)) in [(false, true), (true, true), (false, false)].into_iter().enumerate() {
            let br = Rect::from_min_size(pos2(inner.left() + k as f32 * (bw + 8.0), y), vec2(bw, 30.0));
            Btn::new(name).tone(*tone).on(on).enabled(enabled).show(ui, p, br, ("g-btn", i, k));
        }
    }
    let y = inner.top() + 28.0 + 6.0 * 38.0;
    Btn::new("Cue").icon(Icon::Cue).show(ui, p, Rect::from_min_size(pos2(inner.left(), y), vec2(bw, 44.0)), "g-cue");
    Btn::new("").icon(Icon::Play).tone(Tone::Deck(0)).on(true).show(ui, p, Rect::from_min_size(pos2(inner.left() + bw + 8.0, y), vec2(bw, 44.0)), "g-play");
    Btn::new("Never this").sub("never again").tone(Tone::Danger).accent(true).show(ui, p, Rect::from_min_size(pos2(inner.left() + 2.0 * (bw + 8.0), y), vec2(bw, 44.0)), "g-never");

    // choices: segmented, chips
    let c = panel(0, 354.0, 200.0);
    kit::panel(p, c, false);
    let inner = c.shrink(t::INSET);
    kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Choices");
    let seg = Rect::from_min_size(pos2(inner.left(), inner.top() + 28.0), vec2(inner.width(), 26.0));
    let chosen = ui.ctx().data_mut(|d| *d.get_temp_mut_or_insert_with(ui.scope_id().with("g-seg-at"), || 1usize));
    if let Some(i) = kit::segmented(ui, p, seg, &["¼", "½", "1", "2", "4", "8", "16", "32"], Some(chosen), Tone::Deck(1), "g-seg") {
        ui.ctx().data_mut(|d| d.insert_temp(ui.scope_id().with("g-seg-at"), i));
    }
    let seg2 = Rect::from_min_size(pos2(inner.left(), inner.top() + 66.0), vec2(220.0, 24.0));
    kit::segmented(ui, p, seg2, &["Easy", "Normal", "Bold"], None, Tone::Neutral, "g-seg2");
    let mut x = inner.left();
    for (i, (w, on, enabled)) in [("As shipped", true, true), ("Warehouse", false, true), ("Window", false, false)].into_iter().enumerate() {
        let cw = kit::chip_width(p, w);
        kit::chip(ui, p, Rect::from_min_size(pos2(x, inner.top() + 104.0), vec2(cw, 26.0)), w, on, Tone::Neutral, enabled, ("g-chip", i));
        x += cw + 6.0;
    }
    let mut demo = String::from("Kölsch");
    kit::field(ui, p, Rect::from_min_size(pos2(inner.left(), inner.top() + 140.0), vec2(inner.width(), 32.0)), &mut demo, "Search the house", Some(Icon::Search), false, "g-field");

    // pads, sleeves
    let pd = panel(1, 0.0, 250.0);
    kit::panel(p, pd, false);
    let inner = pd.shrink(t::INSET);
    kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Hot cues and sleeves");
    let pw = (inner.width() - 24.0) / 4.0;
    let kinds = [Some(("Intro", col(theme::pad(wo_deskcore::PadKind::Intro)))), Some(("Drop", col(theme::pad(wo_deskcore::PadKind::Drop)))), Some(("Cue", col(theme::SOFT))), None];
    for (i, k) in kinds.into_iter().enumerate() {
        let pr = Rect::from_min_size(pos2(inner.left() + i as f32 * (pw + 8.0), inner.top() + 28.0), vec2(pw, 56.0));
        if kit::pad(ui, p, pr, i + 1, k, app.pad_fired[0][i], ("g-pad", i)).clicked() {
            app.pad_fired[0][i] += 1;
        }
    }
    for (i, (s, side)) in [("JR", 72.0), ("KM", 36.0), ("FT", 28.0)].into_iter().enumerate() {
        let x = inner.left() + [0.0, 88.0, 136.0][i];
        kit::sleeve(ui, p, Rect::from_min_size(pos2(x, inner.top() + 104.0), vec2(side, side)), None, s, col(theme::sleeve(i as i64 * 7 + 3)), if side > 40.0 { 8 } else { 4 }, ("g-sleeve", i));
    }
    kit::deck_chip(p, pos2(inner.left() + 180.0, inner.top() + 120.0), 0);
    kit::deck_chip(p, pos2(inner.left() + 206.0, inner.top() + 120.0), 1);
    let tab = Rect::from_min_size(pos2(inner.left() + 180.0, inner.top() + 140.0), vec2(120.0, 24.0));
    kit::glass_tab(p, tab);
    crate::paint::label_sized(p, tab.center(), Align2::CENTER_CENTER, "Glass tab", 10.5, t::soft());

    // knobs, faders, meters
    let m = panel(1, 274.0, 280.0);
    kit::panel(p, m, false);
    let inner = m.shrink(t::INSET);
    kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Knobs, faders, meters");
    let vals = ui.ctx().data_mut(|d| *d.get_temp_mut_or_insert_with(ui.scope_id().with("g-vals"), || [0.5f32, 0.8, 0.2, 0.7, 0.35]));
    let mut nv = vals;
    for (i, (v, bip, c)) in [(vals[0], false, Color32::from_rgb(0x9D, 0xA1, 0xAA)), (vals[1], true, t::deck(0)), (vals[2], true, t::deck(1))].into_iter().enumerate() {
        if let Some(x) = kit::knob(ui, p, pos2(inner.left() + 24.0 + i as f32 * 56.0, inner.top() + 50.0), v, c, bip, 0.5, ("g-knob", i)) {
            nv[i] = x;
        }
    }
    if let Some(x) = kit::vfader(ui, p, Rect::from_min_size(pos2(inner.left() + 190.0, inner.top() + 24.0), vec2(34.0, 180.0)), vals[3], t::deck(0), "g-fader") {
        nv[3] = x;
    }
    kit::meter(ui, p, Rect::from_min_size(pos2(inner.left() + 240.0, inner.top() + 26.0), vec2(6.0, 176.0)), vals[3], 18, "g-meter");
    if let Some(x) = kit::crossfader(ui, p, Rect::from_min_size(pos2(inner.left(), inner.bottom() - 30.0), vec2(inner.width(), 30.0)), vals[4], "g-xf") {
        nv[4] = x;
    }
    if nv != vals {
        ui.ctx().data_mut(|d| d.insert_temp(ui.scope_id().with("g-vals"), nv));
    }

    // icons
    let ic = panel(2, 0.0, 250.0);
    kit::panel(p, ic, false);
    let inner = ic.shrink(t::INSET);
    kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Icons");
    let per = ((inner.width() + 8.0) / 44.0).floor().max(1.0) as usize;
    for (i, icon) in ICONS.iter().enumerate() {
        let cell = Rect::from_min_size(pos2(inner.left() + (i % per) as f32 * 44.0, inner.top() + 28.0 + (i / per) as f32 * 44.0), vec2(36.0, 36.0));
        p.rect_filled(cell, CornerRadius::same(t::R_CONTROL), Color32::from_white_alpha(6));
        icons::paint(p, cell.shrink(8.0), *icon, t::soft());
    }

    // type and colour
    let ty = panel(2, 274.0, 280.0);
    kit::panel(p, ty, false);
    let inner = ty.shrink(t::INSET);
    kit::section(p, inner.left_top(), Align2::LEFT_TOP, "Type and colour");
    let mut y = inner.top() + 40.0;
    kit::text(p, pos2(inner.left(), y), Align2::LEFT_CENTER, "128.00", t::DISPLAY_L, "mono-semi", t::text());
    kit::text(p, pos2(inner.left() + 140.0, y), Align2::LEFT_CENTER, "−3:21.4", t::DISPLAY_M, "mono", t::text());
    y += 36.0;
    kit::text(p, pos2(inner.left(), y), Align2::LEFT_CENTER, "Title in Inter semi 17", t::TITLE, "semi", t::text());
    y += 26.0;
    kit::section(p, pos2(inner.left(), y), Align2::LEFT_CENTER, "Section, Archivo caps");
    y += 22.0;
    kit::text(p, pos2(inner.left(), y), Align2::LEFT_CENTER, "Body, Inter 13 for what is read", t::BODY, "", t::muted());
    y += 22.0;
    kit::label(p, pos2(inner.left(), y), Align2::LEFT_CENTER, "Label, 11 caps");
    y += 22.0;
    kit::hint(p, pos2(inner.left(), y), Align2::LEFT_CENTER, "A hint, sentence case and faint");
    y += 30.0;
    for (i, c) in [t::deck(0), t::deck(1), t::ok(), t::warm(), t::hot(), t::red(), t::soft(), t::faint()].into_iter().enumerate() {
        p.rect_filled(Rect::from_min_size(pos2(inner.left() + i as f32 * 34.0, y), vec2(28.0, 20.0)), CornerRadius::same(4), c);
    }

    // toasts and a modal frame, shown as they look
    let o = Rect::from_min_max(pos2(r.left(), r.top() + 578.0), r.max);
    if o.height() > 120.0 {
        kit::panel(p, o, false);
        kit::section(p, o.left_top() + vec2(t::INSET, t::INSET), Align2::LEFT_TOP, "Toasts");
        kit::toast(p, o, 1, "Signed in to 89-58-49-140.nip.io as chris", Tone::Ok, 1.0);
        kit::toast(p, o, 0, "The house said no: wrong password", Tone::Danger, 1.0);
    }
    if Btn::new("Back to the booth").icon(Icon::ChevronLeft).quiet().show(ui, p, Rect::from_min_size(pos2(r.right() - 200.0, r.bottom() - 40.0), vec2(200.0, 32.0)), "g-back").clicked() {
        app.page = crate::show::Page::Booth;
    }
}
