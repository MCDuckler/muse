//! The show's decisions in the Desk (plan §2.1: the Desk decides, the stage draws): the
//! director (wo_show::engine::Direct) over the decks as the Desk plays them, each deck's
//! record as facts for it and for the stages (ShowWire v2's `record`), and its decision as a
//! `cue`. A v1 stage directs itself and ignores these lines; the Rust stage (apps/
//! wetowl-stage) draws what they say.
use std::time::Instant;

use wo_booth::Timing;
use wo_show::deck::{RecordFacts, Section};
use wo_show::doc::ShowDoc;
use wo_show::engine::{Cue, Direct};
use wo_show::scenes::{DRAWN, SceneBook};
use wo_show::milk::MilkDirector;
use wo_show::scores::{ComboScores, MilkScores};
use wo_wire::{Hand, MilkShown};

use crate::records::{Audio, Record};

/// The plan, the sets and the director's temper: the WetOwl app's show.json, read (never
/// written) while v1 keeps it; the show as shipped where there is none.
fn v1_doc() -> ShowDoc {
    crate::records::fetched_dir()
        .and_then(|f| f.parent().map(|p| p.join("show.json")))
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| ShowDoc::parse(&t))
        .unwrap_or_default()
}

/// The house's id of a record, as the Desk's frame names it (none for one made here).
pub(crate) fn track_id(r: &Record) -> Option<i64> {
    (r.id > 0 && !matches!(r.audio, Audio::Synth { .. })).then_some(r.id)
}

/// A record's facts for the show, from what the Desk plays it by.
pub(crate) fn facts_of(r: &Record, t: &Timing) -> RecordFacts {
    let ms = |s: f64| s * 1000.0;
    let beats: Vec<f64> = t.grid.beats.iter().map(|&b| ms(b)).collect();
    let bar_one = t.grid.bar_one;
    // a steady grid where the beats lie on a line (a synthesised record, a fitted file)
    let steady = (beats.len() >= 8)
        .then(|| {
            let n = beats.len() as f64;
            let sx: f64 = (0..beats.len()).map(|i| i as f64).sum();
            let sy: f64 = beats.iter().sum();
            let sxx: f64 = (0..beats.len()).map(|i| (i * i) as f64).sum();
            let sxy: f64 = beats.iter().enumerate().map(|(i, y)| i as f64 * y).sum();
            let period = (n * sxy - sx * sy) / (n * sxx - sx * sx);
            let origin = (sy - period * sx) / n;
            let off = beats.iter().enumerate().map(|(i, b)| (b - origin - period * i as f64).abs()).fold(0.0, f64::max);
            (period > 0.0 && off < 12.0).then_some((origin, period))
        })
        .flatten();
    let downbeats: Vec<f64> = beats.iter().enumerate().filter(|(i, _)| *i >= bar_one && (i - bar_one).is_multiple_of(4)).map(|(_, &b)| b).collect();
    let sections: Vec<Section> = t.sections.iter().map(|s| Section { label: s.label.clone(), start_ms: ms(s.start), end_ms: ms(s.end) }).collect();
    // the bars' loudness: the analysis's, else the sections' shape
    let energy = if !t.energy.is_empty() {
        t.energy.clone()
    } else if !sections.is_empty() {
        downbeats
            .iter()
            .map(|&d| match sections.iter().find(|s| d >= s.start_ms && d < s.end_ms).map(|s| s.label.as_str()) {
                Some("drop" | "chorus") => 230,
                Some("build") => 170,
                Some("breakdown" | "break") => 90,
                Some("intro" | "outro") => 110,
                _ => 150,
            })
            .collect()
    } else {
        vec![]
    };
    RecordFacts {
        track_id: track_id(r),
        title: Some(r.title.clone()).filter(|s| !s.is_empty()),
        artist: Some(r.artist.clone()).filter(|s| !s.is_empty()),
        beats_ms: beats,
        steady,
        bar_starts_on: (bar_one % 4) as i64,
        downbeats_ms: downbeats,
        markers_ms: t.markers.iter().map(|&m| ms(m)).collect(),
        energy,
        drops_ms: t.drops.iter().map(|&d| ms(d)).collect(),
        sections,
        key: None,
        camelot: t.camelot.clone().or_else(|| Some(r.key.clone()).filter(|k| !k.is_empty())),
        vocal_bars: None,
        hook_ms: vec![],
        cover_rgb: r.cover_rgb,
    }
}

