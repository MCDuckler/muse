//! Controls mapped by hand: any MIDI controller (a keyboard's knobs and faders, an
//! Oxygen Pro's, a Launch Control's) put on the booth's controls by choosing one of the
//! booth's and then moving the controller's own. What it sends is learned from the moving:
//! a note or a CC, its channel, and for a knob turned onto a browse knob whether it says
//! where it is or how far it turned. The mappings are kept (controllers-mapped.json) per
//! port and laid over the port's layout (or are its only one), so they read through the
//! same decoder, soft takeover and binding as a console the Desk knows.
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::layout::{Input, Kind, Layout, Protocol};

/// A booth control a controller's own can be mapped onto.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Target {
    /// The surface's vocabulary (what the binding reads): `deck.a.eq.low`.
    pub id: &'static str,
    pub kind: Kind,
    /// In the booth's words: "EQ low".
    pub name: &'static str,
    /// Where it sits: "Deck 1", "Mixer"…
    pub group: &'static str,
}

const fn t(id: &'static str, kind: Kind, name: &'static str, group: &'static str) -> Target {
    Target { id, kind, name, group }
}

macro_rules! deck {
    ($d:literal, $g:literal) => {
        [
            t(concat!("deck.", $d, ".volume"), Kind::Fader, "Channel fader", $g),
            t(concat!("deck.", $d, ".pitch"), Kind::Fader, "Tempo", $g),
            t(concat!("deck.", $d, ".trim"), Kind::Pot, "Trim", $g),
            t(concat!("deck.", $d, ".eq.high"), Kind::Pot, "EQ high", $g),
            t(concat!("deck.", $d, ".eq.mid"), Kind::Pot, "EQ mid", $g),
            t(concat!("deck.", $d, ".eq.low"), Kind::Pot, "EQ low", $g),
            t(concat!("deck.", $d, ".filter"), Kind::Pot, "Filter", $g),
            t(concat!("deck.", $d, ".play"), Kind::Button, "Play / pause", $g),
            t(concat!("deck.", $d, ".cue"), Kind::Button, "Cue", $g),
            t(concat!("deck.", $d, ".sync"), Kind::Button, "Sync", $g),
            t(concat!("deck.", $d, ".load"), Kind::Button, "Load", $g),
            t(concat!("deck.", $d, ".hotcue.1"), Kind::Button, "Hot cue 1", $g),
            t(concat!("deck.", $d, ".hotcue.2"), Kind::Button, "Hot cue 2", $g),
            t(concat!("deck.", $d, ".hotcue.3"), Kind::Button, "Hot cue 3", $g),
            t(concat!("deck.", $d, ".hotcue.4"), Kind::Button, "Hot cue 4", $g),
            t(concat!("deck.", $d, ".beatloop.4"), Kind::Button, "Loop 4 beats", $g),
            t(concat!("deck.", $d, ".loop.exit"), Kind::Button, "Loop exit", $g),
            t(concat!("deck.", $d, ".pfl"), Kind::Button, "Headphones cue", $g),
        ]
    };
}

/// Every booth control that can be mapped, in the order the controllers page lists them.
pub fn targets() -> Vec<Target> {
    let mut all = vec![
        t("mixer.crossfader", Kind::Fader, "Crossfader", "Mixer"),
        t("mixer.headMix", Kind::Pot, "Headphones mix", "Mixer"),
        t("mixer.headGain", Kind::Pot, "Headphones level", "Mixer"),
        t("fx.level", Kind::Pot, "Beat FX level", "Mixer"),
        t("fx.on", Kind::Button, "Beat FX on / off", "Mixer"),
        t("fx.select", Kind::Button, "Beat FX next", "Mixer"),
    ];
    all.extend(deck!("a", "Deck 1"));
    all.extend(deck!("b", "Deck 2"));
    all.extend([
        t("browse.turn", Kind::Encoder, "Browse", "Browser"),
        t("browse.press", Kind::Button, "Browse in", "Browser"),
        t("browse.back", Kind::Button, "Browse back", "Browser"),
        t("show.scene.prev", Kind::Button, "Scene before", "Show"),
        t("show.scene.next", Kind::Button, "Scene after", "Show"),
        t("show.hit", Kind::Button, "Hit", "Show"),
        t("show.blackout", Kind::Button, "Blackout", "Show"),
        t("show.strobe", Kind::Button, "Strobe (held)", "Show"),
    ]);
    all
}

