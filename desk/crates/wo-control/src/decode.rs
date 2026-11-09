//! Bytes from a controller as named events, and lights back as bytes: a MIDI message
//! per control (a 14-bit one's two halves: its MSB kept, its LSB read with it), or a HID
//! report compared with the one before it.
use std::collections::HashMap;

use crate::layout::{Input, Kind, Layout, Output, Protocol};

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
    /// MIDI: (status kind, channel or 16, number) → input, and whether it is the LSB of
    /// a 14-bit one.
    midi: HashMap<(u8, u8, u8), (usize, bool)>,
    /// 14-bit controls' MSBs as last sent, by input.
    msb: HashMap<usize, u8>,
    /// The control whose MSB the last message was (nothing moved yet: its LSB says).
    half: Option<String>,
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
                    let ch = input.channel.unwrap_or(16);
                    midi.insert((kind, ch, number), (i, false));
                    if let (Some(lsb), Some(_)) = (input.lsb, input.cc) {
                        midi.insert((0xB0, ch, lsb), (i, true));
                    }
                }
                Protocol::Hid => {
                    if let Some(b) = input.byte {
                        hid.entry(input.report.unwrap_or(0)).or_default().entry(b).or_default().push(i);
                    }
                }
            }
        }
        Decoder { layout, midi, msb: HashMap::new(), half: None, hid, last_report: HashMap::new(), last_raw: HashMap::new(), lights: HashMap::new() }
    }

    pub fn layout(&self) -> &Layout {
        &self.layout
    }

    /// The 14-bit control the last message was the first half of, if it was.
    pub fn half(&self) -> Option<&str> {
        self.half.as_deref()
    }

    pub fn decode(&mut self, bytes: &[u8]) -> Vec<Event> {
        self.half = None;
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
        let Some(&(i, low)) = self.midi.get(&(kind, channel, m[1])).or_else(|| self.midi.get(&(kind, 16, m[1]))) else { return vec![] };
        let mut raw = if status == 0x80 { 0 } else { m[2] as u32 & 0x7F };
        let input = &self.layout.inputs[i];
        if input.lsb.is_some() && kind == 0xB0 {
            // a 14-bit control: the MSB comes first and is kept; the LSB says the whole
            if !low {
                self.msb.insert(i, raw as u8);
                self.half = Some(input.id.clone());
                return vec![];
            }
            raw |= (*self.msb.get(&i).unwrap_or(&0) as u32) << 7;
        }
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
                let d = input.ticks(raw, last);
                if d == 0.0 {
                    return None;
                }
                d
            }
        };
        Some(Event { id: input.id, kind: input.kind, value })
    }

    /// The bytes that set light `id` on or off: a MIDI message for each of its lights (a
    /// button may have one under each of its notes), or the whole output report each
    /// lives in (the other lights in it as they were). Empty for no such light.
    pub fn light(&mut self, id: &str, on: bool) -> Vec<Vec<u8>> {
        self.send(id, |o| if on { o.on } else { o.off }, Some(on))
    }

    /// The bytes that show `level` (0..1) on meter `id`: its `off`..`on` across it.
    pub fn level(&mut self, id: &str, level: f32) -> Vec<Vec<u8>> {
        let l = level.clamp(0.0, 1.0);
        self.send(id, |o| (o.off as f32 + (o.on as f32 - o.off as f32) * l).round() as u8, None)
    }

    fn send(&mut self, id: &str, value: impl Fn(&Output) -> u8, on: Option<bool>) -> Vec<Vec<u8>> {
        let outs: Vec<Output> = self.layout.outputs.iter().filter(|o| o.id == id && o.meter == on.is_none()).cloned().collect();
        let mut msgs: Vec<Vec<u8>> = vec![];
        for o in outs {
            match self.layout.protocol {
                Protocol::Midi => {
                    let ch = o.channel.unwrap_or(0) & 0x0F;
                    let v = value(&o) & 0x7F;
                    match (o.cc, o.note) {
                        (Some(cc), _) => msgs.push(vec![0xB0 | ch, cc, v]),
                        (None, Some(n)) => msgs.push(vec![0x90 | ch, n, v]),
                        _ => {}
                    }
                }
                Protocol::Hid => {
                    let Some(on) = on else { continue };
                    let report = o.report.unwrap_or(0);
                    let len = o.length.unwrap_or(2).max(2);
                    let buf = self.lights.entry(report).or_insert_with(|| {
                        let mut b = vec![0u8; len];
                        b[0] = report;
                        b
                    });
                    let Some(byte) = o.byte.filter(|&b| b < buf.len()) else { continue };
                    if on { buf[byte] |= o.mask } else { buf[byte] &= !o.mask }
                    // one report however many of its lights changed
                    msgs.retain(|m| m.first() != Some(&report));
                    msgs.push(buf.clone());
                }
            }
        }
        msgs
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::bundled;

    fn decoder(p: Protocol) -> Decoder {
        Decoder::new(bundled().into_iter().find(|l| l.protocol == p && l.id.contains("rmx")).unwrap())
    }

    fn ddj() -> Decoder {
        Decoder::new(bundled().into_iter().find(|l| l.id == "pioneer_ddj_400_midi").unwrap())
    }

    #[test]
    fn the_ddj_400s_fourteen_bits_jogs_and_shift() {
        let mut d = ddj();
        // TEMPO on deck 2: MSB kept, LSB reads the whole; the middle is 0x2000
        assert!(d.decode(&[0xB1, 0x00, 0x40]).is_empty(), "the MSB alone says nothing");
        assert_eq!(d.half(), Some("deck.b.pitch"), "but the monitor is told whose it was");
        let e = d.decode(&[0xB1, 0x20, 0x00]);
        assert_eq!((e[0].id.as_str(), e[0].value), ("deck.b.pitch", 0.5));
        d.decode(&[0xB1, 0x00, 0x00]);
        let e = d.decode(&[0xB1, 0x20, 0x00]);
        assert_eq!(e[0].value, 1.0, "all the way down (0) is the fastest: inverted");
        // the channel fader: 14 bits across 0..1
        d.decode(&[0xB0, 0x13, 0x7F]);
        let e = d.decode(&[0xB0, 0x33, 0x7F]);
        assert_eq!((e[0].id.as_str(), e[0].value), ("deck.a.volume", 1.0));
        // the filter is on the mixer's channel
        d.decode(&[0xB6, 0x18, 0x7F]);
        assert_eq!(d.decode(&[0xB6, 0x38, 0x7F])[0].id, "deck.b.filter");
        // the jog: 720 a turn, given as the booth's 128
        let e = d.decode(&[0xB0, 0x22, 0x40 + 45]);
        assert_eq!((e[0].id.as_str(), e[0].kind, e[0].value), ("deck.a.jog.scratch", Kind::Jog, 8.0));
        assert_eq!(d.decode(&[0xB0, 0x21, 0x40 - 45])[0].value, -8.0, "the side, backwards");
        assert!(d.decode(&[0xB0, 0x23, 0x40]).is_empty(), "no turn");
        // SHIFT is a control; its pads come on their own channel as the same hot cue
        assert!(d.decode(&[0x90, 0x3F, 0x7F])[0].pressed());
        let shifted = d.decode(&[0x98, 0x04, 0x7F]);
        assert_eq!((shifted[0].id.as_str(), shifted[0].pressed()), ("deck.a.hotcue.5", true));
        assert_eq!(d.decode(&[0x99, 0x61, 0x7F])[0].id, "deck.b.beatloop.0.5");
        assert_eq!(d.decode(&[0x97, 0x26, 0x7F])[0].id, "deck.a.beatjump.-8");
        assert_eq!(d.decode(&[0x99, 0x33, 0x7F])[0].id, "show.blackout");
        // the browser turned back one: two's complement
        assert_eq!(d.decode(&[0xB6, 0x40, 0x7F])[0].value, -1.0);
        // a note off as a note on of nothing
        assert!(!d.decode(&[0x91, 0x0B, 0x00])[0].pressed());
    }

    #[test]
    fn the_ddj_400s_lights() {
        let mut d = ddj();
        assert_eq!(d.light("deck.b.play", true), vec![vec![0x91, 0x0B, 0x7F], vec![0x91, 0x47, 0x7F]], "plain and SHIFT's note");
        assert_eq!(d.light("deck.a.hotcue.3", true), vec![vec![0x97, 0x02, 0x7F], vec![0x98, 0x02, 0x7F]]);
        assert_eq!(d.light("deck.b.loaded", true), vec![vec![0x9F, 0x01, 0x7F]]);
        assert_eq!(d.level("deck.a.meter", 0.5), vec![vec![0xB0, 0x02, 64]]);
        assert!(d.light("deck.a.meter", true).is_empty(), "a meter is not a light");
        assert!(d.level("deck.a.play", 1.0).is_empty(), "nor a light a meter");
        assert!(d.light("deck.a.keylock", true).is_empty(), "no such light");
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
        assert_eq!(d.light("deck.a.play", true), vec![vec![0xB0, 0x0B, 0x7F]]);
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
        let lit = d.light("deck.a.play", true).remove(0);
        assert_eq!((lit[0], lit[1] & 0x02), (0, 0x02));
    }
}
