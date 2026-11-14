//! The crate's own shelves and hands (v1's console_crate.dart, console_check.dart): the
//! records a hand queued for the Auto DJ, the house's best fits for the record playing,
//! the records like what is on (some this person's, some new to them), the whole library
//! page by page, a playlist mixed or queued whole, the records to check by ear, and the
//! pads a hand set kept on the record at the house.
use std::thread;

use crate::autodj::LogKind;
use crate::library::{self, Shelf};
use crate::records::{Audio, Record};
use crate::Desk;

impl Desk {
    /// The records a hand queued, in order.
    pub fn queue(&self) -> Vec<Record> {
        self.hand_queue.clone()
    }

    /// A record queued: the Auto DJ plays the queue before choosing for itself.
    pub fn queue_add(&mut self, r: Record) {
        if self.hand_queue.iter().any(|x| x.id == r.id) {
            return;
        }
        self.note(LogKind::Hand, format!("Queued: {}", r.title));
        self.hand_queue.push(r);
        self.queue_shown();
    }

    pub fn queue_remove(&mut self, id: i64) {
        self.hand_queue.retain(|x| x.id != id);
        self.queue_shown();
    }

    /// The queue shelf, where it is open, shows the queue as it is now.
    fn queue_shown(&mut self) {
        if self.library.shelf == Shelf::Queue {
            self.library.rows = self.hand_queue.clone();
            self.library.total = self.hand_queue.len() as i64;
        }
        self.changes += 1;
    }

    /// The next queued record not on a deck, taken off the queue.
    pub(crate) fn queued_next(&mut self) -> Option<Record> {
        let on: Vec<i64> = self.slots.iter().map(|s| s.record.id).collect();
        let i = self.hand_queue.iter().position(|r| !on.contains(&r.id) && r.playable())?;
        let r = self.hand_queue.remove(i);
        self.queue_shown();
        self.note(LogKind::Next, format!("Next from the queue: {}", r.title));
        Some(r)
    }

    /// The shelf of the house's best fits for the record playing.
    pub fn open_fits(&mut self) {
        let r = &self.slots[self.master].record;
        if r.id > 0 {
            let s = Shelf::Fits { from: r.id, title: r.title.clone() };
            self.open_shelf(s);
        }
    }

    /// The next page of the whole library, where there is one and none is coming.
    pub fn more_rows(&mut self) {
        if self.library.shelf != Shelf::All || self.library.loading || self.more_asked == Some(self.library.rows.len()) {
            return;
        }
        if self.library.rows.len() as i64 >= self.library.total {
            return;
        }
        let Some(house) = &self.house else { return };
        self.more_asked = Some(self.library.rows.len());
        library::fetch_more(&self.done_tx, house, self.library.rows.len() as i64, self.shelf_gen);
    }

    /// A record added to one of this person's playlists (a hand's), the playlists read
    /// again after.
    pub fn add_to_playlist(&mut self, playlist: i64, r: &Record) {
        let Some(house) = self.house.clone() else { return };
        let (id, title) = (r.id, r.title.clone());
        let name = self.library.playlists.iter().find(|p| p.id == playlist).map(|p| p.name.clone()).unwrap_or_default();
        self.note(LogKind::Hand, format!("{title} added to {name}"));
        let tx = self.done_tx.clone();
        thread::spawn(move || {
            if let Err(e) = house.add_to_playlist(playlist, &[id]) {
                eprintln!("add {id} to {playlist}: {e}");
            }
            library::fetch_playlists(&tx, &house);
        });
    }

    /// The shelf of records like what is on — the decks' and the next few queued — `fresh`
    /// in hundredths: 0 this person's own, 50 a mix, 100 new to them.
    pub fn open_similar(&mut self, fresh: u8) {
        let mut seeds: Vec<i64> = vec![];
        for d in [self.master, 1 - self.master] {
            let id = self.slots[d].record.id;
            if id > 0 && !seeds.contains(&id) {
                seeds.push(id);
            }
        }
        for r in &self.hand_queue {
            if seeds.len() >= 4 {
                break;
            }
            if r.id > 0 && !seeds.contains(&r.id) {
                seeds.push(r.id);
            }
        }
        let exclude = self.hand_queue.iter().map(|r| r.id).collect();
        if seeds.is_empty() {
            self.library.shelf = Shelf::Similar { fresh, seeds, exclude };
            self.library.rows.clear();
            self.library.total = 0;
            self.library.loading = false;
            return;
        }
        self.open_shelf(Shelf::Similar { fresh, seeds, exclude });
    }

