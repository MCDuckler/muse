//! The board (v1's soundboard): four banks of sixteen pads, each a short sound and how it
//! is played — once, while held, on and off, round and round — on the engine's own pad
//! voices, over the master's level and its limiter.
//!
//! The document is v1's `board.json` as it is (the house's `/booth/board` keeps it, the
//! same one the phone and the old booth show): the Desk keeps its own copy beside its
//! other files, starts from the WetOwl app's when it has none, and takes the house's when
//! it is newer. Sounds are the house's samples (the shelf everyone has, and the account's
//! own), fetched once and kept; negative ids are the kit, rendered here.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use wo_booth::steps::FxSound;
use wo_engine::{Channels, Engine, Source};

/// Pads to a bank, banks to the board.
pub const PADS: usize = 16;
pub const BANKS: usize = 4;
/// The engine's voice kept for hearing a sound before it goes on a pad.
const AUDITION: usize = wo_engine::PADS - 1;
/// Voices the pads take turns on.
const VOICES: usize = wo_engine::PADS - 1;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    /// Plays to its end; pressed again, from the start.
    #[default]
    OneShot,
    /// Plays while held.
    Hold,
    /// Pressed on, pressed off.
    Toggle,
    /// A toggle that goes round.
    Loop,
}

impl Mode {
    pub const ALL: [Mode; 4] = [Mode::OneShot, Mode::Hold, Mode::Toggle, Mode::Loop];
    pub fn word(self) -> &'static str {
        match self {
            Mode::OneShot => "once",
            Mode::Hold => "hold",
            Mode::Toggle => "toggle",
            Mode::Loop => "loop",
        }
    }
}

/// When a pressed pad starts: at once, or on the master's next beat or bar.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Quantise {
    #[default]
    Off,
    Beat,
    Bar,
}

impl Quantise {
    pub const ALL: [Quantise; 3] = [Quantise::Off, Quantise::Beat, Quantise::Bar];
    pub fn word(self) -> &'static str {
        match self {
            Quantise::Off => "now",
            Quantise::Beat => "beat",
            Quantise::Bar => "bar",
        }
    }
}

/// A pad's colour, by name (v1's: `a` and `b` are the decks' own).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Colour {
    A,
    B,
    Accent,
    Teal,
    Violet,
    Orange,
    #[default]
    White,
    Grey,
}

impl Colour {
    pub const ALL: [Colour; 8] = [Colour::A, Colour::B, Colour::Accent, Colour::Teal, Colour::Violet, Colour::Orange, Colour::White, Colour::Grey];
}

/// A value v1 would not know read as its default (v1's `parse`s fall back the same way).
fn lenient<'de, D: serde::Deserializer<'de>, T: serde::de::DeserializeOwned + Default>(d: D) -> Result<T, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    Ok(serde_json::from_value(v).unwrap_or_default())
}

fn one() -> f32 {
    1.0
}

/// One pad: its sound and how it is played (v1's PadSpec, field for field).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Pad {
    /// The house's sample id (negative: the kit's).
    pub sample: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default, deserialize_with = "lenient")]
    pub colour: Colour,
    #[serde(default, deserialize_with = "lenient")]
    pub mode: Mode,
    /// 0..1.5, 1 the sound as it is.
    #[serde(default = "one")]
    pub gain: f32,
    /// 0: none; 1..4: pressing this pad stops the group's others.
    #[serde(default)]
    pub choke: u8,
    #[serde(default, deserialize_with = "lenient")]
    pub quantise: Quantise,
    /// 0..1: how far the decks dip while it sounds (1: half way down).
    #[serde(default)]
    pub duck: f32,
    #[serde(default)]
    pub in_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
}

impl Pad {
    pub fn new(sample: i64, name: &str) -> Pad {
        Pad { sample, name: short(name), colour: Colour::White, mode: Mode::OneShot, gain: 1.0, choke: 0, quantise: Quantise::Off, duck: 0.0, in_ms: 0, out_ms: None, key: None }
    }
}

