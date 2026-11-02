//! One frame of the show (v1: show_state.dart, show_dynamics.dart, show_genome.dart,
//! show_palette.dart, ui/show/show_common.dart): the decks, the room's sound, the mix, the
//! palette, the hands, the record's genome and the dynamics — flattened by dotted name
//! (`master.beat.phase`, `audio.kick`, `dyn.hit.kick`), the names the shaders' common block and
//! the lights read.
use std::collections::BTreeMap;

use crate::deck::{Flat, ShowAudio, ShowDeck};
use crate::rig::ShowRig;
use crate::rng::{Rng, hash_str};

// ------------------------------------------------------------------ the mix

/// The transition on, or about to go.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ShowMix {
    pub on: bool,
    pub armed: bool,
    pub kind: Option<String>,
    pub from: Option<String>,
    pub to: Option<String>,
    pub bars: u32,
    /// 0..1 through, while on.
    pub k: f64,
    /// Seconds until it starts, while armed.
    pub starts_in: Option<f64>,
}

impl ShowMix {
    pub fn flat_into(&self, m: &mut Flat) {
        m.insert("mix.on".into(), if self.on { 1.0 } else { 0.0 });
        m.insert("mix.armed".into(), if self.armed { 1.0 } else { 0.0 });
        m.insert("mix.k".into(), self.k);
        m.insert("mix.bars".into(), self.bars as f64);
        m.insert("mix.startsIn".into(), self.starts_in.unwrap_or(0.0));
    }
}

// ------------------------------------------------------------------ the palette

/// A colour as hue (degrees), saturation and lightness.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Hsl {
    pub h: f64,
    pub s: f64,
    pub l: f64,
}

impl Hsl {
    pub fn rgb(&self) -> [f64; 3] {
        let c = (1.0 - (2.0 * self.l - 1.0).abs()) * self.s;
        let hp = (self.h.rem_euclid(360.0)) / 60.0;
        let x = c * (1.0 - (hp % 2.0 - 1.0).abs());
        let (r, g, b) = match hp as u32 {
            0 => (c, x, 0.0),
            1 => (x, c, 0.0),
            2 => (0.0, c, x),
            3 => (0.0, x, c),
            4 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        let m = self.l - c / 2.0;
        [r + m, g + m, b + m]
    }

    pub fn of_rgb(rgb: u32) -> Hsl {
        let [r, g, b] = [(rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255].map(|v| v as f64 / 255.0);
        let (max, min) = (r.max(g).max(b), r.min(g).min(b));
        let l = (max + min) / 2.0;
        let d = max - min;
        if d == 0.0 {
            return Hsl { h: 0.0, s: 0.0, l };
        }
        let s = d / (1.0 - (2.0 * l - 1.0).abs());
        let h = if max == r { 60.0 * (((g - b) / d) % 6.0) } else if max == g { 60.0 * ((b - r) / d + 2.0) } else { 60.0 * ((r - g) / d + 4.0) };
        Hsl { h: h.rem_euclid(360.0), s, l }
    }

    fn lerp(a: Hsl, b: Hsl, t: f64) -> Hsl {
        let mut d = (b.h - a.h).rem_euclid(360.0);
        if d > 180.0 {
            d -= 360.0;
        }
        Hsl { h: (a.h + d * t).rem_euclid(360.0), s: a.s + (b.s - a.s) * t, l: a.l + (b.l - a.l) * t }
    }
}

/// The show's colours: a primary, a secondary that answers it, an accent for the hits.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShowPalette {
    pub primary: Hsl,
    pub secondary: Hsl,
    pub accent: Hsl,
}

impl ShowPalette {
    pub const HOUSE: ShowPalette =
        ShowPalette { primary: Hsl { h: 262.0, s: 0.7, l: 0.55 }, secondary: Hsl { h: 190.0, s: 0.8, l: 0.5 }, accent: Hsl { h: 40.0, s: 0.9, l: 0.7 } };

