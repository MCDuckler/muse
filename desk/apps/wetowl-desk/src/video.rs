//! The footage's own part of its scene page: the clips on this machine (put in a folder,
//! made ready on their own) — each kept in or out, starred, the one on now marked — then how
//! the beat moves through them, how they fill the stage and take the record's colours, and
//! the knobs. Each change is kept in this Desk's show at once (ShowEdit::Video).
use eframe::egui::{self, Align2, Color32, CornerRadius, Painter, Rect, Sense, Stroke, StrokeKind, Ui, pos2, vec2};
use wo_deskcore::video::{VideoChange, VideoEvery, VideoFit, VideoMode, VideoSpec, VideoTint};
use wo_deskcore::{Desk, ShowEdit};

use crate::App;
use crate::rotation::head;
use crate::ui::kit;
use crate::ui::tokens::{self as t, Tone};

const HEAD: f32 = 34.0;
const LABEL_W: f32 = 84.0;
const CARD_W: f32 = 176.0;
const CARD_H: f32 = 99.0;

/// The folder opened where the system opens folders.
fn open_folder(p: &std::path::Path) {
    let cmd = if cfg!(windows) {
        "explorer"
    } else if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    if let Err(e) = std::process::Command::new(cmd).arg(p).spawn() {
        eprintln!("footage: {} not opened: {e}", p.display());
    }
}

fn secs(s: f64) -> String {
    let s = s.round() as i64;
    if s >= 60 { format!("{}:{:02}", s / 60, s % 60) } else { format!("{s} s") }
}

