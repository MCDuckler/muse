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
//! Made to need no hands: the Desk finds rkbx_link, sets it up and runs it (unless one is
//! already sending), reads rekordbox's library again when a deck's record is not in it
//! (analysed since), and says in [FollowView] what is missing and where.
//!
//! What it cannot know without the DDJ's faders: the mix. The crossfader follows the deck
//! rkbx_link says leads, and stands in the middle while both decks play.
use std::path::{Path, PathBuf};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use wo_engine::DeckId;
use wo_rkbx::runner::{self, Runner};
pub use wo_rkbx::runner::{Link, RELEASES, RunnerView};

use crate::records::{Audio, Loudness, Record, Tags};
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
/// How long to hear whether an rkbx_link is sending already before starting one.
const HEAR_FIRST: Duration = Duration::from_millis(1500);
/// How often to look again for an rkbx_link not found.
const LOOK_AGAIN: Duration = Duration::from_secs(3);
/// The library read again at most this often for a record not in it.
const READ_AGAIN: Duration = Duration::from_secs(15);
/// Within this, a deck counts as in step.
pub const IN_STEP_MS: f64 = 60.0;

/// What to follow with.
#[derive(Clone, Debug)]
pub struct FollowOptions {
    /// Where rkbx_link sends (its `osc.destination`).
    pub addr: String,
    /// Where the audio is (rekordbox's library keeps only file names): searched whole.
    pub music: Vec<PathBuf>,
    /// rekordbox's library folder; its usual place when none.
    pub library: Option<PathBuf>,
    /// rkbx_link chosen by hand (the program or its folder); else looked for.
    pub rkbx_link: Option<PathBuf>,
    /// Run rkbx_link (false: someone else does).
    pub run_rkbx: bool,
}

impl Default for FollowOptions {
    fn default() -> Self {
        FollowOptions { addr: wo_rkbx::listen::DEFAULT_ADDR.into(), music: wo_rekordbox::default_music_folders(), library: None, rkbx_link: None, run_rkbx: true }
    }
}

/// rkbx_link, as following has it.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum Rkbx {
    /// Not decided yet (listening for one already sending).
    #[default]
    Waiting,
    /// Not on this computer.
    NotFound,
    /// One the Desk did not start is sending.
    Outside,
    /// The Desk's own.
    Ours(RunnerView),
}

/// rekordbox's library, as read.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LibraryView {
    /// Records analysed (with a beat grid), and of them with phrases.
    pub tracks: usize,
    pub with_phrases: usize,
    /// Records whose audio is not in the music folders: their file names.
    pub missing: Vec<String>,
}

/// One deck as followed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FollowDeck {
    /// The title rekordbox shows.
    pub title: String,
    /// Its record found in the library, with its audio (None: nothing loaded yet).
    pub found: Option<bool>,
    /// Its record has rekordbox's phrase analysis.
    pub phrases: bool,
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
    pub rkbx: Rkbx,
    /// The rekordbox installed here.
    pub rekordbox: Option<String>,
    /// The library once read (None: not yet), and whether it is being read now.
    pub library: Option<LibraryView>,
    pub reading: bool,
    pub music: Vec<PathBuf>,
    pub decks: [FollowDeck; 2],
    /// The deck the show follows.
    pub lead: Option<usize>,
    /// Why following cannot work at all, where it cannot.
    pub trouble: Option<String>,
}

/// What is here for following, before it is on (the window's checklist).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FollowHere {
    /// The rekordbox installed, its version.
    pub rekordbox: Option<String>,
    /// Its library folder is there.
    pub library: bool,
    /// rkbx_link found, or a download of it not unpacked yet.
    pub rkbx_link: Option<PathBuf>,
    pub rkbx_zip: Option<PathBuf>,
}

/// Looks around for what following needs; `rkbx_hint`: an rkbx_link chosen by hand.
pub fn look_around(rkbx_hint: Option<&Path>) -> FollowHere {
    FollowHere {
        rekordbox: wo_rekordbox::installed(),
        library: wo_rekordbox::library_dir().is_some(),
        rkbx_link: runner::find(rkbx_hint),
        rkbx_zip: runner::downloaded_zip(),
    }
}

/// rekordbox is open now (a hint: see [wo_rekordbox::open_now]).
pub fn rekordbox_open() -> bool {
    wo_rekordbox::open_now()
}

/// Where music usually is (searched when no folders are chosen).
pub fn usual_music() -> Vec<PathBuf> {
    wo_rekordbox::default_music_folders()
}

/// A downloaded rkbx_link (`zip`) unpacked for the Desk's use; the program.
pub fn unpack_rkbx_link(zip: &Path) -> Result<PathBuf, String> {
    runner::unpack(zip)
}

