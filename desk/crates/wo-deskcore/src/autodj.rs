//! The Auto DJ's mind, around the transitions (v1's automix.dart): what it plays next
//! and why — the house's set builder asked for the records that follow the one on best,
//! steered by the room (more energy, less, more like this, something different) — what
//! it has been doing (the log), what was thought of its last mix (the thumbs, kept by
//! the house so the planner leans this person's way), and the hands on it: undo, skip,
//! not now, sooner, longer.
use std::collections::VecDeque;
use std::thread;
use std::time::{Duration, Instant};

use wo_booth::Transition;
use wo_booth::taste::Taste;

use crate::library::{Done, Shelf};
use crate::records::Record;
use crate::{Desk, Style};

/// What the room asked of the Auto DJ's next records.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Steer {
    /// More energy (+) or less (−), −0.36..0.36 in the set builder's units.
    pub energy: f64,
    /// More like this record.
    pub like: Option<Record>,
    /// Something different from the one before.
    pub different: bool,
}

impl Steer {
    pub fn neutral(&self) -> bool {
        self.energy == 0.0 && self.like.is_none() && !self.different
    }
}

/// What the log says a line is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogKind {
    /// Planning, steering, taste.
    Plan,
    /// A transition starting.
    Mix,
    /// The next record chosen.
    Next,
    /// A transition done.
    Done,
    /// A hand on it.
    Hand,
    Trouble,
}

/// One line of the log.
#[derive(Clone, Debug, PartialEq)]
pub struct LogLine {
    /// Seconds into the set.
    pub at: f64,
    pub kind: LogKind,
    pub text: String,
}

/// The last transition made, for the thumbs (and the house's feedback).
#[derive(Clone, Debug, PartialEq)]
pub struct LastMix {
    pub from: Record,
    pub to: Record,
    pub kind: Transition,
    pub bars: u32,
    pub shift: f64,
    pub out: f64,
    pub inn: f64,
    pub why: String,
    pub steered: bool,
    /// The thumb given it: 1 good, -1 so-so.
    pub rating: Option<i8>,
}

/// Something the Auto DJ changed, to go back on.
#[derive(Clone, Debug)]
struct Undo {
    what: String,
    steer: Steer,
    /// The record that was coming, where the change replaced it.
    incoming: Option<Record>,
}

/// The house's choice for after the master, with its fit and words.
#[derive(Clone, Debug, PartialEq)]
pub struct Choice {
    pub record: Record,
    pub fit: f64,
    pub why: String,
}

#[derive(Default)]
pub(crate) struct Mind {
    pub steer: Steer,
    steer_gen: u64,
    pub log: VecDeque<LogLine>,
    pub last: Option<LastMix>,
    undo: Vec<Undo>,
    pub taste: Taste,
    taste_at: Option<Instant>,
    /// The house's picks for after the master, best first, and what they were asked for.
    pub choices: Vec<Choice>,
    asked_for: Option<(i64, u64, u64)>,
    asking: Option<u64>,
    ask_turn: u64,
    /// Records played this set (never chosen again).
    pub played: Vec<i64>,
    /// The incoming deck's record was put there by a hand (the choices leave it be).
    pub by_hand: [bool; 2],
}

const LOG_MAX: usize = 200;

/// The set builder's shape for "keep going": a plateau, steered.
fn shape(steer: &Steer) -> serde_json::Value {
    let smooth = if steer.like.is_some() {
        0.85
    } else if steer.different {
        0.1
    } else {
        0.5
    };
    let mut s = serde_json::json!({
        "energy": [[0.0, 0.55], [0.15, 0.8], [1.0, 0.8]],
        "key": "loose",
        "variety": {"gap": 3, "smooth": smooth, "fresh": 0.5},
        "stems": false,
        "offset": steer.energy,
    });
    if let Some(r) = &steer.like {
        s["anchor"] = serde_json::json!(r.id);
    }
    s
}

impl Desk {
    /// A line in the log.
    pub(crate) fn note(&mut self, kind: LogKind, text: impl Into<String>) {
        let at = self.started.elapsed().as_secs_f64();
        let text = text.into();
        eprintln!("autodj: {text}");
        self.mind.log.push_front(LogLine { at, kind, text });
        self.mind.log.truncate(LOG_MAX);
        self.changes += 1;
    }

    /// What the Auto DJ has been doing, newest first.
    pub fn log(&self) -> Vec<LogLine> {
        self.mind.log.iter().cloned().collect()
    }

