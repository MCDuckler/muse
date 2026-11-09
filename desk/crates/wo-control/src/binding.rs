//! One binding for every controller (the v1 booth's, binding.dart): a control's event
//! as what the booth should do. STOP held is shift (a SHIFT button is too, and only that);
//! SCRATCH flips the jog wheel (a platter's touched top always scratches); the knob over a
//! Hercules's fader is the filter; pads 1–4 are hot cues, 5 and 6 loop in and out; shift +
//! pitch reset cycles the pitch range. Controllers with more say it by name: hot cues 1–8,
//! beat loops and jumps of so many beats, the loop buttons, a trim, a filter, a browse knob,
//! an FX section (the echo). Knobs and faders take over only once they reach where the
//! booth is (soft takeover).
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
    /// the trim, 0.5 unity
    pub gain: [f32; 2],
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
    /// `ticks` as the booth counts them (128 a turn); `shift`: searching.
    Jog { deck: usize, ticks: f64, scratch: bool, shift: bool },
    Load(usize),
    /// Beats on (negative: back).
    Jump(usize, f64),
    Fader(usize, f32),
    /// The trim, 0..1 (0.5 unity).
    Gain(usize, f32),
    Filter(usize, f32),
    /// band 0 low, 1 mid, 2 high; knob 0..1
    Eq(usize, usize, f32),
    KillToggle(usize, usize),
    Pad(usize, usize),
    ClearPad(usize, usize),
    LoopIn(usize),
    LoopOut(usize),
    HalveLoop(usize),
    DoubleLoop(usize),
    /// A loop of so many beats from the bar (the same again lets go).
    LoopBeats(usize, f64),
    Unloop(usize),
    /// The deck's echo send, 0 for none (its tail rings out).
    Echo(usize, f32),
    Crossfader(f32),
    Browse(i32, i32),
    /// The show (the stage's director), as the v1 booth binds it.
    Show(ShowCue),
}

/// What a controller does to the show. PFL and SOURCE have no use in a booth with one
/// output, so they are the show's (v1's binding.dart): PFL the scene before (A) or after
/// (B); SOURCE a hit (A) or the blackout (B); with shift, the picture frozen (A) or the
/// strobe for as long as it is held (B). Layouts may also name `show.*` controls.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ShowCue {
    Previous,
    Next,
    Hit,
    /// Toggles.
    Blackout,
    /// Toggles.
    Freeze,
    Strobe(bool),
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

    /// Whether `id` has been heard and is not (or no longer) taken.
    pub fn waits(&self, id: &str) -> bool {
        self.last_hw.contains_key(id) && self.taken.get(id) != Some(&true)
    }
}

pub struct Binding {
    shift_held: HashSet<usize>,
    shift_used: bool,
    pub scratch: bool,
    takeover: SoftTakeover,
    /// The FX section: on, how much, on which deck (None: both).
    pub fx_on: bool,
    pub fx_level: f32,
    pub fx_to: Option<usize>,
}

impl Default for Binding {
    fn default() -> Self {
        Binding { shift_held: HashSet::new(), shift_used: false, scratch: false, takeover: SoftTakeover::default(), fx_on: false, fx_level: 0.5, fx_to: None }
    }
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

