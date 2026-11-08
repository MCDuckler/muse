//! rekordbox's analysis files (`PIONEER/USBANLZ/…/ANLZ0000.DAT`, `.EXT`): tagged
//! sections, big endian. The Desk reads the beat grid (PQTZ) and the cues: the extended
//! list (PCO2, with colours and comments) where the `.EXT` has one, else the plain one
//! (PCOB). Waveforms are skipped: the Desk draws its own from the audio.
use crate::{Cue, CueKind};

trait Be {
    fn u8_at(&self, at: usize) -> Option<u8>;
    fn u16_at(&self, at: usize) -> Option<u16>;
    fn u32_at(&self, at: usize) -> Option<u32>;
}

impl Be for [u8] {
    fn u8_at(&self, at: usize) -> Option<u8> {
        self.get(at).copied()
    }
    fn u16_at(&self, at: usize) -> Option<u16> {
        Some(u16::from_be_bytes(self.get(at..at + 2)?.try_into().ok()?))
    }
    fn u32_at(&self, at: usize) -> Option<u32> {
        Some(u32::from_be_bytes(self.get(at..at + 4)?.try_into().ok()?))
    }
}

/// One beat of rekordbox's grid: where (ms, as stored), which beat of the bar (1–4),
/// and the tempo there (BPM).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Beat {
    pub ms: u32,
    pub of_bar: u8,
    pub bpm: f64,
}

/// What one analysis file holds that the Desk uses.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Anlz {
    pub beats: Vec<Beat>,
    /// The plain cue lists (PCOB): every file has them.
    pub cues: Vec<Cue>,
    /// The extended lists (PCO2): colours and comments too; in `.EXT` files.
    pub cues_ext: Vec<Cue>,
}

/// The sections of an analysis file, by tag.
fn sections(b: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = vec![];
    if b.get(0..4) != Some(b"PMAI") {
        return out;
    }
    let mut at = b.u32_at(4).unwrap_or(0) as usize;
    while let (Some(tag), Some(total)) = (b.get(at..at + 4), b.u32_at(at + 8)) {
        let total = total as usize;
        if total < 12 {
            break;
        }
        let Some(body) = b.get(at..at + total) else { break };
        out.push((tag.try_into().unwrap(), body));
        at += total;
    }
    out
}

pub fn read(b: &[u8]) -> Anlz {
    let mut a = Anlz::default();
    for (tag, s) in sections(b) {
        let head = s.u32_at(4).unwrap_or(0) as usize;
        match &tag {
            b"PQTZ" => {
                let n = s.u32_at(20).unwrap_or(0) as usize;
                a.beats = (0..n)
                    .map_while(|i| {
                        let e = head + i * 8;
                        Some(Beat { of_bar: s.u16_at(e)? as u8, bpm: s.u16_at(e + 2)? as f64 / 100.0, ms: s.u32_at(e + 4)? })
                    })
                    .collect();
            }
            b"PCOB" => {
                let hot = s.u32_at(12) == Some(1);
                let n = s.u16_at(18).unwrap_or(0) as usize;
                a.cues.extend(entries(s, head, n, b"PCPT").filter_map(|e| plain_cue(e, hot)));
            }
            b"PCO2" => {
                let hot = s.u32_at(12) == Some(1);
                let n = s.u16_at(16).unwrap_or(0) as usize;
                a.cues_ext.extend(entries(s, head, n, b"PCP2").filter_map(|e| ext_cue(e, hot)));
            }
            _ => {}
        }
    }
    a
}

/// A cue list's `n` entries from `at`, each its own tagged block.
fn entries<'a>(s: &'a [u8], mut at: usize, n: usize, tag: &'a [u8; 4]) -> impl Iterator<Item = &'a [u8]> + 'a {
    (0..n).map_while(move |_| {
        if s.get(at..at + 4)? != tag {
            return None;
        }
        let len = s.u32_at(at + 8)? as usize;
        let e = s.get(at..at + len.max(12))?;
        at += len.max(12);
        Some(e)
    })
}

fn kind(hot_cue: u32, hot_list: bool) -> Option<CueKind> {
    match (hot_cue, hot_list) {
        (0, _) => Some(CueKind::Memory),
        (n @ 1..=8, _) => Some(CueKind::Hot(n as u8 - 1)),
        _ => None,
    }
}

fn plain_cue(e: &[u8], hot_list: bool) -> Option<Cue> {
    // (the status word at 16 is no guide: rekordbox 7 writes 0 on live cues)
    let looped = e.u8_at(28)? == 2;
    let ms = e.u32_at(32)?;
    let end = e.u32_at(36)?;
    Some(Cue { kind: kind(e.u32_at(12)?, hot_list)?, ms, loop_end_ms: (looped && end > ms).then_some(end), rgb: None, comment: String::new() })
}