/// MilkDrop as the Desk shows it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MilkView {
    /// Presets in the library (none: no MilkDrop to choose from).
    pub presets: usize,
    /// The stage has a helper to run; it runs and has drawn; frames a second.
    pub ok: bool,
    pub on: bool,
    pub fps: f32,
    /// The preset on (full name), and as the helper confirmed it.
    pub preset: Option<String>,
    pub confirmed: Option<String>,
    pub favourite: bool,
    pub off: bool,
    pub locked: bool,
    /// The hands picked the one on (the bar clock and the breakdowns leave it).
    pub held: bool,
    pub accents: bool,
    pub favourites_only: bool,
    pub trouble: Option<String>,
}

/// A preset as the browser lists it.
#[derive(Clone, Debug, PartialEq)]
pub struct MilkRow {
    pub path: String,
    pub name: String,
    pub favourite: bool,
    pub off: bool,
    pub on: bool,
}

/// The hands on MilkDrop.
#[derive(Clone, Debug, PartialEq)]
pub enum MilkHand {
    Next,
    Previous,
    /// Another, by chance (a skip, if the director just put this one on).
    Another,
    /// The one on a favourite, or not.
    Favourite,
    /// The one on switched off (never put on by the director), and on to another.
    Off,
    /// A preset by path: a favourite toggled, switched off or on, or put on (held).
    FavouriteOf(String),
    OffOf(String),
    Pick(String),
    /// The director may move on from the hands' pick.
    Release,
    Lock(bool),
    Accents(bool),
    FavouritesOnly(bool),
}

pub(crate) struct Show {
    pub(crate) direct: Direct,
    facts: [Option<RecordFacts>; 2],
    /// Which decks' records have their cover on the stage.
    covers: [bool; 2],
    last: Option<Instant>,
    said: String,
    /// MilkDrop's library folder, and when its notes were last written.
    milk_home: Option<std::path::PathBuf>,
    notes_saved: Instant,
    /// The hands' judging of what is on (v1: desk_hands.dart): what NEVER last took out and
    /// how widely, the plan before it (UNDO), and what the show said of it.
    judged: Judged,
    /// The board as last worked out, and for what (the look, the plan, the grounds here, the
    /// favourites kept).
    board: Option<(BoardKey, ShowBoard)>,
    faves_kept: u32,
}

type BoardKey = (Option<wo_show::Combo>, wo_show::plan::ShowPlan, Option<std::collections::BTreeSet<String>>, u32);

#[derive(Default)]
struct Judged {
    never: Option<wo_show::Combo>,
    scope: u8,
    before: Option<wo_show::plan::ShowPlan>,
    said: Option<String>,
    said_n: u32,
}

/// A combination in words: `Dancer · ascii on White · keyhole · add · kaleidoscope`.
pub(crate) fn combo_words(c: &wo_show::Combo, looks: &std::collections::BTreeMap<String, wo_show::Look>) -> String {
    use wo_show::json::Named;
    let name = looks.get(&c.scene).map_or(c.scene.clone(), |l| l.name.clone());
    let mut w = if c.style == "raw" { name } else { format!("{name} · {}", c.style) };
    if !c.world() {
        let ground: Vec<String> = c.ground.split('.').enumerate().map(|(i, p)| if i == 0 { cap(p) } else { p.to_owned() }).collect();
        w += &format!(" on {}", ground.join(" "));
        if c.mask != wo_show::Mask::None {
            w += &format!(" · {}", c.mask.name());
        }
        w += &format!(" · {}", c.mix.name());
    }
    if c.fx != wo_show::Fx::None {
        w += &format!(" · {}", match c.fx {
            wo_show::Fx::Kaleidoscope => "kaleidoscope",
            wo_show::Fx::Slit => "slit-scan",
            wo_show::Fx::Both => "slit-scan and kaleidoscope",
            _ => "datamosh",
        });
    }
    w
}

