//! The moments in the show (v1: show_events.dart): a beat, a bar, a phrase, a section turning,
//! a drop, a mix starting — the edges between one frame and the next, so the director cuts on a
//! phrase and a light strobes on a drop without each reading the state for the edge.
use crate::state::ShowState;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EventKind {
    Beat,
    Bar,
    /// The first bar of a four-bar phrase.
    Phrase,
    Section,
    Drop,
    Breakdown,
    Loaded,
    Play,
    Pause,
    MixArmed,
    MixStart,
    MixEnd,
    Hit,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ShowEvent {
    pub kind: EventKind,
    /// The deck it happened on, where it is a deck's.
    pub deck: Option<String>,
    /// It happened on the deck that has the room.
    pub master: bool,
    /// The first beat of the bar (beats); the bar's index (bars); the section's label (sections).
    pub one: bool,
    pub bar: Option<i64>,
    pub label: Option<String>,
    /// Read off the clock, not a grid.
    pub guessed: bool,
}

impl ShowEvent {
    /// A moment on the deck that has the room (for tests, and moments told rather than read).
    pub fn on_master(kind: EventKind) -> ShowEvent {
        ShowEvent::new(kind, None, true)
    }

    fn new(kind: EventKind, deck: Option<&str>, master: bool) -> ShowEvent {
        ShowEvent { kind, deck: deck.map(str::to_owned), master, one: false, bar: None, label: None, guessed: false }
    }
}

/// The events between `prev` and `next`: what the differ sees in the state alone.
pub fn events_between(prev: Option<&ShowState>, next: &ShowState) -> Vec<ShowEvent> {
    let mut out = vec![];
    for deck in [&next.a, &next.b] {
        let was = prev.map(|p| p.deck(&deck.name));
        let master = next.master_name == deck.name;
        let ev = |k| ShowEvent::new(k, Some(&deck.name), master);
        if was.map(|w| w.track_id) != Some(deck.track_id) {
            out.push(ev(EventKind::Loaded));
        }
        if let Some(w) = was
            && w.playing != deck.playing
        {
            out.push(ev(if deck.playing { EventKind::Play } else { EventKind::Pause }));
        }
        if !deck.playing {
            continue;
        }
        let same = was.is_some_and(|w| w.track_id == deck.track_id && w.playing);
        let Some(now) = deck.beat_index else {
            // no grid: bars and phrases by the clock, at the tempo or 120
            if let Some(w) = was.filter(|w| same && w.beat_index.is_none()) {
                let bar_ms = 240_000.0 / deck.bpm.unwrap_or(120.0);
                let (bw, bn) = ((w.position_ms / bar_ms).floor() as i64, (deck.position_ms / bar_ms).floor() as i64);
                if bn > bw && bn - bw < 4 {
                    out.push(ShowEvent { bar: Some(bn), guessed: true, ..ev(EventKind::Bar) });
                    if bn % 8 == 0 {
                        out.push(ShowEvent { guessed: true, ..ev(EventKind::Phrase) });
                    }
                }
            }
            continue;
        };
        if let Some(w) = was.filter(|_| same)
            && let Some(before) = w.beat_index
            && now > before
            && now - before < 8
        {
            let one = deck.beat_in_bar == Some(0);
            out.push(ShowEvent { one, ..ev(EventKind::Beat) });
            if one {
                out.push(ShowEvent { bar: deck.bar_index, ..ev(EventKind::Bar) });
                if deck.phrase_bar == Some(0) {
                    out.push(ev(EventKind::Phrase));
                }
            }
        }
        if let Some(w) = was.filter(|_| same) {
            if w.section != deck.section && deck.section.is_some() {
                out.push(ShowEvent { label: deck.section.clone(), ..ev(EventKind::Section) });
                if deck.breakdown && !w.breakdown {
                    out.push(ev(EventKind::Breakdown));
                }
            }
            if let (Some(a), Some(b)) = (w.drop_beats_away, deck.drop_beats_away)
                && a > 0.0
                && b <= 0.0
                && a - b < 8.0
            {
                out.push(ev(EventKind::Drop));
            }
        }
    }
    let (was_mix, mix) = (prev.map(|p| p.mix.clone()).unwrap_or_default(), &next.mix);
    if !was_mix.armed && mix.armed {
        out.push(ShowEvent::new(EventKind::MixArmed, None, false));
    }
    if !was_mix.on && mix.on {
        out.push(ShowEvent::new(EventKind::MixStart, None, false));
    }
    if was_mix.on && !mix.on {
        out.push(ShowEvent::new(EventKind::MixEnd, None, false));
    }
    out
}
