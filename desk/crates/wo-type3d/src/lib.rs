//! The 3D text for the Rust stage (v1: ui/show/show_type3d.dart's Type3dSim): the hands' words
//! (wo_show::type3d::TypeSpec, on the cue's macros) set in their face and made a distance
//! field once a line, on a thread of its own ([field]), and the numbers type3d.frag ray-marches
//! them by every frame ([Type3dSim::tick]).
//!
//! Two lines are held, one in each of the shader's slots: the one on, and the next, set ahead
//! of its moment, so the change lands on the beat it was asked for. It turns into the next the
//! hands' way — its letters flowing into the next ones, turned over edge-on, or cut over in
//! bands. A phrase picks one of the hands' motions (the calm ones in a quiet part, the ones
//! that move a lot the harder the music, one of those at once on a drop), one of their looks
//! and two of their bends; the kick pushes the letters out at the camera, the snare whitens
//! their rim and ticks the horizon, the low end breathes their depth; in a loud part they jolt
//! round on every beat, whip once round on the drop, and the camera travels through each shot.
//!
//! One deliberate change from v1: v1 read the kick, snare, low end and hats by the names
//! `kick`, `snare`, `low`, `hat`, which nothing in its state set (they were naught, so the
//! letters never answered the drums); here they are the heard ones (`audio.kick` …).
pub mod field;

use std::collections::{BTreeSet, HashMap};
use std::f64::consts::{PI, TAU};
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};

use wo_dance::clock::{Sweep, cut_hold};
use wo_show::state::{Hsl, ShowState};
use wo_show::treat::meme_hash;
use wo_show::type3d::{TypeChange, TypeColour, TypeDeform, TypeLook, TypeMotion, TypeSpec, TypeTurn};

pub use field::TypeField;

/// The shader's floats (type3d.frag), in the order the file declares them, each with its
/// count (v1's Type3dParams.uniforms; a test holds the .frag to it).
pub const UNIFORMS: &[(&str, usize)] = &[
    ("uResolution", 2),
    ("uTime", 1),
    ("uRotX", 3),
    ("uRotY", 3),
    ("uRotZ", 3),
    ("uPos", 3),
    ("uHalf", 2),
    ("uHalfB", 2),
    ("uRange", 1),
    ("uRangeB", 1),
    ("uMix", 1),
    ("uMixMode", 1),
    ("uSeed", 1),
    ("uDepth", 1),
    ("uBevel", 1),
    ("uWave", 1),
    ("uWavePhase", 1),
    ("uTwist", 1),
    ("uDeformA", 4),
    ("uDeformB", 4),
    ("uDeformC", 4),
    ("uLook", 1),
    ("uInk", 3),
    ("uInk2", 3),
    ("uRim", 3),
    ("uGlow", 1),
    ("uKick", 1),
    ("uFlash", 1),
    ("uFov", 1),
    ("uMirror", 2),
    ("uGroundOn", 1),
    ("uPremul", 1),
];

/// The values by name for one frame (the stage lays them out as its pass's block has them).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Params(pub Vec<(&'static str, Vec<f32>)>);

impl Params {
    pub fn get(&self, name: &str) -> Option<&[f32]> {
        self.0.iter().find(|(n, _)| *n == name).map(|(_, v)| v.as_slice())
    }

    fn set(&mut self, name: &'static str, v: &[f64]) {
        let v: Vec<f32> = v.iter().map(|x| *x as f32).collect();
        match self.0.iter_mut().find(|(n, _)| *n == name) {
            Some(e) => e.1 = v,
            None => self.0.push((name, v)),
        }
    }

    /// In the shader's order, as one list (setFloat's numbering).
    pub fn flat(&self) -> Vec<f32> {
        UNIFORMS.iter().flat_map(|(n, c)| self.get(n).map(<[f32]>::to_vec).unwrap_or_else(|| vec![0.0; *c])).collect()
    }
}

/// Where a motion has the letters at a moment: turned (yaw about the upright, pitch about the
/// across, roll about the view), moved, bent and wrung.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Pose {
    yaw: f64,
    pitch: f64,
    roll: f64,
    x: f64,
    y: f64,
    z: f64,
    wave: f64,
    twist: f64,
}