fn ext_cue(e: &[u8], hot_list: bool) -> Option<Cue> {
    let looped = e.u8_at(16)? == 2;
    let ms = e.u32_at(20)?;
    let end = e.u32_at(24)?;
    let mut cue = Cue { kind: kind(e.u32_at(12)?, hot_list)?, ms, loop_end_ms: (looped && end > ms).then_some(end), rgb: None, comment: String::new() };
    // older files stop after the loop fields
    if let Some(len) = e.u32_at(40).map(|l| l as usize) {
        if let Some(text) = e.get(44..44 + len) {
            let units: Vec<u16> = text.as_chunks::<2>().0.iter().map(|c| u16::from_be_bytes(*c)).collect();
            cue.comment = String::from_utf16_lossy(&units).trim_end_matches('\0').to_owned();
        }
        let c = 44 + len;
        if let (Some(index), Some(r), Some(g), Some(b)) = (e.u8_at(c), e.u8_at(c + 1), e.u8_at(c + 2), e.u8_at(c + 3))
            && index != 0
        {
            cue.rgb = Some(u32::from_be_bytes([0, r, g, b]));
        }
    }
    Some(cue)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn section(tag: &[u8; 4], head: &[u8], body: &[u8]) -> Vec<u8> {
        let mut s = tag.to_vec();
        s.extend(((12 + head.len()) as u32).to_be_bytes());
        s.extend(((12 + head.len() + body.len()) as u32).to_be_bytes());
        s.extend(head);
        s.extend(body);
        s
    }

    fn file(sections: &[Vec<u8>]) -> Vec<u8> {
        let mut f = b"PMAI".to_vec();
        f.extend(28u32.to_be_bytes());
        let total: usize = 28 + sections.iter().map(Vec::len).sum::<usize>();
        f.extend((total as u32).to_be_bytes());
        f.resize(28, 0);
        for s in sections {
            f.extend(s);
        }
        f
    }

    #[test]
    fn a_grid_and_cues_read_from_their_sections() {
        let mut beats = vec![];
        for (i, ms) in [35u32, 479, 923, 1368].iter().enumerate() {
            beats.extend((i as u16 % 4 + 1).to_be_bytes());
            beats.extend(13500u16.to_be_bytes());
            beats.extend(ms.to_be_bytes());
        }
        let mut grid_head = vec![0u8; 8];
        grid_head.extend(4u32.to_be_bytes());
        // a hot cue C at 1.5 s (a point) and a memory loop 2 s → 4 s
        let pcpt = |hot: u32, kind: u8, ms: u32, end: u32| {
            let mut e = b"PCPT".to_vec();
            e.extend(28u32.to_be_bytes());
            e.extend(56u32.to_be_bytes());
            e.extend(hot.to_be_bytes());
            e.extend(4u32.to_be_bytes()); // status: live
            e.extend(0x10000u32.to_be_bytes());
            e.extend([0xff, 0xff, 0xff, 0xff]);
            e.push(kind);
            e.extend([0, 0x03, 0xe8]);
            e.extend(ms.to_be_bytes());
            e.extend(end.to_be_bytes());
            e.resize(56, 0);
            e
        };
        let mut hot_head = 1u32.to_be_bytes().to_vec();
        hot_head.extend([0, 0, 0, 1, 0, 0, 0, 0]);
        let mut mem_head = 0u32.to_be_bytes().to_vec();
        mem_head.extend([0, 0, 0, 1, 0, 0, 0, 0]);
        let f = file(&[section(b"PQTZ", &grid_head, &beats), section(b"PCOB", &hot_head, &pcpt(3, 1, 1500, 0)), section(b"PCOB", &mem_head, &pcpt(0, 2, 2000, 4000))]);
        let a = read(&f);
        assert_eq!(a.beats.len(), 4);
        assert_eq!(a.beats[1], Beat { ms: 479, of_bar: 2, bpm: 135.0 });
        assert_eq!(a.cues.len(), 2);
        assert_eq!(a.cues[0].kind, CueKind::Hot(2));
        assert_eq!((a.cues[0].ms, a.cues[0].loop_end_ms), (1500, None));
        assert_eq!(a.cues[1].kind, CueKind::Memory);
        assert_eq!(a.cues[1].loop_end_ms, Some(4000));
    }

    #[test]
    fn an_extended_cue_brings_its_colour_and_comment() {
        let mut e = b"PCP2".to_vec();
        e.extend(16u32.to_be_bytes());
        let comment: Vec<u8> = "Drop\0".encode_utf16().flat_map(u16::to_be_bytes).collect();
        let len = 44 + comment.len() + 4 + 20;
        e.extend((len as u32).to_be_bytes());
        e.extend(1u32.to_be_bytes()); // A
        e.extend([1, 0, 0, 0]);
        e.extend(64_000u32.to_be_bytes());
        e.extend(0u32.to_be_bytes());
        e.extend([0u8; 12]);
        e.extend((comment.len() as u32).to_be_bytes());
        e.extend(&comment);
        e.extend([0x2a, 0xff, 0x8c, 0x00]);
        e.resize(len, 0);
        let mut head = 1u32.to_be_bytes().to_vec();
        head.extend([0, 1, 0, 0]);
        let a = read(&file(&[section(b"PCO2", &head, &e)]));
        assert_eq!(a.cues_ext.len(), 1);
        let c = &a.cues_ext[0];
        assert_eq!((c.kind, c.ms, c.comment.as_str(), c.rgb), (CueKind::Hot(0), 64_000, "Drop", Some(0xff8c00)));
    }

    #[test]
    fn a_damaged_file_reads_as_nothing_rather_than_failing() {
        assert_eq!(read(b"not an analysis file"), Anlz::default());
        let mut f = file(&[]);
        f.extend(b"PQTZ\0\0\0\x18\xff\xff\xff\xff");
        assert_eq!(read(&f).beats, vec![]);
    }
}
