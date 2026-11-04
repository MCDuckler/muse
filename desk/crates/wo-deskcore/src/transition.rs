//! A transition made on the decks, step by step (v1's Booth._play over Booth.plan; the
//! steps are wo_booth::steps). Each tick: the fader, each deck's filter, bands, pitch
//! shift, chop and stems where they are travelling; then every step reached — the bands
//! set, a loop caught or halved or let go, a brake, the echo, a part swapped, a sound of
//! the booth's own fired.
use wo_booth::steps::{self, DeckStep, EqSet, LoopStep, Side, Step};
use wo_booth::Transition;
use wo_engine::{DeckId, Eq};

use crate::{Desk, eq_db};

/// A transition's running state: its steps, the next to apply, the bands each deck had
/// when it began (a turn starts from there).
#[derive(Clone, Debug, Default)]
pub(crate) struct Running {
    pub steps: Vec<Step>,
    pub next: usize,
    pub eq_began: [EqSet; 2],
}

impl Running {
    /// `kind` over `bars`: its steps on the bars (a cut: across on the one).
    pub fn new(kind: Transition, bars: u32) -> Running {
        let steps = if kind == Transition::Cut {
            vec![Step { at: 0.0, crossfader: Some(1.0), from: None, to: None, fx: None }, Step {
                at: 1.0,
                crossfader: Some(1.0),
                from: None,
                to: None,
                fx: None,
            }]
        } else {
            steps::on_bars(steps::plan(kind), bars)
        };
        Running { steps, next: 0, eq_began: [EqSet::FLAT; 2] }
    }
}

/// How loud each side of a move is at fader place `x` (0 = the outgoing alone): the
/// "full" law (both whole at the middle) or equal power (each at 0.71 there).
pub fn law(x: f32, full: bool) -> (f32, f32) {
    let x = x.clamp(0.0, 1.0);
    if full {
        ((2.0 * (1.0 - x)).min(1.0), (2.0 * x).min(1.0))
    } else {
        let a = x * std::f32::consts::FRAC_PI_2;
        (a.cos(), a.sin())
    }
}

/// The outgoing's and the incoming's levels through `kind` over `bars`, at `k` (for
/// drawing the move).
pub fn levels_at(kind: Transition, bars: u32, k: f64) -> (f32, f32) {
    let r = Running::new(kind, bars);
    law(steps::fader_at(&r.steps, k), kind.full())
}

/// Where the incoming's bass comes back in `kind` over `bars`, in bars (the blends').
pub fn bass_swap_bar(kind: Transition, bars: u32) -> Option<f64> {
    steps::bass_swap(&Running::new(kind, bars).steps).map(|k| k * bars as f64)
}

/// A band's knob (0 kill, 0.5 flat, 1 +6 dB) for decibels: `eq_db` turned round.
pub(crate) fn knob_of_db(db: f32) -> f32 {
    if db >= 0.0 { (0.5 + db / 12.0).min(1.0) } else { 0.5 - 0.5 * (db / -40.0).clamp(0.0, 1.0).powf(1.0 / 1.5) }
}

impl Desk {
    /// Every move the planner considered for the transition planned, best first: the
    /// kind, its bars, why (the plan view's choices).
    pub fn mix_options(&self) -> Vec<(Transition, u32, String)> {
        self.mix.as_ref().map(|m| m.options.iter().map(|o| (o.kind, o.bars, o.why.clone())).collect()).unwrap_or_default()
    }

    /// How many of the booth's own sounds have been fired.
    pub fn sounds_fired(&self) -> u64 {
        self.fx.fired
    }

    /// Another move for the transition planned (a hand on the plan): `kind` over `bars`
    /// (or the bars planned), from the same out point. Not once it has started.
    pub fn choose_move(&mut self, kind: Transition, bars: Option<u32>) {
        let Some(m) = self.mix.as_ref().filter(|m| !m.started) else { return };
        let (from, to) = (m.from, m.to);
        let bars = bars.unwrap_or(m.bars).max(1);
        let bar = self.slots[from].timing.bar().unwrap_or(4.0 * self.spb(from));
        // what the last plan opened on the incoming is undone first
        self.slots[to].stems.mix = None;
        self.set_eq_db(to, EqSet::FLAT, 0.0);
        self.set_filter(to, 0.5);
        if let Some(m) = self.mix.as_mut() {
            m.kind = kind;
            m.bars = bars;
            m.length = bars as f64 * bar;
            m.run = Running::new(kind, bars);
        }
        self.open_move();
    }

    fn side_deck(&self, side: Side) -> Option<usize> {
        let m = self.mix.as_ref()?;
        Some(match side {
            Side::From => m.from,
            Side::To => m.to,
        })
    }

