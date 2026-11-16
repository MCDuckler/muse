//! Video on the stage: footage under a scene (the video ground) or as the scene itself (the
//! video figure), moved by the music.
//!
//! The Desk keeps the hands' say in the show document's pool (`pool.video`, a [VideoSpec]);
//! its [VideoDirector] picks the clip — calm footage in a breakdown, busy footage on a drop,
//! a new one every few phrases — and sends it on the cue's macros ([VideoCue]) while a look
//! with video is on. The stage's [VideoClock] turns the beat into a frame of the clip, the
//! same frame on every stage for the same moment:
//!
//!   play     the clip as it runs, round and round;
//!   lock     a window of footage looped to whole bars (a short clip stretched to them);
//!   cut      a jump to another place in the clip every beat, bar, two bars or phrase;
//!   stutter  a slice of the beat played again and again, shorter as a build rises;
//!   drift    slow motion in the quiet, real time in the loud;
//!   auto     by the section: drift in a breakdown, stutter in a build, cut on a drop,
//!            lock between.
//!
//! The clips' facts ([ClipMeta]: length, frames, each second's light and motion) come from
//! wo-video's import, beside each clip's proxy.
use serde_json::{Value, json};

use crate::events::{EventKind, ShowEvent};
use crate::rng::{Rng, hash_str};
use crate::state::ShowState;

macro_rules! named {
    ($(#[$m:meta])* $name:ident { $($v:ident = $s:literal),* $(,)? }) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub enum $name { $($v),* }
        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$v),*];
            pub fn name(self) -> &'static str {
                match self { $($name::$v => $s),* }
            }
            pub fn by_name(s: &str) -> Option<$name> {
                Self::ALL.iter().copied().find(|x| x.name() == s)
            }
            /// Its place in the list (the stage's numbering).
            pub fn index(self) -> usize {
                self as usize
            }
        }
    };
}

named!(
    /// How the beat moves through the clip.
    VideoMode { Auto = "auto", Play = "play", Lock = "lock", Cut = "cut", Stutter = "stutter", Drift = "drift" }
);
named!(
    /// How the clip fills the stage: cropped to fill it, whole inside it, or whole over a
    /// blurred, filled copy of itself (old 4:3 film, a phone's upright video).
    VideoFit { Fill = "fill", Fit = "fit", Blur = "blur" }
);
named!(
    /// The clip's colours: as they are, two of the record's palette (by light), grey, sepia;
    /// auto: the palette's for footage with little colour of its own, else as it is.
    VideoTint { Auto = "auto", Off = "off", Duotone = "duotone", Mono = "mono", Sepia = "sepia" }
);
named!(
    /// How one clip becomes the next.
    VideoChange { Auto = "auto", Cut = "cut", Dissolve = "dissolve", Mosh = "mosh" }
);
named!(
    /// How often the cut jumps.
    VideoEvery { Beat = "beat", Bar = "bar", TwoBars = "twoBars", Phrase = "phrase" }
);

impl VideoMode {
    pub fn label(self) -> &'static str {
        match self {
            VideoMode::Auto => "Auto",
            VideoMode::Play => "Play",
            VideoMode::Lock => "Lock",
            VideoMode::Cut => "Cut",
            VideoMode::Stutter => "Stutter",
            VideoMode::Drift => "Drift",
        }
    }
}

impl VideoEvery {
    pub fn beats(self) -> f64 {
        match self {
            VideoEvery::Beat => 1.0,
            VideoEvery::Bar => 4.0,
            VideoEvery::TwoBars => 8.0,
            VideoEvery::Phrase => 16.0,
        }
    }
}