fn cap(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}


/// The show as the Show page draws it ([Show::board]).
#[derive(Clone, Debug, Default)]
pub struct ShowBoard {
    /// The likeliest looks next in the scene on, in words, with their shares.
    pub coming: Vec<(String, f32)>,
    /// Bars the look has been on.
    pub bars_on: i64,
    /// The favourites the Rust stage draws: id, words.
    pub faves: Vec<(String, String)>,
    /// How often each scene comes (the most-played 1), by name.
    pub rotation: Vec<(String, f32)>,
}

impl Show {
    /// The director over the scenes the Rust stage draws.
    pub(crate) fn new() -> Show {
        Show::new_in(crate::milk::home())
    }

    /// With MilkDrop's library in `milk_home` (None: no MilkDrop).
    pub(crate) fn new_in(milk_home: Option<std::path::PathBuf>) -> Show {
        let book = SceneBook::shipped().only(DRAWN);
        let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(7, |d| d.as_secs());
        let mut direct = Direct::new(&book, v1_doc(), ComboScores::shipped(), seed);
        direct.director.grounds_here = Some(wo_show::scenes::grounds_drawn(false, false));
        // MilkDrop's library: the shipped presets out where the helper reads them
        if let Some(home) = &milk_home {
            if let Err(e) = crate::milk::write_shipped(home) {
                eprintln!("milk: the shipped presets into {}: {e}", home.display());
            }
            let mut m = MilkDirector::new(crate::milk::library(home), MilkScores::shipped(), seed);
            m.set_textures(Some(home.join("textures").to_string_lossy().into_owned()));
            direct.milk = Some(m);
        }
        Show { direct, facts: [None, None], covers: [false; 2], last: None, said: String::new(), milk_home, notes_saved: Instant::now(), judged: Judged::default(), board: None, faves_kept: 0 }
    }

    /// Whether a deck's record has its cover on the stage (the cover ground's say).
    pub(crate) fn set_cover(&mut self, deck: usize, has: bool) {
        self.covers[deck] = has;
    }

    /// A deck's record as facts: the line to say when they changed.
    pub(crate) fn record(&mut self, deck: usize, facts: Option<RecordFacts>) -> Option<String> {
        if self.facts[deck] == facts {
            return None;
        }
        self.facts[deck] = facts;
        Some(wo_wire::v2::record(["A", "B"][deck], self.facts[deck].as_ref()))
    }

    /// One frame of the Desk, with what the stage said of its MilkDrop: the director's cue, as
    /// a line when it changed.
    pub(crate) fn tick(&mut self, frame: &wo_wire::Frame, milk: Option<&MilkShown>) -> Option<String> {
        let now = Instant::now();
        let dt = self.last.map_or(1.0 / 60.0, |t| (now - t).as_secs_f64().min(0.25));
        self.last = Some(now);
        let room = wo_wire::v2::room(frame, [self.facts[0].as_ref(), self.facts[1].as_ref()], 0.0);
        let ok = milk.is_some_and(|m| m.ok) && self.direct.milk.as_ref().is_some_and(|m| !m.library.presets.is_empty());
        // a cover ground where a deck's record has its cover (the stage shows the master's,
        // else the other's)
        let cover = self.covers.iter().any(|&c| c);
        if self.direct.director.grounds_here.as_ref().is_none_or(|g| g.contains("milk") != ok || g.contains("cover") != cover) {
            self.direct.director.grounds_here = Some(wo_show::scenes::grounds_drawn(ok, cover));
        }
        if let (Some(m), Some(d)) = (milk, self.direct.milk.as_mut()) {
            for p in &m.crashed {
                d.crashed_on(p);
            }
        }
        let mut extra = wo_show::deck::Flat::new();
        extra.insert("milk.ok".into(), if ok { 1.0 } else { 0.0 });
        let (cue, _) = self.direct.tick(dt, room, extra);
        self.save_notes(false);
        let line = wo_wire::v2::cue(&cue);
        if line == self.said {
            return None;
        }
        self.said = line.clone();
        Some(line)
    }

