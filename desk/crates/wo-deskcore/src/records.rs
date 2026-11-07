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
}

/// A record's loudness, as the box measured it: the gain that brings it to the house's
/// reference (−14 LUFS, the one the phones' player turns songs by), and its true peak.
#[derive(Clone, Copy, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Loudness {
    pub gain_db: Option<f32>,
    pub true_peak_db: Option<f32>,
}

impl Loudness {
    /// The most a quiet record is turned up, dB, and how close to full scale its true peak
    /// may come then.
    pub const MOST_UP: f32 = 6.0;
    pub const CEILING_DB: f32 = -1.0;

    /// The deck's level for it, as a multiplier: a loud record turned down to the
    /// reference; a quiet one up only as far as its true peak leaves room (not at all
    /// where its peak is not known — turning a record up is turning its clipping up); 1
    /// where it was never measured.
    pub fn trim(&self) -> f32 {
        let Some(g) = self.gain_db else { return 1.0 };
        let db = if g > 0.0 {
            match self.true_peak_db {
                Some(p) => g.min((Self::CEILING_DB - p).max(0.0)).min(Self::MOST_UP),
                None => 0.0,
            }
        } else {
            g.max(-24.0)
        };
        10f32.powf(db / 20.0)
    }
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
        }
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
mod loudness_tests {
    use super::Loudness;

    #[test]
    fn a_record_is_turned_to_the_house_loudness_and_up_only_into_its_headroom() {
        let db = |l: Loudness| 20.0 * l.trim().log10();
        // never measured: as it is
        assert_eq!(Loudness::default().trim(), 1.0);
        // a loud club record (−8 LUFS) down 6 dB
        assert!((db(Loudness { gain_db: Some(-6.0), true_peak_db: Some(0.4) }) + 6.0).abs() < 1e-4);
        // a quiet one up as far as its peak allows (−4 dBTP: 3 dB to the −1 ceiling)
        assert!((db(Loudness { gain_db: Some(5.0), true_peak_db: Some(-4.0) }) - 3.0).abs() < 1e-4);
        // up no more than 6 dB, however much room
        assert!((db(Loudness { gain_db: Some(10.0), true_peak_db: Some(-20.0) }) - 6.0).abs() < 1e-4);
        // a quiet one whose peak is not known, or already at the ceiling: not turned up
        assert_eq!(Loudness { gain_db: Some(4.0), true_peak_db: None }.trim(), 1.0);
        assert_eq!(Loudness { gain_db: Some(4.0), true_peak_db: Some(-0.5) }.trim(), 1.0);
    }
}