pub fn target(id: &str) -> Option<Target> {
    targets().into_iter().find(|t| t.id == id)
}

/// What a controller's control sends.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Cc,
    Note,
}

/// One control mapped: what it sends on which port, and the booth's control it is.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Mapped {
    /// The port as [port_key] keeps it.
    pub port: String,
    pub source: Source,
    /// 0..15 (the wire's; channel 1 is 0).
    pub channel: u8,
    pub number: u8,
    pub id: String,
    /// A knob turned onto a relative control: how it says the turn (layout.rs's encodings).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encoding: Option<String>,
}

impl Mapped {
    /// "CC 74 · ch 1", "note C3 · ch 10".
    pub fn words(&self) -> String {
        match self.source {
            Source::Cc => format!("CC {} · ch {}", self.number, self.channel + 1),
            Source::Note => format!("note {} · ch {}", note_name(self.number), self.channel + 1),
        }
    }
}

fn note_name(n: u8) -> String {
    const NAMES: [&str; 12] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
    format!("{}{}", NAMES[n as usize % 12], n as i32 / 12 - 2)
}

/// A port's name as kept: what Linux adds that changes from one plug-in to the next (the
/// sequencer's ` 24:0`) taken off, so a mapping finds its controller again.
pub fn port_key(name: &str) -> String {
    let n = name.trim();
    if let Some((head, tail)) = n.rsplit_once(' ') {
        let mut parts = tail.split(':');
        if let (Some(a), Some(b), None) = (parts.next(), parts.next(), parts.next()) {
            if !a.is_empty() && !b.is_empty() && a.bytes().all(|c| c.is_ascii_digit()) && b.bytes().all(|c| c.is_ascii_digit()) {
                return head.trim_end().to_owned();
            }
        }
    }
    n.to_owned()
}

/// The mappings made by hand, kept in a file.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Mappings {
    #[serde(default)]
    pub mapped: Vec<Mapped>,
    #[serde(skip)]
    file: Option<PathBuf>,
}

