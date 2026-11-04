//! PLAN A SET (v1's set_planner_page.dart over dj_set.dart): where the records come
//! from (the whole library, a playlist), how the set should go (its length, its energy
//! over time, how strict about keys, how varied, how familiar), and the set the house's
//! set builder makes from that — every record with how well it follows the one before
//! and why. Played, the Auto DJ takes its records in order; the room's word on it
//! (more energy, like this…) builds the rest of it again from where it is.
use std::thread;

use crate::autodj::LogKind;
use crate::library::Done;
use crate::records::Record;
use crate::Desk;

/// A set's energy over time.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Arc {
    WarmUp,
    Build,
    #[default]
    PeakLate,
    Plateau,
    TwoWaves,
    CoolDown,
}

impl Arc {
    pub const ALL: [Arc; 6] = [Arc::WarmUp, Arc::Build, Arc::PeakLate, Arc::Plateau, Arc::TwoWaves, Arc::CoolDown];

    pub fn word(self) -> &'static str {
        match self {
            Arc::WarmUp => "Warm-up",
            Arc::Build => "Build",
            Arc::PeakLate => "Peak late",
            Arc::Plateau => "Plateau",
            Arc::TwoWaves => "Two waves",
            Arc::CoolDown => "Cool down",
        }
    }

    /// Its energy over the set (0..1 of the way in → 0..1 of the pool's loudness).
    pub fn points(self) -> &'static [(f64, f64)] {
        match self {
            Arc::WarmUp => &[(0.0, 0.1), (0.7, 0.45), (1.0, 0.6)],
            Arc::Build => &[(0.0, 0.2), (1.0, 0.95)],
            Arc::PeakLate => &[(0.0, 0.3), (0.75, 0.95), (1.0, 0.6)],
            Arc::Plateau => &[(0.0, 0.55), (0.15, 0.8), (1.0, 0.8)],
            Arc::TwoWaves => &[(0.0, 0.3), (0.3, 0.85), (0.5, 0.45), (0.8, 0.95), (1.0, 0.6)],
            Arc::CoolDown => &[(0.0, 0.85), (1.0, 0.15)],
        }
    }

    /// Where the curve is `k` of the way in.
    pub fn at(self, k: f64) -> f64 {
        let pts = self.points();
        let k = k.clamp(0.0, 1.0);
        for w in pts.windows(2) {
            if k <= w[1].0 {
                let t = (k - w[0].0) / (w[1].0 - w[0].0).max(1e-9);
                return w[0].1 + (w[1].1 - w[0].1) * t;
            }
        }
        pts.last().unwrap().1
    }
}

/// How strict about keys.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Keys {
    /// Never two keys that clash.
    Strict,
    /// A clash costs, but may happen.
    #[default]
    Loose,
    Any,
}

impl Keys {
    pub fn name(self) -> &'static str {
        match self {
            Keys::Strict => "strict",
            Keys::Loose => "loose",
            Keys::Any => "any",
        }
    }
}

/// How a set should go.
#[derive(Clone, Debug, PartialEq)]
pub struct SetShape {
    /// From the whole library (None), or a playlist (its id).
    pub playlist: Option<(i64, String)>,
    pub tracks: u32,
    /// The length in minutes, where that is how it is asked for (else `tracks`).
    pub minutes: Option<f64>,
    pub arc: Arc,
    pub keys: Keys,
    /// 0 each record unlike the last … 1 each like the last.
    pub smooth: f64,
    /// 0 the records played most … 1 the ones hardly played.
    pub fresh: f64,
    /// No artist again within this many records.
    pub gap: u32,
    /// Records already taken apart first.
    pub stems: bool,
}

impl Default for SetShape {
    fn default() -> Self {
        SetShape { playlist: None, tracks: 12, minutes: None, arc: Arc::PeakLate, keys: Keys::Loose, smooth: 0.5, fresh: 0.5, gap: 3, stems: false }
    }
}

/// One record of a set.
#[derive(Clone, Debug, PartialEq)]
pub struct SetSlot {
    pub record: Record,
    /// How well it follows the one before (none for the first), and why.
    pub fit: Option<f64>,
    pub why: String,
    /// Its energy, and where the shape wanted the set to be there (0..1).
    pub energy: Option<f64>,
    pub target: f64,
    pub bpm: Option<f64>,
    pub camelot: Option<String>,
    /// Where in the set it plays, seconds from its start.
    pub at: f64,
}

/// A set built by the house.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct DjSet {
    pub shape: Option<SetShape>,
    pub slots: Vec<SetSlot>,
}

/// The set as the Desk holds it.
#[derive(Default)]
pub(crate) struct SetState {
    /// The last one built (shown on the set page).
    pub built: Option<DjSet>,
    /// Being played by the Auto DJ.
    pub playing: bool,
    pub building: Option<u64>,
    turn: u64,
    pub error: Option<String>,
}

