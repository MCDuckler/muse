//! Where the sound goes, and the headphones (pre-fader listening). The master goes to one
//! output; the headphones, where there are some, to a DJ console's own channels 3/4, a
//! second sound card, or one stereo jack split (the headphones left, the master right).
//! Automatic (the default): a console's sound card when one is plugged in — the master on
//! its 1/2, the headphones on its 3/4 — else the system's own, no headphones. The outputs
//! are listed on a thread of their own every few seconds; a change routes again.
//!
//! A deck in the headphones is heard there before its fader (and the crossfader), after
//! its trim, EQ, filter and effects. Their blend (the cued decks .. the master) and level
//! are the Desk's — unless the console blends them itself (a DDJ-400's HEADPHONES MIXING
//! and LEVEL act on its own sound card), when the Desk sends the cued decks alone.
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

pub use wo_engine::{Cue, CueAt, OutputDevice, Route, RouteState};

use crate::Desk;

/// Kept between runs (the config folder's audio.json).
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct AudioPrefs {
    /// A console's own sound card when one is plugged in, else the system's own.
    pub auto: bool,
    /// Chosen by hand (used when not automatic).
    pub route: Route,
    /// The headphones' blend, 0 the cued decks alone .. 1 the master alone.
    pub head_mix: f32,
    /// Their level knob, 0..1 (0.75 unity).
    pub head_level: f32,
}

impl Default for AudioPrefs {
    fn default() -> Self {
        AudioPrefs { auto: true, route: Route::default(), head_mix: 0.0, head_level: 0.75 }
    }
}

impl AudioPrefs {
    fn file() -> Option<PathBuf> {
        wo_house::folders::config().map(|d| d.join("wetowl-desk").join("audio.json"))
    }

    pub fn read() -> AudioPrefs {
        Self::file().and_then(|f| std::fs::read_to_string(f).ok()).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
    }

    pub fn save(&self) {
        let Some(f) = Self::file() else { return };
        let _ = std::fs::create_dir_all(f.parent().unwrap());
        if let Err(e) = std::fs::write(&f, serde_json::to_string_pretty(self).unwrap()) {
            eprintln!("desk: the sound settings into {}: {e}", f.display());
        }
    }
}

/// The level knob as a gain: 0.75 unity, 1 about +5 dB, 0 silent.
pub fn level_gain(k: f32) -> f32 {
    (k.clamp(0.0, 1.0) / 0.75).powi(2)
}

/// A console plugged in, as the automatic routing looks for its sound card.
#[derive(Clone, Debug, Default)]
pub struct Console {
    /// Its name and the names its layout matches by.
    pub names: Vec<String>,
    pub audio: Option<wo_control::layout::Audio>,
}

/// What the automatic routing chose, and why.
#[derive(Clone, Debug, PartialEq)]
pub struct Plan {
    pub route: Route,
    pub why: String,
    /// The console blends the headphones itself.
    pub mixes: bool,
}

/// Words in sound cards' names that say "a DJ console" by themselves.
const HINTS: [&str; 12] = ["ddj", "rmx", "djcontrol", "djconsole", "traktorkontrol", "mixtrack", "xdj", "djm", "mc7000", "mc4000", "primego", "partymix"];
/// Words that say nothing of which device it is.
const GENERIC: [&str; 16] = ["midi", "usb", "audio", "port", "device", "controller", "console", "pioneer", "hercules", "native", "instruments", "analog", "digital", "stereo", "output", "speakers"];

fn squash(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_alphanumeric()).map(|c| c.to_ascii_lowercase()).collect()
}

/// Whether output `out` looks like the sound card of a console called by `names`.
fn is_its(out: &str, names: &[String]) -> bool {
    let o = squash(out);
    names.iter().any(|n| {
        let whole = squash(n);
        if whole.len() >= 4 && o.contains(&whole) {
            return true;
        }
        n.split(|c: char| !c.is_ascii_alphanumeric())
            .map(|w| w.to_ascii_lowercase())
            .filter(|w| w.len() >= 3 && w.chars().any(|c| c.is_ascii_alphabetic()) && !GENERIC.contains(&w.as_str()) && w != "dj")
            .any(|w| o.contains(&w))
    })
}

