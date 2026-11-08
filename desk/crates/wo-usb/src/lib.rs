//! rekordbox USB sticks: the records a DJ exported for the CDJs, as the Desk plays them.
//!
//! A stick holds `PIONEER/rekordbox/export.pdb` (the records, playlists, keys, artwork)
//! and per record an analysis (`PIONEER/USBANLZ/…`: the beat grid, hot and memory cues).
//! Read only: nothing here writes to a stick.
use std::path::{Path, PathBuf};

pub mod anlz;
pub mod pdb;

use pdb::{Pdb, Table};

/// Where a stick's database is, under its root.
pub const DATABASE: &str = "PIONEER/rekordbox/export.pdb";

/// A record on a stick.
#[derive(Clone, Debug, PartialEq)]
pub struct Track {
    /// rekordbox's id for it on this stick.
    pub id: u32,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub genre: String,
    /// Camelot ("8A"), whichever way rekordbox wrote it; "" when not known.
    pub key: String,
    /// The grid's tempo, as rekordbox shows it.
    pub bpm: f64,
    pub seconds: u32,
    /// The audio, the analysis (`.DAT`) and the cover (the larger one where there is one),
    /// each a full path.
    pub path: PathBuf,
    pub anlz: Option<PathBuf>,
    pub artwork: Option<PathBuf>,
    pub rating: u8,
    pub comment: String,
    pub date_added: String,
}

/// A playlist (or a folder of them), and its records in order.
#[derive(Clone, Debug, PartialEq)]
pub struct Playlist {
    pub id: u32,
    pub name: String,
    /// The folders above it, outermost first.
    pub folders: Vec<String>,
    pub tracks: Vec<u32>,
}

/// One stick, read.
#[derive(Clone, Debug)]
pub struct Stick {
    pub root: PathBuf,
    /// What the computer calls it (the volume's name).
    pub name: String,
    pub tracks: Vec<Track>,
    pub playlists: Vec<Playlist>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CueKind {
    /// rekordbox's memory cues (the CDJ's CUE/CALL list).
    Memory,
    /// A hot cue: 0 = A … 7 = H.
    Hot(u8),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Cue {
    pub kind: CueKind,
    pub ms: u32,
    /// A loop's end, where the cue is a loop.
    pub loop_end_ms: Option<u32>,
    /// The hot cue's colour (0xRRGGBB), where rekordbox gave it one.
    pub rgb: Option<u32>,
    pub comment: String,
}

/// A record's analysis as the decks take it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Analysis {
    /// Every beat, seconds into the audio as rekordbox decodes it.
    pub beats: Vec<f64>,
    /// Which beat is a bar's first, 0..3 (rekordbox's beat 1 of the first bar).
    pub bar_one: usize,
    /// The extended list where the `.EXT` has one, else the `.DAT`'s; sorted by time.
    pub cues: Vec<Cue>,
}

#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    Bad(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(e) => write!(f, "{e}"),
            Error::Bad(why) => f.write_str(why),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

impl From<pdb::Bad> for Error {
    fn from(e: pdb::Bad) -> Self {
        Error::Bad(e.0)
    }
}

// ---------------------------------------------------------------- finding sticks

/// Where removable drives show up on this computer: the folders whose children are drives.
fn mount_parents() -> Vec<PathBuf> {
    if cfg!(target_os = "macos") {
        return vec![PathBuf::from("/Volumes")];
    }
    if cfg!(target_os = "windows") {
        return vec![];
    }
    let mut v = vec![];
    if let Some(user) = std::env::var_os("USER") {
        v.push(Path::new("/run/media").join(&user));
        v.push(Path::new("/media").join(&user));
    }
    v.extend(["/media", "/mnt"].map(PathBuf::from));
    v
}

/// The roots of the rekordbox sticks mounted now (WO_USB adds folders, `:`-separated
/// on Unix, `;` on Windows — a copy of a stick, for tests). Cheap enough to call every
/// few seconds: a directory listing and a file check per drive.
pub fn find() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = vec![];
    if let Some(extra) = std::env::var_os("WO_USB") {
        roots.extend(std::env::split_paths(&extra));
    }
    if cfg!(target_os = "windows") {
        roots.extend((b'D'..=b'Z').map(|d| PathBuf::from(format!("{}:\\", d as char))));
    }
    for parent in mount_parents() {
        if let Ok(dir) = std::fs::read_dir(&parent) {
            roots.extend(dir.flatten().map(|e| e.path()));
        }
    }
    let mut seen = std::collections::HashSet::new();
    roots.into_iter().filter(|r| r.join(DATABASE).is_file() && seen.insert(r.canonicalize().unwrap_or(r.clone()))).collect()
}

