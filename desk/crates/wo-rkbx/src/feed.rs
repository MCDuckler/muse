//! The decks as rkbx_link tells them: what is loaded where, which decks play, where each
//! is (carried on between messages), its beat and phrase, and which deck leads.
//!
//! Times are the caller's clock in seconds (`t`), so a recorded feed replays exactly.
//!
//! What rkbx_link 1.2 (rekordbox 7.2.2) does, measured 2026-11-18, and what this does about it:
//! - decks are `/0`…`/3` (its README says 1–4) plus `/master`; both spellings of an address
//!   (`/0/time` and `/time/0`) are read.
//! - values are sent only when they change: a paused deck goes silent, so "playing" means
//!   "its position moved lately" and everything else is the last value heard.
//! - `/master` carries no deck number: it is found by matching `/master/time` to a deck's
//!   time (same f32), or its title to one deck's.
//! - on every load `/master` names the new record for ~0.1 s and flips back: a master
//!   must hold [`MASTER_HOLD`] before it counts.
//! - its master moves only when the deck that finished is loaded again (in Automix: at
//!   the end of the record, not at the crossfade), so [`View::lead`] prefers a deck that
//!   plays over a master that has stopped.

/// How many decks rkbx_link can report.
pub const DECKS: usize = 4;
/// A deck whose position has not moved for this long is taken as stopped.
pub const PLAYING_GRACE: f64 = 0.25;
/// How long a new master must hold before it counts (the load flicker is ~0.1 s).
pub const MASTER_HOLD: f64 = 0.4;
/// A position this far from where the deck should be is a jump (a seek, a loop, a cue).
pub const JUMP: f64 = 0.5;
/// No message for this long: rkbx_link (or rekordbox) is gone.
pub const SILENT: f64 = 2.0;

/// rkbx_link's phrase numbers (`osc.phrase_output_format int`): rekordbox's phrase kinds
/// folded to five. Use the library's PSSI for the real kind; this is for timing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhraseKind {
    Intro,
    /// Verse 1–6 (mood low/mid), Up (high).
    Verse,
    Chorus,
    /// Bridge (low/mid), Down (high).
    Bridge,
    Outro,
    Other(i32),
}

impl PhraseKind {
    pub fn from_rkbx(n: i32) -> Option<PhraseKind> {
        Some(match n {
            0 => return None,
            1 => PhraseKind::Intro,
            2 => PhraseKind::Verse,
            3 => PhraseKind::Chorus,
            4 => PhraseKind::Bridge,
            5 => PhraseKind::Outro,
            n => PhraseKind::Other(n),
        })
    }
}

/// A value and when it was heard.
#[derive(Clone, Copy, Debug, PartialEq)]
struct At {
    v: f64,
    t: f64,
}

#[derive(Clone, Debug, Default)]
struct Deck {
    title: String,
    artist: String,
    album: String,
    /// Last position heard, raw (bit-exact, for matching `/master/time`).
    time_raw: Option<At>,
    /// Last time the position moved forward.
    moved: Option<f64>,
    beat: Option<At>,
    bar: Option<At>,
    bpm: Option<f64>,
    bpm_original: Option<f64>,
    phrase: Option<i32>,
    phrase_next: Option<i32>,
    countin: Option<At>,
    loads: u32,
    jumps: u32,
}

impl Deck {
    fn rate(&self) -> f64 {
        match (self.bpm, self.bpm_original) {
            (Some(c), Some(o)) if c > 0.0 && o > 0.0 => c / o,
            _ => 1.0,
        }
    }

    fn playing(&self, t: f64) -> bool {
        self.moved.is_some_and(|m| t - m <= PLAYING_GRACE)
    }

    fn position(&self, t: f64) -> Option<f64> {
        let p = self.time_raw?;
        Some(if self.playing(t) { p.v + (t - p.t).max(0.0) * self.rate() } else { p.v })
    }