/// What the set page shows.
#[derive(Clone, Debug, Default)]
pub struct SetView {
    pub set: Option<DjSet>,
    pub playing: bool,
    pub building: bool,
    pub error: Option<String>,
    /// How far through it the Auto DJ is (slots played or on a deck).
    pub at: usize,
}

fn body(shape: &SetShape, steer: &crate::autodj::Steer, start: Option<(i64, Vec<i64>, f64)>, exclude: &[i64], tracks: Option<u32>) -> serde_json::Value {
    let source = match &shape.playlist {
        Some((id, _)) => serde_json::json!({ "playlists": [id] }),
        None => serde_json::json!({ "library": true }),
    };
    let energy: Vec<[f64; 2]> = shape.arc.points().iter().map(|&(k, e)| [k, e]).collect();
    let mut sh = serde_json::json!({
        "energy": energy,
        "key": shape.keys.name(),
        "variety": { "gap": shape.gap, "smooth": if steer.like.is_some() { 0.85 } else if steer.different { 0.1 } else { shape.smooth }, "fresh": shape.fresh },
        "stems": shape.stems,
        "offset": steer.energy,
    });
    if let Some(r) = &steer.like {
        sh["anchor"] = serde_json::json!(r.id);
    }
    let length = match (tracks, shape.minutes) {
        (Some(n), _) => serde_json::json!({ "tracks": n }),
        (None, Some(m)) => serde_json::json!({ "minutes": m }),
        (None, None) => serde_json::json!({ "tracks": shape.tracks }),
    };
    let mut b = serde_json::json!({ "source": source, "shape": sh, "length": length, "exclude": exclude });
    if let Some((id, before, pitch)) = start {
        b["start"] = serde_json::json!({ "track_id": id, "before": before, "pitch": pitch });
    }
    b
}

