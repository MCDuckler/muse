//! Records from elsewhere (the WetOwl app's search, in the crate): a search asks the house
//! for everything — its own records, songs on YouTube Music, YouTube, SoundCloud,
//! Bandcamp, Spotify (where linked), and public lists (SoundCloud sets, YouTube Music
//! playlists, Bandcamp records). A song from elsewhere is got: the house takes it
//! (`/search/add`) and it is fetched — a YouTube one here, on this computer's connection,
//! where yt-dlp and friends are installed (fetch.rs), else by the house's pool, pushed to
//! its front; SoundCloud and Bandcamp by the house itself. Its state is asked every couple
//! of seconds until it is ready; a deck that asked for it gets it then. A list is opened
//! to its songs, or taken whole as a playlist (mirrored by the house).
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use wo_house::{Found, FoundList, House, Track};

use crate::fetch::{self, HereMap, Tools};
use crate::library::{Done, Shelf};
use crate::records::Record;
use crate::Desk;

/// At most this many songs fetched here at once (the app's own default is three; the
/// Desk is also playing).
const HERE_AT_ONCE: usize = 2;

/// One song asked for.
#[derive(Clone, Debug)]
struct Getting {
    found: Found,
    track: Option<Track>,
    error: Option<String>,
}

/// A song from elsewhere as the crate shows it.
#[derive(Clone, Debug, PartialEq)]
pub struct GettingView {
    /// In words: "asking", "queued", "downloading 42 %", "here"…
    pub words: String,
    pub percent: Option<f32>,
    pub ready: bool,
    /// Fetched on this computer.
    pub here: bool,
    pub error: Option<String>,
    /// The house's record, once it is ready.
    pub record: Option<Record>,
}

pub(crate) struct State {
    getting: HashMap<String, Getting>,
    by_track: HashMap<i64, String>,
    polled: Option<Instant>,
    polling: bool,
    tools: Option<Result<Tools, Vec<&'static str>>>,
    here: HereMap,
    here_busy: Arc<AtomicUsize>,
    /// A deck waiting for a record (by the house's id) to be ready; by the row's key
    /// until the house has answered with its id.
    deck_wants: HashMap<i64, usize>,
    pending_deck: HashMap<String, usize>,
    /// What to tell the person (the window shows it, once).
    said: Vec<String>,
    /// The playlists asked again a little after a list was taken (its mirror is the
    /// house's work, done a moment later).
    lists_again: Option<Instant>,
}

impl Default for State {
    fn default() -> Self {
        State {
            getting: HashMap::new(),
            by_track: HashMap::new(),
            polled: None,
            polling: false,
            tools: None,
            here: Default::default(),
            here_busy: Arc::new(AtomicUsize::new(0)),
            deck_wants: HashMap::new(),
            pending_deck: HashMap::new(),
            said: vec![],
            lists_again: None,
        }
    }
}

/// Asks the house for everything matching `q` (its own records come as the shelf).
pub(crate) fn search(tx: &std::sync::mpsc::Sender<Done>, house: &House, q: String, turn: u64) {
    let (tx, house) = (tx.clone(), house.clone());
    thread::spawn(move || {
        // everything, and the lists on their own (the mixed answer has only a few of
        // each service's), at once; merged, the first answer's order first
        let h2 = house.clone();
        let q2 = q.clone();
        let lists = thread::spawn(move || h2.everything(&q2, "playlist", "all"));
        let got = house.everything(&q, "all", "all").map(|(mut items, mut notes)| {
            if let Ok(Ok((more, more_notes))) = lists.join() {
                for f in more {
                    if !items.iter().any(|x| x.key() == f.key()) {
                        items.push(f);
                    }
                }
                for n in more_notes {
                    if !notes.iter().any(|x| x.0 == n.0) {
                        notes.push(n);
                    }
                }
            }
            (items, notes)
        });
        let _ = tx.send(Done::Found { turn, got: got.map_err(|e| e.to_string()) });
    });
}

/// What is on a list found elsewhere.
pub(crate) fn open_list(tx: &std::sync::mpsc::Sender<Done>, house: &House, f: Found, turn: u64) {
    let (tx, house) = (tx.clone(), house.clone());
    thread::spawn(move || {
        let got = house.found_list(&f).map_err(|e| e.to_string());
        let _ = tx.send(Done::FoundList { turn, got });
    });
}

