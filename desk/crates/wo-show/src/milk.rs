//! MilkDrop's side of the show (v1: milk_library.dart, milk_director.dart, milk_accent.dart and
//! milk_feed.dart's varsOf), cut as the rest of the show is (plan §2.1):
//!
//! - the Desk keeps the [MilkLibrary] (the presets there are, and what the hands think of
//!   them) and runs the [MilkDirector] (which preset is on, when it changes, cut or blended),
//!   whose choice goes to the stages in the cue ([MilkCue]);
//! - the stage feeds the helper each frame: the show's numbers by name ([vars_of]) and the
//!   accents ([MilkAccent]) that make a shipped preset move with the record.
//!
//! A preset is a file, "Author - Title.milk"; nothing here reads more of it than its name
//! (and the Desk its rating).
use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use crate::deck::ShowDeck;
use crate::director::{drive, intensity_for};
use crate::events::{EventKind, ShowEvent};
use crate::rng::Rng;
use crate::scores::{ComboScores, MilkScores};
use crate::state::ShowState;

// ------------------------------------------------------------------ the library

#[derive(Clone, Debug, PartialEq)]
pub struct MilkPreset {
    /// The file, as the helper is told it.
    pub path: String,
    /// The title without the author and the extension.
    pub name: String,
    pub author: String,
    /// `shipped`, `mine`, or an imported folder's name.
    pub collection: String,
    /// The author's own word on it, 0..5 (fRating); 3 where the file does not say.
    pub rating: f64,
}

impl MilkPreset {
    /// Author and title off a file name, by the convention "Author - Title.milk".
    pub fn of(path: &str, collection: &str, rating: f64) -> MilkPreset {
        let base = path.rsplit(['/', '\\']).next().unwrap_or(path);
        let base = if base.to_lowercase().ends_with(".milk") { &base[..base.len() - 5] } else { base };
        let (author, name) = match base.find(" - ") {
            Some(d) if d > 0 => (&base[..d], &base[d + 3..]),
            _ => ("", base),
        };
        MilkPreset { path: path.into(), name: name.into(), author: author.into(), collection: collection.into(), rating }
    }

    pub fn full_name(&self) -> String {
        if self.author.is_empty() { self.name.clone() } else { format!("{} - {}", self.author, self.name) }
    }
}

/// The rating off a preset file's head (`fRating=4.000`), 3 where it says none.
pub fn rating_of(head: &str) -> f64 {
    head.find("fRating=")
        .map(|i| &head[i + 8..])
        .and_then(|r| r.split(|c: char| !(c.is_ascii_digit() || c == '.')).next().and_then(|n| n.parse::<f64>().ok()))
        .map_or(3.0, |v| v.clamp(0.0, 5.0))
}

/// What the hands think of the presets (v1's notes.json, shared while v1 keeps it).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MilkNotes {
    pub favourites: BTreeSet<String>,
    /// Never put on by the director (the hands still can).
    pub off: BTreeSet<String>,
    /// Paths, the newest first.
    pub recent: Vec<String>,
    /// Imported folders: name → path.
    pub imported: BTreeMap<String, String>,
    /// How often the hands skipped each one soon after the director put it on, oldest first.
    pub skips: Vec<(String, i64)>,
}

impl MilkNotes {
    pub const SKIPS_KEPT: usize = 300;

    pub fn parse(text: &str) -> MilkNotes {
        let Ok(j) = serde_json::from_str::<Value>(text) else { return MilkNotes::default() };
        let strings = |k: &str| -> Vec<String> { j.get(k).and_then(Value::as_array).map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect()).unwrap_or_default() };
        let map = |k: &str| j.get(k).and_then(Value::as_object).cloned().unwrap_or_default();
        MilkNotes {
            favourites: strings("favourites").into_iter().collect(),
            off: strings("off").into_iter().collect(),
            recent: strings("recent"),
            imported: map("imported").into_iter().filter_map(|(k, v)| v.as_str().map(|s| (k, s.to_owned()))).collect(),
            skips: map("skips").into_iter().map(|(k, v)| (k, v.as_i64().unwrap_or(0))).collect(),
        }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "favourites": self.favourites,
            "off": self.off,
            "recent": self.recent,
            "imported": self.imported,
            "skips": self.skips.iter().map(|(k, v)| (k.clone(), json!(v))).collect::<serde_json::Map<String, Value>>(),
        })
    }
}

/// The presets there are, and the notes on them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MilkLibrary {
    /// By full name, case aside.
    pub presets: Vec<MilkPreset>,
    pub notes: MilkNotes,
    /// The notes changed since the Desk last wrote them.
    pub dirty: bool,
}

impl MilkLibrary {
    pub fn new(mut presets: Vec<MilkPreset>, notes: MilkNotes) -> MilkLibrary {
        presets.sort_by_key(|p| p.full_name().to_lowercase());
        MilkLibrary { presets, notes, dirty: false }
    }

    pub fn by_name(&self, full: &str) -> Option<&MilkPreset> {
        self.presets.iter().find(|p| p.full_name() == full)
    }

    pub fn by_path(&self, path: &str) -> Option<&MilkPreset> {
        self.presets.iter().find(|p| p.path == path)
    }

    pub fn is_favourite(&self, p: &MilkPreset) -> bool {
        self.notes.favourites.contains(&p.full_name())
    }

    pub fn is_off(&self, p: &MilkPreset) -> bool {
        self.notes.off.contains(&p.full_name())
    }

    pub fn toggle_favourite(&mut self, p: &MilkPreset) {
        let n = p.full_name();
        if !self.notes.favourites.remove(&n) {
            self.notes.favourites.insert(n);
        }
        self.dirty = true;
    }

    pub fn toggle_off(&mut self, p: &MilkPreset) {
        let n = p.full_name();
        if !self.notes.off.remove(&n) {
            self.notes.off.insert(n);
        }
        self.dirty = true;
    }

