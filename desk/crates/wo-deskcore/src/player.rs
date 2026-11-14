//! PLAY IN ORDER: a playlist (or any shelf) played as a plain player would — each record
//! whole, one after the other in the list's order, a short crossfade at the end of each
//! and nothing else (no planner, no beatmatch, no bands, loops or the booth's sounds).
//! The decks, the waveforms and the show go on as ever: it is the Auto DJ with its
//! hands off.
use wo_booth::Transition;
use wo_engine::DeckId;

use crate::autodj::LogKind;
use crate::library::Shelf;
use crate::records::Record;
use crate::Desk;

/// The crossfade between two records, seconds.
pub const FADE: f64 = 3.0;
/// Into a record that stops dead (a cold end): next to nothing.
const COLD: f64 = 0.4;
/// Back within the first seconds of a record goes to the one before; later, to its start.
const BACK_RESTARTS: f64 = 4.0;

/// The list being played.
#[derive(Clone, Debug)]
pub(crate) struct Player {
    pub name: String,
    pub list: Vec<Record>,
    /// The record on the master's place in the list.
    pub at: usize,
}

/// The list playing, for the window.
#[derive(Clone, Debug, PartialEq)]
pub struct PlayerView {
    pub name: String,
    /// The one playing, 0-based, and how many.
    pub at: usize,
    pub len: usize,
    /// The record after this one (none: this is the last).
    pub next: Option<Record>,
}

impl Player {
    /// The first playable record after `i`.
    fn after(&self, i: usize) -> Option<usize> {
        (i + 1..self.list.len()).find(|&j| self.list[j].playable())
    }

    fn before(&self, i: usize) -> Option<usize> {
        (0..i).rev().find(|&j| self.list[j].playable())
    }
}

impl Desk {
    /// The shelf open played in order from the record `from` (none: its first), on now.
    pub fn play_shelf(&mut self, from: Option<i64>) {
        let name = match &self.library.shelf {
            Shelf::Playlist { name, .. } | Shelf::Usb { playlist: Some((_, name)), .. } => name.clone(),
            Shelf::Usb { stick, .. } => stick.clone(),
            Shelf::Search(q) => format!("“{q}”"),
            Shelf::All => "the library".to_owned(),
            _ => "the shelf".to_owned(),
        };
        let list: Vec<Record> = self.shelf_rows().to_vec();
        let start = from.and_then(|id| list.iter().position(|r| r.id == id)).unwrap_or(0);
        self.play_list(name, list, start);
    }

    /// `list` played in order from `start`: its record on the master deck from its start,
    /// the next waiting on the other, the Auto DJ on and plain.
    pub fn play_list(&mut self, name: String, list: Vec<Record>, start: usize) {
        let mut p = Player { name, list, at: start };
        let Some(first) = (start..p.list.len()).find(|&j| p.list[j].playable()) else { return };
        p.at = first;
        let n = p.list.len();
        self.note(LogKind::Plan, format!("Playing {} in order, from {} ({}/{n})", p.name, p.list[first].title, first + 1));
        self.player = Some(p);
        self.set.playing = false;
        self.auto = true;
        self.play_at(first);
    }

    /// Back to the Auto DJ choosing (and mixing) for itself.
    pub fn stop_list(&mut self) {
        if let Some(p) = self.player.take() {
            self.note(LogKind::Plan, format!("{} let go of: the Auto DJ mixes again", p.name));
            // the record waiting was the list's; a choice of its own goes there
            let to = 1 - self.master;
            if self.mix.as_ref().is_none_or(|m| !m.started) && !self.engine.deck(DeckId::new(to).unwrap()).read().playing {
                self.mix = None;
                let next = self.take_next();
                self.load(to, next);
            }
        }
    }

    /// The next record now: a quick crossfade into it where it is ready, else straight.
    pub fn list_next(&mut self) {
        let Some(p) = self.player.as_ref() else { return };
        let Some(i) = p.after(p.at) else { return };
        if let Some(m) = self.mix.as_ref().filter(|m| !m.started) {
            let heard = self.engine.deck(DeckId::new(m.from).unwrap()).position();
            if let Some(m) = self.mix.as_mut() {
                m.out = heard + 2.0 * crate::LEAD;
            }
            return;
        }
        if self.mix.is_none() {
            self.play_at(i);
        }
    }

    /// Back: to the start of the record playing, or (within its first seconds) the one before.
    pub fn list_back(&mut self) {
        let Some(p) = self.player.as_ref() else { return };
        let heard = self.engine.deck(DeckId::new(self.master).unwrap()).position();
        let to = if heard > BACK_RESTARTS { Some(p.at) } else { p.before(p.at) };
        if let Some(i) = to {
            self.play_at(i);
        }
    }

