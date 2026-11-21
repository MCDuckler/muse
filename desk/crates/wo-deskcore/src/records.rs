//! Records the bake-off plays and lists: the WetOwl app's own fetched records with
//! their cached beats, where this computer has them, else two synthesised ones.
use std::path::{Path, PathBuf};

/// A crate row's facts (the house's, for the fixture rows).
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Record {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub bpm: f64,
    /// Camelot, "" when not known.
    pub key: String,
    pub seconds: u32,
    pub audio: Audio,
    /// The house has a cover for it; the cover's colour (0xRRGGBB).
    pub cover: bool,
    pub cover_rgb: Option<u32>,
    /// How loud it is, as the house measured it (none for a record of this computer's).
    #[serde(default)]
    pub loudness: Loudness,
    /// What else is known of it (the browser's other columns, rekordbox's).
    #[serde(default)]
    pub tags: Tags,
}

/// A record's other facts, where they are known: a stick's (rekordbox's) and the house's.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Tags {
    pub album: String,
    pub genre: String,
    /// rekordbox's stars, 0–5.
    pub rating: u8,
    pub comment: String,
    /// When it was added, "YYYY-MM-DD".
    pub added: String,
}

/// A record's loudness, as the box measured it: the gain that brings it to the house's
/// reference (−14 LUFS, the one the phones' player turns songs by), and its true peak.
/// Auto Gain (autogain.rs) takes the gain until this Desk has measured the record itself.
#[derive(Clone, Copy, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Loudness {
    pub gain_db: Option<f32>,
    pub true_peak_db: Option<f32>,
}

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum Audio {
    /// Not on this computer: listed only.
    None,
    /// A fetched record and its cached beats (raw, one tempo fitted through them).
    File { path: PathBuf, beats: Vec<f64>, bar_one: usize },
    /// Made here: a techno loop at a tempo, its grid exact.
    Synth { seed: u32 },
    /// On the house: its analysis and audio fetched when it goes on a deck.
    House { id: i64 },
    /// On a rekordbox USB stick: the audio, its analysis (`.DAT`, the grid and cues read
    /// when it goes on a deck) and its cover, each a full path on the stick.
    Usb { path: PathBuf, anlz: Option<PathBuf>, artwork: Option<PathBuf> },
}

impl Record {
    /// A house record (its key comes with the analysis, when it is loaded).
    pub fn from_house(t: &wo_house::Track) -> Record {
        Record {
            id: t.id,
            title: t.title.clone(),
            artist: t.artist(),
            bpm: t.bpm.unwrap_or(0.0),
            key: String::new(),
            seconds: (t.duration_ms.unwrap_or(0).max(0) / 1000) as u32,
            audio: if t.ready() { Audio::House { id: t.id } } else { Audio::None },
            cover: t.cover_url.is_some(),
            cover_rgb: t.cover_rgb(),
            loudness: Loudness { gain_db: t.gain_db.map(|g| g as f32), true_peak_db: t.true_peak_db.map(|p| p as f32) },
            tags: Tags { album: t.album.clone().unwrap_or_default(), ..Default::default() },
        }
    }

    /// A record on a stick. Its id is negative (the house's are positive, the synth's
    /// −1 and −2) and the same each time this stick is plugged in: the stick's name and
    /// rekordbox's id for the record.
    pub fn from_usb(stick: &str, t: &wo_usb::Track) -> Record {
        Record {
            id: usb_id(stick, t.id),
            title: t.title.clone(),
            artist: t.artist.clone(),
            bpm: t.bpm,
            key: t.key.clone(),
            seconds: t.seconds,
            audio: Audio::Usb { path: t.path.clone(), anlz: t.anlz.clone(), artwork: t.artwork.clone() },
            cover: t.artwork.is_some(),
            cover_rgb: None,
            loudness: Loudness::default(),
            tags: Tags { album: t.album.clone(), genre: t.genre.clone(), rating: t.rating.min(5), comment: t.comment.clone(), added: t.date_added.clone() },
        }
    }