    /// MilkDrop's notes written back when they changed (every few seconds at most), or now.
    pub(crate) fn save_notes(&mut self, now: bool) {
        let (Some(home), Some(m)) = (&self.milk_home, self.direct.milk.as_mut()) else { return };
        if m.library.dirty && (now || self.notes_saved.elapsed().as_secs() >= 3) {
            crate::milk::save_notes(home, &m.library.notes);
            m.library.dirty = false;
            self.notes_saved = Instant::now();
        }
    }

    /// MilkDrop as the Desk shows it, with what the stage said of it.
    pub(crate) fn milk(&self, told: Option<&MilkShown>) -> MilkView {
        let Some(m) = &self.direct.milk else { return MilkView::default() };
        let p = m.preset();
        MilkView {
            presets: m.library.presets.len(),
            ok: told.is_some_and(|t| t.ok),
            on: told.is_some_and(|t| t.on),
            fps: told.map_or(0.0, |t| t.fps),
            preset: m.cue().name.clone(),
            confirmed: told.and_then(|t| t.preset.clone()),
            favourite: p.is_some_and(|p| m.library.is_favourite(p)),
            off: p.is_some_and(|p| m.library.is_off(p)),
            locked: m.locked,
            held: m.held_by_hand,
            accents: m.accents,
            favourites_only: m.favourites_only,
            trouble: told.and_then(|t| t.trouble.clone()),
        }
    }

    /// The presets whose names have `query` in them (all for none), up to `most`.
    pub(crate) fn milk_search(&self, query: &str, most: usize) -> Vec<MilkRow> {
        let Some(m) = &self.direct.milk else { return vec![] };
        let on = m.cue().path.as_deref();
        m.library
            .search(query, false, 0.0, false, false)
            .into_iter()
            .take(most)
            .map(|p| MilkRow { path: p.path.clone(), name: p.full_name(), favourite: m.library.is_favourite(p), off: m.library.is_off(p), on: Some(p.path.as_str()) == on })
            .collect()
    }

    pub(crate) fn milk_hand(&mut self, h: MilkHand) {
        let Some(m) = &mut self.direct.milk else { return };
        let by_path = |m: &wo_show::milk::MilkDirector, path: &str| m.library.by_path(path).cloned();
        match h {
            MilkHand::Next => m.next(),
            MilkHand::Previous => m.previous(),
            MilkHand::Another => m.random(false, true, None),
            MilkHand::Favourite => {
                if let Some(p) = m.preset().cloned() {
                    m.library.toggle_favourite(&p);
                }
            }
            MilkHand::Off => m.switch_off(),
            MilkHand::FavouriteOf(path) => {
                if let Some(p) = by_path(m, &path) {
                    m.library.toggle_favourite(&p);
                }
            }
            MilkHand::OffOf(path) => {
                if let Some(p) = by_path(m, &path) {
                    m.library.toggle_off(&p);
                }
            }
            MilkHand::Pick(path) => {
                if let Some(p) = by_path(m, &path) {
                    m.choose(&p);
                }
            }
            MilkHand::Release => m.release(),
            MilkHand::Lock(on) => m.lock(on),
            MilkHand::Accents(on) => m.set_accents(on),
            MilkHand::FavouritesOnly(on) => m.favourites_only = on,
        }
        self.save_notes(false);
    }

    pub(crate) fn cue(&self) -> &Cue {
        self.direct.cue()
    }

