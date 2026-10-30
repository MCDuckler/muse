//! What a Desk UI draws, toolkit-free: the engine with two decks, the Auto DJ's mix,
//! the crate, the waveforms and the glass backdrop. Both bake-off UIs (egui, Slint)
//! drive one [`Desk`] the same way: [`Desk::tick`] and [`Desk::snapshot`] once a
//! frame, the controls when a hand moves one. Nothing here knows how it is drawn.
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use wo_engine::{Channels, DeckId, Engine, Eq, Gains, Output, Source};
use wo_wave::{Analyser, Tee, Wave};

pub mod backdrop;
pub mod bench;
pub mod library;
pub mod records;
pub mod synth;
pub mod theme;

pub use backdrop::Backdrop;
pub use library::{Library, Shelf};
pub use records::{Audio, Record};
pub use wo_booth::{Grid, Hands, Pad, PadKind, RANGES, Transport};
pub use wo_engine::Load;

const RATE: u32 = 48_000;
/// Bars the Auto DJ's blend takes, and the bar its bass swap lands on.
pub const MIX_BARS: f64 = 32.0;
pub const SWAP_BAR: f64 = 16.0;
/// Seconds a record plays alone before the next comes in.
const SOLO: f64 = 8.0;


/// One deck as it is this frame.
#[derive(Clone, Debug)]
pub struct DeckView {
    pub record: Record,
    pub heard: f64,
    pub length: f64,
    pub rate: f64,
    /// The record's tempo as it plays now.
    pub bpm: f64,
    pub playing: bool,
    pub synced: bool,
    pub master: bool,
    pub keylock: bool,
    pub phase_ms: f64,
    /// Peak since the last frame, 0..1.
    pub peak: f32,
    /// Knobs 0..1 (EQ and filter centred at 0.5).
    pub gain: f32,
    pub eq: [f32; 3],
    pub filter: f32,
    pub fader: f32,
    pub pads: [Option<Pad>; 8],
    /// How much of the record is decoded, 0..1.
    pub decoded: f32,
    /// The hands' state: CUE, the loop, the pitch fader.
    pub cue: Option<f64>,
    pub looped: Option<(f64, f64)>,
    pub loop_beats: Option<f64>,
    pub loop_open: bool,
    /// The pitch fader -1..1 and its range (±fraction).
    pub pitch: f64,
    pub range: f64,
}

#[derive(Clone, Copy, Debug)]
pub struct MixView {
    pub from: usize,
    pub to: usize,
    pub bar: f64,
}

#[derive(Clone, Debug)]
pub struct Snapshot {
    pub decks: [DeckView; 2],
    pub master_bpm: f64,
    pub crossfader: f32,
    pub mix: Option<MixView>,
    pub auto: bool,
    pub load: Load,
    pub set_seconds: f64,
    /// The Auto DJ's next few, best fit first.
    pub up_next: Vec<Record>,
}

/// A crate row this frame.
#[derive(Clone, Debug)]
pub struct Row {
    pub record: Record,
    pub fits: u8,
    pub on_deck: Option<usize>,
}

/// Beat and bar lines across a waveform, x in pixels.
#[derive(Clone, Debug, Default)]
pub struct Lines {
    pub beats: Vec<f32>,
    pub bars: Vec<f32>,
    /// x, the pad's index, the pad.
    pub pads: Vec<(f32, usize, Pad)>,
}

struct Slot {
    record: Record,
    hands: Hands,
    wave: Arc<Mutex<Wave>>,
    loader: Option<JoinHandle<Source>>,
    gain: f32,
    eq: [f32; 3],
    filter: f32,
    fader: f32,
    keylock: bool,
}

struct Mix {
    from: usize,
    to: usize,
    started: Instant,
    bpm: f64,
    swapped: bool,
}

