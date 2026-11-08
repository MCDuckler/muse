//! What a Desk UI draws, toolkit-free: the engine with two decks, the Auto DJ's mix,
//! the crate, the waveforms and the glass backdrop. Both bake-off UIs (egui, Slint)
//! drive one [`Desk`] the same way: [`Desk::tick`] and [`Desk::snapshot`] once a
//! frame, the controls when a hand moves one. Nothing here knows how it is drawn.
//! The show is the Stage's (stage.rs): a window of its own, fed a frame each tick.
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use wo_engine::{Bus, Channels, DeckId, Engine, Eq, Gains, Output, Source};
use wo_wave::{Analyser, Tee, Wave};
pub use wo_wave::Bin;

pub mod backdrop;
pub mod bench;
pub mod covers;
pub mod library;
pub mod milk;
pub mod move_player;
pub mod autodj;
mod crate_;
pub mod plan_view;
pub mod session;
pub mod set;
mod fx;
mod transition;
pub mod parts;
pub mod prefs;
pub mod records;
pub mod show;
pub mod stage;
pub mod synth;
pub mod theme;

pub use backdrop::Backdrop;
pub use covers::Cover;
pub use prefs::Prefs;
pub use library::{GRID_VERDICTS, Library, Shelf, StickView, verdict_word};
pub use records::{Audio, Loudness, Record};
pub use show::{MilkFilter, FaveEdit, FaveRow, FavesView, SetEdit, SetRow, SetsView, FinishView, LooksGrid, MilkHand, MilkRow, MilkView, MoveRow, MovesView, OwnRows, RotationRow, RotationView, ScenePage, ShowBoard, ShowEdit, ShowHands, Square, SquareDo, StyleRow, TuneRow, Variants, shot_name, value_name};
pub use wo_show::plan::{LEVEL_MOST, LEVEL_STEPS, level_word};
pub use wo_show::rig::{RigFinish, TransformSet};
pub use wo_show::shares::share_word;
pub use wo_show::Mix as ShowMix;
/// The scenes the Rust stage draws so far.
pub use wo_show::scenes::DRAWN as RUST_SCENES;
pub use stage::{Hand as ShowHand, StageView, Thumb};
pub use transition::{bass_swap_bar, law, levels_at as mix_levels_at};
pub use wo_booth::{Grid, Hands, Pad, PadKind, RANGES, Style, Timing, Transition, Transport};
pub use wo_engine::Load;

const RATE: u32 = 48_000;
/// Bars the Auto DJ's blend takes, and the bar its bass swap lands on.
/// How far ahead of a transition's out point the next record is started (the engine
/// then starts it sample-exactly on the point).
const LEAD: f64 = 0.25;


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
    /// The same, each side: left, right.
    pub peak_lr: (f32, f32),
    /// How much of it the room hears: its fader through the crossfader's law, 0..1 (0
    /// while it is not playing).
    pub audible: f32,
    /// Knobs 0..1 (EQ and filter centred at 0.5).
    pub gain: f32,
    pub eq: [f32; 3],
    pub filter: f32,
    pub fader: f32,
    pub pads: [Option<Pad>; 8],
    /// How much of the record is decoded, 0..1.
    pub decoded: f32,
    /// The part playing (the whole record, or its stems at a part's levels) and where
    /// the stems are.
    pub part: parts::Part,
    pub stems: parts::Stems,
    /// What is known of the record (v1's data marks): its stems, its beats, its form
    /// (sections), its voice (the vocal map).
    pub marks: [bool; 4],
    /// The record is being put on (its audio and analysis on their way).
    pub loading: bool,
    /// The hands' state: CUE, the loop, the pitch fader.
    pub cue: Option<f64>,
    pub looped: Option<(f64, f64)>,
    pub loop_beats: Option<f64>,
    pub loop_open: bool,
    /// The pitch fader -1..1 and its range (±fraction).
    pub pitch: f64,
    pub range: f64,
}

/// The Auto DJ's next transition, planned or under way.
#[derive(Clone, Debug)]
pub struct MixView {
    pub from: usize,
    pub to: usize,
    pub kind: Transition,
    pub bars: u32,
    /// Under way (else planned).
    pub mixing: bool,
    /// Bars into it when mixing; when planned, seconds until it starts.
    pub bar: f64,
    pub starts_in: f64,
    /// Where its bass changes hands, bars in (the transitions that swap it).
    pub swap_bar: Option<f64>,
    /// Why the planner chose it, in its words.
    pub why: String,
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

/// A control moved on a controller, and what the Desk did with it.
#[derive(Clone, Debug)]
pub struct ControlLine {
    pub at: Instant,
    pub id: String,
    pub value: f64,
    /// The actions it made (none: nothing is bound to it).
    pub did: Vec<String>,
}

/// A crate row this frame.
#[derive(Clone, Debug)]
pub struct Row {
    pub record: Record,
    pub fits: u8,
    pub on_deck: Option<usize>,
    /// A word on it: why it was picked, what its check said.
    pub note: Option<String>,
}

/// Beat and bar lines across a waveform, x in pixels.
#[derive(Clone, Debug, Default)]
pub struct Lines {
    pub beats: Vec<f32>,
    /// Bars, but for those that start two bars (below).
    pub bars: Vec<f32>,
    /// The bars two after a four-bar group's start: its second half.
    pub twos: Vec<f32>,
    /// The bars that start a four-bar group (the house's markers, else every fourth from
    /// the one): x and the bar's number, from 1 at the grid's one.
    pub fours: Vec<(f32, i64)>,
    /// x, the pad's index, the pad.
    pub pads: Vec<(f32, usize, Pad)>,
}

/// A deck's waveform lane: bins fixed to the record's own columns (so as it scrolls its
/// shape holds still), where each falls, and the lines over it. x from the lane's left.
#[derive(Clone, Debug, Default)]
pub struct LaneWave {
    pub bins: Vec<Option<Bin>>,
    /// The first bin's left edge, and each bin's width.
    pub x0: f32,
    pub bin_w: f32,
    /// Pixels a second of the record (its own time), and where the playhead's time is.
    pub px_per_s: f64,
    pub heard: f64,
    pub lines: Lines,
    /// Where the record starts and ends in the lane.
    pub start: f32,
    pub end: f32,
    /// How far it has come in, while it decodes.
    pub arriving: Option<f32>,
}

/// What a record is made of in time, for drawing: its sections (a name, start, end) and
/// its drops, in seconds.
#[derive(Clone, Debug, Default)]
pub struct Form {
    pub sections: Vec<(String, f64, f64)>,
    pub drops: Vec<f64>,
}

/// What a bar's line is on the lanes and overviews.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BarKind {
    /// It starts a four-bar group.
    Four,
    /// Two bars into one: the group's second half.
    Two,
    Bar,
}

/// Beat `i` of `grid`: None where it is not a bar's one; else the bar's number (from 1 at
/// the grid's one) and its kind. Four-bar groups start on the house's markers (`markers`,
/// seconds) where it has them — counted on from the last one before, so the halves split
/// each group evenly — else every fourth bar from the one.
pub(crate) fn bar_kind(grid: &Grid, markers: &[f64], i: usize) -> Option<(i64, BarKind)> {
    if !grid.is_bar(i) {
        return None;
    }
    let b = *grid.beats.get(i)?;
    let bar = (i as i64 - grid.bar_one as i64).div_euclid(4) + 1;
    let since = if markers.is_empty() {
        (bar - 1).rem_euclid(4)
    } else {
        // bars since the last marker at or before it (a marker is within 80 ms of its bar)
        let last = markers.partition_point(|&m| m <= b + 0.08);
        match last.checked_sub(1).map(|k| markers[k]) {
            Some(m) => {
                let im = grid.beats.partition_point(|&x| x < m - 0.08);
                (i as i64 - im as i64).div_euclid(4).max(0)
            }
            // before the first marker: counted back from it
            None => match markers.first() {
                Some(&m) => {
                    let im = grid.beats.partition_point(|&x| x < m - 0.08) as i64;
                    (i as i64 - im).div_euclid(4).rem_euclid(4)
                }
                None => 0,
            },
        }
    };
    // (a group of the house's may run past four bars — a phrase of six: every second bar
    // of it is still a two)
    let kind = match since {
        0 => BarKind::Four,
        n if n % 2 == 0 => BarKind::Two,
        _ => BarKind::Bar,
    };
    Some((bar, kind))
}