/// The automatic routing: a plugged-in console's sound card (by its name, else a DJ word
/// in an output's name) taking four channels gets the master on 1/2 and the headphones
/// on its own pair; one showing two leaves the system's own (and says how to fix it).
pub fn automatic(outs: &[OutputDevice], consoles: &[Console]) -> Plan {
    let by_name = consoles.iter().find_map(|c| outs.iter().find(|o| is_its(&o.name, &c.names)).map(|o| (o, c.audio.clone())));
    let found = by_name.or_else(|| {
        outs.iter().find(|o| {
            let s = squash(&o.name);
            HINTS.iter().any(|h| s.contains(h))
        })
        .map(|o| (o, None))
    });
    let Some((o, audio)) = found else {
        return Plan { route: Route::default(), why: "The system's own output: no DJ console's sound card found".into(), mixes: false };
    };
    let phones = audio.as_ref().map_or(2, |a| a.headphones);
    let need = phones + 2;
    if o.channels != 0 && o.channels < need {
        return Plan {
            route: Route::default(),
            why: format!("{} shows {} channels, not {need}: in the system's sound settings give it a 4-channel profile (Surround 4.0, or Pro Audio) for its headphones", o.name, o.channels),
            mixes: false,
        };
    }
    Plan {
        route: Route { master: Some(o.name.clone()), master_ch: 0, cue: Cue::Device { name: Some(o.name.clone()), ch: phones } },
        why: format!("{}: the master on its {}/{}, the headphones on its {}/{}", o.name, 1, 2, phones + 1, phones + 2),
        mixes: audio.is_some_and(|a| a.mixes),
    }
}

/// The Desk's sound: what is chosen, what is routed, the headphones.
pub(crate) struct Audio {
    pub prefs: AudioPrefs,
    /// Each deck in the headphones.
    pub cue: [bool; 2],
    outputs: Vec<OutputDevice>,
    listed: Option<mpsc::Receiver<Vec<OutputDevice>>>,
    /// What the engine was last routed to, and whether that worked.
    applied: Option<Route>,
    failed: bool,
    said: Option<String>,
    plan: Option<Plan>,
    consoles_seen: usize,
    dirty: Option<Instant>,
    /// No sound card (offline): nothing is routed.
    offline: bool,
}

/// The sound as the settings show it.
#[derive(Clone, Debug)]
pub struct AudioView {
    pub prefs: AudioPrefs,
    pub outputs: Vec<OutputDevice>,
    /// What is routed now, and how the outputs are.
    pub route: Option<Route>,
    pub state: RouteState,
    /// The last routing's trouble, in words.
    pub said: Option<String>,
    /// The automatic routing's choice, in words.
    pub why: Option<String>,
    /// There are headphones.
    pub headphones: bool,
    /// The console blends them itself (the Desk's blend and level are not used).
    pub console_mixes: bool,
    pub cue: [bool; 2],
}

impl Audio {
    pub fn new(offline: bool) -> Audio {
        let listed = (!offline).then(|| {
            let (tx, rx) = mpsc::channel();
            thread::Builder::new()
                .name("desk-outputs".into())
                .spawn(move || {
                    let mut last: Option<Vec<OutputDevice>> = None;
                    loop {
                        let now = wo_engine::outputs();
                        if last.as_ref() != Some(&now) {
                            if tx.send(now.clone()).is_err() {
                                return;
                            }
                            last = Some(now);
                        }
                        thread::sleep(Duration::from_secs(3));
                    }
                })
                .ok();
            rx
        });
        Audio {
            prefs: AudioPrefs::read(),
            cue: [false; 2],
            outputs: vec![],
            listed,
            // the engine starts on the system's own, stereo: routed there already
            applied: Some(Route::default()),
            failed: false,
            said: None,
            plan: None,
            consoles_seen: usize::MAX,
            dirty: None,
            offline,
        }
    }
}