/// What the import found out about a clip (wo-video writes it beside the proxy, clip.json).
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct ClipMeta {
    pub id: String,
    /// The source's file name, without its extension.
    pub name: String,
    pub secs: f64,
    pub fps: f64,
    pub frames: usize,
    /// The proxy's pixels.
    pub w: u32,
    pub h: u32,
    /// The part worth showing: the black leader and tail left out.
    pub in_s: f64,
    pub out_s: f64,
    /// Each second's light and motion, 0..255.
    pub luma: Vec<u8>,
    pub motion: Vec<u8>,
    /// How much colour it has, 0..1 (old film: next to none).
    pub colour: f64,
}

impl ClipMeta {
    /// Its motion as a whole, 0..1 (the busy seconds count more than the still ones).
    pub fn busy(&self) -> f64 {
        if self.motion.is_empty() {
            return 0.5;
        }
        let mut m: Vec<u8> = self.motion.clone();
        m.sort_unstable();
        // the upper half's middle: a clip that is busy half the time is busy
        m[(m.len() * 3 / 4).min(m.len() - 1)] as f64 / 255.0
    }

    /// The part worth showing, in seconds.
    pub fn span(&self) -> (f64, f64) {
        let (a, b) = (self.in_s.max(0.0), if self.out_s > 0.0 { self.out_s.min(self.secs) } else { self.secs });
        if b - a < 0.25 { (0.0, self.secs.max(0.04)) } else { (a, b) }
    }

    pub fn aspect(&self) -> f32 {
        if self.h == 0 { 16.0 / 9.0 } else { self.w as f32 / self.h as f32 }
    }

    /// Second `s`'s light and motion, 0..1.
    fn at(&self, s: f64) -> (f64, f64) {
        let i = s.max(0.0) as usize;
        let l = self.luma.get(i.min(self.luma.len().saturating_sub(1))).copied().unwrap_or(128) as f64 / 255.0;
        let m = self.motion.get(i.min(self.motion.len().saturating_sub(1))).copied().unwrap_or(128) as f64 / 255.0;
        (l, m)
    }
}

/// The video's say, as the hands set it.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(from = "Value", into = "Value")]
pub struct VideoSpec {
    pub mode: VideoMode,
    pub fit: VideoFit,
    pub tint: VideoTint,
    pub change: VideoChange,
    /// The cut's beat.
    pub every: VideoEvery,
    /// Phrases a clip stays on (a drop changes it sooner).
    pub hold: u32,
    /// The footage's speed (1: real time), its light, contrast, colour, the kick's push, the
    /// old film's weave and flicker.
    pub speed: f64,
    pub dim: f64,
    pub contrast: f64,
    pub saturation: f64,
    pub punch: f64,
    pub film: f64,
    pub mirror: bool,
    /// The clips kept out, and the starred (shown more), by id.
    pub off: Vec<String>,
    pub star: Vec<String>,
}

/// The knobs' reach.
pub const KNOB_RANGE: (f64, f64) = (0.0, 2.0);

impl Default for VideoSpec {
    fn default() -> Self {
        VideoSpec {
            mode: VideoMode::Auto,
            fit: VideoFit::Fill,
            tint: VideoTint::Auto,
            change: VideoChange::Auto,
            every: VideoEvery::Bar,
            hold: 2,
            speed: 1.0,
            dim: 1.0,
            contrast: 1.0,
            saturation: 1.0,
            punch: 0.5,
            film: 0.5,
            mirror: false,
            off: vec![],
            star: vec![],
        }
    }
}

impl VideoSpec {
    pub fn to_json(&self) -> Value {
        json!({
            "mode": self.mode.name(),
            "fit": self.fit.name(),
            "tint": self.tint.name(),
            "change": self.change.name(),
            "every": self.every.name(),
            "hold": self.hold,
            "speed": self.speed,
            "dim": self.dim,
            "contrast": self.contrast,
            "saturation": self.saturation,
            "punch": self.punch,
            "film": self.film,
            "mirror": self.mirror,
            "off": self.off,
            "star": self.star,
        })
    }