    pub fn skipped(&mut self, p: &MilkPreset) {
        let n = p.full_name();
        let was = self.notes.skips.iter().position(|(k, _)| *k == n).map(|i| self.notes.skips.remove(i).1).unwrap_or(0);
        self.notes.skips.push((n, was + 1));
        while self.notes.skips.len() > MilkNotes::SKIPS_KEPT {
            self.notes.skips.remove(0);
        }
        self.dirty = true;
    }

    /// How much the director leans on `p` for the hands' skips: 1 never skipped, a half once…
    pub fn skip_lean(&self, p: &MilkPreset) -> f64 {
        let n = p.full_name();
        1.0 / (1.0 + self.notes.skips.iter().find(|(k, _)| *k == n).map_or(0, |(_, v)| *v) as f64)
    }

    pub fn note_used(&mut self, p: &MilkPreset) {
        self.notes.recent.retain(|r| *r != p.path);
        self.notes.recent.insert(0, p.path.clone());
        self.notes.recent.truncate(50);
        self.dirty = true;
    }

    /// The preset on last, if it is still there.
    pub fn last(&self) -> Option<&MilkPreset> {
        self.notes.recent.first().and_then(|p| self.by_path(p))
    }

    /// The pool the director draws from: the favourites where there are any, else all —
    /// never one switched off (all of them off is none off).
    pub fn pool(&self, favourites_only: bool, min_rating: f64) -> Vec<&MilkPreset> {
        let mut on: Vec<&MilkPreset> = self.presets.iter().filter(|p| !self.is_off(p)).collect();
        if on.is_empty() {
            on = self.presets.iter().collect();
        }
        if favourites_only {
            let f: Vec<&MilkPreset> = on.iter().copied().filter(|p| self.is_favourite(p)).collect();
            if !f.is_empty() {
                return f;
            }
        }
        let rated: Vec<&MilkPreset> = on.iter().copied().filter(|p| p.rating >= min_rating || p.collection == "mine").collect();
        if rated.is_empty() { on } else { rated }
    }

    /// The list for the hands: `off_only` the ones switched off, `hide_off` without them.
    pub fn search(&self, query: &str, favourites_only: bool, min_rating: f64, off_only: bool, hide_off: bool) -> Vec<&MilkPreset> {
        let q = query.trim().to_lowercase();
        self.presets
            .iter()
            .filter(|p| {
                (!favourites_only || self.is_favourite(p))
                    && (!off_only || self.is_off(p))
                    && (!hide_off || !self.is_off(p))
                    && (p.rating >= min_rating || p.collection == "mine")
                    && (q.is_empty() || p.full_name().to_lowercase().contains(&q))
            })
            .collect()
    }
}

// ------------------------------------------------------------------ the cue

/// The preset the stages draw (with the Desk's Cue): a new `n` is a new load.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct MilkCue {
    pub path: Option<String>,
    /// Its full name (for the stage's word, and the scores).
    pub name: Option<String>,
    /// The loads so far.
    pub n: u64,
    /// Blended into over `blend` seconds, or cut.
    pub soft: bool,
    pub blend: f64,
    /// Held: the helper switches nothing by itself.
    pub lock: bool,
    /// The beat put on it (MilkAccent).
    pub accents: bool,
    /// How much it moves with the music by itself (MilkScores), for the accents.
    pub react: Option<f64>,
    /// Where presets' textures are looked for.
    pub textures: Option<String>,
}

// ------------------------------------------------------------------ the director

/// Which preset is on (v1: milk_director.dart). MilkDrop's own clock would change presets
/// every so many seconds; here the music does: a hit cuts to another, a drop cuts (or, where
/// MilkDrop is the picture, more often than not datamoshes into another), a breakdown blends
/// into one over four bars, and once so many bars have gone by the next comes on with the
/// next phrase — unless the hands locked the one on.
///
/// Which one: as intense as where the record is, under a figure one a figure is not lost in,
/// in a loud part one that moves with the music by itself; the favourites more often.
pub struct MilkDirector {
    pub library: MilkLibrary,
    pub scores: Option<MilkScores>,
    /// Held: nothing changes it but the hands.
    pub locked: bool,
    pub favourites_only: bool,
    /// Blend to the next every so many bars; 0 never by the clock.
    pub every_bars: i64,
    pub cut_on_drop: bool,
    pub accents: bool,
    pub min_rating: f64,
    /// The presets the helper died on, this run: not put on again.
    pub crashed: BTreeSet<String>,
    /// A preset the hands picked stays until a drop or a hit, or the hands pick again.
    pub held_by_hand: bool,
    /// The datamoshes asked of the stage.
    pub moshes: i64,
    /// How intense the picture should be now; MilkDrop a background under a figure.
    pub target: Option<f64>,
    pub under_figure: bool,
    cue: MilkCue,
    rng: Rng,
    on_path: Option<String>,
    bars_on: i64,
    bars_since_phrase: i64,
    mine: Option<String>,
    due: Option<(MilkPreset, i64)>,
}

impl MilkDirector {
    /// Within this many bars of the director putting a preset on, the hands' next says "not this".
    pub const SKIP_BARS: i64 = 4;
    /// How often a drop is datamoshed into where MilkDrop is the picture.
    pub const MOSH_ON_DROP: f64 = 0.6;

    pub fn new(library: MilkLibrary, scores: Option<MilkScores>, seed: u64) -> MilkDirector {
        MilkDirector {
            library,
            scores,
            locked: false,
            favourites_only: false,
            every_bars: 16,
            cut_on_drop: true,
            accents: true,
            min_rating: 3.0,
            crashed: BTreeSet::new(),
            held_by_hand: false,
            moshes: 0,
            target: None,
            under_figure: false,
            cue: MilkCue { accents: true, ..Default::default() },
            rng: Rng::new(seed ^ 0x6d69_6c6b),
            on_path: None,
            bars_on: 0,
            bars_since_phrase: 999,
            mine: None,
            due: None,
        }
    }

