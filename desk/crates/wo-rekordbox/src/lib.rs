//! rekordbox's own library on this computer, read only: what it knows of each analysed
//! record (beat grid, cues, phrases) and where the audio is, so the Desk can follow a
//! rekordbox set (plan: ~/.claude/plans/wetowl-rekordbox-windows.md).
//!
//! - [`index`]: analysis ↔ audio file ↔ tags, and finding a deck's record by title.
//! - [`sections`]: rekordbox's phrases as the show's sections and drops.
//! - [`tags`]: an audio file's own tags.
//!
//! Nothing here writes to rekordbox's folder: its analyses are only read.
use std::path::{Path, PathBuf};

pub mod index;
pub mod sections;
pub mod tags;

pub use index::{Entry, Index};
pub use sections::{Phrased, Section};

/// rekordbox's library folder: `%APPDATA%\Pioneer\rekordbox` on Windows,
/// `~/Library/Pioneer/rekordbox` on a Mac; `None` when it is not there.
pub fn library_dir() -> Option<PathBuf> {
    let dir = if cfg!(target_os = "windows") {
        PathBuf::from(std::env::var_os("APPDATA")?).join("Pioneer").join("rekordbox")
    } else {
        PathBuf::from(std::env::var_os("HOME")?).join("Library").join("Pioneer").join("rekordbox")
    };
    dir.is_dir().then_some(dir)
}

/// The rekordbox installed here, its version ("7.2.2"; on a Mac only what its folder says,
/// "7"): the newest of `C:\Program Files\rekordbox\rekordbox <version>` or
/// `/Applications/rekordbox <version>`.
pub fn installed() -> Option<String> {
    let (root, prefix) = if cfg!(target_os = "windows") {
        (PathBuf::from(std::env::var_os("ProgramFiles").unwrap_or_else(|| "C:\\Program Files".into())).join("rekordbox"), "rekordbox ")
    } else {
        (PathBuf::from("/Applications"), "rekordbox ")
    };
    let mut versions: Vec<String> = std::fs::read_dir(root)
        .ok()?
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.strip_prefix(prefix).map(str::to_owned))
        .filter(|v| v.chars().next().is_some_and(|c| c.is_ascii_digit()))
        .collect();
    let key = |v: &String| v.split('.').map(|n| n.parse::<u32>().unwrap_or(0)).collect::<Vec<_>>();
    versions.sort_by_key(key);
    versions.pop()
}

/// rekordbox is open now, as its library says (its database's shared-memory file, there while
/// rekordbox has it open; a crash can leave it behind, so a hint, not a fact).
pub fn open_now() -> bool {
    library_dir().is_some_and(|d| d.join("master.db-shm").exists())
}

/// Where the library keeps its analyses.
pub fn anlz_root(library: &Path) -> PathBuf {
    library.join("share").join("PIONEER").join("USBANLZ")
}

/// The usual music folder.
pub fn default_music() -> Option<PathBuf> {
    default_music_folders().into_iter().next()
}

/// Where music usually is, searched when no folders are given: Music, Downloads and the
/// Desktop, those that are there.
pub fn default_music_folders() -> Vec<PathBuf> {
    let Some(home) = std::env::var_os(if cfg!(target_os = "windows") { "USERPROFILE" } else { "HOME" }) else { return vec![] };
    ["Music", "Downloads", "Desktop"].iter().map(|d| PathBuf::from(&home).join(d)).filter(|p| p.is_dir()).collect()
}

/// What the Desk takes from rekordbox for one record.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Record {
    /// Every beat, seconds into the audio.
    pub beats: Vec<f64>,
    /// Which beat is a bar's first, 0..3.
    pub bar_one: usize,
    pub cues: Vec<wo_usb::Cue>,
    /// rekordbox's phrase mood: 1 high, 2 mid, 3 low.
    pub mood: Option<u16>,
    /// The phrases placed on the grid (empty without phrase analysis).
    pub phrased: Phrased,
}

/// A record's analysis (its `.DAT` and the `.EXT` beside it).
pub fn record(e: &Entry) -> Result<Record, String> {
    let a = wo_usb::analysis_of(&e.dat).map_err(|e| format!("{e:?}"))?;
    let ext = std::fs::read(e.dat.with_extension("EXT")).map(|b| wo_usb::anlz::read(&b)).unwrap_or_default();
    let phrased = ext.phrases.as_ref().map(|p| sections::place(p, &a.beats)).unwrap_or_default();
    Ok(Record { beats: a.beats, bar_one: a.bar_one, cues: a.cues, mood: ext.phrases.map(|p| p.mood), phrased })
}