    /// What is missing or not understood is the standard's; a knob clamped to its reach.
    pub fn from_json(j: &Value) -> VideoSpec {
        let s = VideoSpec::default();
        let Some(j) = j.as_object() else { return s };
        let one = |key: &str| j.get(key).and_then(Value::as_str).unwrap_or("");
        let k = |key: &str, rest: f64| j.get(key).and_then(Value::as_f64).map_or(rest, |v| v.clamp(KNOB_RANGE.0, KNOB_RANGE.1));
        let ids = |key: &str| j.get(key).and_then(Value::as_array).map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect()).unwrap_or_default();
        VideoSpec {
            mode: VideoMode::by_name(one("mode")).unwrap_or(s.mode),
            fit: VideoFit::by_name(one("fit")).unwrap_or(s.fit),
            tint: VideoTint::by_name(one("tint")).unwrap_or(s.tint),
            change: VideoChange::by_name(one("change")).unwrap_or(s.change),
            every: VideoEvery::by_name(one("every")).unwrap_or(s.every),
            hold: j.get("hold").and_then(Value::as_u64).map_or(s.hold, |h| h.clamp(1, 16) as u32),
            speed: j.get("speed").and_then(Value::as_f64).map_or(s.speed, |v| v.clamp(0.25, 2.0)),
            dim: k("dim", s.dim),
            contrast: k("contrast", s.contrast),
            saturation: k("saturation", s.saturation),
            punch: k("punch", s.punch),
            film: k("film", s.film),
            mirror: j.get("mirror").and_then(Value::as_bool).unwrap_or(s.mirror),
            off: ids("off"),
            star: ids("star"),
        }
    }

    /// The spec as the stage needs it (the clip lists are the Desk's).
    pub fn for_stage(&self) -> VideoSpec {
        VideoSpec { off: vec![], star: vec![], ..self.clone() }
    }
}

impl From<Value> for VideoSpec {
    fn from(v: Value) -> Self {
        VideoSpec::from_json(&v)
    }
}

impl From<VideoSpec> for Value {
    fn from(s: VideoSpec) -> Self {
        s.to_json()
    }
}

/// The clip on, as the cue carries it.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct VideoCue {
    pub clip: String,
    /// A new number with each clip put on (the stage restarts its clock).
    pub n: u32,
    /// How this clip came on: cut, dissolve, mosh.
    pub how: VideoChange,
    pub spec: VideoSpec,
}

impl Default for VideoCue {
    fn default() -> Self {
        VideoCue { clip: String::new(), n: 0, how: VideoChange::Cut, spec: VideoSpec::default() }
    }
}

impl serde::Serialize for VideoChange {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.name())
    }
}

impl<'de> serde::Deserialize<'de> for VideoChange {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Ok(VideoChange::by_name(&s).unwrap_or(VideoChange::Cut))
    }
}

/// How busy footage the moment wants, 0..1 (a drop the busiest).
pub fn want_busy(st: &ShowState) -> f64 {
    let m = st.master();
    let sec = m.section.as_deref().unwrap_or("").to_ascii_lowercase();
    if m.breakdown || sec.contains("break") || sec.contains("intro") || sec.contains("outro") {
        0.15
    } else if sec.contains("drop") || sec.contains("chorus") {
        0.85
    } else if sec.contains("build") || m.build_k > 0.35 {
        0.55
    } else {
        (0.25 + 0.6 * m.energy).clamp(0.0, 1.0)
    }
}

/// The mode `auto` means now.
pub fn mode_now(mode: VideoMode, st: &ShowState) -> VideoMode {
    if mode != VideoMode::Auto {
        return mode;
    }
    let m = st.master();
    let sec = m.section.as_deref().unwrap_or("").to_ascii_lowercase();
    if m.breakdown || sec.contains("break") || sec.contains("intro") || sec.contains("outro") {
        VideoMode::Drift
    } else if sec.contains("drop") || sec.contains("chorus") {
        VideoMode::Cut
    } else if sec.contains("build") || m.build_k > 0.35 {
        VideoMode::Stutter
    } else {
        VideoMode::Lock
    }
}

