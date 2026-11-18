//! Following rekordbox, for anyone: one button to turn it on and off, and a checklist of what
//! it needs in plain words, each with the hand that puts it right (download rkbx_link, use the
//! one downloaded, find it, add a music folder), then each deck as followed.
use std::path::PathBuf;
use std::time::{Duration, Instant};

use eframe::egui::{self, Align2, Color32, Painter, Rect, Sense, Stroke, Ui, pos2, vec2};
use wo_deskcore::{Desk, FollowHere, FollowView, Rkbx};
use wo_deskcore::follow::{IN_STEP_MS, Link, RELEASES};

use crate::paint::white;
use crate::ui::icons::Icon;
use crate::ui::kit::{self, Btn, State};
use crate::ui::tokens as t;
use crate::{App, RESTART};

/// A line of the checklist: how it is, what it says, its hands (word, what they do).
struct Line {
    state: State,
    name: &'static str,
    words: String,
    detail: Option<String>,
    hands: Vec<(&'static str, Hand)>,
}

#[derive(Clone)]
enum Hand {
    Download,
    Unpack(PathBuf),
    FindRkbx,
    AddFolder,
    ReadAgain,
}

/// How following goes, in a sentence, and how well: the one thing to do next where there is one.
pub(crate) fn summary(v: &FollowView) -> (State, String) {
    if let Some(why) = &v.trouble {
        return (State::Trouble, why.clone());
    }
    match &v.rkbx {
        Rkbx::NotFound => return (State::Trouble, "rkbx_link is needed: it tells the Desk what rekordbox plays. Download it below.".into()),
        Rkbx::Ours(r) => match &r.state {
            Link::Stopped(why) => return (State::Trouble, format!("rkbx_link stopped ({why}); starting it again")),
            Link::Starting => return (State::Busy, "Starting rkbx_link…".into()),
            Link::Looking => {
                if let (Some(have), false) = (&v.rekordbox, r.knows.is_empty())
                    && !r.knows.contains(have)
                {
                    return (State::Trouble, format!("This rkbx_link knows rekordbox {}, this computer has {have}: rkbx_link's licence covers the newer ones", r.knows.join(", ")));
                }
                return (State::Busy, "Waiting for rekordbox: open it".into());
            }
            Link::Connected => {}
        },
        Rkbx::Waiting => return (State::Busy, "Listening for rkbx_link…".into()),
        Rkbx::Outside => {}
    }
    if v.library.is_none() {
        return (State::Busy, "Reading rekordbox's library…".into());
    }
    if let Some(d) = v.decks.iter().find(|d| d.found == Some(false)) {
        return (State::Trouble, format!("\u{201c}{}\u{201d} is not in the music folders: add its folder below", d.title));
    }
    if !v.live || v.decks.iter().all(|d| d.found.is_none()) {
        return (State::On, "Connected to rekordbox: load a track on a deck".into());
    }
    let playing: Vec<&str> = v.decks.iter().filter(|d| d.playing && d.found == Some(true)).map(|d| d.title.as_str()).collect();
    if playing.is_empty() {
        (State::On, "Following rekordbox: nothing playing".into())
    } else {
        (State::On, format!("Following rekordbox: {}", playing.join(" + ")))
    }
}

impl App {
    /// rekordbox is open (looked at every few seconds).
    pub(crate) fn rekordbox_open(&mut self) -> bool {
        match self.rekordbox_seen {
            Some((at, open)) if at.elapsed() < Duration::from_secs(3) => open,
            _ => {
                let open = wo_deskcore::follow::rekordbox_open();
                self.rekordbox_seen = Some((Instant::now(), open));
                open
            }
        }
    }

    /// What is here for following (looked for again every few seconds while the page is up).
    fn here(&mut self) -> FollowHere {
        let fresh = self.follow_here.as_ref().is_some_and(|(at, _)| at.elapsed() < Duration::from_secs(3));
        if !fresh {
            self.follow_here = Some((Instant::now(), wo_deskcore::follow::look_around(self.prefs.rkbx_link.as_deref())));
        }
        self.follow_here.as_ref().unwrap().1.clone()
    }

