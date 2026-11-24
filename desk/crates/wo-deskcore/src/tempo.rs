//! TEMPO RETURN: a deck's tempo taken back to the record's own (the pitch fader to 0)
//! slowly, over seconds a hand sets, eased at both ends so the room does not hear it
//! turn. A hand on the pitch fader meanwhile has it, and the return stops there.
//! A synced follower's tempo is its master's: it has none of its own to go back to.
use std::time::Instant;

use wo_engine::DeckId;

use crate::Desk;

/// How long a return takes, seconds, until a hand sets it, and its reach.
pub const SECS: f64 = 8.0;
pub const RANGE: (f64, f64) = (1.0, 120.0);

/// A return under way.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Back {
    began: Instant,
    /// The fader where it began, -1..1.
    from: f64,
    secs: f64,
}

/// Where the fader is `k` (0..1) of the way through: eased in and out.
fn eased(from: f64, k: f64) -> f64 {
    let k = k.clamp(0.0, 1.0);
    from * (1.0 - k * k * (3.0 - 2.0 * k))
}

impl Desk {
    /// Deck `d`'s tempo back to the record's own, slowly; pressed again while it goes,
    /// it stops where it is. False where there is nothing to do (at its own tempo
    /// already, or synced to the other).
    pub fn tempo_return(&mut self, d: usize) -> bool {
        if self.tempo_back[d].take().is_some() {
            self.changes += 1;
            return true;
        }
        let from = self.slots[d].hands.pitch;
        if from.abs() < 1e-6 || !self.can_return(d) {
            return false;
        }
        self.tempo_back[d] = Some(Back { began: Instant::now(), from, secs: self.tempo_back_secs });
        self.changes += 1;
        true
    }

    /// Deck `d` has a tempo of its own to go back to (not a synced follower).
    pub fn can_return(&self, d: usize) -> bool {
        !self.engine.deck(DeckId::new(d).unwrap()).read().synced
    }

    /// How far through a return deck `d` is (0..1), where one goes.
    pub fn tempo_returning(&self, d: usize) -> Option<f64> {
        self.tempo_back[d].map(|b| (b.began.elapsed().as_secs_f64() / b.secs).min(1.0))
    }

    pub fn tempo_return_secs(&self) -> f64 {
        self.tempo_back_secs
    }

    pub fn set_tempo_return_secs(&mut self, s: f64) {
        self.tempo_back_secs = s.clamp(RANGE.0, RANGE.1);
        self.changes += 1;
    }

    /// The returns under way, a step on.
    pub(crate) fn tempo_tick(&mut self) {
        for d in 0..2 {
            let Some(b) = self.tempo_back[d] else { continue };
            // synced since: its tempo is the master's now
            if !self.can_return(d) {
                self.tempo_back[d] = None;
                continue;
            }
            let k = b.began.elapsed().as_secs_f64() / b.secs.max(0.01);
            let v = eased(b.from, k);
            self.hands(d, |h, t| h.set_pitch(v, t));
            if k >= 1.0 {
                self.tempo_back[d] = None;
                self.changes += 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::eased;

    #[test]
    fn eased_from_where_it_was_to_none_gently() {
        assert_eq!(eased(0.4, 0.0), 0.4);
        assert_eq!(eased(0.4, 1.0), 0.0);
        assert!((eased(0.4, 0.5) - 0.2).abs() < 1e-9, "half way at half time");
        // gentle at the ends: the first and last tenth move less than a straight line would
        assert!(0.4 - eased(0.4, 0.1) < 0.04 && eased(0.4, 0.9) < 0.04);
        assert_eq!(eased(-0.2, 2.0), 0.0, "past its time, at its own tempo");
    }
}
