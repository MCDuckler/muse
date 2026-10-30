//! Bytes from a controller as named events, and lights back as bytes: a MIDI message
//! per control, or a HID report compared with the one before it.
use std::collections::HashMap;

use crate::layout::{Input, Kind, Layout, Protocol};

/// One control moving: a button's 1 or 0, a pot's or fader's 0..1, an encoder's or a
/// jog wheel's turn in ticks.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub id: String,
    pub kind: Kind,
    pub value: f64,
}

impl Event {
    pub fn pressed(&self) -> bool {
        self.kind == Kind::Button && self.value > 0.5
    }
}

pub struct Decoder {
    layout: Layout,
    /// MIDI: (status kind, channel or 16, number) → input.
    midi: HashMap<(u8, u8, u8), usize>,
    /// HID: report id → byte → inputs.
    hid: HashMap<u8, HashMap<usize, Vec<usize>>>,
    last_report: HashMap<u8, Vec<u8>>,
    last_raw: HashMap<String, u32>,
    /// HID lights: the output reports as they stand.
    lights: HashMap<u8, Vec<u8>>,
}

impl Decoder {
    pub fn new(layout: Layout) -> Decoder {
        let mut midi = HashMap::new();
        let mut hid: HashMap<u8, HashMap<usize, Vec<usize>>> = HashMap::new();
        for (i, input) in layout.inputs.iter().enumerate() {
            match layout.protocol {
                Protocol::Midi => {
                    let (kind, number) = match (input.cc, input.note) {
                        (Some(cc), _) => (0xB0, cc),
                        (None, Some(n)) => (0x90, n),
                        _ => continue,
                    };
                    midi.insert((kind, input.channel.unwrap_or(16), number), i);
                }
                Protocol::Hid => {
                    if let Some(b) = input.byte {
                        hid.entry(input.report.unwrap_or(0)).or_default().entry(b).or_default().push(i);
                    }
                }
            }
        }
        Decoder { layout, midi, hid, last_report: HashMap::new(), last_raw: HashMap::new(), lights: HashMap::new() }
    }

    pub fn layout(&self) -> &Layout {
        &self.layout
    }

    pub fn decode(&mut self, bytes: &[u8]) -> Vec<Event> {
        match self.layout.protocol {
            Protocol::Midi => self.decode_midi(bytes),
            Protocol::Hid => self.decode_hid(bytes),
        }
    }

    fn decode_midi(&mut self, m: &[u8]) -> Vec<Event> {
        if m.len() < 3 {
            return vec![];
        }
        let (status, channel) = (m[0] & 0xF0, m[0] & 0x0F);
        let kind = match status {
            0xB0 => 0xB0,
            0x90 | 0x80 => 0x90,
            _ => return vec![],
        };
        let Some(&i) = self.midi.get(&(kind, channel, m[1])).or_else(|| self.midi.get(&(kind, 16, m[1]))) else { return vec![] };
        let raw = if status == 0x80 { 0 } else { m[2] as u32 };
        let input = &self.layout.inputs[i];
        self.event(input.clone(), raw).into_iter().collect()
    }

    fn decode_hid(&mut self, report: &[u8]) -> Vec<Event> {
        let Some(&id) = report.first() else { return vec![] };
        let was = self.last_report.insert(id, report.to_vec());
        let Some(bytes) = self.hid.get(&id) else { return vec![] };
        let mut out = vec![];
        let mut wanted: Vec<(usize, usize)> = bytes.iter().flat_map(|(&b, v)| v.iter().map(move |&i| (b, i))).collect();
        wanted.sort();
        for (b, i) in wanted {
            let Some(&now) = report.get(b) else { continue };
            if was.as_ref().and_then(|w| w.get(b)) == Some(&now) {
                continue;
            }
            let input = self.layout.inputs[i].clone();
            let raw = ((now & input.mask) >> input.mask.trailing_zeros()) as u32;
            let before = self.last_raw.get(&input.id).copied();
            // the first report only says where everything is
            if before.is_none() && matches!(input.kind, Kind::Button | Kind::Encoder | Kind::Jog) {
                self.last_raw.insert(input.id.clone(), raw);
                continue;
            }
            if before == Some(raw) {
                continue;
            }
            out.extend(self.event(input, raw));
        }
        out
    }