    /// Eased towards `o`, the hue the short way round.
    pub fn lerp(&self, o: &ShowPalette, t: f64) -> ShowPalette {
        ShowPalette { primary: Hsl::lerp(self.primary, o.primary, t), secondary: Hsl::lerp(self.secondary, o.secondary, t), accent: Hsl::lerp(self.accent, o.accent, t) }
    }

    pub fn flat_into(&self, m: &mut Flat) {
        for (name, c) in [("primary", self.primary), ("secondary", self.secondary), ("accent", self.accent)] {
            m.insert(format!("palette.{name}.h"), c.h / 360.0);
            m.insert(format!("palette.{name}.s"), c.s);
            m.insert(format!("palette.{name}.l"), c.l);
            let [r, g, b] = c.rgb();
            m.insert(format!("palette.{name}.r"), r);
            m.insert(format!("palette.{name}.g"), g);
            m.insert(format!("palette.{name}.b"), b);
        }
    }
}

fn towards(a: f64, b: f64, k: f64) -> f64 {
    let mut d = (b - a).rem_euclid(360.0);
    if d > 180.0 {
        d -= 360.0;
    }
    (a + d * k).rem_euclid(360.0)
}

/// The palette for a record: its cover's colour turned a little towards its key, a second
/// colour a fixed way round (the record's own), an accent; the section lifts or dims it.
pub fn palette_for(cover_rgb: Option<u32>, key_hue: Option<f64>, section: Option<&str>, colour_turn: f64, apart: Option<f64>) -> ShowPalette {
    let mut base = cover_rgb.map(Hsl::of_rgb).unwrap_or(ShowPalette::HOUSE.primary);
    if base.s < 0.15
        && let Some(k) = key_hue
    {
        base.h = k * 360.0;
    }
    let mut hue = base.h;
    if let Some(k) = key_hue {
        hue = towards(hue, k * 360.0, 0.3);
    }
    hue = (hue + colour_turn * 360.0).rem_euclid(360.0);
    let primary = Hsl { h: hue, s: base.s.clamp(0.55, 0.95), l: 0.55 };
    let sat = match section {
        Some("drop" | "chorus") => 0.9,
        Some("breakdown" | "break") => 0.6,
        _ => 0.8,
    };
    let secondary = Hsl { h: (hue + apart.unwrap_or(150.0)).rem_euclid(360.0), s: sat, l: 0.52 };
    let accent = Hsl { h: (hue + 30.0).rem_euclid(360.0), s: 0.9, l: 0.78 };
    ShowPalette { primary, secondary, accent }
}

// ------------------------------------------------------------------ the genome

/// A record's own numbers, drawn once from a stream seeded by the record: the same record
/// looks like itself every time, no two alike.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Genome(pub BTreeMap<String, f64>);

impl Genome {
    pub fn get(&self, name: &str) -> f64 {
        self.0.get(name).copied().unwrap_or(0.0)
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn of(track_id: i64, camelot: Option<&str>, bpm: Option<f64>, cover_rgb: Option<u32>) -> Genome {
        let mut seed = (track_id as u64).wrapping_mul(2_654_435_761);
        if let Some(c) = camelot {
            seed ^= hash_str(c).wrapping_mul(97);
        }
        if let Some(b) = bpm {
            seed ^= ((b * 10.0).round() as u64).wrapping_mul(31);
        }
        if let Some(c) = cover_rgb {
            seed ^= (c as u64).wrapping_mul(7);
        }
        let mut r = Rng::new(seed);
        let pace = (bpm.unwrap_or(125.0) - 90.0) / 90.0;
        let mut g = BTreeMap::new();
        let mut put = |k: &str, v: f64| {
            g.insert(k.to_owned(), v);
        };
        put("feedback.zoom", r.range(0.985, 1.025));
        put("feedback.rotate", r.range(-0.012, 0.012) * (0.5 + pace));
        put("feedback.fold", r.pick(&[0.0, 0.0, 0.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0]));
        let w = r.range(0.0, 0.5);
        put("feedback.warp", w * r.range(0.0, 1.0));
        put("feedback.hueTurn", r.range(-0.02, 0.02));
        put("feedback.shiftX", r.range(-0.004, 0.004));
        put("feedback.shiftY", r.range(-0.004, 0.004));
        put("feedback.decay", r.range(0.3, 0.75));
        put("fluid.swirl", r.range(0.3, 1.6));
        put("fluid.fade", r.range(0.95, 0.985));
        put("fluid.push", r.range(0.6, 1.4));
        put("veins.look", r.range(5.0, 14.0));
        put("veins.wide", r.range(0.25, 0.7));
        put("veins.turn", r.range(0.2, 0.6));
        put("veins.decay", r.range(0.86, 0.95));
        put("palette.turn", r.range(-0.06, 0.06));
        put("palette.apart", r.pick(&[35.0, 60.0, 120.0, 150.0, 180.0, 210.0]));
        put("camera.zoom", r.range(0.1, 0.9));
        put("camera.turn", r.range(0.0, 1.0));
        put("camera.hue", r.range(0.1, 0.9));
        put("camera.fold", r.pick(&[0.0, 0.0, 0.15, 0.4, 0.6, 0.85]));
        put("blocks.salt", r.range(0.0, 1.0));
        put("kinetic.salt", r.range(0.0, 1.0));
        put("glide.salt", r.range(0.0, 1.0));
        put("palette.sat", r.range(0.85, 1.1));
        for s in ["drift", "build", "tunnel", "kaleido", "type", "grid", "fluid", "veins", "flash", "echo", "fold", "blocks", "kinetic", "glide"] {
            put(&format!("scene.{s}"), r.pick(&[0.4, 0.7, 1.0, 1.0, 1.3, 1.8]));
        }
        for s in ["dance-art", "dance-disco", "dance-neon", "dance-shadow", "flock", "turntable", "lyrics", "siebenschlaefer", "milk", "type3d"] {
            put(&format!("scene.{s}"), r.pick(&[0.7, 1.0, 1.0, 1.0, 1.3, 1.5]));
        }
        Genome(g)
    }

    pub fn flat_into(&self, m: &mut Flat) {
        for (k, v) in &self.0 {
            m.insert(format!("gene.{k}"), *v);
        }
    }
}

// ------------------------------------------------------------------ the dynamics

#[derive(Clone, Debug)]
struct Follower {
    fast: f64,
    slow: f64,
    peak: f64,
    trough: f64,
    hit: f64,
    last: f64,
}

impl Default for Follower {
    fn default() -> Self {
        Follower { fast: 0.0, slow: 0.0, peak: 0.3, trough: 0.0, hit: 0.0, last: 0.0 }
    }
}

impl Follower {
    fn feed(&mut self, v: f64, dt: f64, release: f64, fall: f64, sensitivity: f64) {
        if v >= self.fast {
            self.fast = v;
        } else {
            self.fast += (v - self.fast) * (1.0 - (-dt / release).exp());
        }
        self.slow += (v - self.slow) * (1.0 - (-dt / 1.4).exp());
        self.peak = (self.peak * (-dt / 6.0).exp()).max(0.12).max(v);
        self.trough = (self.trough + (self.peak - self.trough) * (1.0 - (-dt / 3.0).exp())).min(v);
        let rising = v > self.last + 0.02;
        let leap = (v - self.slow * 1.1).max(0.0) / self.peak * sensitivity;
        if rising && leap > 0.18 {
            self.hit = self.hit.max(leap.clamp(0.0, 1.0));
        } else {
            self.hit *= (-dt / fall).exp();
        }
        self.last = v;
    }