    /// Why the house chose a record for after the master, where it did.
    pub fn choice_why(&self, id: i64) -> Option<String> {
        self.mind.choices.iter().find(|c| c.record.id == id).map(|c| c.why.clone()).filter(|w| !w.is_empty())
    }

    pub fn steer(&self) -> Steer {
        self.mind.steer.clone()
    }

    /// The last transition and its thumb.
    pub fn last_mix(&self) -> Option<LastMix> {
        self.mind.last.clone()
    }

    /// Whether there is something to undo, and what.
    pub fn can_undo(&self) -> Option<String> {
        self.mind.undo.last().map(|u| u.what.clone())
    }

    fn steered(&mut self, what: &str, to: Steer) {
        if to == self.mind.steer {
            return;
        }
        let incoming = self.incoming_parked().map(|d| self.slots[d].record.clone());
        self.mind.undo.push(Undo { what: what.to_string(), steer: self.mind.steer.clone(), incoming });
        self.mind.steer = to;
        self.mind.steer_gen += 1;
        self.note(LogKind::Plan, format!("{} from here", capital(what)));
    }

    /// More energy (+1) or less (−1) from here on.
    pub fn more_energy(&mut self, dir: i8) {
        let to = (self.mind.steer.energy + 0.12 * dir.signum() as f64).clamp(-0.36, 0.36);
        let s = Steer { energy: to, ..self.mind.steer.clone() };
        self.steered(if dir > 0 { "more energy" } else { "less energy" }, s);
    }

    /// The next records lean towards the sound of the one on now.
    pub fn more_like_this(&mut self) {
        let on = self.slots[self.master].record.clone();
        let what = format!("more like {}", on.title);
        let s = Steer { like: Some(on), different: false, ..self.mind.steer.clone() };
        self.steered(&what, s);
    }

    /// The next records lean away from the sound of the one before them.
    pub fn something_different(&mut self) {
        let s = Steer { like: None, different: true, ..self.mind.steer.clone() };
        self.steered("something different", s);
    }

    /// The room's word taken back.
    pub fn steer_neutral(&mut self) {
        self.steered("as planned", Steer::default());
    }

    /// The incoming deck, while it waits parked for a transition not yet begun.
    fn incoming_parked(&self) -> Option<usize> {
        let to = 1 - self.master;
        let deck = self.engine.deck(wo_engine::DeckId::new(to).unwrap()).read();
        (!deck.playing && self.mix.as_ref().is_none_or(|m| !m.started)).then_some(to)
    }

    /// Asks the house (the set builder) for the records that would follow the master
    /// best, steered, when what they were asked for has changed.
    pub(crate) fn mind_tick(&mut self) {
        // taste, once an hour at most
        if self.house.is_some() && self.mind.taste_at.is_none_or(|t| t.elapsed() > Duration::from_secs(3600)) {
            self.mind.taste_at = Some(Instant::now());
            let (house, tx) = (self.house.clone().unwrap(), self.done_tx.clone());
            thread::spawn(move || {
                if let Ok(rows) = house.feedback_list(400) {
                    let _ = tx.send(Done::Taste(Taste::from_feedback(&rows)));
                }
            });
        }
        let Some(house) = self.house.clone() else { return };
        let master = self.slots[self.master].record.id;
        let want = (master, self.mind.steer_gen, self.shelf_gen);
        if self.mind.asked_for == Some(want) || self.mind.asking.is_some() || master <= 0 {
            return;
        }
        self.mind.asked_for = Some(want);
        self.mind.ask_turn += 1;
        let turn = self.mind.ask_turn;
        self.mind.asking = Some(turn);
        let source = match &self.library.shelf {
            Shelf::Playlist { id, .. } => serde_json::json!({ "playlists": [id] }),
            _ => serde_json::json!({ "library": true }),
        };
        let mut exclude: Vec<i64> = self.slots.iter().map(|s| s.record.id).collect();
        exclude.extend(self.mind.played.iter().copied());
        let body = serde_json::json!({
            "source": source,
            "shape": shape(&self.mind.steer),
            "prev": master,
            "k": 0,
            "exclude": exclude,
            "limit": 6,
        });
        let tx = self.done_tx.clone();
        thread::spawn(move || {
            let got = house.slot_choices(&body).map_err(|e| e.to_string());
            let _ = tx.send(Done::Choices { turn, got });
        });
    }