    fn event(&mut self, input: Input, raw: u32) -> Option<Event> {
        let last = self.last_raw.insert(input.id.clone(), raw);
        let value = match input.kind {
            Kind::Button => (raw > 0) as u8 as f64,
            Kind::Pot | Kind::Fader => input.position(raw),
            Kind::Encoder | Kind::Jog => {
                let d = input.relative(raw, last);
                if d == 0 {
                    return None;
                }
                d as f64
            }
        };
        Some(Event { id: input.id, kind: input.kind, value })
    }

    /// The bytes that set light `id` on or off: a MIDI message, or the whole output
    /// report it lives in (the other lights in it as they were). None for no such light.
    pub fn light(&mut self, id: &str, on: bool) -> Option<Vec<u8>> {
        let o = self.layout.outputs.iter().find(|o| o.id == id)?.clone();
        match self.layout.protocol {
            Protocol::Midi => {
                let ch = o.channel.unwrap_or(0) & 0x0F;
                let v = if on { o.on } else { o.off };
                match (o.cc, o.note) {
                    (Some(cc), _) => Some(vec![0xB0 | ch, cc, v]),
                    (None, Some(n)) => Some(vec![0x90 | ch, n, v]),
                    _ => None,
                }
            }
            Protocol::Hid => {
                let report = o.report.unwrap_or(0);
                let len = o.length.unwrap_or(2).max(2);
                let buf = self.lights.entry(report).or_insert_with(|| {
                    let mut b = vec![0u8; len];
                    b[0] = report;
                    b
                });
                let byte = o.byte?;
                if byte >= buf.len() {
                    return None;
                }
                if on { buf[byte] |= o.mask } else { buf[byte] &= !o.mask }
                Some(buf.clone())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::bundled;

    fn decoder(p: Protocol) -> Decoder {
        Decoder::new(bundled().into_iter().find(|l| l.protocol == p).unwrap())
    }

    #[test]
    fn midi_buttons_pots_and_jogs() {
        let mut d = decoder(Protocol::Midi);
        assert_eq!(d.decode(&[0xB0, 0x0B, 0x7F]), vec![Event { id: "deck.a.play".into(), kind: Kind::Button, value: 1.0 }]);
        assert!(!d.decode(&[0xB0, 0x0B, 0x00])[0].pressed());
        let gain = d.decode(&[0xB0, 0x33, 63]);
        assert_eq!((gain[0].id.as_str(), gain[0].value), ("deck.a.gain", 0.5));
        let jog = d.decode(&[0xB0, 0x2F, 0x7E]);
        assert_eq!((jog[0].id.as_str(), jog[0].value), ("deck.a.jog", -2.0));
        assert!(d.decode(&[0xB0, 0x7E, 0x7F]).is_empty(), "a CC nobody named");
        assert_eq!(d.light("deck.a.play", true), Some(vec![0xB0, 0x0B, 0x7F]));
    }

    #[test]
    fn hid_reports_by_difference() {
        let mut d = decoder(Protocol::Hid);
        let mut r = vec![0u8; 24];
        r[0] = 1;
        assert!(d.decode(&r).iter().all(|e| e.kind.positional()), "the first report: where the pots are, no presses");
        r[1] = 0x01; // deck.a.pad.1 down
        let e = d.decode(&r);
        assert_eq!(e.len(), 1);
        assert!(e[0].pressed() && e[0].id == "deck.a.pad.1");
        assert!(d.decode(&r).is_empty(), "the same report again: nothing moved");
        r[7] = 5; // deck.a.jog counter on by 5
        let jog = d.decode(&r);
        assert_eq!((jog[0].id.as_str(), jog[0].value), ("deck.a.jog", 5.0));
        let lit = d.light("deck.a.play", true).unwrap();
        assert_eq!((lit[0], lit[1] & 0x02), (0, 0x02));
    }
}
