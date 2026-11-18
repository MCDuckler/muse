//! rekordbox's effects on the Desk (the engine's fx.h): two BEAT FX units, FX1 and FX2,
//! each on a deck or the master, in time with its deck's beat (the master's for the
//! master) or a tapped tempo, each with its RELEASE FX; and the SOUND COLOR FX the
//! channels' knobs turn (FILTER, the knob's own, or SPACE, DUB ECHO, SWEEP, NOISE, CRUSH:
//! rekordbox's USER mode, one effect on every channel).
use std::time::Instant;

pub use wo_engine::{BeatFxKind, ColorFxKind, ReleaseFxKind};
use wo_engine::{BeatFx, DeckId, FxTarget};

use crate::Desk;

/// Where a unit is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Deck(usize),
    Master,
}

/// A BEAT FX unit as the Desk keeps it (and draws it).
#[derive(Clone, Debug, PartialEq)]
pub struct FxUnit {
    pub kind: BeatFxKind,
    pub on: bool,
    pub level: f32,
    pub beats: f64,
    pub param: f32,
    pub target: Target,
    /// A tapped tempo (TAP), else the deck's beat (AUTO).
    pub bpm: Option<f64>,
    pub release: ReleaseFxKind,
    pub release_beats: f64,
    /// Its RELEASE FX held.
    pub releasing: bool,
}

impl FxUnit {
    fn new(target: Target) -> FxUnit {
        FxUnit { kind: BeatFxKind::Echo, on: false, level: 0.5, beats: 1.0, param: 0.5, target, bpm: None, release: ReleaseFxKind::Echo, release_beats: 1.0, releasing: false }
    }
}

/// The SOUND COLOR FX the knobs turn, and its PARAMETER.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ColorFx {
    pub kind: ColorFxKind,
    pub param: f32,
}

/// The Desk's effects.
pub(crate) struct Fx {
    pub units: [FxUnit; 2],
    pub color: ColorFx,
    /// TAP: the taps, each unit's.
    taps: [Vec<Instant>; 2],
    /// The master deck the master's units last kept to.
    master_was: usize,
}

impl Default for Fx {
    fn default() -> Self {
        Fx { units: [FxUnit::new(Target::Deck(0)), FxUnit::new(Target::Deck(1))], color: ColorFx { kind: ColorFxKind::Filter, param: 0.5 }, taps: [vec![], vec![]], master_was: 0 }
    }
}

/// The beats a kind offers, `at` moved `dir` steps (a kind with none keeps 1).
fn step(kind: BeatFxKind, at: f64, dir: i32) -> f64 {
    let list = kind.beats();
    if list.is_empty() {
        return at;
    }
    let i = list.iter().position(|&b| (b - at).abs() < 1e-9).unwrap_or_else(|| list.iter().position(|&b| b >= at).unwrap_or(list.len() - 1)) as i32;
    list[(i + dir).clamp(0, list.len() as i32 - 1) as usize]
}

impl Desk {
    pub fn fx_units(&self) -> [FxUnit; 2] {
        self.beat_fx.units.clone()
    }

    pub fn color_fx(&self) -> ColorFx {
        self.beat_fx.color
    }

    /// A unit's state into the engine.
    fn send_fx(&mut self, u: usize) {
        let f = &self.beat_fx.units[u];
        let (target, tempo) = match f.target {
            Target::Deck(d) => (FxTarget::Deck(DeckId::new(d).unwrap()), d),
            Target::Master => (FxTarget::Master, self.master),
        };
        let fx = BeatFx { kind: f.kind, on: f.on, level: f.level, beats: f.beats, param: f.param, target, tempo: DeckId::new(tempo).unwrap(), bpm: f.bpm };
        self.engine.set_beat_fx(u, &fx);
        self.changes += 1;
    }

    pub fn set_fx_kind(&mut self, u: usize, kind: BeatFxKind) {
        let f = &mut self.beat_fx.units[u];
        if f.kind != kind {
            f.kind = kind;
            if !kind.beats().iter().any(|&b| (b - f.beats).abs() < 1e-9) {
                f.beats = kind.first_beats();
            }
        }
        self.send_fx(u);
    }

    /// FX SELECT: the next effect (or the one before).
    pub fn select_fx(&mut self, u: usize, dir: i32) {
        let all = BeatFxKind::ALL;
        let i = all.iter().position(|k| *k == self.beat_fx.units[u].kind).unwrap_or(0) as i32;
        let k = all[(i + dir).rem_euclid(all.len() as i32) as usize];
        self.set_fx_kind(u, k);
    }

    pub fn set_fx_on(&mut self, u: usize, on: bool) {
        self.beat_fx.units[u].on = on;
        self.send_fx(u);
    }

    pub fn toggle_fx(&mut self, u: usize) {
        let on = !self.beat_fx.units[u].on;
        self.set_fx_on(u, on);
    }