    /// The record is on a stick.
    pub fn on_usb(&self) -> bool {
        matches!(self.audio, Audio::Usb { .. })
    }

    pub fn playable(&self) -> bool {
        !matches!(self.audio, Audio::None)
    }

    pub fn initials(&self) -> String {
        self.title
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .take(2)
            .filter_map(|w| w.chars().next())
            .flat_map(char::to_uppercase)
            .collect()
    }
}

/// A stick's record's id: below −2³² (clear of the synth's), 24 bits of the stick's
/// name (FNV-1a) above rekordbox's 32-bit id.
pub fn usb_id(stick: &str, track: u32) -> i64 {
    let tag = stick.bytes().fold(0x811c_9dc5u32, |h, b| (h ^ b as u32).wrapping_mul(0x0100_0193)) & 0xff_ffff;
    -(((tag as i64 + 1) << 32) | track as i64)
}

const FIXTURE: &str = include_str!("../../../bakeoff/records.json");

/// The fixture's rows (the house's facts), each with its audio where this computer has it.
pub fn crate_rows() -> Vec<Record> {
    let dir = fetched_dir();
    parse_fixture()
        .into_iter()
        .map(|mut r| {
            if let Some(d) = &dir {
                let path = d.join(format!("{}.m4a", r.id));
                if path.exists()
                    && let Some((beats, bar_one)) = beats_for(d, r.id) {
                        r.audio = Audio::File { path, beats, bar_one };
                    }
            }
            r
        })
        .collect()
}

/// Two made-up records for a computer without the app's fetched records (CI, a new box).
pub fn synth_rows() -> Vec<Record> {
    [(1, "Test Pressing A", 128.0, "8A"), (2, "Test Pressing B", 130.0, "9A")]
        .into_iter()
        .map(|(seed, title, bpm, key)| Record {
            id: -(seed as i64),
            title: title.into(),
            artist: "WetOwl synth".into(),
            bpm,
            key: key.into(),
            seconds: crate::synth::seconds(bpm) as u32,
            audio: Audio::Synth { seed },
            cover: false,
            cover_rgb: None,
            loudness: Loudness::default(),
            tags: Tags::default(),
        })
        .collect()
}

fn parse_fixture() -> Vec<Record> {
    // [[id, "title", "artist", bpm, "key", seconds], …] — read by hand, no JSON crate needed.
    let mut out = vec![];
    for line in FIXTURE.lines().map(str::trim).filter(|l| l.starts_with('[') && l.len() > 2) {
        let body = line.trim_start_matches('[').trim_end_matches(',').trim_end_matches(']');
        let mut fields = vec![];
        let mut cur = String::new();
        let (mut quoted, mut esc) = (false, false);
        for ch in body.chars() {
            match (quoted, esc, ch) {
                (true, true, c) => {
                    cur.push(c);
                    esc = false;
                }
                (true, false, '\\') => esc = true,
                (_, false, '"') => quoted = !quoted,
                (false, _, ',') => fields.push(std::mem::take(&mut cur).trim().to_owned()),
                (_, _, c) => cur.push(c),
            }
        }
        fields.push(cur.trim().to_owned());
        if fields.len() == 6 {
            out.push(Record {
                id: fields[0].parse().unwrap_or(0),
                title: fields[1].clone(),
                artist: fields[2].clone(),
                bpm: fields[3].parse().unwrap_or(0.0),
                key: fields[4].clone(),
                seconds: fields[5].parse().unwrap_or(0),
                audio: Audio::None,
                cover: false,
                cover_rgb: None,
                loudness: Loudness::default(),
                tags: Tags::default(),
            });
        }
    }
    out
}