/// A stick's name: its folder's (the volume label on Linux and macOS), or the drive.
pub fn name_of(root: &Path) -> String {
    root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| root.display().to_string().trim_end_matches(['\\', '/']).to_owned())
}

// ---------------------------------------------------------------- reading one

impl Stick {
    /// Reads a stick's database (a few hundred KB even for thousands of records).
    pub fn open(root: &Path) -> Result<Stick, Error> {
        let bytes = std::fs::read(root.join(DATABASE))?;
        Self::from_database(root, &bytes)
    }

    pub fn from_database(root: &Path, bytes: &[u8]) -> Result<Stick, Error> {
        use pdb::Le;
        use std::collections::HashMap;
        let db = Pdb::new(bytes)?;
        let named = |t: Table, at: usize| -> HashMap<u32, String> { db.rows(t).into_iter().filter_map(|r| Some((r.u32_at(0)?, pdb::string(r, at)))).collect() };
        let genres = named(Table::Genres, 4);
        let keys = named(Table::Keys, 8);
        let artwork = named(Table::Artwork, 4);
        let artists: HashMap<u32, String> = db
            .rows(Table::Artists)
            .into_iter()
            .filter_map(|r| Some((r.u32_at(4)?, pdb::near_far_name(r, r.u16_at(0)? == 0x64, 9, 0x0a))))
            .collect();
        let albums: HashMap<u32, String> = db
            .rows(Table::Albums)
            .into_iter()
            .filter_map(|r| Some((r.u32_at(12)?, pdb::near_far_name(r, r.u16_at(0)? == 0x84, 0x15, 0x16))))
            .collect();
        let on_stick = |p: &str| -> Option<PathBuf> { (!p.is_empty()).then(|| root.join(p.trim_start_matches('/'))) };
        let mut tracks: Vec<Track> = db
            .rows(Table::Tracks)
            .into_iter()
            .filter_map(|r| {
                let s = |i: usize| pdb::string_at_u16(r, 0x5e + 2 * i);
                let path = on_stick(&s(20))?;
                let cover = r.u32_at(0x1c).and_then(|a| artwork.get(&a)).and_then(|p| on_stick(p)).map(|small| {
                    // rekordbox writes each cover twice: 80 px, and 240 px as `_m`
                    let big = small.with_file_name(format!("{}_m.jpg", small.file_stem().unwrap_or_default().to_string_lossy()));
                    if big.is_file() { big } else { small }
                });
                let title = s(17);
                Some(Track {
                    id: r.u32_at(0x48)?,
                    title: if title.is_empty() { s(19) } else { title },
                    artist: r.u32_at(0x44).and_then(|a| artists.get(&a)).cloned().unwrap_or_default(),
                    album: r.u32_at(0x40).and_then(|a| albums.get(&a)).cloned().unwrap_or_default(),
                    genre: r.u32_at(0x3c).and_then(|g| genres.get(&g)).cloned().unwrap_or_default(),
                    key: r.u32_at(0x20).and_then(|k| keys.get(&k)).map(|k| camelot(k)).unwrap_or_default(),
                    bpm: r.u32_at(0x38)? as f64 / 100.0,
                    seconds: r.u16_at(0x54)? as u32,
                    path,
                    anlz: on_stick(&s(14)),
                    artwork: cover,
                    rating: r.u8_at(0x59).unwrap_or(0),
                    comment: s(16),
                    date_added: s(10),
                })
            })
            .collect();
        tracks.sort_by_key(|t| t.id);
        tracks.dedup_by_key(|t| t.id);

        // the playlist tree: (parent, sort order, id, folder?, name); entries: (index, track, list)
        let nodes: Vec<(u32, u32, u32, bool, String)> = db
            .rows(Table::PlaylistTree)
            .into_iter()
            .filter_map(|r| Some((r.u32_at(0)?, r.u32_at(8)?, r.u32_at(12)?, r.u32_at(16)? != 0, pdb::string(r, 0x14))))
            .collect();
        let mut entries: Vec<(u32, u32, u32)> = db.rows(Table::PlaylistEntries).into_iter().filter_map(|r| Some((r.u32_at(0)?, r.u32_at(4)?, r.u32_at(8)?))).collect();
        entries.sort();
        let folders_of = |mut parent: u32| -> Vec<String> {
            let mut up = vec![];
            for _ in 0..32 {
                let Some(n) = nodes.iter().find(|n| n.2 == parent && n.3) else { break };
                up.push(n.4.clone());
                parent = n.0;
            }
            up.reverse();
            up
        };
        // depth first, each level in rekordbox's own order
        let mut playlists = vec![];
        fn walk(nodes: &[(u32, u32, u32, bool, String)], parent: u32, depth: usize, out: &mut Vec<u32>) {
            if depth > 32 {
                return;
            }
            let mut kids: Vec<&(u32, u32, u32, bool, String)> = nodes.iter().filter(|n| n.0 == parent && n.2 != parent).collect();
            kids.sort_by_key(|n| n.1);
            for k in kids {
                if k.3 {
                    walk(nodes, k.2, depth + 1, out);
                } else {
                    out.push(k.2);
                }
            }
        }
        let mut order = vec![];
        walk(&nodes, 0, 0, &mut order);
        for id in order {
            let Some(n) = nodes.iter().find(|n| n.2 == id) else { continue };
            playlists.push(Playlist {
                id,
                name: n.4.clone(),
                folders: folders_of(n.0),
                tracks: entries.iter().filter(|e| e.2 == id).map(|e| e.1).collect(),
            });
        }
        Ok(Stick { root: root.to_owned(), name: name_of(root), tracks, playlists })
    }