/// A pad's words from a sound's name: short, upper case (v1's).
fn short(name: &str) -> String {
    name.split(['·', '(', '[']).next().unwrap_or(name).trim().to_uppercase().chars().take(18).collect()
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Bank {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub pads: Vec<Option<Pad>>,
}

fn level() -> f32 {
    0.8
}

/// The whole board (v1's BoardDoc).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Doc {
    #[serde(default)]
    pub rev: i64,
    /// The house's revision this copy came from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_rev: Option<i64>,
    /// The board's own fader, 0..1.
    #[serde(default = "level")]
    pub level: f32,
    /// The row v1 pinned under its decks (kept for it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub strip: Option<serde_json::Value>,
    #[serde(default)]
    pub banks: Vec<Bank>,
}

impl Default for Doc {
    fn default() -> Self {
        Doc { rev: 0, server_rev: None, level: level(), strip: None, banks: Vec::new() }.whole()
    }
}

impl Doc {
    /// Four banks of sixteen, whatever was read.
    fn whole(mut self) -> Doc {
        self.banks.truncate(BANKS);
        while self.banks.len() < BANKS {
            self.banks.push(Bank { name: ["A", "B", "C", "D"][self.banks.len()].into(), pads: Vec::new() });
        }
        for b in &mut self.banks {
            b.pads.resize(PADS, None);
        }
        self.level = self.level.clamp(0.0, 1.0);
        for p in self.banks.iter_mut().flat_map(|b| b.pads.iter_mut().flatten()) {
            p.gain = p.gain.clamp(0.0, 1.5);
            p.choke = p.choke.min(4);
            p.duck = p.duck.clamp(0.0, 1.0);
        }
        self
    }

    fn read(v: serde_json::Value) -> Option<Doc> {
        serde_json::from_value::<Doc>(v).ok().map(Doc::whole)
    }

    pub fn pad(&self, bank: usize, pad: usize) -> Option<&Pad> {
        self.banks.get(bank)?.pads.get(pad)?.as_ref()
    }

    fn samples(&self) -> impl Iterator<Item = i64> + '_ {
        self.banks.iter().flat_map(|b| b.pads.iter().flatten().map(|p| p.sample))
    }
}

/// A sound as the board holds it.
enum Sound {
    Fetching,
    Ready { source: Source, seconds: f64 },
    Failed(String),
}

/// A voice playing a pad.
#[derive(Clone, Copy)]
struct Voice {
    bank: usize,
    pad: usize,
    /// Where in the sound it plays, seconds.
    from: f64,
    to: f64,
    duck: f32,
    choke: u8,
    /// Pressed this many presses ago (the oldest voice goes first).
    turn: u64,
}

enum Back {
    Pcm(i64, Result<Vec<i16>, String>),
    House(Result<(Option<serde_json::Value>, i64), String>),
    Saved(Result<Result<i64, (serde_json::Value, i64)>, String>),
    Shelf(Result<Vec<wo_house::SampleRow>, String>),
}

/// What the screen shows of one pad.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PadView {
    pub pad: Option<Pad>,
    /// Sounding: how far through, 0..1 (or waiting for its beat: 0).
    pub lit: Option<f32>,
    pub ready: bool,
    pub failed: Option<String>,
}

/// What the screen shows of the board.
#[derive(Clone, Debug, Default)]
pub struct View {
    pub bank: usize,
    pub banks: Vec<String>,
    pub pads: Vec<PadView>,
    pub level: f32,
    /// Something to say (the house unreachable, a sound that would not play).
    pub said: Option<String>,
    pub sounding: usize,
}