pub(crate) struct Follow {
    listener: wo_rkbx::Listener,
    port: u16,
    rkbx: Rkbx,
    runner: Option<Runner>,
    run_rkbx: bool,
    rkbx_hint: Option<PathBuf>,
    started: Instant,
    looked: Option<Instant>,
    library_dir: Option<PathBuf>,
    music: Vec<PathBuf>,
    index: Option<Arc<wo_rekordbox::Index>>,
    index_rx: Option<mpsc::Receiver<wo_rekordbox::Index>>,
    read_at: Option<Instant>,
    /// rkbx_link's load count each deck was last loaded for, and its jump count.
    seen: [u32; 2],
    jumps: [u32; 2],
    found: [Option<bool>; 2],
    phrases: [bool; 2],
    snapped: [Option<Instant>; 2],
    settle: [u8; 2],
    rate: [f64; 2],
    last: Instant,
    rekordbox: Option<String>,
    view: FollowView,
}

/// A stable id for a record of rekordbox's library: negative (never the house's), apart
/// from a stick's (whose ids carry their stick's tag above bit 32).
fn local_id(key: &str) -> i64 {
    let h = key.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ b as u64).wrapping_mul(0x0100_0000_01b3));
    -((h >> 2) as i64 & 0x7fff_ffff) - 1
}

/// The record a deck should have for what rekordbox shows, whether it was found, and
/// whether it has phrases.
fn record_for(index: Option<&wo_rekordbox::Index>, d: &wo_rkbx::DeckView) -> (Record, bool, bool) {
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
            tags: Tags { album: d.album.clone(), ..Default::default() },
        };
        return (r, false, false);
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
        tags: Tags { album: if e.tags.album.is_empty() { d.album.clone() } else { e.tags.album.clone() }, comment: e.tags.comment.clone(), ..Default::default() },
    };
    (r, true, e.phrases)
}

impl Follow {
    /// The library read (again) on a thread of its own.
    fn read_library(&mut self) {
        let Some(lib) = self.library_dir.clone() else { return };
        let music = self.music.clone();
        let (tx, rx) = mpsc::channel();
        let spawned = std::thread::Builder::new().name("rekordbox library".into()).spawn(move || {
            let ix = wo_rekordbox::Index::build(&wo_rekordbox::anlz_root(&lib), &music);
            eprintln!("follow: rekordbox library {} analyses, {} tracks, {} with phrases, {} not in {music:?}", ix.stats.analyses, ix.stats.tracks, ix.stats.with_phrases, ix.stats.missing.len());
            let _ = tx.send(ix);
        });
        if spawned.is_ok() {
            self.index_rx = Some(rx);
            self.read_at = Some(Instant::now());
        }
    }

    /// rkbx_link: heard already, else found and started (looked for again now and then).
    fn mind_rkbx(&mut self) {
        if let Some(r) = &self.runner {
            self.rkbx = Rkbx::Ours(r.view());
            return;
        }
        if !self.run_rkbx {
            self.rkbx = Rkbx::Outside;
            return;
        }
        if self.listener.packets() > 0 && self.rkbx == Rkbx::Waiting {
            self.rkbx = Rkbx::Outside;
        }
        if self.rkbx == Rkbx::Outside || self.started.elapsed() < HEAR_FIRST || self.looked.is_some_and(|t| t.elapsed() < LOOK_AGAIN) {
            return;
        }
        self.looked = Some(Instant::now());
        match runner::find(self.rkbx_hint.as_deref()) {
            Some(exe) => {
                if let Err(e) = runner::configure(&exe, self.port, self.rekordbox.as_deref()) {
                    eprintln!("follow: setting up {}: {e}", exe.display());
                }
                eprintln!("follow: starting {}", exe.display());
                let r = Runner::start(exe);
                self.rkbx = Rkbx::Ours(r.view());
                self.runner = Some(r);
            }
            None => self.rkbx = Rkbx::NotFound,
        }
    }
}

impl Desk {
    /// A Desk that follows rekordbox: rkbx_link heard on `o.addr` (and run, where none is
    /// sending), rekordbox's library read in the background. The Auto DJ is off and the
    /// Desk sounds nothing.
    pub fn open_following(o: FollowOptions) -> Result<Desk, String> {
        // a Desk restarting to follow: the one before may hold the port a moment longer
        let t0 = Instant::now();
        let listener = loop {
            match wo_rkbx::Listener::start(&o.addr, None) {
                Ok(l) => break l,
                Err(_) if t0.elapsed() < Duration::from_secs(3) => std::thread::sleep(Duration::from_millis(100)),
                Err(e) => return Err(format!("listening for rkbx_link on {}: {e} (another program has that port?)", o.addr)),
            }
        };
        let port = o.addr.rsplit(':').next().and_then(|p| p.parse().ok()).unwrap_or(4460);
        let mut desk = Desk::open_as(false, true);
        desk.auto = false;
        let library_dir = o.library.clone().or_else(wo_rekordbox::library_dir);
        let trouble = library_dir.is_none().then(|| "rekordbox's library is not on this computer: is rekordbox installed and opened once?".to_owned());
        for d in 0..2 {
            desk.set_fader(d, 1.0);
        }
        let mut f = Follow {
            listener,
            port,
            rkbx: Rkbx::Waiting,
            runner: None,
            run_rkbx: o.run_rkbx,
            rkbx_hint: o.rkbx_link.clone(),
            started: Instant::now(),
            looked: None,
            library_dir,
            music: o.music.clone(),
            index: None,
            index_rx: None,
            read_at: None,
            seen: [0; 2],
            jumps: [0; 2],
            found: [None; 2],
            phrases: [false; 2],
            snapped: [None; 2],
            settle: [0; 2],
            rate: [1.0; 2],
            last: Instant::now(),
            rekordbox: wo_rekordbox::installed(),
            view: FollowView { trouble, ..Default::default() },
        };
        f.read_library();
        desk.follow = Some(f);
        Ok(desk)
    }

