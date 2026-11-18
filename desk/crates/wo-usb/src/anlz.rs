//! rekordbox's analysis files (`PIONEER/USBANLZ/…/ANLZ0000.DAT`, `.EXT`): tagged
//! sections, big endian. The Desk reads the beat grid (PQTZ) and the cues: the extended
//! list (PCO2, with colours and comments) where the `.EXT` has one, else the plain one
//! (PCOB). And rekordbox's own waveforms, 150 columns a second, so the Desk draws a
//! stick's records exactly as rekordbox does: the blue one (PWV3, `.EXT`), the colour one
//! (PWV5, `.EXT`) and the three-band one (PWV7, `.2EX`); and the phrases (PSSI, `.EXT`,
//! masked). The previews (PWAV, PWV4, PWV6) are left: the Desk sums its overviews from
//! the columns.
//!
//! Formats: Deep Symmetry's crate-digger (rekordbox_anlz.ksy). PWV7's band order was
//! measured on a real stick (75 records): its first byte follows PWV5's red and goes
//! against PWV3's whiteness (the lows), the second follows green (the mids), the third
//! blue and whiteness (the highs).
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
    pub waves: Waves,
    pub phrases: Option<Phrases>,
    /// The audio file's path (PPTH). On a stick the whole path under its root; in
    /// rekordbox's own library only `?/<file name>`.
    pub path: Option<String>,
}

/// rekordbox's scrolling waveforms, one entry a column, 150 columns a second (empty where
/// the file has none).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Waves {
    /// PWV3: the blue one; height in the low 5 bits (0–31), whiteness in the high 3.
    pub blue: Vec<u8>,
    /// PWV5: the colour one, big endian u16: red 15–13, green 12–10, blue 9–7 (0–7 each),
    /// height 6–2 (0–31).
    pub rgb: Vec<u16>,
    /// PWV7: the three bands' heights, lows, mids, highs (0–127 near enough).
    pub bands: Vec<[u8; 3]>,
    /// PWVC: three numbers rekordbox keeps beside the bands (one a band, about 80–250;
    /// what they scale is not known).
    pub band_scale: Option<[u16; 3]>,
}

impl Waves {
    pub fn is_empty(&self) -> bool {
        self.blue.is_empty() && self.rgb.is_empty() && self.bands.is_empty()
    }

    /// Another file's waves added where this one has none.
    fn take(&mut self, o: Waves) {
        if self.blue.is_empty() {
            self.blue = o.blue;
        }
        if self.rgb.is_empty() {
            self.rgb = o.rgb;
        }
        if self.bands.is_empty() {
            self.bands = o.bands;
        }
        if self.band_scale.is_none() {
            self.band_scale = o.band_scale;
        }
    }
}

