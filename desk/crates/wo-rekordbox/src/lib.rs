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

/// Where the library keeps its analyses.
pub fn anlz_root(library: &Path) -> PathBuf {
    library.join("share").join("PIONEER").join("USBANLZ")
}

/// The usual music folder (the one searched when no other is given).
pub fn default_music() -> Option<PathBuf> {
    let home = std::env::var_os(if cfg!(target_os = "windows") { "USERPROFILE" } else { "HOME" })?;
    let m = PathBuf::from(home).join("Music");
    m.is_dir().then_some(m)
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