fn words_for(t: &Track) -> (String, Option<f32>) {
    let p = t.progress.as_ref();
    let pct = p.and_then(|p| p.percent).map(|x| (x / 100.0).clamp(0.0, 1.0) as f32);
    let stage = p.and_then(|p| p.stage.clone());
    match (t.state.as_str(), stage) {
        ("ready", _) => ("here".into(), Some(1.0)),
        ("failed", _) => (t.fail_reason.clone().unwrap_or_else(|| "failed".into()), None),
        (_, Some(s)) => (match pct {
            Some(x) => format!("{s} {:.0} %", x * 100.0),
            None => s,
        }, pct),
        _ => ("queued".into(), None),
    }
}

impl Desk {
    /// The tools for fetching here (looked for once).
    pub fn fetch_tools(&mut self) -> Result<(), String> {
        let t = self.elsewhere.tools.get_or_insert_with(fetch::find_tools);
        match t {
            Ok(_) => Ok(()),
            Err(missing) => Err(format!("Missing: {}. {}", missing.join(", "), fetch::how_to_install(missing))),
        }
    }

    /// A song from elsewhere, got: taken by the house, and fetched (here where it can be).
    pub fn get_found(&mut self, f: &Found) {
        let Some(house) = self.house.clone() else { return };
        if !f.plays() || f.unavailable.is_some() {
            return;
        }
        let key = f.key();
        if self.elsewhere.getting.get(&key).is_some_and(|g| g.error.is_none()) {
            return;
        }
        self.elsewhere.getting.insert(key.clone(), Getting { found: f.clone(), track: None, error: None });
        let (tx, f) = (self.done_tx.clone(), f.clone());
        thread::spawn(move || {
            let got = house.add_found(&f).map_err(|e| e.to_string());
            let _ = tx.send(Done::Got { key, got });
        });
        self.changes += 1;
    }

    /// Every song on the shelf from elsewhere that is not here yet.
    pub fn get_all_found(&mut self) {
        let all: Vec<Found> = self.library.found.iter().filter(|f| f.plays() && f.unavailable.is_none() && !f.track.as_ref().is_some_and(|t| t.ready())).cloned().collect();
        for f in &all {
            self.get_found(f);
        }
        if !all.is_empty() {
            self.elsewhere.said.push(format!("Getting {} songs", all.len()));
        }
    }

    /// A list found elsewhere, mirrored by the house as a playlist of this person's.
    pub fn take_found_list(&mut self, f: &Found) {
        let Some(house) = self.house.clone() else { return };
        let (tx, f) = (self.done_tx.clone(), f.clone());
        thread::spawn(move || {
            let got = house.take_list(&f).map_err(|e| e.to_string());
            let _ = tx.send(Done::Took { title: f.title.clone(), got });
        });
    }

    /// A list found elsewhere opened: its songs on the shelf.
    pub fn open_found(&mut self, f: &Found) {
        if f.place == "library" && f.kind == "playlist" {
            if let Ok(id) = f.id.parse() {
                self.open_shelf(Shelf::Playlist { id, name: f.title.clone() });
            }
            return;
        }
        self.open_shelf(Shelf::Elsewhere(f.clone()));
    }

    /// A song from elsewhere onto deck `d`: now where it is here, else once it is.
    pub fn load_found(&mut self, d: usize, f: &Found) {
        if let Some(t) = f.track.as_ref().filter(|t| t.ready()) {
            self.load_by_hand(d, Record::from_house(t));
            return;
        }
        if let Some(v) = self.getting(f)
            && let Some(r) = v.record
        {
            self.load_by_hand(d, r);
            return;
        }
        self.get_found(f);
        let key = f.key();
        if let Some(id) = self.elsewhere.getting.get(&key).and_then(|g| g.track.as_ref().map(|t| t.id)) {
            self.elsewhere.deck_wants.insert(id, d);
        } else {
            // its id comes with the house's answer: kept by the row until then
            self.elsewhere.pending_deck.insert(key, d);
        }
        self.elsewhere.said.push(format!("{} goes on deck {} once it is here", f.title, ["A", "B"][d]));
    }