    /// The list's record `i` played now from its start on the master deck, the one after
    /// it waiting on the other; whatever was mixing stopped.
    pub fn play_at(&mut self, i: usize) {
        let Some(p) = self.player.as_mut() else { return };
        let Some(rec) = p.list.get(i).cloned() else { return };
        p.at = i;
        let next = p.after(i).map(|j| p.list[j].clone());
        self.mix = None;
        self.full_law = false;
        let (m, o) = (self.master, 1 - self.master);
        self.engine.deck(DeckId::new(o).unwrap()).play(false);
        self.plain(m);
        self.plain(o);
        self.set_crossfader(if m == 0 { 0.0 } else { 1.0 });
        self.load(m, rec);
        self.engine.deck(DeckId::new(m).unwrap()).play(true);
        if let Some(next) = next {
            self.load(o, next);
        }
        self.apply_levels();
        self.changes += 1;
    }

    /// The list's next record, for the deck just freed (none: the list is done).
    pub(crate) fn list_next_record(&mut self) -> Option<Option<Record>> {
        let p = self.player.as_mut()?;
        let on = self.slots[self.master].record.id;
        // where the record now playing is in the list (a hand may have put another on)
        if let Some(j) = p.list.iter().enumerate().skip(p.at).chain(p.list.iter().enumerate().take(p.at)).find(|(_, r)| r.id == on).map(|(j, _)| j) {
            p.at = j;
        }
        Some(p.after(p.at).map(|j| p.list[j].clone()))
    }

    /// The plain move planned: the master out at its sound's end less the crossfade, the
    /// incoming from its start, not in step. None where there is nothing to play into.
    pub(crate) fn plan_plain(&mut self) -> bool {
        let Some(p) = self.player.as_ref() else { return false };
        let (from, to) = (self.master, 1 - self.master);
        // the list's next (or one a hand put there), and enough of it in to start
        let want = p.after(p.at).map(|j| p.list[j].id);
        let rec = &self.slots[to].record;
        if !rec.playable() || (want != Some(rec.id) && !self.mind.by_hand[to]) {
            return true;
        }
        let decoded = self.slots[to].wave.lock().unwrap().seconds();
        if decoded < (rec.seconds as f64 - 1.0).clamp(1.0, 8.0) {
            return true;
        }
        let fd = self.engine.deck(DeckId::new(from).unwrap());
        if !fd.read().playing {
            return true;
        }
        let heard = fd.position();
        let (out, length) = self.plain_out(from);
        let bar = self.slots[from].timing.bar().unwrap_or(2.0).max(0.1);
        let bars = ((length / bar).round() as u32).max(1);
        let kind = if length <= COLD { Transition::Cut } else { Transition::Fade };
        let td = self.engine.deck(DeckId::new(to).unwrap());
        td.play(false);
        td.unsync();
        td.seek(0.0);
        let run = crate::transition::Running::new(kind, bars);
        self.mix = Some(crate::Plan {
            from,
            to,
            kind,
            bars,
            out: out.max(heard),
            length,
            in_step: false,
            turn: self.load_gen[to],
            started: false,
            begun: None,
            progress: 0.0,
            run,
            options: vec![],
            why: "in order".into(),
            park: 0.0,
        });
        true
    }

    /// Where the master goes out in order (its sound's end less the crossfade), and the
    /// crossfade's length: the analysis may come after the plan, so asked again each tick.
    pub(crate) fn plain_out(&self, from: usize) -> (f64, f64) {
        let t = &self.slots[from].timing;
        let end = t.sound_end.filter(|&e| e > 1.0).unwrap_or(t.duration.max(self.slots[from].record.seconds as f64));
        let length = if t.ends == "cold" { COLD } else { FADE.min(end / 4.0) };
        ((end - length).max(0.0), length)
    }

    /// The list playing, for the window.
    pub fn player(&self) -> Option<PlayerView> {
        let p = self.player.as_ref()?;
        Some(PlayerView { name: p.name.clone(), at: p.at, len: p.list.len(), next: p.after(p.at).map(|j| p.list[j].clone()) })
    }

    /// The list's records still to come, in order (Up next while one plays).
    pub(crate) fn list_up_next(&self) -> Option<Vec<Record>> {
        let p = self.player.as_ref()?;
        Some(p.list.iter().skip(p.at + 1).filter(|r| r.playable()).take(8).cloned().collect())
    }
}
