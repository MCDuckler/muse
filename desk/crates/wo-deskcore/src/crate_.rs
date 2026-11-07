//! The crate's own shelves and hands (v1's console_crate.dart): the records a hand
//! queued for the Auto DJ, the house's best fits for the record playing, the whole
//! library page by page, and the pads a hand set kept on the record at the house.
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