/// The board, alive.
pub struct Board {
    doc: Doc,
    bank: usize,
    sounds: HashMap<i64, Sound>,
    voices: [Option<Voice>; VOICES],
    turn: u64,
    /// The sound asked for on the audition voice, until it is fetched.
    audition: Option<i64>,
    house: Option<wo_house::House>,
    tx: mpsc::Sender<Back>,
    rx: mpsc::Receiver<Back>,
    /// Changed and not yet written (the file, the house): since when.
    dirty: Option<Instant>,
    saving: bool,
    /// The house's shelf and the account's own sounds, once asked for.
    pub shelf: Option<Result<Vec<wo_house::SampleRow>, String>>,
    shelf_asked: bool,
    said: Option<(String, Instant)>,
    file: Option<PathBuf>,
    /// The decks' dip, as last given.
    pub duck: f32,
}

impl Board {
    pub fn open() -> Board {
        let file = wo_house::folders::config().map(|d| d.join("wetowl-desk").join("board.json"));
        // the Desk's own, else the WetOwl app's
        let from = |p: Option<PathBuf>| p.and_then(|p| std::fs::read(p).ok()).and_then(|b| serde_json::from_slice(&b).ok()).and_then(Doc::read);
        let doc = from(file.clone()).or_else(|| from(wo_house::app_folder().map(|a| a.join("board.json")))).unwrap_or_default();
        Board::with(doc, file)
    }

    /// One of `doc`, kept at `file` (None: in memory, for tests).
    pub fn with(doc: Doc, file: Option<PathBuf>) -> Board {
        let (tx, rx) = mpsc::channel();
        let mut b = Board {
            doc: doc.whole(),
            bank: 0,
            sounds: HashMap::new(),
            voices: [None; VOICES],
            turn: 0,
            audition: None,
            house: None,
            tx,
            rx,
            dirty: None,
            saving: false,
            shelf: None,
            shelf_asked: false,
            said: None,
            file,
            duck: 0.0,
        };
        b.fetch_all();
        b
    }

    pub fn doc(&self) -> &Doc {
        &self.doc
    }

