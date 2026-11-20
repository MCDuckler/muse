//! One binding for every controller (the v1 booth's, binding.dart): a control's event
//! as what the booth should do. STOP held is shift (a SHIFT button is too, and only that);
//! SCRATCH flips the jog wheel (a platter's touched top always scratches; a platter that
//! says it is searching, the DDJ's SHIFT + top, searches); the knob over a Hercules's fader
//! is the filter; pads 1–4 are hot cues, 5 and 6 loop in and out; shift + pitch reset
//! cycles both decks' pitch ranges, a TEMPO RANGE button (the DDJ's SHIFT + BEAT SYNC) its
//! own deck's, the slider then across the new range. Controllers with more say it by name: hot cues 1–8,
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
    /// the headphones: the cue/master blend and their level
    pub head_mix: f32,
    pub head_level: f32,
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
    /// The deck's pitch range, the next one (the rate kept).
    CyclePitchRange(usize),
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
    /// The BEAT FX section (its first unit): rekordbox's, as a DJM's or a DDJ's.
    Fx(FxHand),
    Crossfader(f32),
    /// The deck in the headphones, or out of them (its CUE / PFL button).
    Headphones(usize),
    /// The headphones' blend, 0 the cued decks alone .. 1 the master alone.
    HeadMix(f32),
    /// The headphones' level knob, 0..1.
    HeadLevel(f32),
    Browse(i32, i32),
    /// The show (the stage's director), as the v1 booth binds it.
    Show(ShowCue),
}

/// A hand on the BEAT FX section.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FxHand {
    /// ON/OFF.
    Toggle,
    /// CH SELECT: a deck, or the master (None).
    To(Option<usize>),
    /// LEVEL/DEPTH, 0..1.
    Level(f32),
    /// BEAT ◀ ▶: the beats a step down or up.
    Beats(i32),
    /// FX SELECT: the next effect (−1 with SHIFT: the one before).
    Select(i32),
    /// The RELEASE FX held (SHIFT + ON/OFF) or let go of.
    Release(bool),
}

/// What a controller does to the show. SOURCE has no use in the booth, so it is the
/// show's (v1's binding.dart): a hit (A) or the blackout (B); with shift, the picture
/// frozen (A) or the strobe for as long as it is held (B). PFL is the headphones' where
/// there are some; in a booth with one output it is the show's too: the scene before (A)
/// or after (B) (with headphones: shift + PFL). Layouts may also name `show.*` controls.
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

    /// Where the hardware's `id` is, if it has taken over (it is where the booth is).
    pub fn held(&self, id: &str) -> Option<f64> {
        if self.taken.get(id) == Some(&true) { self.last_hw.get(id).copied() } else { None }
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
    /// SHIFT + ON/OFF held: the RELEASE FX on until it is let go of.
    releasing: bool,
    /// The booth has headphones (a second output): PFL cues decks into them.
    pub headphones: bool,
}

