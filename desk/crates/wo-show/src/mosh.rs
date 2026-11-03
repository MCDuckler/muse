//! The datamosh held (the effect Fx::Mosh), played by the music (v1: mosh_clock.dart). A
//! datamosh is a codec that lost its key frames: the picture as it was, dragged on and on by
//! whatever moves now, until a key frame comes and it is whole again. The record says when the
//! key frames come, how much of the picture is let through between them, how far it is dragged
//! and how blocky:
//!
//! - on each bar a few patches of the picture let through (so it never goes to mud), more on
//!   a phrase;
//! - an intro, an outro, a breakdown: a slow, smooth melt, little grain, a key frame every
//!   eight bars;
//! - a build: the smear growing as it climbs, the key frames closer (every two bars, then
//!   each bar, then each beat of the last), the grain rising;
//! - the drop: the picture whole on the drop, then four bars of the hardest, blockiest mosh;
//! - a snare: a burst of the codec's grain.
//!
//! The effect's knobs (grain, melt, keys) move all of it. Where a record has no grid, bars by
//! the clock. The stage plays it (wo_show::engine::Play), a frame in, the stage's numbers out.
use crate::rig::RigTransform;
use crate::state::ShowState;

/// What the stage is told this frame: on, how healed (0 all smear .. 1 the picture whole),
/// how far dragged (0..2), how blocky (0..1), the key frames asked for so far.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct MoshDrive {
    pub on: bool,
    pub heal: f32,
    pub strength: f32,
    pub grain: f32,
    pub keys: i64,
}

/// How long a pulse of let-through takes to fade, seconds.
const PULSE_FADE: f64 = 0.22;
/// The longest a mosh goes without a key frame, whatever the record says.
const LONGEST: f64 = 30.0;

fn calm(section: Option<&str>) -> bool {
    matches!(section, Some("intro" | "outro" | "breakdown" | "break"))
}

#[derive(Clone, Debug)]
pub struct MoshClock {
    keys: i64,
    on: bool,
    bar: Option<i64>,
    beat: Option<i64>,
    section: Option<String>,
    since_key: f64,
    since_drop: f64,
    pulse: f64,
    pulse_amp: f64,
    snare: f64,
    bar_clock: f64,
    bars_since_key: i64,
}

impl Default for MoshClock {
    fn default() -> Self {
        MoshClock {
            keys: 0,
            on: false,
            bar: None,
            beat: None,
            section: None,
            since_key: 0.0,
            since_drop: 1e9,
            pulse: 0.0,
            pulse_amp: 0.0,
            snare: 0.0,
            bar_clock: 0.0,
            bars_since_key: 0,
        }
    }
}

impl MoshClock {
    pub fn new() -> MoshClock {
        MoshClock::default()
    }

    /// One frame, `t` the effect on (its knobs; off where it is not the datamosh).
    pub fn frame(&mut self, st: &ShowState, t: &RigTransform) -> MoshDrive {
        if !t.mosh {
            self.on = false;
            return MoshDrive { keys: self.keys, ..Default::default() };
        }
        let m = st.master();
        let dt = st.dt.clamp(0.0, 0.25);
        let section_now = if m.breakdown { Some("breakdown".to_owned()) } else { m.section.clone() };
        if !self.on {
            // taken up from the picture as it is: no key frame wanted
            self.on = true;
            self.since_key = 0.0;
            self.bars_since_key = 0;
            self.bar = m.bar_index;
            self.beat = m.beat_index;
            self.section = section_now.clone();
        }
        let section = section_now.as_deref();
        let is_calm = calm(section);
        let build = section == Some("build") || (section.is_none() && m.build_k > 0.05);

        // the moments: a bar (by the grid, else by the clock), a phrase, a beat, the section
        // turning, the drop
        let (mut bar, mut phrase, mut beat) = (false, false, false);
        let bpm = m.bpm.unwrap_or(120.0);
        if let Some(bi) = m.bar_index {
            if Some(bi) != self.bar {
                bar = self.bar.is_some();
                self.bar = Some(bi);
                phrase = bar && m.phrase_bar == Some(0);
            }
        } else {
            self.bar_clock += dt;
            let bar_seconds = 240.0 / bpm;
            if self.bar_clock >= bar_seconds {
                self.bar_clock -= bar_seconds;
                bar = true;
                if self.bars_since_key % 8 == 7 {
                    phrase = true;
                }
            }
        }
        if let Some(b) = m.beat_index
            && Some(b) != self.beat
        {
            beat = self.beat.is_some();
            self.beat = Some(b);
        }
        let turned = section_now != self.section;
        let drop = turned && section == Some("drop");
        if turned {
            self.section = section_now.clone();
        }
        if drop {
            self.since_drop = 0.0;
        }
        self.since_drop += dt;
        self.since_key += dt;
        if bar {
            self.bars_since_key += 1;
        }

        // the knobs: melt holds the smears longer, keys lets the picture through more often,
        // grain is how blocky
        let (melt, keys_k, grain_k) = (t.melt.clamp(0.0, 1.0), t.keys.clamp(0.0, 1.0), t.grain.clamp(0.0, 1.0));
        let bar_seconds = 240.0 / bpm;
        let heavy = self.since_drop < 4.0 * bar_seconds;

        // where the record is: how healed between the pulses, how big a bar's pulse and a
        // phrase's, every how many bars a key frame, how far dragged, how blocky
        let (base, bar_amp, phrase_amp, mut key_bars, strength, mut grain): (f64, f64, f64, i64, f64, f64) = if heavy {
            (0.1, 0.3, 0.45, 8, 1.8, 0.9)
        } else if is_calm {
            (0.2, 0.12, 0.42, 8, 0.7, 0.25)
        } else if build {
            let k = m.build_k.clamp(0.0, 1.0);
            (0.2 - 0.1 * k, 0.4 - 0.12 * k, 0.4, if k < 0.5 { 2 } else { 1 }, 0.9 + 0.8 * k, 0.45 + 0.45 * k)
        } else {
            let s = m.section.as_deref();
            (0.2, 0.4, 0.45, 8, if matches!(s, Some("drop" | "chorus")) { 1.3 } else { 1.1 }, if s == Some("drop") { 0.75 } else { 0.6 })
        };
        key_bars = ((key_bars as f64 * (1.5 - keys_k)).round() as i64).max(1);

        // a key frame: the drop, a breakdown coming (the melt starts whole), every so many
        // bars, each beat of a build's last bar, or too long without one
        let last_bar = build && m.drop_beats_away.unwrap_or(99.0) <= 4.0;
        let key = drop || (turned && is_calm) || (bar && self.bars_since_key >= key_bars) || (beat && last_bar) || self.since_key > LONGEST;
        if key {
            self.keys += 1;
            self.since_key = 0.0;
            self.bars_since_key = 0;
            self.pulse = 0.0;
        } else if phrase {
            self.pulse = 1.0;
            self.pulse_amp = phrase_amp;
        } else if bar {
            self.pulse = 1.0;
            self.pulse_amp = bar_amp;
        }
        self.pulse *= (-dt / PULSE_FADE).exp();
        let amp = self.pulse_amp * (0.6 + 0.8 * keys_k);
        let heal = (base * (1.6 - 1.2 * melt) + amp * self.pulse).clamp(0.0, 0.9);

        // the snare: a burst of grain, fading
        self.snare = (self.snare * (-dt / 0.2).exp()).max(st.num("dyn.hit.snare").clamp(0.0, 1.0));
        grain = (grain * (grain_k / 0.7) + 0.25 * self.snare).clamp(0.0, 1.0);
        MoshDrive { on: true, heal: heal as f32, strength: strength.clamp(0.0, 2.0) as f32, grain: grain as f32, keys: self.keys }
    }
}

