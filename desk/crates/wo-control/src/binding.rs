//! One binding for every controller (the v1 booth's, binding.dart): a control's event
//! as what the booth should do. STOP held is shift; SCRATCH flips the jog wheel; the
//! knob over a Hercules's fader is the filter; pads 1–4 are hot cues, 5 and 6 loop in
//! and out; shift + pitch reset cycles the pitch range. Knobs and faders take over only
//! once they reach where the booth is (soft takeover).
use std::collections::{HashMap, HashSet};

use crate::decode::Event;
use crate::layout::Kind;

/// Where the booth's knobs and faders are, 0..1, for soft takeover.
#[derive(Clone, Copy, Debug, Default)]
pub struct Positions {
    pub crossfader: f32,
    pub fader: [f32; 2],
    pub filter: [f32; 2],
    /// low, mid, high
    pub eq: [[f32; 3]; 2],
    /// the pitch fader, -1..1
    pub pitch: [f64; 2],
}

#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    PlayPause(usize),
    CueDown(usize),
    CueUp(usize),
    /// STOP tapped alone: stop, back on the cue point.
    Stop(usize),
    Sync(usize),
    Keylock(usize),
    PitchReset(usize),
    CyclePitchRange,
    /// The pitch fader, -1..1 of the deck's range.
    Pitch(usize, f64),
    Jog { deck: usize, ticks: f64, scratch: bool, shift: bool },
    Load(usize),
    /// Beats on (negative: back).
    Jump(usize, f64),
    Fader(usize, f32),
    Filter(usize, f32),
    /// band 0 low, 1 mid, 2 high; knob 0..1
    Eq(usize, usize, f32),
    KillToggle(usize, usize),
    Pad(usize, usize),
    ClearPad(usize, usize),
    LoopIn(usize),
    LoopOut(usize),
    HalveLoop(usize),
    Unloop(usize),
    Crossfader(f32),
    Browse(i32, i32),
}

/// How close counts as "there" for a knob to take over: three steps of a 7-bit knob.
const REACH: f64 = 3.0 / 127.0;

#[derive(Default)]
pub struct SoftTakeover {
    last_hw: HashMap<String, f64>,
    taken: HashMap<String, bool>,
}

impl SoftTakeover {
    /// Whether the hardware's `hw` for `id` is taken, the booth being at `sw`.
    pub fn accept(&mut self, id: &str, hw: f64, sw: f64) -> bool {
        let last = self.last_hw.insert(id.to_owned(), hw);
        if self.taken.get(id) == Some(&true) {
            if last.is_some_and(|l| (l - sw).abs() <= REACH * 2.0) {
                return true;
            }
            self.taken.insert(id.to_owned(), false);
        }
        let near = (hw - sw).abs() <= REACH;
        let crossed = last.is_some_and(|l| (l <= sw && hw >= sw) || (l >= sw && hw <= sw));
        if near || crossed {
            self.taken.insert(id.to_owned(), true);
        }
        near || crossed
    }

    pub fn drop(&mut self, id: &str) {
        self.last_hw.remove(id);
        self.taken.remove(id);
    }
}

#[derive(Default)]
pub struct Binding {
    shift_held: HashSet<usize>,
    shift_used: bool,
    pub scratch: bool,
    takeover: SoftTakeover,
}

/// "deck.b.eq.low" → (Some(1), "eq.low"); "mixer.crossfader" → (None, "mixer.crossfader").
fn split(id: &str) -> (Option<usize>, &str) {
    match id.strip_prefix("deck.") {
        Some(rest) if rest.len() > 2 && rest.as_bytes()[1] == b'.' => {
            let d = match rest.as_bytes()[0] {
                b'a' => 0,
                b'b' => 1,
                _ => return (None, id),
            };
            (Some(d), &rest[2..])
        }
        _ => (None, id),
    }
}

impl Binding {
    pub fn shift(&self) -> bool {
        !self.shift_held.is_empty()
    }