// ------------------------------------------------------------------ the Desk's half

/// Picks the clip (the Desk's director's half).
#[derive(Clone, Debug)]
pub struct VideoDirector {
    /// The clips this machine has.
    pub clips: Vec<ClipMeta>,
    on: Option<String>,
    phrases: u32,
    n: u32,
    how: VideoChange,
    recent: Vec<String>,
    rng: Rng,
    /// The datamoshes asked for (a clip moshed in).
    pub moshes: i64,
    /// The hands' NEXT, waiting for the next frame.
    next: bool,
}

impl Default for VideoDirector {
    fn default() -> Self {
        VideoDirector::new(0)
    }
}

impl VideoDirector {
    pub fn new(seed: u64) -> VideoDirector {
        VideoDirector { clips: vec![], on: None, phrases: 0, n: 0, how: VideoChange::Cut, recent: vec![], rng: Rng::new(seed ^ 0x5649_4445_4f00), moshes: 0, next: false }
    }

    /// Whether there is footage to show.
    pub fn any(&self, spec: &VideoSpec) -> bool {
        self.clips.iter().any(|c| !spec.off.contains(&c.id))
    }

    /// The clip on (None while no look shows video).
    pub fn on(&self) -> Option<&str> {
        self.on.as_deref()
    }

    /// Another clip at the next frame (the hands').
    pub fn next(&mut self) {
        self.next = true;
    }

    /// One frame: the clip to show while `wanted` (a look with video on), changed every
    /// `hold` phrases and on a drop.
    pub fn frame(&mut self, st: &ShowState, said: &[ShowEvent], spec: &VideoSpec, wanted: bool) -> Option<VideoCue> {
        if !wanted {
            self.on = None;
            return None;
        }
        // (id, how busy)
        let usable: Vec<(String, f64)> = self.clips.iter().filter(|c| !spec.off.contains(&c.id)).map(|c| (c.id.clone(), c.busy())).collect();
        if usable.is_empty() {
            self.on = None;
            return None;
        }
        let mut change = self.on.as_ref().is_none_or(|on| !usable.iter().any(|c| c.0 == *on));
        let first = self.on.is_none();
        let mut dropped = false;
        for e in said.iter().filter(|e| e.master) {
            match e.kind {
                EventKind::Phrase => {
                    self.phrases += 1;
                    if self.phrases >= spec.hold.max(1) {
                        change = true;
                    }
                }
                EventKind::Drop => {
                    change = true;
                    dropped = true;
                }
                _ => {}
            }
        }
        if std::mem::take(&mut self.next) {
            change = true;
        }
        if change {
            let id = self.pick(&usable, want_busy(st), spec);
            self.how = match spec.change {
                VideoChange::Auto if first => VideoChange::Cut,
                VideoChange::Auto if dropped => VideoChange::Mosh,
                VideoChange::Auto => VideoChange::Dissolve,
                c => c,
            };
            if self.how == VideoChange::Mosh && !first {
                self.moshes += 1;
            }
            self.recent.retain(|r| *r != id);
            self.recent.push(id.clone());
            if self.recent.len() > 4 {
                self.recent.remove(0);
            }
            self.on = Some(id);
            self.phrases = 0;
            self.n = self.n.wrapping_add(1);
        }
        Some(VideoCue { clip: self.on.clone().unwrap_or_default(), n: self.n, how: self.how, spec: spec.for_stage() })
    }

