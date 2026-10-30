//! What a deck does when a hand moves it, the v1 booth's rules (app/lib/src/state/booth/
//! deck.dart) over a [`Transport`], so they are tested without a sound card.
use crate::grid::Grid;

/// The deck's sound, as the hands need it. The engine deck is one; tests use a fake.
pub trait Transport {
    /// Where the record is heard now, source seconds.
    fn position(&self) -> f64;
    fn playing(&self) -> bool;
    fn play(&mut self, on: bool);
    fn seek(&mut self, t: f64);
    /// Loops source time a..b; `None` lets go.
    fn set_loop(&mut self, ab: Option<(f64, f64)>);
    fn set_rate(&mut self, rate: f64);
    fn bend(&mut self, factor: f64);
    fn brake(&mut self, seconds: f64);
}

/// Why the booth put a pad where it is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PadKind {
    Intro,
    Drop,
    Break,
    Out,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pad {
    pub at: f64,
    /// Placed by the booth (and why), or `None`: set by a hand.
    pub auto: Option<PadKind>,
}

/// The pitch fader's ranges, cycled by its label: ±8 %, ±16 %, ±50 %.
pub const RANGES: [f64; 3] = [0.08, 0.16, 0.5];

/// How far a nudge bends the record while it is held.
pub const NUDGE: f64 = 0.04;

/// A CUE press this close to the cue point counts as on it (previews).
const ON_THE_CUE: f64 = 0.06;

#[derive(Clone, Debug)]
pub struct Hands {
    pub grid: Grid,
    /// Where CUE takes the record back to.
    pub cue: Option<f64>,
    /// CUE held with the record playing from the cue point: let go and it goes back.
    pub previewing: bool,
    pub pads: [Option<Pad>; 8],
    by_hand: [bool; 8],
    /// The loop running, source seconds.
    pub looped: Option<(f64, f64)>,
    /// Loop IN pressed, OUT not yet.
    pub loop_in: Option<f64>,
    /// The loop buttons' length when the loop came from one, beats.
    pub loop_beats: Option<f64>,
    /// The pitch fader, -1..1, and its range.
    pub pitch: f64,
    pub range: usize,
    /// The nudge held: -1, 0, 1.
    pub nudging: i8,
}

impl Hands {
    pub fn new(grid: Grid) -> Self {
        Hands {
            grid,
            cue: None,
            previewing: false,
            pads: [None; 8],
            by_hand: [false; 8],
            looped: None,
            loop_in: None,
            loop_beats: None,
            pitch: 0.0,
            range: 0,
            nudging: 0,
        }
    }

    // ---------------------------------------------------------------- the CUE button

    /// CUE pressed, the way a CDJ does it. Playing: stop, back to the cue point (or mark
    /// one here). Parked on the cue point: play from it while the button is held.
    /// Parked anywhere else: the cue point is here now.
    pub fn cue_down(&mut self, t: &mut impl Transport) {
        let here = t.position();
        if t.playing() {
            t.play(false);
            match self.cue {
                Some(at) => t.seek(at),
                None => self.cue = Some(here),
            }
            return;
        }
        if let Some(at) = self.cue
            && (here - at).abs() < ON_THE_CUE {
                self.previewing = true;
                t.play(true);
                return;
            }
        self.cue = Some(here);
    }

    /// CUE let go: a preview ends back at the cue point.
    pub fn cue_up(&mut self, t: &mut impl Transport) {
        if !std::mem::take(&mut self.previewing) {
            return;
        }
        t.play(false);
        if let Some(at) = self.cue {
            t.seek(at);
        }
    }

    // ---------------------------------------------------------------- pads

    /// A pad pressed: an empty one is set here; a set one takes the record there.
    pub fn pad(&mut self, n: usize, t: &mut impl Transport) {
        match self.pads[n] {
            Some(p) => t.seek(p.at),
            None => {
                self.pads[n] = Some(Pad { at: t.position(), auto: None });
                self.by_hand[n] = true;
            }
        }
    }

    /// A pad cleared by hand: it stays empty (the booth does not place it again).
    pub fn clear_pad(&mut self, n: usize) {
        self.pads[n] = None;
        self.by_hand[n] = true;
    }

    /// The booth's own pads, placed wherever a hand has not set or cleared one.
    pub fn place_auto(&mut self, placed: &[(usize, f64, PadKind)]) {
        for &(n, at, kind) in placed {
            if n < 8 && !self.by_hand[n] {
                self.pads[n] = Some(Pad { at, auto: Some(kind) });
            }
        }
    }

    // ---------------------------------------------------------------- loops