    /// Signed in: the house's board (when newer), the sounds not here yet.
    pub fn signed_in(&mut self, house: wo_house::House) {
        let h = house.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let _ = tx.send(Back::House(h.board().map_err(|e| e.to_string())));
        });
        self.house = Some(house);
        self.shelf_asked = false;
        // what failed for want of the house, again
        self.sounds.retain(|_, s| !matches!(s, Sound::Failed(_)));
        self.fetch_all();
    }

    fn say(&mut self, words: impl Into<String>) {
        let w = words.into();
        eprintln!("board: {w}");
        self.said = Some((w, Instant::now()));
    }

    fn fetch_all(&mut self) {
        let ids: Vec<i64> = self.doc.samples().collect();
        for id in ids {
            self.fetch(id);
        }
    }

    /// Brings sound `id` here and decodes it, on a worker.
    fn fetch(&mut self, id: i64) {
        if self.sounds.contains_key(&id) {
            return;
        }
        self.sounds.insert(id, Sound::Fetching);
        let tx = self.tx.clone();
        let house = self.house.clone();
        std::thread::spawn(move || {
            let _ = tx.send(Back::Pcm(id, pcm_of(id, house.as_ref())));
        });
    }

    /// The house's answers, the sounds decoded; the decks' dip as the pads sound; the
    /// board written a second after it changed.
    pub fn tick(&mut self, engine: &Engine) {
        while let Ok(back) = self.rx.try_recv() {
            match back {
                Back::Pcm(id, Ok(pcm)) if !pcm.is_empty() => {
                    let Ok(mut source) = engine.new_source(Channels::Stereo, (pcm.len() / 2) as i64) else { continue };
                    if source.append(&pcm).is_err() {
                        continue;
                    }
                    source.finish();
                    let seconds = pcm.len() as f64 / 2.0 / crate::RATE as f64;
                    self.sounds.insert(id, Sound::Ready { source, seconds });
                    if self.audition == Some(id) {
                        self.audition = None;
                        self.audition_now(engine, id);
                    }
                }
                Back::Pcm(id, r) => {
                    let e = r.err().unwrap_or_else(|| "silent".into());
                    if self.house.is_some() || id < 0 {
                        self.say(format!("sound {id}: {e}"));
                    }
                    self.sounds.insert(id, Sound::Failed(e));
                }
                Back::House(Ok((Some(v), rev))) => {
                    let newer = self.doc.server_rev.is_none_or(|r| rev > r);
                    if newer && self.dirty.is_none() {
                        if let Some(mut d) = Doc::read(v) {
                            d.server_rev = Some(rev);
                            self.doc = d;
                            self.write_file();
                            self.fetch_all();
                        }
                    } else if self.dirty.is_none() && self.doc.server_rev != Some(rev) {
                        // ours is ahead of the house (changed while away): it goes up
                        self.dirty = Some(Instant::now());
                    }
                }
                Back::House(Ok((None, _))) => {
                    // the house has none: ours goes up
                    if self.doc.samples().next().is_some() {
                        self.dirty = Some(Instant::now());
                    }
                }
                Back::House(Err(e)) => self.say(format!("the house's board: {e}")),
                Back::Saved(r) => {
                    self.saving = false;
                    match r {
                        Ok(Ok(rev)) => {
                            self.doc.server_rev = Some(rev);
                            self.write_file();
                        }
                        Ok(Err((v, rev))) => {
                            // changed elsewhere meanwhile: theirs, as v1 does it
                            if let Some(mut d) = Doc::read(v) {
                                d.server_rev = Some(rev);
                                self.doc = d;
                                self.write_file();
                                self.fetch_all();
                                self.say("the board was changed elsewhere: took that one");
                            }
                        }
                        Err(e) => self.say(format!("board not saved to the house: {e}")),
                    }
                }
                Back::Shelf(r) => self.shelf = Some(r),
            }
        }
        // the voices ended let go of
        for v in 0..VOICES {
            if self.voices[v].is_some() && engine.pad_at(v).is_none() {
                self.voices[v] = None;
            }
        }
        self.duck = self.voices.iter().flatten().map(|v| v.duck).fold(0.0, f32::max);
        if self.dirty.is_some_and(|t| t.elapsed() > Duration::from_secs(1)) && !self.saving {
            self.dirty = None;
            self.doc.rev += 1;
            self.write_file();
            if let Some(h) = self.house.clone() {
                self.saving = true;
                let doc = serde_json::to_value(&self.doc).unwrap_or_default();
                let rev = self.doc.server_rev.unwrap_or(0);
                let tx = self.tx.clone();
                std::thread::spawn(move || {
                    let _ = tx.send(Back::Saved(h.put_board(&doc, rev).map_err(|e| e.to_string())));
                });
            }
        }
        if self.said.as_ref().is_some_and(|(_, t)| t.elapsed() > Duration::from_secs(8)) {
            self.said = None;
        }
    }

    fn write_file(&self) {
        let Some(f) = &self.file else { return };
        let Ok(bytes) = serde_json::to_vec_pretty(&self.doc) else { return };
        let _ = std::fs::create_dir_all(f.parent().unwrap());
        let part = f.with_extension("json.part");
        if std::fs::write(&part, bytes).is_ok() {
            let _ = std::fs::rename(&part, f);
        }
    }

    fn changed(&mut self) {
        self.dirty = Some(Instant::now());
    }

    fn voice_of(&self, bank: usize, pad: usize) -> Option<usize> {
        self.voices.iter().position(|v| v.is_some_and(|v| v.bank == bank && v.pad == pad))
    }

    /// Pad `pad` of bank `bank` pressed (`beat`: when the master's next beat and bar are
    /// heard, engine time, where it plays on a grid).
    pub fn press(&mut self, engine: &Engine, bank: usize, pad: usize, beat: Option<(f64, f64)>) {
        let Some(p) = self.doc.pad(bank, pad).cloned() else { return };
        let playing = self.voice_of(bank, pad);
        if matches!(p.mode, Mode::Toggle | Mode::Loop)
            && let Some(v) = playing
        {
            engine.pad_stop(v, 0.05);
            self.voices[v] = None;
            return;
        }
        let Some(Sound::Ready { source, seconds }) = self.sounds.get(&p.sample) else {
            match self.sounds.get(&p.sample) {
                Some(Sound::Failed(e)) => {
                    let e = e.clone();
                    self.say(format!("{}: {e}", p.name));
                }
                Some(_) => self.say(format!("{}: still fetching", p.name)),
                None => self.fetch(p.sample),
            }
            return;
        };
        // its choke group's others stop
        if p.choke > 0 {
            for v in 0..VOICES {
                if self.voices[v].is_some_and(|o| o.choke == p.choke && (o.bank, o.pad) != (bank, pad)) {
                    engine.pad_stop(v, 0.02);
                    self.voices[v] = None;
                }
            }
        }
        let from = (p.in_ms as f64 / 1000.0).clamp(0.0, *seconds);
        let to = p.out_ms.map_or(*seconds, |o| (o as f64 / 1000.0).clamp(from, *seconds));
        let at = match (p.quantise, beat) {
            (Quantise::Beat, Some((b, _))) => b,
            (Quantise::Bar, Some((_, bar))) => bar,
            _ => 0.0,
        };
        // its own voice again, else a free one, else the one pressed longest ago
        let v = playing
            .or_else(|| self.voices.iter().position(|v| v.is_none()))
            .unwrap_or_else(|| (0..VOICES).min_by_key(|&v| self.voices[v].map_or(0, |v| v.turn)).unwrap_or(0));
        self.turn += 1;
        engine.pad_play(v, source, at, from, if to >= *seconds { 0.0 } else { to }, p.mode == Mode::Loop, p.gain);
        self.voices[v] = Some(Voice { bank, pad, from, to, duck: p.duck, choke: p.choke, turn: self.turn });
    }

    /// Pad let go of: a held one stops.
    pub fn release(&mut self, engine: &Engine, bank: usize, pad: usize) {
        if self.doc.pad(bank, pad).is_some_and(|p| p.mode == Mode::Hold)
            && let Some(v) = self.voice_of(bank, pad)
        {
            engine.pad_stop(v, 0.03);
            self.voices[v] = None;
        }
    }

    /// Every pad quiet.
    pub fn stop_all(&mut self, engine: &Engine) {
        for v in 0..wo_engine::PADS {
            engine.pad_stop(v, 0.1);
        }
        self.voices = [None; VOICES];
        self.audition = None;
    }

    pub fn set_bank(&mut self, bank: usize) {
        self.bank = bank.min(BANKS - 1);
    }

    pub fn bank(&self) -> usize {
        self.bank
    }

    pub fn set_level(&mut self, engine: &Engine, level: f32) {
        self.doc.level = level.clamp(0.0, 1.0);
        self.apply_level(engine);
        self.changed();
    }

    /// The board's fader on the engine (squared: a fader's feel).
    pub fn apply_level(&self, engine: &Engine) {
        engine.pads_level(self.doc.level * self.doc.level / 0.64, 0.03);
    }

    /// A pad put (or taken off, None).
    pub fn set_pad(&mut self, engine: &Engine, bank: usize, pad: usize, p: Option<Pad>) {
        if bank >= BANKS || pad >= PADS {
            return;
        }
        if let Some(v) = self.voice_of(bank, pad) {
            engine.pad_stop(v, 0.03);
            self.voices[v] = None;
        }
        if let Some(p) = &p {
            self.fetch(p.sample);
        }
        self.doc.banks[bank].pads[pad] = p;
        self.changed();
    }

    /// The house's shelf and the account's own sounds, asked for once.
    pub fn want_shelf(&mut self) {
        if self.shelf_asked {
            return;
        }
        self.shelf_asked = true;
        let Some(h) = self.house.clone() else {
            self.shelf = Some(Err("not signed in to the house".into()));
            return;
        };
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let _ = tx.send(Back::Shelf(h.samples().map_err(|e| e.to_string())));
        });
    }

    /// Sound `id` heard before it goes on a pad (again: it stops).
    pub fn audition(&mut self, engine: &Engine, id: i64) {
        if engine.pad_at(AUDITION).is_some() {
            engine.pad_stop(AUDITION, 0.05);
            return;
        }
        match self.sounds.get(&id) {
            Some(Sound::Ready { .. }) => self.audition_now(engine, id),
            Some(Sound::Failed(_)) => {
                self.sounds.remove(&id);
                self.audition = Some(id);
                self.fetch(id);
            }
            _ => {
                self.audition = Some(id);
                self.fetch(id);
            }
        }
    }

    fn audition_now(&self, engine: &Engine, id: i64) {
        if let Some(Sound::Ready { source, .. }) = self.sounds.get(&id) {
            engine.pad_play(AUDITION, source, 0.0, 0.0, 0.0, false, 1.0);
        }
    }

    pub fn view(&self, engine: &Engine) -> View {
        let pads = (0..PADS)
            .map(|i| {
                let pad = self.doc.pad(self.bank, i).cloned();
                let lit = self.voice_of(self.bank, i).and_then(|v| {
                    let at = engine.pad_at(v)?;
                    let voice = self.voices[v]?;
                    Some((((at - voice.from) / (voice.to - voice.from).max(1e-3)) as f32).clamp(0.0, 1.0))
                });
                let (ready, failed) = match pad.as_ref().and_then(|p| self.sounds.get(&p.sample)) {
                    Some(Sound::Ready { .. }) => (true, None),
                    Some(Sound::Failed(e)) => (false, Some(e.clone())),
                    _ => (false, None),
                };
                PadView { pad, lit, ready, failed }
            })
            .collect();
        View {
            bank: self.bank,
            banks: self.doc.banks.iter().map(|b| b.name.clone()).collect(),
            pads,
            level: self.doc.level,
            said: self.said.as_ref().map(|(w, _)| w.clone()),
            sounding: self.voices.iter().flatten().count(),
        }
    }
}