    /// A hand on the show, as the director takes it.
    pub(crate) fn hand(&mut self, h: &Hand) {
        let d = &mut self.direct;
        match h {
            Hand::Hit => d.hit(),
            Hand::Next => d.next(1),
            Hand::Previous => d.next(-1),
            Hand::Mosh => d.mosh_next(),
            Hand::Hold(on) => d.hold(*on),
            Hand::LetGo => d.hold(false),
            Hand::Blackout(on) => d.macros.blackout = *on,
            Hand::Strobe(on) => d.macros.strobe = if *on { 1.0 } else { 0.0 },
            Hand::Freeze(on) => d.macros.freeze = *on,
            Hand::Never => self.never(0, false),
            Hand::Wider => {
                if self.judged.never.is_some() && self.judged.scope < 2 {
                    self.never(self.judged.scope + 1, true);
                }
            }
            Hand::Less => self.scale(0.5),
            Hand::More => self.scale(2.0),
            Hand::Keep => self.keep(),
            Hand::Fave(id) => {
                if let Some(f) = self.direct.doc.faves().into_iter().find(|f| &f.id == id) {
                    let words = combo_words(&f.combo, &self.direct.looks);
                    self.direct.director.play(f.combo, wo_show::director::SceneChange::Dissolve);
                    self.say(format!("On: {words}"));
                }
            }
            Hand::Undo => {
                if let Some(b) = self.judged.before.take() {
                    self.set_plan(b);
                    self.judged.never = None;
                    self.say("Undone".into());
                }
            }
            _ => {}
        }
    }

    /// The show as the Show page draws it: what may come next, how long the look has been
    /// on, the favourites the Rust stage can put on, and the rotation.
    pub(crate) fn board(&mut self) -> ShowBoard {
        let d = &mut self.direct;
        let on = d.director.combo().cloned();
        // the look's alternatives weigh every combination of its scene (milliseconds): only
        // again when the look, the plan or the grounds here change
        let key = (on.clone(), d.director.plan().clone(), d.director.grounds_here.clone(), self.faves_kept);
        if self.board.as_ref().is_some_and(|(k, _)| *k == key) {
            return self.board.as_ref().map(|(_, b)| b.clone()).unwrap_or_default();
        }
        let mut coming: Vec<(wo_show::Combo, f64)> = match d.director.scene() {
            Some(scene) => d.director.weighted(scene).into_iter().filter(|(c, w)| *w > 0.0 && Some(c) != on.as_ref()).collect(),
            None => vec![],
        };
        coming.sort_by(|a, b| b.1.total_cmp(&a.1));
        let total: f64 = coming.iter().map(|c| c.1).sum::<f64>().max(1e-9);
        let coming = coming.into_iter().take(3).map(|(c, w)| (combo_words(&c, &d.looks), (w / total) as f32)).collect();
        let faves = d
            .doc
            .faves()
            .into_iter()
            .filter(|f| DRAWN.contains(&f.combo.scene.as_str()))
            .take(12)
            .map(|f| {
                let words = if f.name.is_empty() { combo_words(&f.combo, &d.looks) } else { f.name.clone() };
                (f.id, words)
            })
            .collect();
        let levels = d.director.levels();
        let most = levels.values().copied().fold(0.0f64, f64::max).max(1e-9);
        let mut rotation: Vec<(String, f32)> = levels
            .iter()
            .filter(|(id, _)| DRAWN.contains(&id.as_str()))
            .map(|(id, l)| (d.looks.get(id).map_or(id.clone(), |l| l.name.clone()), (l / most) as f32))
            .collect();
        rotation.sort_by(|a, b| b.1.total_cmp(&a.1));
        let b = ShowBoard { coming, bars_on: 0, faves, rotation };
        self.board = Some((key, b.clone()));
        b
    }

    /// The board with what moves every bar.
    pub(crate) fn board_now(&mut self) -> ShowBoard {
        ShowBoard { bars_on: self.direct.director.combo_bars(), ..self.board() }
    }

    /// The look on, in words.
    pub(crate) fn look_words(&self) -> Option<String> {
        self.direct.director.combo().map(|c| combo_words(c, &self.direct.looks))
    }

