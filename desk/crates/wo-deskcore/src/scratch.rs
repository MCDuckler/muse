//! Hands on the records: true scratching. A controller's touch-sensitive platter (the
//! DDJ-400's `jog.touch`) puts a hand on its deck's record and its turns (`jog.scratch`)
//! take the record with them; a wheel with no touch (the RMX) does the same in SCRATCH
//! mode while it turns, and lets go once it stops. Read on the controller's own thread
//! (a [wo_control::Lane]), straight to the engine — a hand cannot wait for the Desk's next
//! frame. The on-screen platter's drag is a hand too ([Desk::scratch]).
//!
//! A turn of the wheel is a turn of vinyl at 33⅓: 1.8 seconds of the record.
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use wo_control::{Event, Kind};
use wo_engine::{DeckId, Engine, Hand};

/// Seconds of the record in one of the booth's jog ticks (128 a turn).
pub const SECONDS_A_TICK: f64 = 1.8 / wo_control::layout::JOG_TICKS;

/// A wheel with no touch lets go once it has not turned for this long.
const LET_GO: Duration = Duration::from_millis(100);

pub struct Scratcher {
    hands: [Hand; 2],
    /// A hand on each record.
    on: [AtomicBool; 2],
    /// …put there by a wheel turning (no touch), and when it last turned (µs since t0).
    turning: [AtomicBool; 2],
    last: [AtomicU64; 2],
    /// SHIFT (or STOP, the RMX's shift) held on each deck: then the wheel searches.
    shift: [AtomicBool; 2],
    /// SCRATCH mode (the binding's toggle), for wheels with no touch.
    pub mode: AtomicBool,
    t0: Instant,
}

/// "deck.b.jog.touch" → (1, "jog.touch").
fn deck_of(id: &str) -> Option<(usize, &str)> {
    let rest = id.strip_prefix("deck.")?;
    let d = match rest.as_bytes().first()? {
        b'a' => 0,
        b'b' => 1,
        _ => return None,
    };
    Some((d, rest.get(2..)?))
}

const SIDE: [&str; 2] = ["A", "B"];

impl Scratcher {
    pub fn new(engine: &Engine) -> Scratcher {
        let hand = |d| engine.hand(DeckId::new(d).unwrap());
        Scratcher {
            hands: [hand(0), hand(1)],
            on: Default::default(),
            turning: Default::default(),
            last: Default::default(),
            shift: Default::default(),
            mode: AtomicBool::new(false),
            t0: Instant::now(),
        }
    }

    /// Whether a hand is on deck `d`'s record.
    pub fn held(&self, d: usize) -> bool {
        self.on[d].load(Ordering::Acquire)
    }

    /// A hand on deck `d`'s record, or off it.
    pub fn hold(&self, d: usize, on: bool) {
        if self.on[d].swap(on, Ordering::AcqRel) != on {
            self.hands[d].scratch(on);
        }
        if !on {
            self.turning[d].store(false, Ordering::Release);
        }
    }

    /// The hand on deck `d`'s record moved it `seconds` (nothing without a hand on it).
    pub fn by(&self, d: usize, seconds: f64) {
        if self.held(d) {
            self.hands[d].scratch_by(seconds);
        }
    }

    /// A controller's event, on its own thread: what was done with it, or None for the
    /// binding to have.
    pub fn heard(&self, e: &Event) -> Option<String> {
        let (d, name) = deck_of(&e.id)?;
        let shift = || self.shift.iter().any(|s| s.load(Ordering::Acquire));
        match name {
            // seen, and still the binding's
            "shift" | "stop" if e.kind == Kind::Button => {
                self.shift[d].store(e.pressed(), Ordering::Release);
                None
            }
            "jog.touch" if e.pressed() => {
                // SHIFT + the platter searches (the binding's): no hand
                if shift() {
                    return None;
                }
                self.turning[d].store(false, Ordering::Release);
                self.hold(d, true);
                Some(format!("a hand on {}'s record", SIDE[d]))
            }
            "jog.touch" => {
                if !self.held(d) {
                    return None;
                }
                self.hold(d, false);
                Some(format!("{}'s record let go", SIDE[d]))
            }
            "jog.scratch" if self.held(d) => {
                self.hands[d].scratch_by(e.value * SECONDS_A_TICK);
                Some(format!("{}'s record {:+.1} ms", SIDE[d], e.value * SECONDS_A_TICK * 1000.0))
            }
            // a wheel with no touch, in SCRATCH mode: a hand while it turns
            "jog" if self.mode.load(Ordering::Acquire) && !shift() => {
                self.last[d].store(self.t0.elapsed().as_micros() as u64, Ordering::Release);
                if !self.held(d) {
                    self.turning[d].store(true, Ordering::Release);
                    self.hold(d, true);
                }
                self.hands[d].scratch_by(e.value * SECONDS_A_TICK);
                Some(format!("{}'s record {:+.1} ms", SIDE[d], e.value * SECONDS_A_TICK * 1000.0))
            }
            _ => None,
        }
    }

    /// Each frame: a wheel with no touch that stopped turning lets go.
    pub fn tick(&self) {
        let now = self.t0.elapsed().as_micros() as u64;
        for d in 0..2 {
            let idle = now.saturating_sub(self.last[d].load(Ordering::Acquire));
            if self.turning[d].load(Ordering::Acquire) && idle > LET_GO.as_micros() as u64 {
                self.hold(d, false);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decks_by_name() {
        assert_eq!(deck_of("deck.b.jog.touch"), Some((1, "jog.touch")));
        assert_eq!(deck_of("deck.a.shift"), Some((0, "shift")));
        assert_eq!(deck_of("mixer.crossfader"), None);
        assert_eq!(deck_of("deck.c.play"), None);
    }
}