    pub fn track(&self, id: u32) -> Option<&Track> {
        self.tracks.binary_search_by_key(&id, |t| t.id).ok().map(|i| &self.tracks[i])
    }
}

impl Track {
    /// The record's grid and cues: its `.DAT`, and its `.EXT` for the cues' colours and
    /// comments. A record rekordbox never analysed has none of either.
    pub fn analysis(&self) -> Result<Analysis, Error> {
        match &self.anlz {
            Some(dat) => analysis_of(dat),
            None => Ok(Analysis::default()),
        }
    }
}

/// The grid and cues in a record's analysis, from the path of its `.DAT`.
pub fn analysis_of(dat: &Path) -> Result<Analysis, Error> {
    let a = anlz::read(&std::fs::read(dat)?);
    let ext = std::fs::read(dat.with_extension("EXT")).map(|b| anlz::read(&b)).unwrap_or_default();
    let mut cues = if !ext.cues_ext.is_empty() {
        ext.cues_ext
    } else if !a.cues.is_empty() {
        a.cues
    } else {
        ext.cues
    };
    cues.sort_by_key(|c| c.ms);
    let (beats, bar_one) = grid(&a.beats);
    Ok(Analysis { beats, bar_one, cues })
}

// ---------------------------------------------------------------- the grid

/// rekordbox's beats as the decks take them: seconds, and which beat is a bar's one.
///
/// The file keeps whole milliseconds, so each beat is off by up to half of one; within a
/// stretch of one tempo the beats are fitted to a straight line (what rekordbox laid
/// down), which puts them back within a few microseconds of where rekordbox meant.
pub fn grid(beats: &[anlz::Beat]) -> (Vec<f64>, usize) {
    let mut out = Vec::with_capacity(beats.len());
    let mut start = 0;
    while start < beats.len() {
        let mut end = start + 1;
        while end < beats.len() && beats[end].bpm == beats[start].bpm {
            end += 1;
        }
        out.extend(fit(&beats[start..end]));
        start = end;
    }
    let bar_one = beats.iter().position(|b| b.of_bar == 1).map(|i| i % 4).unwrap_or(0);
    (out, bar_one)
}

/// One tempo's run of beats, least squares through their stored times. A run too short
/// to fit, or one that does not lie on a line (a hand-moved beat), stays as stored.
fn fit(run: &[anlz::Beat]) -> Vec<f64> {
    let stored: Vec<f64> = run.iter().map(|b| b.ms as f64 / 1000.0).collect();
    if run.len() < 4 {
        return stored;
    }
    let n = run.len() as f64;
    let sx: f64 = (0..run.len()).map(|i| i as f64).sum();
    let sy: f64 = stored.iter().sum();
    let sxx: f64 = (0..run.len()).map(|i| (i * i) as f64).sum();
    let sxy: f64 = stored.iter().enumerate().map(|(i, y)| i as f64 * y).sum();
    let spb = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    let first = (sy - spb * sx) / n;
    let line: Vec<f64> = (0..run.len()).map(|i| first + spb * i as f64).collect();
    let worst = line.iter().zip(&stored).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
    if worst > 0.002 { stored } else { line }
}

// ---------------------------------------------------------------- keys