impl Mappings {
    /// The ones kept at `file` (None: in memory only, for tests).
    pub fn at(file: Option<PathBuf>) -> Mappings {
        let mut m: Mappings = file.as_ref().and_then(|f| std::fs::read(f).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        m.file = file;
        m
    }

    pub fn file(&self) -> Option<&Path> {
        self.file.as_deref()
    }

    fn save(&self) {
        let Some(f) = &self.file else { return };
        let Ok(bytes) = serde_json::to_vec_pretty(self) else { return };
        if let Some(dir) = f.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let part = f.with_extension("json.part");
        if std::fs::write(&part, bytes).is_ok() {
            let _ = std::fs::rename(&part, f);
        }
    }

    /// Whether port `name` has any mapped.
    pub fn has(&self, name: &str) -> bool {
        let k = port_key(name);
        self.mapped.iter().any(|m| m.port == k)
    }

    /// `m` mapped: what that booth control was mapped to on its port, and whatever else
    /// that control of the controller's was, give way.
    pub fn set(&mut self, m: Mapped) {
        self.mapped.retain(|o| o.port != m.port || (o.id != m.id && (o.source, o.channel, o.number) != (m.source, m.channel, m.number)));
        self.mapped.push(m);
        self.save();
    }

    /// Booth control `id` unmapped on every port (on `port` only, given one).
    pub fn forget(&mut self, id: &str, port: Option<&str>) {
        let k = port.map(port_key);
        self.mapped.retain(|m| m.id != id || k.as_ref().is_some_and(|k| *k != m.port));
        self.save();
    }

    /// The mappings on port `name` as a layout's inputs.
    pub fn inputs(&self, name: &str) -> Vec<Input> {
        let k = port_key(name);
        self.mapped
            .iter()
            .filter(|m| m.port == k)
            .filter_map(|m| {
                let target = target(&m.id)?;
                // a pad or key mapped onto a button; anything onto a knob, a fader or the browse knob is a CC
                let kind = target.kind;
                Some(Input {
                    id: m.id.clone(),
                    kind,
                    channel: Some(m.channel),
                    cc: (m.source == Source::Cc).then_some(m.number),
                    note: (m.source == Source::Note).then_some(m.number),
                    report: None,
                    byte: None,
                    mask: 0xFF,
                    max: 127,
                    center: None,
                    encoding: m.encoding.clone(),
                    invert: false,
                    lsb: None,
                    per_turn: None,
                })
            })
            .collect()
    }

    /// Port `name`'s layout: the one the Desk knows for it (if any) with the hand's mappings
    /// over it, or the mappings alone. None: neither.
    pub fn layout(&self, name: &str, known: Option<&Layout>) -> Option<Layout> {
        let inputs = self.inputs(name);
        match known {
            Some(l) => {
                let mut l = l.clone();
                // the hand's come after, so they win where both read the same bytes
                l.inputs.extend(inputs);
                Some(l)
            }
            None if inputs.is_empty() => None,
            None => Some(Layout {
                id: format!("mapped:{}", port_key(name)),
                name: "mapped by hand".to_owned(),
                protocol: Protocol::Midi,
                usb: vec![],
                names: vec![port_key(name)],
                inputs,
                outputs: vec![],
                audio: None,
            }),
        }
    }
}

/// Watching for the control to map: the messages heard since the booth's control was
/// chosen, until one of them clearly is the one being moved.
#[derive(Clone, Debug)]
pub struct Learner {
    pub target: Target,
    heard: HashMap<(String, u8, u8), Vec<u8>>,
}

/// How far a knob or fader has to go before it is taken as the one moved (a resting
/// fader's jitter, a knob brushed, are not).
const MOVED: u8 = 6;

impl Learner {
    pub fn new(target: Target) -> Learner {
        Learner { target, heard: HashMap::new() }
    }