impl Default for Binding {
    fn default() -> Self {
        Binding {
            shift_held: HashSet::new(),
            shift_used: false,
            scratch: false,
            takeover: SoftTakeover::default(),
            releasing: false,
            headphones: false,
        }
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
                "mixer.headMix" if self.take(e, at.head_mix as f64) => {
                    let v = if (e.value - 0.5).abs() < 0.012 { 0.5 } else { e.value };
                    vec![Action::HeadMix(v as f32)]
                }
                "mixer.headGain" if self.take(e, at.head_level as f64) => vec![Action::HeadLevel(e.value as f32)],
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
                // SHIFT + ON/OFF: the RELEASE FX while held (its let-go may come on either note)
                "fx.on" if pressed && self.shift() => {
                    self.releasing = true;
                    vec![Action::Fx(FxHand::Release(true))]
                }
                "fx.on" if pressed => vec![Action::Fx(FxHand::Toggle)],
                "fx.on" if e.kind == Kind::Button && self.releasing => {
                    self.releasing = false;
                    vec![Action::Fx(FxHand::Release(false))]
                }
                "fx.to.a" if pressed => vec![Action::Fx(FxHand::To(Some(0)))],
                "fx.to.b" if pressed => vec![Action::Fx(FxHand::To(Some(1)))],
                "fx.to.master" if pressed => vec![Action::Fx(FxHand::To(None))],
                "fx.level" => vec![Action::Fx(FxHand::Level(e.value as f32))],
                "fx.beat.left" if pressed => vec![Action::Fx(FxHand::Beats(-1))],
                "fx.beat.right" if pressed => vec![Action::Fx(FxHand::Beats(1))],
                "fx.select" if pressed => vec![Action::Fx(FxHand::Select(if self.shift() { -1 } else { 1 }))],
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
                    vec![Action::CyclePitchRange(0), Action::CyclePitchRange(1)]
                } else {
                    vec![Action::PitchReset(d)]
                }
            }
            "pitch" if self.take(e, (at.pitch[d] + 1.0) / 2.0) => vec![Action::Pitch(d, (e.value - 0.5) * 2.0)],
            "jog" => vec![Action::Jog { deck: d, ticks: e.value, scratch: self.scratch, shift }],
            "jog.scratch" => vec![Action::Jog { deck: d, ticks: e.value, scratch: true, shift }],
            // the controller's own SHIFT + platter (the DDJ's): a search whatever we think of shift
            "jog.search" => vec![Action::Jog { deck: d, ticks: e.value, scratch: false, shift: true }],
            // as rekordbox: this deck's range, and the slider (where it has taken over) across
            // it at once — the rate is where the slider is in the new range
            "tempoRange" if pressed => {
                let id = format!("deck.{}.pitch", if d == 0 { 'a' } else { 'b' });
                match self.takeover.held(&id) {
                    Some(hw) => vec![Action::CyclePitchRange(d), Action::Pitch(d, (hw - 0.5) * 2.0)],
                    None => vec![Action::CyclePitchRange(d)],
                }
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
            "pfl" if pressed && self.headphones && !shift => vec![Action::Headphones(d)],
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
        // with headphones PFL cues the deck into them; shift + PFL is still the show's
        b.headphones = true;
        assert_eq!(b.handle(&button("deck.a.pfl", true), &at), vec![Action::Headphones(0)]);
        assert_eq!(b.handle(&button("deck.a.pfl", false), &at), vec![]);
        b.handle(&button("deck.b.stop", true), &at);
        assert_eq!(b.handle(&button("deck.b.pfl", true), &at), vec![Action::Show(ShowCue::Next)]);
        b.handle(&button("deck.b.stop", false), &at);
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
        assert_eq!(b.handle(&button("deck.a.tempoRange", true), &at), vec![Action::CyclePitchRange(0)]);
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
    fn the_fx_section_is_rekordbox_s_beat_fx() {
        let (mut b, at) = (Binding::default(), Positions::default());
        let level = |v: f64| Event { id: "fx.level".into(), kind: Kind::Pot, value: v };
        assert_eq!(b.handle(&level(0.8), &at), vec![Action::Fx(FxHand::Level(0.8))]);
        assert_eq!(b.handle(&button("fx.on", true), &at), vec![Action::Fx(FxHand::Toggle)]);
        assert!(b.handle(&button("fx.on", false), &at).is_empty(), "ON/OFF acts on its press");
        assert_eq!(b.handle(&button("fx.to.b", true), &at), vec![Action::Fx(FxHand::To(Some(1)))]);
        assert_eq!(b.handle(&button("fx.to.master", true), &at), vec![Action::Fx(FxHand::To(None))]);
        assert_eq!(b.handle(&button("fx.beat.right", true), &at), vec![Action::Fx(FxHand::Beats(1))]);
        assert_eq!(b.handle(&button("fx.select", true), &at), vec![Action::Fx(FxHand::Select(1))]);
        // with SHIFT: the effect before; ON/OFF the RELEASE FX while held
        b.handle(&button("deck.a.shift", true), &at);
        assert_eq!(b.handle(&button("fx.select", true), &at), vec![Action::Fx(FxHand::Select(-1))]);
        assert_eq!(b.handle(&button("fx.on", true), &at), vec![Action::Fx(FxHand::Release(true))]);
        b.handle(&button("deck.a.shift", false), &at);
        assert_eq!(b.handle(&button("fx.on", false), &at), vec![Action::Fx(FxHand::Release(false))], "let go of, even after SHIFT");
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
    fn the_ddj_s_shift_and_platter_searches() {
        let (mut b, at) = (Binding::default(), Positions::default());
        let search = Event { id: "deck.b.jog.search".into(), kind: Kind::Jog, value: -4.0 };
        assert_eq!(b.handle(&search, &at), vec![Action::Jog { deck: 1, ticks: -4.0, scratch: false, shift: true }], "a search, though no SHIFT was heard");
    }

    /// The DDJ-400's SHIFT + BEAT SYNC: its own deck's range, the slider (taken over) then
    /// across the new range; one far from the booth's still waits.
    #[test]
    fn tempo_range_is_the_deck_s_and_the_slider_follows() {
        let mut b = Binding::default();
        let mut at = Positions::default();
        let slider = |id: &str, v: f64| Event { id: id.into(), kind: Kind::Fader, value: v };
        assert_eq!(b.handle(&slider("deck.a.pitch", 0.5), &at), vec![Action::Pitch(0, 0.0)]);
        assert_eq!(b.handle(&slider("deck.a.pitch", 0.75), &at), vec![Action::Pitch(0, 0.5)], "toward you: faster");
        at.pitch[0] = 0.5;
        assert_eq!(b.handle(&button("deck.a.tempoRange", true), &at), vec![Action::CyclePitchRange(0), Action::Pitch(0, 0.5)]);
        assert!(b.handle(&button("deck.a.tempoRange", false), &at).is_empty());
        // B's slider far from the booth's: the range alone, the rate kept
        assert!(b.handle(&slider("deck.b.pitch", 0.9), &at).is_empty());
        assert_eq!(b.handle(&button("deck.b.tempoRange", true), &at), vec![Action::CyclePitchRange(1)]);
        // the RMX's shift + pitch reset: both decks
        b.handle(&button("deck.a.stop", true), &at);
        assert_eq!(b.handle(&button("deck.a.pitchReset", true), &at), vec![Action::CyclePitchRange(0), Action::CyclePitchRange(1)]);
    }

    #[test]
    fn scratch_flips_the_jog() {
        let (mut b, at) = (Binding::default(), Positions::default());
        b.handle(&button("mixer.scratch", true), &at);
        let jog = Event { id: "deck.b.jog".into(), kind: Kind::Jog, value: 3.0 };
        assert_eq!(b.handle(&jog, &at), vec![Action::Jog { deck: 1, ticks: 3.0, scratch: true, shift: false }]);
    }
}
