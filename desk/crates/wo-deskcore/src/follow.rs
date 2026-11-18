//! Follow mode: the Desk as rekordbox's shadow, for a set played in rekordbox on this
//! computer (plan: ~/.claude/plans/wetowl-rekordbox-windows.md).
//!
//! rkbx_link tells what each rekordbox deck has and where it is (wo-rkbx); rekordbox's own
//! library gives each record's grid, cues and phrases and finds its audio (wo-rekordbox).
//! The Desk loads the same file on the same deck and keeps it where rekordbox is ("ghost
//! decks"): playing as it plays, at its tempo, put back when it drifts or jumps. Its engine
//! runs without a sound card, so nothing is heard from it (rekordbox holds the DDJ's), but
//! the show hears both decks and reads their records as it does when the Desk plays.
//!
//! What it cannot know without the DDJ's faders: the mix. The crossfader follows the deck
//! rkbx_link says leads, and stands in the middle while both decks play.
use std::path::PathBuf;
use std::sync::{Arc, mpsc};
use std::time::Instant;

use wo_engine::DeckId;

use crate::records::{Audio, Loudness, Record};
use crate::Desk;

/// Off by more than this, a deck is put back where rekordbox is rather than bent there.
const SNAP: f64 = 0.08;
/// Puts back at most this often (a seek past what is decoded yet would repeat otherwise).
const SNAP_EVERY: f64 = 0.5;
/// How much of the drift a bend takes back each second, and the most it bends.
const CATCH_UP: f64 = 0.5;
const MOST_BEND: f64 = 0.03;
/// The crossfader's speed, its whole travel a second this many times.
const GLIDE: f32 = 0.5;
/// Ticks a newly loaded deck is left alone: the engine still tells the record before's
/// place until its next block has played.
const SETTLE_TICKS: u8 = 3;

/// What to follow with.
#[derive(Clone, Debug)]
pub struct FollowOptions {
    /// Where rkbx_link sends (its `osc.destination`).
    pub addr: String,
    /// Where the audio is (rekordbox's library keeps only file names): searched whole.
    pub music: Vec<PathBuf>,
    /// rekordbox's library folder; its usual place when none.
    pub library: Option<PathBuf>,
}

impl Default for FollowOptions {
    fn default() -> Self {
        FollowOptions { addr: wo_rkbx::listen::DEFAULT_ADDR.into(), music: wo_rekordbox::default_music().into_iter().collect(), library: None }
    }
}

/// One deck as followed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FollowDeck {
    /// The title rekordbox shows.
    pub title: String,
    /// Its record found in the library, with its audio (None: nothing loaded yet).
    pub found: Option<bool>,
    pub playing: bool,
    /// How far the Desk's deck is from rekordbox's, ms (+: behind).
    pub drift_ms: Option<f64>,
}

/// How following goes, for the window.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FollowView {
    /// rkbx_link heard lately.
    pub live: bool,
    pub packets: u64,
    /// rekordbox's analysed records found, once read.
    pub library: Option<usize>,
    pub decks: [FollowDeck; 2],
    /// The deck the show follows.
    pub lead: Option<usize>,
    /// Why following is not working, where it is not.
    pub trouble: Option<String>,
}

pub(crate) struct Follow {
    listener: wo_rkbx::Listener,
    index: Option<Arc<wo_rekordbox::Index>>,
    index_rx: Option<mpsc::Receiver<wo_rekordbox::Index>>,
    /// rkbx_link's load count each deck was last loaded for, and its jump count.
    seen: [u32; 2],
    jumps: [u32; 2],
    found: [Option<bool>; 2],
    snapped: [Option<Instant>; 2],
    settle: [u8; 2],
    rate: [f64; 2],
    last: Instant,
    view: FollowView,
}

/// A stable id for a record of rekordbox's library: negative (never the house's), apart
/// from a stick's (whose ids carry their stick's tag above bit 32).
fn local_id(key: &str) -> i64 {
    let h = key.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ b as u64).wrapping_mul(0x0100_0000_01b3));
    -((h >> 2) as i64 & 0x7fff_ffff) - 1
}

