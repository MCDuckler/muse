//! The booth as it was, taken up again after a restart (v1: session.dart): while a record
//! plays the Desk keeps what is on each deck and where, its tempo and fader, the crossfader,
//! the Auto DJ and the hand's queue (every few seconds, beside its other files); started
//! again within eight hours of a set that was playing, it puts the same records back on the
//! same decks, each at its place, playing where it was playing, and the Auto DJ carries on.
//! A set stopped by hand (nothing playing for a while) is not taken up again.
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::records::Record;

/// How old a session may be and still be taken up.
pub const FRESH: Duration = Duration::from_secs(8 * 3600);
/// How often it is kept while something plays.
pub const EVERY: Duration = Duration::from_secs(5);
/// Nothing playing this long: the set is over (not taken up again).
pub const OVER_AFTER: Duration = Duration::from_secs(15);

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DeckSession {
    pub record: Record,
    /// Seconds into it.
    pub position: f64,
    pub playing: bool,
    /// The pitch fader, -1..1, and the channel fader and gain.
    pub pitch: f64,
    pub fader: f32,
    pub gain: f32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Session {
    /// When it was kept (seconds since 1970), and whether a record was playing then.
    pub at: u64,
    pub live: bool,
    pub master: usize,
    pub crossfader: f32,
    pub auto: bool,
    pub decks: Vec<DeckSession>,
    #[serde(default)]
    pub queue: Vec<Record>,
}

pub fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

/// Where it is kept: beside the Desk's other files (its config folder — a test's own).
pub fn file() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("wetowl-desk").join("booth-session.json"))
}

/// Kept (written whole, then moved into place).
pub fn save(s: &Session) {
    let Some(f) = file() else { return };
    let _ = std::fs::create_dir_all(f.parent().unwrap());
    let part = f.with_extension("json.part");
    if std::fs::write(&part, serde_json::to_vec(s).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(&part, &f);
    }
}

/// The session to take up: one kept while playing, within FRESH.
pub fn load() -> Option<Session> {
    let s: Session = serde_json::from_slice(&std::fs::read(file()?).ok()?).ok()?;
    (s.live && now_secs().saturating_sub(s.at) <= FRESH.as_secs() && !s.decks.is_empty()).then_some(s)
}

impl crate::Desk {
    /// The booth as it is now, as a session.
    fn session_now(&self, live: bool) -> Session {
        let decks = (0..2)
            .map(|d| {
                let st = self.engine.deck(wo_engine::DeckId::new(d).unwrap()).read();
                let s = &self.slots[d];
                DeckSession { record: s.record.clone(), position: self.engine.deck(wo_engine::DeckId::new(d).unwrap()).position(), playing: st.playing, pitch: s.hands.pitch, fader: s.fader, gain: s.gain }
            })
            .collect();
        Session { at: now_secs(), live, master: self.master, crossfader: self.crossfader, auto: self.auto, decks, queue: self.hand_queue.clone() }
    }

    /// Each tick: kept every few seconds while a record plays; a while after the last one
    /// stopped, kept as over; a resumed deck put at its place and played once its sound is
    /// in.
    pub(crate) fn session_tick(&mut self) {
        let playing = (0..2).any(|d| self.engine.deck(wo_engine::DeckId::new(d).unwrap()).read().playing);
        let resuming = self.resume.iter().any(Option::is_some);
        if playing {
            self.idle_since = None;
            if self.session_kept.is_none_or(|t| t.elapsed() >= EVERY) {
                save(&self.session_now(true));
                self.session_kept = Some(Instant::now());
                self.session_live = true;
            }
        } else if self.session_live && !resuming {
            let since = *self.idle_since.get_or_insert_with(Instant::now);
            if since.elapsed() >= OVER_AFTER {
                save(&self.session_now(false));
                self.session_live = false;
            }
        }
        for d in 0..2 {
            let Some((at, play)) = self.resume[d] else { continue };
            // its sound decoded past the place (or whole), and the house's analysis in
            let decoded = self.slots[d].wave.lock().unwrap().seconds();
            let whole = self.slots[d].loader.as_ref().is_none_or(|h| h.is_finished());
            if decoded >= at + 2.0 || (whole && decoded > 0.0) {
                self.seek_to(d, at);
                if play {
                    self.engine.deck(wo_engine::DeckId::new(d).unwrap()).play(true);
                }
                self.resume[d] = None;
            }
        }
    }

    /// The set that was playing when the Desk last closed, back on the decks: the same
    /// records at their places, playing where they played, the faders, the crossfader, the
    /// Auto DJ and the queue. Whether there was one to take up.
    pub(crate) fn resume_session(&mut self) -> bool {
        let Some(s) = load() else { return false };
        // a record of the house's needs the house
        let house = self.house.is_some();
        let can = move |r: &Record| r.playable() && (!matches!(r.audio, crate::records::Audio::House { .. }) || house);
        if !s.decks.iter().any(|d| can(&d.record)) {
            return false;
        }
        let mut said = vec![];
        for (d, ds) in s.decks.iter().enumerate().take(2) {
            if !can(&ds.record) {
                continue;
            }
            self.load(d, ds.record.clone());
            self.set_pitch(d, ds.pitch);
            self.set_fader(d, ds.fader);
            self.set_gain(d, ds.gain);
            self.resume[d] = Some((ds.position, ds.playing));
            if ds.playing {
                said.push(format!("{} at {}:{:02}", ds.record.title, (ds.position / 60.0) as i64, (ds.position % 60.0) as i64));
            }
        }
        self.master = s.master.min(1);
        self.set_crossfader(s.crossfader);
        self.hand_queue = s.queue.into_iter().filter(|r| can(r)).collect();
        self.set_auto(s.auto);
        self.session_live = true;
        self.resumed = Some(if said.is_empty() { "Back in the booth: the records as they were".to_owned() } else { format!("Back in the booth: {}", said.join(" · ")) });
        true
    }

    /// What taking the set up again said, once (the window says it).
    pub fn take_resumed(&mut self) -> Option<String> {
        self.resumed.take()
    }
}

use std::time::Instant;