    fn gain(&self) -> f64 {
        ((self.fast - self.trough) / (self.peak - self.trough).max(0.05)).clamp(0.0, 1.0)
    }
}

/// The record's sound turned into what a picture answers: hits against the floor and the
/// record's own scale, adaptive bands, an exposure following the loudness, and the grid's
/// exact ramps — by `dyn.*` name.
#[derive(Clone, Debug)]
pub struct Dynamics {
    sub: Follower,
    low: Follower,
    mid: Follower,
    high: Follower,
    air: Follower,
    kick: Follower,
    onset: Follower,
    snare: Follower,
    hat: Follower,
    loud: f64,
    exposure: f64,
    energy: f64,
}

impl Default for Dynamics {
    fn default() -> Self {
        let f = Follower::default;
        Dynamics { sub: f(), low: f(), mid: f(), high: f(), air: f(), kick: f(), onset: f(), snare: f(), hat: f(), loud: 0.0, exposure: 0.7, energy: 0.0 }
    }
}

impl Dynamics {
    /// One frame `dt` seconds after the last; `heard`: the sound is the engine's measure
    /// (with the snare's and the hats' own onsets).
    pub fn frame(&mut self, audio: &ShowAudio, master: &ShowDeck, dt: f64, heard: bool) -> Flat {
        let dt = dt.clamp(1.0 / 240.0, 0.1);
        let a = audio;
        self.sub.feed(a.sub, dt, 0.15, 0.2, 1.0);
        self.low.feed(a.low, dt, 0.14, 0.2, 1.0);
        self.mid.feed(a.mid, dt, 0.1, 0.2, 1.0);
        self.high.feed(a.high, dt, 0.08, 0.2, 1.0);
        self.air.feed(a.air, dt, 0.06, 0.2, 1.0);
        self.kick.feed(a.kick, dt, 0.1, 0.18, if heard { 1.0 } else { 1.3 });
        self.onset.feed(a.onset, dt, 0.08, 0.15, 1.0);
        self.snare.feed(a.snare, dt, 0.08, 0.18, 1.0);
        self.hat.feed(a.hat, dt, 0.06, 0.12, 1.0);
        let kick_hit = self.kick.hit.max(self.sub.hit.min(self.low.hit) * 0.8);
        let snare_hit = if heard { self.snare.hit.max(self.mid.hit * 0.5) } else { self.mid.hit.max(self.onset.hit * 0.7) } * (1.0 - kick_hit * 0.5);
        let top_hit = if heard { self.hat.hit.max(self.air.hit * 0.8) } else { self.air.hit.max(self.high.hit * 0.8) };
        let loud = a.sub * 0.3 + a.low * 0.35 + a.mid * 0.25 + a.high * 0.1;
        let tau = if loud > self.loud { 0.3 } else { 2.0 };
        self.loud += (loud - self.loud) * (1.0 - (-dt / tau).exp());
        let want = 0.45 + 0.65 * (self.loud / 0.15f64.max(self.low.peak.max(self.mid.peak)));
        self.exposure += (want.clamp(0.35, 1.2) - self.exposure) * (1.0 - (-dt / 0.4).exp());
        let m = master;
        let energy = (m.energy * (0.4 + 0.6 * m.channel.level)).clamp(0.0, 1.0);
        self.energy += (energy - self.energy) * (1.0 - (-dt / 0.8).exp());
        let (beat, bar, phrase) = (m.beat_phase, m.bar_phase, m.phrase_phase);
        let in_bar = m.beat_in_bar.unwrap_or(0);
        let gridded = m.playing && m.beat_index.is_some();
        let g = |v: f64| if gridded { v } else { 0.0 };
        Flat::from([
            ("dyn.hit.kick".into(), kick_hit),
            ("dyn.hit.snare".into(), snare_hit),
            ("dyn.hit.top".into(), top_hit),
            ("dyn.hit.any".into(), kick_hit.max(snare_hit).max(top_hit)),
            ("dyn.band.sub".into(), self.sub.gain()),
            ("dyn.band.low".into(), self.low.gain()),
            ("dyn.band.mid".into(), self.mid.gain()),
            ("dyn.band.high".into(), self.high.gain()),
            ("dyn.band.air".into(), self.air.gain()),
            ("dyn.loud".into(), self.loud),
            ("dyn.exposure".into(), self.exposure),
            ("dyn.energy".into(), self.energy),
            ("dyn.beat.saw".into(), beat),
            ("dyn.beat.decay".into(), g((-beat * 6.0).exp())),
            ("dyn.beat.pulse".into(), g((beat * std::f64::consts::PI).cos().max(0.0).powi(3))),
            ("dyn.half.saw".into(), ((in_bar % 2) as f64 + beat) / 2.0),
            ("dyn.bar.saw".into(), bar),
            ("dyn.bar.decay".into(), g((-bar * 5.0).exp())),
            ("dyn.phrase.saw".into(), phrase),
            ("dyn.phrase.decay".into(), g((-phrase * 4.0).exp())),
            ("dyn.downbeat".into(), if gridded && in_bar == 0 { (-beat * 6.0).exp() } else { 0.0 }),
        ])
    }
}

// ------------------------------------------------------------------ the hands

/// The performer's hands on the show.
#[derive(Clone, Debug, PartialEq)]
pub struct ShowMacros {
    /// A master for everything, 0..1.
    pub intensity: f64,
    /// A turn of the palette's hue, 0..1 round.
    pub colour: f64,
    /// The strobe held, 0..1.
    pub strobe: f64,
    pub blackout: bool,
    pub freeze: bool,
    /// The last hit, 1 as it lands and falling.
    pub hit: f64,
    /// The session's own number.
    pub seed: i64,
    /// The stages lower their working size while frames come late.
    pub adapt: bool,
    /// Eight knobs each scene reads its own way.
    pub macros: Vec<f64>,
    /// The treatments' knobs (show_tune), the pool's.
    pub tune: BTreeMap<String, f64>,
    /// Who dances (None or "mix": each record its own).
    pub dancer: Option<String>,
    pub dancers_off: Vec<String>,
    /// The MilkDrop preset on, by full name.
    pub milk_preset: Option<String>,
}

impl Default for ShowMacros {
    fn default() -> Self {
        ShowMacros {
            intensity: 1.0,
            colour: 0.0,
            strobe: 0.0,
            blackout: false,
            freeze: false,
            hit: 0.0,
            seed: 0,
            adapt: true,
            macros: vec![],
            tune: BTreeMap::new(),
            dancer: None,
            dancers_off: vec![],
            milk_preset: None,
        }
    }
}

impl ShowMacros {
    pub fn flat_into(&self, m: &mut Flat) {
        let b = |v: bool| if v { 1.0 } else { 0.0 };
        m.insert("show.intensity".into(), self.intensity);
        m.insert("show.colour".into(), self.colour);
        m.insert("show.strobe".into(), self.strobe);
        m.insert("show.blackout".into(), b(self.blackout));
        m.insert("show.freeze".into(), b(self.freeze));
        m.insert("show.hit".into(), self.hit);
        m.insert("show.seed".into(), self.seed as f64);
        for (i, v) in self.macros.iter().enumerate() {
            m.insert(format!("show.macro.{}", i + 1), *v);
        }
    }
}

// ------------------------------------------------------------------ the frame

/// One frame of the show.
#[derive(Clone, Debug, PartialEq)]
pub struct ShowState {
    /// Seconds since the last frame.
    pub dt: f64,
    pub a: ShowDeck,
    pub b: ShowDeck,
    /// Which deck has the room ("A" or "B").
    pub master_name: String,
    /// The room's sound.
    pub audio: ShowAudio,
    pub mix: ShowMix,
    pub palette: ShowPalette,
    pub macros: ShowMacros,
    pub set_k: f64,
    pub set_energy: f64,
    /// The scene on, the one being left, and how far across (1: wholly on).
    pub scene: Option<String>,
    pub scene_from: Option<String>,
    pub scene_k: f64,
    /// The datamoshes so far.
    pub mosh: i64,
    pub rig: ShowRig,
    pub rig_from: Option<ShowRig>,
    pub genome: Genome,
    pub dyn_: Flat,
}

impl Default for ShowState {
    fn default() -> Self {
        ShowState {
            dt: 0.0,
            a: ShowDeck { name: "A".into(), ..Default::default() },
            b: ShowDeck { name: "B".into(), ..Default::default() },
            master_name: "A".into(),
            audio: ShowAudio::SILENCE,
            mix: ShowMix::default(),
            palette: ShowPalette::HOUSE,
            macros: ShowMacros::default(),
            set_k: 0.0,
            set_energy: 0.0,
            scene: None,
            scene_from: None,
            scene_k: 1.0,
            mosh: 0,
            rig: ShowRig::default(),
            rig_from: None,
            genome: Genome::default(),
            dyn_: Flat::new(),
        }
    }
}

impl ShowState {
    pub fn master(&self) -> &ShowDeck {
        if self.master_name == "B" { &self.b } else { &self.a }
    }