    fn phase(&self, x: Option<At>, beats: f64, t: f64) -> Option<f64> {
        let x = x?;
        let bpm = self.bpm.filter(|b| *b > 0.0)?;
        let moved = if self.playing(t) { (t - x.t).max(0.0) * bpm / 60.0 / beats } else { 0.0 };
        Some((x.v + moved).rem_euclid(1.0))
    }
}

/// One deck as of a moment.
#[derive(Clone, Debug, PartialEq)]
pub struct DeckView {
    pub deck: usize,
    pub title: String,
    pub artist: String,
    pub album: String,
    /// Something is loaded (a title has been heard).
    pub loaded: bool,
    pub playing: bool,
    /// Seconds into the record, carried on from the last message at the deck's rate.
    pub position: Option<f64>,
    /// Playback speed (tempo fader): current / original BPM.
    pub rate: f64,
    pub bpm: Option<f64>,
    pub bpm_original: Option<f64>,
    /// Where in the beat, 0..1 (needs `osc.msg.n/beat/subdiv 1`).
    pub beat_phase: Option<f64>,
    /// Where in the bar, 0..1 (only the master deck: `osc.msg.master/beat/subdiv 4`).
    pub bar_phase: Option<f64>,
    pub phrase: Option<PhraseKind>,
    pub phrase_next: Option<PhraseKind>,
    /// Beats until the next phrase, carried on.
    pub beats_to_next: Option<f64>,
    /// Counts up on every new record (to notice a reload of the same one too).
    pub loads: u32,
    /// Counts up on every jump in position (seek, loop, hot cue).
    pub jumps: u32,
}

/// All decks as of a moment.
#[derive(Clone, Debug, PartialEq)]
pub struct View {
    pub decks: Vec<DeckView>,
    /// rekordbox's master deck, steadied ([`MASTER_HOLD`]).
    pub master: Option<usize>,
    /// The deck to follow: the master while it plays, else the deck that plays (the one
    /// started last when several do), else the master.
    pub lead: Option<usize>,
    /// Heard from rkbx_link within [`SILENT`].
    pub live: bool,
}

/// What rkbx_link has said so far.
#[derive(Clone, Debug, Default)]
pub struct Feed {
    decks: [Deck; DECKS],
    master_raw: Option<usize>,
    master_raw_since: f64,
    master: Option<usize>,
    /// When each deck last started playing (for `lead`).
    started: [Option<f64>; DECKS],
    was_playing: [bool; DECKS],
    heard: Option<f64>,
    /// The master's last time, to place it once the deck's own time arrives.
    master_time: Option<f64>,
}

enum Who {
    Deck(usize),
    Master,
}

/// `/0/time`, `/time/0`, `/master/beat/subdiv/4` → (who, field path).
fn split(addr: &str) -> Option<(Who, Vec<&str>)> {
    let parts: Vec<&str> = addr.trim_start_matches('/').split('/').collect();
    let who = |s: &str| match s {
        "master" => Some(Who::Master),
        n => n.parse::<usize>().ok().filter(|n| *n < DECKS).map(Who::Deck),
    };
    if let Some(w) = parts.first().and_then(|p| who(p)) {
        return Some((w, parts[1..].to_vec()));
    }
    // the other spelling: /time/0, /phrase/0/current
    let w = who(parts.get(1)?)?;
    let mut rest = vec![parts[0]];
    rest.extend_from_slice(&parts[2..]);
    Some((w, rest))
}

impl Feed {
    pub fn new() -> Feed {
        Feed::default()
    }

    /// Take in one message heard at `t`.
    pub fn apply(&mut self, m: &crate::osc::Msg, t: f64) {
        self.heard = Some(t);
        let Some((who, field)) = split(&m.addr) else { return };
        match who {
            Who::Deck(n) => self.apply_deck(n, &field, m, t),
            Who::Master => self.apply_master(&field, m, t),
        }
        self.settle(t);
    }