    /// A loop of `beats` from this bar's one where the deck has just passed it (within a
    /// beat), else from the next bar's one — so a loop caught on a step starts on that
    /// bar, not a bar late. The same length again lets go.
    pub fn loop_beats(&mut self, beats: f64, t: &mut impl Transport) {
        if self.looped.is_some() && self.loop_beats == Some(beats) {
            return self.unloop(t);
        }
        let Some(spb) = self.grid.spb() else { return };
        let here = t.position();
        let next = self.grid.next_beat(here, 4).unwrap_or(here);
        let prev = next - 4.0 * spb;
        let from = if next - here > 3.0 * spb && prev >= 0.0 { prev } else { next };
        self.set(Some((from, from + beats * spb)), Some(beats), t);
    }

    /// Loop IN: the loop will start here. Nothing loops until OUT; a running loop is let go.
    pub fn loop_in(&mut self, t: &mut impl Transport) {
        self.loop_in = Some(t.position());
        if self.looped.is_some() {
            self.set(None, None, t);
        }
    }

    /// Loop OUT: the loop ends here and goes round from IN. Without an IN before here, nothing.
    pub fn loop_out(&mut self, t: &mut impl Transport) {
        let Some(from) = self.loop_in else { return };
        let to = t.position();
        if to > from + 0.02 {
            self.loop_in = None;
            self.set(Some((from, to)), None, t);
        }
    }

    /// Half the loop, from its start: down to an eighth of a beat, below which it is a tone.
    pub fn halve(&mut self, t: &mut impl Transport) {
        let (Some((a, b)), Some(spb)) = (self.looped, self.grid.spb()) else { return };
        if b - a > spb / 8.0 + 1e-9 {
            self.set(Some((a, a + (b - a) / 2.0)), self.loop_beats.map(|n| n / 2.0), t);
        }
    }

    /// Twice the loop, from its start: up to 32 bars.
    pub fn double(&mut self, t: &mut impl Transport) {
        let (Some((a, b)), Some(spb)) = (self.looped, self.grid.spb()) else { return };
        if (b - a) * 2.0 <= 128.0 * spb + 1e-9 {
            self.set(Some((a, a + (b - a) * 2.0)), self.loop_beats.map(|n| n * 2.0), t);
        }
    }

    pub fn unloop(&mut self, t: &mut impl Transport) {
        self.loop_in = None;
        self.set(None, None, t);
    }

    fn set(&mut self, ab: Option<(f64, f64)>, beats: Option<f64>, t: &mut impl Transport) {
        self.looped = ab;
        self.loop_beats = beats;
        t.set_loop(ab);
    }

    // ---------------------------------------------------------------- moving it

    /// `beats` beats on (or back), the loop with it when looping, so the phrase holds.
    pub fn jump(&mut self, beats: f64, t: &mut impl Transport) {
        let Some(spb) = self.grid.spb() else { return };
        let by = beats * spb;
        if let Some((a, b)) = self.looped {
            self.set(Some((a + by, b + by)), self.loop_beats, t);
        }
        t.seek((t.position() + by).max(0.0));
    }

    /// The pitch fader, -1..1 across the range: the rate it gives.
    pub fn set_pitch(&mut self, v: f64, t: &mut impl Transport) -> f64 {
        self.pitch = v.clamp(-1.0, 1.0);
        let rate = self.rate();
        t.set_rate(rate);
        rate
    }

    /// The next range, the rate kept where it can be.
    pub fn cycle_range(&mut self, t: &mut impl Transport) {
        let rate = self.rate();
        self.range = (self.range + 1) % RANGES.len();
        self.set_pitch((rate - 1.0) / RANGES[self.range], t);
    }

    pub fn rate(&self) -> f64 {
        1.0 + self.pitch * RANGES[self.range]
    }

    /// A nudge held (-1 back, 1 on) or let go (0).
    pub fn nudge(&mut self, dir: i8, t: &mut impl Transport) {
        self.nudging = dir.signum();
        t.bend(1.0 + self.nudging as f64 * NUDGE);
    }

