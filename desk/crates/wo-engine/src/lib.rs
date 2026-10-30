//! The booth engine (`app/native/engine`), safe.
//!
//! One engine runs at a time ([`Engine::start`]); it stops when the last handle goes.
//! A [`Source`] is a decoded record in the engine's memory, owned by whoever fills it:
//! appending needs `&mut`, and only dropping it lets the engine free it, so a record
//! can never be freed under the thread still decoding into it (the C API would let
//! that happen). Decks are handles ([`Engine::deck`]); their commands reach the audio
//! thread at the start of its next block, in the order given, from any thread.
//!
//! Times are seconds. A deck's "source" time is the record's own, as its beat grid
//! counts it; "heard" is where the record is at the moment the sound card plays it.
use std::ffi::CStr;
use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use wo_engine_sys as sys;

pub use sys::{WE_DECKS as DECKS, WE_SOURCES as SOURCE_SLOTS, WE_SPECTRUM as SPECTRUM};

static RUNNING: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, PartialEq)]
pub enum Error {
    /// Another engine is running in this process.
    AlreadyRunning,
    /// The sound card (or the engine) would not start: what it said.
    Start(String),
    /// Rendering on demand is for an engine started [`Output::Offline`].
    NotOffline,
    /// The engine had no memory for a source, or for more of one.
    OutOfMemory,
    /// Samples that are not whole frames, or buffers of the wrong length.
    Shape(&'static str),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::AlreadyRunning => write!(f, "an engine is running already"),
            Error::Start(why) => write!(f, "the engine would not start: {why}"),
            Error::NotOffline => write!(f, "only an offline engine renders on demand"),
            Error::OutOfMemory => write!(f, "the engine is out of memory"),
            Error::Shape(why) => write!(f, "{why}"),
        }
    }
}

impl std::error::Error for Error {}

/// Where the engine's sound goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Output {
    /// The default sound card, on its own audio thread.
    Device,
    /// No sound card: [`Engine::render`] renders blocks on demand (tests, offline renders).
    Offline,
}

/// Which of the engine's four decks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DeckId(u8);

impl DeckId {
    pub const A: DeckId = DeckId(0);
    pub const B: DeckId = DeckId(1);
    pub const C: DeckId = DeckId(2);
    pub const D: DeckId = DeckId(3);
    pub const ALL: [DeckId; DECKS] = [Self::A, Self::B, Self::C, Self::D];

    pub fn new(index: usize) -> Option<DeckId> {
        (index < DECKS).then_some(DeckId(index as u8))
    }

    pub fn index(self) -> usize {
        self.0 as usize
    }

    fn raw(self) -> i32 {
        self.0 as i32
    }
}

/// What is measured: one deck's output (post fader) or the master.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Bus {
    Deck(DeckId),
    Master,
}

impl Bus {
    fn raw(self) -> i32 {
        match self {
            Bus::Deck(d) => d.raw(),
            Bus::Master => sys::WE_MASTER,
        }
    }
}

/// Channels a source holds: a record (stereo), or its stems (drums, bass+other, vocals).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Channels {
    Mono = 1,
    Stereo = 2,
    Stems = 6,
}

/// Which of Rubber Band's engines keylocked decks use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stretch {
    /// R3: the better sound, the heavier load.
    Finer,
    /// R2: what the engine falls back to on a machine that cannot carry R3.
    Faster,
}

/// How the audio thread keeps up.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Load {
    /// The time a call took over the time it had, averaged over about a second.
    pub average: f64,
    /// The worst since the last ask.
    pub worst: f64,
    /// Calls that ran late (each a gap in the sound) since the start.
    pub late: i64,
    /// Keylocked decks moved to the faster stretcher for it.
    pub faster: bool,
    /// The device period asked for, frames.
    pub period: i32,
}