    /// A message from port `port`: the mapping, once it says which control is moving.
    pub fn hear(&mut self, port: &str, m: &[u8]) -> Option<Mapped> {
        if m.len() < 3 {
            return None;
        }
        let (status, channel, number, value) = (m[0] & 0xF0, m[0] & 0x0F, m[1] & 0x7F, m[2] & 0x7F);
        let Target { id, kind, .. } = self.target;
        let mapped = |source, encoding| Mapped { port: port_key(port), source, channel, number, id: id.to_owned(), encoding };
        match status {
            // a key or a pad pressed: a button
            0x90 if value > 0 => (kind == Kind::Button).then(|| mapped(Source::Note, None)),
            // the channel's mode messages (all notes off…) are no control
            0xB0 if number >= 120 => None,
            0xB0 => {
                if kind == Kind::Button {
                    // a button that sends a CC: its press
                    return (value > 0).then(|| mapped(Source::Cc, None));
                }
                let seen = self.heard.entry((port_key(port), channel, number)).or_default();
                seen.push(value);
                if kind == Kind::Encoder {
                    return (seen.len() >= 3).then(|| mapped(Source::Cc, Some(encoding(seen).to_owned())));
                }
                let (lo, hi) = (*seen.iter().min().unwrap(), *seen.iter().max().unwrap());
                (seen.len() >= 2 && hi - lo >= MOVED).then(|| mapped(Source::Cc, None))
            }
            _ => None,
        }
    }
}

/// How a CC turned onto a relative control says its turn: a relative knob's steps either
/// side of 0 (signed7) or of 64 (offset64), or an ordinary knob's positions, the turn read
/// from one to the next (wrap7).
fn encoding(values: &[u8]) -> &'static str {
    let near = |v: u8, c: i32| (v as i32 - c).abs() <= 7;
    if values.iter().all(|&v| v != 0 && (near(v, 0) || near(v, 128))) {
        "signed7"
    } else if values.iter().all(|&v| v != 0x40 && near(v, 64)) {
        "offset64"
    } else {
        "wrap7"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decode::Decoder;

    fn learner(id: &str) -> Learner {
        Learner::new(target(id).unwrap())
    }

    #[test]
    fn a_knob_turned_is_learned_once_it_has_moved() {
        let mut l = learner("deck.a.eq.low");
        assert!(l.hear("Oxygen Pro 49", &[0x90, 0x30, 0x64]).is_none(), "a key is not a knob");
        assert!(l.hear("Oxygen Pro 49", &[0xB0, 0x47, 60]).is_none(), "one message: not yet");
        assert!(l.hear("Oxygen Pro 49", &[0xB0, 0x47, 62]).is_none(), "a twitch");
        assert!(l.hear("Oxygen Pro 49", &[0xB1, 0x10, 0]).is_none(), "another control, once");
        let m = l.hear("Oxygen Pro 49", &[0xB0, 0x47, 67]).unwrap();
        assert_eq!((m.source, m.channel, m.number, m.id.as_str(), m.encoding.as_deref()), (Source::Cc, 0, 0x47, "deck.a.eq.low", None));
        assert_eq!(m.words(), "CC 71 · ch 1");
    }

    #[test]
    fn a_pad_or_a_cc_button_onto_a_button() {
        let mut l = learner("deck.b.play");
        assert!(l.hear("p", &[0x99, 0x24, 0x00]).is_none(), "a note off");
        let m = l.hear("p", &[0x99, 0x24, 0x50]).unwrap();
        assert_eq!((m.source, m.channel, m.number), (Source::Note, 9, 0x24));
        assert_eq!(m.words(), "note C1 · ch 10");
        let mut l = learner("deck.b.play");
        assert!(l.hear("p", &[0xB0, 0x74, 0x00]).is_none(), "a CC button let go of");
        assert_eq!(l.hear("p", &[0xB0, 0x74, 0x7F]).unwrap().source, Source::Cc);
        assert!(learner("deck.a.play").hear("p", &[0xB0, 0x7B, 0x7F]).is_none(), "all notes off is no button");
    }

    #[test]
    fn a_knob_onto_browse_is_read_by_its_turn() {
        let mut l = learner("browse.turn");
        l.hear("p", &[0xB0, 0x10, 0x01]);
        l.hear("p", &[0xB0, 0x10, 0x7F]);
        assert_eq!(l.hear("p", &[0xB0, 0x10, 0x02]).unwrap().encoding.as_deref(), Some("signed7"));
        let mut l = learner("browse.turn");
        l.hear("p", &[0xB0, 0x10, 0x41]);
        l.hear("p", &[0xB0, 0x10, 0x3F]);
        assert_eq!(l.hear("p", &[0xB0, 0x10, 0x42]).unwrap().encoding.as_deref(), Some("offset64"));
        let mut l = learner("browse.turn");
        for v in [20, 22] {
            l.hear("p", &[0xB0, 0x10, v]);
        }
        assert_eq!(l.hear("p", &[0xB0, 0x10, 24]).unwrap().encoding.as_deref(), Some("wrap7"));
    }

    #[test]
    fn linux_s_numbers_are_not_the_port_s_name() {
        assert_eq!(port_key("Oxygen Pro 49:Oxygen Pro 49 MIDI 1 24:0"), "Oxygen Pro 49:Oxygen Pro 49 MIDI 1");
        assert_eq!(port_key("MIDIIN2 (Oxygen Pro 49)"), "MIDIIN2 (Oxygen Pro 49)");
        assert_eq!(port_key("Oxygen Pro 49"), "Oxygen Pro 49");
    }

    #[test]
    fn mappings_give_way_and_read_through_the_decoder() {
        let mut m = Mappings::at(None);
        let cc = |n: u8, id: &str| Mapped { port: "Oxygen Pro 49".into(), source: Source::Cc, channel: 0, number: n, id: id.into(), encoding: None };
        m.set(cc(0x47, "deck.a.eq.low"));
        m.set(cc(0x48, "deck.a.eq.low"));
        assert_eq!(m.mapped, vec![cc(0x48, "deck.a.eq.low")], "the booth's control moved to the knob turned last");
        m.set(cc(0x48, "deck.a.eq.mid"));
        assert_eq!(m.mapped, vec![cc(0x48, "deck.a.eq.mid")], "one knob, one booth control");
        m.set(cc(0x10, "browse.turn").clone());
        m.mapped.last_mut().unwrap().encoding = Some("wrap7".into());
        m.set(Mapped { source: Source::Note, channel: 9, number: 0x24, ..cc(0, "deck.a.play") });
        assert!(m.has("Oxygen Pro 49") && !m.has("MIDIIN2 (Oxygen Pro 49)"));
        assert!(m.layout("MIDIIN2 (Oxygen Pro 49)", None).is_none());
        let layout = m.layout("Oxygen Pro 49", None).unwrap();
        let mut d = Decoder::new(layout);
        let e = d.decode(&[0xB0, 0x48, 127]);
        assert_eq!((e[0].id.as_str(), e[0].kind, e[0].value), ("deck.a.eq.mid", Kind::Pot, 1.0));
        assert!(d.decode(&[0xB1, 0x48, 127]).is_empty(), "another channel");
        assert!(d.decode(&[0x99, 0x24, 0x40])[0].pressed());
        assert!(!d.decode(&[0x89, 0x24, 0x40])[0].pressed(), "a note off lets go");
        d.decode(&[0xB0, 0x10, 30]);
        assert_eq!(d.decode(&[0xB0, 0x10, 28])[0].value, -2.0, "an ordinary knob onto browse: its turn");
        m.forget("deck.a.play", None);
        assert_eq!(m.mapped.len(), 2);
    }

    #[test]
    fn over_a_known_layout_the_hand_s_win() {
        let ddj = crate::layout::bundled().into_iter().find(|l| l.id == "pioneer_ddj_400_midi").unwrap();
        let mut m = Mappings::at(None);
        // the DDJ's deck 1 PLAY (note 0x0B, ch 1) made deck 2's
        m.set(Mapped { port: "DDJ-400".into(), source: Source::Note, channel: 0, number: 0x0B, id: "deck.b.play".into(), encoding: None });
        let mut d = Decoder::new(m.layout("DDJ-400", Some(&ddj)).unwrap());
        assert_eq!(d.decode(&[0x90, 0x0B, 0x7F])[0].id, "deck.b.play");
        assert_eq!(d.decode(&[0x91, 0x0B, 0x7F])[0].id, "deck.b.play", "the rest as the layout says");
    }

    #[test]
    fn kept_in_a_file() {
        let dir = std::env::temp_dir().join(format!("wo-control-learn-{}", std::process::id()));
        let f = dir.join("controllers-mapped.json");
        let mut m = Mappings::at(Some(f.clone()));
        m.set(Mapped { port: "Oxygen Pro 49".into(), source: Source::Cc, channel: 0, number: 0x47, id: "mixer.crossfader".into(), encoding: None });
        let again = Mappings::at(Some(f));
        assert_eq!(again.mapped, m.mapped);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn every_target_is_one_the_binding_reads() {
        use crate::binding::{Binding, Positions};
        use crate::decode::Event;
        let mut b = Binding::default();
        let at = Positions { crossfader: 1.0, fader: [1.0; 2], filter: [1.0; 2], eq: [[1.0; 3]; 2], pitch: [1.0; 2], gain: [1.0; 2], head_mix: 1.0, head_level: 1.0 };
        let mut ids = std::collections::HashSet::new();
        for t in targets() {
            assert!(ids.insert(t.id), "{} twice", t.id);
            let did = b.handle(&Event { id: t.id.into(), kind: t.kind, value: 1.0 }, &at);
            assert!(!did.is_empty(), "{} does nothing", t.id);
            if t.kind == Kind::Button {
                b.handle(&Event { id: t.id.into(), kind: t.kind, value: 0.0 }, &at);
            }
        }
    }
}