impl App {
    /// The footage's part of the page from `r`'s top, `r` wide; its height.
    pub(crate) fn video_editor(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) -> f32 {
        let (spec, shelf, on) = desk.show_video();
        let mut next: Option<VideoSpec> = None;
        let mut y = r.top();

        // ---- the clips
        let folder = shelf.folder.as_ref().map(|f| f.display().to_string()).unwrap_or_else(|| "nowhere (no home)".into());
        head(p, r, y, "The clips", &format!("put footage in {folder} · each is made ready once, on its own"));
        y += HEAD;
        let mut x = r.left();
        let bw = 120.0;
        if kit::Btn::new("Open the folder").size(11.0).show(ui, p, Rect::from_min_size(pos2(x, y), vec2(bw, 26.0)), "vid-open").on_hover_text("The footage folder, made where it is not: put clips in it (or in folders in it); taken out, they go from the show").clicked()
            && let Some(f) = desk.show_video_folder()
        {
            open_folder(&f);
        }
        x += bw + 8.0;
        if kit::Btn::new("Look again").quiet().size(11.0).show(ui, p, Rect::from_min_size(pos2(x, y), vec2(96.0, 26.0)), "vid-rescan").on_hover_text("The folder looked at now (it is every twenty seconds); clips that failed are tried again").clicked() {
            desk.show_edit(ShowEdit::VideoRescan);
        }
        x += 104.0;
        if on.is_some() && kit::Btn::new("Next clip").quiet().size(11.0).show(ui, p, Rect::from_min_size(pos2(x, y), vec2(90.0, 26.0)), "vid-next").on_hover_text("Another clip now").clicked() {
            desk.show_edit(ShowEdit::VideoNext);
        }
        x += 98.0;
        // what is happening: being made, waiting, failed, no ffmpeg
        let status = if !shelf.tools && shelf.proxies.is_some() {
            ("no ffmpeg here: clips cannot be made ready (put ffmpeg and ffprobe on the PATH, or beside the Desk)".to_owned(), t::warm())
        } else if let Some((name, k)) = &shelf.making {
            let more = if shelf.waiting > 0 { format!(" · {} waiting", shelf.waiting) } else { String::new() };
            (format!("making {name} ready · {:.0} %{more}", k * 100.0), t::muted())
        } else if shelf.clips.is_empty() {
            ("no clips yet".to_owned(), t::faint())
        } else {
            let kept = shelf.clips.iter().filter(|c| !spec.off.contains(&c.id)).count();
            (format!("{} clips · {kept} in the show", shelf.clips.len()), t::faint())
        };
        kit::clipped(p, pos2(x + 4.0, y + 13.0), &status.0, 11.5, "", status.1, r.right() - x - 4.0);
        y += 36.0;
        for (name, why) in &shelf.failed {
            kit::clipped(p, pos2(r.left(), y + 8.0), &format!("{name}: {why}"), 11.0, "mono", t::warm(), r.width());
            y += 18.0;
        }
        if shelf.making.is_some() {
            ui.ctx().request_repaint_after(std::time::Duration::from_millis(250));
        }
        // the cards: the poster, the name, its length and nature; a click keeps it in or out,
        // the star shows it more
        let cols = ((r.width() + 10.0) / (CARD_W + 10.0)).floor().max(1.0) as usize;
        for (i, c) in shelf.clips.iter().enumerate() {
            let (cx, cy) = (r.left() + (i % cols) as f32 * (CARD_W + 10.0), y + (i / cols) as f32 * (CARD_H + 44.0));
            let card = Rect::from_min_size(pos2(cx, cy), vec2(CARD_W, CARD_H));
            let off = spec.off.contains(&c.id);
            let star = spec.star.contains(&c.id);
            if !self.scene_ui.posters.contains_key(&c.id) {
                let tex = desk.show_video_poster(&c.id).and_then(|f| std::fs::read(f).ok()).and_then(|b| image::load_from_memory(&b).ok()).map(|img| {
                    let img = img.thumbnail(CARD_W as u32 * 2, CARD_H as u32 * 2).to_rgba8();
                    let ci = egui::ColorImage::from_rgba_unmultiplied([img.width() as usize, img.height() as usize], img.as_raw());
                    ui.ctx().load_texture(format!("poster {}", c.id), ci, egui::TextureOptions::LINEAR)
                });
                self.scene_ui.posters.insert(c.id.clone(), tex);
            }
            p.rect_filled(card, CornerRadius::same(t::R_CONTROL), Color32::from_black_alpha(160));
            if let Some(Some(tex)) = self.scene_ui.posters.get(&c.id) {
                // the poster fitted whole
                let a = tex.aspect_ratio();
                let (w, h) = if a > CARD_W / CARD_H { (CARD_W, CARD_W / a) } else { (CARD_H * a, CARD_H) };
                let pr = Rect::from_center_size(card.center(), vec2(w, h));
                let tint = if off { Color32::from_white_alpha(70) } else { Color32::WHITE };
                p.image(tex.id(), pr, Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)), tint);
            }
            let playing = on.as_deref() == Some(c.id.as_str());
            let edge = if playing { Stroke::new(2.0, t::focus()) } else { Stroke::new(1.0, t::edge_rest()) };
            p.rect_stroke(card, CornerRadius::same(t::R_CONTROL), edge, StrokeKind::Inside);
            let resp = ui.interact(card, ui.scope_id().with(("vid-card", &c.id)), Sense::click());
            let nature = format!(
                "{} · {} · {}",
                secs(c.out_s - c.in_s),
                if c.busy() > 0.55 { "busy" } else if c.busy() < 0.25 { "calm" } else { "moving" },
                if c.colour < 0.08 { "black & white" } else { "colour" }
            );
            let resp = resp.on_hover_text(format!("{}\n{nature} · {}×{} · {:.0} fps\n{}", c.name, c.w, c.h, c.fps, if off { "kept out: a click lets it in" } else { "a click keeps it out of the show" }));
            if resp.clicked() {
                let mut s = next.clone().unwrap_or_else(|| spec.clone());
                if off {
                    s.off.retain(|x| *x != c.id);
                } else {
                    s.off.push(c.id.clone());
                }
                next = Some(s);
            }
            // the star, top right
            let sr = Rect::from_min_size(pos2(card.right() - 26.0, card.top() + 4.0), vec2(22.0, 22.0));
            p.circle_filled(sr.center(), 10.0, Color32::from_black_alpha(140));
            kit::text(p, sr.center(), Align2::CENTER_CENTER, if star { "★" } else { "☆" }, 13.0, "", if star { t::focus() } else { t::muted() });
            if ui.interact(sr, ui.scope_id().with(("vid-star", &c.id)), Sense::click()).on_hover_text("Starred: shown twice as often").clicked() {
                let mut s = next.clone().unwrap_or_else(|| spec.clone());
                if star {
                    s.star.retain(|x| *x != c.id);
                } else {
                    s.star.push(c.id.clone());
                }
                next = Some(s);
            }
            if playing {
                kit::text(p, pos2(card.left() + 8.0, card.top() + 12.0), Align2::LEFT_CENTER, "● ON", 10.5, "mono", t::focus());
            }
            kit::clipped(p, pos2(cx, cy + CARD_H + 11.0), &c.name, 12.0, "", if off { t::faint() } else { t::text() }, CARD_W);
            kit::clipped(p, pos2(cx, cy + CARD_H + 27.0), &nature, 10.5, "mono", t::faint(), CARD_W);
        }
        if !shelf.clips.is_empty() {
            y += shelf.clips.len().div_ceil(cols) as f32 * (CARD_H + 44.0);
        }
        y += 12.0;

        // ---- how the beat moves through them
        head(p, r, y, "How it moves", "Auto: drift in a breakdown, stutter in a build, cut on a drop, lock between");
        y += HEAD;
        let seg = |ui: &mut Ui, y: &mut f32, word: &str, tip: &str, items: &[&str], chosen: usize, id: &str| -> Option<usize> {
            let lr = kit::section(p, pos2(r.left(), *y + 13.0), Align2::LEFT_CENTER, word);
            ui.interact(lr, ui.scope_id().with((id, "tip")), Sense::hover()).on_hover_text(tip);
            let at = Rect::from_min_size(pos2(r.left() + LABEL_W, *y), vec2((r.width() - LABEL_W).min(items.len() as f32 * 78.0), 26.0));
            *y += 34.0;
            kit::segmented(ui, p, at, items, Some(chosen), Tone::Neutral, id)
        };
        let modes: Vec<&str> = VideoMode::ALL.iter().map(|m| m.label()).collect();
        if let Some(i) = seg(
            ui,
            &mut y,
            "Mode",
            "Play: the clip as it runs · Lock: four bars of footage looped on the bar (a short clip stretched to whole bars) · Cut: a jump to another place every beat, bar or phrase · Stutter: a slice played again, shorter as a build rises · Drift: slow motion in the quiet",
            &modes,
            spec.mode.index(),
            "vid-mode",
        ) {
            next = Some(VideoSpec { mode: VideoMode::ALL[i], ..next.unwrap_or_else(|| spec.clone()) });
        }
        if let Some(i) = seg(ui, &mut y, "Cut every", "How often the cut jumps (Cut, and Auto's drops)", &["Beat", "Bar", "2 bars", "Phrase"], spec.every.index(), "vid-every") {
            next = Some(VideoSpec { every: VideoEvery::ALL[i], ..next.unwrap_or_else(|| spec.clone()) });
        }
        let holds = [1u32, 2, 4, 8];
        let held = holds.iter().position(|h| *h == spec.hold).unwrap_or(1);
        if let Some(i) = seg(ui, &mut y, "New clip", "Another clip every so many phrases (four bars); a drop brings one sooner", &["Phrase", "2 phrases", "4 phrases", "8 phrases"], held, "vid-hold") {
            next = Some(VideoSpec { hold: holds[i], ..next.unwrap_or_else(|| spec.clone()) });
        }
        if let Some(i) = seg(ui, &mut y, "Into it", "How the next clip comes: Auto dissolves over a bar and datamoshes on a drop", &["Auto", "Cut", "Dissolve", "Mosh"], spec.change.index(), "vid-change") {
            next = Some(VideoSpec { change: VideoChange::ALL[i], ..next.unwrap_or_else(|| spec.clone()) });
        }
        y += 8.0;

        // ---- how it looks
        head(p, r, y, "How it looks", "the record's colours on footage with little of its own (old film)");
        y += HEAD;
        if let Some(i) = seg(ui, &mut y, "Fit", "Fill: cropped to the stage · Whole: all of it, black beside · Blurred: all of it over itself, soft and dark (old 4:3 film, upright phone video)", &["Fill", "Whole", "Blurred"], spec.fit.index(), "vid-fit") {
            next = Some(VideoSpec { fit: VideoFit::ALL[i], ..next.unwrap_or_else(|| spec.clone()) });
        }
        if let Some(i) = seg(ui, &mut y, "Colour", "Auto: the record's palette on black & white footage, colour footage as it is · Palette · As it is · Grey · Sepia", &["Auto", "As it is", "Palette", "Grey", "Sepia"], [0, 1, 2, 3, 4][spec.tint.index()], "vid-tint") {
            next = Some(VideoSpec { tint: VideoTint::ALL[i], ..next.unwrap_or_else(|| spec.clone()) });
        }
        let mr = Rect::from_min_size(pos2(r.left() + LABEL_W, y), vec2(kit::chip_width(p, "Mirrored"), 24.0));
        kit::section(p, pos2(r.left(), y + 12.0), Align2::LEFT_CENTER, "Mirror");
        if kit::chip(ui, p, mr, "Mirrored", spec.mirror, Tone::Neutral, true, "vid-mirror").on_hover_text("The left half mirrored into the right").clicked() {
            next = Some(VideoSpec { mirror: !spec.mirror, ..next.unwrap_or_else(|| spec.clone()) });
        }
        y += 40.0;

        // ---- the knobs
        head(p, r, y, "Knobs", "drag; a double click for the shipped value");
        y += HEAD;
        let d = VideoSpec::default();
        let knobs: [(&str, f64, f64, &str); 6] = [
            ("Speed", spec.speed, d.speed, "The footage's speed: 1 is real time (Lock and Cut keep to the bar either way)"),
            ("Light", spec.dim, d.dim, "How bright the footage is"),
            ("Contrast", spec.contrast, d.contrast, "How hard its lights and darks"),
            ("Colour", spec.saturation, d.saturation, "How much colour (before the tint)"),
            ("Kick", spec.punch, d.punch, "How far the kick pushes in and lights it"),
            ("Film", spec.film, d.film, "The old film's weave in the gate and its flicker"),
        ];
        let kw = (r.width().min(560.0) / knobs.len() as f32).max(64.0);
        let (lo, hi) = (0.0, 2.0);
        for (i, (word, v, rest, tip)) in knobs.iter().enumerate() {
            let c = pos2(r.left() + kw * (i as f32 + 0.5), y + 24.0);
            let k = ((v - lo) / (hi - lo)) as f32;
            let picked = kit::knob(ui, p, c, k, t::text(), false, ((rest - lo) / (hi - lo)) as f32, ("vid-knob", i));
            ui.interact(Rect::from_center_size(c, vec2(44.0, 44.0)), ui.scope_id().with(("vid-knob-tip", i)), Sense::hover()).on_hover_text(*tip);
            kit::section(p, pos2(c.x, c.y + 30.0), Align2::CENTER_CENTER, word);
            kit::text(p, pos2(c.x, c.y + 46.0), Align2::CENTER_CENTER, &format!("{v:.2}×"), 11.0, "mono", t::muted());
            if let Some(nk) = picked
                && (nk - k).abs() > 1e-4
            {
                let nv = (lo + nk as f64 * (hi - lo)).clamp(lo, hi);
                let mut s = next.clone().unwrap_or_else(|| spec.clone());
                match i {
                    0 => s.speed = nv.max(0.25),
                    1 => s.dim = nv,
                    2 => s.contrast = nv,
                    3 => s.saturation = nv,
                    4 => s.punch = nv,
                    _ => s.film = nv,
                }
                next = Some(s);
            }
        }
        y += 70.0;
        let shipped = VideoSpec { off: spec.off.clone(), star: spec.star.clone(), ..Default::default() };
        if spec != shipped {
            let br = Rect::from_min_size(pos2(r.left(), y), vec2(140.0, 26.0));
            if kit::Btn::new("As shipped").quiet().size(11.0).show(ui, p, br, "vid-reset").on_hover_text("Every mode, fit, colour and knob back as shipped (the clips kept out and starred stay)").clicked() {
                next = Some(shipped);
            }
            y += 34.0;
        }
        if let Some(s) = next
            && s != spec
        {
            desk.show_edit(ShowEdit::Video(s));
        }
        y - r.top()
    }
}