/// What a deck is doing, as of `at`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct DeckState {
    /// Source time heard at `at`.
    pub heard: f64,
    /// [`Engine::now`] time of it.
    pub at: f64,
    /// Source seconds per second now (rate × bend × the sync's trim).
    pub rate: f64,
    /// Source seconds decoded so far.
    pub length: f64,
    /// The loop, when looping.
    pub looped: Option<(f64, f64)>,
    /// Synced: seconds its beat is off the master's, heard.
    pub phase_error: f64,
    /// Counts every jump, seek and loop wrap.
    pub moves: i64,
    pub playing: bool,
    pub synced: bool,
    pub braking: bool,
    /// Times it ran off the end of its record.
    pub ended: i32,
    /// Peaks since the last read.
    pub peak: (f32, f32),
}

impl From<sys::we_deck_state> for DeckState {
    fn from(s: sys::we_deck_state) -> Self {
        DeckState {
            heard: s.heard,
            at: s.at,
            rate: s.rate,
            length: s.length,
            looped: (s.looping != 0).then_some((s.loop_a, s.loop_b)),
            phase_error: s.phase_error,
            moves: s.moves,
            playing: s.playing != 0,
            synced: s.synced != 0,
            braking: s.braking != 0,
            ended: s.ended,
            peak: (s.peak_l, s.peak_r),
        }
    }
}

/// What is heard on a bus, each 0..1 against a fixed scale (a mastered record's loud
/// near 1). Levels are the latest row; hits and the peak the most of the span asked.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Features {
    pub at: f64,
    pub sub: f32,
    pub low: f32,
    pub mid: f32,
    pub high: f32,
    pub air: f32,
    pub kick: f32,
    pub snare: f32,
    pub hat: f32,
    pub onset: f32,
    pub rms: f32,
    pub peak: f32,
    /// The master's only: 30 Hz .. 16 kHz, log-spaced.
    pub spectrum: [f32; SPECTRUM],
    pub rows: i32,
}

/// A source's gains on its deck: the whole, and a stems source's three pairs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Gains {
    pub gain: f32,
    pub drums: f32,
    pub rest: f32,
    pub vocals: f32,
}

impl Gains {
    pub const FULL: Gains = Gains { gain: 1.0, drums: 1.0, rest: 1.0, vocals: 1.0 };
}

/// The EQ's bands, decibels (a kill at -40).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Eq {
    pub low: f32,
    pub mid: f32,
    pub high: f32,
}

struct Inner {
    offline: bool,
}

impl Drop for Inner {
    fn drop(&mut self) {
        unsafe { sys::we_stop() };
        RUNNING.store(false, Ordering::Release);
    }
}

/// The running engine. Clones are handles to the same one; it stops with the last.
#[derive(Clone)]
pub struct Engine {
    inner: Arc<Inner>,
}

impl fmt::Debug for Engine {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Engine").field("offline", &self.inner.offline).field("rate", &self.rate()).finish()
    }
}

impl Engine {
    /// Starts the engine at `rate` frames a second (None: the sound card's own).
    pub fn start(rate: Option<u32>, output: Output) -> Result<Engine, Error> {
        if RUNNING.swap(true, Ordering::AcqRel) {
            return Err(Error::AlreadyRunning);
        }
        let device = match output {
            Output::Device => 1,
            Output::Offline => 0,
        };
        let code = unsafe { sys::we_start(rate.unwrap_or(0) as i32, device) };
        if code != 0 {
            let why = unsafe { CStr::from_ptr(sys::we_error()) }.to_string_lossy().into_owned();
            unsafe { sys::we_stop() };
            RUNNING.store(false, Ordering::Release);
            return Err(Error::Start(if why.is_empty() { format!("error {code}") } else { why }));
        }
        Ok(Engine { inner: Arc::new(Inner { offline: output == Output::Offline }) })
    }

    pub fn is_offline(&self) -> bool {
        self.inner.offline
    }

    /// Frames a second.
    pub fn rate(&self) -> u32 {
        unsafe { sys::we_rate() as u32 }
    }