/// The house's slots, read.
pub(crate) fn slots_of(v: &serde_json::Value) -> Vec<SetSlot> {
    let f = |x: &serde_json::Value| x.as_f64();
    v.get("slots")
        .and_then(|s| s.as_array())
        .map(|rows| {
            rows.iter()
                .filter_map(|r| {
                    let t: wo_house::Track = serde_json::from_value(r.get("track")?.clone()).ok()?;
                    Some(SetSlot {
                        record: Record::from_house(&t),
                        fit: r.get("fit").and_then(f),
                        why: r.get("why").and_then(|w| w.as_str()).unwrap_or("").to_string(),
                        energy: r.get("energy").and_then(f),
                        target: r.get("target").and_then(f).unwrap_or(0.0),
                        bpm: r.get("bpm").and_then(f),
                        camelot: r.get("camelot").and_then(|c| c.as_str()).map(str::to_owned),
                        at: r.get("at_ms").and_then(f).unwrap_or(0.0) / 1000.0,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

impl Desk {
    /// The set page's view.
    pub fn set_view(&self) -> SetView {
        let at = self.set_position();
        SetView { set: self.set.built.clone(), playing: self.set.playing, building: self.set.building.is_some(), error: self.set.error.clone(), at }
    }

    /// How many of the set's records have been played or are on a deck.
    fn set_position(&self) -> usize {
        let Some(s) = &self.set.built else { return 0 };
        let on: Vec<i64> = self.slots.iter().map(|s| s.record.id).collect();
        s.slots.iter().rposition(|x| on.contains(&x.record.id) || self.mind.played.contains(&x.record.id)).map_or(0, |i| i + 1)
    }

    /// Builds a set to `shape` at the house: from the record playing now when one is
    /// (the set follows it), else from the top.
    pub fn build_set(&mut self, shape: SetShape) {
        let Some(house) = self.house.clone() else {
            self.set.error = Some("Sign in to the house: it builds the sets".into());
            return;
        };
        self.set.turn += 1;
        let turn = self.set.turn;
        self.set.building = Some(turn);
        self.set.error = None;
        let master = &self.slots[self.master].record;
        let playing = self.engine.deck(wo_engine::DeckId::new(self.master).unwrap()).read().playing;
        let start = (playing && master.id > 0).then(|| (master.id, self.mind.played.iter().rev().take(10).copied().collect(), 1.0));
        let b = body(&shape, &self.mind.steer, start, &self.mind.played, None);
        let tx = self.done_tx.clone();
        thread::spawn(move || {
            let got = house.build_set(&b).map(|v| DjSet { shape: Some(shape), slots: slots_of(&v) }).map_err(|e| e.to_string());
            let _ = tx.send(Done::Set { turn, got, rest: false });
        });
    }

    /// The house's set, or why not.
    pub(crate) fn got_set(&mut self, turn: u64, got: Result<DjSet, String>, rest: bool) {
        if self.set.building != Some(turn) {
            return;
        }
        self.set.building = None;
        match got {
            Ok(s) if s.slots.is_empty() => self.set.error = Some("The house found no records for that".into()),
            Ok(s) if rest => {
                // the rest built again from where the set is: what was played stays
                let keep = self.set_position();
                let mut old = self.set.built.take().unwrap_or_default();
                old.slots.truncate(keep);
                let have: Vec<i64> = old.slots.iter().map(|x| x.record.id).collect();
                old.slots.extend(s.slots.into_iter().filter(|x| !have.contains(&x.record.id)));
                self.note(LogKind::Plan, format!("The rest of the set built again: {} records", old.slots.len() - keep));
                self.set.built = Some(old);
            }
            Ok(s) => {
                self.note(LogKind::Plan, format!("A set of {} records built", s.slots.len()));
                self.set.built = Some(s);
            }
            Err(e) => self.set.error = Some(e),
        }
    }

    /// The Auto DJ plays the set built, in order, from the first record not yet played.
    pub fn play_set(&mut self) {
        if self.set.built.as_ref().is_none_or(|s| s.slots.is_empty()) {
            return;
        }
        self.set.playing = true;
        self.auto = true;
        self.note(LogKind::Plan, "Playing the set");
        // the record coming goes over to the set's next where the Auto DJ chose it
        let to = 1 - self.master;
        let parked = !self.engine.deck(wo_engine::DeckId::new(to).unwrap()).read().playing && self.mix.as_ref().is_none_or(|m| !m.started);
        if parked && !self.mind.by_hand[to]
            && let Some(next) = self.set_next()
            && next.id != self.slots[to].record.id
        {
            self.mix = None;
            self.load(to, next);
        }
    }

    /// The Auto DJ back to choosing for itself.
    pub fn stop_set(&mut self) {
        if self.set.playing {
            self.set.playing = false;
            self.note(LogKind::Plan, "The set let go of: the Auto DJ chooses again");
        }
    }

    /// The set's next record: the first after the last one played or on a deck.
    pub(crate) fn set_next(&self) -> Option<Record> {
        if !self.set.playing {
            return None;
        }
        let s = self.set.built.as_ref()?;
        let on: Vec<i64> = self.slots.iter().map(|s| s.record.id).collect();
        s.slots.iter().skip(self.set_position()).find(|x| !on.contains(&x.record.id) && x.record.playable()).map(|x| x.record.clone())
    }

    /// The rest of a set playing built again from where it is (the room's word changed it).
    pub(crate) fn reroute_set(&mut self) {
        if !self.set.playing {
            return;
        }
        let (Some(house), Some(built)) = (self.house.clone(), self.set.built.clone()) else { return };
        let Some(shape) = built.shape.clone() else { return };
        let left = built.slots.len().saturating_sub(self.set_position()) as u32;
        if left == 0 {
            return;
        }
        self.set.turn += 1;
        let turn = self.set.turn;
        self.set.building = Some(turn);
        let master = self.slots[self.master].record.id;
        let mut exclude = self.mind.played.clone();
        exclude.extend(self.slots.iter().map(|s| s.record.id));
        let b = body(&shape, &self.mind.steer, Some((master, self.mind.played.iter().rev().take(10).copied().collect(), 1.0)), &exclude, Some(left));
        let tx = self.done_tx.clone();
        thread::spawn(move || {
            let got = house.build_set(&b).map(|v| DjSet { shape: Some(shape), slots: slots_of(&v) }).map_err(|e| e.to_string());
            let _ = tx.send(Done::Set { turn, got, rest: true });
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arcs_and_the_body() {
        assert!((Arc::PeakLate.at(0.75) - 0.95).abs() < 1e-9);
        assert!((Arc::Build.at(0.5) - 0.575).abs() < 1e-9);
        let b = body(&SetShape::default(), &Default::default(), Some((7, vec![3], 1.0)), &[3], None);
        assert_eq!(b["length"]["tracks"], 12);
        assert_eq!(b["shape"]["key"], "loose");
        assert_eq!(b["start"]["track_id"], 7);
        assert_eq!(b["source"]["library"], true);
        let rows = serde_json::json!({ "slots": [
            { "track": { "id": 5, "title": "One", "state": "ready", "duration_ms": 200000 }, "fit": null, "why": "", "energy": 0.4, "target": 0.3, "at_ms": 0 },
            { "track": { "id": 6, "title": "Two", "state": "ready", "duration_ms": 180000 }, "fit": 0.81, "why": "the same key", "target": 0.5, "at_ms": 190000 }
        ]});
        let s = slots_of(&rows);
        assert_eq!(s.len(), 2);
        assert_eq!((s[1].record.id, s[1].fit, s[1].at), (6, Some(0.81), 190.0));
    }
}