    /// What the hands' judging said last (counted), and whether UNDO and WIDER have work.
    pub(crate) fn judged(&self) -> (Option<String>, u32, bool, bool) {
        let j = &self.judged;
        (j.said.clone(), j.said_n, j.before.is_some(), j.never.as_ref().is_some_and(|c| j.scope < 2 && !c.world()))
    }

    fn say(&mut self, words: String) {
        self.judged.said = Some(words);
        self.judged.said_n += 1;
    }

    /// The plan the director picks by, changed (kept for this session: the WetOwl app's
    /// show.json is read, never written, while v1 keeps it).
    fn set_plan(&mut self, p: wo_show::plan::ShowPlan) {
        self.direct.doc.set_plan(&p);
        self.direct.director.set_plan(p);
    }

    /// NEVER this look: the combination (0), its style on its ground whatever the mask and
    /// blend (1), or the scene in that style at all (2); WIDER reaches from the plan before.
    fn never(&mut self, scope: u8, again: bool) {
        use wo_show::plan::{PlanAxis, cell_key, cell_of};
        let c = if again { self.judged.never.clone() } else { self.direct.director.combo().cloned() };
        let Some(c) = c else { return };
        let before = if again { self.judged.before.clone().unwrap_or_else(|| self.direct.director.plan().clone()) } else { self.direct.director.plan().clone() };
        let name = self.direct.looks.get(&c.scene).map_or(c.scene.clone(), |l| l.name.clone());
        let s = if c.world() { 2 } else { scope };
        let (plan, words) = match s {
            0 => (before.with_cell(&c.scene, &cell_of(&c), Some(0.0)), format!("Never: {}", combo_words(&c, &self.direct.looks))),
            1 => (before.with_cell(&c.scene, &cell_key(&c.style, &c.ground, "*", "*", "*"), Some(0.0)), format!("Never: {name} · {}, any mask and blend", c.style)),
            _ => (
                before.with_in(&c.scene, PlanAxis::Style, &c.style, None, Some(true)),
                format!("Never: {name} in {}", if c.style == "raw" { "its own style" } else { c.style.as_str() }),
            ),
        };
        self.judged.before = Some(before);
        self.judged.never = Some(c);
        self.judged.scope = s;
        self.set_plan(plan);
        self.say(words);
        // and off it, now
        self.direct.next(1);
    }

    /// LESS (½) or MORE (×2) of the look on.
    fn scale(&mut self, k: f64) {
        use wo_show::plan::{cell_of, level_word};
        let Some(c) = self.direct.director.combo().cloned().filter(|c| !c.world()) else { return };
        let before = self.direct.director.plan().clone();
        let key = cell_of(&c);
        let next = before.scale_cell(&c.scene, &key, k);
        let level = next.of(&c.scene).cells.get(&key).copied().unwrap_or(1.0);
        self.judged.before = Some(before);
        self.judged.never = None;
        self.set_plan(next);
        self.say(format!("{}: {} — {}", if k < 1.0 { "Less" } else { "More" }, combo_words(&c, &self.direct.looks), level_word(level)));
    }

    /// KEEP: the look on as a favourite (the MilkDrop preset with it).
    fn keep(&mut self) {
        let Some(c) = self.direct.director.combo().cloned() else {
            self.say("Nothing on to keep".into());
            return;
        };
        let micros = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_micros() as i64);
        let at = chrono_free_iso(micros / 1_000_000);
        let milk = self.direct.milk.as_ref().and_then(|m| m.preset().map(|p| p.name.clone()));
        let words = combo_words(&c, &self.direct.looks);
        let fave = wo_show::faves::ShowFave { id: wo_show::faves::ShowFave::new_id(micros), at, combo: c, milk, shot: None, type3d: None, stars: 0, name: String::new() };
        self.direct.doc.keep_fave(fave);
        self.faves_kept += 1;
        self.say(format!("Kept: {words}"));
    }
}

