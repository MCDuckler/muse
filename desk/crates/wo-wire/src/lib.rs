//! ShowWire: the show between the Desk and a Stage, as JSON lines over a WebSocket —
//! v1's protocol (app/lib/src/state/show/show_wire.dart) with the Desk's own lines
//! (app/lib/src/state/show/desk_show_source.dart).
//!
//! Desk → stage: `hello` (on connecting, and again when the Desk signs in or out: the
//! house it reads records from, so the stage needs no sign-in of its own), a `desk`
//! frame each tick (the two decks as facts: the stage directs the show over them, as
//! the Desk has no director of its own) with the room's sound beside it as a binary
//! message ([pcm]: what MilkDrop listens to), `hands` when a hand moves the show.
//! Stage → Desk: its picture ten times a second (four bytes of size, then RGBA) with
//! `shown` (the scene on, held or not), and `ping`.
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
#[derive(Clone, Debug, PartialEq, Eq)]
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
    /// The look on judged, as v1's PERFORM does (app/lib/src/ui/show/desk_hands.dart):
    /// never again; the last never wider (any mask and blend, then the style in the
    /// scene); half as often; twice; kept as a favourite; the last judging undone.
    Never,
    Wider,
    Less,
    More,
    Keep,
    Undo,
    /// Every hold let go: the director has it all.
    LetGo,
    /// A set on, by id ("" the show as shipped).
    Set(String),
    /// The stage full screen on the screen of this name.
    Screen(String),
    /// Full screen where the window is, or a window again.
    Full(bool),
}

/// The house the Desk is signed into: the stage reads the records' beats, sections,
/// voices and pulse from it with the Desk's sign-in, not its own.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct House {
    pub server: String,
    pub token: String,
}