/// A key as rekordbox wrote it ("8A" or "Am", "F#m", "Dbm"…) in Camelot; "" for
/// anything else.
pub fn camelot(key: &str) -> String {
    let k = key.trim();
    if let Some(letter) = k.chars().last().filter(|c| matches!(c, 'A' | 'B'))
        && let Ok(n) = k[..k.len() - 1].parse::<u8>()
        && (1..=12).contains(&n)
    {
        return format!("{n}{letter}");
    }
    let minor = k.ends_with('m') && !k.ends_with("maj");
    let root = k.trim_end_matches("min").trim_end_matches("maj").trim_end_matches('m');
    let pc = match root.replace('♯', "#").replace('♭', "b").as_str() {
        "C" | "B#" => 0,
        "C#" | "Db" => 1,
        "D" => 2,
        "D#" | "Eb" => 3,
        "E" | "Fb" => 4,
        "F" | "E#" => 5,
        "F#" | "Gb" => 6,
        "G" => 7,
        "G#" | "Ab" => 8,
        "A" => 9,
        "A#" | "Bb" => 10,
        "B" | "Cb" => 11,
        _ => return String::new(),
    };
    // C major = 8B, A minor = 8A; a fifth up is one step round the wheel
    let major_n = |pc: i32| (pc * 7 % 12 + 7) % 12 + 1;
    if minor {
        format!("{}A", major_n((pc + 3) % 12))
    } else {
        format!("{}B", major_n(pc))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use anlz::Beat;

    #[test]
    fn keys_come_out_as_camelot_however_rekordbox_wrote_them() {
        for (k, c) in [("8A", "8A"), ("12B", "12B"), ("Am", "8A"), ("C", "8B"), ("F#m", "11A"), ("Gbm", "11A"), ("Db", "3B"), ("Ebm", "2A"), ("G", "9B"), ("Em", "9A"), ("Bb", "6B"), ("B", "1B"), ("Fm", "4A")] {
            assert_eq!(camelot(k), c, "{k}");
        }
        assert_eq!(camelot(""), "");
        assert_eq!(camelot("13A"), "");
        assert_eq!(camelot("H"), "");
    }

    #[test]
    fn whole_milliseconds_are_fitted_back_onto_the_tempo() {
        // 135 BPM from 35 ms, stored rounded to the millisecond
        let spb = 60.0 / 135.0;
        let beats: Vec<Beat> = (0..64).map(|i| Beat { ms: ((0.035 + i as f64 * spb) * 1000.0).round() as u32, of_bar: (i % 4 + 1) as u8, bpm: 135.0 }).collect();
        let (g, bar_one) = grid(&beats);
        assert_eq!(bar_one, 0);
        for (i, t) in g.iter().enumerate() {
            assert!((t - (0.035 + i as f64 * spb)).abs() < 2e-4, "beat {i}: {t}");
        }
        // a grid starting on beat 3: the bar's one is the third beat
        let late: Vec<Beat> = beats.iter().map(|b| Beat { of_bar: (b.of_bar + 1) % 4 + 1, ..*b }).collect();
        assert_eq!(grid(&late).1, 2);
    }

    #[test]
    fn a_tempo_change_starts_a_new_line() {
        let mut beats = vec![];
        let mut t = 0.1;
        for i in 0..32 {
            let bpm = if i < 16 { 120.0 } else { 128.0 };
            beats.push(Beat { ms: (t * 1000.0f64).round() as u32, of_bar: (i % 4 + 1) as u8, bpm });
            t += 60.0 / bpm;
        }
        let (g, _) = grid(&beats);
        assert_eq!(g.len(), 32);
        assert!((g[15] - g[14] - 0.5).abs() < 1e-3);
        assert!((g[31] - g[30] - 60.0 / 128.0).abs() < 1e-3);
    }

    /// The real stick, where one is plugged in (or a copy named by WO_USB): reads all of
    /// it. `cargo test -p wo-usb -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn the_sticks_plugged_in_read() {
        let roots = find();
        assert!(!roots.is_empty(), "no stick found (plug one in or set WO_USB)");
        for root in roots {
            let s = Stick::open(&root).unwrap();
            println!("{} at {}: {} records, {} playlists", s.name, root.display(), s.tracks.len(), s.playlists.len());
            for p in &s.playlists {
                println!("  {}{} · {} records", p.folders.iter().map(|f| format!("{f} / ")).collect::<String>(), p.name, p.tracks.len());
                assert!(p.tracks.iter().all(|&id| s.track(id).is_some()), "a playlist names a record the stick does not have");
            }
            let (mut gridded, mut cued, mut missing) = (0, 0, 0);
            for t in &s.tracks {
                if !t.path.is_file() {
                    missing += 1;
                }
                let a = t.analysis().unwrap();
                if !a.beats.is_empty() {
                    gridded += 1;
                    assert!(a.beats.windows(2).all(|w| w[1] > w[0]), "{}: beats out of order", t.title);
                }
                if !a.cues.is_empty() {
                    cued += 1;
                }
            }
            println!("  {gridded} gridded, {cued} with cues, {missing} audio files missing");
            for t in s.tracks.iter().take(5) {
                let a = t.analysis().unwrap();
                println!("  #{} {} — {} · {} · {:.2} BPM · {} s · {} beats (one at {}) · cues {:?}", t.id, t.title, t.artist, t.key, t.bpm, t.seconds, a.beats.len(), a.bar_one, a.cues.iter().map(|c| (c.kind, c.ms)).collect::<Vec<_>>());
            }
            assert_eq!(missing, 0);
        }
    }
}
