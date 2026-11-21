//! A deck's Auto Gain under its TRIM knob, as rekordbox shows it in GRID EDIT: the value,
//! dragged up and down by hand (kept for the record), double-clicked back to the measured.
use crate::egui::{self, Color32, Sense, Ui};
use wo_deskcore::autogain::{AutoGain, Source};
use wo_deskcore::Desk;

/// Its words: "AG −6.2" (by hand "AG −6.2 ✎"), "AG …" while it is measured, "AG off".
pub(crate) fn words(a: &AutoGain, on: bool) -> String {
    match (on, a.db) {
        (false, _) => "AG off".to_owned(),
        (true, None) => "AG …".to_owned(),
        (true, Some(db)) => format!("AG {}{:.1}{}", if db < 0.0 { "−" } else { "+" }, db.abs(), if a.source == Some(Source::Hand) { " ✎" } else { "" }),
    }
}

fn tip(a: &AutoGain, on: bool) -> String {
    let how = "Drag up or down to set it for this record (kept) · double-click: the measured value again";
    if !on {
        return "Auto Gain is off (Settings › Booth)".to_owned();
    }
    let Some(db) = a.db else { return "Auto Gain: the record is being measured".to_owned() };
    let measured = a.lufs.map(|l| format!(", measured at {l:.1} LUFS")).unwrap_or_default();
    let whose = match a.source {
        Some(Source::Hand) => "set by hand",
        Some(Source::House) => "the house's measurement (this Desk's own on the way)",
        _ => "brought to −14 LUFS",
    };
    format!("Auto Gain {db:+.1} dB: {whose}{measured}.\n{how}")
}

/// Drawn by `draw` (its painter, place, words; the rect it took), and handled.
pub(crate) fn tag(ui: &Ui, desk: &mut Desk, d: usize, a: &AutoGain, on: bool, color: Color32, id: impl std::hash::Hash + std::fmt::Debug, draw: impl FnOnce(&str, Color32) -> egui::Rect) {
    let lit = if a.source == Some(Source::Hand) { Color32::from_rgb(0xE8, 0xB0, 0x4A) } else { color };
    let r = draw(&words(a, on), lit);
    let resp = ui.interact(r.expand(3.0), ui.scope_id().with(("auto-gain", id)), Sense::click_and_drag()).on_hover_cursor(egui::CursorIcon::ResizeVertical).on_hover_text(tip(a, on));
    if !on {
        return;
    }
    if resp.double_clicked() {
        desk.set_auto_gain(d, None);
    } else if resp.dragged() {
        let dy = resp.drag_delta().y;
        if dy != 0.0 {
            // a tenth of a dB a pixel, fine with shift
            let fine = ui.input(|i| i.modifiers.shift);
            let now = a.db.unwrap_or(0.0) - dy * if fine { 0.02 } else { 0.1 };
            desk.set_auto_gain(d, Some((now * 10.0).round() / 10.0));
        }
    }
}