/// Seconds since 1970 as ISO 8601 UTC (`2026-11-03T19:42:07Z`), without a calendar crate.
fn chrono_free_iso(secs: i64) -> String {
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // civil from days (Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem / 60 % 60, rem % 60)
}

#[cfg(test)]
mod tests {
    use super::*;
    use wo_booth::Grid;

    #[test]
    fn iso_dates_without_a_calendar() {
        assert_eq!(chrono_free_iso(0), "1970-01-01T00:00:00Z");
        assert_eq!(chrono_free_iso(1_793_740_927), "2026-11-03T21:22:07Z");
        assert_eq!(chrono_free_iso(951_782_400), "2000-02-29T00:00:00Z", "a leap day");
    }

    #[test]
    fn a_synthesised_record_reads_as_steady_facts() {
        let spb = 60.0 / 128.0;
        let beats: Vec<f64> = (0..256).map(|i| 0.1 + i as f64 * spb).collect();
        let mut t = Timing::from_grid(Grid::new(beats, 1), 120.0);
        t.sections = vec![wo_booth::mix::Section { label: "drop".into(), start: 0.0, end: 60.0 }, wo_booth::mix::Section { label: "breakdown".into(), start: 60.0, end: 120.0 }];
        let r = Record { id: 0, title: "Loop".into(), artist: String::new(), bpm: 128.0, key: "8A".into(), seconds: 120, audio: Audio::Synth { seed: 1 }, cover: false, cover_rgb: None };
        let f = facts_of(&r, &t);
        assert_eq!(f.track_id, None);
        let (origin, period) = f.steady.unwrap();
        assert!((origin - 100.0).abs() < 1e-6 && (period - spb * 1000.0).abs() < 1e-6);
        assert_eq!(f.bar_starts_on, 1);
        assert_eq!(f.downbeats_ms[0], f.beats_ms[1]);
        assert_eq!(f.energy.len(), f.downbeats_ms.len());
        assert_eq!((f.energy[0], *f.energy.last().unwrap()), (230, 90), "the sections' shape");
        assert_eq!(f.camelot.as_deref(), Some("8A"));
    }

    #[test]
    fn the_hands_judge_what_is_on_and_undo_it() {
        let mut show = Show::new_in(None);
        let r = Record { id: 0, title: "Loop".into(), artist: String::new(), bpm: 120.0, key: String::new(), seconds: 200, audio: Audio::Synth { seed: 1 }, cover: false, cover_rgb: None };
        let t = Timing::from_grid(Grid::new((0..400).map(|i| i as f64 * 0.5).collect(), 0), 200.0);
        show.record(0, Some(facts_of(&r, &t)));
        let frame = wo_wire::Frame { a: wo_wire::Deck { playing: true, position_ms: 4000.0, rate: 1.0, level: 1.0, ..Default::default() }, ..Default::default() };
        show.tick(&frame, None);
        let c = show.direct.director.combo().cloned().expect("a look on");
        let words = show.look_words().unwrap();
        assert!(!words.is_empty());
        // MORE doubles its cell; LESS halves it back
        show.hand(&Hand::More);
        let key = wo_show::plan::cell_of(&c);
        let level = |s: &Show| s.direct.director.plan().of(&c.scene).cells.get(&key).copied().unwrap_or(1.0);
        if !c.world() {
            assert_eq!(level(&show), 2.0);
            let (said, n, undo, _) = show.judged();
            assert!(said.unwrap().starts_with("More: ") && n == 1 && undo);
            show.hand(&Hand::Less);
            assert_eq!(level(&show), 1.0);
        }
        // NEVER takes it out of the plan (and off the stage); UNDO puts the plan back
        let before = show.direct.director.plan().clone();
        show.hand(&Hand::Never);
        assert_ne!(*show.direct.director.plan(), before);
        assert!(show.judged().0.unwrap().starts_with("Never: "));
        show.hand(&Hand::Undo);
        assert_eq!(*show.direct.director.plan(), before);
        assert_eq!(show.judged().0.as_deref(), Some("Undone"));
        // KEEP: a favourite of it
        let faves = show.direct.doc.faves().len();
        show.hand(&Hand::Keep);
        assert_eq!(show.direct.doc.faves().len(), faves + 1);
    }

