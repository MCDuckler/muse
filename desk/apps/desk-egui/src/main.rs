//! The bake-off's egui Desk: the glass booth of the Look board, painted by hand over
//! one blurred stage, driven by wo-deskcore. `--bench 30 [--out DIR]` measures it.
use std::sync::{Arc, mpsc};
use std::time::Instant;

use eframe::egui::{
    self, Align2, Color32, ColorImage, CornerRadius, FontFamily, FontId, Mesh, Painter, Pos2, Rect, Sense, Stroke, StrokeKind, TextFormat,
    TextureHandle, TextureOptions, pos2, text::LayoutJob, vec2,
};
use wo_deskcore::bench::Bench;
use wo_deskcore::theme::{self, Rgba};
use wo_deskcore::{Desk, MIX_BARS, PadKind, SWAP_BAR, Snapshot};

fn col(v: Rgba) -> Color32 {
    Color32::from_rgba_unmultiplied(v[0], v[1], v[2], v[3])
}

fn alpha(v: Rgba, a: f32) -> Color32 {
    Color32::from_rgba_unmultiplied(v[0], v[1], v[2], (a * 255.0) as u8)
}

fn white(a: f32) -> Color32 {
    Color32::from_white_alpha((a * 255.0) as u8)
}

fn family(name: &str) -> FontFamily {
    match name {
        "" => FontFamily::Proportional,
        "mono" => FontFamily::Monospace,
        n => FontFamily::Name(n.into()),
    }
}

fn fonts(ctx: &egui::Context) {
    let mut f = egui::FontDefinitions::default();
    for (name, bytes) in [
        ("inter", theme::fonts::INTER),
        ("inter-semi", theme::fonts::INTER_SEMI),
        ("mono", theme::fonts::MONO),
        ("mono-semi", theme::fonts::MONO_SEMI),
        ("label", theme::fonts::LABEL),
        ("mark", theme::fonts::MARK),
    ] {
        f.font_data.insert(name.into(), Arc::new(egui::FontData::from_static(bytes)));
    }
    f.families.entry(FontFamily::Proportional).or_default().insert(0, "inter".into());
    f.families.entry(FontFamily::Monospace).or_default().insert(0, "mono".into());
    for (fam, font) in [("semi", "inter-semi"), ("label", "label"), ("mono-semi", "mono-semi"), ("mark", "mark")] {
        f.families.insert(FontFamily::Name(fam.into()), vec![font.into(), "inter".into()]);
    }
    ctx.set_fonts(f);
}

/// Text at `pos` anchored by `anchor`.
fn text(p: &Painter, pos: Pos2, anchor: Align2, s: &str, size: f32, fam: &str, color: Color32) -> Rect {
    p.text(pos, anchor, s, FontId::new(size, family(fam)), color)
}

/// A label: condensed caps, tracked.
fn label(p: &Painter, pos: Pos2, anchor: Align2, s: &str, color: Color32) -> Rect {
    label_sized(p, pos, anchor, s, 11.0, color)
}

fn label_sized(p: &Painter, pos: Pos2, anchor: Align2, s: &str, size: f32, color: Color32) -> Rect {
    let mut job = LayoutJob::default();
    job.append(
        &s.to_uppercase(),
        0.0,
        TextFormat { font_id: FontId::new(size, family("label")), color, extra_letter_spacing: size * 0.09, ..Default::default() },
    );
    let galley = p.layout_job(job);
    let r = anchor.anchor_size(pos, galley.size());
    p.galley(r.min, galley, color);
    r
}

fn panel(p: &Painter, r: Rect, dense: bool) {
    let fill = col(if dense { theme::GLASS_DENSE } else { theme::GLASS_PANEL });
    p.rect(r, CornerRadius::same(10), fill, Stroke::new(1.0, col(theme::GLASS_EDGE)), StrokeKind::Inside);
    p.line_segment([pos2(r.left() + 10.0, r.top() + 1.5), pos2(r.right() - 10.0, r.top() + 1.5)], Stroke::new(1.0, col(theme::GLASS_HIGHLIGHT)));
}

#[derive(Clone, Copy, PartialEq)]
enum Lit {
    No,
    Deck(usize),
    Ok,
}

/// A button, painted; its response.
fn button(ui: &mut egui::Ui, p: &Painter, r: Rect, s: &str, lit: Lit, id: impl std::hash::Hash + std::fmt::Debug) -> egui::Response {
    let resp = ui.interact(r, ui.scope_id().with(id), Sense::click());
    let (bg, edge, ink) = match lit {
        Lit::No => (white(0.05), white(0.11), col(theme::SOFT)),
        Lit::Deck(d) => (alpha(theme::DECKS[d], 0.15), alpha(theme::DECKS[d], 0.6), col(theme::TINTS[d])),
        Lit::Ok => (alpha(theme::OK, 0.15), alpha(theme::OK, 0.6), Color32::from_rgb(0xCF, 0xF5, 0xDF)),
    };
    let bg = if resp.hovered() { bg.gamma_multiply(1.6) } else { bg };
    p.rect(r, CornerRadius::same(6), bg, Stroke::new(1.0, edge), StrokeKind::Inside);
    label_sized(p, r.center(), Align2::CENTER_CENTER, s, 11.5, ink);
    resp
}

/// The two edges of a band, mirrored around `mid`, as one mesh.
fn band(mesh: &mut Mesh, x0: f32, step: f32, mid: f32, amps: impl Iterator<Item = f32>, color: Color32) {
    let base = mesh.vertices.len() as u32;
    let mut n = 0u32;
    for (i, a) in amps.enumerate() {
        let x = x0 + i as f32 * step;
        mesh.colored_vertex(pos2(x, mid - a), color);
        mesh.colored_vertex(pos2(x, mid + a), color);
        if i > 0 {
            let k = base + 2 * (i as u32 - 1);
            mesh.add_triangle(k, k + 1, k + 2);
            mesh.add_triangle(k + 1, k + 3, k + 2);
        }
        n += 1;
    }
    let _ = n;
}