/// Where the WetOwl app keeps fetched records on this computer (WO_RECORDS overrides).
pub fn fetched_dir() -> Option<PathBuf> {
    if let Ok(d) = std::env::var("WO_RECORDS") {
        return Some(PathBuf::from(d));
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let candidates: Vec<PathBuf> = if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(|a| vec![PathBuf::from(a).join("io.wetowl").join("muse")]).unwrap_or_default()
    } else if cfg!(target_os = "macos") {
        home.map(|h| vec![h.join("Library/Application Support/io.wetowl.muse")]).unwrap_or_default()
    } else {
        home.map(|h| vec![h.join(".local/share/io.wetowl.muse")]).unwrap_or_default()
    };
    candidates.into_iter().map(|c| c.join("fetched")).find(|c| c.is_dir())
}

/// The app's cached beats for a record (`stems/<id>-beats-v1.json` beside `fetched/`),
/// a steady tempo fitted through them, and which beat is a bar's first.
fn beats_for(fetched: &Path, id: i64) -> Option<(Vec<f64>, usize)> {
    let file = fetched.parent()?.join("stems").join(format!("{id}-beats-v1.json"));
    let text = std::fs::read_to_string(file).ok()?;
    let ms = |key: &str| -> Vec<f64> {
        let Some(i) = text.find(&format!("\"{key}\":[")) else { return vec![] };
        let rest = &text[i + key.len() + 4..];
        rest[..rest.find(']').unwrap_or(0)].split(',').filter_map(|v| v.trim().parse::<f64>().ok()).map(|v| v / 1000.0).collect()
    };
    let raw = ms("beats_ms");
    if raw.len() < 16 {
        return None;
    }
    let n = raw.len() as f64;
    let sx: f64 = (0..raw.len()).map(|i| i as f64).sum();
    let sy: f64 = raw.iter().sum();
    let sxx: f64 = (0..raw.len()).map(|i| (i * i) as f64).sum();
    let sxy: f64 = raw.iter().enumerate().map(|(i, y)| i as f64 * y).sum();
    let spb = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    let first = (sy - spb * sx) / n;
    let grid: Vec<f64> = (0..raw.len()).map(|i| first + spb * i as f64).collect();
    let bar_one = ms("downbeats_ms")
        .first()
        .and_then(|&d| grid.iter().enumerate().min_by(|a, b| (a.1 - d).abs().total_cmp(&(b.1 - d).abs())).map(|(i, _)| i % 4))
        .unwrap_or(0);
    Some((grid, bar_one))
}

/// How well `r` follows a record at `bpm` in `key`: the Camelot wheel first, then tempo. 0..100.
/// A Camelot key ("8A") as its number and whether it is major (B).
fn camelot_parts(k: &str) -> Option<(i32, bool)> {
    let k = k.trim();
    let (n, l) = k.split_at(k.len().checked_sub(1)?);
    let n: i32 = n.parse().ok()?;
    let major = match l {
        "A" | "a" => false,
        "B" | "b" => true,
        _ => return None,
    };
    (1..=12).contains(&n).then_some((n, major))
}

/// A Camelot key shifted `semis` semitones (seven steps round the wheel a semitone).
pub fn shift_camelot(k: &str, semis: i32) -> String {
    match camelot_parts(k) {
        Some((n, major)) => format!("{}{}", (n - 1 + 7 * semis).rem_euclid(12) + 1, if major { 'B' } else { 'A' }),
        None => k.to_owned(),
    }
}

/// The fewest semitones (−6 … +5) that take key `from` to the number of key `to` (the same
/// key, or its relative major or minor: they mix).
pub fn semis_to(from: &str, to: &str) -> Option<i32> {
    let ((a, _), (b, _)) = (camelot_parts(from)?, camelot_parts(to)?);
    // a semitone is seven numbers round the wheel: 7 × 7 = 49 ≡ 1, so seven back again
    let s = (7 * (b - a)).rem_euclid(12);
    Some(if s > 5 { s - 12 } else { s })
}