    /// The house's answer: the choices for after the master; a parked incoming the
    /// Auto DJ chose (not a hand) goes over to the new best where steering changed it.
    pub(crate) fn got_choices(&mut self, turn: u64, got: Result<Vec<wo_house::SlotChoice>, String>) {
        if self.mind.asking != Some(turn) {
            return;
        }
        self.mind.asking = None;
        let list = match got {
            Ok(l) => l,
            Err(e) => {
                self.note(LogKind::Trouble, format!("The house could not say what follows: {e}"));
                return;
            }
        };
        self.mind.choices = list
            .iter()
            .map(|c| Choice { record: Record::from_house(&c.track), fit: c.fit_in.unwrap_or(0.0), why: c.why.clone() })
            .filter(|c| c.record.playable())
            .collect();
        let Some(best) = self.mind.choices.first().cloned() else { return };
        if let Some(to) = self.incoming_parked()
            && self.auto
            && !self.mind.by_hand[to]
            && self.slots[to].record.id != best.record.id
            && !self.mind.steer.neutral()
        {
            self.note(LogKind::Next, format!("Next: {}{}", best.record.title, if best.why.is_empty() { String::new() } else { format!(" · {}", best.why) }));
            self.mix = None;
            self.load(to, best.record.clone());
            self.mind.by_hand[to] = false;
        }
    }

    /// The next record for the free deck: the house's best choice not on a deck or
    /// played, else the best fit on the shelf.
    pub(crate) fn chosen_next(&mut self) -> Option<Record> {
        let on: Vec<i64> = self.slots.iter().map(|s| s.record.id).collect();
        let c = self.mind.choices.iter().find(|c| !on.contains(&c.record.id) && !self.mind.played.contains(&c.record.id))?.clone();
        self.note(LogKind::Next, format!("Next: {}{}", c.record.title, if c.why.is_empty() { String::new() } else { format!(" · {}", c.why) }));
        Some(c.record)
    }

    /// A thumb on the last transition: 1 a good one, -1 so-so (kept by the house).
    pub fn rate(&mut self, rating: i8) {
        let Some(m) = self.mind.last.as_mut() else { return };
        m.rating = Some(rating);
        let m = m.clone();
        self.note(LogKind::Hand, format!("{} {} → {}", if rating > 0 { "A good one:" } else { "So-so:" }, m.from.title, m.to.title));
        self.tell_house("rating", &m, serde_json::json!({ "rating": rating }));
    }

    /// One thing the booth did, or what was thought of it, to the house's mix feedback.
    pub(crate) fn tell_house(&self, event: &str, m: &LastMix, more: serde_json::Value) {
        // only records the house has (a synthesised or local-only record is nothing to it)
        if m.from.id <= 0 || m.to.id <= 0 || !matches!(m.to.audio, crate::records::Audio::House { .. }) {
            return;
        }
        let Some(house) = self.house.clone() else { return };
        let style = match self.style {
            Style::Easy => "easy",
            Style::Normal => "normal",
            Style::Bold => "bold",
        };
        let mut detail = serde_json::json!({ "why": m.why, "steered": m.steered, "style": style, "client": "desk" });
        if let (Some(d), Some(more)) = (detail.as_object_mut(), more.as_object()) {
            d.extend(more.clone());
        }
        let mut body = serde_json::json!({
            "event": event,
            "from_track": m.from.id,
            "to_track": m.to.id,
            "kind": m.kind.name(),
            "bars": m.bars,
            "shift": m.shift,
            "out_ms": (m.out * 1000.0) as i64,
            "in_ms": (m.inn * 1000.0) as i64,
            "detail": detail,
        });
        if let Some(r) = more.get("rating") {
            body["rating"] = r.clone();
        }
        thread::spawn(move || {
            if let Err(e) = house.feedback(&body) {
                eprintln!("feedback: {e}");
            }
        });
    }

    /// Goes back on the last thing the Auto DJ changed: the room's word as it was, and
    /// the record that was coming, where the change had replaced it.
    pub fn undo(&mut self) {
        let Some(u) = self.mind.undo.pop() else { return };
        self.mind.steer = u.steer;
        self.mind.steer_gen += 1;
        if let (Some(rec), Some(to)) = (u.incoming, self.incoming_parked())
            && self.slots[to].record.id != rec.id
        {
            self.mix = None;
            self.load(to, rec);
        }
        self.note(LogKind::Plan, format!("Undone: {}", u.what));
    }

