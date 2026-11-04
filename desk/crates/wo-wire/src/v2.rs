//! ShowWire v2 (plan §2.3): what the Rust stage (apps/wetowl-stage) reads beyond v1's lines.
//! The Desk directs the show itself (wo_show::engine::Direct) and says:
//!
//!   {"t":"record","deck":"A","facts":{…RecordFacts}|null}   a deck's record, on load and as
//!                                                            its analysis comes (kept for a
//!                                                            stage that connects later)
//!   {"t":"cue","cue":{…Cue}}                                the director's decision, when it
//!                                                            changes (each frame of a dissolve)
//!
//! beside v1's `desk` frame (the decks' positions and what is heard) and the PCM. A v1 stage
//! ignores both; the Rust stage ignores v1's hands but the screen's. Both ends make the show's
//! room from a frame the same way ([room]), so the Desk directs over what the stage plays.
//!
//! Stage → Desk: `{"t":"hello","v":2,"from":"stage"}` on connecting, then the picture and
//! `shown` as v1's stage sends them.
use wo_show::deck::{Channel, RecordFacts, ShowAudio, ShowDeck, gain_of};
use wo_show::engine::{Cue, Room};
use wo_show::state::ShowMix;

use crate::{Audio, Deck, Frame, Hand, Mix};