    /// Where presets' textures are looked for, for the stages.
    pub fn set_textures(&mut self, dir: Option<String>) {
        self.cue.textures = dir;
    }

    /// What the stages are told.
    pub fn cue(&self) -> &MilkCue {
        &self.cue
    }

    /// The preset on, as the library knows it.
    pub fn preset(&self) -> Option<&MilkPreset> {
        self.cue.path.as_deref().and_then(|p| self.library.by_path(p))
    }

    fn scores(&self) -> Option<&MilkScores> {
        self.scores.as_ref()
    }

    /// How likely `p` is now.
    pub fn weigh(&self, p: &MilkPreset) -> f64 {
        let name = p.full_name();
        let s = self.scores();
        let mut w = ComboScores::lean(if self.under_figure { s.and_then(|s| s.ground(&name)) } else { None });
        if w <= 0.0 {
            return 0.0;
        }
        let (t, i) = (self.target, s.and_then(|s| s.intensity(&name)));
        if let (Some(t), Some(i)) = (t, i) {
            let d = i - t;
            w *= (-d * d / (2.0 * 0.22 * 0.22)).exp();
        }
        if let (Some(t), Some(r)) = (t, s.and_then(|s| s.react(&name)))
            && t > 0.5
        {
            w *= 1.0 + 1.6 * (t - 0.5) * 2.0 * (r - 0.5);
        }
        if self.library.is_favourite(p) {
            w *= 2.5;
        }
        w * self.library.skip_lean(p)
    }

    fn pick(&mut self, not: Option<&str>) -> Option<MilkPreset> {
        let pool: Vec<MilkPreset> = self.library.pool(self.favourites_only, self.min_rating).into_iter().filter(|p| !self.crashed.contains(&p.path)).cloned().collect();
        match pool.len() {
            0 => return None,
            1 => return pool.into_iter().next(),
            _ => {}
        }
        let weights: Vec<f64> = pool.iter().map(|p| if Some(p.path.as_str()) == not { 0.0 } else { self.weigh(p) }).collect();
        let total: f64 = weights.iter().sum();
        if total <= 0.0 {
            let others: Vec<&MilkPreset> = pool.iter().filter(|p| Some(p.path.as_str()) != not).collect();
            let i = (self.rng.next_f64() * others.len() as f64) as usize;
            return others.get(i.min(others.len().saturating_sub(1))).map(|p| (*p).clone());
        }
        let mut x = self.rng.next_f64() * total;
        for (p, w) in pool.iter().zip(&weights) {
            x -= w;
            if x <= 0.0 && *w > 0.0 {
                return Some(p.clone());
            }
        }
        pool.iter().zip(&weights).rev().find(|(_, w)| **w > 0.0).map(|(p, _)| p.clone())
    }

    fn load(&mut self, p: &MilkPreset, soft: bool, blend: Option<f64>) {
        self.cue.path = Some(p.path.clone());
        self.cue.name = Some(p.full_name());
        self.cue.n += 1;
        self.cue.soft = soft && blend.is_some();
        self.cue.blend = blend.unwrap_or(0.0);
        self.cue.react = if p.collection == "mine" { Some(0.8) } else { self.scores().and_then(|s| s.react(&p.full_name())) };
        self.library.note_used(p);
    }

    /// The helper came up (or the Desk did): the preset on last, unless it crashed or was
    /// switched off since; or any.
    pub fn start(&mut self) {
        if self.cue.path.is_some() {
            return;
        }
        let last = self.library.last().filter(|l| !self.crashed.contains(&l.path) && !self.library.is_off(l)).cloned();
        if let Some(p) = last.or_else(|| self.pick(None)) {
            self.load(&p, false, None);
        }
    }

    // ---------------------------------------------------------------- the hands

    /// The hands' choice: a cut, and held.
    pub fn choose(&mut self, p: &MilkPreset) {
        self.held_by_hand = true;
        self.load(p, false, None);
    }

    pub fn release(&mut self) {
        self.held_by_hand = false;
    }

    pub fn lock(&mut self, on: bool) {
        self.locked = on;
        self.cue.lock = on;
    }

    pub fn set_accents(&mut self, on: bool) {
        self.accents = on;
        self.cue.accents = on;
    }

    /// The one on switched off, and on to another.
    pub fn switch_off(&mut self) {
        let Some(p) = self.preset().cloned() else { return };
        if !self.library.is_off(&p) {
            self.library.toggle_off(&p);
        }
        if let Some(n) = self.pick(Some(&p.path)).filter(|n| !self.library.is_off(n)) {
            self.load(&n, false, None);
        }
    }

    pub fn next(&mut self) {
        self.step(1);
    }

    pub fn previous(&mut self) {
        self.step(-1);
    }

    /// Another, by chance: a cut, or a blend over `blend` seconds.
    pub fn random(&mut self, soft: bool, by_hand: bool, blend: Option<f64>) {
        if by_hand {
            self.skip();
        }
        let not = self.cue.path.clone();
        let Some(p) = self.pick(not.as_deref()) else { return };
        self.held_by_hand = by_hand;
        self.mine = (!by_hand).then(|| p.path.clone());
        self.load(&p, soft && !by_hand, blend);
    }

    /// The helper died on the preset on: never again this run, and on to another.
    pub fn crashed_on(&mut self, path: &str) {
        if self.crashed.insert(path.to_owned()) && self.cue.path.as_deref() == Some(path) {
            let held = self.held_by_hand;
            self.random(false, false, None);
            self.held_by_hand = held;
        }
    }

    fn skip(&mut self) {
        if let Some(p) = self.preset().cloned()
            && self.mine.as_deref() == Some(p.path.as_str())
            && self.bars_on < Self::SKIP_BARS
        {
            self.library.skipped(&p);
        }
        self.mine = None;
    }

