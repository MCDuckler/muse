//! The controllers page (v1: controllers_sheet.dart): what is plugged in and what it is taken
//! for, the layouts the Desk knows, each connected one's controls, and the monitor — every
//! packet as it came and how it was read, and what the Desk did with each control moved — the
//! thing to watch when new hardware first meets the Desk.
use eframe::egui::{self, Align2, Painter, Rect, Sense, Ui, pos2, vec2};
use wo_deskcore::Desk;

use crate::App;
use crate::ui::kit::{self, Btn};
use crate::ui::tokens as t;

const LINE: f32 = 20.0;

impl App {
    pub(crate) fn controllers_page(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let controllers = desk.controllers();
        let layouts = desk.controller_layouts();
        let mut y = r.top();
        kit::hint(p, pos2(r.left(), y + 8.0), Align2::LEFT_CENTER, "A DJ console plugged in drives the booth: the decks, the mixer, the pads. One the Desk knows is taken up by itself.");
        y += 28.0;
        // what is plugged in
        kit::section(p, pos2(r.left(), y), Align2::LEFT_TOP, "Plugged in");
        y += 24.0;
        if controllers.is_empty() {
            kit::clipped(p, pos2(r.left(), y + 10.0), "Nothing that looks like a controller (it is looked for every couple of seconds)", 13.0, "", t::muted(), r.width());
            y += LINE + 6.0;
        }
        for c in &controllers {
            crate::ui::icons::paint(p, Rect::from_center_size(pos2(r.left() + 6.0, y + 10.0), vec2(14.0, 14.0)), crate::ui::icons::Icon::Controller, if c.trouble.is_none() { t::ok() } else { t::warm() });
            let words = match &c.trouble {
                None => format!("{} — taken as {}", c.name, c.layout),
                Some(why) => format!("{}: {why}", c.name),
            };
            kit::clipped(p, pos2(r.left() + 20.0, y + 10.0), &words, 13.0, "", t::text(), r.width() - 20.0);
            y += LINE + 4.0;
        }
        let known: Vec<String> = layouts.iter().map(|l| format!("{} ({})", l.name, if l.protocol == wo_control::Protocol::Hid { "USB" } else { "MIDI" })).collect();
        let g = p.layout(format!("Knows: {}", known.join(" · ")), egui::FontId::new(11.5, crate::paint::family("")), t::faint(), r.width());
        let gh = g.size().y;
        p.galley(pos2(r.left(), y + 2.0), g, t::faint());
        y += gh + 14.0;
        // each connected one's controls
        let two = r.width() > 760.0;
        let mon_h = (r.bottom() - y) * if two { 1.0 } else { 0.55 };
        let (sheet, monitor) = if two {
            let w = 300.0;
            (Rect::from_min_size(pos2(r.left(), y), vec2(w, r.bottom() - y)), Rect::from_min_max(pos2(r.left() + w + 24.0, y), r.max))
        } else {
            (Rect::from_min_max(pos2(r.left(), y), pos2(r.right(), r.bottom() - mon_h)), Rect::from_min_max(pos2(r.left(), r.bottom() - mon_h + 10.0), r.max))
        };
        kit::section(p, sheet.min, Align2::LEFT_TOP, "Its controls");
        let open: Vec<&wo_control::Layout> = layouts.iter().filter(|l| controllers.iter().any(|c| c.trouble.is_none() && c.layout == l.name)).collect();
        let list = Rect::from_min_max(pos2(sheet.left(), sheet.top() + 24.0), sheet.max);
        if open.is_empty() {
            kit::hint(p, pos2(list.left(), list.top() + 10.0), Align2::LEFT_CENTER, "With one plugged in, its controls show here");
        } else {
            let rows: Vec<(String, String)> = open
                .iter()
                .flat_map(|l| {
                    // a control under two messages (a SHIFT's other note) once
                    let mut seen = std::collections::HashSet::new();
                    std::iter::once((l.name.clone(), String::new())).chain(l.inputs.iter().filter(move |i| seen.insert(i.id.clone())).map(|i| (i.id.clone(), format!("{:?}", i.kind).to_lowercase())))
                })
                .collect();
            let mut child = ui.new_child(egui::UiBuilder::new().max_rect(list));
            egui::ScrollArea::vertical().id_salt("ctl-sheet").auto_shrink([false, false]).show_rows(&mut child, 18.0, rows.len(), |ui, range| {
                for (id, kind) in &rows[range] {
                    let (rr, _) = ui.allocate_exact_size(vec2(list.width(), 18.0), Sense::hover());
                    let p = ui.painter();
                    if kind.is_empty() {
                        kit::clipped(p, pos2(rr.left(), rr.center().y), id, 12.0, "semi", t::soft(), rr.width());
                    } else {
                        kit::clipped(p, pos2(rr.left() + 8.0, rr.center().y), id, 11.5, "mono", t::text(), rr.width() - 80.0);
                        kit::text(p, pos2(rr.right() - 4.0, rr.center().y), Align2::RIGHT_CENTER, kind, 11.0, "", t::faint());
                    }
                }
            });
        }
        // the monitor
        let (packets, lines) = desk.control_monitor();
        kit::section(p, monitor.min, Align2::LEFT_TOP, "Monitor");
        let clear = Rect::from_min_size(pos2(monitor.right() - 70.0, monitor.top() - 6.0), vec2(70.0, 24.0));
        if Btn::new("Clear").quiet().size(10.5).show(ui, p, clear, "ctl-clear").clicked() {
            desk.clear_control_monitor();
        }
        kit::hint(p, pos2(monitor.left() + 84.0, monitor.top() + 7.0), Align2::LEFT_CENTER, "newest first · what came, how it was read, what it did");
        let mut rows: Vec<(std::time::Instant, String, String)> = vec![];
        for pk in &packets {
            let hex: Vec<String> = pk.bytes.iter().take(24).map(|b| format!("{b:02X}")).collect();
            let read = if pk.read.is_empty() { "— not in its layout".to_owned() } else { pk.read.join(", ") };
            rows.push((pk.at, format!("{}  {}", pk.from, hex.join(" ")), read));
        }
        for l in &lines {
            let did = if l.did.is_empty() { "nothing bound to it".to_owned() } else { l.did.join(", ") };
            rows.push((l.at, format!("{} {:.3}", l.id, l.value), format!("→ {did}")));
        }
        rows.sort_by(|a, b| b.0.cmp(&a.0));
        let list = Rect::from_min_max(pos2(monitor.left(), monitor.top() + 24.0), monitor.max);
        if rows.is_empty() {
            kit::hint(p, pos2(list.left(), list.top() + 10.0), Align2::LEFT_CENTER, "Quiet: move a control");
            return;
        }
        let now = std::time::Instant::now();
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(list));
        egui::ScrollArea::vertical().id_salt("ctl-monitor").auto_shrink([false, false]).show_rows(&mut child, LINE, rows.len(), |ui, range| {
            for (at, what, read) in &rows[range] {
                let (rr, _) = ui.allocate_exact_size(vec2(list.width(), LINE), Sense::hover());
                let p = ui.painter();
                let ago = now.saturating_duration_since(*at).as_secs_f32();
                kit::text(p, pos2(rr.left(), rr.center().y), Align2::LEFT_CENTER, &format!("{ago:5.1}s"), 10.5, "mono", t::faint());
                let half = (rr.width() - 56.0) * 0.5;
                kit::clipped(p, pos2(rr.left() + 56.0, rr.center().y), what, 11.5, "mono", t::text(), half - 8.0);
                kit::clipped(p, pos2(rr.left() + 56.0 + half, rr.center().y), read, 11.5, "", t::soft(), half);
            }
        });
        ui.ctx().request_repaint_after(std::time::Duration::from_millis(100));
    }
}