    /// A clip by how busy the moment wants it, a starred one twice as likely, the last few
    /// seldom, the one on never (where there is another).
    fn pick(&mut self, usable: &[(String, f64)], want: f64, spec: &VideoSpec) -> String {
        let items: Vec<(String, f64)> = usable
            .iter()
            .map(|(id, busy)| {
                let d = (busy - want) / 0.35;
                let mut w = (-d * d).exp().max(0.05);
                if spec.star.contains(id) {
                    w *= 2.0;
                }
                if let Some(i) = self.recent.iter().position(|r| r == id) {
                    w *= 0.1 + 0.1 * i as f64;
                }
                if usable.len() > 1 && self.on.as_deref() == Some(id.as_str()) {
                    w = 0.0;
                }
                (id.clone(), w)
            })
            .collect();
        crate::combos::pick_by_weight(&items, self.rng.next_f64()).unwrap_or_else(|| usable[0].0.clone())
    }
}

// ------------------------------------------------------------------ the stage's half

/// Which frame of the clip, and how the last clip goes away.
#[derive(Clone, Debug, PartialEq)]
pub struct VideoAt {
    pub frame: usize,
    /// The mode it played by.
    pub mode: VideoMode,
    /// The last clip's picture over this one, fading (1: wholly this one).
    pub k: f32,
}

/// The beat into a frame of the clip (the stage's half; once a frame).
#[derive(Clone, Debug, Default)]
pub struct VideoClock {
    n: Option<u32>,
    /// Where in the clip, in seconds (the free modes run on from it).
    pos: f64,
    /// The beats counted where the decks give none (120 BPM).
    own_beats: f64,
    /// The dissolve's start, in beats.
    fade_from: Option<f64>,
}

impl VideoClock {
    /// The frame for `cue`'s clip (`clip` its facts) at `st`.
    pub fn tick(&mut self, cue: &VideoCue, clip: &ClipMeta, st: &ShowState, dt: f64) -> VideoAt {
        let spec = &cue.spec;
        let m = st.master();
        self.own_beats += dt * 2.0;
        let (beats, beat_secs) = match (m.playing, m.bpm, m.beat_index) {
            (true, Some(bpm), Some(i)) if bpm > 20.0 => (i as f64 + m.beat_phase, 60.0 / bpm),
            _ => (self.own_beats, 0.5),
        };
        let (a, b) = clip.span();
        let len = b - a;
        let fresh = self.n != Some(cue.n);
        if fresh {
            self.fade_from = (self.n.is_some() && cue.how == VideoChange::Dissolve).then_some(beats);
            self.n = Some(cue.n);
            self.pos = anchor(clip, cue.n as i64, 0, len.min(8.0), want_busy(st));
        }
        let mode = mode_now(spec.mode, st);
        let speed = spec.speed.clamp(0.25, 2.0);
        let fpb = beat_secs * speed; // footage seconds a beat
        let wrap = |p: f64| a + (p - a).rem_euclid(len.max(1e-3));
        let busy = want_busy(st);
        let salt = cue.n as i64 * 7919;
        let pos = match mode {
            VideoMode::Play | VideoMode::Auto => wrap(self.pos + dt * speed),
            VideoMode::Drift => {
                // slow motion in the quiet, real time in the loud
                let e = m.energy.clamp(0.0, 1.0);
                wrap(self.pos + dt * speed * (0.3 + 0.7 * e * e.sqrt()))
            }
            VideoMode::Lock => {
                if len < 16.0 * fpb {
                    // a short clip: stretched over the whole bars nearest its own length
                    let bars = [1.0, 2.0, 4.0].into_iter().min_by(|x: &f64, y: &f64| ((len / (x * 4.0 * beat_secs)).ln() - speed.ln()).abs().total_cmp(&((len / (y * 4.0 * beat_secs)).ln() - speed.ln()).abs())).unwrap_or(1.0);
                    let wb = bars * 4.0;
                    a + beats.rem_euclid(wb) / wb * len
                } else {
                    // four bars of footage looped, somewhere else every eight bars
                    let wb = 16.0;
                    let k = (beats / 32.0).floor() as i64;
                    anchor(clip, salt + k, 1, wb * fpb, busy) + beats.rem_euclid(wb) * fpb
                }
            }
            VideoMode::Cut => {
                let eb = spec.every.beats();
                let k = (beats / eb).floor() as i64;
                anchor(clip, salt + k, 2, eb * fpb, busy) + (beats - k as f64 * eb) * fpb
            }
            VideoMode::Stutter => {
                // a slice played again: a beat, a half, a quarter as the build rises, an eighth
                // in the last bar before the drop
                let slice = if m.drop_beats_away.is_some_and(|d| d > 0.0 && d <= 4.0) {
                    0.125
                } else if m.build_k > 0.66 {
                    0.25
                } else if m.build_k > 0.33 {
                    0.5
                } else {
                    1.0
                };
                let group = slice * 2.0;
                let local = beats.rem_euclid(16.0);
                let k = (beats / 16.0).floor() as i64;
                anchor(clip, salt + k, 3, 16.0 * fpb, busy) + ((local / group).floor() * group + local.rem_euclid(slice)) * fpb
            }
        };
        let pos = wrap(pos);
        self.pos = pos;
        let k = match self.fade_from {
            Some(f) => {
                let k = ((beats - f) / 4.0).clamp(0.0, 1.0);
                if k >= 1.0 {
                    self.fade_from = None;
                }
                // a beat counted backwards (a deck moved) ends it
                if beats < f { 1.0 } else { k }
            }
            None => 1.0,
        };
        let frame = ((pos * clip.fps).floor().max(0.0) as usize).min(clip.frames.saturating_sub(1));
        VideoAt { frame, mode, k: k as f32 }
    }
}