    /// How a song from elsewhere is coming along (None: not asked for).
    pub fn getting(&self, f: &Found) -> Option<GettingView> {
        let g = self.elsewhere.getting.get(&f.key());
        let track = g.and_then(|g| g.track.as_ref()).or(f.track.as_ref());
        if g.is_none() && !track.is_some_and(|t| t.ready()) {
            return None;
        }
        if let Some(e) = g.and_then(|g| g.error.clone()) {
            return Some(GettingView { words: "could not be got".into(), percent: None, ready: false, here: false, error: Some(e), record: None });
        }
        let Some(t) = track else {
            return Some(GettingView { words: "asking the house".into(), percent: None, ready: false, here: false, error: None, record: None });
        };
        if t.ready() {
            return Some(GettingView { words: "here".into(), percent: Some(1.0), ready: true, here: false, error: None, record: Some(Record::from_house(t)) });
        }
        // fetched on this computer: its own progress, finer than the house's
        if let Some(h) = self.elsewhere.here.lock().ok().and_then(|m| m.get(&t.id).cloned()) {
            let pct = h.percent.map(|p| p as f32);
            let words = match (&h.error, h.stage.as_str(), pct) {
                (Some(e), _, _) => e.clone(),
                (_, "done", _) => "handed in · the house is taking it".into(),
                (_, s, Some(p)) => format!("{s} here {:.0} %", p * 100.0),
                (_, s, None) => format!("{s} here"),
            };
            return Some(GettingView { words, percent: pct, ready: false, here: true, error: h.error, record: None });
        }
        let (words, percent) = words_for(t);
        let failed = t.state == "failed";
        Some(GettingView { words, percent, ready: false, here: false, error: failed.then(|| t.fail_reason.clone().unwrap_or_default()), record: None })
    }

    /// What to tell the person since the last ask.
    pub fn take_elsewhere_said(&mut self) -> Vec<String> {
        std::mem::take(&mut self.elsewhere.said)
    }

    /// Each frame: the songs asked for, asked after every couple of seconds.
    pub(crate) fn elsewhere_tick(&mut self) {
        if self.elsewhere.lists_again.is_some_and(|t| t.elapsed() > Duration::from_secs(8)) {
            self.elsewhere.lists_again = None;
            if let Some(h) = &self.house {
                crate::library::fetch_playlists(&self.done_tx, h);
            }
        }
        if self.elsewhere.polling || self.elsewhere.polled.is_some_and(|t| t.elapsed() < Duration::from_secs(2)) {
            return;
        }
        let ids: Vec<i64> = self.elsewhere.getting.values().filter(|g| g.error.is_none()).filter_map(|g| g.track.as_ref()).filter(|t| !t.ready() && t.state != "failed").map(|t| t.id).collect();
        let Some(house) = self.house.clone().filter(|_| !ids.is_empty()) else { return };
        self.elsewhere.polling = true;
        self.elsewhere.polled = Some(Instant::now());
        let tx = self.done_tx.clone();
        thread::spawn(move || {
            let tracks: Vec<Track> = ids.iter().filter_map(|&id| house.track(id).ok()).collect();
            let _ = tx.send(Done::States(tracks));
        });
    }

    /// The house's answer to a song asked for.
    pub(crate) fn got(&mut self, key: String, got: Result<Track, String>) {
        let Some(g) = self.elsewhere.getting.get_mut(&key) else { return };
        match got {
            Err(e) => {
                self.elsewhere.said.push(format!("{}: {e}", g.found.title));
                g.error = Some(e);
            }
            Ok(t) => {
                let (id, ready, youtube) = (t.id, t.ready(), t.source.as_deref() == Some("youtube"));
                self.elsewhere.by_track.insert(id, key.clone());
                g.track = Some(t.clone());
                if let Some(d) = self.elsewhere.pending_deck.remove(&key) {
                    self.elsewhere.deck_wants.insert(id, d);
                }
                if ready {
                    self.arrived(&t);
                } else {
                    self.fetch(id, youtube);
                }
            }
        }
        self.changes += 1;
    }