impl Desk {
    /// The consoles plugged in, with their layouts' sound cards.
    fn consoles(&self) -> Vec<Console> {
        let layouts = self.controller_layouts();
        self.controllers()
            .into_iter()
            .map(|c| {
                let l = layouts.iter().find(|l| l.name == c.layout);
                let mut names = vec![c.name.clone(), c.layout.clone()];
                if let Some(l) = l {
                    names.extend(l.names.iter().cloned());
                }
                Console { names, audio: l.and_then(|l| l.audio.clone()) }
            })
            .collect()
    }

    /// Routes again where the outputs, the consoles or the choice changed. Each frame.
    pub(crate) fn audio_tick(&mut self) {
        if self.audio.offline {
            return;
        }
        let mut changed = false;
        if let Some(rx) = &self.audio.listed {
            while let Ok(o) = rx.try_recv() {
                self.audio.outputs = o;
                changed = true;
            }
        }
        let n = self.controllers().len();
        if n != self.audio.consoles_seen {
            self.audio.consoles_seen = n;
            changed = true;
        }
        let st = self.engine.route_state();
        if st.lost || st.cue_lost {
            // unplugged: start over (the system's own, if it is gone)
            self.audio.applied = None;
            changed = true;
        }
        if changed || self.audio.applied.is_none() {
            self.route_audio(changed);
        }
        if self.audio.dirty.is_some_and(|t| t.elapsed() > Duration::from_secs(1)) {
            self.audio.dirty = None;
            self.audio.prefs.save();
        }
        self.binding.headphones = self.headphones();
    }

    /// Routes as chosen, if that is not what is routed (or it failed and `retry`).
    fn route_audio(&mut self, retry: bool) {
        let plan = automatic(&self.audio.outputs, &self.consoles());
        let want = if self.audio.prefs.auto { plan.route.clone() } else { self.audio.prefs.route.clone() };
        self.audio.plan = Some(plan);
        if self.audio.applied.as_ref() == Some(&want) && !(self.audio.failed && retry) {
            self.apply_head();
            return;
        }
        match self.engine.route(&want) {
            Ok(()) => {
                self.audio.said = None;
                self.audio.failed = false;
            }
            Err(e) => {
                eprintln!("desk: sound to {want:?}: {e}");
                self.audio.said = Some(e.to_string());
                self.audio.failed = true;
            }
        }
        self.audio.applied = Some(want);
        self.apply_head();
        self.apply_levels();
        self.changes += 1;
    }

    /// The headphones' blend and level into the engine (the console's own: the cued decks
    /// alone, whole).
    fn apply_head(&self) {
        if self.console_mixes() {
            self.engine.set_cue_mix(0.0, 1.0);
        } else {
            self.engine.set_cue_mix(self.audio.prefs.head_mix, level_gain(self.audio.prefs.head_level));
        }
    }

    /// Whether the routed console blends the headphones itself.
    fn console_mixes(&self) -> bool {
        self.audio.prefs.auto && self.audio.plan.as_ref().is_some_and(|p| p.mixes) && self.engine.route_state().cue == CueAt::SameDevice
    }

    /// There are headphones to cue into.
    pub fn headphones(&self) -> bool {
        !self.audio.offline && self.engine.route_state().cue != CueAt::Nowhere
    }

    /// Deck `d` in the headphones, or out of them.
    pub fn toggle_headphones(&mut self, d: usize) {
        self.audio.cue[d] = !self.audio.cue[d];
        self.apply_levels();
        self.changes += 1;
    }

    pub fn set_head_mix(&mut self, v: f32) {
        self.audio.prefs.head_mix = v.clamp(0.0, 1.0);
        self.apply_head();
        self.audio.dirty.get_or_insert_with(Instant::now);
    }

    pub fn set_head_level(&mut self, v: f32) {
        self.audio.prefs.head_level = v.clamp(0.0, 1.0);
        self.apply_head();
        self.audio.dirty.get_or_insert_with(Instant::now);
    }

