//! ShowWire: the show between the Desk and a Stage, as JSON lines over a WebSocket —
//! v1's protocol (app/lib/src/state/show/show_wire.dart) with the Desk's own lines
//! (app/lib/src/state/show/desk_show_source.dart).
//!
//! Desk → stage: `hello` once, a `desk` frame each tick (the two decks as facts: the
//! stage directs the show over them, as the Desk has no director of its own), `hands`
//! when a hand moves the show. Stage → Desk: its picture ten times a second (four bytes
//! of size, then RGBA) with `shown` (the scene on, held or not), and `ping`.
//!
//! The stage tells a line by how it starts (`{"t":"desk"`), so the `t` goes first.
use serde::{Deserialize, Serialize};

pub mod server;
pub use server::{Server, Thumb};

/// What the engine measured of a bus, as the show's sound (ShowAudio's JSON, no stems).
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Audio {
    pub sub: f32,
    pub low: f32,
    pub mid: f32,
    pub high: f32,
    pub air: f32,
    pub kick: f32,
    pub snare: f32,
    pub hat: f32,
    pub onset: f32,
}

/// The three bands, in decibels (the kill at -40).
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct EqDb {
    pub low: f32,
    pub mid: f32,
    pub high: f32,
}

/// One deck as the show reads it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Deck {
    /// The house's track, whose beats, sections and voice the stage asks the house for.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub track_id: Option<i64>,
    pub title: String,
    pub artist: String,
    pub playing: bool,
    /// Where the ear is in the record, milliseconds.
    pub position_ms: f64,
    /// Seconds of the record a second, to carry the position on between frames.
    pub rate: f64,
    /// The channel's share of the room, 0..1.
    pub level: f32,
    pub eq: EqDb,
    /// -1 all the way low-pass, 0 open, 1 all the way high-pass.
    pub filter: f32,
    pub looping: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub heard: Option<Audio>,
}

/// The room's sound: the master, and its 32-bin spectrum (30 Hz .. 16 kHz).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Heard {
    pub master: Audio,
    pub spectrum: Vec<f32>,
}

/// The transition on, or about to go (ShowMix's JSON).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Mix {
    pub on: bool,
    pub armed: bool,
    pub kind: Option<String>,
    pub from: Option<String>,
    pub to: Option<String>,
    pub bars: u32,
    /// 0..1 through, while on.
    pub k: f64,
    pub starts_in_ms: Option<i64>,
}

/// One frame of the Desk.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Frame {
    pub a: Deck,
    pub b: Deck,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub heard: Option<Heard>,
    pub mix: Mix,
}

/// A hand on the show.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hand {
    /// The flash.
    Hit,
    Next,
    Previous,
    /// The next scene, datamoshed into.
    Mosh,
    /// The scene on held (the director's rules off it), or let go.
    Hold(bool),
    Blackout(bool),
    /// The strobe, while held.
    Strobe(bool),
    /// The picture held still.
    Freeze(bool),
}

pub fn hello() -> String {
    r#"{"t":"hello","v":1,"from":"desk"}"#.to_owned()
}

pub fn frame(f: &Frame) -> String {
    format!(r#"{{"t":"desk","d":{}}}"#, serde_json::to_string(f).expect("a frame is JSON"))
}

pub fn hand(h: Hand) -> String {
    let (what, on) = match h {
        Hand::Hit => ("hit", None),
        Hand::Next => ("next", None),
        Hand::Previous => ("previous", None),
        Hand::Mosh => ("mosh", None),
        Hand::Hold(on) => ("hold", Some(on)),
        Hand::Blackout(on) => ("blackout", Some(on)),
        Hand::Strobe(on) => ("strobe", Some(on)),
        Hand::Freeze(on) => ("freeze", Some(on)),
    };
    match on {
        Some(on) => format!(r#"{{"t":"hands","do":"{what}","on":{on}}}"#),
        None => format!(r#"{{"t":"hands","do":"{what}"}}"#),
    }
}

/// What the stage says it shows.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
pub struct Shown {
    pub scene: Option<String>,
    #[serde(default)]
    pub held: bool,
}

/// A stage's line: `shown`, or None for any other.
pub fn shown(line: &str) -> Option<Shown> {
    if !line.starts_with(r#"{"t":"shown""#) {
        return None;
    }
    serde_json::from_str(line).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_lines_start_with_their_kind() {
        let f = Frame { a: Deck { track_id: Some(7), title: "A song".into(), playing: true, position_ms: 1250.0, rate: 1.0, ..Default::default() }, ..Default::default() };
        let line = frame(&f);
        assert!(line.starts_with(r#"{"t":"desk","d":{"a":{"trackId":7,"#), "{line}");
        assert!(line.contains(r#""positionMs":1250.0"#) && !line.contains("heard"));
        let back: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(back["d"]["mix"]["startsInMs"], serde_json::Value::Null);
        assert_eq!(hand(Hand::Hit), r#"{"t":"hands","do":"hit"}"#);
        assert_eq!(hand(Hand::Blackout(true)), r#"{"t":"hands","do":"blackout","on":true}"#);
    }

    #[test]
    fn what_the_stage_shows() {
        assert_eq!(shown(r#"{"t":"shown","scene":"tunnel","held":true}"#), Some(Shown { scene: Some("tunnel".into()), held: true }));
        assert_eq!(shown(r#"{"t":"shown","scene":null,"held":false}"#), Some(Shown::default()));
        assert_eq!(shown(r#"{"t":"now","shots":{}}"#), None);
    }
}