struct Slot {
    record: Record,
    hands: Hands,
    /// What the record is made of in time, for the Auto DJ (the house's analysis, or
    /// the grid alone).
    timing: Timing,
    wave: Arc<Mutex<Wave>>,
    loader: Option<JoinHandle<Source>>,
    gain: f32,
    eq: [f32; 3],
    filter: f32,
    fader: f32,
    keylock: bool,
    /// The record's stems and the part playing (parts.rs).
    stems: parts::DeckStems,
    /// What a transition has the deck's effects at: the echo (send, dry), the chop
    /// (depth, chops to a beat), the pitch shift in semitones.
    echo: (f32, f32),
    gate: (f32, u32),
    shift: f32,
    /// Where the record sings (the house's vocal map), for the planner.
    vocals: Option<wo_booth::planner::VocalMap>,
}

/// A transition the Auto DJ has planned (and, once `started`, is making).
struct Plan {
    from: usize,
    to: usize,
    kind: Transition,
    bars: u32,
    /// The outgoing's source time where it starts, and how long it lasts there.
    out: f64,
    length: f64,
    in_step: bool,
    /// The incoming deck's load it was planned for: a load since makes it stale.
    turn: u64,
    started: bool,
    /// When the outgoing reached the out point (the engine's clock) and its rate then:
    /// the move's progress is time from there, not the outgoing's place — a roll loops
    /// that place.
    begun: Option<(f64, f64)>,
    /// 0..1 through the move.
    progress: f64,
    /// Its steps and how far through them (transition.rs).
    run: transition::Running,
    /// Every move the planner considered, best first, and why each.
    options: Vec<wo_booth::planner::MixPlan>,
    why: String,
    /// Where the incoming waits, parked (its source time).
    park: f64,
}