    fn step(&mut self, by: i64) {
        self.skip();
        let list: Vec<MilkPreset> = self.library.search("", self.favourites_only, self.min_rating, false, true).into_iter().cloned().collect();
        if list.is_empty() {
            return;
        }
        let i = self.cue.path.as_ref().and_then(|c| list.iter().position(|p| p.path == *c));
        let n = match i {
            None => 0,
            Some(i) => (i as i64 + by).rem_euclid(list.len() as i64) as usize,
        };
        let p = list[n].clone();
        self.choose(&p);
    }

    // ---------------------------------------------------------------- the music

    /// Every tick of the Desk, with what happened since the last; `milk_scene` where MilkDrop
    /// is the picture itself (not a ground under a figure).
    pub fn frame(&mut self, st: &ShowState, said: &[ShowEvent], milk_scene: bool) {
        if self.cue.path.is_none() {
            self.start();
        }
        if self.locked {
            return;
        }
        let m = st.master().clone();
        self.target = (m.playing || m.bpm.is_some()).then(|| intensity_for(&m, 0.0));
        self.under_figure = !milk_scene;
        if let Some((p, n)) = self.due.take() {
            if n <= 1 {
                self.mine = Some(p.path.clone());
                self.load(&p, false, None);
            } else {
                self.due = Some((p, n - 1));
            }
        }
        if self.cue.path != self.on_path {
            self.on_path = self.cue.path.clone();
            self.bars_on = 0;
        }
        let mut phrase = false;
        for e in said.iter().filter(|e| e.master) {
            if e.kind == EventKind::Bar {
                self.bars_on += 1;
                self.bars_since_phrase += 1;
            }
            if e.kind == EventKind::Phrase {
                phrase = true;
                self.bars_since_phrase = 0;
            }
        }
        let bpm = m.bpm.unwrap_or(120.0);
        let blend_of = |bars: f64| (bars * 240.0 / bpm).clamp(1.0, 10.0);
        let loud = drive(&m) > 0.5;
        for e in said {
            match e.kind {
                EventKind::Drop => {
                    if self.cut_on_drop {
                        self.drop(milk_scene);
                    }
                    return;
                }
                EventKind::Hit => {
                    if self.cut_on_drop && self.due.is_none() {
                        self.random(false, false, None);
                    }
                    return;
                }
                EventKind::Breakdown => {
                    if !self.held_by_hand {
                        self.random(true, false, Some(blend_of(4.0)));
                    }
                    return;
                }
                EventKind::Loaded => {
                    if e.deck.as_deref() == Some(st.master_name.as_str()) && !self.held_by_hand {
                        self.random(true, false, Some(blend_of(2.0)));
                    }
                    return;
                }
                EventKind::Section => {
                    let off = self.off_target().unwrap_or(0.0);
                    if !self.held_by_hand && off > 0.35 {
                        self.random(true, false, Some(blend_of(if loud { 1.0 } else { 2.0 })));
                    }
                    return;
                }
                _ => {}
            }
        }
        if self.held_by_hand || self.every_bars <= 0 || !m.playing || self.due.is_some() {
            return;
        }
        if self.bars_on >= self.every_bars && (phrase || self.bars_since_phrase > 32) {
            self.random(true, false, Some(blend_of(if loud { 1.0 } else { 2.0 })));
        }
    }

    fn off_target(&self) -> Option<f64> {
        let t = self.target?;
        let p = self.preset()?;
        let i = self.scores()?.intensity(&p.full_name())?;
        Some((i - t).abs())
    }

    fn drop(&mut self, milk_scene: bool) {
        let not = self.cue.path.clone();
        let Some(p) = self.pick(not.as_deref()) else { return };
        self.held_by_hand = false;
        if milk_scene && self.rng.next_f64() < Self::MOSH_ON_DROP {
            self.moshes += 1;
            // put on a couple of ticks after the mosh is asked for, so the melt starts from
            // the one before
            self.due = Some((p, 2));
        } else {
            self.mine = Some(p.path.clone());
            self.load(&p, false, None);
        }
    }
}

// ------------------------------------------------------------------ the stage's side

/// The section as a number: 0 none, 1 intro, 2 verse, 3 build, 4 drop, 5 chorus, 6 breakdown,
/// 7 outro, 8 other.
fn section_code(s: Option<&str>) -> f64 {
    match s {
        None => 0.0,
        Some("intro") => 1.0,
        Some("verse") => 2.0,
        Some("build") => 3.0,
        Some("drop") => 4.0,
        Some("chorus") => 5.0,
        Some("breakdown" | "break") => 6.0,
        Some("outro") => 7.0,
        Some(_) => 8.0,
    }
}