/// A knob on a 270° sweep (bipolar ones drawn from 12 o'clock); drag up or down.
fn knob(ui: &mut egui::Ui, p: &Painter, c: Pos2, v: f32, color: Color32, bipolar: bool, id: impl std::hash::Hash + std::fmt::Debug) -> Option<f32> {
    let r = Rect::from_center_size(c, vec2(36.0, 36.0));
    let resp = ui.interact(r, ui.scope_id().with(id), Sense::drag());
    let arc = |a0: f32, a1: f32, color: Color32| {
        let n = 24;
        let pts: Vec<Pos2> = (0..=n).map(|i| {
            let a = (a0 + (a1 - a0) * i as f32 / n as f32).to_radians();
            pos2(c.x + 13.5 * a.cos(), c.y + 13.5 * a.sin())
        }).collect();
        p.add(egui::Shape::line(pts, Stroke::new(2.7, color)));
    };
    arc(135.0, 405.0, col(theme::EDGE));
    let at = 135.0 + 270.0 * v;
    if bipolar { arc(270.0f32.min(at), 270.0f32.max(at), color) } else { arc(135.0, at, color) }
    p.circle(c, 9.5, Color32::from_rgb(0x1E, 0x20, 0x27), Stroke::new(1.0, Color32::from_rgb(0x33, 0x36, 0x3E)));
    let a = at.to_radians();
    p.line_segment([c, pos2(c.x + 8.0 * a.cos(), c.y + 8.0 * a.sin())], Stroke::new(2.0, col(theme::TEXT)));
    resp.dragged().then(|| (v - resp.drag_delta().y * 0.004).clamp(0.0, 1.0))
}

/// A vertical fader: track, cap; drag the cap.
fn vfader(ui: &mut egui::Ui, p: &Painter, r: Rect, v: f32, id: impl std::hash::Hash + std::fmt::Debug) -> Option<f32> {
    let resp = ui.interact(r, ui.scope_id().with(id), Sense::drag());
    p.rect_filled(Rect::from_center_size(r.center(), vec2(4.0, r.height())), CornerRadius::same(2), col(theme::LINE));
    let y = r.bottom() - 9.0 - v * (r.height() - 18.0);
    p.rect_filled(Rect::from_center_size(pos2(r.center().x, y), vec2(30.0, 18.0)), CornerRadius::same(4), col(theme::CAP));
    resp.dragged().then(|| (v - resp.drag_delta().y / (r.height() - 18.0)).clamp(0.0, 1.0))
}

fn meter(p: &Painter, r: Rect, level: f32, n: usize) {
    let h = (r.height() - (n - 1) as f32 * 2.0) / n as f32;
    for i in 0..n {
        let on = (n - i) as f32 / n as f32 <= level;
        let c = if !on { Color32::from_rgb(0x22, 0x25, 0x2C) } else if i < 2 { col(theme::HOT) } else if i < 5 { col(theme::WARM) } else { Color32::from_rgb(0xD7, 0xDA, 0xE0) };
        p.rect_filled(Rect::from_min_size(pos2(r.left(), r.top() + i as f32 * (h + 2.0)), vec2(r.width(), h)), CornerRadius::same(1), c);
    }
}

fn mmss(s: f64) -> String {
    let s = s.max(0.0);
    format!("{}:{:04.1}", (s / 60.0) as u32, s % 60.0)
}