pub struct Desk {
    engine: Engine,
    slots: [Slot; 2],
    master: usize,
    crossfader: f32,
    rows: Vec<Record>,
    queue: Vec<Record>,
    next: usize,
    mix: Option<Plan>,
    pub style: Style,
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
    /// DJ controllers: found and read on their own threads, bound the v1 booth's way.
    controls: Option<wo_control::Manager>,
    binding: wo_control::Binding,
    /// What the controllers asked of the crate (browse, load), for the UI, which has it.
    for_the_crate: Vec<wo_control::Action>,
    /// The jog wheel's feel per deck: its speed, and when it last turned.
    jog: [(f64, Option<Instant>); 2],
    /// The lights as last sent, and to how many controllers.
    lit: std::collections::HashMap<String, bool>,
    lit_for: usize,
    /// The show's window.
    stage: stage::Stage,
    /// Counts what changed the Desk from outside the window (a controller, an answer from
    /// the house): the window repaints when it moves, and rests when nothing does.
    changes: u64,
    /// Records' covers for the sleeves.
    covers: covers::Covers,
    /// The rekordbox sticks plugged in, read.
    sticks: Vec<Arc<wo_usb::Stick>>,
    /// The crossfader's law: equal power, or "full" (both whole at the middle) while a
    /// move that shares one record's worth of sound between the decks runs.
    full_law: bool,
    /// The booth's own sounds.
    fx: fx::Fx,
    /// The moves made, the last last (the planner keeps from repeating itself).
    recent: Vec<Transition>,
    /// The planner's dice.
    dice: u64,
    /// The Auto DJ's mind: steering, the house's choices, the log, the thumbs (autodj.rs).
    mind: autodj::Mind,
    /// A set built at the house, and whether the Auto DJ plays it (set.rs).
    set: set::SetState,
    /// Records a hand queued for the Auto DJ (crate_.rs).
    hand_queue: Vec<Record>,
    /// The library's next page asked for at this many rows.
    more_asked: Option<usize>,
    /// What the controllers' moves did, lately (the controllers page).
    control_lines: std::collections::VecDeque<ControlLine>,
    /// The booth as it was, kept (session.rs): when last, whether a record was playing then,
    /// since when nothing has; a resumed deck's place and play, kept until its sound is in;
    /// what the resuming said (taken once by the window).
    session_kept: Option<Instant>,
    session_live: bool,
    idle_since: Option<Instant>,
    resume: [Option<(f64, bool)>; 2],
    resumed: Option<String>,
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
    /// paced in real time) and loads the first two playable records, parked. With
    /// `autoplay` (benches, demos) the first plays from just before its drop and the
    /// Auto DJ is on; without, nothing sounds until a hand asks.
    pub fn open(autoplay: bool) -> Desk {
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
            timing: Timing::default(),
            wave: Arc::new(Mutex::new(Wave::default())),
            loader: None,
            gain: 0.5,
            eq: [0.5; 3],
            filter: 0.5,
            fader: 0.85,
            keylock: true,
            stems: Default::default(),
            echo: (0.0, 1.0),
            gate: (0.0, 2),
            shift: 0.0,
            vocals: None,
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
            style: Style::Normal,
            started: Instant::now(),
            auto: autoplay,
            _pacer: pacer,
            house: None,
            done_tx,
            done_rx,
            library: Library::default(),
            shelf_gen: 0,
            load_gen: [0; 2],
            // WO_CONTROLLERS=off: none (tests)
            controls: (std::env::var("WO_CONTROLLERS").as_deref() != Ok("off")).then(wo_control::Manager::start),
            binding: wo_control::Binding::default(),
            for_the_crate: vec![],
            jog: [(0.0, None); 2],
            lit: Default::default(),
            lit_for: 0,
            stage: stage::Stage::default(),
            changes: 0,
            covers: Default::default(),
            sticks: vec![],
            full_law: false,
            fx: Default::default(),
            recent: vec![],
            mind: Default::default(),
            set: Default::default(),
            hand_queue: vec![],
            more_asked: None,
            control_lines: Default::default(),
            session_kept: None,
            session_live: false,
            idle_since: None,
            resume: [None, None],
            resumed: None,
            dice: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(7, |d| d.as_nanos() as u64) | 1,
        };
        // the Desk's own saved sign-in; WO_APP_SIGN_IN=1 borrows the WetOwl app's for
        // this run only (development, screenshots)
        // WO_HOUSE=off: never the house (tests: no account is read or told anything)
        let borrowed = (std::env::var("WO_APP_SIGN_IN").as_deref() == Ok("1")).then(wo_house::Session::from_wetowl_app).flatten();
        let house_ok = std::env::var("WO_HOUSE").as_deref() != Ok("off");
        library::watch_sticks(&desk.done_tx);
        if let Some(session) = wo_house::Session::saved().or(borrowed).filter(|_| house_ok) {
            desk.signed_in(wo_house::House::new(session));
        }
        let (a, b) = (desk.take_next(), desk.take_next());
        desk.load(0, a);
        desk.load(1, b);
        for d in 0..2 {
            desk.engine.deck(DeckId::new(d).unwrap()).set_keylock(true);
        }
        desk.set_crossfader(0.0);
        // the set that was playing when the Desk last closed, taken up again (not for a
        // bench or a test's demo; WO_RESUME=off: never)
        if !autoplay && std::env::var("WO_RESUME").as_deref() != Ok("off") {
            desk.resume_session();
        }
        if autoplay {
            let start = desk.slots[0].hands.pads[1].map(|p| p.at).unwrap_or(0.0);
            let a = desk.engine.deck(DeckId::A);
            a.seek((start - 4.0).max(0.0));
            a.play(true);
        }
        desk
    }

    /// The Auto DJ's next record: the best fit to the master's on the house's shelf (what
    /// Up next shows first), else the local queue's next.
    fn take_next(&mut self) -> Record {
        if let Some(r) = self.queued_next() {
            return r;
        }
        if let Some(r) = self.set_next() {
            return r;
        }
        if let Some(r) = self.chosen_next() {
            return r;
        }
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
        self.mind.by_hand[slot] = false;
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
            Audio::House { .. } | Audio::Usb { .. } | Audio::None => (vec![], 0),
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
        // the record's cover for the stage's cover ground: none until it comes
        self.stage.cover(slot, record.id, None);
        if let (Audio::House { id }, true, Some(house)) = (&record.audio, record.cover, self.house.clone()) {
            let (id, tx) = (*id, self.done_tx.clone());
            thread::spawn(move || {
                let cover = library::cover(&house, id).map_err(|e| eprintln!("cover of {id}: {e}")).ok();
                let _ = tx.send(library::Done::Cover { slot, turn, id, cover });
            });
        }
        if let Audio::Usb { artwork: Some(art), .. } = &record.audio {
            let (art, id, tx) = (art.clone(), record.id, self.done_tx.clone());
            thread::spawn(move || {
                let cover = library::cover_file(&art).map_err(|e| eprintln!("cover {}: {e}", art.display())).ok();
                let _ = tx.send(library::Done::Cover { slot, turn, id, cover });
            });
        }
        let audio = record.audio.clone();
        let seconds = record.seconds as f64;
        let bpm = record.bpm;
        let (house, tx) = (self.house.clone(), self.done_tx.clone());
        let loader = thread::spawn(move || {
            match audio {
                Audio::House { id } => match house {
                    Some(house) => {
                        let result = library::analyse(&house, id).map(Box::new);
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
                // rekordbox's grid and cues first (a few KB off the stick), then the audio
                Audio::Usb { path, anlz, .. } => {
                    let result = library::analyse_usb(anlz.as_deref(), seconds).map(Box::new);
                    let _ = tx.send(library::Done::Analysed { slot, turn, result });
                    let mut tee = Tee { sink: &mut source, analyser: &mut analyser };
                    // decoded as rekordbox does, so its grid and cues sit on the beats
                    if let Err(e) = wo_decode::decode_as_rekordbox(&path, RATE, &mut tee) {
                        let why = if path.exists() { e.to_string() } else { "its stick is not plugged in".to_owned() };
                        let _ = tx.send(library::Done::LoadFailed { slot, turn, why });
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
        let timing = self.timing_of(&record, hands.grid.clone());
        let s = &mut self.slots[slot];
        s.record = record;
        s.hands = hands;
        s.timing = timing;
        s.wave = wave;
        s.loader = Some(loader);
        s.vocals = None;
        if s.shift != 0.0 {
            s.shift = 0.0;
            self.engine.deck(DeckId::new(slot).unwrap()).set_shift(0.0);
        }
        self.reset_stems(slot);
        self.apply_levels();
        let deck = self.engine.deck(DeckId::new(slot).unwrap());
        deck.set_keylock(self.slots[slot].keylock);
        deck.set_eq(eq_db(self.slots[slot].eq), 0.0);
    }

    /// Advances the Auto DJ. Call once a frame.
    ///
    /// Planned: with the master playing and a timed record on the other deck, the
    /// transition is chosen (wo_booth::mix: which kind, how many bars, where the master
    /// goes out, where the next comes in) and the next is parked at its in point.
    /// Started: a beat ahead of the out point the engine is told to start it exactly
    /// there, in step. Under way: the transition's moves each frame. Done: the old
    /// record stops, the new one is master, and the record after goes on the free deck.
    pub fn tick(&mut self) {
        while let Ok(done) = self.done_rx.try_recv() {
            self.handle(done);
            self.changes += 1;
        }
        self.controllers_tick();
        self.session_tick();
        self.stems_tick();
        self.mind_tick();
        self.feed_stage();
        if !self.auto {
            return;
        }
        // a hand loaded something else onto the incoming deck: plan again
        if self.mix.as_ref().is_some_and(|m| !m.started && m.turn != self.load_gen[m.to]) {
            self.mix = None;
        }
        let Some(m) = self.mix.as_ref() else { return self.plan() };
        let (from, to, out, length, kind, started) = (m.from, m.to, m.out, m.length, m.kind, m.started);
        let fd = DeckId::new(from).unwrap();
        let heard = self.engine.deck(fd).position();
        if !started {
            if heard >= out - LEAD {
                let d = self.engine.deck(DeckId::new(to).unwrap());
                // a moment late (the plan came in after its point): start now, in step
                d.start_with(fd, 4, (heard < out).then_some(out), 0.0);
                if self.mix.as_ref().is_some_and(|m| m.in_step) {
                    d.sync(fd, 4, 0.0);
                }
                if let Some(m) = self.mix.as_mut() {
                    m.started = true;
                }
            }
            return;
        }
        let now = self.engine.now();
        let begun = match self.mix.as_ref().and_then(|m| m.begun) {
            Some(b) => b,
            None if heard >= out - 0.005 => {
                let b = (now, self.engine.deck(fd).read().rate.max(0.01));
                if let Some(m) = self.mix.as_mut() {
                    m.begun = Some(b);
                }
                self.begin_move();
                b
            }
            None => return,
        };
        let p = (now - begun.0) * begun.1 / length.max(0.01);
        let _ = kind;
        self.run_move(p.min(1.0));
        if let Some(m) = self.mix.as_mut() {
            m.progress = p.min(1.0);
        }
        if p >= 1.0 {
            self.finish_mix(from, to);
        }
    }

    /// The next transition, when there is one to plan.
    fn plan(&mut self) {
        let (from, to) = (self.master, 1 - self.master);
        let fd = self.engine.deck(DeckId::new(from).unwrap());
        if !fd.read().playing || !self.slots[to].record.playable() {
            return;
        }
        let (ft, tt) = (&self.slots[from].timing, &self.slots[to].timing);
        // the incoming's grid (a house record's comes with its analysis) and some sound
        let decoded = self.slots[to].wave.lock().unwrap().seconds();
        if !tt.has_beats() || decoded < 20.0 {
            return;
        }
        let pitch = fd.read().rate.max(0.01);
        let heard = fd.position();
        let mut dice = self.dice;
        let mut chance = move || {
            // xorshift64*
            dice ^= dice >> 12;
            dice ^= dice << 25;
            dice ^= dice >> 27;
            (dice.wrapping_mul(0x2545F4914F6CDD1D) >> 11) as f64 / (1u64 << 53) as f64
        };
        let options = wo_booth::planner::options(
            wo_booth::planner::MixSide {
                timing: ft,
                vocals: self.slots[from].vocals.as_ref(),
                stems: self.slots[from].stems.state.ready(),
                pitch,
                fx: true,
                position: Some(heard),
            },
            wo_booth::planner::MixSide {
                timing: tt,
                vocals: self.slots[to].vocals.as_ref(),
                stems: self.slots[to].stems.state.ready(),
                pitch: 1.0,
                fx: true,
                position: None,
            },
            self.style,
            None,
            &self.recent,
            wo_booth::planner::Can { sound: true, gate: true },
            &|k| self.mind.taste.of_kind(k),
            &mut chance,
        );
        self.dice = self.dice.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407) | 1;
        let best = options[0].clone();
        let (kind, bars) = (best.kind, best.bars.max(1));
        let bar = ft.bar().unwrap_or(60.0 / self.slots[from].record.bpm.max(60.0) * 4.0);
        let length = bars as f64 * bar;
        let mut out = match best.out_at {
            Some(at) => ft.on_grid(at, 4),
            None => wo_booth::mix::clear_of_drops(ft, wo_booth::mix::out_point(ft, length), length),
        };
        // a plan for a place already behind the record goes at the soonest marker
        // there is time for
        if out < heard + bar {
            out = ft.markers.iter().copied().find(|&m| m >= heard + bar).unwrap_or_else(|| ft.on_grid(heard + bar, 4));
        }
        let in_step = match (ft.bpm, tt.bpm) {
            (Some(a), Some(b)) => wo_booth::mix::sync_ratio(b, a * pitch, wo_booth::mix::BRIDGE_REACH).is_some(),
            _ => false,
        };
        let on_the_drop = self.style == Style::Bold && !tt.drops.is_empty();
        let park = match (in_step, best.in_at) {
            (true, Some(at)) => at,
            (true, None) => wo_booth::mix::in_point(tt, bars, on_the_drop),
            (false, _) => tt.first_downbeat.unwrap_or(0.0),
        };
        if best.shift != 0.0 {
            self.slots[to].shift = best.shift as f32;
            self.engine.deck(DeckId::new(to).unwrap()).set_shift(best.shift);
        }
        let td = self.engine.deck(DeckId::new(to).unwrap());
        td.play(false);
        td.unsync();
        td.seek(park);
        let run = transition::Running::new(kind, bars);
        let why = best.why.clone();
        self.mix = Some(Plan { from, to, kind, bars, out, length, in_step, turn: self.load_gen[to], started: false, begun: None, progress: 0.0, run, options, why, park });
        // the incoming waits silent, its bands and stems already where the move opens
        // them: nothing happens to the outgoing until the move starts
        self.open_move();
    }

    /// The transition is over: the old record stops and is put back to flat, the new
    /// one is the master, and the record after goes on the deck just freed.
    fn finish_mix(&mut self, from: usize, to: usize) {
        if let Some(m) = self.mix.as_ref() {
            self.recent.push(m.kind);
            if self.recent.len() > 8 {
                self.recent.remove(0);
            }
            let inn = self.slots[to].hands.cue.unwrap_or(0.0);
            self.mind.last = Some(autodj::LastMix {
                from: self.slots[from].record.clone(),
                to: self.slots[to].record.clone(),
                kind: m.kind,
                bars: m.bars,
                shift: self.slots[to].shift as f64,
                out: m.out,
                inn,
                why: m.why.clone(),
                steered: !self.mind.steer.neutral(),
                rating: None,
            });
            let id = self.slots[from].record.id;
            if !self.mind.played.contains(&id) {
                self.mind.played.push(id);
            }
            let t = self.slots[to].record.title.clone();
            self.note(autodj::LogKind::Done, format!("{t} has the room"));
        }
        self.mix = None;
        self.engine.deck(DeckId::new(from).unwrap()).play(false);
        self.plain(from);
        // the incoming keeps its bands and filter as the move left them (flat), its stems
        // back to its part
        self.slots[to].stems.mix = None;
        self.apply_part(to, parts::RAMP);
        self.full_law = false;
        self.apply_levels();
        self.engine.deck(DeckId::new(to).unwrap()).unsync();
        self.master = to;
        let next = self.take_next();
        self.load(from, next);
    }

    /// Mix now: a planned transition starts on the master's next bar.
    pub fn mix_now(&mut self) {
        let Some(m) = self.mix.as_ref().filter(|m| !m.started) else { return };
        let ft = &self.slots[m.from].timing;
        let heard = self.engine.deck(DeckId::new(m.from).unwrap()).position();
        let out = ft.grid.next_beat(heard + 2.0 * LEAD, 4).unwrap_or(heard + 2.0 * LEAD);
        if let Some(m) = self.mix.as_mut() {
            m.out = out;
        }
    }

    /// Not that: another record onto the incoming deck (the plan follows it).
    pub fn not_that(&mut self) {
        let Some(m) = self.mix.as_ref().filter(|m| !m.started) else { return };
        let to = m.to;
        self.mix = None;
        let mut next = self.take_next();
        if next.id == self.slots[to].record.id {
            next = self.take_next();
        }
        self.load(to, next);
    }

    /// A record's timing before its analysis comes: its grid, and for the synthesised
    /// records the sections they were made with.
    fn timing_of(&self, record: &Record, grid: Grid) -> Timing {
        let mut t = Timing::from_grid(grid, record.seconds as f64);
        if !record.key.is_empty() {
            t.camelot = Some(record.key.clone());
        }
        if let Audio::Synth { .. } = record.audio {
            let bar = |n: f64| n * 4.0 * 60.0 / record.bpm;
            t.mix_in = Some(bar(16.0));
            t.mix_out = Some(bar(112.0));
            t.drops = vec![bar(32.0), bar(80.0)];
            t.phrases = (0..8).map(|k| bar(16.0 * k as f64)).collect();
        }
        t
    }

    /// What changed the Desk from outside the window, counted ([Desk::tick] moves it).
    pub fn changes(&self) -> u64 {
        self.changes + self.covers.arrived.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// A record's cover for its sleeve, where it has one and it has come (asked for the
    /// first time it is wanted; the house's small one, kept on disk).
    pub fn cover(&mut self, r: &Record) -> Option<Arc<Cover>> {
        match (&r.audio, r.cover) {
            (Audio::House { id }, true) => self.covers.get(*id, self.house.as_ref()),
            (Audio::Usb { artwork: Some(art), .. }, true) => self.covers.get_file(r.id, art),
            _ => None,
        }
    }

    pub fn snapshot(&self) -> Snapshot {
        let view = |i: usize| {
            let s = &self.slots[i];
            let st = self.engine.deck(DeckId::new(i).unwrap()).read();
            let lr = self.engine.deck(DeckId::new(i).unwrap()).take_peak();
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
                peak_lr: lr,
                peak: lr.0.max(lr.1),
                audible: if st.playing {
                    let (ga, gb) = transition::law(self.crossfader, self.full_law);
                    (s.fader * s.fader * if i == 0 { ga } else { gb }).clamp(0.0, 1.0)
                } else {
                    0.0
                },
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
                part: s.stems.part,
                stems: s.stems.state.clone(),
                marks: [s.stems.state.ready(), !s.hands.grid.is_empty(), !s.timing.sections.is_empty(), s.vocals.as_ref().is_some_and(|v| v.bars.is_some())],
                loading: s.loader.as_ref().is_some_and(|h| !h.is_finished()),
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
        // the house's choices for after the master, where it has given them
        let chosen: Vec<&Record> = self
            .mind
            .choices
            .iter()
            .map(|c| &c.record)
            .filter(|r| r.id != decks[0].record.id && r.id != decks[1].record.id && !self.mind.played.contains(&r.id))
            .collect();
        if !chosen.is_empty() {
            up = chosen;
        }
        // a set playing: its records still to come, in order
        let from_set: Vec<&Record> = if self.set.playing {
            let at = self.set_view().at;
            self.set.built.as_ref().map(|st| st.slots.iter().skip(at).map(|x| &x.record).filter(|r| r.id != decks[0].record.id && r.id != decks[1].record.id).collect()).unwrap_or_default()
        } else {
            vec![]
        };
        if !from_set.is_empty() {
            up = from_set;
        }
        Snapshot {
            master_bpm,
            crossfader: self.crossfader,
            mix: self.mix.as_ref().map(|m| {
                let heard = self.engine.deck(DeckId::new(m.from).unwrap()).position();
                MixView {
                    from: m.from,
                    to: m.to,
                    kind: m.kind,
                    bars: m.bars,
                    mixing: m.started,
                    bar: m.progress * m.bars as f64,
                    starts_in: (m.out - heard).max(0.0),
                    swap_bar: transition::bass_swap_bar(m.kind, m.bars),
                    why: m.why.clone(),
                }
            }),
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
        // signed in: the house's shelf as it came (its search is the house's own); a
        // stick's records are searched here, signed in or not
        let on_usb = matches!(self.library.shelf, Shelf::Usb { .. });
        let (source, f) = match (on_usb, self.house.is_some()) {
            (true, _) => (&self.library.rows, filter.to_lowercase()),
            (false, true) => (&self.library.rows, String::new()),
            (false, false) => (&self.rows, filter.to_lowercase()),
        };
        let mut rows: Vec<Row> = source
            .iter()
            .filter(|r| f.is_empty() || r.title.to_lowercase().contains(&f) || r.artist.to_lowercase().contains(&f))
            .map(|r| Row {
                record: r.clone(),
                fits: records::fits(r, master_bpm, &key),
                on_deck: (0..2).find(|&d| self.slots[d].record.id == r.id),
                note: self.library.notes.get(&r.id).cloned(),
            })
            .collect();
        if !matches!(self.library.shelf, Shelf::Fits { .. } | Shelf::Queue | Shelf::Similar { .. } | Shelf::Check | Shelf::Usb { playlist: Some(_), .. }) || (self.house.is_none() && !on_usb) {
            rows.sort_by_key(|r| (r.on_deck.is_none(), std::cmp::Reverse(r.fits)));
        }
        rows
    }

    /// A deck's waveform lane around `heard`, `width` px wide with the playhead in the
    /// middle, beats `beat_px` apart, about `step` px a bin. A bin is a power of two of the
    /// record's columns and starts on a multiple of it: the same columns make the same bin
    /// every frame, wherever the playhead is, so the picture scrolls without re-shaping (a
    /// zoom changes the bins only where it crosses a power of two).
    pub fn lane_wave(&self, deck: usize, heard: f64, width: f32, step: f32, beat_px: f32) -> LaneWave {
        let s = &self.slots[deck];
        let spb = self.spb(deck);
        let px_per_s = beat_px as f64 / spb;
        let px_per_col = px_per_s / wo_wave::RATE;
        let want = (step as f64 / px_per_col).max(1.0);
        let k = 1usize << (want.log2().round().clamp(0.0, 12.0) as u32);
        let half = width as f64 / 2.0;
        let x_of = |t: f64| (half + (t - heard) * px_per_s) as f32;
        let t0 = heard - half / px_per_s;
        let first = ((t0 * wo_wave::RATE) / k as f64).floor() as i64 * k as i64;
        let x0 = x_of(first as f64 / wo_wave::RATE);
        let bin_w = (k as f64 * px_per_col) as f32;
        let n = ((width - x0) / bin_w).ceil().max(0.0) as usize + 1;
        let wave = s.wave.lock().unwrap();
        let bins = wave.bins(first, k, n);
        let length = if s.record.seconds > 0 { s.record.seconds as f64 } else { wave.seconds() };
        let arriving = (!wave.done).then(|| x_of(wave.seconds()));
        drop(wave);
        let t1 = t0 + width as f64 / px_per_s;
        let mut lines = Lines::default();
        let grid = &s.hands.grid;
        let markers = &s.timing.markers;
        let first_beat = grid.beats.partition_point(|&b| b < t0);
        for (i, &b) in grid.beats.iter().enumerate().skip(first_beat) {
            if b > t1 {
                break;
            }
            let x = x_of(b);
            match bar_kind(grid, markers, i) {
                None => lines.beats.push(x),
                Some((bar, BarKind::Four)) => lines.fours.push((x, bar)),
                Some((_, BarKind::Two)) => lines.twos.push(x),
                Some((_, BarKind::Bar)) => lines.bars.push(x),
            }
        }
        for (i, p) in s.hands.pads.iter().enumerate() {
            let Some(p) = p else { continue };
            if p.at >= t0 && p.at <= t1 {
                lines.pads.push((x_of(p.at), i, *p));
            }
        }
        LaneWave { bins, x0, bin_w, px_per_s, heard, lines, start: x_of(0.0), end: x_of(length), arriving }
    }

    /// Every second bar of a deck's record, for its overview: when, and whether it starts
    /// a four-bar group (else it starts the group's second half).
    pub fn two_bars(&self, deck: usize) -> Vec<(f64, bool)> {
        let s = &self.slots[deck];
        let grid = &s.hands.grid;
        (0..grid.beats.len())
            .filter_map(|i| match bar_kind(grid, &s.timing.markers, i)? {
                (_, BarKind::Four) => Some((grid.beats[i], true)),
                (_, BarKind::Two) => Some((grid.beats[i], false)),
                _ => None,
            })
            .collect()
    }

    /// The whole record in `n` bins, against its own ceiling (None where it has not come in).
    pub fn overview(&self, deck: usize, n: usize) -> Vec<Option<Bin>> {
        let s = &self.slots[deck];
        let wave = s.wave.lock().unwrap();
        let len = if s.record.seconds > 0 { s.record.seconds as f64 } else { wave.seconds() };
        wave.overview(len, n)
    }

    /// How much of a deck's record has come in (its waveform's columns; changes as it
    /// decodes): what an overview's picture is kept by.
    pub fn wave_len(&self, deck: usize) -> usize {
        self.slots[deck].wave.lock().unwrap().cols.len()
    }

    /// A deck's record's sections and drops (the house's structure; empty without it).
    pub fn form(&self, deck: usize) -> Form {
        let t = &self.slots[deck].timing;
        Form { sections: t.sections.iter().map(|x| (x.label.clone(), x.start, x.end)).collect(), drops: t.drops.clone() }
    }

    /// Where `t` falls on a deck's grid: how far into its beat (0..1) and which beat of its
    /// bar (0..3). None without a grid, or outside it.
    pub fn beat_at(&self, deck: usize, t: f64) -> Option<(f64, usize)> {
        let g = &self.slots[deck].hands.grid;
        let i = g.beats.partition_point(|&b| b <= t);
        if i == 0 || i >= g.beats.len() {
            return None;
        }
        let (a, b) = (g.beats[i - 1], g.beats[i]);
        let beat = (i - 1 + 4 - g.bar_one % 4) % 4;
        Some((((t - a) / (b - a).max(1e-6)).clamp(0.0, 1.0), beat))
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
        let was = self.slots[d].hands.pads[n];
        self.hands(d, |h, t| h.pad(n, t));
        // a pad set here by a hand is the record's from now on (kept by the house)
        if was.is_none()
            && let Some(p) = self.slots[d].hands.pads[n]
        {
            self.keep_pad(d, n, Some(p.at));
        }
    }

    pub fn clear_pad(&mut self, d: usize, n: usize) {
        self.slots[d].hands.clear_pad(n);
        self.keep_pad(d, n, None);
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
    /// The record moved to `at` seconds (the overview clicked).
    pub fn seek_to(&mut self, d: usize, at: f64) {
        let len = self.slots[d].wave.lock().unwrap().seconds().max(self.slots[d].record.seconds as f64);
        self.engine.deck(DeckId::new(d).unwrap()).seek(at.clamp(0.0, len.max(0.0)));
    }

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
        self.stage.set_show_house(None);
        self.house = None;
        self.stage.set_house(None);
        self.library = Library::default();
        self.covers.forget();
    }

    /// Shows a shelf: everything, a playlist, a search (an empty search is everything).
    pub fn open_shelf(&mut self, shelf: Shelf) {
        let shelf = match shelf {
            Shelf::Search(q) if q.trim().is_empty() => Shelf::All,
            s => s,
        };
        if let Shelf::Usb { root, playlist, .. } = &shelf {
            self.shelf_gen += 1;
            self.more_asked = None;
            self.library.rows = self.usb_rows(root, playlist.as_ref().map(|p| p.0));
            self.library.total = self.library.rows.len() as i64;
            self.library.shelf = shelf;
            self.library.loading = false;
            self.library.error = None;
            self.library.notes.clear();
            self.library.checked.clear();
            return;
        }
        if shelf == Shelf::Queue {
            self.shelf_gen += 1;
            self.library.shelf = Shelf::Queue;
            self.library.loading = false;
            self.library.rows = self.hand_queue.clone();
            self.library.total = self.hand_queue.len() as i64;
            return;
        }
        let Some(house) = &self.house else { return };
        self.shelf_gen += 1;
        self.more_asked = None;
        self.library.shelf = shelf.clone();
        self.library.loading = true;
        library::fetch_shelf(&self.done_tx, house, shelf, self.shelf_gen);
    }

    /// A stick's records, all of them or a playlist's, in rekordbox's order.
    fn usb_rows(&self, root: &std::path::Path, playlist: Option<u32>) -> Vec<Record> {
        let Some(stick) = self.sticks.iter().find(|s| s.root == root) else { return vec![] };
        let ids: Vec<u32> = match playlist {
            Some(p) => stick.playlists.iter().find(|l| l.id == p).map(|l| l.tracks.clone()).unwrap_or_default(),
            None => stick.tracks.iter().map(|t| t.id).collect(),
        };
        ids.iter().filter_map(|&id| stick.track(id)).map(|t| Record::from_usb(&stick.name, t)).collect()
    }

    /// The sticks plugged in changed: the crate's list of them, and its shelf where that
    /// was a stick's (read again, or gone back to all records where it went).
    fn got_sticks(&mut self, sticks: Vec<Arc<wo_usb::Stick>>) {
        self.sticks = sticks;
        self.library.sticks = self.sticks.iter().map(|s| library::StickView::of(s)).collect();
        if let Shelf::Usb { root, .. } = &self.library.shelf {
            let shelf = self.library.shelf.clone();
            if self.sticks.iter().any(|s| &s.root == root) {
                self.open_shelf(shelf);
            } else {
                self.library.rows.clear();
                self.library.total = 0;
                self.library.shelf = Shelf::All;
                self.open_shelf(Shelf::All);
            }
        }
        self.changes += 1;
    }

    /// The sticks read now rather than at the watcher's next look, the first one's first
    /// playlist open, its first two records on the decks with `load` — or the records
    /// rekordbox numbers `ids` (screenshots, trying a stick out). Whether there was a stick.
    pub fn open_first_stick(&mut self, load: bool, ids: &[u32]) -> bool {
        let sticks: Vec<Arc<wo_usb::Stick>> = wo_usb::find().iter().filter_map(|r| wo_usb::Stick::open(r).ok()).map(Arc::new).collect();
        self.got_sticks(sticks);
        let Some(s) = self.sticks.first().cloned() else { return false };
        let playlist = s.playlists.first().map(|p| (p.id, p.name.clone()));
        self.open_shelf(Shelf::Usb { root: s.root.clone(), stick: s.name.clone(), playlist });
        let records: Vec<Record> = if ids.is_empty() {
            self.library.rows.iter().take(2).cloned().collect()
        } else {
            ids.iter().filter_map(|&id| s.track(id)).map(|t| Record::from_usb(&s.name, t)).collect()
        };
        if load {
            for (d, r) in records.into_iter().take(2).enumerate() {
                self.load(d, r);
            }
        }
        true
    }

    /// The rekordbox sticks plugged in (the crate's list of them is [Library::sticks]).
    pub fn sticks(&self) -> &[Arc<wo_usb::Stick>] {
        &self.sticks
    }

    fn signed_in(&mut self, house: wo_house::House) {
        self.covers.forget();
        library::fetch_playlists(&self.done_tx, &house);
        self.stage.set_house(Some(wo_wire::House { server: house.session.server.clone(), token: house.session.token.clone() }));
        self.stage.set_show_house(Some(house.clone()));
        self.house = Some(house);
        self.open_shelf(Shelf::All);
    }

    fn handle(&mut self, done: library::Done) {
        use library::Done;
        match done {
            Done::SignedIn(Ok(house)) => {
                self.library.signing_in = false;
                self.signed_in(*house);
            }
            Done::SignedIn(Err(e)) => {
                self.library.signing_in = false;
                self.library.error = Some(e);
            }
            Done::Shelf { turn, rows, notes, checked } if turn == self.shelf_gen => {
                self.library.loading = false;
                match rows {
                    Ok((rows, total)) => {
                        self.library.rows = rows;
                        self.library.total = total;
                        self.library.error = None;
                        self.library.notes = notes.into_iter().collect();
                        self.library.checked = checked.into_iter().collect();
                    }
                    Err(e) => self.library.error = Some(e),
                }
            }
            Done::Shelf { .. } => {}
            Done::More { turn, rows } if turn == self.shelf_gen => {
                if let Ok((rows, total)) = rows {
                    let have: std::collections::HashSet<i64> = self.library.rows.iter().map(|r| r.id).collect();
                    self.library.rows.extend(rows.into_iter().filter(|r| !have.contains(&r.id)));
                    self.library.total = total;
                }
            }
            Done::More { .. } => {}
            Done::Playlists(Ok(lists)) => self.library.playlists = lists,
            Done::Playlists(Err(e)) => self.library.error = Some(e),
            Done::Analysed { slot, turn, result } if turn == self.load_gen[slot] => match result {
                Ok(a) => {
                    let a = *a;
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
                    hands.cue = a.cue;
                    let s = &mut self.slots[slot];
                    s.hands = hands;
                    s.timing = a.timing;
                    s.vocals = a.vocals;
                    if let Some(k) = a.camelot {
                        s.record.key = k;
                    }
                    if let Some(b) = a.bpm {
                        s.record.bpm = b;
                    }
                    if s.timing.camelot.is_none() && !s.record.key.is_empty() {
                        s.timing.camelot = Some(s.record.key.clone());
                    }
                    // a CDJ parks a record it loads on its first memory cue: so does the deck,
                    // where no hand has moved it yet
                    if let Some(at) = a.cue {
                        let deck = self.engine.deck(DeckId::new(slot).unwrap());
                        if !deck.read().playing && deck.position() < 0.5 {
                            deck.seek(at);
                        }
                    }
                }
                Err(e) => self.library.error = Some(format!("{}: {e}", self.slots[slot].record.title)),
            },
            Done::Analysed { .. } => {}
            Done::Cover { slot, turn, id, cover } if turn == self.load_gen[slot] => self.stage.cover(slot, id, cover),
            Done::Cover { .. } => {}
            Done::LoadFailed { slot, turn, why } if turn == self.load_gen[slot] => {
                self.library.error = Some(format!("{}: {why}", self.slots[slot].record.title));
            }
            Done::LoadFailed { .. } => {}
            Done::Stems { slot, turn, got } if turn == self.load_gen[slot] => self.got_stems(slot, got),
            Done::Sticks(sticks) => self.got_sticks(sticks),
            Done::Taste(t) => {
                if t.count > 0 {
                    let fav = t.favourite().map(|k| format!(" · you like a {}", k.word().to_lowercase())).unwrap_or_default();
                    self.note(autodj::LogKind::Plan, format!("Read {} of your words on its mixes{fav}", t.count));
                }
                self.mind.taste = t;
            }
            Done::Choices { turn, got } => self.got_choices(turn, got),
            Done::Set { turn, got, rest } => self.got_set(turn, got, rest),
            Done::Stems { .. } => {}
        }
    }

    // ---- controllers and the keyboard

    /// The controllers found (and any that could not be opened, with why).
    pub fn controllers(&self) -> Vec<wo_control::Controller> {
        self.controls.as_ref().map(|c| c.controllers()).unwrap_or_default()
    }

    /// The controllers page's monitor: the packets as they came and were read, and what
    /// the Desk did with each control moved — oldest first.
    pub fn control_monitor(&self) -> (Vec<wo_control::Packet>, Vec<ControlLine>) {
        (self.controls.as_ref().map(|c| c.monitor()).unwrap_or_default(), self.control_lines.iter().cloned().collect())
    }

    pub fn clear_control_monitor(&mut self) {
        if let Some(c) = &self.controls {
            c.clear_monitor();
        }
        self.control_lines.clear();
    }

    /// The layouts the Desk knows: a controller one of them names is taken up by itself.
    pub fn controller_layouts(&self) -> Vec<wo_control::Layout> {
        match &self.controls {
            Some(c) => c.layouts().to_vec(),
            None => wo_control::layout::bundled(),
        }
    }

    /// What the controllers asked of the crate since the last call (browse, load).
    pub fn take_crate_actions(&mut self) -> Vec<wo_control::Action> {
        std::mem::take(&mut self.for_the_crate)
    }

    fn controllers_tick(&mut self) {
        let events = self.controls.as_ref().map(|c| c.poll()).unwrap_or_default();
        if !events.is_empty() {
            self.changes += 1;
        }
        for e in events {
            let at = self.positions();
            let actions = self.binding.handle(&e, &at);
            // the controllers page's monitor: what the binding made of it
            if self.control_lines.len() >= wo_control::MONITOR {
                self.control_lines.pop_front();
            }
            self.control_lines.push_back(ControlLine { at: Instant::now(), id: e.id.clone(), value: e.value, did: actions.iter().map(|a| format!("{a:?}")).collect() });
            for a in actions {
                self.act(a);
            }
        }
        // the jog wheel settles when it stops turning
        for d in 0..2 {
            if self.jog[d].1.is_some_and(|t| t.elapsed() > Duration::from_millis(90)) {
                self.jog[d] = (0.0, None);
                let nudge = self.slots[d].hands.nudging;
                self.engine.deck(DeckId::new(d).unwrap()).bend(1.0 + nudge as f64 * wo_booth::NUDGE);
            }
        }
        self.lights();
    }

    /// Where the booth's knobs and faders are, for the controllers' soft takeover.
    fn positions(&self) -> wo_control::Positions {
        wo_control::Positions {
            crossfader: self.crossfader,
            fader: [self.slots[0].fader, self.slots[1].fader],
            filter: [self.slots[0].filter, self.slots[1].filter],
            eq: [self.slots[0].eq, self.slots[1].eq],
            pitch: [self.slots[0].hands.pitch, self.slots[1].hands.pitch],
        }
    }

    /// One thing a controller (or a key) asked for.
    pub fn act(&mut self, a: wo_control::Action) {
        use wo_control::Action as A;
        match a {
            A::PlayPause(d) => self.toggle_play(d),
            A::CueDown(d) => self.cue_down(d),
            A::CueUp(d) => self.cue_up(d),
            A::Stop(d) => {
                let cue = self.slots[d].hands.cue.unwrap_or(0.0);
                let deck = self.engine.deck(DeckId::new(d).unwrap());
                deck.play(false);
                deck.seek(cue);
            }
            A::Sync(d) => self.toggle_sync(d),
            A::Keylock(d) => self.toggle_keylock(d),
            A::PitchReset(d) => self.set_pitch(d, 0.0),
            A::CyclePitchRange => {
                self.cycle_range(0);
                self.cycle_range(1);
            }
            A::Pitch(d, v) => self.set_pitch(d, v),
            A::Jog { deck, ticks, scratch, shift } => self.jog(deck, ticks, scratch, shift),
            A::Jump(d, beats) => self.jump(d, beats),
            A::Fader(d, v) => self.set_fader(d, v),
            A::Filter(d, v) => self.set_filter(d, v),
            A::Eq(d, band, v) => self.set_eq(d, band, v),
            A::KillToggle(d, band) => self.kill(d, band),
            A::Pad(d, n) => self.pad(d, n),
            A::ClearPad(d, n) => self.clear_pad(d, n),
            A::LoopIn(d) => self.loop_in(d),
            A::LoopOut(d) => self.loop_out(d),
            A::HalveLoop(d) => self.halve_loop(d),
            A::Unloop(d) => self.unloop(d),
            A::Crossfader(x) => {
                // a hand on the crossfader mid-mix takes the mix over
                if self.mix.as_ref().is_some_and(|m| m.started) {
                    self.set_auto(false);
                }
                self.set_crossfader(x);
            }
            a @ (A::Load(_) | A::Browse(..)) => self.for_the_crate.push(a),
            A::Show(cue) => {
                use wo_control::ShowCue as C;
                let v = self.stage.view();
                self.show(match cue {
                    C::Previous => ShowHand::Previous,
                    C::Next => ShowHand::Next,
                    C::Hit => ShowHand::Hit,
                    C::Blackout => ShowHand::Blackout(!v.blackout),
                    C::Freeze => ShowHand::Freeze(!v.freeze),
                    C::Strobe(on) => ShowHand::Strobe(on),
                });
            }
        }
    }

    /// A band killed, or back to flat.
    pub fn kill(&mut self, d: usize, band: usize) {
        let v = if self.slots[d].eq[band] <= 0.01 { 0.5 } else { 0.0 };
        self.set_eq(d, band, v);
    }

    /// The jog wheel turned `ticks`: a parked record is moved (20 ms a tick, 250 with
    /// shift); a playing one bends with the speed of the hand (much harder in scratch).
    pub fn jog(&mut self, d: usize, ticks: f64, scratch: bool, shift: bool) {
        let deck = self.engine.deck(DeckId::new(d).unwrap());
        if !deck.read().playing {
            deck.seek((deck.position() + ticks * if shift { 0.25 } else { 0.02 }).max(0.0));
            return;
        }
        let v = self.jog[d].0 * 0.6 + ticks;
        self.jog[d] = (v, Some(Instant::now()));
        let k = if scratch { 0.06 } else { 0.008 };
        deck.bend((1.0 + k * v).clamp(0.5, 2.0));
    }

    /// The record moved by `secs` (a nudge by ear).
    pub fn nudge_by(&mut self, d: usize, secs: f64) {
        let deck = self.engine.deck(DeckId::new(d).unwrap());
        deck.seek((deck.position() + secs).max(0.0));
    }

    /// The master deck's index.
    pub fn master(&self) -> usize {
        self.master
    }

    pub fn crossfader(&self) -> f32 {
        self.crossfader
    }

    /// Starts deck `d` in step with the other, on its beat.
    pub fn start_in_step(&mut self, d: usize) {
        let master = DeckId::new(1 - d).unwrap();
        self.engine.deck(DeckId::new(d).unwrap()).start_with(master, 4, None, 0.0);
    }

    /// The controllers' lights as the decks are (only what changed is sent).
    fn lights(&mut self) {
        let Some(controls) = &self.controls else { return };
        // a controller come (or come back): every light again
        let n = controls.controllers().len();
        if n != self.lit_for {
            self.lit.clear();
            self.lit_for = n;
        }
        let mut want = vec![("mixer.scratch".to_owned(), self.binding.scratch)];
        for d in 0..2 {
            let st = self.engine.deck(DeckId::new(d).unwrap()).read();
            let side = ["a", "b"][d];
            let on_cue = self.slots[d].hands.cue.is_some_and(|c| (c - st.heard).abs() < 0.06);
            want.push((format!("deck.{side}.play"), st.playing));
            want.push((format!("deck.{side}.cue"), on_cue && !st.playing));
            want.push((format!("deck.{side}.sync"), st.synced));
            want.push((format!("deck.{side}.keylock"), self.slots[d].keylock));
        }
        for (id, on) in want {
            if self.lit.get(&id) != Some(&on) {
                controls.light(&id, on);
                self.lit.insert(id, on);
            }
        }
    }

    pub fn set_auto(&mut self, on: bool) {
        self.auto = on;
    }

    // ---- the stage

    /// Starts the show's window (unless one is reading already).
    pub fn open_stage(&mut self) {
        self.stage.open();
    }

    /// Closes the window the Desk started.
    pub fn close_stage(&mut self) {
        self.stage.close();
    }

    pub fn stage(&self) -> StageView {
        self.stage.view()
    }

    /// The stage's picture, and its count (a new count is a new picture).
    pub fn stage_thumb(&self) -> Option<(u64, std::sync::Arc<Thumb>)> {
        self.stage.thumb()
    }

    /// The Rust stage (apps/wetowl-stage, the Desk directing) instead of the WetOwl app's:
    /// kept for the next time; a window open now starts again as the other.
    pub fn set_rust_stage(&mut self, on: bool) {
        self.stage.set_rust(on);
    }

    /// MilkDrop as the Desk's director has it (the Rust stage's), with what the stage said.
    pub fn milk(&mut self) -> MilkView {
        self.stage.milk()
    }

    /// The hands on MilkDrop.
    /// The show as the Show page draws it, where the Desk directs (the Rust stage).
    pub fn show_board(&mut self) -> Option<ShowBoard> {
        if !self.stage().rust {
            return None;
        }
        self.stage.board()
    }

    pub fn milk_hand(&mut self, h: MilkHand) {
        self.stage.milk_hand(h);
    }

    /// The show's rotation (the Rust stage's: the Desk directs it).
    pub fn show_rotation(&mut self) -> Option<RotationView> {
        self.stage().rust.then(|| self.stage.rotation())
    }

    /// An edit of the show's rotation, a scene's page, the finish, kept.
    pub fn show_edit(&mut self, e: ShowEdit) {
        self.stage.edit(e);
    }

    /// A scene's page (`all`: its styles and backgrounds that are off in the grid too) — on
    /// the Rust stage only.
    pub fn show_scene(&mut self, id: &str, all: bool) -> Option<ScenePage> {
        if !self.stage().rust {
            return None;
        }
        self.stage.scene_page(id, all)
    }

    /// One square of a scene's grid, each mask and blend under the effect `fx`.
    pub fn show_variants(&mut self, scene: &str, style: &str, ground: &str, fx: &str) -> Option<Variants> {
        self.stage.variants(scene, style, ground, fx)
    }

    /// The dancers' moves, with the hands' say on each.
    pub fn show_moves(&mut self) -> MovesView {
        self.stage.moves()
    }

    /// The finish over every scene, the blend's strength, the slit-scan's knobs.
    pub fn show_finish(&mut self) -> FinishView {
        self.stage.finish()
    }

    /// The show's sets: this Desk's and the shared ones, the one on (the shared ones listed
    /// again now and then while this is asked).
    pub fn show_sets(&mut self) -> SetsView {
        self.stage.sets()
    }

    /// The favourites, the one on, the one just kept.
    pub fn show_faves(&mut self) -> FavesView {
        self.stage.faves()
    }

    /// The library's presets whose names have `query` in them, up to `most`.
    pub fn milk_search(&mut self, query: &str, most: usize, filter: MilkFilter) -> Vec<MilkRow> {
        self.stage.milk_search(query, most, filter)
    }

    /// Where a stage window started by hand connects (`wetowl --stage <url>`).
    pub fn stage_url(&mut self) -> Option<String> {
        self.stage.url()
    }

    /// A hand on the show: the stage's director takes it.
    pub fn show(&mut self, h: ShowHand) {
        self.stage.hand(h);
    }

    /// A frame to the stage, when one reads and one is due: the decks as the ear hears
    /// them, what the engine heard of each since the last frame, the mix on.
    fn feed_stage(&mut self) {
        if !self.stage.due() {
            return;
        }
        // read as the v1 show reads its engine: up to the clock plus the output's
        // latency (40 ms at most), so the picture, a frame late to the eye, keeps up
        let to = self.engine.now() + self.engine.latency().min(0.04);
        let from = match self.stage.heard_to {
            Some(f) if f <= to && to - f < 0.25 => f,
            _ => to - 1.0 / 60.0,
        };
        self.stage.heard_to = Some(to);
        let audio = |f: &wo_engine::Features| wo_wire::Audio {
            sub: f.sub,
            low: f.low,
            mid: f.mid,
            high: f.high,
            air: f.air,
            kick: f.kick,
            snare: f.snare,
            hat: f.hat,
            onset: f.onset,
        };
        let x = self.crossfader;
        let deck = |i: usize| {
            let s = &self.slots[i];
            let id = DeckId::new(i).unwrap();
            let e = self.engine.deck(id);
            let st = e.read();
            let g = if i == 0 { (2.0 * (1.0 - x)).min(1.0) } else { (2.0 * x).min(1.0) };
            let eq = eq_db(s.eq);
            let k = (s.filter - 0.5) * 2.0;
            wo_wire::Deck {
                // a record of the house's (the WetOwl app's fetched copies are too)
                track_id: (s.record.id > 0 && !matches!(s.record.audio, Audio::Synth { .. })).then_some(s.record.id),
                title: s.record.title.clone(),
                artist: s.record.artist.clone(),
                playing: st.playing,
                position_ms: e.position() * 1000.0,
                rate: if st.playing { st.rate } else { 0.0 },
                level: (s.fader * s.fader * g).clamp(0.0, 1.0),
                eq: wo_wire::EqDb { low: eq.low, mid: eq.mid, high: eq.high },
                filter: if k.abs() < 0.04 { 0.0 } else { k },
                looping: s.hands.looped.is_some(),
                heard: self.engine.features(Bus::Deck(id), from, to).as_ref().map(audio),
            }
        };
        let heard = self.engine.features(Bus::Master, from, to).map(|m| wo_wire::Heard { master: audio(&m), spectrum: m.spectrum.to_vec() });
        let frame = wo_wire::Frame { a: deck(0), b: deck(1), heard, mix: self.show_mix() };
        self.stage.say(&wo_wire::frame(&frame));
        // the Desk directs (ShowWire v2): each deck's record as facts when it changes, then
        // the director's cue — the Rust stage draws it, a v1 stage directs itself
        for i in 0..2 {
            let s = &self.slots[i];
            let t = &s.timing;
            let key = (s.record.id, s.record.title.clone(), t.grid.beats.len(), t.grid.bar_one, t.sections.len(), t.energy.len(), t.drops.len());
            self.stage.record(i, key, || show::facts_of(&s.record, t));
        }
        self.stage.direct(&frame);
        // and the room's sound over the same span, for MilkDrop: what the master
        // plays, every fader, EQ and kill in it (v1's stage read the records instead)
        let rate = self.engine.rate();
        let n = (((to - from) * rate as f64).round() as usize).min(rate as usize / 4);
        if n > 0 {
            let mut buf = vec![0.0f32; n];
            if self.engine.scope(Bus::Master, to, &mut buf) == n {
                self.stage.say_pcm(wo_wire::pcm(rate, &buf));
            }
        }
    }

    /// The Auto DJ's transition as the show sees it: on while it is being made, armed
    /// in the bar before it goes (as the v1 booth arms a mix).
    fn show_mix(&self) -> wo_wire::Mix {
        let Some(m) = self.mix.as_ref().filter(|_| self.auto) else { return wo_wire::Mix::default() };
        let name = |d: usize| Some(if d == 0 { "A" } else { "B" }.to_owned());
        let kind = Some(format!("{:?}", m.kind).to_lowercase());
        if m.begun.is_some() {
            return wo_wire::Mix { on: true, kind, from: name(m.from), to: name(m.to), bars: m.bars, k: m.progress, ..Default::default() };
        }
        let d = self.engine.deck(DeckId::new(m.from).unwrap());
        let rate = d.read().rate.max(0.01);
        let wait = (m.out - d.position()) / rate;
        if wait > 4.0 * self.spb(m.from) / rate {
            return wo_wire::Mix::default();
        }
        wo_wire::Mix {
            armed: true,
            kind,
            from: name(m.from),
            to: name(m.to),
            bars: m.bars,
            starts_in_ms: Some((wait.max(0.0) * 1000.0) as i64),
            ..Default::default()
        }
    }

    // ---- inside

    fn apply_levels(&self) {
        let (ga, gb) = transition::law(self.crossfader, self.full_law);
        for (d, g) in [(0, ga), (1, gb)] {
            let s = &self.slots[d];
            // the hands' gain (±12 dB) over the record brought to the house's loudness
            let trim = 10f32.powf((s.gain - 0.5) * 24.0 / 20.0) * s.record.loudness.trim();
            self.engine.deck(DeckId::new(d).unwrap()).set_level(s.fader * s.fader * g * trim, 0.03);
        }
    }

    fn spb(&self, deck: usize) -> f64 {
        self.slots[deck].hands.grid.spb().unwrap_or(60.0 / self.slots[deck].record.bpm.max(1.0))
    }

    fn base_bpm(&self, deck: usize) -> f64 {
        60.0 / self.spb(deck)
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

#[cfg(test)]
mod bar_kind_tests {
    use super::{BarKind, bar_kind};
    use wo_booth::Grid;

    fn kinds(grid: &Grid, markers: &[f64]) -> String {
        (0..grid.beats.len())
            .filter_map(|i| bar_kind(grid, markers, i))
            .map(|(_, k)| match k {
                BarKind::Four => 'F',
                BarKind::Two => 'T',
                BarKind::Bar => '.',
            })
            .collect()
    }

    #[test]
    fn every_second_bar_is_marked_and_every_fourth_starts_a_group() {
        let grid = Grid::new((0..64).map(|i| i as f64 * 0.5).collect(), 0);
        assert_eq!(kinds(&grid, &[]), "F.T.F.T.F.T.F.T.");
        // the grid's one on its third beat: the beats before it are not a bar
        let late = Grid::new((0..66).map(|i| i as f64 * 0.5).collect(), 2);
        assert_eq!(bar_kind(&late, &[], 0), None);
        assert_eq!(bar_kind(&late, &[], 2), Some((1, BarKind::Four)));
        assert_eq!(bar_kind(&late, &[], 10), Some((3, BarKind::Two)));
    }

    #[test]
    fn the_houses_markers_lead_and_the_twos_split_their_groups() {
        // bars every 2 s; the house's groups start at bar 2 (2 s), then six bars on (14 s),
        // then four (22 s), each marker a little off its bar
        let grid = Grid::new((0..64).map(|i| i as f64 * 0.5).collect(), 0);
        let markers = [2.03, 13.96, 22.0];
        // bar 1 is before the first marker: counted back from it (three bars short of a group);
        // past the last one only the house's markers start groups, so every second bar is a two
        assert_eq!(kinds(&grid, &markers), ".F.T.T.F.T.F.T.T");
    }
}