    /// From a block handed over to the sound card playing it, seconds.
    pub fn latency(&self) -> f64 {
        unsafe { sys::we_latency() }
    }

    /// The engine's clock, the one positions are stamped with (monotonic; offline:
    /// the frames rendered so far).
    pub fn now(&self) -> f64 {
        unsafe { sys::we_now() }
    }

    pub fn load(&self) -> Load {
        let mut s = sys::we_load_state::default();
        unsafe { sys::we_load(&mut s) };
        Load { average: s.average, worst: s.worst, late: s.late, faster: s.faster != 0, period: s.period }
    }

    /// Pins keylocked decks to one stretcher from now on; the load no longer chooses.
    pub fn set_stretch(&self, s: Stretch) {
        unsafe { sys::we_stretch((s == Stretch::Faster) as i32) }
    }

    /// Offline only: renders `out.len() / 2` frames of the stereo master (interleaved),
    /// and each deck's own output (post fader, stereo) into the buffers given.
    pub fn render(&self, out: &mut [f32], decks: &mut [Option<&mut [f32]>; DECKS]) -> Result<(), Error> {
        if !self.inner.offline {
            return Err(Error::NotOffline);
        }
        if !out.len().is_multiple_of(2) {
            return Err(Error::Shape("the master is stereo: an even number of samples"));
        }
        if decks.iter().flatten().any(|d| d.len() != out.len()) {
            return Err(Error::Shape("every deck's buffer is as long as the master's"));
        }
        let mut ptrs: [*mut f32; DECKS] = [std::ptr::null_mut(); DECKS];
        for (p, d) in ptrs.iter_mut().zip(decks.iter_mut()) {
            if let Some(d) = d {
                *p = d.as_mut_ptr();
            }
        }
        unsafe { sys::we_render(out.as_mut_ptr(), (out.len() / 2) as i32, ptrs.as_mut_ptr()) };
        Ok(())
    }

    /// A new empty source with room for about `frames_hint` frames to begin with.
    pub fn new_source(&self, channels: Channels, frames_hint: i64) -> Result<Source, Error> {
        let id = unsafe { sys::we_source_new(channels as i32, frames_hint.max(0)) };
        if id <= 0 {
            return Err(Error::OutOfMemory);
        }
        Ok(Source { id, channels, done: false, _engine: self.clone() })
    }

    pub fn deck(&self, d: DeckId) -> Deck<'_> {
        Deck { _engine: self, d: d.raw() }
    }

    pub fn set_master_level(&self, gain: f32) {
        unsafe { sys::we_master_level(gain) }
    }

    /// What was heard on `bus` in (from, to], engine time. Measuring runs while asked:
    /// from the first call until ten seconds after the last.
    pub fn features(&self, bus: Bus, from: f64, to: f64) -> Option<Features> {
        let mut s = sys::we_features_state::default();
        if unsafe { sys::we_features(bus.raw(), from, to, &mut s) } == 0 {
            return None;
        }
        Some(Features {
            at: s.at,
            sub: s.sub,
            low: s.low,
            mid: s.mid,
            high: s.high,
            air: s.air,
            kick: s.kick,
            snare: s.snare,
            hat: s.hat,
            onset: s.onset,
            rms: s.rms,
            peak: s.peak,
            spectrum: s.spectrum,
            rows: s.rows,
        })
    }

    /// The last `out.len()` mono samples of `bus` heard by `at`. Returns how many were
    /// there (0 when they are not, or no longer).
    pub fn scope(&self, bus: Bus, at: f64, out: &mut [f32]) -> usize {
        unsafe { sys::we_scope(bus.raw(), at, out.as_mut_ptr(), out.len() as i32).max(0) as usize }
    }
}

/// A decoded record in the engine's memory. Fill it with [`Source::append`] (from any
/// one thread: it is `Send`), say [`Source::finish`] at the end; a deck can play what
/// is in already. Dropping it lets the engine free it once no deck plays it.
pub struct Source {
    id: i32,
    channels: Channels,
    done: bool,
    _engine: Engine,
}