struct App {
    desk: Desk,
    backdrop: TextureHandle,
    ball: TextureHandle,
    search: String,
    bench: Option<Bench>,
    shot: Option<mpsc::Receiver<Arc<ColorImage>>>,
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        fonts(&cc.egui_ctx);
        let tex = |name: &str, b: wo_deskcore::Backdrop| {
            cc.egui_ctx.load_texture(name, ColorImage::from_rgba_unmultiplied([b.width as usize, b.height as usize], &b.rgba), TextureOptions::LINEAR)
        };
        let desk = Desk::open();
        App {
            desk,
            backdrop: tex("backdrop", wo_deskcore::backdrop::backdrop(480, 270)),
            ball: tex("ball", wo_deskcore::backdrop::ball()),
            search: String::new(),
            bench: Bench::from_args(if std::env::var("WO_RENDERER").as_deref() == Ok("glow") { "egui-glow" } else { "egui-wgpu" }),
            shot: None,
        }
    }

    fn top_bar(&mut self, ui: &mut egui::Ui, p: &Painter, r: Rect, s: &Snapshot) {
        panel(p, r, false);
        let logo = Rect::from_min_size(pos2(r.left() + 6.0, r.center().y - 17.0), vec2(104.0, 34.0));
        p.rect_filled(logo, CornerRadius::same(6), col(theme::RED));
        let w = text(p, pos2(logo.left() + 10.0, logo.center().y + 1.0), Align2::LEFT_CENTER, "WET", 27.0, "mark", Color32::WHITE);
        let ball = Rect::from_min_size(pos2(w.right() + 1.0, logo.center().y - 11.0), vec2(22.0, 22.0));
        p.image(self.ball.id(), ball, Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)), Color32::WHITE);
        text(p, pos2(ball.right() + 1.0, logo.center().y + 1.0), Align2::LEFT_CENTER, "WL", 27.0, "mark", Color32::WHITE);
        let mut x = logo.right() + 18.0;
        for (i, tab) in ["Booth", "Show", "Crate", "Pool"].iter().enumerate() {
            let t = label_sized(p, pos2(x + 16.0, r.center().y), Align2::LEFT_CENTER, tab, 13.0, if i == 0 { col(theme::TEXT) } else { Color32::from_rgb(0x8D, 0x91, 0x9B) });
            if i == 0 {
                p.rect_filled(Rect::from_min_size(pos2(x, r.bottom() - 2.0), vec2(t.width() + 32.0, 2.0)), CornerRadius::ZERO, col(theme::RED));
            }
            x = t.right() + 16.0;
        }
        let m = r.center().x;
        let l = label(p, pos2(m - 60.0, r.center().y), Align2::RIGHT_CENTER, "Master", col(theme::FAINT_ON_GLASS));
        let v = text(p, pos2(l.right() + 10.0, r.center().y), Align2::LEFT_CENTER, &format!("{:.2}", s.master_bpm), 22.0, "mono-semi", col(theme::TEXT));
        let master = s.decks.iter().position(|d| d.master).unwrap_or(0);
        label(p, pos2(v.right() + 10.0, r.center().y), Align2::LEFT_CENTER, if master == 0 { "Deck A" } else { "Deck B" }, col(theme::DECKS[master]));
        let set = s.set_seconds as u64;
        label(p, pos2(m + 160.0, r.center().y), Align2::LEFT_CENTER, "Set", col(theme::FAINT_ON_GLASS));
        text(p, pos2(m + 190.0, r.center().y), Align2::LEFT_CENTER, &format!("{}:{:02}:{:02}", set / 3600, set / 60 % 60, set % 60), 15.0, "mono", col(theme::SOFT));
        // right side, from the right edge in
        let mut rx = r.right() - 8.0;
        let gear = Rect::from_min_size(pos2(rx - 34.0, r.center().y - 15.0), vec2(34.0, 30.0));
        button(ui, p, gear, "⚙", Lit::No, "settings");
        rx = gear.left() - 12.0;
        let h = label(p, pos2(rx, r.center().y), Align2::RIGHT_CENTER, "House", col(theme::MUTED));
        p.circle_filled(pos2(h.left() - 8.0, r.center().y), 3.5, col(theme::OK));
        rx = h.left() - 24.0;
        let pct = (s.load.average * 100.0).round();
        let t = text(p, pos2(rx, r.center().y), Align2::RIGHT_CENTER, &format!("{pct:.0}%"), 12.0, "mono", col(theme::MUTED));
        let bar = Rect::from_min_size(pos2(t.left() - 72.0, r.center().y - 3.0), vec2(64.0, 6.0));
        p.rect_filled(bar, CornerRadius::same(3), col(theme::LINE));
        p.rect_filled(Rect::from_min_size(bar.min, vec2(64.0 * (s.load.average as f32).min(1.0), 6.0)), CornerRadius::same(3), Color32::from_rgb(0x9D, 0xA1, 0xAA));
        let d = label(p, pos2(bar.left() - 8.0, r.center().y), Align2::RIGHT_CENTER, "DSP", col(theme::FAINT_ON_GLASS));
        let rec = Rect::from_min_size(pos2(d.left() - 80.0, r.center().y - 15.0), vec2(66.0, 30.0));
        button(ui, p, rec, "  Rec", Lit::No, "rec");
        p.circle_stroke(pos2(rec.left() + 16.0, rec.center().y), 4.0, Stroke::new(1.5, col(theme::RED)));
        let auto = Rect::from_min_size(pos2(rec.left() - 104.0, r.center().y - 15.0), vec2(96.0, 30.0));
        if button(ui, p, auto, "  Auto DJ", if s.auto { Lit::Ok } else { Lit::No }, "auto").clicked() {
            self.desk.set_auto(!s.auto);
        }
        p.circle_filled(pos2(auto.left() + 14.0, auto.center().y), 3.5, if s.auto { col(theme::OK) } else { col(theme::FAINT) });
    }

    fn overviews(&self, p: &Painter, r: Rect, s: &Snapshot) {
        panel(p, r, true);
        for d in 0..2 {
            let y = r.top() + 8.0 + d as f32 * 28.0;
            text(p, pos2(r.left() + 12.0, y + 11.0), Align2::LEFT_CENTER, ["A", "B"][d], 12.0, "mono-semi", col(theme::DECKS[d]));
            let bar = Rect::from_min_max(pos2(r.left() + 36.0, y), pos2(r.right() - 86.0, y + 22.0));
            let cols = self.desk.overview(d, (bar.width() / 3.0) as usize);
            let mut mesh = Mesh::default();
            band(&mut mesh, bar.left(), 3.0, bar.center().y, cols.iter().map(|c| c[0] * 10.0 + 1.0), alpha(theme::DECKS[d], 0.85));
            p.add(mesh);
            let v = &s.decks[d];
            let at = bar.left() + bar.width() * (v.heard / v.length.max(1.0)).clamp(0.0, 1.0) as f32;
            p.rect_filled(Rect::from_min_max(bar.min, pos2(at, bar.bottom())), CornerRadius::ZERO, alpha(theme::GROUND, 0.55));
            for pad in v.pads.iter().flatten() {
                let x = bar.left() + bar.width() * (pad.at / v.length.max(1.0)) as f32;
                p.line_segment([pos2(x, bar.top()), pos2(x, bar.bottom())], Stroke::new(2.0, alpha(theme::TEXT, 0.7)));
            }
            p.rect_filled(Rect::from_min_size(pos2(at, bar.top()), vec2(3.0, 22.0)), CornerRadius::ZERO, Color32::WHITE);
            text(p, pos2(r.right() - 12.0, y + 11.0), Align2::RIGHT_CENTER, &format!("−{}", mmss(v.length - v.heard)), 12.0, "mono", col(theme::MUTED));
        }
    }

    fn waves(&self, p: &Painter, r: Rect, s: &Snapshot) {
        panel(p, r, true);
        let clip = p.with_clip_rect(r.shrink(1.0));
        for d in 0..2 {
            let w = Rect::from_min_size(pos2(r.left(), r.top() + 8.0 + d as f32 * 116.0), vec2(r.width(), 112.0));
            let v = &s.decks[d];
            let (cols, lines) = self.desk.waveform(d, v.heard, w.width(), 3.0, 110.0);
            for x in &lines.beats {
                clip.line_segment([pos2(w.left() + x, w.top()), pos2(w.left() + x, w.bottom())], Stroke::new(1.0, white(0.10)));
            }
            for x in &lines.bars {
                clip.line_segment([pos2(w.left() + x, w.top()), pos2(w.left() + x, w.bottom())], Stroke::new(1.5, white(0.30)));
            }
            let mid = w.center().y;
            let mut mesh = Mesh::default();
            band(&mut mesh, w.left(), 3.0, mid, cols.iter().map(|c| c[0] * 50.0), alpha(theme::DECKS[d], 0.92));
            band(&mut mesh, w.left(), 3.0, mid, cols.iter().map(|c| c[1] * 30.0), alpha(theme::TINTS[d], 0.9));
            band(&mut mesh, w.left(), 3.0, mid, cols.iter().map(|c| c[2] * 16.0), alpha(theme::HIGH, 0.85));
            clip.add(mesh);
            clip.rect_filled(Rect::from_min_max(w.min, pos2(w.center().x, w.bottom())), CornerRadius::ZERO, alpha(theme::GROUND, 0.42));
            for (x, pad) in &lines.pads {
                let c = col(theme::pad(pad.kind));
                let x = w.left() + x;
                clip.rect_filled(Rect::from_min_size(pos2(x, w.top()), vec2(2.0, w.height())), CornerRadius::ZERO, c);
                clip.add(egui::Shape::convex_polygon(vec![pos2(x, w.top()), pos2(x + 12.0, w.top()), pos2(x, w.top() + 12.0)], c, Stroke::NONE));
                label(&clip, pos2(x + 16.0, w.top() + 6.0), Align2::LEFT_TOP, &format!("{} {}", pad.n, pad_name(pad.kind)), c);
            }
            clip.rect_filled(Rect::from_center_size(pos2(w.center().x, mid), vec2(2.0, w.height())), CornerRadius::ZERO, Color32::WHITE);
            let t = text(p, pos2(w.left() + 12.0, w.top() + 8.0), Align2::LEFT_TOP, ["A", "B"][d], 12.0, "mono-semi", col(theme::DECKS[d]));
            let state = if v.master { "Master · playing" } else if v.synced { "Sync · in step" } else if v.playing { "Playing" } else { "Parked" };
            label(p, pos2(t.right() + 8.0, w.top() + 9.0), Align2::LEFT_TOP, state, col(theme::SOFT));
        }
        if let Some(f) = s.decks.iter().find(|d| d.synced) {
            let c = pos2(r.center().x, r.top() + 122.0);
            let pill = Rect::from_center_size(c, vec2(250.0, 18.0));
            p.rect_filled(pill, CornerRadius::same(9), alpha(theme::GROUND, 0.85));
            label(p, pos2(pill.left() + 10.0, c.y), Align2::LEFT_CENTER, "Phase", col(theme::FAINT_ON_GLASS));
            let track = Rect::from_center_size(pos2(c.x, c.y), vec2(120.0, 4.0));
            p.rect_filled(track, CornerRadius::same(2), col(theme::EDGE));
            let off = (f.phase_ms as f32 / 20.0).clamp(-1.0, 1.0) * 58.0;
            p.rect_filled(Rect::from_center_size(pos2(c.x + off, c.y), vec2(4.0, 10.0)), CornerRadius::same(2), col(theme::OK));
            text(p, pos2(pill.right() - 10.0, c.y), Align2::RIGHT_CENTER, &format!("{:+.1} ms", f.phase_ms), 11.0, "mono", Color32::from_rgb(0xCF, 0xF5, 0xDF));
        }
    }

    fn deck(&mut self, ui: &mut egui::Ui, p: &Painter, r: Rect, s: &Snapshot, d: usize) {
        panel(p, r, false);
        let v = &s.decks[d];
        let inner = r.shrink(14.0);
        let sleeve = Rect::from_min_size(inner.min, vec2(64.0, 64.0));
        p.rect_filled(sleeve, CornerRadius::same(8), col(theme::sleeve(v.record.id)));
        text(p, sleeve.center(), Align2::CENTER_CENTER, &v.record.initials(), 22.0, "mark", white(0.88));
        // readouts from the right
        let tr = text(p, pos2(inner.right(), inner.top() + 14.0), Align2::RIGHT_CENTER, &format!("−{}", mmss(v.length - v.heard)), 22.0, "mono", col(theme::TEXT));
        text(p, pos2(inner.right(), inner.top() + 44.0), Align2::RIGHT_CENTER, &mmss(v.heard), 12.0, "mono", col(theme::FAINT_ON_GLASS));
        let sep = inner.right() - 108.0;
        p.line_segment([pos2(sep, inner.top() + 10.0), pos2(sep, inner.top() + 54.0)], Stroke::new(1.0, col(theme::EDGE)));
        let _ = tr;
        let b = text(p, pos2(sep - 14.0, inner.top() + 18.0), Align2::RIGHT_CENTER, &format!("{:.2}", v.bpm), 30.0, "mono-semi", col(theme::TEXT));
        let pitch = (v.rate - 1.0) * 100.0;
        text(p, pos2(sep - 14.0, inner.top() + 48.0), Align2::RIGHT_CENTER, &format!("{pitch:+.2}% · {}", if v.record.key.is_empty() { "—" } else { &v.record.key }), 12.0, "mono", col(theme::MUTED));
        let title_room = b.left() - sleeve.right() - 40.0;
        let x = sleeve.right() + 14.0;
        let l = text(p, pos2(x, inner.top() + 20.0), Align2::LEFT_CENTER, ["A", "B"][d], 12.0, "mono-semi", col(theme::DECKS[d]));
        let galley = p.layout(v.record.title.clone(), FontId::new(17.0, family("semi")), col(theme::TEXT), title_room.max(40.0));
        let first: String = galley.rows.first().map(|r| r.text()).unwrap_or_default();
        text(p, pos2(l.right() + 8.0, inner.top() + 20.0), Align2::LEFT_CENTER, &first, 17.0, "semi", col(theme::TEXT));
        text(p, pos2(x, inner.top() + 44.0), Align2::LEFT_CENTER, &v.record.artist, 13.0, "", col(theme::MUTED));

        // transport
        let body = Rect::from_min_max(pos2(inner.left(), inner.top() + 76.0), pos2(inner.right(), inner.top() + 244.0));
        let cell = |c: f32, r_: f32, w: f32, h: f32| Rect::from_min_size(pos2(body.left() + c * 79.0, body.top() + r_), vec2(w, h));
        button(ui, p, cell(0.0, 0.0, 71.0, 44.0), "Cue", Lit::No, (d, "cue"));
        if button(ui, p, cell(1.0, 0.0, 71.0, 44.0), if v.playing { "❚❚" } else { "▶" }, if v.playing { Lit::Deck(d) } else { Lit::No }, (d, "play")).clicked() {
            self.desk.toggle_play(d);
        }
        if button(ui, p, cell(0.0, 52.0, 71.0, 30.0), "Sync", if v.synced { Lit::Ok } else { Lit::No }, (d, "sync")).clicked() {
            self.desk.toggle_sync(d);
        }
        button(ui, p, cell(1.0, 52.0, 71.0, 30.0), "Master", if v.master { Lit::Deck(d) } else { Lit::No }, (d, "master"));
        if button(ui, p, cell(0.0, 90.0, 150.0, 30.0), "Key lock", if v.keylock { Lit::Deck(d) } else { Lit::No }, (d, "kl")).clicked() {
            self.desk.toggle_keylock(d);
        }
        button(ui, p, cell(0.0, 128.0, 71.0, 30.0), "Slip", Lit::No, (d, "slip"));
        button(ui, p, cell(1.0, 128.0, 71.0, 30.0), "Brake", Lit::No, (d, "brake"));
        // pads
        let pads = Rect::from_min_max(pos2(body.left() + 164.0, body.top()), pos2(body.right() - 60.0, body.bottom()));
        label(p, pads.left_top(), Align2::LEFT_TOP, "Hot cues", col(theme::FAINT_ON_GLASS));
        label(p, pads.right_top(), Align2::RIGHT_TOP, "Auto pads", col(theme::FAINT_ON_GLASS));
        let pw = (pads.width() - 24.0) / 4.0;
        for i in 0..8 {
            let pr = Rect::from_min_size(pos2(pads.left() + (i % 4) as f32 * (pw + 8.0), pads.top() + 22.0 + (i / 4) as f32 * 48.0), vec2(pw, 40.0));
            let resp = ui.interact(pr, ui.scope_id().with((d, "pad", i)), Sense::click());
            match v.pads[i] {
                Some(pad) => {
                    let c = theme::pad(pad.kind);
                    p.rect(pr, CornerRadius::same(6), alpha(c, if resp.hovered() { 0.26 } else { 0.15 }), Stroke::new(1.0, alpha(c, 0.65)), StrokeKind::Inside);
                    let n = text(p, pos2(pr.left() + 10.0, pr.center().y), Align2::LEFT_CENTER, &pad.n.to_string(), 11.0, "mono", white(0.8));
                    label_sized(p, pos2(n.right() + 8.0, pr.center().y), Align2::LEFT_CENTER, pad_name(pad.kind), 11.5, col(theme::TEXT));
                    if resp.clicked() {
                        self.desk.jump_to_pad(d, i);
                    }
                }
                None => {
                    p.rect_stroke(pr, CornerRadius::same(6), Stroke::new(1.0, Color32::from_rgb(0x33, 0x36, 0x3E)), StrokeKind::Inside);
                    text(p, pos2(pr.left() + 10.0, pr.center().y), Align2::LEFT_CENTER, &(i + 1).to_string(), 11.0, "mono", col(theme::FAINT));
                }
            }
        }
        // loops
        let ly = pads.top() + 22.0 + 96.0 + 14.0;
        let ll = label(p, pos2(pads.left(), ly), Align2::LEFT_CENTER, "Loop", col(theme::FAINT_ON_GLASS));
        let mut lx = ll.right() + 12.0;
        for (i, n) in ["1/4", "1/2", "1", "2", "4", "8", "16", "32"].iter().enumerate() {
            let sr = Rect::from_min_size(pos2(lx, ly - 13.0), vec2(36.0, 26.0));
            if i == 5 {
                p.rect_filled(sr, CornerRadius::same(5), col(theme::EDGE));
            }
            text(p, sr.center(), Align2::CENTER_CENTER, n, 11.5, "mono", if i == 5 { col(theme::TEXT) } else { col(theme::MUTED) });
            lx += 38.0;
        }
        // pitch fader
        let pf = Rect::from_min_max(pos2(body.right() - 46.0, body.top() + 18.0), pos2(body.right(), body.bottom() - 18.0));
        label(p, pos2(pf.center().x, body.top()), Align2::CENTER_TOP, "±8", col(theme::FAINT_ON_GLASS));
        p.rect_filled(Rect::from_center_size(pf.center(), vec2(4.0, pf.height())), CornerRadius::same(2), col(theme::LINE));
        p.line_segment([pos2(pf.left() + 8.0, pf.center().y), pos2(pf.right() - 8.0, pf.center().y)], Stroke::new(1.0, Color32::from_rgb(0x4A, 0x4E, 0x57)));
        let py = pf.center().y - ((v.rate - 1.0) / 0.08).clamp(-1.0, 1.0) as f32 * (pf.height() / 2.0 - 8.0);
        p.rect_filled(Rect::from_center_size(pos2(pf.center().x, py), vec2(36.0, 16.0)), CornerRadius::same(4), col(theme::CAP));
        text(p, pos2(pf.center().x, body.bottom()), Align2::CENTER_BOTTOM, &format!("{pitch:+.2}%"), 11.0, "mono", col(theme::MUTED));
    }

    fn mixer(&mut self, ui: &mut egui::Ui, p: &Painter, r: Rect, s: &Snapshot) {
        panel(p, r, false);
        let inner = r.shrink2(vec2(14.0, 12.0));
        let names = ["Gain", "High", "Mid", "Low", "Filter"];
        for d in 0..2 {
            let v = &s.decks[d];
            let knobs_x = if d == 0 { inner.left() + 20.0 } else { inner.right() - 20.0 };
            for (i, name) in names.iter().enumerate() {
                let c = pos2(knobs_x, inner.top() + 18.0 + i as f32 * 49.0);
                let (val, bip, color) = match i {
                    0 => (v.gain, false, Color32::from_rgb(0x9D, 0xA1, 0xAA)),
                    1 => (v.eq[2], true, col(theme::DECKS[d])),
                    2 => (v.eq[1], true, col(theme::DECKS[d])),
                    3 => (v.eq[0], true, col(theme::DECKS[d])),
                    _ => (v.filter, true, Color32::from_rgb(0x9D, 0xA1, 0xAA)),
                };
                if let Some(nv) = knob(ui, p, c, val, color, bip, (d, "knob", i)) {
                    match i {
                        0 => self.desk.set_gain(d, nv),
                        1 => self.desk.set_eq(d, 2, nv),
                        2 => self.desk.set_eq(d, 1, nv),
                        3 => self.desk.set_eq(d, 0, nv),
                        _ => self.desk.set_filter(d, nv),
                    }
                }
                label(p, pos2(c.x, c.y + 19.0), Align2::CENTER_TOP, name, col(theme::FAINT_ON_GLASS));
            }
            let fx = if d == 0 { inner.left() + 72.0 } else { inner.right() - 72.0 - 52.0 };
            text(p, pos2(fx + 26.0, inner.top() + 4.0), Align2::CENTER_TOP, ["A", "B"][d], 12.0, "mono-semi", col(theme::DECKS[d]));
            let level = (1.0 + 20.0 * v.peak.max(1e-6).log10() / 48.0).clamp(0.0, 1.0);
            let (mx, fdx) = if d == 0 { (fx, fx + 16.0) } else { (fx + 46.0, fx) };
            meter(p, Rect::from_min_size(pos2(mx, inner.top() + 26.0), vec2(6.0, 178.0)), level, 18);
            if let Some(nv) = vfader(ui, p, Rect::from_min_size(pos2(fdx, inner.top() + 24.0), vec2(34.0, 182.0)), v.fader, (d, "fader")) {
                self.desk.set_fader(d, nv);
            }
            let e = Rect::from_min_size(pos2(fx - 2.0, inner.top() + 216.0), vec2(56.0, 24.0));
            button(ui, p, e, "Echo", Lit::No, (d, "echo"));
        }
        let mc = inner.center().x;
        label(p, pos2(mc, inner.top() + 4.0), Align2::CENTER_TOP, "Master", col(theme::FAINT_ON_GLASS));
        let lvl = (1.0 + 20.0 * s.decks[0].peak.max(s.decks[1].peak).max(1e-6).log10() / 48.0).clamp(0.0, 1.0);
        meter(p, Rect::from_min_size(pos2(mc - 9.0, inner.top() + 26.0), vec2(7.0, 178.0)), lvl, 18);
        meter(p, Rect::from_min_size(pos2(mc + 2.0, inner.top() + 26.0), vec2(7.0, 178.0)), lvl * 0.97, 18);
        // crossfader
        let cf = Rect::from_min_max(pos2(inner.left() + 24.0, inner.bottom() - 30.0), pos2(inner.right() - 24.0, inner.bottom()));
        text(p, pos2(inner.left(), cf.center().y), Align2::LEFT_CENTER, "A", 12.0, "mono", col(theme::DECK_A));
        text(p, pos2(inner.right(), cf.center().y), Align2::RIGHT_CENTER, "B", 12.0, "mono", col(theme::DECK_B));
        let resp = ui.interact(cf, ui.scope_id().with("xf"), Sense::drag());
        p.rect_filled(Rect::from_center_size(cf.center(), vec2(cf.width(), 4.0)), CornerRadius::same(2), col(theme::LINE));
        p.line_segment([pos2(cf.center().x, cf.top() + 4.0), pos2(cf.center().x, cf.bottom() - 4.0)], Stroke::new(1.0, Color32::from_rgb(0x4A, 0x4E, 0x57)));
        let x = cf.left() + 14.0 + s.crossfader * (cf.width() - 28.0);
        p.rect_filled(Rect::from_center_size(pos2(x, cf.center().y), vec2(28.0, 22.0)), CornerRadius::same(4), col(theme::CAP));
        if resp.dragged() {
            self.desk.set_auto(false);
            self.desk.set_crossfader(s.crossfader + resp.drag_delta().x / (cf.width() - 28.0));
        }
    }

    fn crate_(&mut self, ui: &mut egui::Ui, p: &Painter, r: Rect, s: &Snapshot) {
        panel(p, r, true);
        let tree = Rect::from_min_max(r.min, pos2(r.left() + 230.0, r.bottom()));
        p.line_segment([pos2(tree.right(), r.top()), pos2(tree.right(), r.bottom())], Stroke::new(1.0, white(0.06)));
        label(p, pos2(tree.left() + 18.0, tree.top() + 14.0), Align2::LEFT_TOP, "Library", col(theme::FAINT_ON_GLASS));
        let items = [
            ("All records", "27,457"), ("Liked Songs", "13,820"), ("Fetched here", "40"), ("", ""), ("Techno · Hard & Rave", "47"),
            ("Techno · Now (2025–26)", "43"), ("Techno · Peak-Time Main Room", "40"), ("Techno · Berlin Hypnotic", "39"), ("80s", "50"), ("vvv favs", "229"),
        ];
        let mut y = tree.top() + 34.0;
        for (i, (name, n)) in items.iter().enumerate() {
            if name.is_empty() {
                label(p, pos2(tree.left() + 18.0, y + 10.0), Align2::LEFT_TOP, "Crates", col(theme::FAINT_ON_GLASS));
                y += 30.0;
                continue;
            }
            let row = Rect::from_min_size(pos2(tree.left() + 10.0, y), vec2(210.0, 28.0));
            if i == 2 {
                p.rect_filled(row, CornerRadius::same(6), white(0.07));
            }
            let ink = if i == 2 { col(theme::TEXT) } else { Color32::from_rgb(0xB9, 0xBC, 0xC4) };
            clip_text(p, pos2(row.left() + 8.0, row.center().y), name, 13.0, ink, 150.0);
            text(p, pos2(row.right() - 8.0, row.center().y), Align2::RIGHT_CENTER, n, 11.0, "mono", col(theme::FAINT));
            y += 30.0;
        }
        // search + sort
        let main = Rect::from_min_max(pos2(tree.right(), r.top()), r.max);
        let field = Rect::from_min_size(pos2(main.left() + 14.0, main.top() + 8.0), vec2(360.0, 32.0));
        p.rect(field, CornerRadius::same(7), white(0.03), Stroke::new(1.0, col(theme::EDGE)), StrokeKind::Inside);
        let edit = Rect::from_min_max(pos2(field.left() + 32.0, field.top() + 7.0), pos2(field.right() - 8.0, field.bottom() - 6.0));
        p.circle_stroke(pos2(field.left() + 16.0, field.center().y - 1.0), 5.5, Stroke::new(1.8, col(theme::FAINT)));
        ui.put(
            edit,
            egui::TextEdit::singleline(&mut self.search)
                .hint_text("Search everything — library, YouTube, Bandcamp")
                .frame(egui::Frame::NONE)
                .font(FontId::new(13.0, family("")))
                .text_color(col(theme::TEXT)),
        );
        let mut bx = main.right() - 14.0;
        for b in ["Key", "BPM", "Fits"].iter() {
            let br = Rect::from_min_size(pos2(bx - 60.0, field.top() + 2.0), vec2(60.0, 28.0));
            button(ui, p, br, b, Lit::No, ("sort", *b));
            bx -= 68.0;
        }
        // header + rows
        let cols = |w: f32| -> [f32; 8] {
            let fixed = 28.0 + 34.0 + 64.0 + 48.0 + 56.0 + 120.0 + 7.0 * 12.0 + 28.0;
            let flex = (w - fixed).max(200.0);
            let (t, a) = (flex * 0.6, flex * 0.4);
            let mut x = [0.0; 8];
            let widths = [28.0, 34.0, t, a, 64.0, 48.0, 56.0, 120.0];
            let mut acc = 14.0;
            for i in 0..8 {
                x[i] = acc;
                acc += widths[i] + 12.0;
            }
            x
        };
        let cx = cols(main.width());
        let hy = main.top() + 58.0;
        for (i, h) in ["#", "", "Title", "Artist", "BPM", "Key", "Time", "Fits"].iter().enumerate() {
            let anchor = if i == 4 || i == 6 { Align2::RIGHT_CENTER } else { Align2::LEFT_CENTER };
            let x = if i == 4 { main.left() + cx[5] - 12.0 } else if i == 6 { main.left() + cx[7] - 12.0 } else { main.left() + cx[i] };
            label(p, pos2(x, hy), anchor, h, col(theme::FAINT_ON_GLASS));
        }
        p.line_segment([pos2(main.left(), hy + 13.0), pos2(main.right(), hy + 13.0)], Stroke::new(1.0, white(0.08)));
        let list = Rect::from_min_max(pos2(main.left(), hy + 14.0), main.max);
        let rows = self.desk.rows(&self.search, s.master_bpm);
        let mut load: Option<wo_deskcore::Record> = None;
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(list));
        egui::ScrollArea::vertical().id_salt("crate").auto_shrink([false, false]).show_rows(&mut child, 34.0, rows.len(), |ui, range| {
            for i in range {
                let row = &rows[i];
                let (rr, resp) = ui.allocate_exact_size(vec2(list.width(), 34.0), Sense::click());
                let p = ui.painter();
                if resp.hovered() {
                    p.rect_filled(rr, CornerRadius::ZERO, white(0.05));
                }
                p.line_segment([pos2(rr.left(), rr.bottom()), pos2(rr.right(), rr.bottom())], Stroke::new(1.0, white(0.04)));
                let y = rr.center().y;
                let at = |k: usize| rr.left() + cx[k];
                text(p, pos2(at(0), y), Align2::LEFT_CENTER, &(i + 1).to_string(), 11.0, "mono", col(theme::FAINT));
                let sl = Rect::from_min_size(pos2(at(1), y - 14.0), vec2(28.0, 28.0));
                p.rect_filled(sl, CornerRadius::same(4), col(theme::sleeve(row.record.id)));
                text(p, sl.center(), Align2::CENTER_CENTER, &row.record.initials(), 12.0, "mark", white(0.86));
                let mut tx = at(2);
                if let Some(d) = row.on_deck {
                    let chip = Rect::from_min_size(pos2(tx, y - 9.0), vec2(18.0, 18.0));
                    p.rect_filled(chip, CornerRadius::same(4), col(theme::DECKS[d]));
                    text(p, chip.center(), Align2::CENTER_CENTER, ["A", "B"][d], 10.0, "mono-semi", col(theme::GROUND));
                    tx += 26.0;
                }
                let ink = if row.on_deck.is_some() { col(theme::FAINT) } else if row.record.playable() { col(theme::TEXT) } else { col(theme::MUTED) };
                clip_text(p, pos2(tx, y), &row.record.title, 13.0, ink, at(3) - tx - 12.0);
                clip_text(p, pos2(at(3), y), &row.record.artist, 13.0, col(theme::MUTED), at(4) - at(3) - 12.0);
                text(p, pos2(at(5) - 12.0, y), Align2::RIGHT_CENTER, &format!("{:.2}", row.record.bpm), 12.0, "mono", col(theme::TEXT));
                text(p, pos2(at(5), y), Align2::LEFT_CENTER, &row.record.key, 12.0, "mono", col(theme::MUTED));
                text(p, pos2(at(7) - 12.0, y), Align2::RIGHT_CENTER, &format!("{}:{:02}", row.record.seconds / 60, row.record.seconds % 60), 12.0, "mono", col(theme::MUTED));
                if row.on_deck.is_none() {
                    let bar = Rect::from_min_size(pos2(at(7), y - 2.0), vec2(70.0, 4.0));
                    p.rect_filled(bar, CornerRadius::same(2), col(theme::LINE));
                    p.rect_filled(Rect::from_min_size(bar.min, vec2(0.7 * row.fits as f32, 4.0)), CornerRadius::same(2), Color32::from_rgb(0x9D, 0xA1, 0xAA));
                    text(p, pos2(bar.right() + 8.0, y), Align2::LEFT_CENTER, &row.fits.to_string(), 11.0, "mono", col(theme::MUTED));
                }
                if resp.double_clicked() && row.record.playable() && row.on_deck.is_none() {
                    load = Some(row.record.clone());
                }
            }
        });
        if let Some(rec) = load
            && s.mix.is_none() {
                let free = s.decks.iter().position(|d| !d.master).unwrap_or(1);
                self.desk.load(free, rec);
            }
    }

    fn auto_dj(&mut self, ui: &mut egui::Ui, p: &Painter, r: Rect, s: &Snapshot) {
        panel(p, r, false);
        let inner = r.shrink(14.0);
        label(p, inner.left_top(), Align2::LEFT_TOP, "Auto DJ", col(theme::SOFT));
        label(p, inner.right_top(), Align2::RIGHT_TOP, if s.auto { "On · follows your hands" } else { "Off" }, if s.auto { col(theme::OK) } else { col(theme::FAINT_ON_GLASS) });
        let card = Rect::from_min_size(pos2(inner.left(), inner.top() + 26.0), vec2(inner.width(), 132.0));
        p.rect(card, CornerRadius::same(8), white(0.035), Stroke::new(1.0, white(0.06)), StrokeKind::Inside);
        let c = card.shrink(12.0);
        let master = s.decks.iter().position(|d| d.master).unwrap_or(0);
        let (from, to) = s.mix.map(|m| (m.from, m.to)).unwrap_or((master, 1 - master));
        let a = text(p, pos2(c.left(), c.top() + 8.0), Align2::LEFT_CENTER, ["A", "B"][from], 12.0, "mono", col(theme::DECKS[from]));
        text(p, pos2(a.right() + 14.0, c.top() + 8.0), Align2::CENTER_CENTER, "→", 13.0, "", col(theme::MUTED));
        let b = text(p, pos2(a.right() + 26.0, c.top() + 8.0), Align2::LEFT_CENTER, ["A", "B"][to], 12.0, "mono", col(theme::DECKS[to]));
        text(p, pos2(b.right() + 10.0, c.top() + 8.0), Align2::LEFT_CENTER, "Long blend", 13.0, "semi", col(theme::TEXT));
        let bar = s.mix.map(|m| m.bar).unwrap_or(0.0);
        let status = if s.mix.is_some() { format!("bar {:.0} / {:.0}", bar.floor() + 1.0, MIX_BARS) } else { "next soon".into() };
        text(p, pos2(c.right(), c.top() + 8.0), Align2::RIGHT_CENTER, &status, 12.0, "mono", col(theme::MUTED));
        let track = Rect::from_min_size(pos2(c.left(), c.top() + 26.0), vec2(c.width(), 6.0));
        p.rect_filled(track, CornerRadius::same(3), col(theme::LINE));
        let fill = Rect::from_min_size(track.min, vec2(c.width() * (bar / MIX_BARS).min(1.0) as f32, 6.0));
        let mut mesh = Mesh::default();
        mesh.colored_vertex(fill.left_top(), col(theme::DECKS[from]));
        mesh.colored_vertex(fill.right_top(), col(theme::DECKS[to]));
        mesh.colored_vertex(fill.right_bottom(), col(theme::DECKS[to]));
        mesh.colored_vertex(fill.left_bottom(), col(theme::DECKS[from]));
        mesh.add_triangle(0, 1, 2);
        mesh.add_triangle(0, 2, 3);
        p.add(mesh);
        let sw = track.left() + track.width() * (SWAP_BAR / MIX_BARS) as f32;
        p.rect_filled(Rect::from_center_size(pos2(sw, track.center().y), vec2(2.0, 12.0)), CornerRadius::ZERO, col(theme::TEXT));
        text(p, pos2(c.left(), c.top() + 50.0), Align2::LEFT_CENTER, &format!("Bass swap on bar {:.0}", SWAP_BAR + 1.0), 12.0, "", col(theme::MUTED));
        let bw = (c.width() - 16.0) / 3.0;
        for (i, name) in ["Mix now", "Not that", "Hold"].iter().enumerate() {
            let br = Rect::from_min_size(pos2(c.left() + i as f32 * (bw + 8.0), c.bottom() - 30.0), vec2(bw, 30.0));
            if button(ui, p, br, name, Lit::No, ("mixbtn", i)).clicked() && i == 2 {
                self.desk.set_auto(!s.auto);
            }
        }
        label(p, pos2(inner.left(), card.bottom() + 14.0), Align2::LEFT_TOP, "Up next", col(theme::FAINT_ON_GLASS));
        let room = ((inner.bottom() - card.bottom() - 40.0) / 46.0).floor().max(0.0) as usize;
        for (i, rec) in s.up_next.iter().take(room).enumerate() {
            let y = card.bottom() + 40.0 + i as f32 * 46.0;
            let sl = Rect::from_min_size(pos2(inner.left(), y), vec2(36.0, 36.0));
            p.rect_filled(sl, CornerRadius::same(4), col(theme::sleeve(rec.id)));
            text(p, sl.center(), Align2::CENTER_CENTER, &rec.initials(), 13.0, "mark", white(0.86));
            let meta = format!("{:.0} · {}", rec.bpm, rec.key);
            let m = text(p, pos2(inner.right(), y + 18.0), Align2::RIGHT_CENTER, &meta, 11.0, "mono", col(theme::MUTED));
            clip_text(p, pos2(sl.right() + 10.0, y + 10.0), &rec.title, 13.0, col(theme::TEXT), m.left() - sl.right() - 20.0);
            clip_text(p, pos2(sl.right() + 10.0, y + 27.0), &rec.artist, 12.0, col(theme::MUTED), m.left() - sl.right() - 20.0);
        }
    }
}