/// The record's phrases, as rekordbox's phrase analysis found them (PSSI).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Phrases {
    /// 1 high, 2 mid, 3 low: which words its phrases are named with.
    pub mood: u16,
    /// The beat (from 1) the last phrase ends on.
    pub end_beat: u16,
    pub list: Vec<Phrase>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Phrase {
    /// The beat it starts on, from 1 (rekordbox's grid).
    pub beat: u16,
    pub kind: PhraseKind,
    /// Where a fill-in starts toward its end (a beat, from 1), if it has one.
    pub fill: Option<u16>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhraseKind {
    Intro,
    Verse(u8),
    Bridge,
    Chorus,
    Up,
    Down,
    Outro,
    Other(u16),
}

impl PhraseKind {
    fn of(mood: u16, id: u16) -> PhraseKind {
        use PhraseKind::*;
        match (mood, id) {
            (1, 1) => Intro,
            (1, 2) => Up,
            (1, 3) => Down,
            (1, 5) => Chorus,
            (1, 6) => Outro,
            (3, 1) => Intro,
            (3, 2..=4) => Verse(1),
            (3, 5..=7) => Verse(2),
            (3, 8) => Bridge,
            (3, 9) => Chorus,
            (3, 10) => Outro,
            (_, 1) => Intro,
            (_, n @ 2..=7) => Verse(n as u8 - 1),
            (_, 8) => Bridge,
            (_, 9) => Chorus,
            (_, 10) => Outro,
            (_, n) => Other(n),
        }
    }

    /// Its name as rekordbox shows it.
    pub fn name(self) -> String {
        use PhraseKind::*;
        match self {
            Intro => "Intro".into(),
            Verse(n) => format!("Verse {n}"),
            Bridge => "Bridge".into(),
            Chorus => "Chorus".into(),
            Up => "Up".into(),
            Down => "Down".into(),
            Outro => "Outro".into(),
            Other(n) => format!("Phrase {n}"),
        }
    }
}

/// PSSI's mask (rekordbox 6 on), each byte plus the number of phrases.
const PSSI_MASK: [u8; 19] = [0xCB, 0xE1, 0xEE, 0xFA, 0xE5, 0xEE, 0xAD, 0xEE, 0xE9, 0xD2, 0xE9, 0xEB, 0xE1, 0xE9, 0xF3, 0xE8, 0xE9, 0xF4, 0xE1];

/// A PSSI section into its phrases; None where it does not read as phrases (a wrong
/// mask, a damaged file): no phrases rather than wrong ones.
fn phrases(s: &[u8]) -> Option<Phrases> {
    let entry = s.u32_at(12)? as usize;
    let n = s.u16_at(16)?;
    let mut body = s.get(18..)?.to_vec();
    // masked files have a mood far past 3
    if body.u16_at(0)? > 20 {
        for (i, b) in body.iter_mut().enumerate() {
            *b ^= PSSI_MASK[i % PSSI_MASK.len()].wrapping_add(n as u8);
        }
    }
    let mood = body.u16_at(0)?;
    if !(1..=3).contains(&mood) || entry < 24 {
        return None;
    }
    let end_beat = body.u16_at(8)?;
    let mut list = Vec::with_capacity(n as usize);
    for i in 0..n as usize {
        let e = body.get(14 + i * entry..14 + (i + 1) * entry)?;
        let beat = e.u16_at(2)?;
        let fill = (e.u8_at(21)? != 0).then(|| e.u16_at(22)).flatten();
        list.push(Phrase { beat, kind: PhraseKind::of(mood, e.u16_at(4)?), fill });
    }
    // starts go up, from beat 1
    if list.windows(2).any(|w| w[1].beat <= w[0].beat) || list.first().is_some_and(|p| p.beat == 0) {
        return None;
    }
    Some(Phrases { mood, end_beat, list })
}

/// A scrolling waveform's entries: (bytes an entry, how many) at 12 and 16, the data
/// after the section's header.
fn wave_entries(s: &[u8], head: usize, size: usize) -> Option<&[u8]> {
    if s.u32_at(12)? as usize != size {
        return None;
    }
    let n = s.u32_at(16)? as usize;
    let end = head.checked_add(n.checked_mul(size)?)?;
    s.get(head..end.min(s.len()))
}

/// The PPTH section's UTF-16 path.
fn path(s: &[u8]) -> Option<String> {
    let head = s.u32_at(4)? as usize;
    let len = s.u32_at(12)? as usize;
    let text = s.get(head..head + len)?;
    let units: Vec<u16> = text.as_chunks::<2>().0.iter().map(|c| u16::from_be_bytes(*c)).collect();
    Some(String::from_utf16_lossy(&units).trim_end_matches('\0').to_owned())
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
            b"PWV3" => {
                if let Some(d) = wave_entries(s, head, 1) {
                    a.waves.blue = d.to_vec();
                }
            }
            b"PWV5" => {
                if let Some(d) = wave_entries(s, head, 2) {
                    a.waves.rgb = d.as_chunks::<2>().0.iter().map(|c| u16::from_be_bytes(*c)).collect();
                }
            }
            b"PWV7" => {
                if let Some(d) = wave_entries(s, head, 3) {
                    a.waves.bands = d.as_chunks::<3>().0.to_vec();
                }
            }
            b"PWVC" => {
                if let (Some(x), Some(y), Some(z)) = (s.u16_at(head), s.u16_at(head + 2), s.u16_at(head + 4)) {
                    a.waves.band_scale = Some([x, y, z]);
                }
            }
            b"PPTH" => a.path = path(s),
            b"PSSI" => a.phrases = phrases(s),
            _ => {}
        }
    }
    a
}