// The `t` first, as every line of the wire (a stage tells a line by how it starts).
pub fn record(deck: &str, facts: Option<&RecordFacts>) -> String {
    format!(r#"{{"t":"record","deck":{},"facts":{}}}"#, serde_json::Value::from(deck), serde_json::to_string(&facts).expect("facts are JSON"))
}

pub fn cue(c: &Cue) -> String {
    format!(r#"{{"t":"cue","cue":{}}}"#, c.to_json())
}

/// What a v2 stage says first.
pub const STAGE_HELLO: &str = r#"{"t":"hello","v":2,"from":"stage"}"#;

/// A line from the Desk, as a v2 stage reads it.
#[derive(Clone, Debug, PartialEq)]
pub enum Said {
    Desk(Box<Frame>),
    Record(String, Option<Box<RecordFacts>>),
    Cue(Box<Cue>),
    Hand(Hand),
    /// The Desk's hello, or anything else.
    Other,
}

pub fn said(line: &str) -> Said {
    let Ok(j) = serde_json::from_str::<serde_json::Value>(line) else { return Said::Other };
    match j.get("t").and_then(|t| t.as_str()) {
        Some("desk") => j.get("d").and_then(|d| serde_json::from_value(d.clone()).ok()).map(|f| Said::Desk(Box::new(f))).unwrap_or(Said::Other),
        Some("record") => {
            let deck = j.get("deck").and_then(|d| d.as_str()).unwrap_or("A").to_owned();
            let facts = j.get("facts").and_then(|f| serde_json::from_value::<RecordFacts>(f.clone()).ok()).map(Box::new);
            Said::Record(deck, facts)
        }
        Some("cue") => j.get("cue").map(|c| Said::Cue(Box::new(Cue::from_json(c)))).unwrap_or(Said::Other),
        Some("hands") => hand_of(&j).map(Said::Hand).unwrap_or(Said::Other),
        _ => Said::Other,
    }
}

/// A `hands` line back into the hand (crate::hand's other way).
fn hand_of(j: &serde_json::Value) -> Option<Hand> {
    let on = j.get("on").and_then(|o| o.as_bool()).unwrap_or(true);
    let s = |k: &str| j.get(k).and_then(|v| v.as_str()).map(str::to_owned);
    Some(match j.get("do")?.as_str()? {
        "hit" => Hand::Hit,
        "next" => Hand::Next,
        "previous" => Hand::Previous,
        "mosh" => Hand::Mosh,
        "hold" => Hand::Hold(on),
        "blackout" => Hand::Blackout(on),
        "strobe" => Hand::Strobe(on),
        "freeze" => Hand::Freeze(on),
        "never" => Hand::Never,
        "wider" => Hand::Wider,
        "less" => Hand::Less,
        "more" => Hand::More,
        "keep" => Hand::Keep,
        "undo" => Hand::Undo,
        "letgo" => Hand::LetGo,
        "full" => Hand::Full(on),
        "set" => Hand::Set(s("id").unwrap_or_default()),
        "screen" => Hand::Screen(s("name")?),
        "fave" => Hand::Fave(s("id")?),
        _ => return None,
    })
}

/// The engine's measure as the show's sound (the stems' shares not measured: none).
pub fn audio(a: &Audio) -> ShowAudio {
    let f = |v: f32| v as f64;
    ShowAudio { sub: f(a.sub), low: f(a.low), mid: f(a.mid), high: f(a.high), air: f(a.air), kick: f(a.kick), snare: f(a.snare), hat: f(a.hat), onset: f(a.onset), ..Default::default() }
}

fn mix(m: &Mix) -> ShowMix {
    ShowMix { on: m.on, armed: m.armed, kind: m.kind.clone(), from: m.from.clone(), to: m.to.clone(), bars: m.bars, k: m.k, starts_in: m.starts_in_ms.map(|ms| ms as f64 / 1000.0) }
}

/// A deck of the frame, `dt` seconds on (a stage carries the decks on between frames, a
/// quarter of a second at most), read on its record's facts.
pub fn deck(name: &str, d: &Deck, facts: Option<&RecordFacts>, dt: f64) -> ShowDeck {
    let dt = dt.clamp(0.0, 0.25);
    let ms = d.position_ms + if d.playing { dt * 1000.0 * d.rate } else { 0.0 };
    let channel = Channel {
        level: (d.level as f64).clamp(0.0, 1.0),
        eq_low: gain_of(d.eq.low as f64),
        eq_mid: gain_of(d.eq.mid as f64),
        eq_high: gain_of(d.eq.high as f64),
        filter: (d.filter as f64).clamp(-1.0, 1.0),
        looping: d.looping,
    };
    // a record the facts are not of (another loaded meanwhile) is read on none
    let facts = facts.filter(|f| f.track_id == d.track_id);
    ShowDeck::derive(name, facts, d.playing, ms.max(0.0), channel, d.heard.as_ref().map(audio).unwrap_or_default())
}

/// The room of a Desk frame, `dt` seconds on: the two decks on their records' facts, the
/// master's sound (the decks' summed where the engine measured none), the mix.
pub fn room(f: &Frame, facts: [Option<&RecordFacts>; 2], dt: f64) -> Room {
    let a = deck("A", &f.a, facts[0], dt);
    let b = deck("B", &f.b, facts[1], dt);
    let audio = f.heard.as_ref().map(|h| audio(&h.master)).unwrap_or_else(|| a.audio.plus(&b.audio));
    Room { a, b, audio, mix: mix(&f.mix) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_lines_read_back_as_said() {
        let facts = RecordFacts { track_id: Some(3), beats_ms: vec![0.0, 500.0], camelot: Some("8A".into()), ..Default::default() };
        assert_eq!(said(&record("B", Some(&facts))), Said::Record("B".into(), Some(Box::new(facts))));
        assert_eq!(said(&record("A", None)), Said::Record("A".into(), None));
        let c = Cue { scene: Some("glide".into()), k: 0.25, ..Default::default() };
        assert_eq!(said(&cue(&c)), Said::Cue(Box::new(c)));
        for h in [Hand::Hit, Hand::Hold(false), Hand::Screen("HDMI-1".into()), Hand::Set(String::new()), Hand::Full(true)] {
            assert_eq!(said(&crate::hand(h.clone())), Said::Hand(h));
        }
        let f = Frame { a: Deck { track_id: Some(3), playing: true, position_ms: 1000.0, rate: 1.0, level: 1.0, ..Default::default() }, ..Default::default() };
        assert_eq!(said(&crate::frame(&f)), Said::Desk(Box::new(f)));
        assert_eq!(said(&crate::hello(None)), Said::Other);
    }

    #[test]
    fn a_frame_is_the_same_room_at_both_ends_and_runs_on_between() {
        let period = 500.0;
        let facts = RecordFacts { track_id: Some(3), beats_ms: (0..64).map(|i| i as f64 * period).collect(), steady: Some((0.0, period)), ..Default::default() };
        let f = Frame { a: Deck { track_id: Some(3), playing: true, position_ms: 1000.0, rate: 1.0, level: 0.8, ..Default::default() }, ..Default::default() };
        let r = room(&f, [Some(&facts), None], 0.0);
        assert_eq!(r.a.bpm, Some(120.0));
        assert_eq!(r.a.beat_index, Some(2));
        let later = room(&f, [Some(&facts), None], 0.1);
        assert_eq!(later.a.position_ms, 1100.0);
        // facts of another record are not read
        let other = RecordFacts { track_id: Some(4), ..facts.clone() };
        assert_eq!(room(&f, [Some(&other), None], 0.0).a.bpm, None);
        // a second at most a quarter
        assert_eq!(room(&f, [Some(&facts), None], 1.0).a.position_ms, 1250.0);
    }
}