impl fmt::Debug for Source {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Source").field("id", &self.id).field("frames", &self.frames()).field("done", &self.done).finish()
    }
}

impl Source {
    pub fn channels(&self) -> Channels {
        self.channels
    }

    /// Appends interleaved 16-bit frames.
    pub fn append(&mut self, pcm: &[i16]) -> Result<(), Error> {
        let ch = self.channels as usize;
        if !pcm.len().is_multiple_of(ch) {
            return Err(Error::Shape("samples that are not whole frames"));
        }
        if pcm.is_empty() {
            return Ok(());
        }
        let r = unsafe { sys::we_source_append(self.id, pcm.as_ptr(), (pcm.len() / ch) as i64) };
        if r != 0 { Err(Error::OutOfMemory) } else { Ok(()) }
    }

    /// No more is coming: a deck playing to its end now ends there.
    pub fn finish(&mut self) {
        if !self.done {
            unsafe { sys::we_source_done(self.id) };
            self.done = true;
        }
    }

    pub fn is_finished(&self) -> bool {
        self.done
    }

    /// Frames in so far.
    pub fn frames(&self) -> i64 {
        unsafe { sys::we_source_frames(self.id) }
    }
}

impl Drop for Source {
    fn drop(&mut self) {
        unsafe { sys::we_source_free(self.id) }
    }
}

/// One deck's controls.
pub struct Deck<'e> {
    _engine: &'e Engine,
    d: i32,
}