    /// The record braked to a stop over two of its beats (0.6–1.4 s).
    pub fn brake(&self, t: &mut impl Transport) {
        if t.playing() {
            t.brake(self.grid.spb().map(|s| s * 2.0).unwrap_or(0.9).clamp(0.6, 1.4));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Fake {
        at: f64,
        playing: bool,
        looped: Option<(f64, f64)>,
        rate: f64,
        bend: f64,
        braked: Option<f64>,
    }

    impl Transport for Fake {
        fn position(&self) -> f64 {
            self.at
        }
        fn playing(&self) -> bool {
            self.playing
        }
        fn play(&mut self, on: bool) {
            self.playing = on;
        }
        fn seek(&mut self, t: f64) {
            self.at = t;
        }
        fn set_loop(&mut self, ab: Option<(f64, f64)>) {
            self.looped = ab;
        }
        fn set_rate(&mut self, rate: f64) {
            self.rate = rate;
        }
        fn bend(&mut self, factor: f64) {
            self.bend = factor;
        }
        fn brake(&mut self, seconds: f64) {
            self.braked = Some(seconds);
        }
    }

    /// 120 bpm from 0.25 s; the bar's one on beat 1 (0.75 s, 2.75 s, 4.75 s…).
    fn hands() -> Hands {
        Hands::new(Grid::new((0..256).map(|i| 0.25 + i as f64 * 0.5).collect(), 1))
    }

    #[test]
    fn cue_marks_previews_and_returns() {
        let (mut h, mut t) = (hands(), Fake::default());
        t.at = 10.0;
        h.cue_down(&mut t);
        assert_eq!(h.cue, Some(10.0), "parked: CUE marks the cue point here");
        h.cue_up(&mut t);
        h.cue_down(&mut t);
        assert!(t.playing && h.previewing, "parked on the cue: CUE plays while held");
        t.at = 11.3;
        h.cue_up(&mut t);
        assert!(!t.playing && t.at == 10.0, "let go: back on the cue point");
        t.playing = true;
        t.at = 20.0;
        h.cue_down(&mut t);
        assert!(!t.playing && t.at == 10.0, "playing: CUE stops and goes back");
    }

    #[test]
    fn pads_set_jump_clear_and_stay_cleared() {
        let (mut h, mut t) = (hands(), Fake::default());
        h.place_auto(&[(0, 0.75, PadKind::Intro), (1, 32.75, PadKind::Drop)]);
        t.at = 50.0;
        h.pad(1, &mut t);
        assert_eq!(t.at, 32.75, "a set pad jumps");
        t.at = 50.0;
        h.pad(4, &mut t);
        assert_eq!(h.pads[4], Some(Pad { at: 50.0, auto: None }), "an empty pad is set here");
        h.clear_pad(0);
        h.place_auto(&[(0, 0.75, PadKind::Intro)]);
        assert_eq!(h.pads[0], None, "a pad cleared by hand is not placed again");
    }

    #[test]
    fn a_loop_starts_on_the_bar() {
        let (mut h, mut t) = (hands(), Fake::default());
        t.at = 3.0; // a quarter beat past the bar's one at 2.75
        h.loop_beats(4.0, &mut t);
        assert_eq!(t.looped, Some((2.75, 4.75)), "just past a bar's one: from it");
        h.loop_beats(4.0, &mut t);
        assert_eq!(t.looped, None, "the same length again lets go");
        t.at = 4.0; // well into the bar
        h.loop_beats(8.0, &mut t);
        assert_eq!(t.looped, Some((4.75, 8.75)), "mid-bar: from the next one");
        h.halve(&mut t);
        assert_eq!(t.looped, Some((4.75, 6.75)));
        h.double(&mut t);
        h.double(&mut t);
        assert_eq!(t.looped, Some((4.75, 12.75)));
        assert_eq!(h.loop_beats, Some(16.0));
    }

    #[test]
    fn loop_in_and_out() {
        let (mut h, mut t) = (hands(), Fake::default());
        t.at = 5.0;
        h.loop_in(&mut t);
        h.loop_out(&mut t);
        assert_eq!(t.looped, None, "OUT at IN marks nothing");
        t.at = 7.0;
        h.loop_out(&mut t);
        assert_eq!(t.looped, Some((5.0, 7.0)));
        h.loop_in(&mut t);
        assert_eq!(t.looped, None, "a new IN lets the running loop go");
    }

    #[test]
    fn jump_carries_the_loop() {
        let (mut h, mut t) = (hands(), Fake::default());
        t.at = 3.0;
        h.loop_beats(4.0, &mut t);
        h.jump(4.0, &mut t);
        assert_eq!(t.at, 5.0);
        assert_eq!(t.looped, Some((4.75, 6.75)));
    }

    #[test]
    fn pitch_ranges_nudge_and_brake() {
        let (mut h, mut t) = (hands(), Fake::default());
        assert!((h.set_pitch(0.5, &mut t) - 1.04).abs() < 1e-12);
        h.cycle_range(&mut t);
        assert!((t.rate - 1.04).abs() < 1e-12 && (h.pitch - 0.25).abs() < 1e-12, "a wider range keeps the rate");
        h.nudge(1, &mut t);
        assert!((t.bend - 1.04).abs() < 1e-12);
        h.nudge(0, &mut t);
        assert_eq!(t.bend, 1.0);
        t.playing = true;
        h.brake(&mut t);
        assert_eq!(t.braked, Some(1.0), "two beats at 120 bpm");
    }
}
