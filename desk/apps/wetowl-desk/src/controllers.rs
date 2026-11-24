//! The controllers page (v1: controllers_sheet.dart): what is plugged in and what it is taken
//! for, the layouts the Desk knows, each connected one's controls, and the monitor — every
//! packet as it came and how it was read, and what the Desk did with each control moved — the
//! thing to watch when new hardware first meets the Desk. Any MIDI controller (a keyboard's
//! knobs and faders: an Oxygen Pro's) is mapped onto the booth here by hand: a booth control
//! chosen, then the controller's own moved.
use eframe::egui::{self, Align2, Painter, Rect, Sense, Ui, pos2, vec2};
use wo_control::{Kind, Learning, Mapped, Target};
use wo_deskcore::{ControlLine, Desk};

use crate::App;
use crate::ui::icons::Icon;
use crate::ui::kit::{self, Btn};
use crate::ui::tokens::{self as t, Tone};

const LINE: f32 = 20.0;

impl App {
    pub(crate) fn controllers_page(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let controllers = desk.controllers();
        let layouts = desk.controller_layouts();
        let mut y = r.top();
        kit::hint(p, pos2(r.left(), y + 8.0), Align2::LEFT_CENTER, "A DJ console plugged in drives the booth: the decks, the mixer, the pads. One the Desk knows is taken up by itself; any other MIDI controller is mapped by hand.");
        y += 28.0;
        // what is plugged in
        kit::section(p, pos2(r.left(), y), Align2::LEFT_TOP, "Plugged in");
        y += 24.0;
        if controllers.is_empty() {
            kit::clipped(p, pos2(r.left(), y + 10.0), "Nothing that looks like a controller (it is looked for every couple of seconds)", 13.0, "", t::muted(), r.width());
            y += LINE + 6.0;
        }
        for c in &controllers {
            crate::ui::icons::paint(p, Rect::from_center_size(pos2(r.left() + 6.0, y + 10.0), vec2(14.0, 14.0)), Icon::Controller, if c.trouble.is_none() { t::ok() } else { t::warm() });
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
        // the booth's controls to map onto (or a known console's own), and the monitor
        let two = r.width() > 760.0;
        let mon_h = (r.bottom() - y) * if two { 1.0 } else { 0.4 };
        let (sheet, monitor) = if two {
            let w = (r.width() * 0.5).clamp(300.0, 480.0);
            (Rect::from_min_size(pos2(r.left(), y), vec2(w, r.bottom() - y)), Rect::from_min_max(pos2(r.left() + w + 24.0, y), r.max))
        } else {
            (Rect::from_min_max(pos2(r.left(), y), pos2(r.right(), r.bottom() - mon_h)), Rect::from_min_max(pos2(r.left(), r.bottom() - mon_h + 10.0), r.max))
        };
        let tab_id = egui::Id::unique("ctl-tab");
        let tab: usize = ui.ctx().data(|d| d.get_temp(tab_id)).unwrap_or(0);
        let tabs = Rect::from_min_size(sheet.min - vec2(0.0, 4.0), vec2(sheet.width().min(280.0), 26.0));
        if let Some(i) = kit::segmented(ui, p, tabs, &["Map by hand", "Its controls"], Some(tab), Tone::Neutral, "ctl-tabs") {
            ui.ctx().data_mut(|d| d.insert_temp(tab_id, i));
            if i != 0 {
                desk.stop_learning_control();
            }
        }
        let below = Rect::from_min_max(pos2(sheet.left(), sheet.top() + 32.0), sheet.max);
        let (packets, lines) = desk.control_monitor();
        if tab == 0 {
            map_sheet(desk, ui, p, below, &lines);
        } else {
            its_controls(ui, p, below, &controllers, &layouts);
        }
        monitor_list(desk, ui, p, monitor, &packets, &lines);
    }
}

/// The layouts' own controls, for the consoles plugged in that the Desk knows.
fn its_controls(ui: &mut Ui, p: &Painter, list: Rect, controllers: &[wo_control::Controller], layouts: &[wo_control::Layout]) {
    let open: Vec<&wo_control::Layout> = layouts.iter().filter(|l| controllers.iter().any(|c| c.trouble.is_none() && c.layout.starts_with(&l.name))).collect();
    if open.is_empty() {
        kit::hint(p, pos2(list.left(), list.top() + 10.0), Align2::LEFT_CENTER, "With a console the Desk knows plugged in, its controls show here");
        return;
    }
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

/// What to move for a booth control of kind `k`.
fn move_words(k: Kind) -> &'static str {
    match k {
        Kind::Button => "press a pad, key or button…",
        Kind::Fader => "move a fader or turn a knob…",
        Kind::Encoder => "turn a knob…",
        _ => "turn a knob or move a fader…",
    }
}

/// The booth's controls, each with what is mapped onto it by hand. One clicked listens for
/// the controller's control to move (on any MIDI port); moving one already mapped lights its row.
fn map_sheet(desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, lines: &[ControlLine]) {
    let learning = desk.learning_control();
    let mapped = desk.control_mappings();
    let ports = desk.midi_ports();
    let listening = match &learning {
        Learning::Listening(t) => Some(*t),
        _ => None,
    };
    // the head: what to do, what is listened for, or what was just mapped
    let head = Rect::from_min_size(r.min, vec2(r.width(), 40.0));
    let top = pos2(head.left(), head.top() + 9.0);
    match &learning {
        _ if !desk.has_controllers() => {
            kit::hint(p, top, Align2::LEFT_CENTER, "Controllers are off in this Desk");
        }
        Learning::Listening(target) => {
            let pulse = (ui.input(|i| i.time) * 3.0).sin() as f32 * 0.25 + 0.75;
            let what = format!("{} · {}: {}", target.group, target.name, move_words(target.kind));
            kit::clipped(p, top, &what, 12.5, "semi", kit::alpha_of(t::warm(), pulse), head.width() - 90.0);
            let cancel = Rect::from_min_size(pos2(head.right() - 80.0, head.top() - 3.0), vec2(80.0, 24.0));
            if Btn::new("Cancel").quiet().size(10.5).show(ui, p, cancel, "ctl-learn-cancel").on_hover_text("Stop listening").clicked() {
                desk.stop_learning_control();
            }
            ui.ctx().request_repaint();
        }
        Learning::Caught(target, m) => {
            let what = format!("{} · {}  ←  {} on {}", target.group, target.name, m.words(), m.port);
            kit::clipped(p, top, &what, 12.5, "semi", t::ok(), head.width());
        }
        Learning::Off => {
            kit::clipped(p, top, "Click a control, then move the knob, fader or pad you want for it", 12.0, "", t::soft(), head.width());
        }
    }
    let ins = if ports.is_empty() { "MIDI in: none".to_owned() } else { format!("MIDI in: {}", ports.join(" · ")) };
    kit::clipped(p, pos2(head.left(), head.top() + 29.0), &ins, 11.0, "", t::faint(), head.width());
    // the control a hand moved last, for a moment
    let now = std::time::Instant::now();
    let moved = lines.iter().rev().find(|l| now.saturating_duration_since(l.at).as_secs_f32() < 1.2).map(|l| l.id.clone());
    // the rows: each group's name (None), then its controls
    let mut rows: Vec<(Option<Target>, &'static str)> = vec![];
    let mut group = "";
    for target in wo_control::learn::targets() {
        if target.group != group {
            group = target.group;
            rows.push((None, group));
        }
        rows.push((Some(target), group));
    }
    const ROW: f32 = 24.0;
    let list = Rect::from_min_max(pos2(r.left(), head.bottom() + 6.0), r.max);
    let mut child = ui.new_child(egui::UiBuilder::new().max_rect(list));
    let mut clicked: Option<Target> = None;
    let mut forget: Option<&'static str> = None;
    egui::ScrollArea::vertical().id_salt("ctl-map").auto_shrink([false, false]).show_rows(&mut child, ROW, rows.len(), |ui, range| {
        let w = list.width() - 10.0;
        for &(target, group) in &rows[range] {
            let Some(target) = target else {
                let (rr, _) = ui.allocate_exact_size(vec2(w, ROW), Sense::hover());
                kit::clipped(ui.painter(), pos2(rr.left(), rr.center().y + 3.0), group, 11.5, "semi", t::label(), rr.width());
                continue;
            };
            let (rr, resp) = ui.allocate_exact_size(vec2(w, ROW), Sense::click());
            let p = ui.painter().clone();
            let on: Vec<&Mapped> = mapped.iter().filter(|m| m.id == target.id).collect();
            let here = listening.is_some_and(|l| l.id == target.id);
            let lit = !on.is_empty() && moved.as_deref() == Some(target.id);
            let fill = if here {
                kit::alpha_of(t::warm(), 0.14)
            } else if lit {
                kit::alpha_of(t::focus(), 0.16)
            } else if resp.hovered() {
                t::fill_hover()
            } else {
                egui::Color32::TRANSPARENT
            };
            p.rect_filled(rr, 4.0, fill);
            let kind = match target.kind {
                Kind::Button => "button",
                Kind::Fader => "fader",
                Kind::Encoder => "turn",
                _ => "knob",
            };
            let name_w = (rr.width() * 0.38).max(110.0);
            kit::clipped(&p, pos2(rr.left() + 8.0, rr.center().y), target.name, 12.0, "", t::text(), name_w - 12.0);
            kit::text(&p, pos2(rr.left() + name_w, rr.center().y), Align2::LEFT_CENTER, kind, 10.5, "", t::faint());
            let x = rr.left() + name_w + 48.0;
            let room = rr.right() - 30.0 - x;
            let (words, colour) = if here {
                (move_words(target.kind).to_owned(), t::warm())
            } else if let Some(m) = on.first() {
                let more = if on.len() > 1 { format!("  +{}", on.len() - 1) } else { String::new() };
                (format!("{} · {}{more}", m.words(), m.port), if lit { t::high() } else { t::soft() })
            } else {
                ("—".to_owned(), t::faint())
            };
            kit::clipped(&p, pos2(x, rr.center().y), &words, 11.0, "", colour, room);
            if !on.is_empty() {
                let x_r = Rect::from_center_size(pos2(rr.right() - 13.0, rr.center().y), vec2(22.0, 20.0));
                if Btn::new("").icon(Icon::Close).quiet().show(ui, &p, x_r, ("ctl-forget", target.id)).on_hover_text("Unmap").clicked() {
                    forget = Some(target.id);
                    continue;
                }
            }
            let tip = if on.is_empty() { "Click, then move a control on the controller" } else { "Click to map another control onto it" };
            if resp.on_hover_cursor(egui::CursorIcon::PointingHand).on_hover_text(tip).clicked() {
                clicked = Some(target);
            }
        }
    });
    if moved.is_some() {
        ui.ctx().request_repaint_after(std::time::Duration::from_millis(100));
    }
    if let Some(id) = forget {
        desk.forget_control(id);
    }
    if let Some(target) = clicked {
        if listening.is_some_and(|l| l.id == target.id) {
            desk.stop_learning_control();
        } else {
            desk.learn_control(target);
        }
    }
}

/// The monitor: every packet as it came and how it was read, and what the Desk did with it.
fn monitor_list(desk: &mut Desk, ui: &mut Ui, p: &Painter, monitor: Rect, packets: &[wo_control::Packet], lines: &[ControlLine]) {
    kit::section(p, monitor.min, Align2::LEFT_TOP, "Monitor");
    let clear = Rect::from_min_size(pos2(monitor.right() - 70.0, monitor.top() - 6.0), vec2(70.0, 24.0));
    if Btn::new("Clear").quiet().size(10.5).show(ui, p, clear, "ctl-clear").clicked() {
        desk.clear_control_monitor();
    }
    kit::hint(p, pos2(monitor.left() + 84.0, monitor.top() + 7.0), Align2::LEFT_CENTER, "newest first · what came, how it was read, what it did");
    let mut rows: Vec<(std::time::Instant, String, String)> = vec![];
    for pk in packets {
        let hex: Vec<String> = pk.bytes.iter().take(24).map(|b| format!("{b:02X}")).collect();
        let read = if pk.read.is_empty() { "— not in its layout".to_owned() } else { pk.read.join(", ") };
        rows.push((pk.at, format!("{}  {}", pk.from, hex.join(" ")), read));
    }
    for l in lines {
        let did = if l.did.is_empty() { "nothing bound to it".to_owned() } else { l.did.join(", ") };
        rows.push((l.at, format!("{} {:.3}", l.id, l.value), format!("→ {did}")));
    }
    rows.sort_by(|a, b| b.0.cmp(&a.0));
    let list = Rect::from_min_max(pos2(monitor.left(), monitor.top() + 24.0), monitor.max);
    ui.ctx().request_repaint_after(std::time::Duration::from_millis(100));
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
}