    fn apply_deck(&mut self, n: usize, field: &[&str], m: &crate::osc::Msg, t: f64) {
        let d = &mut self.decks[n];
        let num = m.num();
        match field {
            ["time"] => {
                let Some(v) = num else { return };
                if let Some(p) = d.time_raw {
                    let expected = if d.playing(t) { p.v + (t - p.t) * d.rate() } else { p.v };
                    if (v - expected).abs() > JUMP {
                        d.jumps += 1;
                    }
                    if v > p.v + 1e-6 {
                        d.moved = Some(t);
                    }
                }
                d.time_raw = Some(At { v, t });
                if self.master_time == Some(v) {
                    self.see_master(n, t);
                }
            }
            ["track", "title"] => {
                let s = m.text().unwrap_or_default().to_owned();
                // a new record: its place is not known until rkbx_link sends it (the beat and
                // phrase are kept: rkbx_link sends the new record's just before its title)
                if s != d.title || d.loads == 0 {
                    d.loads += 1;
                    d.time_raw = None;
                    d.moved = None;
                }
                d.title = s;
            }
            ["track", "artist"] => d.artist = m.text().unwrap_or_default().to_owned(),
            ["track", "album"] => d.album = m.text().unwrap_or_default().to_owned(),
            ["bpm", "current"] => d.bpm = num,
            ["bpm", "original"] => d.bpm_original = num,
            ["beat", "subdiv", x] => {
                let every = x.parse::<f64>().ok();
                if let Some(v) = num {
                    if every == Some(1.0) {
                        d.beat = Some(At { v, t });
                    } else if every == Some(4.0) {
                        d.bar = Some(At { v, t });
                    }
                }
            }
            ["phrase", "current"] => d.phrase = num.map(|v| v as i32),
            ["phrase", "next"] => d.phrase_next = num.map(|v| v as i32),
            ["phrase", "countin"] => d.countin = num.map(|v| At { v, t }),
            _ => {}
        }
    }

    fn apply_master(&mut self, field: &[&str], m: &crate::osc::Msg, t: f64) {
        match field {
            ["time"] => {
                let Some(v) = m.num() else { return };
                self.master_time = Some(v);
                let hits: Vec<usize> = (0..DECKS).filter(|&n| self.decks[n].time_raw.is_some_and(|p| p.v == v)).collect();
                if let [n] = hits[..] {
                    self.see_master(n, t);
                }
            }
            ["track", "title"] => {
                let s = m.text().unwrap_or_default().to_owned();
                let hits: Vec<usize> = (0..DECKS).filter(|&n| self.decks[n].loads > 0 && self.decks[n].title == s).collect();
                if let [n] = hits[..] {
                    self.see_master(n, t);
                }
            }
            // the master's bar phase is kept on its deck once it is known
            ["beat", "subdiv", x] if x.parse::<f64>().ok() == Some(4.0) => {
                if let (Some(n), Some(v)) = (self.master_raw, m.num()) {
                    self.decks[n].bar = Some(At { v, t });
                }
            }
            _ => {}
        }
    }

    fn see_master(&mut self, n: usize, t: f64) {
        if self.master_raw != Some(n) {
            self.master_raw = Some(n);
            self.master_raw_since = t;
        }
    }

    fn settle(&mut self, t: f64) {
        if self.master_raw != self.master && (t - self.master_raw_since >= MASTER_HOLD || self.master.is_none()) {
            self.master = self.master_raw;
        }
        for n in 0..DECKS {
            let p = self.decks[n].playing(t);
            if p && !self.was_playing[n] {
                self.started[n] = Some(t);
            }
            self.was_playing[n] = p;
        }
    }