/// The record a deck should have for what rekordbox shows.
fn record_for(index: Option<&wo_rekordbox::Index>, d: &wo_rkbx::DeckView) -> (Record, bool) {
    let entry = index.and_then(|ix| ix.find(&d.title, &d.artist, &d.album)).filter(|e| e.audio.is_some());
    let Some(e) = entry else {
        let r = Record {
            id: local_id(&d.title),
            title: d.title.clone(),
            artist: d.artist.clone(),
            bpm: d.bpm_original.or(d.bpm).unwrap_or(0.0),
            key: String::new(),
            seconds: 0,
            audio: Audio::None,
            cover: false,
            cover_rgb: None,
            loudness: Loudness::default(),
        };
        return (r, false);
    };
    // its length and tempo from rekordbox's grid (the grid runs to the end)
    let beats = wo_usb::analysis_of(&e.dat).map(|a| a.beats).unwrap_or_default();
    let n = beats.len();
    let bpm = if n > 8 { 60.0 * (n - 1) as f64 / (beats[n - 1] - beats[0]) } else { d.bpm_original.or(d.bpm).unwrap_or(0.0) };
    let seconds = beats.last().map_or(0, |l| (l + 1.0).ceil() as u32);
    let r = Record {
        id: local_id(&e.dat.to_string_lossy()),
        title: e.title(),
        artist: if e.tags.artist.is_empty() { d.artist.clone() } else { e.tags.artist.clone() },
        bpm: (bpm * 100.0).round() / 100.0,
        key: String::new(),
        seconds,
        audio: Audio::Usb { path: e.audio.clone().unwrap(), anlz: Some(e.dat.clone()), artwork: None },
        cover: false,
        cover_rgb: None,
        loudness: Loudness::default(),
    };
    (r, true)
}

impl Desk {
    /// A Desk that follows rekordbox: rkbx_link heard on `o.addr`, rekordbox's library
    /// read in the background. The Auto DJ is off and the Desk sounds nothing.
    pub fn open_following(o: FollowOptions) -> Result<Desk, String> {
        let listener = wo_rkbx::Listener::start(&o.addr, None).map_err(|e| format!("listening for rkbx_link on {}: {e}", o.addr))?;
        let mut desk = Desk::open_as(false, true);
        desk.auto = false;
        let library = o.library.clone().or_else(wo_rekordbox::library_dir);
        let (tx, rx) = mpsc::channel();
        let trouble = match library {
            Some(lib) => {
                let music = o.music.clone();
                std::thread::Builder::new()
                    .name("rekordbox library".into())
                    .spawn(move || {
                        let ix = wo_rekordbox::Index::build(&wo_rekordbox::anlz_root(&lib), &music);
                        eprintln!("follow: rekordbox library {:?} (music {music:?})", ix.stats);
                        let _ = tx.send(ix);
                    })
                    .map_err(|e| e.to_string())?;
                None
            }
            None => Some("rekordbox's library is not on this computer".to_owned()),
        };
        for d in 0..2 {
            desk.set_fader(d, 1.0);
        }
        desk.follow = Some(Follow {
            listener,
            index: None,
            index_rx: Some(rx),
            seen: [0; 2],
            jumps: [0; 2],
            found: [None; 2],
            snapped: [None; 2],
            settle: [0; 2],
            rate: [1.0; 2],
            last: Instant::now(),
            view: FollowView { trouble, ..Default::default() },
        });
        Ok(desk)
    }

    /// How following goes (None: not following).
    pub fn following(&self) -> Option<FollowView> {
        self.follow.as_ref().map(|f| f.view.clone())
    }