    /// Automatic, or a route chosen by hand: kept, and routed at once.
    pub fn set_audio_choice(&mut self, auto: bool, route: Route) {
        self.audio.prefs.auto = auto;
        self.audio.prefs.route = route;
        self.audio.prefs.save();
        self.route_audio(true);
    }

    /// Lists the outputs again now (the settings opened).
    pub fn refresh_outputs(&mut self) {
        if !self.audio.offline {
            self.audio.outputs = wo_engine::outputs();
            self.route_audio(false);
        }
    }

    pub fn audio_view(&self) -> AudioView {
        AudioView {
            prefs: self.audio.prefs.clone(),
            outputs: self.audio.outputs.clone(),
            route: self.audio.applied.clone(),
            state: self.engine.route_state(),
            said: self.audio.said.clone(),
            why: self.audio.plan.as_ref().map(|p| p.why.clone()),
            headphones: self.headphones(),
            console_mixes: self.console_mixes(),
            cue: self.audio.cue,
        }
    }

    /// Deck `d`'s gain in the headphones: its trim when cued, else none.
    pub(crate) fn cue_gain(&self, d: usize, trim: f32) -> f32 {
        if self.audio.cue[d] { trim } else { 0.0 }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn out(name: &str, channels: u32) -> OutputDevice {
        OutputDevice { name: name.into(), channels, is_default: false }
    }

    fn console(names: &[&str], mixes: bool) -> Console {
        Console { names: names.iter().map(|s| s.to_string()).collect(), audio: Some(wo_control::layout::Audio { headphones: 2, mixes }) }
    }

    #[test]
    fn a_console_with_four_channels_takes_master_and_headphones() {
        let outs = [out("Built-in Audio Analog Stereo", 2), out("DDJ-400 Analog Surround 4.0", 4)];
        let p = automatic(&outs, &[console(&["DDJ-400", "Pioneer DDJ-400"], true)]);
        let name = Some("DDJ-400 Analog Surround 4.0".to_owned());
        assert_eq!(p.route, Route { master: name.clone(), master_ch: 0, cue: Cue::Device { name, ch: 2 } });
        assert!(p.mixes);
    }

    #[test]
    fn two_channels_stay_on_the_system_and_say_why() {
        let outs = [out("Built-in Audio Analog Stereo", 2), out("DDJ-400 Analog Stereo", 2)];
        let p = automatic(&outs, &[console(&["DDJ-400"], true)]);
        assert_eq!(p.route, Route::default());
        assert!(p.why.contains("4-channel"), "{}", p.why);
    }

    #[test]
    fn a_dj_word_finds_one_no_layout_knows() {
        let outs = [out("Speakers (Realtek)", 2), out("Speakers (DJControl Inpulse 500)", 4)];
        let p = automatic(&outs, &[]);
        assert_eq!(p.route.master.as_deref(), Some("Speakers (DJControl Inpulse 500)"));
        assert!(!p.mixes);
    }

    #[test]
    fn nothing_like_a_console_is_the_system() {
        let outs = [out("Built-in Audio Analog Stereo", 2), out("AD107 High Definition Audio Controller Digital Stereo (HDMI)", 2)];
        assert_eq!(automatic(&outs, &[console(&["DJ Console RMX", "Hercules DJ Console RMX"], false)]).route, Route::default());
    }

    #[test]
    fn the_rmx_by_its_word() {
        let outs = [out("Built-in Audio Analog Stereo", 2), out("DJ Console Rmx Analog Surround 4.0", 4)];
        let p = automatic(&outs, &[console(&["Hercules DJ Console RMX"], false)]);
        assert_eq!(p.route.master.as_deref(), Some("DJ Console Rmx Analog Surround 4.0"));
    }

    #[test]
    fn the_level_knob() {
        assert_eq!(level_gain(0.0), 0.0);
        assert!((level_gain(0.75) - 1.0).abs() < 1e-6);
        assert!(level_gain(1.0) > 1.7);
    }
}