/// Sound `id` as stereo 16-bit at the Desk's rate: the kit's rendered, the house's from
/// this computer or fetched.
fn pcm_of(id: i64, house: Option<&wo_house::House>) -> Result<Vec<i16>, String> {
    if id < 0 {
        let (sound, seconds) = match id {
            -1 => (FxSound::Riser, 8.0),
            -2 => (FxSound::SweepUp, 1.0),
            -3 => (FxSound::SweepDown, 1.5),
            -4 => (FxSound::Hydrant, 2.0),
            -5 => (FxSound::Impact, 1.0),
            _ => return Err("not in the kit".into()),
        };
        return Ok(crate::fx::to_pcm(&crate::fx::render(sound, seconds, 0.5, 0.9)));
    }
    let path = match (wo_house::sample_here(id), house) {
        (Some(p), _) => p,
        (None, Some(h)) => h.sample_audio(id).map_err(|e| e.to_string())?,
        (None, None) => return Err("not here, and not signed in to the house".into()),
    };
    let mut pcm = Vec::new();
    wo_decode::decode(&path, crate::RATE, &mut pcm).map_err(|e| e.to_string())?;
    Ok(pcm)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_v1s_board_whatever_it_lacks() {
        let v = serde_json::json!({
            "rev": 449, "server_rev": 84, "level": 0.4, "strip": {"bank": 0, "row": 0},
            "banks": [{"name": "A", "pads": [
                {"sample": 508, "name": "NEBENWIRKUNGEN", "colour": "accent", "mode": "oneShot", "gain": 1.0, "choke": 0, "quantise": "off", "duck": 0.0, "in_ms": 0},
                {"sample": 465, "name": "USB IN", "colour": "violet", "mode": "toggle", "quantise": "bar", "in_ms": 0},
                null,
                {"sample": -1, "mode": "someday", "colour": "pink", "gain": 9}
            ]}]
        });
        let d = Doc::read(v.clone()).unwrap();
        assert_eq!(d.banks.len(), BANKS);
        assert!(d.banks.iter().all(|b| b.pads.len() == PADS));
        assert_eq!(d.banks[1].name, "B");
        let p = d.pad(0, 1).unwrap();
        assert_eq!((p.mode, p.quantise, p.colour), (Mode::Toggle, Quantise::Bar, Colour::Violet));
        assert!(d.pad(0, 2).is_none());
        // what it does not know falls back, as v1's parse does
        let odd = d.pad(0, 3).unwrap();
        assert_eq!((odd.mode, odd.colour, odd.gain), (Mode::OneShot, Colour::White, 1.5));
        // written back as v1 writes it
        let back = serde_json::to_value(&d).unwrap();
        assert_eq!(back["banks"][0]["pads"][1]["mode"], "toggle");
        assert_eq!(back["banks"][0]["pads"][0]["colour"], "accent");
        assert_eq!(back["strip"], v["strip"]);
        assert_eq!(back["server_rev"], 84);
    }

    #[test]
    fn a_pads_words_from_a_sounds_name() {
        assert_eq!(Pad::new(1, "Air horn · classic").name, "AIR HORN");
        assert_eq!(Pad::new(1, "Vine boom (loud)").name, "VINE BOOM");
    }

    fn engine() -> Engine {
        Engine::start(Some(crate::RATE), wo_engine::Output::Offline).unwrap()
    }

    fn ready(b: &mut Board, e: &Engine) {
        for _ in 0..200 {
            b.tick(e);
            if b.sounds.values().all(|s| matches!(s, Sound::Ready { .. })) {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("the kit never rendered");
    }

    #[test]
    fn modes_choke_and_the_kit() {
        let e = engine();
        let mut doc = Doc::default();
        let p = |s: i64, m: Mode, choke: u8| Pad { mode: m, choke, ..Pad::new(s, "x") };
        doc.banks[0].pads[0] = Some(p(-5, Mode::OneShot, 0));
        doc.banks[0].pads[1] = Some(p(-2, Mode::Toggle, 0));
        doc.banks[0].pads[2] = Some(p(-1, Mode::Hold, 0));
        doc.banks[0].pads[3] = Some(p(-4, Mode::OneShot, 1));
        doc.banks[0].pads[4] = Some(p(-3, Mode::OneShot, 1));
        doc.banks[0].pads[5] = Some(Pad { duck: 0.6, ..p(-1, Mode::Loop, 0) });
        let mut b = Board::with(doc, None);
        ready(&mut b, &e);
        let mut out = vec![0f32; 2 * 512];
        let mut run = |e: &Engine| {
            let mut decks = [None, None, None, None];
            e.render(&mut out, &mut decks).unwrap();
        };
        let lit = |b: &Board, e: &Engine, i: usize| b.view(e).pads[i].lit.is_some();
        b.press(&e, 0, 0, None);
        run(&e);
        assert!(lit(&b, &e, 0));
        // toggle: on, off
        b.press(&e, 0, 1, None);
        run(&e);
        assert!(lit(&b, &e, 1));
        b.press(&e, 0, 1, None);
        run(&e);
        assert!(!lit(&b, &e, 1));
        // hold: while held
        b.press(&e, 0, 2, None);
        run(&e);
        assert!(lit(&b, &e, 2));
        b.release(&e, 0, 2);
        for _ in 0..8 {
            run(&e);
        }
        assert!(!lit(&b, &e, 2));
        // a choke group: one at a time
        b.press(&e, 0, 3, None);
        run(&e);
        b.press(&e, 0, 4, None);
        run(&e);
        assert!(!lit(&b, &e, 3) && lit(&b, &e, 4));
        // a ducking loop dips the decks while it sounds
        b.press(&e, 0, 5, None);
        run(&e);
        b.tick(&e);
        assert_eq!(b.duck, 0.6);
        b.stop_all(&e);
        for _ in 0..20 {
            run(&e);
        }
        b.tick(&e);
        assert_eq!(b.duck, 0.0);
        assert_eq!(b.view(&e).sounding, 0);
    }
}