    /// Skip: into the next record at the next bar, quickly (a short blend; a fade where
    /// the two cannot be held in step; bold: echoed out).
    pub fn skip(&mut self) {
        let Some(m) = self.mix.as_ref().filter(|m| !m.started) else { return };
        let (kind, bars) = if !m.in_step {
            (Transition::Fade, 2)
        } else if self.style == Style::Bold {
            (Transition::EchoOut, 2)
        } else if self.style == Style::Easy {
            (Transition::Blend, 8)
        } else {
            (Transition::Blend, 4)
        };
        let title = self.slots[m.to].record.title.clone();
        self.choose_move(kind, Some(bars));
        if let Some(m) = self.mix.as_mut() {
            m.why = "skipped".into();
        }
        self.mix_now();
        self.note(LogKind::Hand, format!("Skip: into {title} at the next bar"));
    }

    /// The planned transition `phrases` four-bar phrases later (+) or sooner (−): not
    /// past where the record still has room for the move, not before now.
    pub fn later(&mut self, phrases: i32) {
        let Some(m) = self.mix.as_ref().filter(|m| !m.started) else { return };
        let (from, out, length) = (m.from, m.out, m.length);
        let t = &self.slots[from].timing;
        let Some(bar) = t.bar() else { return };
        let end = t.sound_end.unwrap_or(t.duration);
        let heard = self.engine.deck(wo_engine::DeckId::new(from).unwrap()).position();
        let mut at = out + bar * 4.0 * phrases as f64;
        at = at.min(end - length).max(heard + bar);
        let at = t.on_grid(at, 4);
        if (at - out).abs() < 0.05 {
            let title = self.slots[from].record.title.clone();
            self.note(LogKind::Plan, if phrases > 0 { format!("No more of {title} to give: it goes out as late as it can") } else { "It cannot go any sooner".into() });
            return;
        }
        if let Some(m) = self.mix.as_mut() {
            m.out = at;
        }
        let title = self.slots[from].record.title.clone();
        self.note(LogKind::Hand, format!("{}: out of {title} at {}", if at > out { "Later" } else { "Sooner" }, clock(at)));
    }

    /// The planned transition twice as long (64 bars at most).
    pub fn longer(&mut self) {
        let Some(m) = self.mix.as_ref().filter(|m| !m.started) else { return };
        let (kind, bars) = (m.kind, (m.bars * 2).min(64));
        if bars == m.bars {
            return;
        }
        self.choose_move(kind, Some(bars));
        self.note(LogKind::Hand, format!("Longer: {} over {bars} bars", kind.word()));
    }

    /// A hand picks another move for the transition planned (the plan view): told to the
    /// house, so the planner learns what this person steers it away from.
    pub fn steer_move(&mut self, kind: Transition, bars: u32) {
        let Some(m) = self.mix.as_ref().filter(|m| !m.started) else { return };
        let (was, was_bars) = (m.kind, m.bars);
        if (was, was_bars) == (kind, bars) {
            return;
        }
        self.choose_move(kind, Some(bars));
        if let Some(m) = self.mix.as_mut() {
            m.why = "by hand".into();
        }
        self.tell_steer(was, was_bars);
        self.note(LogKind::Hand, format!("{} over {bars} bars, by hand (was {})", kind.word(), was.word().to_lowercase()));
    }

    /// A record a hand put on deck `d`: the Auto DJ plans with it and its choices leave
    /// it there.
    pub fn load_by_hand(&mut self, d: usize, record: Record) {
        let title = record.title.clone();
        self.load(d, record);
        self.mind.by_hand[d] = true;
        self.note(LogKind::Hand, format!("{title} on deck {} by hand", ["A", "B"][d]));
    }

    /// A move chosen by a hand on the plan, told to the house (the planner learns which
    /// moves this person steers it away from).
    pub(crate) fn tell_steer(&mut self, was: Transition, was_bars: u32) {
        let Some(m) = self.mix.as_ref() else { return };
        let last = LastMix {
            from: self.slots[m.from].record.clone(),
            to: self.slots[m.to].record.clone(),
            kind: m.kind,
            bars: m.bars,
            shift: 0.0,
            out: m.out,
            inn: 0.0,
            why: m.why.clone(),
            steered: true,
            rating: None,
        };
        self.tell_house("steer", &last, serde_json::json!({ "was": was.name(), "wasBars": was_bars }));
    }
}

fn capital(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

/// m:ss
pub fn clock(secs: f64) -> String {
    let s = secs.max(0.0) as u64;
    format!("{}:{:02}", s / 60, s % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shape_carries_the_steer() {
        let s = shape(&Steer { energy: 0.24, like: None, different: true });
        assert_eq!(s["offset"], 0.24);
        assert_eq!(s["variety"]["smooth"], 0.1);
        assert!(s.get("anchor").is_none());
        assert_eq!(clock(125.0), "2:05");
        assert_eq!(capital("more energy"), "More energy");
    }
}