impl Pose {
    fn lerp(self, o: Pose, k: f64) -> Pose {
        let l = |a: f64, b: f64| a + (b - a) * k;
        Pose { yaw: l(self.yaw, o.yaw), pitch: l(self.pitch, o.pitch), roll: l(self.roll, o.roll), x: l(self.x, o.x), y: l(self.y, o.y), z: l(self.z, o.z), wave: l(self.wave, o.wave), twist: l(self.twist, o.twist) }
    }
}

/// The close drift's way in: the camera this much nearer than the line's distance.
const DRIFT_Z: f64 = 1.6;

fn ease(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// The motions that move a lot (picked the harder the music), and the ones on the beat (their
/// clock the record's beats, never sped up).
fn hard(m: TypeMotion) -> bool {
    matches!(m, TypeMotion::Spin | TypeMotion::Tumble | TypeMotion::Flip | TypeMotion::Twist | TypeMotion::Zoom | TypeMotion::Bounce)
}

fn on_beat(m: TypeMotion) -> bool {
    matches!(m, TypeMotion::Bounce | TypeMotion::Flip | TypeMotion::Swing | TypeMotion::Zoom)
}

/// One of `from` by the dice `d`: the hard ones the harder the music (`drive`), the calm ones
/// the calmer.
fn pick_motion(from: &[TypeMotion], drive: f64, d: f64) -> TypeMotion {
    let w: Vec<f64> = from.iter().map(|x| 0.15 + 3.0 * if hard(*x) { drive } else { 1.0 - drive }).collect();
    let mut left = d * w.iter().sum::<f64>();
    for (i, x) in from.iter().enumerate() {
        left -= w[i];
        if left <= 0.0 {
            return *x;
        }
    }
    *from.last().unwrap()
}

/// The motions, by beats `b` (the speed taken in) into the record.
fn motion(m: TypeMotion, b: f64) -> Pose {
    let in_bar = b.rem_euclid(4.0);
    let p = Pose::default();
    match m {
        TypeMotion::Spin => Pose { yaw: TAU * b / 8.0, pitch: 0.12 * (TAU * b / 16.0).sin(), ..p },
        TypeMotion::Tumble => Pose { yaw: TAU * b / 11.0, pitch: TAU * b / 17.0, roll: TAU * b / 23.0, ..p },
        TypeMotion::Swing => Pose { yaw: 0.6 * (PI * b).cos(), roll: 0.06 * (PI * b).sin(), ..p },
        // a whole turn over, in the bar's first beat and a half, then still
        TypeMotion::Flip => Pose { pitch: TAU * ease(in_bar / 1.5), ..p },
        TypeMotion::Wave => Pose { yaw: 0.28 * (TAU * b / 16.0).sin(), wave: 0.07, pitch: 0.1 * (TAU * b / 8.0).sin(), ..p },
        TypeMotion::Twist => Pose { twist: 0.55 * (TAU * b / 4.0).sin(), yaw: 0.2 * (TAU * b / 16.0).sin(), ..p },
        TypeMotion::Orbit => Pose { x: 0.55 * (TAU * b / 16.0).sin(), z: 0.6 * (TAU * b / 16.0).cos(), yaw: -0.45 * (TAU * b / 16.0).sin(), pitch: 0.12 * (TAU * b / 8.0).sin(), ..p },
        // in from far off over the phrase, held its last bar
        TypeMotion::Zoom => Pose { z: -9.0 * (1.0 - ease(b.rem_euclid(16.0) / 12.0)), yaw: 0.35 * (TAU * b / 16.0).sin(), ..p },
        TypeMotion::Bounce => Pose { y: 0.22 * (PI * b.rem_euclid(1.0)).sin().max(0.0).powf(0.8), pitch: -0.1 * (TAU * b.rem_euclid(1.0)).cos(), ..p },
        // close: the camera nearly at the letters, sliding along them over two bars
        TypeMotion::Drift => Pose { z: DRIFT_Z, x: -1.3 * (TAU * b / 32.0).sin(), yaw: 0.35 * (TAU * b / 16.0).sin(), roll: 0.08 * (TAU * b / 12.0).sin(), ..p },
        TypeMotion::Still => p,
    }
}

fn hex(c: u32) -> [f64; 3] {
    [((c >> 16) & 255) as f64 / 255.0, ((c >> 8) & 255) as f64 / 255.0, (c & 255) as f64 / 255.0]
}

/// The colours: face, side, rim.
fn colours(c: TypeColour, st: &ShowState) -> [[f64; 3]; 3] {
    let p = &st.palette;
    let with = |h: Hsl, s: f64, l: f64| Hsl { h: h.h, s, l }.rgb();
    match c {
        TypeColour::Record => [with(p.accent, 0.75, 0.78), with(p.primary, 0.8, 0.42), with(p.secondary, 1.0, 0.62)],
        TypeColour::Purple => [hex(0xe9b8ff), hex(0x5b1fa8), hex(0xff4fd8)],
        TypeColour::Sunset => [hex(0xffd27a), hex(0xe0405a), hex(0xff7a3d)],
        TypeColour::Ice => [hex(0xcff6ff), hex(0x3a7bd5), hex(0x7af0ff)],
        TypeColour::Gold => [hex(0xffe6a0), hex(0xa8741a), hex(0xffc94a)],
        TypeColour::Mono => [hex(0xffffff), hex(0x8a8a8a), hex(0xffffff)],
    }
}

/// How many lines made are kept (the one on, the next, a few before).
const KEEP: usize = 6;

/// The 3D type's clock: the lines made and in the slots, the phrase's picks, the beat's
/// accents, the camera's travel.
pub struct Type3dSim {
    t: f64,
    fade: f64,
    made: HashMap<String, Arc<TypeField>>,
    /// The order they were made in (the oldest let go first).
    order: Vec<String>,
    making: BTreeSet<String>,
    tx: Sender<TypeField>,
    rx: Receiver<TypeField>,
    /// Bake on the caller's thread (a shot, a test): the line there at once.
    pub at_once: bool,
    slots: [Option<Arc<TypeField>>; 2],
    /// What went into a slot since the stage last asked.
    placed: Vec<(usize, Arc<TypeField>)>,
    on: usize,
    turn: f64,
    turn_how: TypeTurn,
    phrase_was: i64,
    motion_now: Option<TypeMotion>,
    motion_was: Option<TypeMotion>,
    look: TypeLook,
    bends: BTreeSet<TypeDeform>,
    deforms_was: Vec<TypeDeform>,
    blend: f64,
    bend: [f64; 10],
    drop_at: Option<f64>,
    away_was: Option<f64>,
    hat: f64,
    phase: f64,
    beats_was: f64,
    step_aim: f64,
    step_yaw: f64,
    sweep: Sweep,
    sweep_n: i64,
    away_pick: Option<f64>,
    beat_was: i64,
}

impl Default for Type3dSim {
    fn default() -> Self {
        let (tx, rx) = channel();
        Type3dSim {
            t: 0.0,
            fade: 0.0,
            made: HashMap::new(),
            order: vec![],
            making: BTreeSet::new(),
            tx,
            rx,
            at_once: false,
            slots: [None, None],
            placed: vec![],
            on: 0,
            turn: -1.0,
            turn_how: TypeTurn::Morph,
            phrase_was: -1,
            motion_now: None,
            motion_was: None,
            look: TypeLook::Chrome,
            bends: BTreeSet::new(),
            deforms_was: vec![],
            blend: 1.0,
            bend: [0.0; 10],
            drop_at: None,
            away_was: None,
            hat: 0.0,
            phase: 0.0,
            beats_was: -1.0,
            step_aim: 0.0,
            step_yaw: 0.0,
            sweep: Sweep::default(),
            sweep_n: -1,
            away_pick: None,
            beat_was: -1,
        }
    }
}

/// A beat's seconds at a tempo of one.
const BEAT1: f64 = 60.0;

impl Type3dSim {
    /// The fields put into the slots since the last asking (the stage uploads them).
    pub fn take_placed(&mut self) -> Vec<(usize, Arc<TypeField>)> {
        std::mem::take(&mut self.placed)
    }

    /// The line on (tests).
    pub fn field(&self) -> Option<&TypeField> {
        self.slots[self.on].as_deref()
    }

    pub fn turning(&self) -> bool {
        self.turn >= 0.0
    }

    pub fn bends(&self) -> &BTreeSet<TypeDeform> {
        &self.bends
    }

    /// Whether a line is still being set.
    pub fn busy(&self) -> bool {
        !self.making.is_empty()
    }

    fn keep(&mut self, f: TypeField) {
        let key = f.key();
        self.making.remove(&key);
        self.order.retain(|k| *k != key);
        self.order.push(key.clone());
        self.made.insert(key, Arc::new(f));
        // the lines made long ago let go: a handful kept, never one in a slot
        while self.made.len() > KEEP {
            let Some(i) = self.order.iter().position(|k| !self.slots.iter().flatten().any(|s| s.key() == *k)) else { break };
            let k = self.order.remove(i);
            self.made.remove(&k);
        }
    }

    /// `text` in the spec's face set, where it is not (or being).
    fn want(&mut self, text: &str, spec: &TypeSpec) {
        let key = format!("{}|{}", spec.font.name(), text);
        if self.made.contains_key(&key) || self.making.contains(&key) {
            return;
        }
        self.making.insert(key);
        let font = spec.font;
        if self.at_once {
            let f = TypeField::bake(text, font);
            self.keep(f);
            return;
        }
        let (tx, text) = (self.tx.clone(), text.to_owned());
        let _ = std::thread::Builder::new().name("type3d".into()).spawn(move || {
            let _ = tx.send(TypeField::bake(&text, font));
        });
    }

    fn place(&mut self, i: usize, f: Arc<TypeField>) {
        self.slots[i] = Some(f.clone());
        self.placed.push((i, f));
    }

    /// One frame's numbers for `st`, `dt` seconds on, at a working size of `w`×`h`; the lines
    /// made as needed. `ground`: a picture lies under the letters (glass bends it, and the
    /// letters are drawn straight for the blend).
    pub fn tick(&mut self, st: &ShowState, dt: f64, w: f64, h: f64, ground: bool) -> Params {
        while let Ok(f) = self.rx.try_recv() {
            self.keep(f);
        }
        self.t += dt;
        let m = st.master();
        let spec = st.macros.type3d.clone().unwrap_or_default();
        let playing = m.playing && m.beat_index.is_some();
        let bpm = m.bpm.filter(|b| *b > 1.0).unwrap_or(120.0);
        let beats = if !playing {
            self.t * bpm / 60.0
        } else {
            match (m.bar_index, m.beat_in_bar) {
                (Some(bar), Some(b)) => (bar * 4 + b) as f64 + m.beat_phase,
                _ => m.beat_index.unwrap_or(0) as f64 + m.beat_phase,
            }
        };
        let salt = m.track_id.unwrap_or(0) ^ st.macros.seed;
        let s9973 = salt.rem_euclid(9973) as f64;
        let beats_per = BEAT1 / bpm;
        // how hard the music is now: the motion picked by it, its speed, the beat's accents;
        // a drop landing: a hard motion at once
        let drive = if playing { wo_show::director::drive(m) } else { 0.0 };
        let away_now = m.drop_beats_away;
        let drop_landed = playing && away_now.is_some_and(|a| a <= 0.0 && a > -2.5) && self.away_pick.is_none_or(|a| a > 0.0);
        self.away_pick = away_now;

        // the line: the change's count; the one now and the one after it set ahead
        let every = match spec.change {
            TypeChange::Beat => 1.0,
            TypeChange::Bar => 4.0,
            TypeChange::TwoBars => 8.0,
            TypeChange::Phrase => 16.0,
            TypeChange::EightBars => 32.0,
            TypeChange::Never => 0.0,
        };
        let n = if every == 0.0 { 0 } else { (beats / every).floor() as i64 };
        let (title, artist) = (m.title.as_deref(), m.artist.as_deref());
        let text = spec.line_at(n, title, artist);
        self.want(&text, &spec);
        if every > 0.0 {
            self.want(&spec.line_at(n + 1, title, artist), &spec);
        }
        let wanted = self.made.get(&format!("{}|{}", spec.font.name(), text)).cloned();

        // the line wanted ready and not the one on: on at once where none is, else turned to
        if let Some(wanted) = wanted
            && self.turn < 0.0
            && !self.slots[self.on].as_ref().is_some_and(|s| Arc::ptr_eq(s, &wanted))
        {
            if self.slots[self.on].is_none() {
                self.place(self.on, wanted);
            } else {
                self.place(1 - self.on, wanted);
                self.turn = 0.0;
                self.turn_how = spec.turn;
            }
        }
        // the turn: a beat or so, less where the lines come every beat
        let turn_beats = match spec.change {
            TypeChange::Beat => 0.45,
            TypeChange::Bar => 1.0,
            TypeChange::TwoBars => 1.5,
            _ => 2.0,
        };
        let mut swap_angle = 0.0;
        let mut mix = self.on as f64;
        if self.turn >= 0.0 {
            self.turn += dt / (turn_beats * beats_per);
            let k = self.turn.clamp(0.0, 1.0);
            let to = 1 - self.on;
            if self.turn_how == TypeTurn::Flip {
                // away edge-on, the next in from the other edge
                swap_angle = (if k < 0.5 { k } else { k - 1.0 }) * PI;
                mix = (if k < 0.5 { self.on } else { to }) as f64;
            } else {
                let e = ease(k);
                mix = if self.on == 0 { e } else { 1.0 - e };
            }
            if self.turn >= 1.0 {
                self.on = to;
                self.turn = -1.0;
                mix = self.on as f64;
            }
        }

        // a phrase: a motion, a look and two bends of the hands', crossfaded in (and at once
        // where the hands' sets leave out what is on)
        let phrase = (beats / 16.0).floor() as i64;
        if phrase != self.phrase_was
            || (drop_landed && !self.motion_now.is_some_and(hard))
            || self.motion_now.is_none_or(|x| !spec.motions.contains(&x))
            || !spec.looks.contains(&self.look)
            || spec.deforms != self.deforms_was
        {
            let motions: Vec<TypeMotion> = TypeMotion::ALL.iter().copied().filter(|x| spec.motions.contains(x)).collect();
            let looks: Vec<TypeLook> = TypeLook::ALL.iter().copied().filter(|x| spec.looks.contains(x)).collect();
            let hards: Vec<TypeMotion> = motions.iter().copied().filter(|x| hard(*x)).collect();
            let pick = if motions.is_empty() {
                TypeMotion::Still
            } else if drop_landed && !hards.is_empty() {
                hards[((meme_hash(s9973, phrase as f64, 319.0) * hards.len() as f64).floor() as usize) % hards.len()]
            } else {
                pick_motion(&motions, drive, meme_hash(s9973, phrase as f64, 311.0))
            };
            if Some(pick) != self.motion_now {
                self.motion_was = self.motion_now;
                self.motion_now = Some(pick);
                self.blend = if self.motion_was.is_none() { 1.0 } else { 0.0 };
            }
            if !looks.is_empty() {
                self.look = looks[((meme_hash(s9973, phrase as f64, 313.0) * looks.len() as f64).floor() as usize) % looks.len()];
            }
            let bends: Vec<TypeDeform> = TypeDeform::ALL.iter().copied().filter(|x| spec.deforms.contains(x)).collect();
            let mut chosen = BTreeSet::new();
            for i in 0..2 {
                if chosen.len() >= bends.len() {
                    break;
                }
                let mut j = ((meme_hash(s9973, (phrase * 3 + i) as f64, 317.0) * bends.len() as f64).floor() as usize) % bends.len();
                while chosen.contains(&bends[j]) {
                    j = (j + 1) % bends.len();
                }
                chosen.insert(bends[j]);
            }
            // the drop's shatter whenever it is one of the hands'
            if spec.deforms.contains(&TypeDeform::Shatter) {
                chosen.insert(TypeDeform::Shatter);
            }
            self.bends = chosen;
            self.deforms_was = spec.deforms.clone();
            self.phrase_was = phrase;
        }
        self.bends.retain(|b| spec.deforms.contains(b));
        self.blend = (self.blend + dt / beats_per).min(1.0);
        // the continuous motions run faster the harder the music; the ones on the beat stay on it
        let step = if self.beats_was < 0.0 || (beats - self.beats_was).abs() > 4.0 { 0.0 } else { beats - self.beats_was };
        if self.beats_was < 0.0 {
            self.phase = beats * spec.speed;
        }
        self.beats_was = beats;
        self.phase += step * spec.speed * (0.7 + 0.8 * drive);
        let clock = |x: TypeMotion| if on_beat(x) { beats * spec.speed } else { self.phase };
        let now = self.motion_now.unwrap_or(TypeMotion::Still);
        let mut pose = motion(now, clock(now));
        if self.blend < 1.0
            && let Some(was) = self.motion_was
        {
            pose = motion(was, clock(was)).lerp(pose, ease(self.blend));
        }

        let kick = st.num("audio.kick").clamp(0.0, 1.0) * spec.beat;
        let snare = st.num("audio.snare").clamp(0.0, 1.0) * spec.beat;
        let low = st.num("audio.low").clamp(0.0, 1.0);
        self.hat += (st.num("audio.hat").clamp(0.0, 1.0) - self.hat) * (dt * 8.0).min(1.0);
        let energy = st.num("dyn.energy").clamp(0.0, 1.0);
        let ready = self.slots[self.on].is_some();
        self.fade = if ready { (self.fade + dt * 3.0).min(1.0) } else { 0.0 };

        // the drop, remembered past the deck's two beats; a build, by the drop coming
        let away = m.drop_beats_away;
        if playing
            && let Some(a) = away
            && a <= 0.0
            && a > -2.5
            && self.away_was.is_none_or(|w| w > 0.0)
        {
            self.drop_at = Some(beats + a);
        }
        if playing && m.section.as_deref() == Some("drop") && self.drop_at.is_none() {
            self.drop_at = Some(beats);
        }
        if self.drop_at.is_some_and(|d| beats - d > 16.0 || beats < d - 1.0) {
            self.drop_at = None;
        }
        self.away_was = away;
        let build = if m.section.as_deref() == Some("build") {
            m.section_k
        } else {
            away.filter(|a| *a > 0.0 && *a < 16.0).map_or(0.0, |a| 1.0 - a / 16.0)
        };
        let burst = self.drop_at.map_or(0.0, |d| (-(beats - d) / 2.5).exp());
        let phrase_in = beats.rem_euclid(16.0);

        // each bend by its own part of the music, eased toward it (the slices not: torn is
        // torn at once)
        for d in TypeDeform::ALL {
            let target = if !self.bends.contains(d) {
                0.0
            } else {
                match d {
                    TypeDeform::Inflate => 0.15 + 0.85 * kick,
                    TypeDeform::Ripple => 0.35 + 0.65 * low,
                    TypeDeform::Melt => ease(phrase_in / 14.0) * (0.35 + 0.65 * (1.0 - energy)) * if m.breakdown { 1.3 } else { 1.0 },
                    TypeDeform::Slice => snare,
                    TypeDeform::Shatter => burst.max((0.35 * build).max(0.3 * (-phrase_in * 1.2).exp())),
                    TypeDeform::Wobble => 0.3 + 1.2 * self.hat,
                    TypeDeform::Squash => 0.8 * kick,
                    TypeDeform::Arc => 0.35 * (TAU * beats.rem_euclid(4.0) / 4.0).sin(),
                    TypeDeform::Stack | TypeDeform::Repeat => 1.0,
                }
            };
            let want = target * spec.bend;
            let rate = if matches!(d, TypeDeform::Slice | TypeDeform::Inflate | TypeDeform::Squash) { 30.0 } else { 6.0 };
            let b = &mut self.bend[d.index()];
            *b += (want - *b) * (dt * rate).min(1.0);
        }
        let bent = |d: TypeDeform| {
            let v = self.bend[d.index()];
            if v.abs() < 1e-3 { 0.0 } else { v }
        };

        // the beat's accents, as hard as the music: a jolt round on every beat in a loud part,
        // the horizon ticked on the snare one way then the other, a whip once round on the drop
        let beat_now = beats.floor() as i64;
        if beat_now != self.beat_was {
            if self.beat_was >= 0 && drive > 0.5 {
                self.step_aim += 0.24 * (drive - 0.5) * 2.0;
            }
            self.beat_was = beat_now;
        }
        self.step_yaw += (self.step_aim - self.step_yaw) * (dt * 16.0).min(1.0);
        let whip = if self.drop_at.is_none() { 0.0 } else { TAU * (1.0 - burst.powf(0.6)) };
        let tick = 0.08 * snare * drive * if beat_now % 2 == 0 { 1.0 } else { -1.0 };
        // the camera's travel through the shot in a loud part, a new one every few bars
        let hold = cut_hold(16, drive);
        let sweep_n = (beats / hold as f64).floor() as i64;
        if sweep_n != self.sweep_n || drop_landed {
            self.sweep_n = sweep_n;
            self.sweep.cut(beats, hold, drive, meme_hash(s9973, sweep_n as f64, 323.0), false, false, false);
        }
        let sw = self.sweep.at(beats, drive, dt);
        let yaw = pose.yaw + self.step_yaw + whip - sw.yaw;
        let pitch = pose.pitch + swap_angle + 1.4 * sw.rise;
        let roll = pose.roll + tick + sw.roll;
        let (cy, sy, cp, sp, cr, sr) = (yaw.cos(), yaw.sin(), pitch.cos(), pitch.sin(), roll.cos(), roll.sin());
        // R = Ry · Rx · Rz (object to world); the shader wants the rows of the way back
        let (r00, r01, r02) = (cy * cr + sy * sp * sr, -cy * sr + sy * sp * cr, sy * cp);
        let (r10, r11, r12) = (cp * sr, cp * cr, -sp);
        let (r20, r21, r22) = (-sy * cr + cy * sp * sr, sy * sr + cy * sp * cr, cy * cp);
        let mut p = Params::default();
        p.set("uRotX", &[r00, r10, r20]);
        p.set("uRotY", &[r01, r11, r21]);
        p.set("uRotZ", &[r02, r12, r22]);

        let (a, bb) = (self.slots[0].as_deref(), self.slots[1].as_deref());
        let shown = self.slots[self.on].as_deref();
        let size = spec.size * (1.0 + 0.09 * kick) * self.fade;
        let s = size.max(1e-3);
        // the camera far enough that the wider of the two lines fills about four fifths of
        // the width
        let fov = 1.7;
        let aspect = w / h.max(1.0);
        let widest = a.map_or(0.0, |f| f.half_x).max(bb.map_or(0.0, |f| f.half_x));
        let text_half_w = ((if widest > 0.0 { widest } else { shown.map_or(1.0, |f| f.half_x) }) - field::RANGE_PX / field::FONT_PX) * spec.size;
        let dist = 2.2f64.max((text_half_w * fov / (0.8 * aspect * 0.5)).max(0.6 * spec.size * fov / 0.7));
        p.set("uTime", &[self.t]);
        // the kick: the letters thrown at the camera a little, as hard as the music
        let pos = [pose.x * dist * 0.5, pose.y * spec.size, (-dist + pose.z) * sw.dist + 0.16 * kick * drive * dist];
        p.set("uPos", &pos);
        p.set("uHalf", &[a.map_or(1.0, |f| f.half_x) * s, a.map_or(0.5, |f| f.half_y) * s]);
        p.set("uHalfB", &[bb.map_or(1.0, |f| f.half_x) * s, bb.map_or(0.5, |f| f.half_y) * s]);
        p.set("uRange", &[a.map_or(0.1, |f| f.range) * s]);
        p.set("uRangeB", &[bb.map_or(0.1, |f| f.range) * s]);
        p.set("uMix", &[mix]);
        p.set("uMixMode", &[if self.turn_how == TypeTurn::Glitch { 1.0 } else { 0.0 }]);
        p.set("uSeed", &[salt.rem_euclid(997) as f64 * 0.37 + phrase as f64 * 1.3]);
        p.set("uDepth", &[0.11 * spec.depth * size * (1.0 + 0.25 * low)]);
        p.set("uBevel", &[(0.02 * spec.bevel).min(0.05) * size]);
        p.set("uWave", &[pose.wave * size]);
        p.set("uWavePhase", &[beats * PI]);
        p.set("uTwist", &[pose.twist / (shown.map_or(1.0, |f| f.half_x) * s).max(0.2)]);
        p.set("uDeformA", &[bent(TypeDeform::Inflate) * s, bent(TypeDeform::Ripple), beats * TAU, bent(TypeDeform::Melt) * s]);
        p.set("uDeformB", &[bent(TypeDeform::Slice) * s, bent(TypeDeform::Shatter), bent(TypeDeform::Wobble), bent(TypeDeform::Squash).clamp(0.0, 1.5)]);
        // repeated: the rows a line and a half apart
        let repeat = if bent(TypeDeform::Repeat) > 0.5 { shown.map_or(0.5, |f| f.half_y) * s * 2.2 } else { 0.0 };
        p.set("uDeformC", &[bent(TypeDeform::Arc) / s, bent(TypeDeform::Stack).clamp(0.0, 1.0), (0.09 + 0.12 * kick) * s, repeat]);
        p.set("uLook", &[self.look.index() as f64]);
        let [ink, ink2, rim] = colours(spec.colour, st);
        p.set("uInk", &ink);
        p.set("uInk2", &ink2);
        p.set("uRim", &rim);
        p.set("uGlow", &[0.6 * spec.glow * self.fade]);
        p.set("uKick", &[kick]);
        p.set("uFlash", &[snare]);
        p.set("uFov", &[fov]);
        // seen from behind, or upside down: the letters turned back to be read (they pass
        // edge-on as it changes); the camera at the origin, in the object's space
        let behind = -(r02 * pos[0] + r12 * pos[1] + r22 * pos[2]) < 0.0;
        let down = r11 < 0.0;
        p.set("uMirror", &[if behind != down { -1.0 } else { 1.0 }, if down { -1.0 } else { 1.0 }]);
        // over a ground: glass bends it, and the blend mixes the letters by their coverage
        // (straight); on their own, premultiplied
        p.set("uGroundOn", &[if ground { 1.0 } else { 0.0 }]);
        p.set("uPremul", &[if ground { 0.0 } else { 1.0 }]);
        p.set("uResolution", &[w, h]);
        p
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wo_show::state::ShowMacros;

    fn st(spec: TypeSpec) -> ShowState {
        let mut s = ShowState { macros: ShowMacros { type3d: Some(spec), ..Default::default() }, ..Default::default() };
        s.a.playing = true;
        s.a.bpm = Some(128.0);
        s.a.beat_index = Some(0);
        s.a.bar_index = Some(0);
        s.a.beat_in_bar = Some(0);
        s
    }

    #[test]
    fn the_uniforms_are_the_shaders_in_its_order() {
        let src = include_str!("../../../../app/shaders/show/sim/type3d.frag");
        let mut floats = vec![];
        for line in src.lines() {
            let l = line.trim();
            let Some(rest) = l.strip_prefix("uniform ") else { continue };
            let mut it = rest.split_whitespace();
            let (ty, name) = (it.next().unwrap(), it.next().unwrap().trim_end_matches(';'));
            let n = match ty {
                "float" => 1,
                "vec2" => 2,
                "vec3" => 3,
                "vec4" => 4,
                _ => continue,
            };
            floats.push((name.to_owned(), n));
        }
        // the shader packs some floats four to a vec4 (uT00 = uRange uRangeB uMix uMixMode…):
        // the count is what has to match, and every unpacked name in order
        let total: usize = floats.iter().map(|f| f.1).sum();
        assert_eq!(total, UNIFORMS.iter().map(|u| u.1).sum::<usize>());
        let ours: Vec<&str> = UNIFORMS.iter().map(|u| u.0).collect();
        let mut at = 0;
        for (name, _) in &floats {
            if name.starts_with("uT") {
                continue;
            }
            let i = ours[at..].iter().position(|o| o == name).unwrap_or_else(|| panic!("{name} out of order"));
            at += i + 1;
        }
    }

    #[test]
    fn a_line_comes_on_then_turns_to_the_next() {
        let spec = TypeSpec { lines: vec!["ONE".into(), "TWO".into()], change: TypeChange::Bar, ..Default::default() };
        let mut sim = Type3dSim { at_once: true, ..Default::default() };
        let mut s = st(spec);
        let p = sim.tick(&s, 1.0 / 60.0, 1280.0, 720.0, false);
        assert_eq!(sim.field().unwrap().text, "ONE");
        assert_eq!(sim.take_placed().len(), 1);
        assert_eq!(p.flat().len(), 59);
        // a bar on: TWO turns in, over a beat
        s.a.bar_index = Some(1);
        s.a.beat_index = Some(4);
        sim.tick(&s, 1.0 / 60.0, 1280.0, 720.0, false);
        assert!(sim.turning());
        assert_eq!(sim.take_placed()[0].1.text, "TWO");
        for _ in 0..60 {
            sim.tick(&s, 1.0 / 60.0, 1280.0, 720.0, false);
        }
        assert!(!sim.turning());
        assert_eq!(sim.field().unwrap().text, "TWO");
    }

    #[test]
    fn the_bends_are_the_hands_and_shatter_always() {
        let spec = TypeSpec { deforms: vec![TypeDeform::Melt, TypeDeform::Shatter, TypeDeform::Arc], ..Default::default() };
        let mut sim = Type3dSim { at_once: true, ..Default::default() };
        sim.tick(&st(spec), 0.016, 800.0, 600.0, false);
        assert!(sim.bends().contains(&TypeDeform::Shatter));
        assert!(sim.bends().len() >= 2 && sim.bends().iter().all(|b| [TypeDeform::Melt, TypeDeform::Shatter, TypeDeform::Arc].contains(b)));
        let none = TypeSpec { deforms: vec![], ..Default::default() };
        sim.tick(&st(none), 0.016, 800.0, 600.0, false);
        assert!(sim.bends().is_empty());
    }
}