    /// The opening of a planned move on the incoming, before it makes a sound: its bands,
    /// its stems, its part (the outgoing is left alone until the move begins).
    pub(crate) fn open_move(&mut self) {
        let Some(m) = self.mix.as_ref() else { return };
        let to = m.to;
        let Some(first) = m.run.steps.first().copied() else { return };
        if let Some(d) = first.to {
            self.deck_step(to, &d);
        }
        if let Some(l) = steps::stems_at(&self.mix.as_ref().unwrap().run.steps, Side::To, 0.0) {
            self.stems_mix(to, Some(l));
        }
        // the move's own sounds, rendered now so each is there when its step comes
        let m = self.mix.as_ref().unwrap();
        let shots: Vec<steps::FxShot> = m.run.steps.iter().filter_map(|s| s.fx).collect();
        if !shots.is_empty() {
            let rate = self.engine.deck(DeckId::new(m.from).unwrap()).read().rate.max(0.01);
            let (move_s, beat) = (m.length / rate, self.spb(m.from) / rate);
            self.fx.prepare(&shots, move_s, beat);
        }
    }

    /// The move begins: what each deck has now is where its bands turn from, and the
    /// outgoing's side of the first step is done.
    pub(crate) fn begin_move(&mut self) {
        let Some(m) = self.mix.as_ref() else { return };
        let (from, to) = (m.from, m.to);
        let began = [from, to].map(|d| {
            let k = self.slots[d].eq;
            let db = eq_db(k);
            EqSet { low: db.low, mid: db.mid, high: db.high }
        });
        let first = m.run.steps.first().copied();
        if let Some(m) = self.mix.as_mut() {
            m.run.eq_began = began;
            m.run.next = 1;
        }
        if let Some(s) = first {
            if let Some(d) = s.from {
                self.deck_step(from, &d);
            }
            if let Some(shot) = s.fx {
                self.fire_fx(shot);
            }
        }
    }

    /// One tick of a running move at `k` (0..1).
    pub(crate) fn run_move(&mut self, k: f64) {
        let Some(m) = self.mix.as_ref() else { return };
        let (from, kind, bars) = (m.from, m.kind, m.bars);
        let run = m.run.clone();
        let full = kind.full();
        if self.full_law != full {
            self.full_law = full;
            self.apply_levels();
        }
        let x = steps::fader_at(&run.steps, k);
        let x = if from == 0 { x } else { 1.0 - x };
        if (x - self.crossfader).abs() > 1e-4 {
            self.set_crossfader(x);
        }
        let beat_k = 1.0 / (bars.max(1) as f64 * 4.0);
        for (side, began) in [(Side::From, run.eq_began[0]), (Side::To, run.eq_began[1])] {
            let Some(d) = self.side_deck(side) else { continue };
            if let Some(f) = steps::filter_at(&run.steps, side, k) {
                let knob = 0.5 + f / 2.0;
                if (self.slots[d].filter - knob).abs() > 1e-3 {
                    self.set_filter(d, knob);
                }
            }
            if let Some(e) = steps::eq_at(&run.steps, side, k, began, beat_k) {
                self.set_eq_db(d, e, 0.0);
            }
            if let Some(semis) = steps::shift_at(&run.steps, side, k)
                && (self.slots[d].shift - semis).abs() > 0.02
            {
                self.slots[d].shift = semis;
                self.engine.deck(DeckId::new(d).unwrap()).set_shift(semis as f64);
            }
            if let Some(depth) = steps::gate_at(&run.steps, side, k) {
                let div = steps::gate_div_at(&run.steps, side, k);
                self.set_gate(d, depth, div);
            }
            if let Some(l) = steps::stems_at(&run.steps, side, k)
                && !self.slots[d].stems.mix.is_some_and(|m| m.close_to(l))
            {
                self.stems_mix(d, Some(l));
            }
        }
        let mut next = run.next;
        while next < run.steps.len() && k >= run.steps[next].at {
            let s = run.steps[next];
            for (side, ds) in [(Side::From, s.from), (Side::To, s.to)] {
                if let (Some(d), Some(ds)) = (self.side_deck(side), ds) {
                    self.deck_step(d, &ds);
                }
            }
            if let Some(shot) = s.fx {
                self.fire_fx(shot);
            }
            next += 1;
        }
        if let Some(m) = self.mix.as_mut() {
            m.run.next = next;
        }
    }