    /// The rekordbox page.
    pub(crate) fn rekordbox_page(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect) {
        let ctx = ui.ctx().clone();
        let following = desk.following();
        let here = self.here();
        let open = self.rekordbox_open();
        let mut y = r.top();
        let words = |p: &Painter, pos: egui::Pos2, s: &str, c: Color32, w: f32, size: f32| -> f32 {
            let g = p.layout(s.to_owned(), egui::FontId::new(size, crate::paint::family("")), c, w);
            let h = g.size().y;
            p.galley(pos, g, c);
            h
        };

        // the one sentence, and the one button
        let (state, said) = match &following {
            Some(v) => summary(v),
            None => match &self.follow_failed {
                Some(why) => (State::Trouble, format!("Following could not start: {why}")),
                None => (State::Off, "The show can follow a set you play in rekordbox. rekordbox plays the music; the Desk stays silent and the show reads its decks.".into()),
            },
        };
        let bw = 200.0;
        let dot = Rect::from_center_size(pos2(r.left() + 9.0, y + 14.0), vec2(18.0, 18.0));
        kit::status(ui, p, dot, Icon::Disc, state, "rb-state");
        let h = words(p, pos2(r.left() + 30.0, y + 4.0), &said, if state == State::Trouble { t::warm() } else { t::text() }, r.width() - bw - 60.0, 15.0);
        let b = Rect::from_min_size(pos2(r.right() - bw, y), vec2(bw, 34.0));
        let on = self.prefs.follow_rekordbox || following.is_some();
        let word = if on { "Stop following" } else { "Follow rekordbox" };
        let resp = Btn::new(word).icon(Icon::Disc).accent(!on).show(ui, p, b, "rb-toggle");
        if resp.on_hover_text("The Desk starts again to change this (a second)").clicked() {
            self.prefs.follow_rekordbox = !on;
            self.save_prefs(&ctx);
            RESTART.store(true, std::sync::atomic::Ordering::Relaxed);
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
        y += h.max(34.0) + 22.0;

        // what it needs, a line each
        kit::section(p, pos2(r.left(), y), Align2::LEFT_TOP, "What it needs");
        y += 28.0;
        let mut lines = vec![];
        lines.push(Line {
            state: if here.rekordbox.is_some() { State::On } else { State::Trouble },
            name: "rekordbox",
            words: match (&here.rekordbox, here.library) {
                (Some(v), true) if open => format!("rekordbox {v} · open now"),
                (Some(v), true) => format!("rekordbox {v}"),
                (Some(v), false) => format!("rekordbox {v}: open it once, so its library is there"),
                (None, _) => "Not found on this computer".into(),
            },
            detail: Some("Keep its version as it is until the gig: rkbx_link knows only some versions, and an update can stop it".into()),
            hands: vec![],
        });
        let (rk_state, rk_words, rk_detail) = match following.as_ref().map(|v| &v.rkbx) {
            Some(Rkbx::Ours(r)) => {
                let knows = if r.knows.is_empty() { String::new() } else { format!(" · knows rekordbox {}", r.knows.join(", ")) };
                let how = match &r.state {
                    Link::Starting => "starting".to_owned(),
                    Link::Looking => "running, waiting for rekordbox".to_owned(),
                    Link::Connected => "connected to rekordbox".to_owned(),
                    Link::Stopped(why) => format!("stopped: {why}"),
                };
                let st = match r.state {
                    Link::Connected => State::On,
                    Link::Stopped(_) => State::Trouble,
                    _ => State::Busy,
                };
                (st, format!("{how}{knows}"), Some(format!("{}\nThe Desk runs it, and stops it when it closes. Its last words:\n{}", r.exe.display(), r.last.join("\n"))))
            }
            Some(Rkbx::Outside) => (State::On, "Running (started outside the Desk)".into(), None),
            Some(Rkbx::Waiting) => (State::Busy, "Listening for it…".into(), None),
            Some(Rkbx::NotFound) | None => match &here.rkbx_link {
                Some(exe) => (State::On, "Found: the Desk runs it while following".into(), Some(exe.display().to_string())),
                None => (State::Trouble, "Not on this computer: it reads rekordbox's decks for the Desk (free, by grufkork)".into(), None),
            },
        };
        let mut rk_hands = vec![];
        if here.rkbx_link.is_none() {
            if let Some(zip) = &here.rkbx_zip {
                rk_hands.push(("Use the download", Hand::Unpack(zip.clone())));
            } else {
                rk_hands.push(("Download…", Hand::Download));
            }
        }
        rk_hands.push((if here.rkbx_link.is_some() { "Change…" } else { "Find it…" }, Hand::FindRkbx));
        lines.push(Line { state: rk_state, name: "rkbx_link", words: rk_words, detail: rk_detail, hands: rk_hands });
        let library = following.as_ref().and_then(|v| v.library.clone());
        let reading = following.as_ref().is_some_and(|v| v.reading);
        lines.push(match (&library, reading) {
            (_, true) => Line { state: State::Busy, name: "Its library", words: "Reading…".into(), detail: None, hands: vec![] },
            (Some(l), false) => {
                let mut w = format!("{} tracks analysed, {} with phrases", l.tracks, l.with_phrases);
                if !l.missing.is_empty() {
                    w.push_str(&format!(" · {} not in the music folders", l.missing.len()));
                }
                let detail = (!l.missing.is_empty()).then(|| format!("Not found:\n{}", l.missing.iter().take(20).cloned().collect::<Vec<_>>().join("\n")));
                Line { state: if l.missing.is_empty() { State::On } else { State::Trouble }, name: "Its library", words: w, detail, hands: vec![("Read again", Hand::ReadAgain)] }
            }
            (None, false) => Line {
                state: State::Off,
                name: "Its library",
                words: if here.library { "Read when following starts".into() } else { "Not found: open rekordbox once".into() },
                detail: None,
                hands: vec![],
            },
        });
        let music = following.as_ref().map(|v| v.music.clone()).unwrap_or_else(|| self.prefs.music());
        lines.push(Line {
            state: if music.is_empty() { State::Trouble } else { State::On },
            name: "Music folders",
            words: if self.prefs.music_folders.is_empty() { "The usual ones (rekordbox keeps only file names; the Desk finds the audio here)".into() } else { "Chosen (rekordbox keeps only file names; the Desk finds the audio here)".into() },
            detail: None,
            hands: vec![("Add a folder…", Hand::AddFolder)],
        });

        let name_w = 130.0;
        let mut hand = None;
        for (i, l) in lines.iter().enumerate() {
            let cy = y + 14.0;
            let dot = match l.state {
                State::On => t::ok(),
                State::Trouble => t::warm(),
                State::Busy => t::soft(),
                State::Off => t::faint(),
            };
            p.circle_filled(pos2(r.left() + 7.0, cy), 4.0, dot);
            kit::text(p, pos2(r.left() + 22.0, cy), Align2::LEFT_CENTER, l.name, t::BODY, "semi", t::text());
            let hands_w: f32 = l.hands.iter().map(|(w, _)| w.len() as f32 * 7.5 + 28.0).sum();
            let x = r.left() + name_w;
            let room = r.right() - x - hands_w - 12.0;
            let tr = kit::clipped(p, pos2(x, cy), &l.words, t::BODY, "", if l.state == State::Trouble { t::warm() } else { t::soft() }, room);
            if let Some(d) = &l.detail {
                ui.interact(tr.union(Rect::from_min_size(pos2(r.left(), y), vec2(name_w, 28.0))), ui.scope_id().with(("rb-line", i)), Sense::hover()).on_hover_text(d);
            }
            let mut hx = r.right();
            for (j, (w, h)) in l.hands.iter().enumerate().rev() {
                let bw = w.len() as f32 * 7.5 + 22.0;
                let br = Rect::from_min_size(pos2(hx - bw, y), vec2(bw, 28.0));
                if Btn::new(w).size(11.0).show(ui, p, br, ("rb-hand", i, j)).clicked() {
                    hand = Some(h.clone());
                }
                hx = br.left() - 6.0;
            }
            y += 38.0;
            // the music folders, one under the other, each with its ×
            if l.name == "Music folders" {
                let mut gone = None;
                for (k, m) in music.iter().enumerate() {
                    let fy = y + 11.0;
                    kit::clipped(p, pos2(x, fy), &m.display().to_string(), 12.5, "mono", t::muted(), r.right() - x - 40.0);
                    let xr = Rect::from_center_size(pos2(r.right() - 12.0, fy), vec2(22.0, 22.0));
                    if Btn::new("").icon(Icon::Close).quiet().show(ui, p, xr, ("rb-folder-x", k)).on_hover_text("Not this folder").clicked() {
                        gone = Some(k);
                    }
                    y += 24.0;
                }
                if let Some(k) = gone {
                    let mut next = music.clone();
                    next.remove(k);
                    self.set_music(desk, &ctx, next);
                }
                y += 8.0;
            }
        }
        if let Some(h) = hand {
            self.rekordbox_hand(desk, &ctx, h, &music);
        }

        // the decks, while following
        if let Some(v) = &following {
            y += 6.0;
            p.line_segment([pos2(r.left(), y), pos2(r.right(), y)], Stroke::new(1.0, white(0.06)));
            y += 14.0;
            kit::section(p, pos2(r.left(), y), Align2::LEFT_TOP, "The decks");
            y += 28.0;
            for (i, d) in v.decks.iter().enumerate() {
                let cy = y + 12.0;
                let chip = kit::deck_chip(p, pos2(r.left(), cy), i);
                let lead = v.lead == Some(i);
                let (c, how) = match (d.found, d.drift_ms) {
                    (None, _) => (t::faint(), "nothing loaded".to_owned()),
                    (Some(false), _) => (t::warm(), "not in the music folders".to_owned()),
                    (Some(true), Some(ms)) if d.playing && ms.abs() <= IN_STEP_MS => (t::ok(), "playing, in step".to_owned()),
                    (Some(true), Some(ms)) if d.playing => (t::warm(), format!("playing, {:.0} ms off: catching up", ms.abs())),
                    (Some(true), _) if d.playing => (t::soft(), "playing".to_owned()),
                    (Some(true), _) => (t::soft(), "stopped".to_owned()),
                };
                let mut how = how;
                if d.found == Some(true) && !d.phrases {
                    how.push_str(" · no phrase analysis (the show guesses its sections)");
                }
                if lead {
                    how.push_str(" · the show follows it");
                }
                let title = if d.title.is_empty() { "—" } else { &d.title };
                let tr = kit::clipped(p, pos2(chip.right() + 10.0, cy), title, t::BODY, "semi", t::text(), (r.width() * 0.45).min(420.0));
                kit::clipped(p, pos2(tr.right() + 12.0, cy), &how, 12.5, "", c, r.right() - tr.right() - 12.0);
                y += 30.0;
            }
        }

        // a few words for the night
        let tips = "Before the set: analyse every track in rekordbox, with phrase analysis on (Preferences → Analysis → Track Analysis Setting). A track loaded before its analysis finished: load it again. The DDJ's faders are not read yet: the show takes the playing deck, both in a blend.";
        let th = p.layout(tips.to_owned(), egui::FontId::new(12.0, crate::paint::family("")), t::faint(), r.width()).size().y;
        words(p, pos2(r.left(), r.bottom() - th), tips, t::faint(), r.width(), 12.0);
    }

    fn set_music(&mut self, desk: &mut Desk, ctx: &egui::Context, music: Vec<PathBuf>) {
        let usual = wo_deskcore::follow::usual_music();
        // back to the usual folders: kept as "none chosen", so they stay the usual ones
        self.prefs.music_folders = if music == usual { vec![] } else { music.clone() };
        self.save_prefs(ctx);
        desk.set_follow_music(self.prefs.music());
    }

    fn rekordbox_hand(&mut self, desk: &mut Desk, ctx: &egui::Context, h: Hand, music: &[PathBuf]) {
        match h {
            Hand::Download => ctx.open_url(egui::OpenUrl::new_tab(RELEASES)),
            Hand::Unpack(zip) => match wo_deskcore::follow::unpack_rkbx_link(&zip) {
                Ok(exe) => self.use_rkbx(desk, ctx, exe),
                Err(e) => self.follow_failed = Some(format!("rkbx_link from {}: {e}", zip.display())),
            },
            Hand::FindRkbx => {
                if let Some(exe) = rfd::FileDialog::new().set_title("rkbx_link: the program, or its folder").add_filter("rkbx_link", &["exe", ""]).pick_file() {
                    self.use_rkbx(desk, ctx, exe);
                }
            }
            Hand::AddFolder => {
                if let Some(dir) = rfd::FileDialog::new().set_title("A folder with your music").pick_folder() {
                    let mut next = music.to_vec();
                    if !next.contains(&dir) {
                        next.push(dir);
                    }
                    self.set_music(desk, ctx, next);
                }
            }
            Hand::ReadAgain => desk.follow_read_again(),
        }
        self.follow_here = None;
    }

    fn use_rkbx(&mut self, desk: &mut Desk, ctx: &egui::Context, exe: PathBuf) {
        self.prefs.rkbx_link = Some(exe.clone());
        self.save_prefs(ctx);
        desk.set_follow_rkbx_link(exe);
    }
}
