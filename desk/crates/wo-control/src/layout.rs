//! A controller's layout (controllers/*.json, the v1 files unchanged): which device it
//! is, and where each control's bytes are — a MIDI CC or note, or a HID report's byte
//! and bits — named in the surface's vocabulary (deck.a.play, mixer.crossfader…).
use serde::Deserialize;
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Protocol {
    Midi,
    Hid,
}

/// What a control is, which decides how its bytes become a value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Button,
    Pot,
    Fader,
    Encoder,
    Jog,
}

impl Kind {
    fn parse(s: &str) -> Option<Kind> {
        Some(match s {
            "button" => Kind::Button,
            "pot" => Kind::Pot,
            "fader" => Kind::Fader,
            "encoder" => Kind::Encoder,
            "jog" => Kind::Jog,
            _ => return None,
        })
    }

    pub fn positional(self) -> bool {
        matches!(self, Kind::Pot | Kind::Fader)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Input {
    pub id: String,
    pub kind: Kind,
    pub channel: Option<u8>,
    pub cc: Option<u8>,
    pub note: Option<u8>,
    pub report: Option<u8>,
    pub byte: Option<usize>,
    pub mask: u8,
    pub max: u32,
    pub center: Option<u32>,
    /// signed7, delta, wrap8, wrap7.
    pub encoding: Option<String>,
    pub invert: bool,
}

impl Input {
    /// A raw position as 0..1, a centred control's centre at 0.5.
    pub fn position(&self, raw: u32) -> f64 {
        let v = raw.min(self.max) as f64;
        let max = self.max as f64;
        let t = match self.center {
            Some(c) if c > 0 && c < self.max => {
                let c = c as f64;
                if v <= c { 0.5 * v / c } else { 0.5 + 0.5 * (v - c) / (max - c) }
            }
            _ => v / max,
        };
        if self.invert { 1.0 - t } else { t }
    }

    /// A relative control's turn, from its raw value (and the last one, for counters).
    pub fn relative(&self, raw: u32, last: Option<u32>) -> i32 {
        let raw = raw as i32;
        let wrapped = |d: i32, size: i32| if d > size / 2 { d - size } else if d < -size / 2 { d + size } else { d };
        let v = match self.encoding.as_deref() {
            Some("delta") => if raw >= 0x80 { raw - 0x100 } else { raw },
            Some("wrap8") => last.map(|l| wrapped(raw - l as i32, 256)).unwrap_or(0),
            Some("wrap7") => last.map(|l| wrapped(raw - l as i32, 128)).unwrap_or(0),
            _ => if raw >= 0x40 { raw - 0x80 } else { raw },
        };
        if self.invert { -v } else { v }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Output {
    pub id: String,
    pub channel: Option<u8>,
    pub cc: Option<u8>,
    pub note: Option<u8>,
    pub on: u8,
    pub off: u8,
    pub report: Option<u8>,
    pub length: Option<usize>,
    pub byte: Option<usize>,
    pub mask: u8,
}

#[derive(Clone, Debug)]
pub struct Layout {
    pub id: String,
    pub name: String,
    pub protocol: Protocol,
    /// USB vendor and product ids, and names a port or device may carry.
    pub usb: Vec<(u16, u16)>,
    pub names: Vec<String>,
    pub inputs: Vec<Input>,
    pub outputs: Vec<Output>,
}

/// A number as the layouts write them: 11, "11", "0x0B".
fn int(v: Option<&Value>) -> Option<u32> {
    match v? {
        Value::Number(n) => n.as_u64().map(|n| n as u32),
        Value::String(s) => {
            let s = s.trim();
            match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
                Some(h) => u32::from_str_radix(h, 16).ok(),
                None => s.parse().ok(),
            }
        }
        _ => None,
    }
}

fn hex(v: Option<&Value>) -> Option<u16> {
    match v? {
        Value::Number(n) => n.as_u64().map(|n| n as u16),
        Value::String(s) => u16::from_str_radix(s.trim().trim_start_matches("0x"), 16).ok(),
        _ => None,
    }
}

#[derive(Deserialize)]
struct Raw {
    id: String,
    name: String,
    protocol: String,
    #[serde(rename = "match", default)]
    matching: Value,
    #[serde(default)]
    midi: Value,
    #[serde(default)]
    hid: Value,
    #[serde(default)]
    inputs: Vec<Value>,
    #[serde(default)]
    outputs: Vec<Value>,
}

impl Layout {
    pub fn parse(json: &str) -> Result<Layout, String> {
        let raw: Raw = serde_json::from_str(json).map_err(|e| e.to_string())?;
        let protocol = match raw.protocol.as_str() {
            "midi" => Protocol::Midi,
            "hid" => Protocol::Hid,
            p => return Err(format!("{}: protocol {p} is not one the Desk speaks", raw.id)),
        };
        let defaults = if protocol == Protocol::Midi { &raw.midi } else { &raw.hid };
        let d = |k: &str| defaults.get(k);
        let mut inputs = vec![];
        for j in &raw.inputs {
            let Some(kind) = j.get("kind").and_then(|k| k.as_str()).and_then(Kind::parse) else { continue };
            let max = int(j.get("max")).or(int(d("max"))).unwrap_or(if j.get("byte").is_some() { 255 } else { 127 });
            inputs.push(Input {
                id: j.get("id").and_then(|v| v.as_str()).unwrap_or_default().to_owned(),
                kind,
                channel: int(j.get("channel")).or(int(d("channel"))).map(|v| v as u8),
                cc: int(j.get("cc")).map(|v| v as u8),
                note: int(j.get("note")).map(|v| v as u8),
                report: int(j.get("report")).or(int(d("report"))).map(|v| v as u8),
                byte: int(j.get("byte")).map(|v| v as usize),
                mask: int(j.get("mask")).unwrap_or(0xFF) as u8,
                max,
                center: int(j.get("center")).or_else(|| (kind.positional() && j.get("centered").and_then(|c| c.as_bool()) == Some(true)).then(|| int(d("center"))).flatten()),
                encoding: j.get("encoding").and_then(|e| e.as_str()).map(str::to_owned).or_else(|| matches!(kind, Kind::Encoder | Kind::Jog).then(|| d("encoding").and_then(|e| e.as_str()).map(str::to_owned)).flatten()),
                invert: j.get("invert").and_then(|v| v.as_bool()) == Some(true),
            });
        }
        let outputs = raw
            .outputs
            .iter()
            .map(|j| Output {
                id: j.get("id").and_then(|v| v.as_str()).unwrap_or_default().to_owned(),
                channel: int(j.get("channel")).or(int(d("channel"))).map(|v| v as u8),
                cc: int(j.get("cc")).map(|v| v as u8),
                note: int(j.get("note")).map(|v| v as u8),
                on: int(j.get("on")).or(int(d("on"))).unwrap_or(0x7F) as u8,
                off: int(j.get("off")).or(int(d("off"))).unwrap_or(0) as u8,
                report: int(j.get("report")).or(int(d("outputReport"))).map(|v| v as u8),
                length: int(j.get("length")).or(int(d("outputLength"))).map(|v| v as usize),
                byte: int(j.get("byte")).map(|v| v as usize),
                mask: int(j.get("mask")).unwrap_or(0xFF) as u8,
            })
            .collect();
        let usb = raw
            .matching
            .get("usb")
            .and_then(|u| u.as_array())
            .map(|a| a.iter().filter_map(|u| Some((hex(u.get("vid"))?, hex(u.get("pid"))?))).collect())
            .unwrap_or_default();
        let names = raw
            .matching
            .get("names")
            .and_then(|n| n.as_array())
            .map(|a| a.iter().filter_map(|n| n.as_str().map(str::to_owned)).collect())
            .unwrap_or_default();
        Ok(Layout { id: raw.id, name: raw.name, protocol, usb, names, inputs, outputs })
    }

    /// Whether a MIDI port or HID device named `name` is this controller.
    pub fn names_match(&self, name: &str) -> bool {
        let n = name.to_lowercase();
        self.names.iter().any(|m| n.contains(&m.to_lowercase()))
    }
}

/// The layouts the Desk knows: one JSON per device per protocol (controllers/).
pub fn bundled() -> Vec<Layout> {
    [
        include_str!("../../../controllers/hercules_dj_console_rmx.midi.json"),
        include_str!("../../../controllers/hercules_dj_console_rmx.hid.json"),
    ]
    .iter()
    .filter_map(|j| Layout::parse(j).map_err(|e| eprintln!("controller layout: {e}")).ok())
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_rmx_layouts_read() {
        let all = bundled();
        assert_eq!(all.len(), 2);
        let midi = all.iter().find(|l| l.protocol == Protocol::Midi).unwrap();
        let hid = all.iter().find(|l| l.protocol == Protocol::Hid).unwrap();
        assert_eq!(midi.usb, vec![(0x06f8, 0xb101)]);
        assert!(midi.names_match("Hercules DJ Console RMX MIDI 1") && !midi.names_match("Launchpad"));
        let play = midi.inputs.iter().find(|i| i.id == "deck.a.play").unwrap();
        assert_eq!((play.kind, play.cc), (Kind::Button, Some(0x0B)));
        let pitch = hid.inputs.iter().find(|i| i.id == "deck.a.pitch").unwrap();
        assert_eq!((pitch.byte, pitch.center, pitch.invert), (Some(9), Some(128), true));
        assert!(midi.inputs.len() > 50 && hid.inputs.len() > 50 && !hid.outputs.is_empty());
    }

    #[test]
    fn positions_centre_and_invert() {
        let midi = bundled().into_iter().find(|l| l.protocol == Protocol::Midi).unwrap();
        let gain = midi.inputs.iter().find(|i| i.id == "deck.a.gain").unwrap();
        assert_eq!(gain.position(63), 0.5, "centred on 0x3F");
        assert_eq!(gain.position(0), 0.0);
        assert_eq!(gain.position(127), 1.0);
        let pitch = midi.inputs.iter().find(|i| i.id == "deck.a.pitch").unwrap();
        assert_eq!(pitch.position(127), 0.0, "inverted");
    }

    #[test]
    fn turns() {
        let jog = Input { id: "j".into(), kind: Kind::Jog, channel: None, cc: None, note: None, report: None, byte: None, mask: 0xFF, max: 255, center: None, encoding: Some("wrap8".into()), invert: false };
        assert_eq!(jog.relative(2, Some(254)), 4, "a counter wrapping past 255");
        assert_eq!(jog.relative(250, Some(4)), -10);
        let signed = Input { encoding: Some("signed7".into()), ..jog };
        assert_eq!((signed.relative(1, None), signed.relative(0x7F, None)), (1, -1));
    }
}