/// A place in the clip to start a `window` seconds long run from: the same for the same
/// clip, `k` and `kind`; the best of eight tried, away from the dark, as busy as wanted.
pub fn anchor(clip: &ClipMeta, k: i64, kind: u64, window: f64, want: f64) -> f64 {
    let (a, b) = clip.span();
    let room = (b - a - window).max(0.0);
    if room <= 0.0 {
        return a;
    }
    let mut rng = Rng::new(hash_str(&clip.id) ^ (k as u64).wrapping_mul(0x9E37_79B9) ^ kind.wrapping_mul(0x51_7CC1_B727_220A));
    let mut best = (f64::NEG_INFINITY, a);
    // one try in each eighth of the clip, in a random order of goodness
    for i in 0..8 {
        let at = a + (i as f64 + rng.next_f64()) / 8.0 * room;
        // the run's middle
        let (l, mo) = clip.at(at + window * 0.5);
        let dark = if l < 0.06 { -3.0 } else { 0.0 };
        let score = dark - ((mo - want) / 0.3).powi(2) + rng.next_f64() * 0.3;
        if score > best.0 {
            best = (score, at);
        }
    }
    best.1
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::deck::ShowDeck;

    fn clip(id: &str, secs: f64, busy: u8) -> ClipMeta {
        let n = secs.ceil() as usize;
        ClipMeta { id: id.into(), name: id.into(), secs, fps: 25.0, frames: (secs * 25.0) as usize, w: 720, h: 540, in_s: 0.0, out_s: secs, luma: vec![120; n], motion: vec![busy; n], colour: 0.05 }
    }

    fn at(beat: i64, phase: f64, section: &str) -> ShowState {
        let a = ShowDeck { name: "A".into(), playing: true, bpm: Some(120.0), beat_index: Some(beat), beat_phase: phase, section: Some(section.into()), energy: 0.5, ..Default::default() };
        ShowState { a, master_name: "A".into(), ..Default::default() }
    }

    #[test]
    fn the_spec_reads_and_writes() {
        let s = VideoSpec { mode: VideoMode::Cut, fit: VideoFit::Blur, every: VideoEvery::Phrase, speed: 9.0, off: vec!["x".into()], ..Default::default() };
        let back = VideoSpec::from_json(&s.to_json());
        assert_eq!(back.speed, 2.0, "clamped");
        assert_eq!(VideoSpec { speed: 2.0, ..s.clone() }, back);
        assert_eq!(VideoSpec::from_json(&Value::Null), VideoSpec::default());
        let cue = VideoCue { clip: "a".into(), n: 3, how: VideoChange::Mosh, spec: s.for_stage() };
        let j = serde_json::to_value(&cue).unwrap();
        assert_eq!(j["how"], "mosh");
        assert_eq!(serde_json::from_value::<VideoCue>(j).unwrap(), VideoCue { spec: VideoSpec { speed: 2.0, ..s.for_stage() }, ..cue });
    }

    #[test]
    fn auto_follows_the_section() {
        assert_eq!(mode_now(VideoMode::Auto, &at(0, 0.0, "drop")), VideoMode::Cut);
        assert_eq!(mode_now(VideoMode::Auto, &at(0, 0.0, "breakdown")), VideoMode::Drift);
        assert_eq!(mode_now(VideoMode::Auto, &at(0, 0.0, "build")), VideoMode::Stutter);
        assert_eq!(mode_now(VideoMode::Auto, &at(0, 0.0, "verse")), VideoMode::Lock);
        assert_eq!(mode_now(VideoMode::Play, &at(0, 0.0, "drop")), VideoMode::Play);
    }

    #[test]
    fn the_same_beat_is_the_same_frame() {
        let c = clip("reel", 120.0, 100);
        let cue = VideoCue { clip: "reel".into(), n: 1, how: VideoChange::Cut, spec: VideoSpec { mode: VideoMode::Cut, ..Default::default() } };
        let (mut one, mut two) = (VideoClock::default(), VideoClock::default());
        for b in [5, 9, 40] {
            let st = at(b, 0.3, "drop");
            assert_eq!(one.tick(&cue, &c, &st, 0.016), two.tick(&cue, &c, &st, 0.5));
        }
    }

    #[test]
    fn cut_jumps_on_the_bar_and_runs_between() {
        let c = clip("reel", 300.0, 100);
        let cue = VideoCue { clip: "reel".into(), n: 1, how: VideoChange::Cut, spec: VideoSpec { mode: VideoMode::Cut, every: VideoEvery::Bar, ..Default::default() } };
        let mut k = VideoClock::default();
        let f = |k: &mut VideoClock, b, p| k.tick(&cue, &c, &at(b, p, "drop"), 0.016).frame as i64;
        let (a0, a1, a3) = (f(&mut k, 4, 0.0), f(&mut k, 5, 0.0), f(&mut k, 7, 0.0));
        // a beat at 120 BPM is half a second: 12 or 13 frames at 25 fps
        assert!((a1 - a0 - 12).abs() <= 1 && (a3 - a0 - 37).abs() <= 1, "{a0} {a1} {a3}");
        let b0 = f(&mut k, 8, 0.0);
        assert!((b0 - a0 - 50).abs() > 3, "a new place on the next bar");
    }

    #[test]
    fn a_short_loop_locks_to_whole_bars() {
        // 2 s of footage at 120 BPM: one bar
        let c = clip("loop", 2.0, 100);
        let cue = VideoCue { clip: "loop".into(), n: 1, how: VideoChange::Cut, spec: VideoSpec { mode: VideoMode::Lock, ..Default::default() } };
        let mut k = VideoClock::default();
        assert_eq!(k.tick(&cue, &c, &at(8, 0.0, "verse"), 0.0).frame, 0);
        assert_eq!(k.tick(&cue, &c, &at(10, 0.0, "verse"), 0.0).frame, 25);
        assert_eq!(k.tick(&cue, &c, &at(12, 0.0, "verse"), 0.0).frame, 0);
    }

    #[test]
    fn stutter_plays_a_slice_twice() {
        let c = clip("reel", 300.0, 100);
        let cue = VideoCue { clip: "reel".into(), n: 1, how: VideoChange::Cut, spec: VideoSpec { mode: VideoMode::Stutter, ..Default::default() } };
        let mut k = VideoClock::default();
        let mut st = at(16, 0.25, "build");
        st.a.build_k = 0.2; // a beat's slice, twice
        let x = k.tick(&cue, &c, &st, 0.0).frame;
        st.a.beat_index = Some(17);
        assert_eq!(k.tick(&cue, &c, &st, 0.0).frame, x, "the beat again");
        st.a.beat_index = Some(18);
        assert!(k.tick(&cue, &c, &st, 0.0).frame > x + 20, "then on");
    }

    #[test]
    fn a_dissolve_takes_a_bar() {
        let c = clip("reel", 60.0, 100);
        let mut cue = VideoCue { clip: "reel".into(), n: 1, how: VideoChange::Cut, spec: VideoSpec::default() };
        let mut k = VideoClock::default();
        assert_eq!(k.tick(&cue, &c, &at(0, 0.0, "verse"), 0.0).k, 1.0, "the first clip is simply on");
        cue.n = 2;
        cue.how = VideoChange::Dissolve;
        assert_eq!(k.tick(&cue, &c, &at(4, 0.0, "verse"), 0.0).k, 0.0);
        assert_eq!(k.tick(&cue, &c, &at(6, 0.0, "verse"), 0.0).k, 0.5);
        assert_eq!(k.tick(&cue, &c, &at(8, 0.0, "verse"), 0.0).k, 1.0);
    }

    #[test]
    fn the_director_picks_by_the_moment_and_changes_on_phrases_and_drops() {
        let mut d = VideoDirector::new(1);
        d.clips = vec![clip("calm", 60.0, 10), clip("busy", 60.0, 230), clip("mid", 60.0, 120)];
        let spec = VideoSpec { hold: 2, ..Default::default() };
        assert!(d.frame(&at(0, 0.0, "drop"), &[], &spec, false).is_none());
        // over many seeds a breakdown mostly gets the calm clip
        let calm = (0..40)
            .filter(|s| {
                let mut d = VideoDirector::new(*s);
                d.clips = vec![clip("calm", 60.0, 10), clip("busy", 60.0, 230)];
                d.frame(&at(0, 0.0, "breakdown"), &[], &spec, true).unwrap().clip == "calm"
            })
            .count();
        assert!(calm > 30, "{calm}/40");
        let c1 = d.frame(&at(0, 0.0, "verse"), &[], &spec, true).unwrap();
        assert_eq!(c1.how, VideoChange::Cut, "the first comes on by a cut");
        let phrase = ShowEvent::on_master(EventKind::Phrase);
        let c2 = d.frame(&at(16, 0.0, "verse"), std::slice::from_ref(&phrase), &spec, true).unwrap();
        assert_eq!(c2.n, c1.n, "one phrase: held");
        let c3 = d.frame(&at(32, 0.0, "verse"), std::slice::from_ref(&phrase), &spec, true).unwrap();
        assert_ne!(c3.clip, c1.clip, "two phrases: another");
        assert_eq!(c3.how, VideoChange::Dissolve);
        let m = d.moshes;
        let c4 = d.frame(&at(40, 0.0, "drop"), &[ShowEvent::on_master(EventKind::Drop)], &spec, true).unwrap();
        assert_eq!(c4.how, VideoChange::Mosh);
        assert_eq!(d.moshes, m + 1);
        // a clip kept out is never shown
        let spec_off = VideoSpec { off: vec!["calm".into(), "mid".into()], ..spec };
        for _ in 0..5 {
            d.next();
            assert_eq!(d.frame(&at(48, 0.0, "breakdown"), &[], &spec_off, true).unwrap().clip, "busy");
        }
    }

    #[test]
    fn an_anchor_keeps_away_from_the_dark() {
        let mut c = clip("reel", 100.0, 100);
        for l in c.luma.iter_mut().take(50) {
            *l = 2;
        }
        for k in 0..20 {
            let at = anchor(&c, k, 0, 2.0, 0.4);
            assert!(at > 48.0, "{k}: {at}");
        }
    }
}