    /// Following stopped (rkbx_link with it, its port let go): for closing the Desk.
    pub fn stop_following(&mut self) {
        self.follow = None;
    }

    /// How following goes (None: not following).
    pub fn following(&self) -> Option<FollowView> {
        self.follow.as_ref().map(|f| f.view.clone())
    }

    /// Where the audio is looked for, from now on (the library is read again).
    pub fn set_follow_music(&mut self, music: Vec<PathBuf>) {
        if let Some(f) = self.follow.as_mut() {
            f.music = music;
            f.read_library();
            self.changes += 1;
        }
    }

    /// rekordbox's library read again now (records analysed since).
    pub fn follow_read_again(&mut self) {
        if let Some(f) = self.follow.as_mut() {
            f.read_library();
            self.changes += 1;
        }
    }

    /// rkbx_link chosen by hand (the program or its folder): used from now on.
    pub fn set_follow_rkbx_link(&mut self, at: PathBuf) {
        if let Some(f) = self.follow.as_mut() {
            f.rkbx_hint = Some(at);
            f.runner = None;
            f.rkbx = Rkbx::Waiting;
            f.looked = None;
            f.started = Instant::now() - HEAR_FIRST;
            self.changes += 1;
        }
    }

    /// Each tick: rekordbox's decks onto the Desk's.
    pub(crate) fn follow_tick(&mut self) {
        let Some(f) = self.follow.as_mut() else { return };
        let dt = f.last.elapsed().as_secs_f64().min(0.25);
        f.last = Instant::now();
        f.mind_rkbx();
        if let Some(rx) = &f.index_rx
            && let Ok(ix) = rx.try_recv()
        {
            f.index = Some(Arc::new(ix));
            f.index_rx = None;
            // a deck whose record was not found: tried again with what was read
            for d in 0..2 {
                if f.found[d] == Some(false) {
                    f.seen[d] = 0;
                }
            }
            self.changes += 1;
        }
        let f = self.follow.as_mut().unwrap();
        let v = f.listener.view();
        let index = f.index.clone();
        let reading = f.index_rx.is_some();
        let mut loads = vec![];
        for d in 0..2 {
            let dv = &v.decks[d];
            // a new record on rekordbox's deck: the same on ours, once the library is read
            if dv.loaded && dv.loads != f.seen[d] && !reading {
                f.seen[d] = dv.loads;
                f.jumps[d] = dv.jumps;
                f.snapped[d] = None;
                f.settle[d] = SETTLE_TICKS;
                let (record, found, phrases) = record_for(index.as_deref(), dv);
                f.found[d] = Some(found);
                f.phrases[d] = phrases;
                if !found {
                    eprintln!("follow: deck {d}: {:?} not found in rekordbox's library and the music folders", dv.title);
                }
                loads.push((d, record));
            }
        }
        // not found: perhaps analysed since the library was read
        if f.found.contains(&Some(false)) && !reading && f.read_at.is_none_or(|t| t.elapsed() >= READ_AGAIN) {
            f.read_library();
        }
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
            deck_views[d].phrases = f.phrases[d];
            deck_views[d].playing = dv.playing;
        }
        f.view.live = v.live;
        f.view.packets = f.listener.packets();
        f.view.lead = v.lead;
        f.view.decks = deck_views;
        f.view.rkbx = f.rkbx.clone();
        f.view.rekordbox = f.rekordbox.clone();
        f.view.reading = reading;
        f.view.music = f.music.clone();
        f.view.library = f.index.as_ref().map(|ix| LibraryView { tracks: ix.stats.tracks, with_phrases: ix.stats.with_phrases, missing: ix.stats.missing.clone() });
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
        let (r, found, phrases) = record_for(None, &d);
        assert!(!found && !phrases);
        assert_eq!((r.title.as_str(), r.artist.as_str(), r.bpm), ("Nowhere To Be Found", "Nobody", 128.0));
        assert!(!r.playable());
    }
}