    /// One of the similar waved away: never offered again.
    pub fn dismiss(&mut self, id: i64) {
        self.library.rows.retain(|r| r.id != id);
        self.library.total = self.library.rows.len() as i64;
        let Some(house) = self.house.clone() else { return };
        thread::spawn(move || {
            if let Err(e) = house.dismiss_pick(id) {
                eprintln!("dismiss {id}: {e}");
            }
        });
    }

    /// The records to check by ear.
    pub fn open_check(&mut self) {
        self.open_shelf(Shelf::Check);
    }

    /// The record on deck `d` checked: what its grid is like (one of GRID_VERDICTS), and
    /// where its pads were left — each the booth's own place or a hand's — kept at the house
    /// as the ground truth its grids and pads are measured against.
    pub fn check(&mut self, d: usize, grid: &str) {
        let (Some(house), Audio::House { id }) = (self.house.clone(), &self.slots[d].record.audio) else { return };
        let id = *id;
        let pads: Vec<(usize, i64, bool)> = self.slots[d].hands.pads.iter().enumerate().filter_map(|(n, p)| p.map(|p| (n + 1, (p.at * 1000.0).round() as i64, p.auto.is_some()))).collect();
        self.library.checked.insert(id, Some(grid.to_owned()));
        self.library.notes.insert(id, format!("checked · {}", library::verdict_word(Some(grid))));
        self.note(LogKind::Hand, format!("Checked: {} — {}", self.slots[d].record.title, library::verdict_word(Some(grid))));
        let grid = grid.to_owned();
        thread::spawn(move || {
            if let Err(e) = house.check_cues(id, &grid, &pads) {
                eprintln!("check {id}: {e}");
            }
        });
        self.changes += 1;
    }

    /// A check taken back: the record to be checked again.
    pub fn uncheck(&mut self, id: i64) {
        self.library.checked.remove(&id);
        self.library.notes.remove(&id);
        let Some(house) = self.house.clone() else { return };
        thread::spawn(move || {
            if let Err(e) = house.uncheck_cues(id) {
                eprintln!("uncheck {id}: {e}");
            }
        });
        self.changes += 1;
    }

    /// The records the crate shows: the house's shelf, or the records on this computer.
    pub(crate) fn shelf_rows(&self) -> &[Record] {
        if self.house.is_some() || matches!(self.library.shelf, Shelf::Usb { .. }) { &self.library.rows } else { &self.rows }
    }

    /// The playlist open, mixed by the Auto DJ from now in its order (the records on the
    /// decks left out); the queue there was kept after it. The Auto DJ on.
    pub fn mix_shelf(&mut self) {
        let on: Vec<i64> = self.slots.iter().map(|s| s.record.id).collect();
        let mut q: Vec<Record> = self.shelf_rows().iter().filter(|r| r.playable() && !on.contains(&r.id)).cloned().collect();
        let n = q.len();
        for r in std::mem::take(&mut self.hand_queue) {
            if !q.iter().any(|x| x.id == r.id) {
                q.push(r);
            }
        }
        self.hand_queue = q;
        // mixed now, not played plainly in order
        self.player = None;
        let name = match &self.library.shelf {
            Shelf::Playlist { name, .. } | Shelf::Usb { playlist: Some((_, name)), .. } => name.clone(),
            Shelf::Usb { stick, .. } => stick.clone(),
            _ => "the shelf".to_owned(),
        };
        self.note(LogKind::Hand, format!("Mixing {name}: {n} records queued"));
        self.set_auto(true);
        self.queue_shown();
    }

    /// The shelf's records (playable, not queued already) put at the end of the queue.
    pub fn queue_shelf(&mut self) -> usize {
        let rows: Vec<Record> = self.shelf_rows().iter().filter(|r| r.playable() && !self.hand_queue.iter().any(|q| q.id == r.id)).cloned().collect();
        let n = rows.len();
        self.hand_queue.extend(rows);
        self.queue_shown();
        n
    }

    /// A pad set or cleared by a hand kept on the record at the house (`at` none:
    /// cleared), as v1 keeps it.
    pub(crate) fn keep_pad(&self, d: usize, n: usize, at: Option<f64>) {
        let (Some(house), Audio::House { id }) = (self.house.clone(), &self.slots[d].record.audio) else { return };
        let id = *id;
        let mut pads = serde_json::Map::new();
        pads.insert((n + 1).to_string(), at.map_or(serde_json::Value::Null, |t| serde_json::json!((t * 1000.0).round() as i64)));
        let body = serde_json::json!({ "pads": pads });
        thread::spawn(move || {
            if let Err(e) = house.set_cues(id, &body) {
                eprintln!("pads of {id}: {e}");
            }
        });
    }
}