    /// What the booth should do for `e`, the booth's knobs being at `at`.
    pub fn handle(&mut self, e: &Event, at: &Positions) -> Vec<Action> {
        let (deck, name) = split(&e.id);
        let shift = self.shift();
        if shift && name != "stop" {
            self.shift_used = true;
        }
        let pressed = e.pressed();
        let Some(d) = deck else {
            return match name {
                "mixer.crossfader" if self.take(e, at.crossfader as f64) => vec![Action::Crossfader(e.value as f32)],
                "mixer.scratch" if pressed => {
                    self.scratch = !self.scratch;
                    vec![]
                }
                "browse.up" if pressed => vec![Action::Browse(0, -1)],
                "browse.down" if pressed => vec![Action::Browse(0, 1)],
                "browse.left" if pressed => vec![Action::Browse(-1, 0)],
                "browse.right" if pressed => vec![Action::Browse(1, 0)],
                _ => vec![],
            };
        };
        match name {
            "play" if pressed => vec![Action::PlayPause(d)],
            "cue" if e.kind == Kind::Button => vec![if pressed { Action::CueDown(d) } else { Action::CueUp(d) }],
            "stop" => {
                if pressed {
                    self.shift_held.insert(d);
                    self.shift_used = false;
                    vec![]
                } else {
                    self.shift_held.remove(&d);
                    // a tap on STOP with nothing else: the record stops, back on its cue
                    if !self.shift_used && !self.shift() { vec![Action::Stop(d)] } else { vec![] }
                }
            }
            "sync" if pressed => vec![Action::Sync(d)],
            "keylock" if pressed => vec![Action::Keylock(d)],
            "pitchReset" if pressed => {
                if shift {
                    self.takeover.drop("deck.a.pitch");
                    self.takeover.drop("deck.b.pitch");
                    vec![Action::CyclePitchRange]
                } else {
                    vec![Action::PitchReset(d)]
                }
            }
            "pitch" if self.take(e, (at.pitch[d] + 1.0) / 2.0) => vec![Action::Pitch(d, (e.value - 0.5) * 2.0)],
            "jog" => vec![Action::Jog { deck: d, ticks: e.value, scratch: self.scratch, shift }],
            "load" if pressed => vec![Action::Load(d)],
            "prev" | "next" if pressed => {
                let beats = if shift { 32.0 } else { 4.0 };
                vec![Action::Jump(d, if name == "prev" { -beats } else { beats })]
            }
            "volume" => {
                // a fader's last few steps read as its stop
                let v = if e.value < 0.02 { 0.0 } else { e.value };
                if self.take(e, at.fader[d] as f64) { vec![Action::Fader(d, v as f32)] } else { vec![] }
            }
            "gain" if self.take(e, at.filter[d] as f64) => {
                let v = if (e.value - 0.5).abs() < 0.03 { 0.5 } else { e.value };
                vec![Action::Filter(d, v as f32)]
            }
            "eq.low" | "eq.mid" | "eq.high" => {
                let band = match name {
                    "eq.low" => 0,
                    "eq.mid" => 1,
                    _ => 2,
                };
                if !self.take(e, at.eq[d][band] as f64) {
                    return vec![];
                }
                let v = if (e.value - 0.5).abs() < 0.012 { 0.5 } else { e.value };
                vec![Action::Eq(d, band, v as f32)]
            }
            "kill.low" if pressed => vec![Action::KillToggle(d, 0)],
            "kill.mid" if pressed => vec![Action::KillToggle(d, 1)],
            "kill.high" if pressed => vec![Action::KillToggle(d, 2)],
            _ => match name.strip_prefix("pad.").and_then(|n| n.parse::<usize>().ok()) {
                Some(n) if pressed => vec![match (n, shift) {
                    (5, false) => Action::LoopIn(d),
                    (5, true) => Action::HalveLoop(d),
                    (6, false) => Action::LoopOut(d),
                    (6, true) => Action::Unloop(d),
                    (n, false) => Action::Pad(d, n - 1),
                    (n, true) => Action::ClearPad(d, n - 1),
                }],
                _ => vec![],
            },
        }
    }

    fn take(&mut self, e: &Event, sw: f64) -> bool {
        !e.kind.positional() || self.takeover.accept(&e.id, e.value, sw)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn button(id: &str, down: bool) -> Event {
        Event { id: id.into(), kind: Kind::Button, value: down as u8 as f64 }
    }

    #[test]
    fn stop_is_shift_and_a_tap_stops() {
        let (mut b, at) = (Binding::default(), Positions::default());
        assert!(b.handle(&button("deck.a.stop", true), &at).is_empty());
        assert_eq!(b.handle(&button("deck.a.pad.2", true), &at), vec![Action::ClearPad(0, 1)], "shift + pad clears");
        assert!(b.handle(&button("deck.a.stop", false), &at).is_empty(), "used as shift: no stop");
        b.handle(&button("deck.b.stop", true), &at);
        assert_eq!(b.handle(&button("deck.b.stop", false), &at), vec![Action::Stop(1)], "a tap alone stops");
    }

    #[test]
    fn pads_loops_and_cue() {
        let (mut b, at) = (Binding::default(), Positions::default());
        assert_eq!(b.handle(&button("deck.a.pad.3", true), &at), vec![Action::Pad(0, 2)]);
        assert_eq!(b.handle(&button("deck.b.pad.5", true), &at), vec![Action::LoopIn(1)]);
        assert_eq!(b.handle(&button("deck.b.pad.6", true), &at), vec![Action::LoopOut(1)]);
        assert_eq!(b.handle(&button("deck.a.cue", true), &at), vec![Action::CueDown(0)]);
        assert_eq!(b.handle(&button("deck.a.cue", false), &at), vec![Action::CueUp(0)]);
    }

    #[test]
    fn knobs_take_over_only_when_they_reach_the_booth() {
        let mut b = Binding::default();
        let mut at = Positions::default();
        at.eq[0][0] = 0.5;
        let knob = |v: f64| Event { id: "deck.a.eq.low".into(), kind: Kind::Pot, value: v };
        assert!(b.handle(&knob(0.1), &at).is_empty(), "the knob is far from the booth's");
        assert!(b.handle(&knob(0.3), &at).is_empty());
        assert_eq!(b.handle(&knob(0.55), &at), vec![Action::Eq(0, 0, 0.55)], "crossed it: taken");
        at.eq[0][0] = 0.55;
        assert_eq!(b.handle(&knob(0.6), &at), vec![Action::Eq(0, 0, 0.6)]);
    }

    #[test]
    fn scratch_flips_the_jog() {
        let (mut b, at) = (Binding::default(), Positions::default());
        b.handle(&button("mixer.scratch", true), &at);
        let jog = Event { id: "deck.b.jog".into(), kind: Kind::Jog, value: 3.0 };
        assert_eq!(b.handle(&jog, &at), vec![Action::Jog { deck: 1, ticks: 3.0, scratch: true, shift: false }]);
    }
}