    pub fn other(&self) -> &ShowDeck {
        if self.master_name == "B" { &self.a } else { &self.b }
    }

    /// Everything, by dotted name.
    pub fn flat(&self) -> Flat {
        let mut m = Flat::new();
        m.insert("time.dt".into(), self.dt);
        self.a.flat_into(&mut m, "deck.a");
        self.b.flat_into(&mut m, "deck.b");
        self.master().flat_into(&mut m, "master");
        m.insert("master.isB".into(), if self.master_name == "B" { 1.0 } else { 0.0 });
        self.audio.flat_into(&mut m, "audio");
        self.mix.flat_into(&mut m);
        self.palette.flat_into(&mut m);
        self.macros.flat_into(&mut m);
        m.insert("set.k".into(), self.set_k);
        m.insert("set.energy".into(), self.set_energy);
        m.insert("show.scene.k".into(), self.scene_k);
        self.genome.flat_into(&mut m);
        m.extend(self.dyn_.iter().map(|(k, v)| (k.clone(), *v)));
        let (ma, ot) = (self.master(), self.other());
        let intensity = if self.macros.blackout { 0.0 } else { (ma.energy * ma.channel.level + ot.energy * ot.channel.level).clamp(0.0, 1.0) * self.macros.intensity };
        m.insert("intensity".into(), intensity);
        m
    }