/// What preset code reads by name (the projectM patch's wo_*): everything the show knows that a
/// picture could want, 0..1 unless said (docs/milk-presets.md).
pub fn vars_of(st: &ShowState) -> Vec<(&'static str, f64)> {
    let f = st.flat();
    let g = |k: &str, d: f64| f.get(k).copied().unwrap_or(d);
    let m = st.master();
    let a = &m.audio;
    vec![
        ("wo_beat", m.beat_phase),
        ("wo_bar", m.bar_phase),
        ("wo_phrase", m.phrase_phase),
        ("wo_beat_in_bar", m.beat_in_bar.unwrap_or(0) as f64),
        ("wo_bar_index", m.bar_index.unwrap_or(0) as f64),
        ("wo_bpm", m.bpm.unwrap_or(0.0)),
        ("wo_playing", if m.playing { 1.0 } else { 0.0 }),
        ("wo_kick", a.kick),
        ("wo_onset", a.onset),
        ("wo_sub", a.sub),
        ("wo_low", a.low),
        ("wo_mid", a.mid),
        ("wo_high", a.high),
        ("wo_air", a.air),
        ("wo_drums", a.drums),
        ("wo_vocals", a.vocals),
        ("wo_hit_kick", g("dyn.hit.kick", 0.0)),
        ("wo_hit_snare", g("dyn.hit.snare", 0.0)),
        ("wo_hit_top", g("dyn.hit.top", 0.0)),
        ("wo_beat_decay", g("dyn.beat.decay", 0.0)),
        ("wo_bar_decay", g("dyn.bar.decay", 0.0)),
        ("wo_downbeat", g("dyn.downbeat", 0.0)),
        ("wo_exposure", g("dyn.exposure", 0.7)),
        ("wo_loud", g("dyn.loud", 0.0)),
        ("wo_band_low", g("dyn.band.low", 0.0)),
        ("wo_band_mid", g("dyn.band.mid", 0.0)),
        ("wo_band_high", g("dyn.band.high", 0.0)),
        ("wo_energy", m.energy),
        ("wo_build", m.build_k),
        ("wo_drop", g("master.drop.near", 0.0)),
        ("wo_drop_beats", m.drop_beats_away.unwrap_or(999.0)),
        ("wo_breakdown", if m.breakdown { 1.0 } else { 0.0 }),
        ("wo_section", section_code(m.section.as_deref())),
        ("wo_section_k", m.section_k),
        ("wo_vocal", m.vocal),
        ("wo_hook", if m.hook { 1.0 } else { 0.0 }),
        ("wo_hit", st.macros.hit),
        ("wo_intensity", st.macros.intensity),
        ("wo_hue", st.palette.primary.h / 360.0),
        ("wo_hue2", st.palette.secondary.h / 360.0),
        ("wo_hue3", st.palette.accent.h / 360.0),
        ("wo_mix", if st.mix.on { st.mix.k } else { 0.0 }),
        ("wo_level_a", st.a.channel.level * if st.a.playing || st.a.track_id.is_some() { 1.0 } else { 0.0 }),
        ("wo_level_b", st.b.channel.level * if st.b.playing || st.b.track_id.is_some() { 1.0 } else { 0.0 }),
        ("wo_cam_motion", g("cam.motion", 0.0)),
        ("wo_cam_x", g("cam.x", 0.5)),
        ("wo_cam_y", g("cam.y", 0.5)),
    ]
}

/// MilkDrop's bass/mid/treb from the show's own hits and bands rather than its FFT: 1 is its
/// "average", a hit lands at 2 to 3; and their slow followers (eased over a sixth of a second),
/// kept in `att`.
pub fn levels(st: &ShowState, att: &mut [f64; 3]) -> [f64; 6] {
    let f = st.flat();
    let g = |k: &str| f.get(k).copied().unwrap_or(0.0);
    let lv = [
        0.55 + g("dyn.band.low") + 1.7 * g("dyn.hit.kick"),
        0.55 + g("dyn.band.mid") + 1.5 * g("dyn.hit.snare"),
        0.55 + g("dyn.band.high") + 1.5 * g("dyn.hit.top"),
    ];
    for i in 0..3 {
        att[i] += (lv[i] - att[i]) * 0.12;
    }
    [lv[0], lv[1], lv[2], att[0], att[1], att[2]]
}

/// When an accent lands.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum MilkLand {
    Kick,
    Snare,
    Off,
    Bar,
    TwoBars,
}

/// What it does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum MilkMove {
    Push,
    Pull,
    Turn,
    Warp,
    Flash,
}

/// MilkDrop's accents (v1: milk_accent.dart): what the show adds to whatever preset is on, so
/// the shipped presets — which know only the levels — move with the record: the preset's own
/// motion made bigger on the landing a phrase dealt (the kick, the snare, off the beat, the
/// bar, every other bar), in through a build, a burst on the drop. Small numbers: MilkDrop
/// feeds each frame into the next.
pub struct MilkAccent {
    phrase: i64,
    pub land: MilkLand,
    pub moves: Vec<MilkMove>,
    w: f64,
    push: f64,
    drop_at: Option<f64>,
    away_was: Option<f64>,
}

impl Default for MilkAccent {
    fn default() -> Self {
        MilkAccent { phrase: -1, land: MilkLand::Bar, moves: vec![MilkMove::Push], w: 0.0, push: 0.0, drop_at: None, away_was: None }
    }
}