    /// A song the house does not have yet: fetched here (YouTube, tools installed, a slot
    /// free), else pushed to the front of the house's fetching.
    fn fetch(&mut self, id: i64, youtube: bool) {
        let Some(house) = self.house.clone() else { return };
        let tools = if youtube { self.elsewhere.tools.get_or_insert_with(fetch::find_tools).clone().ok() } else { None };
        let busy = self.elsewhere.here_busy.clone();
        let here = self.elsewhere.here.clone();
        let tools = tools.filter(|_| busy.load(Ordering::Acquire) < HERE_AT_ONCE);
        thread::spawn(move || {
            if let Some(tools) = tools {
                busy.fetch_add(1, Ordering::AcqRel);
                let r = fetch::fetch_now(&house, &tools, id, &here);
                busy.fetch_sub(1, Ordering::AcqRel);
                match r {
                    Ok(true) => return,
                    // another computer has it, or this one could not: the pool's, first in line
                    Ok(false) | Err(_) => {}
                }
            }
            if let Err(e) = house.promote(&[id]) {
                eprintln!("desk: promoting {id}: {e}");
            }
        });
    }

    /// The songs asked for, as the house has them now.
    pub(crate) fn states(&mut self, tracks: Vec<Track>) {
        self.elsewhere.polling = false;
        for t in tracks {
            let Some(key) = self.elsewhere.by_track.get(&t.id).cloned() else { continue };
            let was_ready = self.elsewhere.getting.get(&key).and_then(|g| g.track.as_ref()).is_some_and(|x| x.ready());
            if let Some(g) = self.elsewhere.getting.get_mut(&key) {
                g.track = Some(t.clone());
            }
            if t.ready() && !was_ready {
                self.arrived(&t);
            }
            if t.state == "failed" {
                self.elsewhere.deck_wants.remove(&t.id);
            }
        }
        self.changes += 1;
    }

    /// A song asked for is here: on the deck that wanted it (when that deck is free), and
    /// among the shelf's records where the shelf is a search.
    fn arrived(&mut self, t: &Track) {
        let r = Record::from_house(t);
        self.elsewhere.said.push(format!("{} is here", t.title));
        if matches!(self.library.shelf, Shelf::Search(_) | Shelf::Elsewhere(_)) && !self.library.rows.iter().any(|x| x.id == r.id) {
            self.library.rows.insert(0, r.clone());
            self.library.total += 1;
        }
        if let Some(d) = self.elsewhere.deck_wants.remove(&t.id) {
            if self.engine.deck(wo_engine::DeckId::new(d).unwrap()).read().playing {
                self.elsewhere.said.push(format!("Deck {} is playing: {} waits in the crate", ["A", "B"][d], t.title));
            } else {
                self.load_by_hand(d, r);
            }
        }
    }

    /// A list taken whole.
    pub(crate) fn took(&mut self, title: String, got: Result<String, String>) {
        match got {
            Ok(name) => {
                self.elsewhere.said.push(format!("{name}: the house is making it a playlist of yours"));
                self.elsewhere.lists_again = Some(Instant::now());
            }
            Err(e) => self.elsewhere.said.push(format!("{title}: {e}")),
        }
    }

    /// The shelf's songs and lists from elsewhere.
    pub(crate) fn found_answer(&mut self, turn: u64, got: Result<(Vec<Found>, Vec<(String, String)>), String>) {
        if turn != self.shelf_gen {
            return;
        }
        self.library.found_loading = false;
        match got {
            Ok((items, notes)) => {
                self.library.found = items;
                self.library.found_notes = notes;
            }
            Err(e) => self.library.found_notes = vec![("house".into(), e)],
        }
    }

    pub(crate) fn found_list_answer(&mut self, turn: u64, got: Result<FoundList, String>) {
        if turn != self.shelf_gen {
            return;
        }
        self.library.found_loading = false;
        self.library.loading = false;
        match got {
            Ok(list) => {
                // its songs already here are records on the shelf too
                self.library.rows = list.tracks.iter().filter_map(|f| f.track.as_ref().filter(|t| t.ready())).map(Record::from_house).collect();
                self.library.total = list.tracks.len() as i64;
                self.library.found = list.tracks;
                self.library.found_notes = vec![];
                self.library.error = None;
            }
            Err(e) => {
                self.library.found = vec![];
                self.library.error = Some(e);
            }
        }
    }
}