/// Another of a record's files read into this one: its waves and phrases where this has
/// none (the cues and grid stay apart: the caller picks).
pub(crate) fn merge_waves(a: &mut Anlz, other: Anlz) {
    a.waves.take(other.waves);
    if a.phrases.is_none() {
        a.phrases = other.phrases;
    }
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

    fn wave_section(tag: &[u8; 4], size: u32, n: u32, data: &[u8]) -> Vec<u8> {
        let mut head = size.to_be_bytes().to_vec();
        head.extend(n.to_be_bytes());
        head.extend(0x0096_0000u32.to_be_bytes());
        section(tag, &head, data)
    }

    #[test]
    fn the_waveforms_read_column_by_column() {
        let blue = [0x3f, 0xe1];
        let rgb: Vec<u8> = [0xe07cu16, 0x1234].iter().flat_map(|v| v.to_be_bytes()).collect();
        let bands = [90, 40, 9, 1, 2, 3];
        let mut pwvc = vec![0, 0];
        pwvc.extend([0, 0x50, 0, 0x7c, 0, 0xb2]);
        let f = file(&[wave_section(b"PWV3", 1, 2, &blue), wave_section(b"PWV5", 2, 2, &rgb), wave_section(b"PWV7", 3, 2, &bands), section(b"PWVC", &pwvc[..2], &pwvc[2..])]);
        let a = read(&f);
        assert_eq!(a.waves.blue, vec![0x3f, 0xe1]);
        assert_eq!(a.waves.rgb, vec![0xe07c, 0x1234]);
        assert_eq!(a.waves.bands, vec![[90, 40, 9], [1, 2, 3]]);
        assert_eq!(a.waves.band_scale, Some([80, 124, 178]));
        // the wrong entry size: not read as this kind
        assert!(read(&file(&[wave_section(b"PWV5", 3, 2, &rgb)])).waves.rgb.is_empty());
        // fewer bytes than it says: what is there
        assert_eq!(read(&file(&[wave_section(b"PWV3", 1, 9, &blue)])).waves.blue.len(), 2);
    }

    fn pssi(mood: u16, list: &[(u16, u16)], mask: bool) -> Vec<u8> {
        let n = list.len() as u16;
        let mut body = mood.to_be_bytes().to_vec();
        body.extend([0u8; 6]);
        body.extend(200u16.to_be_bytes());
        body.extend([0u8; 2]);
        body.extend([0, 0]);
        for (i, &(beat, kind)) in list.iter().enumerate() {
            let mut e = ((i + 1) as u16).to_be_bytes().to_vec();
            e.extend(beat.to_be_bytes());
            e.extend(kind.to_be_bytes());
            e.resize(24, 0);
            body.extend(e);
        }
        if mask {
            for (i, b) in body.iter_mut().enumerate() {
                *b ^= PSSI_MASK[i % 19].wrapping_add(n as u8);
            }
        }
        let mut head = 24u32.to_be_bytes().to_vec();
        head.extend(n.to_be_bytes());
        // (the header proper is 32 long; the body starts right after the count)
        let mut s = b"PSSI".to_vec();
        s.extend(32u32.to_be_bytes());
        s.extend(((12 + head.len() + body.len()) as u32).to_be_bytes());
        s.extend(head);
        s.extend(body);
        s
    }

    #[test]
    fn phrases_read_masked_or_not() {
        for mask in [false, true] {
            let a = read(&file(&[pssi(1, &[(1, 1), (33, 2), (65, 5), (129, 6)], mask)]));
            let p = a.phrases.expect("phrases");
            assert_eq!((p.mood, p.end_beat), (1, 200));
            let kinds: Vec<_> = p.list.iter().map(|x| (x.beat, x.kind)).collect();
            assert_eq!(kinds, vec![(1, PhraseKind::Intro), (33, PhraseKind::Up), (65, PhraseKind::Chorus), (129, PhraseKind::Outro)]);
        }
        let mid = read(&file(&[pssi(2, &[(1, 1), (17, 3), (49, 8)], true)])).phrases.unwrap();
        assert_eq!(mid.list.iter().map(|p| p.kind.name()).collect::<Vec<_>>(), ["Intro", "Verse 2", "Bridge"]);
        // phrases going backwards: not believed
        assert!(read(&file(&[pssi(2, &[(40, 1), (17, 3)], true)])).phrases.is_none());
    }

    #[test]
    fn the_path_reads_from_ppth() {
        let text: Vec<u8> = "?/03 XXL.m4a\0".encode_utf16().flat_map(u16::to_be_bytes).collect();
        let head = (text.len() as u32).to_be_bytes();
        let a = read(&file(&[section(b"PPTH", &head, &text)]));
        assert_eq!(a.path.as_deref(), Some("?/03 XXL.m4a"));
    }

    /// The head of "03 XXL"'s PSSI as rekordbox 7.2.2 wrote it into its own library (plain,
    /// mid mood, ending on beat 305).
    #[test]
    fn rekordbox_libraries_plain_phrases_read() {
        let entries = [(1u16, 1u16), (16, 9), (80, 9), (112, 8)];
        let mut head = 24u32.to_be_bytes().to_vec();
        head.extend((entries.len() as u16).to_be_bytes());
        head.extend(2u16.to_be_bytes());
        head.extend([0, 0, 0, 0, 0, 0]);
        head.extend(0x131u16.to_be_bytes());
        head.extend([1, 1, 0, 0]);
        let mut body = vec![];
        for (i, (beat, kind)) in entries.iter().enumerate() {
            let mut e = ((i + 1) as u16).to_be_bytes().to_vec();
            e.extend(beat.to_be_bytes());
            e.extend(kind.to_be_bytes());
            e.resize(24, 0);
            body.extend(e);
        }
        let p = read(&file(&[section(b"PSSI", &head, &body)])).phrases.expect("phrases");
        assert_eq!((p.mood, p.end_beat), (2, 305));
        let got: Vec<_> = p.list.iter().map(|x| (x.beat, x.kind)).collect();
        assert_eq!(got, [(1, PhraseKind::Intro), (16, PhraseKind::Chorus), (80, PhraseKind::Chorus), (112, PhraseKind::Bridge)]);
    }

    #[test]
    fn a_damaged_file_reads_as_nothing_rather_than_failing() {
        assert_eq!(read(b"not an analysis file"), Anlz::default());
        let mut f = file(&[]);
        f.extend(b"PQTZ\0\0\0\x18\xff\xff\xff\xff");
        assert_eq!(read(&f).beats, vec![]);
    }
}