impl MilkAccent {
    pub const NAMES: [&'static str; 6] = ["wo_fx_amp", "wo_fx_zoom", "wo_fx_rot", "wo_fx_warp", "wo_fx_decay", "wo_fx_flash"];
    /// How much a preset nobody measured moves with the music by itself.
    pub const UNKNOWN_REACT: f64 = 0.4;

    /// All off: the preset as its author made it.
    pub fn none() -> [(&'static str, f64); 6] {
        Self::NAMES.map(|n| (n, 0.0))
    }

    fn out(amp: f64, zoom: f64, rot: f64, warp: f64, flash: f64) -> [(&'static str, f64); 6] {
        [("wo_fx_amp", amp), ("wo_fx_zoom", zoom), ("wo_fx_rot", rot), ("wo_fx_warp", warp), ("wo_fx_decay", 0.0), ("wo_fx_flash", flash)]
    }

    fn pick<T: Copy>(w: &[(T, f64)], d: f64) -> T {
        let total: f64 = w.iter().map(|(_, x)| x.max(0.0)).sum();
        let mut at = d * total;
        for (k, x) in w {
            let x = x.max(0.0);
            if at < x {
                return *k;
            }
            at -= x;
        }
        w.last().unwrap().0
    }

    /// 0..1 from three numbers, the same every time.
    fn hash(a: i64, b: i64, c: i64) -> f64 {
        let mut h: u32 = 0x811c_9dc5;
        for x in [a, b, c] {
            h = (h ^ (x as u32)).wrapping_mul(0x0100_0193);
            h ^= h >> 13;
        }
        (h & 0xff_ffff) as f64 / 0x100_0000 as f64
    }

    /// The accents for this frame of `m`: `react` how much the preset on moves by itself
    /// (None: not known), `salt` the record's.
    pub fn frame(&mut self, m: &ShowDeck, dt: f64, react: Option<f64>, salt: i64) -> [(&'static str, f64); 6] {
        let playing = m.playing && m.beat_index.is_some();
        let dr = if playing { drive(m) } else { 0.0 };
        let r = react.unwrap_or(Self::UNKNOWN_REACT).clamp(0.0, 1.0);
        self.w += (dr * (1.0 - 0.9 * r) - self.w) * (dt * 1.5).min(1.0);
        if !playing {
            self.drop_at = None;
            self.push = 0.0;
            return if self.w < 0.005 { Self::none() } else { Self::out(0.0, 0.0, 0.0, 0.0, 0.0) };
        }
        let bi = m.beat_index.unwrap();
        let beats = bi as f64 + m.beat_phase;
        let phrase = (beats / 16.0).floor() as i64;
        if phrase != self.phrase {
            self.phrase = phrase;
            let (d1, d2, d3) = (Self::hash(salt, phrase, 7), Self::hash(salt, phrase, 11), Self::hash(salt, phrase, 13));
            self.land = Self::pick(
                &[
                    (MilkLand::Kick, 0.3 + 3.0 * dr * dr),
                    (MilkLand::Off, 0.2 + 1.2 * dr),
                    (MilkLand::Snare, 0.5 + 1.0 * dr),
                    (MilkLand::Bar, 2.5 - 1.5 * dr),
                    (MilkLand::TwoBars, 1.6 - 1.2 * dr),
                ],
                d1,
            );
            let w = [(MilkMove::Push, 1.0), (MilkMove::Pull, 0.6), (MilkMove::Turn, 1.0), (MilkMove::Warp, 0.8), (MilkMove::Flash, 0.5)];
            let first = Self::pick(&w, d2);
            let rest: Vec<(MilkMove, f64)> = w.iter().copied().filter(|(k, _)| *k != first).collect();
            let second = Self::pick(&rest, d3);
            self.moves = if dr > 0.6 && d3 > 0.35 { vec![first, second] } else { vec![first] };
        }
        let ph = m.beat_phase;
        let in_bar = m.beat_in_bar.unwrap_or(bi.rem_euclid(4)) as f64 + ph;
        let bar = m.bar_index.unwrap_or(bi.div_euclid(4));
        let even = |x: i64| x.rem_euclid(2) == 0;
        let side = |b: bool| if b { 1.0 } else { -1.0 };
        let (e, s) = match self.land {
            MilkLand::Kick => ((-ph * 7.0).exp(), side(even(bi))),
            MilkLand::Off => ((-((ph + 0.5) % 1.0) * 7.0).exp(), side(even(bi))),
            MilkLand::Snare => (if m.beat_in_bar.unwrap_or(bi).rem_euclid(2) == 1 { (-ph * 6.0).exp() } else { 0.0 }, side(even(bi.div_euclid(2)))),
            MilkLand::Bar => ((-in_bar * 2.2).exp(), side(even(bar))),
            MilkLand::TwoBars => (if even(bar) { (-in_bar * 1.2).exp() } else { (-(in_bar + 4.0) * 1.2).exp() }, side(even(bar.div_euclid(2)))),
        };
        // the build: in, faster as it climbs; let go of on the drop
        let away = m.drop_beats_away;
        if let Some(a) = away
            && a <= 0.0
            && a > -2.5
            && self.away_was.is_none_or(|w| w > 0.0)
        {
            self.drop_at = Some(beats + a);
        }
        self.away_was = away;
        if self.drop_at.is_some_and(|d| beats - d > 16.0 || beats < d - 1.0) {
            self.drop_at = None;
        }
        let burst = self.drop_at.map_or(0.0, |d| (-(beats - d) / 1.5).exp());
        let building = !m.breakdown && (m.section.as_deref() == Some("build") || away.is_some_and(|a| a > 0.0 && a < 32.0));
        let want = if building { m.build_k.clamp(0.0, 1.0).powf(1.5) } else { 0.0 };
        self.push = if burst > 0.3 { 0.0 } else { self.push + (want - self.push) * (dt * if want > self.push { 1.0 } else { 4.0 }).min(1.0) };
        let shape = 1.0 - 0.5 * r;
        let w = self.w;
        let (mut zoom, mut rot, mut warp, mut flash) = (0.0, 0.0, 0.0, 0.0);
        for mv in &self.moves {
            match mv {
                MilkMove::Push => zoom += 0.03 * w * e,
                MilkMove::Pull => zoom -= 0.025 * w * e,
                MilkMove::Turn => rot += 0.05 * s * w * e,
                MilkMove::Warp => warp += 1.6 * w * e,
                MilkMove::Flash => flash += 0.25 * w * e,
            }
        }
        zoom += shape * (0.02 * self.push + 0.08 * burst);
        flash += shape * 0.35 * burst;
        rot += shape * 0.25 * burst * if even(self.phrase) { 1.0 } else { -1.0 };
        let amp = w * (0.3 + 0.9 * e) + shape * (0.4 * self.push + 0.6 * burst);
        Self::out(amp, zoom, rot, warp, flash)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::deck::Channel;

    // ---- the library (v1's milk_test.dart)

    #[test]
    fn a_preset_is_named_by_the_convention() {
        let p = MilkPreset::of("/x/Geiss - Cosmic Dust 2.milk", "shipped", 3.0);
        assert_eq!((p.author.as_str(), p.name.as_str(), p.full_name().as_str()), ("Geiss", "Cosmic Dust 2", "Geiss - Cosmic Dust 2"));
        let q = MilkPreset::of("/x/plain.milk", "mine", 3.0);
        assert_eq!((q.author.as_str(), q.name.as_str(), q.full_name().as_str()), ("", "plain", "plain"));
        let w = MilkPreset::of(r"C:\m\Flexi - a b.milk", "shipped", 3.0);
        assert_eq!(w.full_name(), "Flexi - a b");
        assert_eq!(rating_of("[preset00]\nfRating=4.500000\nfGammaAdj=2"), 4.5);
        assert_eq!(rating_of("[preset00]\nfGammaAdj=2"), 3.0);
    }

    fn three() -> MilkLibrary {
        MilkLibrary::new(["A - one", "B - two", "C - three"].iter().map(|n| MilkPreset::of(&format!("/x/{n}.milk"), "shipped", 4.0)).collect(), MilkNotes::default())
    }

    #[test]
    fn a_preset_switched_off_is_never_in_the_pool_but_still_listed() {
        let mut lib = three();
        let two = lib.by_name("B - two").unwrap().clone();
        lib.toggle_off(&two);
        assert!(lib.is_off(&two));
        let names = |v: Vec<&MilkPreset>| v.iter().map(|p| p.name.clone()).collect::<Vec<_>>();
        assert_eq!(names(lib.pool(false, 0.0)), ["one", "three"]);
        assert_eq!(names(lib.pool(true, 0.0)), ["one", "three"]);
        lib.toggle_favourite(&two);
        assert_eq!(names(lib.pool(true, 0.0)), ["one", "three"], "a favourite switched off is still off");
        assert_eq!(lib.search("", false, 0.0, false, false).len(), 3);
        assert_eq!(names(lib.search("", false, 0.0, false, true)), ["one", "three"]);
        assert_eq!(names(lib.search("", false, 0.0, true, false)), ["two"]);
    }

    #[test]
    fn all_of_them_off_is_none_off() {
        let mut lib = three();
        for p in lib.presets.clone() {
            lib.toggle_off(&p);
        }
        assert_eq!(lib.pool(false, 0.0).len(), 3);
    }

    #[test]
    fn the_notes_read_and_write_as_v1_keeps_them() {
        let text = r#"{"favourites":["A - one"],"off":["B - two"],"recent":["/x/C - three.milk"],"imported":{"pack":"/p"},"skips":{"A - one":2}}"#;
        let n = MilkNotes::parse(text);
        assert_eq!(n.skips, vec![("A - one".to_owned(), 2)]);
        assert_eq!(MilkNotes::parse(&n.to_json().to_string()), n);
        let lib = MilkLibrary::new(three().presets, n);
        assert_eq!(lib.last().unwrap().name, "three");
        assert!((lib.skip_lean(lib.by_name("A - one").unwrap()) - 1.0 / 3.0).abs() < 1e-9);
    }

    // ---- the vars (v1's milk_test.dart: the show, by name)

    #[test]
    fn the_numbers_a_preset_reads() {
        let a = ShowDeck {
            name: "A".into(),
            track_id: Some(1),
            playing: true,
            bpm: Some(132.0),
            beat_phase: 0.25,
            bar_phase: 0.5,
            bar_index: Some(17),
            beat_in_bar: Some(2),
            section: Some("drop".into()),
            energy: 0.8,
            drop_beats_away: Some(0.0),
            channel: Channel { level: 1.0, ..Default::default() },
            ..Default::default()
        };
        let st = ShowState { a, ..Default::default() };
        let v: BTreeMap<&str, f64> = vars_of(&st).into_iter().collect();
        assert_eq!(v["wo_beat"], 0.25);
        assert_eq!(v["wo_bar"], 0.5);
        assert_eq!(v["wo_bar_index"], 17.0);
        assert_eq!(v["wo_beat_in_bar"], 2.0);
        assert_eq!(v["wo_bpm"], 132.0);
        assert_eq!(v["wo_playing"], 1.0);
        assert_eq!(v["wo_section"], 4.0, "a drop");
        assert_eq!(v["wo_drop"], 1.0, "landing now");
        assert_eq!(v["wo_energy"], 0.8);
        assert_eq!(v["wo_level_a"], 1.0);
        assert_eq!(v["wo_level_b"], 0.0);
        assert!(v.keys().all(|k| k.starts_with("wo_")) && v.values().all(|x| x.is_finite()));
    }

    // ---- the accents (v1's milk_accent_test.dart)

    fn at(beats: f64, section: &str, energy: f64, build_k: f64, drop_away: Option<f64>) -> ShowDeck {
        let i = beats.floor() as i64;
        ShowDeck {
            name: "A".into(),
            playing: true,
            track_id: Some(7),
            bpm: Some(128.0),
            section: Some(section.into()),
            energy,
            channel: Channel { level: 1.0, ..Default::default() },
            build_k,
            beat_index: Some(i),
            beat_phase: beats - i as f64,
            beat_in_bar: Some(i % 4),
            bar_index: Some(i / 4),
            drop_beats_away: drop_away,
            ..Default::default()
        }
    }

    fn play(a: &mut MilkAccent, from: f64, to: f64, section: &str, react: Option<f64>, energy: f64) -> Vec<BTreeMap<&'static str, f64>> {
        let dt = 1.0 / 60.0;
        let per = 128.0 / 60.0 * dt;
        let mut out = vec![];
        let mut b = from;
        while b < to {
            out.push(a.frame(&at(b, section, energy, 0.0, None), dt, react, 7).into_iter().collect());
            b += per;
        }
        out
    }

    fn most(fx: &[BTreeMap<&str, f64>], k: &str) -> f64 {
        fx.iter().map(|x| x[k].abs()).fold(0.0, f64::max)
    }

    #[test]
    fn a_quiet_part_leaves_the_preset_as_it_is() {
        let fx = play(&mut MilkAccent::default(), 0.0, 32.0, "intro", None, 0.2);
        for k in MilkAccent::NAMES {
            assert!(most(&fx[60..], k) < 0.01, "{k}");
        }
    }

    #[test]
    fn a_drop_moves_it_on_the_beat() {
        let fx = play(&mut MilkAccent::default(), 0.0, 64.0, "drop", None, 0.9);
        assert!(most(&fx[120..], "wo_fx_amp") > 0.5);
        let amps: Vec<f64> = fx[120..].iter().map(|x| x["wo_fx_amp"]).collect();
        let (lo, hi) = amps.iter().fold((f64::MAX, f64::MIN), |(l, h), &a| (l.min(a), h.max(a)));
        assert!(hi - lo > 0.4);
    }

    #[test]
    fn a_preset_that_moves_by_itself_gets_less() {
        let deaf = most(&play(&mut MilkAccent::default(), 0.0, 32.0, "drop", Some(0.0), 0.9)[120..], "wo_fx_amp");
        let lively = most(&play(&mut MilkAccent::default(), 0.0, 32.0, "drop", Some(1.0), 0.9)[120..], "wo_fx_amp");
        assert!(lively < deaf * 0.25, "{lively} vs {deaf}");
    }

    #[test]
    fn the_phrases_deal_different_landings_and_moves() {
        let mut a = MilkAccent::default();
        let (mut lands, mut moves) = (BTreeSet::new(), BTreeSet::new());
        for phrase in 0..24 {
            a.frame(&at(phrase as f64 * 16.0 + 0.5, if phrase % 2 == 0 { "drop" } else { "chorus" }, 0.9, 0.0, None), 1.0 / 60.0, None, 7);
            lands.insert(a.land);
            moves.extend(a.moves.iter().copied());
        }
        assert!(lands.len() >= 3, "{lands:?}");
        assert!(moves.len() >= 4, "{moves:?}");
    }

    #[test]
    fn a_build_pushes_in_and_the_drop_bursts() {
        let mut a = MilkAccent::default();
        let dt = 1.0 / 60.0;
        let per = 128.0 / 60.0 * dt;
        let zoom = |a: &mut MilkAccent, d: ShowDeck| a.frame(&d, dt, Some(0.0), 7)[1].1;
        let (mut z, mut b) = (0.0, 0.0);
        while b < 32.0 {
            z = zoom(&mut a, at(b, "build", 0.6, b / 32.0, Some(32.0 - b)));
            b += per;
        }
        assert!(z > 0.01, "{z}");
        let mut burst = 0.0;
        let mut b = 32.0;
        while b < 33.0 {
            burst = zoom(&mut a, at(b, "drop", 0.9, 0.0, Some(32.0 - b)));
            b += per;
        }
        assert!(burst > 0.03, "{burst}");
    }

    // ---- the director

    fn lib(n: usize) -> MilkLibrary {
        MilkLibrary::new((0..n).map(|i| MilkPreset::of(&format!("/x/P - {i:02}.milk"), "shipped", 4.0)).collect(), MilkNotes::default())
    }

    fn ev(kind: EventKind) -> ShowEvent {
        ShowEvent::on_master(kind)
    }

    #[test]
    fn the_director_starts_on_the_last_one_and_cuts_on_a_drop() {
        let mut l = lib(20);
        let last = l.presets[7].clone();
        l.note_used(&last);
        let mut d = MilkDirector::new(l, None, 3);
        let st = ShowState::default();
        d.frame(&st, &[], false);
        assert_eq!(d.cue().path.as_deref(), Some(last.path.as_str()), "the last one on");
        let n = d.cue().n;
        d.frame(&st, &[ev(EventKind::Drop)], false);
        assert_eq!(d.cue().n, n + 1);
        assert_ne!(d.cue().path.as_deref(), Some(last.path.as_str()));
        assert!(!d.cue().soft, "a drop cuts");
        // a breakdown blends
        d.frame(&st, &[ev(EventKind::Breakdown)], false);
        assert!(d.cue().soft && d.cue().blend >= 1.0);
    }

    #[test]
    fn on_the_milk_scene_a_drop_moshes_more_often_than_not_and_the_preset_follows() {
        let mut d = MilkDirector::new(lib(20), None, 5);
        let st = ShowState::default();
        d.frame(&st, &[], true);
        let mut moshed = 0;
        for _ in 0..40 {
            let before = d.moshes;
            d.frame(&st, &[ev(EventKind::Drop)], true);
            if d.moshes > before {
                moshed += 1;
                let n = d.cue().n;
                d.frame(&st, &[], true);
                d.frame(&st, &[], true);
                assert_eq!(d.cue().n, n + 1, "the new preset two ticks after the mosh");
            }
        }
        assert!((14..=34).contains(&moshed), "{moshed} of 40");
    }

    #[test]
    fn the_hands_hold_a_preset_lock_it_and_a_crash_moves_on() {
        let mut d = MilkDirector::new(lib(20), None, 9);
        let st = ShowState::default();
        d.frame(&st, &[], false);
        let pick = d.library.presets[3].clone();
        d.choose(&pick);
        d.frame(&st, &[ev(EventKind::Breakdown)], false);
        assert_eq!(d.cue().path.as_deref(), Some(pick.path.as_str()), "held through a breakdown");
        d.frame(&st, &[ev(EventKind::Drop)], false);
        assert_ne!(d.cue().path.as_deref(), Some(pick.path.as_str()), "a drop moves on");
        d.lock(true);
        let on = d.cue().clone();
        d.frame(&st, &[ev(EventKind::Drop)], false);
        assert_eq!(d.cue().path, on.path, "locked");
        assert!(d.cue().lock);
        d.lock(false);
        let on = d.cue().path.clone().unwrap();
        d.crashed_on(&on);
        assert_ne!(d.cue().path.as_deref(), Some(on.as_str()));
        for _ in 0..50 {
            d.frame(&st, &[ev(EventKind::Hit)], false);
            assert_ne!(d.cue().path.as_deref(), Some(on.as_str()), "never again this run");
        }
        // next and previous step through the list
        let a = d.cue().path.clone();
        d.next();
        d.previous();
        assert_eq!(d.cue().path, a);
    }

    #[test]
    fn next_soon_after_the_directors_pick_is_a_skip() {
        let mut d = MilkDirector::new(lib(5), None, 2);
        let st = ShowState::default();
        d.frame(&st, &[], false);
        d.random(false, false, None);
        let mine = d.preset().unwrap().clone();
        d.random(false, true, None);
        assert!(d.library.skip_lean(&mine) < 1.0, "skipped");
        assert!(d.library.dirty);
    }
}