pub fn hello(house: Option<&House>) -> String {
    match house {
        Some(h) => format!(r#"{{"t":"hello","v":1,"from":"desk","house":{}}}"#, serde_json::to_string(h).expect("a house is JSON")),
        None => r#"{"t":"hello","v":1,"from":"desk"}"#.to_owned(),
    }
}

/// The room's sound since the last frame, as the master heard it (every fader, EQ and
/// kill in it): `PCM1`, the rate (u32, little-endian), then mono 16-bit samples
/// (little-endian). Binary, so the stage tells it from the picture's way back by
/// direction and from any line by kind.
pub fn pcm(rate: u32, samples: &[f32]) -> Vec<u8> {
    let mut b = Vec::with_capacity(8 + samples.len() * 2);
    b.extend_from_slice(b"PCM1");
    b.extend_from_slice(&rate.to_le_bytes());
    for &x in samples {
        b.extend_from_slice(&((x.clamp(-1.0, 1.0) * 32767.0).round() as i16).to_le_bytes());
    }
    b
}

pub fn frame(f: &Frame) -> String {
    format!(r#"{{"t":"desk","d":{}}}"#, serde_json::to_string(f).expect("a frame is JSON"))
}

pub fn hand(h: Hand) -> String {
    let named = |what: &str, key: &str, v: &str| format!(r#"{{"t":"hands","do":"{what}","{key}":{}}}"#, serde_json::Value::from(v));
    let (what, on) = match h {
        Hand::Hit => ("hit", None),
        Hand::Next => ("next", None),
        Hand::Previous => ("previous", None),
        Hand::Mosh => ("mosh", None),
        Hand::Hold(on) => ("hold", Some(on)),
        Hand::Blackout(on) => ("blackout", Some(on)),
        Hand::Strobe(on) => ("strobe", Some(on)),
        Hand::Freeze(on) => ("freeze", Some(on)),
        Hand::Never => ("never", None),
        Hand::Wider => ("wider", None),
        Hand::Less => ("less", None),
        Hand::More => ("more", None),
        Hand::Keep => ("keep", None),
        Hand::Undo => ("undo", None),
        Hand::LetGo => ("letgo", None),
        Hand::Full(on) => ("full", Some(on)),
        Hand::Set(id) => return named("set", "id", &id),
        Hand::Screen(name) => return named("screen", "name", &name),
    };
    match on {
        Some(on) => format!(r#"{{"t":"hands","do":"{what}","on":{on}}}"#),
        None => format!(r#"{{"t":"hands","do":"{what}"}}"#),
    }
}

/// What the stage says it shows (a stage from before the Desk's PERFORM says only the
/// scene and whether it is held).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Shown {
    pub scene: Option<String>,
    pub held: bool,
    /// The look on, in words: `Dancer · ascii on White · add`.
    pub look: Option<String>,
    /// How many things the hands hold.
    pub holds: u32,
    pub blackout: bool,
    pub freeze: bool,
    pub sets: Vec<SetRef>,
    /// The set on, by id; None the show as shipped.
    pub set: Option<String>,
    /// The last thing the hands were told, counted (a new count is news).
    pub said: Option<String>,
    pub said_n: u32,
    /// Whether UNDO and WIDER have something to do.
    pub undo: bool,
    pub wider: bool,
    pub screens: Vec<Screen>,
    /// The screen the window is full screen on, by name.
    pub screen: Option<String>,
    pub full: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
pub struct SetRef {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
pub struct Screen {
    pub name: String,
    pub w: u32,
    pub h: u32,
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
        // the stage knows a Desk by this beginning, house or not
        let h = House { server: "https://h".into(), token: "tk".into() };
        assert!(hello(Some(&h)).starts_with(r#"{"t":"hello","v":1,"from":"desk""#));
        assert_eq!(hello(Some(&h)), r#"{"t":"hello","v":1,"from":"desk","house":{"server":"https://h","token":"tk"}}"#);
    }

    #[test]
    fn the_sound_is_sixteen_bit_after_its_header() {
        let b = pcm(48000, &[0.0, 1.0, -1.0, 2.0]);
        assert_eq!(&b[..4], b"PCM1");
        assert_eq!(u32::from_le_bytes(b[4..8].try_into().unwrap()), 48000);
        let s: Vec<i16> = b[8..].chunks(2).map(|c| i16::from_le_bytes([c[0], c[1]])).collect();
        assert_eq!(s, vec![0, 32767, -32767, 32767]);
    }

    #[test]
    fn the_perform_hands() {
        assert_eq!(hand(Hand::Never), r#"{"t":"hands","do":"never"}"#);
        assert_eq!(hand(Hand::LetGo), r#"{"t":"hands","do":"letgo"}"#);
        assert_eq!(hand(Hand::Full(false)), r#"{"t":"hands","do":"full","on":false}"#);
        assert_eq!(hand(Hand::Set("l:1".into())), r#"{"t":"hands","do":"set","id":"l:1"}"#);
        assert_eq!(hand(Hand::Screen("BenQ \"W1070\"".into())), r#"{"t":"hands","do":"screen","name":"BenQ \"W1070\""}"#);
    }

    #[test]
    fn what_the_stage_shows() {
        let full = shown(
            r#"{"t":"shown","scene":"Dancer","held":true,"look":"Dancer · ascii","holds":2,"blackout":false,"freeze":true,"sets":[{"id":"l:1","name":"Club"}],"set":"l:1","said":"Never: x","saidN":3,"undo":true,"wider":false,"screens":[{"name":"HDMI","w":1920,"h":1080}],"screen":"HDMI","full":true}"#,
        )
        .unwrap();
        assert_eq!(full.look.as_deref(), Some("Dancer · ascii"));
        assert_eq!((full.holds, full.freeze, full.said_n, full.undo, full.full), (2, true, 3, true, true));
        assert_eq!(full.sets, vec![SetRef { id: "l:1".into(), name: "Club".into() }]);
        assert_eq!(full.screens[0], Screen { name: "HDMI".into(), w: 1920, h: 1080 });
        assert_eq!(shown(r#"{"t":"shown","scene":"tunnel","held":true}"#), Some(Shown { scene: Some("tunnel".into()), held: true, ..Default::default() }));
        assert_eq!(shown(r#"{"t":"shown","scene":null,"held":false}"#), Some(Shown::default()));
        assert_eq!(shown(r#"{"t":"now","shots":{}}"#), None);
    }
}
