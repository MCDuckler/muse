//! Words that fit their place. A caps label too wide for its room is set tighter, then
//! smaller (to [SMALLEST]); a control with an icon then shows the icon alone (its word moves
//! to its tooltip); anything else that still does not fit is cut with an ellipsis — and
//! counted, so the pages test fails on it (nothing on the Desk overflows or is cut short
//! where it is laid out).
use std::cell::RefCell;

use eframe::egui::{Align2, Color32, Painter, Pos2, Rect};

use crate::paint::{SPACING, label_job};

/// The smallest a caps label is set to fit.
pub const SMALLEST: f32 = 9.5;

thread_local! {
    static MISSES: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    /// The panel (or modal card) being drawn into.
    static PANEL: RefCell<Option<Rect>> = const { RefCell::new(None) };
}

/// The panel controls are drawn into from now on.
pub fn panel(r: Rect) {
    PANEL.with(|p| *p.borrow_mut() = Some(r));
}

/// A control at `r`, named `what`, drawn where `clip` shows: counted as a miss when it
/// leaves the panel it is in (in a scrolling list, inside its panel, anything goes).
pub fn inside(what: &str, r: Rect, clip: Rect) {
    let Some(panel) = PANEL.with(|p| *p.borrow()) else { return };
    // a list scrolling inside the panel: clipped above and below by it, so only its sides count
    let scrolling = clip.top() >= panel.top() - 1.0 && clip.bottom() <= panel.bottom() + 1.0 && clip.height() < panel.height() - 4.0;
    let bound = if scrolling { Rect::from_x_y_ranges(panel.x_range(), r.y_range()) } else { panel };
    if clip.intersects(r) && !bound.expand(0.5).contains_rect(r) {
        let out = (panel.top() - r.top()).max(r.bottom() - panel.bottom()).max(panel.left() - r.left()).max(r.right() - panel.right());
        MISSES.with(|m| {
            let mut m = m.borrow_mut();
            if m.len() < 500 {
                m.push(format!("“{what}” leaves its panel by {out:.0} px"));
            }
        });
    }
}

/// Words that did not fit their room, recorded (the pages test reads them).
pub fn miss(words: &str, need: f32, room: f32) {
    MISSES.with(|m| {
        let mut m = m.borrow_mut();
        if m.len() < 500 {
            m.push(format!("“{words}” needs {need:.0} px, has {room:.0}"));
        }
    });
}

/// The words that did not fit since the last call.
#[cfg_attr(not(test), allow(dead_code))]
pub fn take() -> Vec<String> {
    MISSES.with(|m| std::mem::take(&mut *m.borrow_mut()))
}

/// How a caps label of `s` fits `room`: its size and letter spacing, stepping the spacing
/// down first, then the size (by half points, to [SMALLEST]). None: it does not, even so.
pub fn caps(p: &Painter, s: &str, size: f32, room: f32) -> Option<(f32, f32)> {
    let w = |size: f32, sp: f32| p.layout_job(label_job(s, size, sp, Color32::WHITE)).size().x;
    for sp in [SPACING, 0.05, 0.02] {
        if w(size, sp) <= room {
            return Some((size, sp));
        }
    }
    let mut z = size - 0.5;
    while z >= SMALLEST - 1e-3 {
        if w(z, 0.02) <= room {
            return Some((z, 0.02));
        }
        z -= 0.5;
    }
    None
}

/// A caps label set to fit `room` (see [caps]); where it cannot, cut with an ellipsis and
/// counted as a miss. Its rect.
pub fn label(p: &Painter, pos: Pos2, anchor: Align2, s: &str, size: f32, color: Color32, room: f32) -> Rect {
    match caps(p, s, size, room) {
        Some((z, sp)) => {
            let g = p.layout_job(label_job(s, z, sp, color));
            let r = anchor.anchor_size(pos, g.size());
            p.galley(r.min, g, color);
            r
        }
        None => {
            let need = p.layout_job(label_job(s, SMALLEST, 0.02, color)).size().x;
            miss(s, need, room);
            let mut job = label_job(s, SMALLEST, 0.02, color);
            job.wrap = eframe::egui::text::TextWrapping { max_width: room.max(8.0), max_rows: 1, break_anywhere: true, overflow_character: Some('…') };
            let g = p.layout_job(job);
            let r = anchor.anchor_size(pos, g.size());
            p.galley(r.min, g, color);
            r
        }
    }
}