    #[test]
    fn the_desk_directs_and_says_the_cue_only_when_it_changes() {
        let home = std::env::temp_dir().join(format!("wo-show-milk-{}", std::process::id()));
        let mut show = Show::new_in(Some(home.clone()));
        assert!(show.direct.milk.as_ref().is_some_and(|m| m.library.presets.len() > 500), "the shipped presets");
        let spb = 0.5;
        let r = Record { id: 0, title: "Loop".into(), artist: String::new(), bpm: 120.0, key: String::new(), seconds: 200, audio: Audio::Synth { seed: 1 }, cover: false, cover_rgb: None };
        let t = Timing::from_grid(Grid::new((0..400).map(|i| i as f64 * spb).collect(), 0), 200.0);
        let line = show.record(0, Some(facts_of(&r, &t))).expect("the record said");
        assert!(line.starts_with(r#"{"t":"record","deck":"A""#), "{line}");
        assert!(show.record(0, Some(facts_of(&r, &t))).is_none(), "said once");
        let frame = wo_wire::Frame { a: wo_wire::Deck { playing: true, position_ms: 4000.0, rate: 1.0, level: 1.0, ..Default::default() }, ..Default::default() };
        let first = show.tick(&frame, None).expect("a first cue");
        assert!(first.contains(r#""t":"cue""#));
        assert!(DRAWN.contains(&show.cue().scene.as_deref().unwrap()));
        assert!(show.tick(&frame, None).is_none(), "nothing new");
        show.hand(&Hand::Blackout(true));
        assert!(show.tick(&frame, None).unwrap().contains(r#""blackout":true"#));
        // no MilkDrop on the stage: no preset chosen, and no milk ground
        assert!(show.cue().milk.path.is_none());
        assert!(!show.direct.director.grounds_here.as_ref().unwrap().contains("milk"));
        // a stage with MilkDrop: a preset on, and the ground there
        let milk = MilkShown { ok: true, ..Default::default() };
        show.tick(&frame, Some(&milk));
        let on = show.cue().milk.path.clone().expect("a preset");
        assert!(show.direct.director.grounds_here.as_ref().unwrap().contains("milk"));
        assert!(show.cue().milk.textures.as_deref().is_some_and(|t| t.ends_with("textures")));
        // it crashed on that one: another
        show.tick(&frame, Some(&MilkShown { ok: true, crashed: vec![on.clone()], ..Default::default() }));
        assert_ne!(show.cue().milk.path.as_deref(), Some(on.as_str()));
        show.save_notes(true);
        assert!(home.join("notes.json").is_file());
        let _ = std::fs::remove_dir_all(&home);
    }
}

#[cfg(test)]
mod board {
    /// Weighing a look's alternatives takes milliseconds: the Show page asks every frame, so
    /// the board is worked out once per look (and again when the plan changes).
    #[test]
    fn the_board_is_worked_out_once_per_look() {
        let mut s = super::Show::new_in(None);
        let frame = wo_wire::Frame::default();
        for _ in 0..30 {
            s.tick(&frame, None);
        }
        let first = s.board_now();
        assert!(!first.coming.is_empty(), "a scene on has alternatives");
        assert!(!first.rotation.is_empty());
        let t = std::time::Instant::now();
        for _ in 0..100 {
            assert_eq!(s.board_now().coming, first.coming);
        }
        assert!(t.elapsed().as_millis() < 50, "kept, not weighed again: {:?} for 100", t.elapsed());
        // LESS changes the plan: the board follows
        s.hand(&wo_wire::Hand::Less);
        let _ = s.board_now();
        assert!(s.board.as_ref().is_some_and(|(k, _)| k.1 == *s.direct.director.plan()));
    }
}