    /// This frame `dt` seconds later, the decks carried on.
    pub fn advanced(&self, dt: f64) -> ShowState {
        ShowState { dt, a: self.a.advanced(dt), b: self.b.advanced(dt), ..self.clone() }
    }
}

/// A scene shader's knob `k` (1..4): the record's genome where the scene reads one, else the
/// scene file's (v1: show_common.dart layerKnob).
pub fn layer_knob(shader: &str, file_knob: f64, k: usize, genome: &Genome) -> f64 {
    if !genome.is_empty() {
        match (shader, k) {
            ("echo", 1..=3) => return genome.get(["camera.zoom", "camera.turn", "camera.hue"][k - 1]),
            ("fold", 1) => return genome.get("camera.fold"),
            ("blocks", 1) => return genome.get("blocks.salt"),
            ("kinetic", 1) => return genome.get("kinetic.salt"),
            ("glide", 1) => return genome.get("glide.salt"),
            _ => {}
        }
    }
    file_knob
}

/// uTime .. uBarIndex (shaders/show/common.glsl, after uResolution) for a scene layer at
/// `time` seconds of the stage's clock: the 35 floats every scene shader reads.
pub fn common_block(flat: &Flat, knobs: [f64; 4], time: f64) -> [f32; 35] {
    let f = |k: &str| flat.get(k).copied().unwrap_or(0.0);
    let v: [f64; 35] = [
        time,
        f("master.beat.phase"),
        f("master.bar.phase"),
        f("master.phrase.phase"),
        f("master.energy"),
        f("intensity"),
        f("audio.kick"),
        f("audio.low"),
        f("audio.mid"),
        f("audio.high"),
        f("audio.air"),
        f("audio.onset"),
        f("palette.primary.h"),
        f("palette.secondary.h"),
        f("master.drop.near"),
        f("master.build.k"),
        f("show.hit"),
        f("master.vocal"),
        knobs[0],
        knobs[1],
        knobs[2],
        knobs[3],
        f("dyn.hit.kick"),
        f("dyn.hit.snare"),
        f("dyn.hit.top"),
        f("dyn.beat.decay"),
        f("dyn.bar.decay"),
        f("dyn.bar.saw"),
        f("dyn.phrase.saw"),
        f("dyn.downbeat"),
        flat.get("dyn.exposure").copied().unwrap_or(0.7),
        f("dyn.band.low"),
        f("dyn.band.mid"),
        f("dyn.band.high"),
        f("master.bar.index"),
    ];
    v.map(|x| x as f32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::deck::{Channel, RecordFacts};

    #[test]
    fn a_record_looks_like_itself_and_no_two_alike() {
        let a = Genome::of(42, Some("8A"), Some(128.0), Some(0xff3366));
        assert_eq!(a, Genome::of(42, Some("8A"), Some(128.0), Some(0xff3366)));
        assert_ne!(a, Genome::of(43, Some("8A"), Some(128.0), Some(0xff3366)));
        let z = a.get("feedback.zoom");
        assert!((0.985..1.025).contains(&z));
        assert!([0.4, 0.7, 1.0, 1.3, 1.8].contains(&a.get("scene.kinetic")));
    }

    #[test]
    fn the_palette_from_a_cover_and_a_key() {
        let p = palette_for(Some(0xff0000), Some(0.5), Some("drop"), 0.0, Some(180.0));
        assert!((p.primary.h - 54.0).abs() < 1e-6, "red turned 30 % of the way to 180°: {}", p.primary.h);
        assert_eq!(p.secondary.s, 0.9);
        assert!((p.secondary.h - 234.0).abs() < 1e-6);
        let [r, g, b] = Hsl { h: 0.0, s: 1.0, l: 0.5 }.rgb();
        assert!((r - 1.0).abs() < 1e-9 && g.abs() < 1e-9 && b.abs() < 1e-9);
        let back = Hsl::of_rgb(0x3366cc);
        let [r, g, b] = back.rgb();
        assert!((r * 255.0 - 0x33 as f64).abs() < 0.6 && (g * 255.0 - 0x66 as f64).abs() < 0.6 && (b * 255.0 - 0xcc as f64).abs() < 0.6);
    }

    #[test]
    fn a_kick_is_a_hit_and_the_grid_ramps_are_exact() {
        let facts = RecordFacts { beats_ms: (0..64).map(|i| i as f64 * 500.0).collect(), steady: Some((0.0, 500.0)), ..Default::default() };
        let mut dynamics = Dynamics::default();
        let mut last = Flat::new();
        for i in 0..120 {
            let ms = i as f64 * 1000.0 / 60.0;
            let deck = ShowDeck::derive("A", Some(&facts), true, ms, Channel::default(), ShowAudio::SILENCE);
            // a kick on each beat, lasting a sixtieth
            let on = (ms % 500.0) < 17.0;
            let audio = ShowAudio { kick: if on { 0.9 } else { 0.05 }, low: if on { 0.8 } else { 0.2 }, ..Default::default() };
            last = dynamics.frame(&audio, &deck, 1.0 / 60.0, true);
            if on && i > 30 {
                assert!(last["dyn.hit.kick"] > 0.5, "frame {i}: the kick leaps");
            }
        }
        assert!(last["dyn.hit.kick"] < 0.5, "and falls between");
        assert!(last["dyn.beat.decay"] > 0.0);
    }

    #[test]
    fn the_common_block_is_in_the_shaders_order() {
        let mut s = ShowState::default();
        s.macros.hit = 0.75;
        let mut flat = s.flat();
        flat.insert("master.beat.phase".into(), 0.25);
        flat.insert("dyn.band.high".into(), 0.5);
        let c = common_block(&flat, [0.1, 0.2, 0.3, 0.4], 9.0);
        assert_eq!(c[0], 9.0, "uTime");
        assert_eq!(c[1], 0.25, "uBeat");
        assert_eq!(c[16], 0.75, "uHit");
        assert_eq!(c[18..22], [0.1, 0.2, 0.3, 0.4], "uM1..uM4");
        assert_eq!(c[30], 0.7, "uExposure before the dynamics run");
        assert_eq!(c[33], 0.5, "uBandHigh");
    }
}