    /// Whether knob or fader `id` was moved but waits to reach the booth's (soft takeover).
    pub fn waits(&self, id: &str) -> bool {
        self.takeover.waits(id)
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
                "browse.turn" if e.value != 0.0 => vec![Action::Browse(0, e.value.round() as i32)],
                "browse.up" if pressed => vec![Action::Browse(0, -1)],
                "browse.down" if pressed => vec![Action::Browse(0, 1)],
                "browse.left" if pressed => vec![Action::Browse(-1, 0)],
                "browse.right" if pressed => vec![Action::Browse(1, 0)],
                "show.scene.prev" if pressed => vec![Action::Show(ShowCue::Previous)],
                "show.scene.next" if pressed => vec![Action::Show(ShowCue::Next)],
                "show.hit" if pressed => vec![Action::Show(ShowCue::Hit)],
                "show.blackout" if pressed => vec![Action::Show(ShowCue::Blackout)],
                "show.freeze" if pressed => vec![Action::Show(ShowCue::Freeze)],
                "show.strobe" if e.kind == Kind::Button => vec![Action::Show(ShowCue::Strobe(pressed))],
                "fx.on" if pressed => {
                    self.fx_on = !self.fx_on;
                    self.echo()
                }
                "fx.to.a" | "fx.to.b" | "fx.to.master" if pressed => {
                    self.fx_to = match name {
                        "fx.to.a" => Some(0),
                        "fx.to.b" => Some(1),
                        _ => None,
                    };
                    if self.fx_on { self.echo() } else { vec![] }
                }
                "fx.level" => {
                    self.fx_level = e.value as f32;
                    if self.fx_on { self.echo() } else { vec![] }
                }
                _ => vec![],
            };
        };
        match name {
            "play" if pressed => vec![Action::PlayPause(d)],
            "cue" if e.kind == Kind::Button => vec![if pressed { Action::CueDown(d) } else { Action::CueUp(d) }],
            // a SHIFT of its own: only ever shift
            "shift" => {
                if pressed { self.shift_held.insert(d) } else { self.shift_held.remove(&d) };
                vec![]
            }
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
            "jog.scratch" => vec![Action::Jog { deck: d, ticks: e.value, scratch: true, shift }],
            "tempoRange" if pressed => {
                self.takeover.drop("deck.a.pitch");
                self.takeover.drop("deck.b.pitch");
                vec![Action::CyclePitchRange]
            }
            "trim" if self.take(e, at.gain[d] as f64) => {
                let v = if (e.value - 0.5).abs() < 0.012 { 0.5 } else { e.value };
                vec![Action::Gain(d, v as f32)]
            }
            "loop.in" if pressed => vec![Action::LoopIn(d)],
            "loop.out" if pressed => vec![Action::LoopOut(d)],
            "loop.exit" if pressed => vec![Action::Unloop(d)],
            "loop.halve" if pressed => vec![Action::HalveLoop(d)],
            "loop.double" if pressed => vec![Action::DoubleLoop(d)],
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
            "gain" | "filter" if self.take(e, at.filter[d] as f64) => {
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
            "pfl" if pressed => vec![Action::Show(if d == 0 { ShowCue::Previous } else { ShowCue::Next })],
            "source" if e.kind == Kind::Button => match (shift, d) {
                (true, 0) if pressed => vec![Action::Show(ShowCue::Freeze)],
                (true, 1) => vec![Action::Show(ShowCue::Strobe(pressed))],
                (false, 0) if pressed => vec![Action::Show(ShowCue::Hit)],
                (false, 1) if pressed => vec![Action::Show(ShowCue::Blackout)],
                _ => vec![],
            },
            "kill.low" if pressed => vec![Action::KillToggle(d, 0)],
            "kill.mid" if pressed => vec![Action::KillToggle(d, 1)],
            "kill.high" if pressed => vec![Action::KillToggle(d, 2)],
            _ if !pressed => vec![],
            _ => {
                let number = |prefix: &str| name.strip_prefix(prefix).and_then(|n| n.parse::<f64>().ok()).filter(|n| n.is_finite());
                if let Some(n) = number("pad.").filter(|n| *n >= 1.0 && *n <= 8.0) {
                    vec![match (n as usize, shift) {
                        (5, false) => Action::LoopIn(d),
                        (5, true) => Action::HalveLoop(d),
                        (6, false) => Action::LoopOut(d),
                        (6, true) => Action::Unloop(d),
                        (n, false) => Action::Pad(d, n - 1),
                        (n, true) => Action::ClearPad(d, n - 1),
                    }]
                } else if let Some(n) = number("hotcue.").filter(|n| *n >= 1.0 && *n <= 8.0) {
                    let n = n as usize - 1;
                    vec![if shift { Action::ClearPad(d, n) } else { Action::Pad(d, n) }]
                } else if let Some(b) = number("beatloop.").filter(|b| *b > 0.0) {
                    vec![Action::LoopBeats(d, b)]
                } else if let Some(b) = number("beatjump.").filter(|b| *b != 0.0) {
                    vec![Action::Jump(d, b)]
                } else {
                    vec![]
                }
            }
        }
    }

    /// The echo as the FX section says: its send on the deck(s) it is on, none elsewhere.
    fn echo(&self) -> Vec<Action> {
        (0..2).map(|d| Action::Echo(d, if self.fx_on && self.fx_to.is_none_or(|t| t == d) { self.fx_level } else { 0.0 })).collect()
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
        // PFL and SOURCE are the show's
        assert_eq!(b.handle(&button("deck.a.pfl", true), &at), vec![Action::Show(ShowCue::Previous)]);
        assert_eq!(b.handle(&button("deck.b.pfl", true), &at), vec![Action::Show(ShowCue::Next)]);
        assert_eq!(b.handle(&button("deck.a.source", true), &at), vec![Action::Show(ShowCue::Hit)]);
        assert!(b.handle(&button("deck.a.source", false), &at).is_empty());
        assert_eq!(b.handle(&button("deck.b.source", true), &at), vec![Action::Show(ShowCue::Blackout)]);
        b.handle(&button("deck.a.stop", true), &at);
        assert_eq!(b.handle(&button("deck.b.source", true), &at), vec![Action::Show(ShowCue::Strobe(true))], "shift: the strobe while held");
        assert_eq!(b.handle(&button("deck.b.source", false), &at), vec![Action::Show(ShowCue::Strobe(false))]);
        assert_eq!(b.handle(&button("deck.a.source", true), &at), vec![Action::Show(ShowCue::Freeze)]);
        b.handle(&button("deck.a.stop", false), &at);
    }

    #[test]
    fn knobs_take_over_only_when_they_reach_the_booth() {
        let mut b = Binding::default();
        let mut at = Positions::default();
        at.eq[0][0] = 0.5;
        let knob = |v: f64| Event { id: "deck.a.eq.low".into(), kind: Kind::Pot, value: v };
        assert!(b.handle(&knob(0.1), &at).is_empty(), "the knob is far from the booth's");
        assert!(b.handle(&knob(0.3), &at).is_empty());
        assert!(b.waits("deck.a.eq.low") && !b.waits("deck.a.eq.mid"));
        assert_eq!(b.handle(&knob(0.55), &at), vec![Action::Eq(0, 0, 0.55)], "crossed it: taken");
        at.eq[0][0] = 0.55;
        assert!(!b.waits("deck.a.eq.low"));
        assert_eq!(b.handle(&knob(0.6), &at), vec![Action::Eq(0, 0, 0.6)]);
    }

    #[test]
    fn a_shift_button_is_only_shift() {
        let (mut b, at) = (Binding::default(), Positions::default());
        assert!(b.handle(&button("deck.a.shift", true), &at).is_empty());
        assert!(b.shift());
        assert_eq!(b.handle(&button("deck.b.hotcue.7", true), &at), vec![Action::ClearPad(1, 6)], "either SHIFT shifts both decks");
        assert!(b.handle(&button("deck.a.shift", false), &at).is_empty(), "let go: no stop");
        assert!(!b.shift());
        assert_eq!(b.handle(&button("deck.b.hotcue.7", true), &at), vec![Action::Pad(1, 6)]);
    }

    #[test]
    fn hot_cues_loops_and_jumps_by_name() {
        let (mut b, at) = (Binding::default(), Positions::default());
        assert_eq!(b.handle(&button("deck.a.hotcue.5", true), &at), vec![Action::Pad(0, 4)], "5–8 are hot cues too");
        assert!(b.handle(&button("deck.a.hotcue.5", false), &at).is_empty());
        assert!(b.handle(&button("deck.a.hotcue.9", true), &at).is_empty(), "the booth has eight");
        assert_eq!(b.handle(&button("deck.b.beatloop.0.25", true), &at), vec![Action::LoopBeats(1, 0.25)]);
        assert_eq!(b.handle(&button("deck.b.beatjump.-8", true), &at), vec![Action::Jump(1, -8.0)]);
        assert_eq!(b.handle(&button("deck.a.loop.exit", true), &at), vec![Action::Unloop(0)]);
        assert_eq!(b.handle(&button("deck.a.loop.double", true), &at), vec![Action::DoubleLoop(0)]);
        assert_eq!(b.handle(&button("deck.a.tempoRange", true), &at), vec![Action::CyclePitchRange]);
        let browse = Event { id: "browse.turn".into(), kind: Kind::Encoder, value: -2.0 };
        assert_eq!(b.handle(&browse, &at), vec![Action::Browse(0, -2)]);
    }

    #[test]
    fn trim_and_filter_take_over() {
        let mut b = Binding::default();
        let at = Positions { gain: [0.5, 0.5], filter: [0.5, 0.5], ..Positions::default() };
        let trim = |v: f64| Event { id: "deck.b.trim".into(), kind: Kind::Pot, value: v };
        assert!(b.handle(&trim(0.9), &at).is_empty());
        assert_eq!(b.handle(&trim(0.501), &at), vec![Action::Gain(1, 0.5)], "near the middle is the middle");
        let filter = Event { id: "deck.a.filter".into(), kind: Kind::Pot, value: 0.5 };
        assert_eq!(b.handle(&filter, &at), vec![Action::Filter(0, 0.5)]);
    }

    #[test]
    fn the_fx_section_is_the_echo() {
        let (mut b, at) = (Binding::default(), Positions::default());
        let level = |v: f64| Event { id: "fx.level".into(), kind: Kind::Pot, value: v };
        assert!(b.handle(&level(0.8), &at).is_empty(), "off: the knob only waits");
        assert_eq!(b.handle(&button("fx.on", true), &at), vec![Action::Echo(0, 0.8), Action::Echo(1, 0.8)], "MASTER: both");
        assert_eq!(b.handle(&button("fx.to.b", true), &at), vec![Action::Echo(0, 0.0), Action::Echo(1, 0.8)]);
        assert_eq!(b.handle(&level(0.4), &at), vec![Action::Echo(0, 0.0), Action::Echo(1, 0.4)]);
        assert_eq!(b.handle(&button("fx.on", true), &at), vec![Action::Echo(0, 0.0), Action::Echo(1, 0.0)], "off: the tails ring out");
    }

    #[test]
    fn a_touched_platter_scratches() {
        let (mut b, at) = (Binding::default(), Positions::default());
        let jog = |id: &str| Event { id: id.into(), kind: Kind::Jog, value: 2.0 };
        assert_eq!(b.handle(&jog("deck.a.jog.scratch"), &at), vec![Action::Jog { deck: 0, ticks: 2.0, scratch: true, shift: false }]);
        assert_eq!(b.handle(&jog("deck.a.jog"), &at), vec![Action::Jog { deck: 0, ticks: 2.0, scratch: false, shift: false }]);
        b.handle(&button("deck.b.shift", true), &at);
        assert_eq!(b.handle(&jog("deck.a.jog"), &at), vec![Action::Jog { deck: 0, ticks: 2.0, scratch: false, shift: true }], "SHIFT: search");
        assert!(b.handle(&button("deck.a.jog.touch", true), &at).is_empty());
    }

    #[test]
    fn scratch_flips_the_jog() {
        let (mut b, at) = (Binding::default(), Positions::default());
        b.handle(&button("mixer.scratch", true), &at);
        let jog = Event { id: "deck.b.jog".into(), kind: Kind::Jog, value: 3.0 };
        assert_eq!(b.handle(&jog, &at), vec![Action::Jog { deck: 1, ticks: 3.0, scratch: true, shift: false }]);
    }
}