    /// What a step does to deck `d` at once: the bands, a loop, a brake, the echo, a part.
    /// (The filter, shift, chop and stems are travelled to, in [Desk::run_move].)
    fn deck_step(&mut self, d: usize, s: &DeckStep) {
        if let Some(e) = s.eq {
            self.set_eq_db(d, e, 0.03);
        }
        match s.looped {
            Some(LoopStep::Bars(n)) => self.hands(d, |h, t| h.loop_from_bar(n as f64 * 4.0, t)),
            Some(LoopStep::Halve) => self.halve_loop(d),
            Some(LoopStep::Off) => self.unloop(d),
            None => {}
        }
        if s.brake {
            self.brake(d);
        }
        if s.echo.is_some() || s.dry.is_some() {
            let (send, dry) = (s.echo.unwrap_or(self.slots[d].echo.0), s.dry.unwrap_or(self.slots[d].echo.1));
            self.set_echo(d, send, dry);
        }
        if let Some(p) = s.part {
            self.set_part(d, p);
        }
    }

    /// Deck `d`'s bands in decibels, the knobs following.
    pub(crate) fn set_eq_db(&mut self, d: usize, e: EqSet, ramp: f64) {
        let knobs = [knob_of_db(e.low), knob_of_db(e.mid), knob_of_db(e.high)];
        if self.slots[d].eq == knobs {
            return;
        }
        self.slots[d].eq = knobs;
        self.engine.deck(DeckId::new(d).unwrap()).set_eq(Eq { low: e.low, mid: e.mid, high: e.high }, ramp);
    }

    /// Deck `d`'s echo: the send and the record's own level, a dotted echo of its beat as
    /// heard.
    pub(crate) fn set_echo(&mut self, d: usize, send: f32, dry: f32) {
        if self.slots[d].echo == (send, dry) {
            return;
        }
        self.slots[d].echo = (send, dry);
        let beat = self.spb(d) / self.engine.deck(DeckId::new(d).unwrap()).read().rate.max(0.01);
        self.engine.deck(DeckId::new(d).unwrap()).set_echo(send, dry, beat);
    }

    /// Deck `d`'s chop: `depth` deep, `div` chops to the record's own beat, counted from
    /// its first downbeat.
    pub(crate) fn set_gate(&mut self, d: usize, depth: f32, div: u32) {
        let period = self.spb(d) / div.max(1) as f64;
        let origin = self.slots[d].timing.first_downbeat.unwrap_or(0.0);
        if (self.slots[d].gate.0 - depth).abs() < 1e-3 && self.slots[d].gate.1 == div {
            return;
        }
        self.slots[d].gate = (depth, div);
        self.engine.deck(DeckId::new(d).unwrap()).set_gate(depth, period, origin);
    }

    /// A move's own stems levels on deck `d` (None: back to its part).
    pub(crate) fn stems_mix(&mut self, d: usize, l: Option<wo_booth::Levels>) {
        self.slots[d].stems.mix = l;
        self.apply_part(d, 0.0);
    }

    /// Everything a move did to deck `d` undone: bands flat, filter off, no loop, no chop,
    /// no echo, no shift, the stems back to its part.
    pub(crate) fn plain(&mut self, d: usize) {
        self.unloop(d);
        self.set_filter(d, 0.5);
        self.set_eq_db(d, EqSet::FLAT, 0.0);
        if self.slots[d].gate.0 > 0.0 {
            self.set_gate(d, 0.0, 2);
        }
        self.set_echo(d, 0.0, 1.0);
        if self.slots[d].shift != 0.0 {
            self.slots[d].shift = 0.0;
            self.engine.deck(DeckId::new(d).unwrap()).set_shift(0.0);
        }
        self.slots[d].stems.mix = None;
        self.apply_part(d, crate::parts::RAMP);
    }

    /// A sound of the booth's own, fired now (fx.rs).
    fn fire_fx(&mut self, shot: steps::FxShot) {
        let Some(m) = self.mix.as_ref() else { return };
        let beat = self.spb(m.from) / self.engine.deck(DeckId::new(m.from).unwrap()).read().rate.max(0.01);
        let seconds = shot.seconds(m.length / self.engine.deck(DeckId::new(m.from).unwrap()).read().rate.max(0.01), beat);
        self.fx.fire(&self.engine, shot, seconds, beat);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knobs_and_decibels_turn_round() {
        for db in [-40.0f32, -18.0, -12.0, -6.0, 0.0, 3.0, 6.0] {
            let k = knob_of_db(db);
            let back = eq_db([k, 0.5, 0.5]).low;
            assert!((back - db).abs() < 0.05, "{db} dB → knob {k} → {back} dB");
        }
    }

    #[test]
    fn the_laws() {
        let (a, b) = law(0.5, false);
        assert!((a - 0.7071).abs() < 1e-3 && (b - 0.7071).abs() < 1e-3);
        assert_eq!(law(0.5, true), (1.0, 1.0));
        assert_eq!(law(0.0, false), (1.0, 0.0));
    }
}