fn pad_name(k: PadKind) -> &'static str {
    match k {
        PadKind::Intro => "Intro",
        PadKind::Drop => "Drop",
        PadKind::Break => "Break",
        PadKind::Out => "Out",
    }
}

/// One line of text cut to `room` px with an ellipsis.
fn clip_text(p: &Painter, pos: Pos2, s: &str, size: f32, color: Color32, room: f32) {
    let font = FontId::new(size, family(""));
    let mut job = LayoutJob::single_section(s.to_owned(), TextFormat { font_id: font, color, ..Default::default() });
    job.wrap = egui::text::TextWrapping { max_width: room.max(10.0), max_rows: 1, break_anywhere: true, overflow_character: Some('…') };
    let g = p.layout_job(job);
    p.galley(pos2(pos.x, pos.y - g.size().y / 2.0), g, color);
}

struct Layout {
    top: Rect,
    overview: Rect,
    waves: Rect,
    decks: [Rect; 2],
    mixer: Rect,
    crate_: Rect,
    auto: Rect,
}

fn layout(full: Rect) -> Layout {
    let r = full.shrink(12.0);
    let mut y = r.top();
    let mut row = |h: f32| {
        let rr = Rect::from_min_size(pos2(r.left(), y), vec2(r.width(), h));
        y += h + 10.0;
        rr
    };
    let (top, overview, waves, mid) = (row(48.0), row(66.0), row(252.0), row(318.0));
    let rest = Rect::from_min_max(pos2(r.left(), y), r.max);
    let dw = (r.width() - 440.0 - 20.0) / 2.0;
    let decks = [Rect::from_min_size(mid.min, vec2(dw, mid.height())), Rect::from_min_size(pos2(mid.right() - dw, mid.top()), vec2(dw, mid.height()))];
    let mixer = Rect::from_min_max(pos2(decks[0].right() + 10.0, mid.top()), pos2(decks[1].left() - 10.0, mid.bottom()));
    let crate_ = Rect::from_min_max(rest.min, pos2(rest.right() - 410.0, rest.bottom()));
    let auto = Rect::from_min_max(pos2(rest.right() - 400.0, rest.top()), rest.max);
    Layout { top, overview, waves, decks, mixer, crate_, auto }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let t0 = Instant::now();
        self.desk.tick();
        let s = self.desk.snapshot();
        let full = ui.max_rect();
        let p = ui.painter().clone();
        p.rect_filled(full, CornerRadius::ZERO, col(theme::GROUND));
        p.image(self.backdrop.id(), full, Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)), Color32::WHITE);
        let l = layout(full);
        self.top_bar(ui, &p, l.top, &s);
        self.overviews(&p, l.overview, &s);
        self.waves(&p, l.waves, &s);
        for d in 0..2 {
            self.deck(ui, &p, l.decks[d], &s, d);
        }
        self.mixer(ui, &p, l.mixer, &s);
        self.crate_(ui, &p, l.crate_, &s);
        self.auto_dj(ui, &p, l.auto, &s);
        let work = t0.elapsed().as_secs_f32() * 1000.0;
        if let Some(b) = &mut self.bench {
            b.size = (full.width() as u32, full.height() as u32);
            if self.shot.is_none() && b.frame(work) {
                let (tx, rx) = mpsc::channel();
                ui.ctx().send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::ScreenshotCallback::new(move |img| {
                    let _ = tx.send(img);
                })));
                self.shot = Some(rx);
            }
            if let Some(rx) = &self.shot
                && let Ok(img) = rx.try_recv() {
                    let rgba: Vec<u8> = img.pixels.iter().flat_map(|c| c.to_srgba_unmultiplied()).collect();
                    println!("{}", b.finish(Some((img.size[0] as u32, img.size[1] as u32, &rgba))));
                    ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
                }
        }
        ui.ctx().request_repaint();
    }
}

fn main() -> eframe::Result {
    let renderer = match std::env::var("WO_RENDERER").as_deref() {
        Ok("glow") => eframe::Renderer::Glow,
        _ => eframe::Renderer::Wgpu,
    };
    let options = eframe::NativeOptions {
        renderer,
        viewport: egui::ViewportBuilder::default().with_inner_size([1920.0, 1080.0]).with_title("WetOwl Desk — egui").with_app_id("wetowl-desk-egui"),
        ..Default::default()
    };
    eframe::run_native("WetOwl Desk — egui", options, Box::new(|cc| Ok(Box::new(App::new(cc)))))
}