    /// The decks as of `t` (positions and phases carried on to then).
    pub fn view(&self, t: f64) -> View {
        // the hold also runs out between messages
        let master = if self.master_raw != self.master && t - self.master_raw_since >= MASTER_HOLD { self.master_raw } else { self.master };
        let decks: Vec<DeckView> = self
            .decks
            .iter()
            .enumerate()
            .map(|(n, d)| DeckView {
                deck: n,
                title: d.title.clone(),
                artist: d.artist.clone(),
                album: d.album.clone(),
                loaded: d.loads > 0,
                playing: d.playing(t),
                position: d.position(t),
                rate: d.rate(),
                bpm: d.bpm,
                bpm_original: d.bpm_original,
                beat_phase: d.phase(d.beat, 1.0, t),
                bar_phase: d.phase(d.bar, 4.0, t),
                phrase: d.phrase.and_then(PhraseKind::from_rkbx),
                phrase_next: d.phrase_next.and_then(PhraseKind::from_rkbx),
                beats_to_next: d.countin.map(|c| {
                    let moved = if d.playing(t) { (t - c.t).max(0.0) * d.bpm.unwrap_or(0.0) / 60.0 } else { 0.0 };
                    (c.v - moved).max(0.0)
                }),
                loads: d.loads,
                jumps: d.jumps,
            })
            .collect();
        let lead = match master {
            Some(m) if decks[m].playing => Some(m),
            _ => {
                let playing = (0..DECKS).filter(|&n| decks[n].playing);
                playing.max_by(|&a, &b| self.started[a].partial_cmp(&self.started[b]).unwrap_or(std::cmp::Ordering::Equal)).or(master)
            }
        };
        View { decks, master, lead, live: self.heard.is_some_and(|h| t - h <= SILENT) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::{Arg, Msg};

    fn f(addr: &str, v: f32) -> Msg {
        Msg::new(addr, vec![Arg::Float(v)])
    }
    fn s(addr: &str, v: &str) -> Msg {
        Msg::new(addr, vec![Arg::Str(v.into())])
    }

    /// Deck `n` playing from `from` for `secs` at 50 Hz, its time also as master when asked.
    fn play(feed: &mut Feed, n: usize, t0: f64, from: f32, secs: f64, as_master: bool) -> f64 {
        let mut t = t0;
        while t < t0 + secs {
            let v = from + (t - t0) as f32;
            feed.apply(&f(&format!("/{n}/time"), v), t);
            if as_master {
                feed.apply(&f("/master/time", v), t);
            }
            t += 0.02;
        }
        t
    }

    #[test]
    fn plays_carries_on_and_stops() {
        let mut feed = Feed::new();
        feed.apply(&s("/0/track/title", "Cairo FM"), 0.0);
        feed.apply(&f("/0/bpm/current", 111.0), 0.0);
        feed.apply(&f("/0/bpm/original", 111.0), 0.0);
        let t = play(&mut feed, 0, 0.0, 40.0, 2.0, true);
        let v = feed.view(t + 0.1);
        assert!(v.decks[0].playing);
        let p = v.decks[0].position.unwrap();
        assert!((p - 42.1).abs() < 0.03, "{p}");
        assert_eq!(v.master, Some(0));
        assert_eq!(v.lead, Some(0));
        // silence: stopped, position held
        let v = feed.view(t + 1.0);
        assert!(!v.decks[0].playing);
        assert!((v.decks[0].position.unwrap() - 42.0).abs() < 0.03);
        assert!(v.live);
        assert!(!feed.view(t + 3.0).live);
    }

    #[test]
    fn rate_follows_tempo() {
        let mut feed = Feed::new();
        feed.apply(&s("/1/track/title", "XXL"), 0.0);
        feed.apply(&f("/1/bpm/current", 95.8), 0.0);
        feed.apply(&f("/1/bpm/original", 141.0), 0.0);
        feed.apply(&f("/1/time", 10.0), 0.0);
        feed.apply(&f("/1/time", 10.0136), 0.02);
        let v = feed.view(1.02 - 0.8);
        assert!((v.decks[1].rate - 95.8 / 141.0).abs() < 1e-6);
        assert!((v.decks[1].position.unwrap() - (10.0136 + 0.2 * 95.8 / 141.0)).abs() < 1e-3);
    }

    #[test]
    fn load_flicker_does_not_move_master() {
        let mut feed = Feed::new();
        feed.apply(&s("/0/track/title", "Waiting"), 0.0);
        feed.apply(&s("/1/track/title", "XXL"), 0.0);
        let t = play(&mut feed, 0, 0.0, 100.0, 1.0, true);
        assert_eq!(feed.view(t).master, Some(0));
        // deck 1 is loaded anew: /master names it for 0.1 s, then deck 0 again
        feed.apply(&s("/1/track/title", "Don't call me"), t);
        feed.apply(&s("/master/track/title", "Don't call me"), t);
        feed.apply(&s("/master/track/title", "Waiting"), t + 0.1);
        let t2 = play(&mut feed, 0, t + 0.1, 101.1, 1.0, true);
        let v = feed.view(t2);
        assert_eq!(v.master, Some(0));
        assert_eq!(v.decks[1].loads, 2);
        assert_eq!(v.decks[1].title, "Don't call me");
        assert_eq!(v.decks[1].position, None);
    }

    #[test]
    fn master_moves_after_hold() {
        let mut feed = Feed::new();
        feed.apply(&s("/0/track/title", "A"), 0.0);
        feed.apply(&s("/1/track/title", "B"), 0.0);
        let t = play(&mut feed, 0, 0.0, 10.0, 1.0, true);
        let t = play(&mut feed, 1, t, 0.0, 1.0, true);
        let v = feed.view(t);
        assert_eq!(v.master, Some(1));
        assert_eq!(v.lead, Some(1));
    }

    #[test]
    fn lead_prefers_a_playing_deck_over_a_stopped_master() {
        let mut feed = Feed::new();
        feed.apply(&s("/0/track/title", "Waiting"), 0.0);
        feed.apply(&s("/1/track/title", "XXL"), 0.0);
        // deck 0 is master and ends; deck 1 plays on its own (rkbx_link has not moved master)
        let t = play(&mut feed, 0, 0.0, 300.0, 1.0, true);
        let t = play(&mut feed, 1, t, 20.0, 2.0, false);
        let v = feed.view(t);
        assert_eq!(v.master, Some(0));
        assert!(!v.decks[0].playing);
        assert_eq!(v.lead, Some(1));
    }

    #[test]
    fn jumps_are_counted() {
        let mut feed = Feed::new();
        feed.apply(&s("/0/track/title", "A"), 0.0);
        let t = play(&mut feed, 0, 0.0, 10.0, 1.0, false);
        feed.apply(&f("/0/time", 60.0), t);
        let t = play(&mut feed, 0, t + 0.02, 60.02, 0.5, false);
        feed.apply(&f("/0/time", 30.0), t);
        assert_eq!(feed.view(t).decks[0].jumps, 2);
    }

    #[test]
    fn phases_and_phrase() {
        let mut feed = Feed::new();
        feed.apply(&s("/0/track/title", "A"), 0.0);
        feed.apply(&f("/0/bpm/current", 120.0), 0.0);
        feed.apply(&Msg::new("/0/phrase/current", vec![Arg::Int(3)]), 0.0);
        feed.apply(&Msg::new("/0/phrase/next", vec![Arg::Int(4)]), 0.0);
        feed.apply(&f("/0/phrase/countin", 8.0), 0.0);
        feed.apply(&f("/0/beat/subdiv/1", 0.25), 0.0);
        let t = play(&mut feed, 0, 0.0, 5.0, 0.5, false);
        let v = &feed.view(t).decks[0];
        // 120 bpm: 2 beats a second
        assert!((v.beat_phase.unwrap() - (0.25 + 2.0 * t).rem_euclid(1.0)).abs() < 1e-6);
        assert!((v.beats_to_next.unwrap() - (8.0 - 2.0 * t)).abs() < 1e-6);
        assert_eq!(v.phrase, Some(PhraseKind::Chorus));
        assert_eq!(v.phrase_next, Some(PhraseKind::Bridge));
    }

    #[test]
    fn other_spelling() {
        let mut feed = Feed::new();
        feed.apply(&s("/2/track/title", "A"), 0.0);
        feed.apply(&f("/time/2", 5.0), 0.0);
        feed.apply(&Msg::new("/phrase/2/current", vec![Arg::Int(1)]), 0.0);
        let v = feed.view(0.0);
        assert_eq!(v.decks[2].position, Some(5.0));
        assert_eq!(v.decks[2].phrase, Some(PhraseKind::Intro));
    }
}