/// A datamosh from the picture on, as the stage starts one on a cut the director moshed: over
/// a bar and a half (two to four seconds), harder in the loud parts. (seconds, strength)
pub fn mosh_cut(st: &ShowState) -> (f32, f32) {
    let m = st.master();
    let bar = 240.0 / m.bpm.unwrap_or(120.0);
    ((bar * 1.5).clamp(2.0, 4.0) as f32, (0.8 + 0.6 * m.energy.clamp(0.0, 1.0)) as f32)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn on() -> RigTransform {
        RigTransform { mosh: true, ..Default::default() }
    }

    fn at(bar: i64, section: &str) -> ShowState {
        let mut st = ShowState { dt: 1.0 / 60.0, ..Default::default() };
        st.a.bpm = Some(120.0);
        st.a.bar_index = Some(bar);
        st.a.beat_index = Some(bar * 4);
        st.a.phrase_bar = Some(bar % 8);
        st.a.section = Some(section.into());
        st
    }

    #[test]
    fn off_unless_the_effect_is_the_mosh() {
        let mut c = MoshClock::new();
        let d = c.frame(&at(0, "drop"), &RigTransform::default());
        assert!(!d.on);
        assert_eq!(d.keys, 0);
    }

    #[test]
    fn taken_up_with_no_key_then_a_key_every_eight_bars() {
        let mut c = MoshClock::new();
        let d = c.frame(&at(0, "verse"), &on());
        assert!(d.on);
        assert_eq!(d.keys, 0, "taken up from the picture as it is");
        // keys 0.5: 8 × (1.5 − 0.5) = 8 bars
        for bar in 1..8 {
            assert_eq!(c.frame(&at(bar, "verse"), &on()).keys, 0, "bar {bar}");
        }
        assert_eq!(c.frame(&at(8, "verse"), &on()).keys, 1);
    }

    #[test]
    fn the_drop_is_a_key_and_then_the_hardest_mosh() {
        let mut c = MoshClock::new();
        c.frame(&at(0, "build"), &on());
        let d = c.frame(&at(1, "drop"), &on());
        assert_eq!(d.keys, 1, "whole on the drop");
        assert!((d.strength - 1.8).abs() < 1e-6);
        let g = d.grain;
        assert!((g - 0.9).abs() < 1e-6, "the grain at the knob's rest (0.7): {g}");
    }

    #[test]
    fn a_bar_lets_a_pulse_through_that_fades() {
        let mut c = MoshClock::new();
        c.frame(&at(0, "verse"), &on());
        let calm = c.frame(&at(0, "verse"), &on()).heal;
        let pulse = c.frame(&at(1, "verse"), &on()).heal;
        assert!(pulse > calm + 0.2, "{calm} → {pulse}");
        let mut later = pulse;
        for _ in 0..60 {
            later = c.frame(&at(1, "verse"), &on()).heal;
        }
        assert!((later - calm).abs() < 0.01);
    }

    #[test]
    fn a_cut_is_a_bar_and_a_half() {
        let mut st = at(0, "drop");
        st.a.energy = 1.0;
        assert_eq!(mosh_cut(&st), (3.0, 1.4));
        st.a.bpm = Some(200.0);
        assert_eq!(mosh_cut(&st).0, 2.0, "never under two seconds");
        st.a.bpm = Some(60.0);
        assert_eq!(mosh_cut(&st).0, 4.0, "nor over four");
    }
}