pub struct Desk {
    engine: Engine,
    slots: [Slot; 2],
    master: usize,
    crossfader: f32,
    rows: Vec<Record>,
    queue: Vec<Record>,
    next: usize,
    mix: Option<Mix>,
    solo_since: Instant,
    started: Instant,
    auto: bool,
    _pacer: Option<Pacer>,
    /// The house, when signed in; what its workers hand back.
    house: Option<wo_house::House>,
    done_tx: mpsc::Sender<library::Done>,
    done_rx: mpsc::Receiver<library::Done>,
    library: Library,
    shelf_gen: u64,
    /// Each deck's load, counted: an answer for a record since replaced is dropped.
    load_gen: [u64; 2],
}

/// An offline engine rendered in real time on its own thread: a computer with no
/// sound card (CI) still plays, silently, so the UI has something to show.
struct Pacer {
    stop: Arc<std::sync::atomic::AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Drop for Pacer {
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Desk {
    /// Starts the engine (the sound card; else, or with WO_AUDIO=off, silently and
    /// paced in real time), loads the first two
    /// playable records, and plays the first from its first drop.
    pub fn open() -> Desk {
        // WO_AUDIO=off: no sound card even where there is one (tests, CI).
        let device = if std::env::var("WO_AUDIO").as_deref() == Ok("off") { Output::Offline } else { Output::Device };
        let started = if device == Output::Device { Engine::start(Some(RATE), Output::Device) } else { Err(wo_engine::Error::NotOffline) };
        let (engine, pacer) = match started {
            Ok(e) => (e, None),
            Err(_) => {
                let e = Engine::start(Some(RATE), Output::Offline).expect("an offline engine");
                let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
                let (e2, s2) = (e.clone(), stop.clone());
                let thread = thread::spawn(move || {
                    let t0 = Instant::now();
                    let mut done = 0u64;
                    let mut m = vec![0f32; 960];
                    while !s2.load(std::sync::atomic::Ordering::Relaxed) {
                        let _ = e2.render(&mut m, &mut [None, None, None, None]);
                        done += 480;
                        let due = Duration::from_secs_f64(done as f64 / RATE as f64);
                        if let Some(wait) = due.checked_sub(t0.elapsed()) {
                            thread::sleep(wait);
                        }
                    }
                });
                (e, Some(Pacer { stop, thread: Some(thread) }))
            }
        };
        let mut rows = records::crate_rows();
        let mut queue: Vec<Record> = rows.iter().filter(|r| r.playable()).cloned().collect();
        if queue.len() < 2 {
            let synth = records::synth_rows();
            rows.splice(0..0, synth.clone());
            queue = synth;
        }
        let empty = || Slot {
            record: queue[0].clone(),
            hands: Hands::new(Grid::default()),
            wave: Arc::new(Mutex::new(Wave::default())),
            loader: None,
            gain: 0.5,
            eq: [0.5; 3],
            filter: 0.5,
            fader: 0.85,
            keylock: true,
        };
        let (done_tx, done_rx) = mpsc::channel();
        let mut desk = Desk {
            engine,
            slots: [empty(), empty()],
            master: 0,
            crossfader: 0.0,
            rows,
            queue,
            next: 0,
            mix: None,
            solo_since: Instant::now(),
            started: Instant::now(),
            auto: true,
            _pacer: pacer,
            house: None,
            done_tx,
            done_rx,
            library: Library::default(),
            shelf_gen: 0,
            load_gen: [0; 2],
        };
        // the Desk's own saved sign-in; WO_APP_SIGN_IN=1 borrows the WetOwl app's for
        // this run only (development, screenshots)
        let borrowed = (std::env::var("WO_APP_SIGN_IN").as_deref() == Ok("1")).then(wo_house::Session::from_wetowl_app).flatten();
        if let Some(session) = wo_house::Session::saved().or(borrowed) {
            desk.signed_in(wo_house::House::new(session));
        }
        let (a, b) = (desk.take_next(), desk.take_next());
        desk.load(0, a);
        desk.load(1, b);
        for d in 0..2 {
            desk.engine.deck(DeckId::new(d).unwrap()).set_keylock(true);
        }
        let start = desk.slots[0].hands.pads[1].map(|p| p.at).unwrap_or(0.0);
        let a = desk.engine.deck(DeckId::A);
        a.seek((start - 4.0).max(0.0));
        a.play(true);
        desk.set_crossfader(0.0);
        desk
    }

    /// The Auto DJ's next record: the best fit to the master's on the house's shelf (what
    /// Up next shows first), else the local queue's next.
    fn take_next(&mut self) -> Record {
        let playing: Vec<i64> = self.slots.iter().map(|s| s.record.id).collect();
        let m = &self.slots[self.master].record;
        let best = self
            .library
            .rows
            .iter()
            .filter(|r| r.playable() && !playing.contains(&r.id))
            .max_by_key(|r| records::fits(r, m.bpm, &m.key));
        if let Some(r) = best {
            return r.clone();
        }
        let r = self.queue[self.next % self.queue.len()].clone();
        self.next += 1;
        r
    }

    /// A record onto a deck: its grid at once, its sound and waveform as they decode.
    pub fn load(&mut self, slot: usize, record: Record) {
        let deck = self.engine.deck(DeckId::new(slot).unwrap());
        deck.play(false);
        deck.unsync();
        deck.clear_loop();
        deck.bend(1.0);
        if let Some(old) = self.slots[slot].loader.take() {
            thread::spawn(move || drop(old.join()));
        }
        let (beats, bar_one) = match &record.audio {
            Audio::File { beats, bar_one, .. } => (beats.clone(), *bar_one),
            Audio::Synth { .. } => {
                let spb = 60.0 / record.bpm;
                ((0..(synth::seconds(record.bpm) / spb) as usize).map(|b| b as f64 * spb).collect(), 0)
            }
            Audio::House { .. } | Audio::None => (vec![], 0),
        };
        self.load_gen[slot] += 1;
        let turn = self.load_gen[slot];
        let mut source = self.engine.new_source(Channels::Stereo, RATE as i64 * record.seconds.max(60) as i64).expect("a source");
        deck.set_source(0, &source);
        deck.set_gains(0, Gains::FULL, 0.0);
        deck.set_beats(&beats);
        deck.set_bar_one(bar_one);
        let mut analyser = Analyser::new(RATE);
        let wave = analyser.wave();
        let audio = record.audio.clone();
        let bpm = record.bpm;
        let (house, tx) = (self.house.clone(), self.done_tx.clone());
        let loader = thread::spawn(move || {
            match audio {
                Audio::House { id } => match house {
                    Some(house) => {
                        let result = library::analyse(&house, id);
                        let ok = result.is_ok();
                        let _ = tx.send(library::Done::Analysed { slot, turn, result });
                        match house.audio(id) {
                            Ok(path) if ok => {
                                let mut tee = Tee { sink: &mut source, analyser: &mut analyser };
                                if let Err(e) = wo_decode::decode(&path, RATE, &mut tee) {
                                    let _ = tx.send(library::Done::LoadFailed { slot, turn, why: e.to_string() });
                                }
                            }
                            Ok(_) => {}
                            Err(e) => {
                                let _ = tx.send(library::Done::LoadFailed { slot, turn, why: e.to_string() });
                            }
                        }
                    }
                    None => {
                        let _ = tx.send(library::Done::LoadFailed { slot, turn, why: "not signed in to the house".into() });
                    }
                },
                Audio::File { path, .. } => {
                    let mut tee = Tee { sink: &mut source, analyser: &mut analyser };
                    if let Err(e) = wo_decode::decode(&path, RATE, &mut tee) {
                        eprintln!("{}: {e}", path.display());
                    }
                }
                Audio::Synth { seed } => {
                    let (pcm, _) = synth::render(bpm, seed);
                    for chunk in pcm.chunks(RATE as usize * 2) {
                        analyser.feed(chunk);
                        let _ = source.append(chunk);
                    }
                }
                Audio::None => {}
            }
            source.finish();
            analyser.finish();
            source
        });
        let len = record.seconds as f64;
        let bar_at = |frac: f64| -> f64 {
            let i = (((frac * beats.len() as f64) as usize).saturating_sub(bar_one) / 4) * 4 + bar_one;
            beats.get(i).copied().unwrap_or(frac * len)
        };
        let drop_at = match &record.audio {
            Audio::Synth { .. } => synth::first_drop(bpm),
            _ => bar_at(0.3),
        };
        let mut hands = Hands::new(Grid::new(beats.clone(), bar_one));
        if !beats.is_empty() {
            hands.place_auto(&[
                (0, beats[bar_one.min(beats.len() - 1)], PadKind::Intro),
                (1, drop_at, PadKind::Drop),
                (2, bar_at(0.5), PadKind::Break),
                (3, bar_at(0.86), PadKind::Out),
            ]);
        }
        let s = &mut self.slots[slot];
        s.record = record;
        s.hands = hands;
        s.wave = wave;
        s.loader = Some(loader);
        self.apply_levels();
        let deck = self.engine.deck(DeckId::new(slot).unwrap());
        deck.set_keylock(self.slots[slot].keylock);
        deck.set_eq(eq_db(self.slots[slot].eq), 0.0);
    }

    /// Advances the Auto DJ. Call once a frame.
    pub fn tick(&mut self) {
        while let Ok(done) = self.done_rx.try_recv() {
            self.handle(done);
        }
        if !self.auto {
            return;
        }
        match &mut self.mix {
            None => {
                let to = 1 - self.master;
                let ready = self.slots[to].wave.lock().unwrap().seconds() > 30.0;
                if self.solo_since.elapsed().as_secs_f64() >= SOLO && ready {
                    let from = self.master;
                    let bpm = self.deck_bpm(from);
                    let d = self.engine.deck(DeckId::new(to).unwrap());
                    let start = self.slots[to].hands.pads[0].map(|p| p.at).unwrap_or(0.0);
                    d.seek(start);
                    let master = DeckId::new(from).unwrap();
                    d.start_with(master, 4, None, 0.0);
                    d.sync(master, 4, 0.0);
                    self.slots[to].eq[0] = 0.0;
                    d.set_eq(eq_db(self.slots[to].eq), 0.0);
                    self.mix = Some(Mix { from, to, started: Instant::now(), bpm, swapped: false });
                }
            }
            Some(m) => {
                let bar = m.started.elapsed().as_secs_f64() * m.bpm / 240.0;
                let (from, to) = (m.from, m.to);
                let p = (bar / MIX_BARS).min(1.0) as f32;
                let x = if to == 1 { p } else { 1.0 - p };
                if bar >= SWAP_BAR && !m.swapped {
                    m.swapped = true;
                    self.slots[from].eq[0] = 0.0;
                    self.slots[to].eq[0] = 0.5;
                    for d in [from, to] {
                        self.engine.deck(DeckId::new(d).unwrap()).set_eq(eq_db(self.slots[d].eq), 60.0 / m.bpm);
                    }
                }
                self.set_crossfader(x);
                if bar >= MIX_BARS {
                    self.mix = None;
                    let old = self.engine.deck(DeckId::new(from).unwrap());
                    old.play(false);
                    self.engine.deck(DeckId::new(to).unwrap()).unsync();
                    self.master = to;
                    self.slots[from].eq = [0.5; 3];
                    self.solo_since = Instant::now();
                    let next = self.take_next();
                    self.load(from, next);
                }
            }
        }
    }

    pub fn snapshot(&self) -> Snapshot {
        let view = |i: usize| {
            let s = &self.slots[i];
            let st = self.engine.deck(DeckId::new(i).unwrap()).read();
            let wave = s.wave.lock().unwrap();
            let length = if s.record.seconds > 0 { s.record.seconds as f64 } else { wave.seconds() };
            DeckView {
                record: s.record.clone(),
                heard: self.engine.deck(DeckId::new(i).unwrap()).position(),
                length,
                // a parked deck has no rate in the engine: the pitch fader's, then
                rate: if st.rate > 0.0 { st.rate } else { s.hands.rate() },
                bpm: self.base_bpm(i) * if st.rate > 0.0 { st.rate } else { s.hands.rate() },
                playing: st.playing,
                synced: st.synced,
                master: i == self.master,
                keylock: s.keylock,
                phase_ms: st.phase_error * 1000.0,
                peak: st.peak.0.max(st.peak.1),
                gain: s.gain,
                eq: s.eq,
                filter: s.filter,
                fader: s.fader,
                pads: s.hands.pads,
                cue: s.hands.cue,
                looped: s.hands.looped,
                loop_beats: s.hands.loop_beats,
                loop_open: s.hands.loop_in.is_some(),
                pitch: s.hands.pitch,
                range: RANGES[s.hands.range],
                decoded: if wave.done { 1.0 } else { (wave.seconds() / length.max(1.0)).min(1.0) as f32 },
            }
        };
        let decks = [view(0), view(1)];
        let master_bpm = decks[self.master].bpm;
        let key = decks[self.master].record.key.clone();
        // the house's shelf when signed in (the Auto DJ takes from it), else the local queue
        let pool = if self.library.rows.iter().any(Record::playable) { &self.library.rows } else { &self.queue };
        let mut up: Vec<&Record> =
            pool.iter().filter(|r| r.playable() && r.id != decks[0].record.id && r.id != decks[1].record.id).collect();
        up.sort_by_key(|r| std::cmp::Reverse(records::fits(r, master_bpm, &key)));
        Snapshot {
            master_bpm,
            crossfader: self.crossfader,
            mix: self.mix.as_ref().map(|m| MixView { from: m.from, to: m.to, bar: m.started.elapsed().as_secs_f64() * m.bpm / 240.0 }),
            auto: self.auto,
            load: self.engine.load(),
            set_seconds: self.started.elapsed().as_secs_f64(),
            up_next: up.into_iter().take(4).cloned().collect(),
            decks,
        }
    }

    /// The crate as listed this frame: `filter` matched against title and artist,
    /// the decks' records first, then by fit to the master deck.
    pub fn rows(&self, filter: &str, master_bpm: f64) -> Vec<Row> {
        let key = self.slots[self.master].record.key.clone();
        // signed in: the house's shelf as it came (its search is the house's own)
        let (source, f) = if self.house.is_some() { (&self.library.rows, String::new()) } else { (&self.rows, filter.to_lowercase()) };
        let mut rows: Vec<Row> = source
            .iter()
            .filter(|r| f.is_empty() || r.title.to_lowercase().contains(&f) || r.artist.to_lowercase().contains(&f))
            .map(|r| Row {
                record: r.clone(),
                fits: records::fits(r, master_bpm, &key),
                on_deck: (0..2).find(|&d| self.slots[d].record.id == r.id),
            })
            .collect();
        rows.sort_by_key(|r| (r.on_deck.is_none(), std::cmp::Reverse(r.fits)));
        rows
    }

    /// A deck's waveform around `heard`, `width` px wide with the playhead in the
    /// middle, beats `beat_px` apart: each band's peak per `step` px, and the lines.
    pub fn waveform(&self, deck: usize, heard: f64, width: f32, step: f32, beat_px: f32) -> (Vec<[f32; 3]>, Lines) {
        let s = &self.slots[deck];
        let spb = self.spb(deck);
        let px_per_s = beat_px as f64 / spb;
        let t0 = heard - (width as f64 / 2.0) / px_per_s;
        let wave = s.wave.lock().unwrap();
        let n = (width / step).ceil() as usize;
        let cols = (0..n)
            .map(|i| {
                let a = t0 + (i as f64 * step as f64) / px_per_s;
                wave.span(a, a + step as f64 / px_per_s)
            })
            .collect();
        let t1 = t0 + width as f64 / px_per_s;
        let mut lines = Lines::default();
        let grid = &s.hands.grid;
        let first = grid.beats.partition_point(|&b| b < t0);
        for (i, &b) in grid.beats.iter().enumerate().skip(first) {
            if b > t1 {
                break;
            }
            let x = ((b - t0) * px_per_s) as f32;
            if grid.is_bar(i) { lines.bars.push(x) } else { lines.beats.push(x) }
        }
        for (i, p) in s.hands.pads.iter().enumerate() {
            let Some(p) = p else { continue };
            if p.at >= t0 && p.at <= t1 {
                lines.pads.push((((p.at - t0) * px_per_s) as f32, i, *p));
            }
        }
        (cols, lines)
    }

    /// The whole record in `cols` columns.
    pub fn overview(&self, deck: usize, cols: usize) -> Vec<[f32; 3]> {
        let s = &self.slots[deck];
        let wave = s.wave.lock().unwrap();
        let len = if s.record.seconds > 0 { s.record.seconds as f64 } else { wave.seconds() };
        (0..cols).map(|i| wave.span(i as f64 * len / cols as f64, (i + 1) as f64 * len / cols as f64)).collect()
    }

    // ---- the hands

    /// 0 = all A, 1 = all B.
    pub fn set_crossfader(&mut self, x: f32) {
        self.crossfader = x.clamp(0.0, 1.0);
        self.apply_levels();
    }

    pub fn set_fader(&mut self, deck: usize, v: f32) {
        self.slots[deck].fader = v.clamp(0.0, 1.0);
        self.apply_levels();
    }

    pub fn set_gain(&mut self, deck: usize, v: f32) {
        self.slots[deck].gain = v.clamp(0.0, 1.0);
        self.apply_levels();
    }

    /// band 0 low, 1 mid, 2 high; 0 kills, 0.5 is flat, 1 is +6 dB.
    pub fn set_eq(&mut self, deck: usize, band: usize, v: f32) {
        self.slots[deck].eq[band] = v.clamp(0.0, 1.0);
        self.engine.deck(DeckId::new(deck).unwrap()).set_eq(eq_db(self.slots[deck].eq), 0.02);
    }

    pub fn set_filter(&mut self, deck: usize, v: f32) {
        self.slots[deck].filter = v.clamp(0.0, 1.0);
        let k = (v - 0.5) * 2.0;
        self.engine.deck(DeckId::new(deck).unwrap()).set_filter(if k.abs() < 0.04 { 0.0 } else { k });
    }

    pub fn toggle_play(&mut self, deck: usize) {
        let d = self.engine.deck(DeckId::new(deck).unwrap());
        d.play(!d.read().playing);
    }

    pub fn toggle_sync(&mut self, deck: usize) {
        let d = self.engine.deck(DeckId::new(deck).unwrap());
        if d.read().synced {
            d.unsync();
        } else {
            d.sync(DeckId::new(1 - deck).unwrap(), 4, 0.0);
        }
    }

    pub fn toggle_keylock(&mut self, deck: usize) {
        let s = &mut self.slots[deck];
        s.keylock = !s.keylock;
        self.engine.deck(DeckId::new(deck).unwrap()).set_keylock(s.keylock);
    }

    // ---- a deck's hands (wo-booth), on the engine

    /// Runs `f` with deck `d`'s hands over its engine deck.
    fn hands<R>(&mut self, d: usize, f: impl FnOnce(&mut Hands, &mut EngineDeck<'_>) -> R) -> R {
        let mut t = EngineDeck(self.engine.deck(DeckId::new(d).unwrap()));
        f(&mut self.slots[d].hands, &mut t)
    }

    pub fn cue_down(&mut self, d: usize) {
        self.hands(d, |h, t| h.cue_down(t));
    }

    pub fn cue_up(&mut self, d: usize) {
        self.hands(d, |h, t| h.cue_up(t));
    }

    /// A pad pressed: set here when empty, else the record goes there.
    pub fn pad(&mut self, d: usize, n: usize) {
        self.hands(d, |h, t| h.pad(n, t));
    }

    pub fn clear_pad(&mut self, d: usize, n: usize) {
        self.slots[d].hands.clear_pad(n);
    }

    /// A loop of `beats` from the bar (the same again lets go).
    pub fn loop_beats(&mut self, d: usize, beats: f64) {
        self.hands(d, |h, t| h.loop_beats(beats, t));
    }

    pub fn loop_in(&mut self, d: usize) {
        self.hands(d, |h, t| h.loop_in(t));
    }

    pub fn loop_out(&mut self, d: usize) {
        self.hands(d, |h, t| h.loop_out(t));
    }

    pub fn halve_loop(&mut self, d: usize) {
        self.hands(d, |h, t| h.halve(t));
    }

    pub fn double_loop(&mut self, d: usize) {
        self.hands(d, |h, t| h.double(t));
    }

    pub fn unloop(&mut self, d: usize) {
        self.hands(d, |h, t| h.unloop(t));
    }

    /// `beats` on (negative: back), the loop with it.
    pub fn jump(&mut self, d: usize, beats: f64) {
        self.hands(d, |h, t| h.jump(beats, t));
    }

    /// The pitch fader, -1..1.
    pub fn set_pitch(&mut self, d: usize, v: f64) {
        self.hands(d, |h, t| h.set_pitch(v, t));
    }

    pub fn cycle_range(&mut self, d: usize) {
        self.hands(d, |h, t| h.cycle_range(t));
    }

    /// A nudge held (-1, 1) or let go (0).
    pub fn nudge(&mut self, d: usize, dir: i8) {
        self.hands(d, |h, t| h.nudge(dir, t));
    }

    pub fn brake(&mut self, d: usize) {
        self.hands(d, |h, t| h.brake(t));
    }

    // ---- the house

    /// The library as the crate shows it.
    pub fn library(&self) -> &Library {
        &self.library
    }

    /// Who is signed in, and where: (server, user).
    pub fn house(&self) -> Option<(&str, Option<&str>)> {
        self.house.as_ref().map(|h| (h.session.server.as_str(), h.session.user.as_deref()))
    }

    /// Signs in (on a worker); the library fills when it is done.
    pub fn sign_in(&mut self, server: &str, user: &str, password: &str) {
        self.library.signing_in = true;
        self.library.error = None;
        library::sign_in(&self.done_tx, server.to_owned(), user.to_owned(), password.to_owned());
    }

    /// Whether the WetOwl app on this computer is signed in, to use its sign-in.
    pub fn app_sign_in_here() -> bool {
        wo_house::Session::from_wetowl_app().is_some()
    }

    pub fn use_app_sign_in(&mut self) {
        if let Some(s) = wo_house::Session::from_wetowl_app() {
            let _ = s.save();
            self.use_session(s);
        }
    }

    /// Signed in with `s` for this run (not saved).
    pub fn use_session(&mut self, s: wo_house::Session) {
        self.signed_in(wo_house::House::new(s));
    }

    pub fn sign_out(&mut self) {
        wo_house::Session::forget();
        self.house = None;
        self.library = Library::default();
    }

    /// Shows a shelf: everything, a playlist, a search (an empty search is everything).
    pub fn open_shelf(&mut self, shelf: Shelf) {
        let shelf = match shelf {
            Shelf::Search(q) if q.trim().is_empty() => Shelf::All,
            s => s,
        };
        let Some(house) = &self.house else { return };
        self.shelf_gen += 1;
        self.library.shelf = shelf.clone();
        self.library.loading = true;
        library::fetch_shelf(&self.done_tx, house, shelf, self.shelf_gen);
    }

    fn signed_in(&mut self, house: wo_house::House) {
        library::fetch_playlists(&self.done_tx, &house);
        self.house = Some(house);
        self.open_shelf(Shelf::All);
    }

    fn handle(&mut self, done: library::Done) {
        use library::Done;
        match done {
            Done::SignedIn(Ok(house)) => {
                self.library.signing_in = false;
                self.signed_in(house);
            }
            Done::SignedIn(Err(e)) => {
                self.library.signing_in = false;
                self.library.error = Some(e);
            }
            Done::Shelf { turn, rows } if turn == self.shelf_gen => {
                self.library.loading = false;
                match rows {
                    Ok((rows, total)) => {
                        self.library.rows = rows;
                        self.library.total = total;
                        self.library.error = None;
                    }
                    Err(e) => self.library.error = Some(e),
                }
            }
            Done::Shelf { .. } => {}
            Done::Playlists(Ok(lists)) => self.library.playlists = lists,
            Done::Playlists(Err(e)) => self.library.error = Some(e),
            Done::Analysed { slot, turn, result } if turn == self.load_gen[slot] => match result {
                Ok(a) => {
                    let deck = self.engine.deck(DeckId::new(slot).unwrap());
                    deck.set_beats(&a.grid.beats);
                    deck.set_bar_one(a.grid.bar_one);
                    let mut hands = Hands::new(a.grid);
                    for &(n, at) in &a.hand {
                        match at {
                            Some(at) => hands.pads[n] = Some(Pad { at, auto: None }),
                            None => hands.clear_pad(n),
                        }
                    }
                    hands.place_auto(&a.auto);
                    let s = &mut self.slots[slot];
                    s.hands = hands;
                    if let Some(k) = a.camelot {
                        s.record.key = k;
                    }
                    if let Some(b) = a.bpm {
                        s.record.bpm = b;
                    }
                }
                Err(e) => self.library.error = Some(format!("{}: {e}", self.slots[slot].record.title)),
            },
            Done::Analysed { .. } => {}
            Done::LoadFailed { slot, turn, why } if turn == self.load_gen[slot] => {
                self.library.error = Some(format!("{}: {why}", self.slots[slot].record.title));
            }
            Done::LoadFailed { .. } => {}
        }
    }

    pub fn set_auto(&mut self, on: bool) {
        self.auto = on;
    }

    // ---- inside

    fn apply_levels(&self) {
        let x = self.crossfader;
        let (ga, gb) = ((2.0 * (1.0 - x)).min(1.0), (2.0 * x).min(1.0));
        for (d, g) in [(0, ga), (1, gb)] {
            let s = &self.slots[d];
            let trim = 10f32.powf((s.gain - 0.5) * 24.0 / 20.0);
            self.engine.deck(DeckId::new(d).unwrap()).set_level(s.fader * s.fader * g * trim, 0.03);
        }
    }

    fn spb(&self, deck: usize) -> f64 {
        self.slots[deck].hands.grid.spb().unwrap_or(60.0 / self.slots[deck].record.bpm.max(1.0))
    }

    fn base_bpm(&self, deck: usize) -> f64 {
        60.0 / self.spb(deck)
    }

    fn deck_bpm(&self, deck: usize) -> f64 {
        self.base_bpm(deck) * self.engine.deck(DeckId::new(deck).unwrap()).read().rate.max(0.01)
    }
}

/// A knob 0..1 to decibels: 0 kills (-40), 0.5 flat, 1 is +6.
fn eq_db(eq: [f32; 3]) -> Eq {
    let db = |v: f32| if v >= 0.5 { (v - 0.5) * 12.0 } else { -40.0 * ((0.5 - v) * 2.0).powf(1.5) };
    Eq { low: db(eq[0]), mid: db(eq[1]), high: db(eq[2]) }
}

/// An engine deck as the hands' transport.
struct EngineDeck<'e>(wo_engine::Deck<'e>);

impl Transport for EngineDeck<'_> {
    fn position(&self) -> f64 {
        self.0.position()
    }
    fn playing(&self) -> bool {
        self.0.read().playing
    }
    fn play(&mut self, on: bool) {
        self.0.play(on);
    }
    fn seek(&mut self, t: f64) {
        self.0.seek(t);
    }
    fn set_loop(&mut self, ab: Option<(f64, f64)>) {
        match ab {
            Some((a, b)) => self.0.set_loop(a, b),
            None => self.0.clear_loop(),
        }
    }
    fn set_rate(&mut self, rate: f64) {
        self.0.set_rate(rate);
    }
    fn bend(&mut self, factor: f64) {
        self.0.bend(factor);
    }
    fn brake(&mut self, seconds: f64) {
        self.0.brake(seconds);
    }
}