/// Whether a record goes with the master's (rekordbox's related tracks, as a DJ means it):
/// its key the same or the wheel's next (or its relative), and its tempo within 6 % of the
/// master's, or of half or double it. A record or a master without a key or a tempo: by the
/// one known.
pub fn related(r: &Record, bpm: f64, key: &str) -> bool {
    let parse = |k: &str| -> Option<(i32, char)> {
        let letter = k.chars().last()?;
        Some((k.strip_suffix(letter)?.parse().ok()?, letter))
    };
    let key_ok = match (parse(&r.key), parse(key)) {
        (Some((n, l)), Some((m, k))) => {
            let d = (n - m).abs().min(12 - (n - m).abs());
            d == 0 || (d == 1 && l == k)
        }
        _ => true,
    };
    let tempo_ok = bpm <= 0.0 || r.bpm <= 0.0 || [1.0, 0.5, 2.0].iter().any(|&k| ((r.bpm * k) / bpm - 1.0).abs() <= 0.06);
    key_ok && tempo_ok
}

pub fn fits(r: &Record, bpm: f64, key: &str) -> u8 {
    let parse = |k: &str| -> Option<(i32, char)> {
        let letter = k.chars().last()?;
        Some((k.strip_suffix(letter)?.parse().ok()?, letter))
    };
    let key_fit = match (parse(&r.key), parse(key)) {
        (Some((n, l)), Some((m, k))) => {
            let d = (n - m).abs().min(12 - (n - m).abs());
            match (d, l == k) {
                (0, true) => 1.0,
                (0, false) => 0.8,
                (1, true) => 0.85,
                (1, false) => 0.6,
                _ => 0.3,
            }
        }
        _ => 0.4,
    };
    let tempo = (1.0 - ((r.bpm - bpm).abs() / bpm) * 8.0).max(0.0);
    (100.0 * (0.6 * key_fit + 0.4 * tempo)).round() as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn related_by_the_wheel_and_the_tempo() {
        let mut r = parse_fixture()[0].clone();
        (r.key, r.bpm) = ("8A".into(), 128.0);
        assert!(related(&r, 126.0, "8A"), "the same key, 1.6 % apart");
        assert!(related(&r, 130.0, "9A") && related(&r, 130.0, "7A") && related(&r, 128.0, "8B"), "the wheel's next and the relative");
        assert!(!related(&r, 128.0, "10A") && !related(&r, 128.0, "9B"), "two steps, or across and along");
        assert!(!related(&r, 140.0, "8A"), "9 % apart");
        assert!(related(&r, 64.5, "8A") && related(&r, 255.0, "8A"), "half and double time");
    }

    #[test]
    fn the_fixture_reads() {
        let rows = parse_fixture();
        assert_eq!(rows.len(), 17);
        assert_eq!(rows[0].title, "Back To The 90s");
        assert_eq!(rows[13].title, "Give It Up (7\" Version)");
        assert_eq!(rows[3].key, "9A");
        assert_eq!(rows[0].initials(), "BT");
    }

    #[test]
    fn fits_prefer_the_same_key_and_tempo() {
        let rows = parse_fixture();
        let f = |i: usize| fits(&rows[i], 159.99, "10B");
        assert!(f(1) > f(3) && f(3) > f(8), "{} {} {}", f(1), f(3), f(8));
        assert!(f(15) > 0, "a record with no key still fits by tempo");
    }
}


#[cfg(test)]
mod key_tests {
    use super::*;

    #[test]
    fn keys_shift_round_the_wheel() {
        assert_eq!(shift_camelot("8A", 1), "3A", "A minor up a semitone is B flat minor");
        assert_eq!(shift_camelot("8B", -1), "1B", "C major down a semitone is B major");
        assert_eq!(shift_camelot("12A", 0), "12A");
        assert_eq!(semis_to("8A", "3A"), Some(1));
        assert_eq!(semis_to("3A", "8A"), Some(-1));
        assert_eq!(semis_to("8A", "8B"), Some(0), "relatives already mix");
        assert_eq!(shift_camelot("8A", semis_to("8A", "10A").unwrap()), "10A");
        assert_eq!(semis_to("", "8A"), None);
    }
}