    pub fn set_fx_level(&mut self, u: usize, level: f32) {
        self.beat_fx.units[u].level = level.clamp(0.0, 1.0);
        self.send_fx(u);
    }

    pub fn set_fx_beats(&mut self, u: usize, beats: f64) {
        self.beat_fx.units[u].beats = beats;
        self.send_fx(u);
    }

    /// BEAT ◀ ▶.
    pub fn step_fx_beats(&mut self, u: usize, dir: i32) {
        let f = &self.beat_fx.units[u];
        let b = step(f.kind, f.beats, dir);
        self.set_fx_beats(u, b);
    }

    pub fn set_fx_param(&mut self, u: usize, p: f32) {
        self.beat_fx.units[u].param = p.clamp(0.0, 1.0);
        self.send_fx(u);
    }

    pub fn set_fx_target(&mut self, u: usize, t: Target) {
        self.beat_fx.units[u].target = t;
        self.send_fx(u);
    }

    /// TAP: four taps or more set the unit's tempo; AUTO (`None`) back to the deck's.
    pub fn tap_fx(&mut self, u: usize) {
        let now = Instant::now();
        let taps = &mut self.beat_fx.taps[u];
        if taps.last().is_some_and(|t| now.duration_since(*t).as_secs_f64() > 2.0) {
            taps.clear();
        }
        taps.push(now);
        if taps.len() > 8 {
            taps.remove(0);
        }
        if taps.len() >= 3 {
            let span = taps.last().unwrap().duration_since(taps[0]).as_secs_f64() / (taps.len() - 1) as f64;
            if span > 0.2 && span < 2.0 {
                self.beat_fx.units[u].bpm = Some(60.0 / span);
                self.send_fx(u);
            }
        }
    }

    pub fn auto_fx_tempo(&mut self, u: usize) {
        self.beat_fx.units[u].bpm = None;
        self.beat_fx.taps[u].clear();
        self.send_fx(u);
    }

    pub fn set_release_kind(&mut self, u: usize, k: ReleaseFxKind) {
        self.beat_fx.units[u].release = k;
        self.changes += 1;
    }

    pub fn set_release_beats(&mut self, u: usize, beats: f64) {
        self.beat_fx.units[u].release_beats = beats.clamp(0.25, 16.0);
        self.changes += 1;
    }

    /// The RELEASE FX held (the unit's BEAT FX turned off with it) or let go of.
    pub fn release_fx(&mut self, u: usize, hold: bool) {
        let f = &mut self.beat_fx.units[u];
        f.releasing = hold;
        if hold {
            f.on = false;
        }
        let (k, b) = (f.release, f.release_beats);
        self.engine.release_fx(u, k, hold, b);
        self.changes += 1;
    }

    /// The SOUND COLOR FX the knobs turn; the knobs' places sent again.
    pub fn set_color_fx(&mut self, kind: ColorFxKind) {
        self.beat_fx.color.kind = kind;
        for d in 0..2 {
            let v = self.slots[d].filter;
            self.set_filter(d, v);
        }
        self.changes += 1;
    }

    pub fn set_color_param(&mut self, p: f32) {
        self.beat_fx.color.param = p.clamp(0.0, 1.0);
        for d in 0..2 {
            let v = self.slots[d].filter;
            self.set_filter(d, v);
        }
    }

    /// The units on the master keep to the master deck's beat: sent again when it moves.
    pub(crate) fn fx_tick(&mut self) {
        if self.beat_fx.master_was != self.master {
            self.beat_fx.master_was = self.master;
            for u in 0..2 {
                if self.beat_fx.units[u].target == Target::Master {
                    self.send_fx(u);
                }
            }
        }
    }

    /// A controller's hand on the BEAT FX section (its first unit).
    pub(crate) fn fx_hand(&mut self, h: wo_control::FxHand) {
        use wo_control::FxHand as H;
        match h {
            H::Toggle => self.toggle_fx(0),
            H::To(Some(d)) => self.set_fx_target(0, Target::Deck(d.min(1))),
            H::To(None) => self.set_fx_target(0, Target::Master),
            H::Level(v) => self.set_fx_level(0, v),
            H::Beats(dir) => self.step_fx_beats(0, dir),
            H::Select(dir) => self.select_fx(0, dir),
            H::Release(hold) => self.release_fx(0, hold),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn beats_step_along_the_kinds_own() {
        assert_eq!(step(BeatFxKind::Echo, 1.0, 1), 2.0);
        assert_eq!(step(BeatFxKind::Echo, 1.0, -1), 0.75);
        assert_eq!(step(BeatFxKind::Echo, 16.0, 1), 16.0, "the end stays");
        assert_eq!(step(BeatFxKind::Flanger, 16.0, 1), 32.0);
        assert_eq!(step(BeatFxKind::Reverb, 1.0, 1), 1.0, "none to step");
        assert_eq!(step(BeatFxKind::Trans, 3.0, 1), 8.0, "off the list: from the next one up");
    }
}