    /// Each tick: rekordbox's decks onto the Desk's.
    pub(crate) fn follow_tick(&mut self) {
        let Some(f) = self.follow.as_mut() else { return };
        let dt = f.last.elapsed().as_secs_f64().min(0.25);
        f.last = Instant::now();
        if let Some(rx) = &f.index_rx
            && let Ok(ix) = rx.try_recv()
        {
            f.view.library = Some(ix.stats.analyses);
            f.index = Some(Arc::new(ix));
            f.index_rx = None;
            self.changes += 1;
        }
        let v = f.listener.view();
        let index = f.index.clone();
        let mut loads = vec![];
        for d in 0..2 {
            let dv = &v.decks[d];
            // a new record on rekordbox's deck: the same on ours, once the library is read
            if dv.loaded && dv.loads != f.seen[d] && (index.is_some() || f.index_rx.is_none()) {
                f.seen[d] = dv.loads;
                f.jumps[d] = dv.jumps;
                f.snapped[d] = None;
                f.settle[d] = SETTLE_TICKS;
                let (record, found) = record_for(index.as_deref(), dv);
                f.found[d] = Some(found);
                if !found {
                    eprintln!("follow: deck {d}: {:?} not found in rekordbox's library and music folders", dv.title);
                }
                loads.push((d, record));
            }
        }
        let f = self.follow.as_mut().unwrap();
        let mut deck_views: [FollowDeck; 2] = Default::default();
        for d in 0..2 {
            let dv = &v.decks[d];
            let e = self.engine.deck(DeckId::new(d).unwrap());
            let st = e.read();
            // a deck loaded this tick still has the record before on it until the load
            // below, and tells its place for a few ticks more
            let loading = loads.iter().any(|(l, _)| *l == d);
            if !loading && f.settle[d] > 0 {
                f.settle[d] -= 1;
            }
            if dv.loaded && !loading && f.settle[d] == 0 && f.seen[d] == dv.loads && f.found[d] == Some(true) {
                if st.playing != dv.playing {
                    // starting: from exactly where rekordbox is (not bent there over a second)
                    if let (true, Some(p)) = (dv.playing, dv.position) {
                        e.seek(p.max(0.0));
                        e.bend(1.0);
                        f.snapped[d] = Some(Instant::now());
                    }
                    e.play(dv.playing);
                }
                if (f.rate[d] - dv.rate).abs() > 1e-4 {
                    e.set_rate(dv.rate);
                    f.rate[d] = dv.rate;
                }
                if let Some(p) = dv.position {
                    let err = p - e.position();
                    let may_snap = f.snapped[d].is_none_or(|t| t.elapsed().as_secs_f64() >= SNAP_EVERY);
                    if may_snap && (dv.jumps != f.jumps[d] || err.abs() > SNAP) {
                        e.seek(p.max(0.0));
                        e.bend(1.0);
                        f.jumps[d] = dv.jumps;
                        f.snapped[d] = Some(Instant::now());
                    } else if dv.playing {
                        e.bend(1.0 + (err * CATCH_UP).clamp(-MOST_BEND, MOST_BEND));
                    }
                    deck_views[d].drift_ms = Some(err * 1000.0);
                }
            }
            deck_views[d].title = dv.title.clone();
            deck_views[d].found = f.found[d];
            deck_views[d].playing = dv.playing;
        }
        f.view.live = v.live;
        f.view.packets = f.listener.packets();
        f.view.lead = v.lead;
        f.view.decks = deck_views;
        // the mix, as well as it can be told: the lead deck, both while both play
        let both = v.decks[0].playing && v.decks[1].playing;
        let target = match (both, v.lead) {
            (true, _) => Some(0.5),
            (false, Some(0)) => Some(0.0),
            (false, Some(1)) => Some(1.0),
            _ => None,
        };
        let lead = v.lead.filter(|l| *l < 2);
        for (d, record) in loads {
            self.load(d, record);
        }
        if let Some(t) = target {
            let x = self.crossfader;
            let step = GLIDE * dt as f32;
            let next = if (t - x).abs() <= step { t } else { x + step * (t - x).signum() };
            if next != x {
                self.set_crossfader(next);
            }
        }
        if let Some(l) = lead {
            self.master = l;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_ids_are_negative_and_stable() {
        let a = local_id("C:/x/ANLZ0000.DAT");
        assert!(a < 0);
        assert_eq!(a, local_id("C:/x/ANLZ0000.DAT"));
        assert_ne!(a, local_id("C:/y/ANLZ0000.DAT"));
        assert!(a > -(1i64 << 32), "apart from a stick's ids");
    }

    #[test]
    fn an_unknown_record_still_names_the_deck() {
        let d = wo_rkbx::DeckView {
            deck: 0,
            title: "Nowhere To Be Found".into(),
            artist: "Nobody".into(),
            album: String::new(),
            loaded: true,
            playing: true,
            position: Some(10.0),
            rate: 1.0,
            bpm: Some(128.0),
            bpm_original: Some(128.0),
            beat_phase: None,
            bar_phase: None,
            phrase: None,
            phrase_next: None,
            beats_to_next: None,
            loads: 1,
            jumps: 0,
        };
        let (r, found) = record_for(None, &d);
        assert!(!found);
        assert_eq!((r.title.as_str(), r.artist.as_str(), r.bpm), ("Nowhere To Be Found", "Nobody", 128.0));
        assert!(!r.playable());
    }
}