impl Deck<'_> {
    /// Plays `source` in `slot` (0..SOURCE_SLOTS) of the deck's timeline.
    pub fn set_source(&self, slot: usize, source: &Source) {
        assert!(slot < SOURCE_SLOTS, "a deck has {SOURCE_SLOTS} slots");
        unsafe { sys::we_deck_source(self.d, slot as i32, source.id) }
    }

    /// Empties `slot`.
    pub fn clear_source(&self, slot: usize) {
        assert!(slot < SOURCE_SLOTS, "a deck has {SOURCE_SLOTS} slots");
        unsafe { sys::we_deck_source(self.d, slot as i32, 0) }
    }

    pub fn set_gains(&self, slot: usize, g: Gains, ramp: f64) {
        unsafe { sys::we_deck_source_gain(self.d, slot as i32, g.gain, g.drums, g.rest, g.vocals, ramp) }
    }

    pub fn play(&self, playing: bool) {
        unsafe { sys::we_deck_play(self.d, playing as i32) }
    }

    /// Puts the deck at source time `t` at once (a short crossfade from where it was).
    pub fn seek(&self, t: f64) {
        unsafe { sys::we_deck_seek(self.d, t) }
    }

    /// The tempo: source seconds per second, 1 = as recorded.
    pub fn set_rate(&self, rate: f64) {
        unsafe { sys::we_deck_rate(self.d, rate) }
    }

    /// A temporary bend on top of the rate (the jog wheel, a nudge): 1 = none.
    pub fn bend(&self, factor: f64) {
        unsafe { sys::we_deck_bend(self.d, factor) }
    }

    pub fn set_keylock(&self, on: bool) {
        unsafe { sys::we_deck_keylock(self.d, on as i32) }
    }

    pub fn set_shift(&self, semitones: f64) {
        unsafe { sys::we_deck_shift(self.d, semitones) }
    }

    /// The beat grid: the times of the record's beats, ascending.
    pub fn set_beats(&self, times: &[f64]) {
        unsafe { sys::we_deck_beats(self.d, times.as_ptr(), times.len() as i32) }
    }

    /// Which beat of the grid is the first of a bar.
    pub fn set_bar_one(&self, beat_index: usize) {
        unsafe { sys::we_deck_bar_one(self.d, beat_index as i32) }
    }

    /// Follows `master`'s tempo with its beats on the master's: every `every` master
    /// beats line up with whole beats of its own (1 any beat, 4 bars). `offset`: how
    /// far ahead of the master's beat it sits, seconds of its own record.
    pub fn sync(&self, master: DeckId, every: u32, offset: f64) {
        unsafe { sys::we_deck_sync(self.d, master.raw(), every as i32, offset) }
    }

    pub fn unsync(&self) {
        unsafe { sys::we_deck_sync(self.d, -1, 1, 0.0) }
    }

    /// Starts playing in step with `master`: `at` None = now, wherever its beat meets
    /// the master's nearest where it is parked; Some(t) = from where it is parked, at
    /// the moment the master is heard at source time t.
    pub fn start_with(&self, master: DeckId, every: u32, at: Option<f64>, offset: f64) {
        unsafe { sys::we_deck_start(self.d, master.raw(), every as i32, at.unwrap_or(-1.0), offset) }
    }

    /// A synced deck's nudge by ear, eased there by the hold.
    pub fn set_sync_offset(&self, offset: f64) {
        unsafe { sys::we_deck_sync_offset(self.d, offset) }
    }

    /// The follower locked at half (0.5) or double (2) the beat it would choose.
    pub fn set_sync_octave(&self, octave: f64) {
        unsafe { sys::we_deck_sync_octave(self.d, octave) }
    }

    /// Puts its beat on the master's once, now, without holding it there.
    pub fn align(&self, master: DeckId, every: u32, offset: f64) {
        unsafe { sys::we_deck_align(self.d, master.raw(), every as i32, offset) }
    }

    /// Loops source time a..b.
    pub fn set_loop(&self, a: f64, b: f64) {
        unsafe { sys::we_deck_loop(self.d, a, b) }
    }

    pub fn clear_loop(&self) {
        unsafe { sys::we_deck_loop(self.d, 0.0, 0.0) }
    }

    /// A loop of `beats` beats from the beat the deck is on, sample-exact on the grid
    /// (`from_bar`: from the bar's first beat if it was passed within a beat, else the next).
    pub fn loop_beats(&self, beats: f64, from_bar: bool) {
        unsafe { sys::we_deck_loop_beats(self.d, beats, from_bar as i32) }
    }

    /// The channel: gain after the EQ (fader × crossfader × trim).
    pub fn set_level(&self, gain: f32, ramp: f64) {
        unsafe { sys::we_deck_level(self.d, gain, ramp) }
    }

    pub fn set_eq(&self, eq: Eq, ramp: f64) {
        unsafe { sys::we_deck_eq(self.d, eq.low, eq.mid, eq.high, ramp) }
    }

    /// -1 (low pass) .. 1 (high pass).
    pub fn set_filter(&self, knob: f32) {
        unsafe { sys::we_deck_filter(self.d, knob) }
    }

    /// The chop: a cosine dip `depth` deep every `period` seconds of the record, from `origin`.
    pub fn set_gate(&self, depth: f32, period: f64, origin: f64) {
        unsafe { sys::we_deck_gate(self.d, depth, period, origin) }
    }

    /// The echo: send into a dotted echo of `beat` seconds, and the dry.
    pub fn set_echo(&self, send: f32, dry: f32, beat: f64) {
        unsafe { sys::we_deck_echo(self.d, send, dry, beat) }
    }

    /// Slows the record to a stop over `seconds`, pitch going down with it.
    pub fn brake(&self, seconds: f64) {
        unsafe { sys::we_deck_brake(self.d, seconds) }
    }

    pub fn read(&self) -> DeckState {
        let mut s = sys::we_deck_state::default();
        unsafe { sys::we_deck_read(self.d, &mut s) };
        s.into()
    }

    /// Where the deck is heard right now, source seconds.
    pub fn position(&self) -> f64 {
        unsafe { sys::we_deck_position(self.d) }
    }
}
