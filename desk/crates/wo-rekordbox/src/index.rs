//! Which analysis belongs to which record: every analysis file under rekordbox's
//! `USBANLZ`, its audio file found by name in the music folders, and that file's tags,
//! so a deck's title (rkbx_link's) finds its analysis and its audio.
//!
//! rekordbox's own library stores only `?/<file name>` in an analysis (the folder is in
//! master.db, which this does not open), so the audio is looked up by file name in the
//! folders given; a record kept elsewhere is indexed without audio and matched by its
//! file name only.
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::tags::{self, Tags};

/// Audio files rekordbox imports.
const AUDIO: &[&str] = &["mp3", "m4a", "mp4", "aac", "aif", "aiff", "wav", "flac", "ogg", "alac"];

/// One analysed record.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    /// Its `ANLZ0000.DAT` (the `.EXT` sits beside it).
    pub dat: PathBuf,
    /// The audio file's name, as the analysis has it.
    pub file_name: String,
    /// The audio file, where it was found.
    pub audio: Option<PathBuf>,
    /// Its tags (empty when the audio was not found).
    pub tags: Tags,
    /// A WetOwl record id, from a `wetowl:<id>` comment (files fetched from WetOwl).
    pub wetowl_id: Option<i64>,
    /// When the analysis was last written (newer wins between two of one file).
    pub analysed: Option<SystemTime>,
}

impl Entry {
    /// The title it goes by: its tag's, else the file name without its extension (as
    /// rekordbox shows an untagged file).
    pub fn title(&self) -> String {
        if !self.tags.title.is_empty() {
            return self.tags.title.clone();
        }
        Path::new(&self.file_name).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
    }
}

/// How a library was indexed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Stats {
    pub analyses: usize,
    /// Analyses whose audio was found in the music folders.
    pub with_audio: usize,
    /// File names found more than once in the music folders (the first is taken).
    pub ambiguous: usize,
}

#[derive(Clone, Debug, Default)]
pub struct Index {
    pub entries: Vec<Entry>,
    pub stats: Stats,
    by_title: HashMap<String, Vec<usize>>,
}

/// Lower case, inner whitespace folded, ends trimmed.
pub fn norm(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// A file name's stem without a leading track number ("03 XXL.m4a" → "XXL").
fn bare_stem(file_name: &str) -> Option<String> {
    let stem = Path::new(file_name).file_stem()?.to_string_lossy().into_owned();
    let rest = stem.trim_start_matches(|c: char| c.is_ascii_digit());
    let rest = rest.trim_start_matches([' ', '.', '-', '_']);
    (rest.len() < stem.len() && !rest.is_empty()).then(|| rest.to_owned())
}

/// Every file under `root` (depth-limited, links not followed).
fn walk(root: &Path, depth: usize, each: &mut dyn FnMut(&Path)) {
    let Ok(rd) = std::fs::read_dir(root) else { return };
    for e in rd.flatten() {
        let Ok(ft) = e.file_type() else { continue };
        let p = e.path();
        if ft.is_dir() && depth > 0 {
            walk(&p, depth - 1, each);
        } else if ft.is_file() {
            each(&p);
        }
    }
}

impl Index {
    /// Index the analyses under `anlz_root` (rekordbox's `share/PIONEER/USBANLZ`), finding
    /// their audio in `music` (searched whole). Read only.
    pub fn build(anlz_root: &Path, music: &[PathBuf]) -> Index {
        let mut files: HashMap<String, Vec<PathBuf>> = HashMap::new();
        for root in music {
            walk(root, 12, &mut |p| {
                let audio = p.extension().and_then(|e| e.to_str()).is_some_and(|e| AUDIO.contains(&e.to_ascii_lowercase().as_str()));
                if audio && let Some(n) = p.file_name() {
                    files.entry(n.to_string_lossy().to_lowercase()).or_default().push(p.to_owned());
                }
            });
        }
        let mut dats = vec![];
        walk(anlz_root, 4, &mut |p| {
            if p.file_name().is_some_and(|n| n.eq_ignore_ascii_case("ANLZ0000.DAT")) {
                dats.push(p.to_owned());
            }
        });
        dats.sort();
        let mut index = Index::default();
        for dat in dats {
            let Ok(bytes) = std::fs::read(&dat) else { continue };
            let Some(path) = wo_usb::anlz::read(&bytes).path else { continue };
            index.stats.analyses += 1;
            let file_name = path.rsplit(['/', '\\']).next().unwrap_or(&path).to_owned();
            let audio = if Path::new(&path).is_absolute() && Path::new(&path).is_file() {
                Some(PathBuf::from(&path))
            } else {
                let found = files.get(&file_name.to_lowercase());
                if found.is_some_and(|f| f.len() > 1) {
                    index.stats.ambiguous += 1;
                }
                found.and_then(|f| f.first().cloned())
            };
            let tags = audio.as_deref().and_then(tags::read).unwrap_or_default();
            if audio.is_some() {
                index.stats.with_audio += 1;
            }
            let wetowl_id = tags.comment.split_whitespace().find_map(|w| w.strip_prefix("wetowl:")?.parse().ok());
            let analysed = std::fs::metadata(&dat).and_then(|m| m.modified()).ok();
            index.push(Entry { dat, file_name, audio, tags, wetowl_id, analysed });
        }
        index
    }

    fn push(&mut self, e: Entry) {
        let i = self.entries.len();
        let mut keys = vec![norm(&e.title())];
        if let Some(stem) = Path::new(&e.file_name).file_stem() {
            keys.push(norm(&stem.to_string_lossy()));
        }
        if let Some(b) = bare_stem(&e.file_name) {
            keys.push(norm(&b));
        }
        keys.sort();
        keys.dedup();
        for k in keys {
            self.by_title.entry(k).or_default().push(i);
        }
        self.entries.push(e);
    }

    /// The record a deck shows: by title, then artist and album to tell same-titled ones
    /// apart, then the one with audio, then the newest analysis.
    pub fn find(&self, title: &str, artist: &str, album: &str) -> Option<&Entry> {
        let hits = self.by_title.get(&norm(title))?;
        let (artist, album) = (norm(artist), norm(album));
        let score = |e: &Entry| {
            let mut s = 0;
            if !artist.is_empty() && norm(&e.tags.artist) == artist {
                s += 4;
            }
            if !album.is_empty() && norm(&e.tags.album) == album {
                s += 2;
            }
            if e.audio.is_some() {
                s += 1;
            }
            (s, e.analysed)
        };
        hits.iter().map(|&i| &self.entries[i]).max_by(|a, b| score(a).cmp(&score(b)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(file: &str, title: &str, artist: &str, audio: bool) -> Entry {
        Entry {
            dat: PathBuf::from(format!("/anlz/{file}/ANLZ0000.DAT")),
            file_name: file.into(),
            audio: audio.then(|| PathBuf::from(format!("/music/{file}"))),
            tags: Tags { title: title.into(), artist: artist.into(), ..Default::default() },
            wetowl_id: None,
            analysed: None,
        }
    }

    #[test]
    fn finds_by_title_artist_and_file_name() {
        let mut ix = Index::default();
        ix.push(entry("03 XXL.m4a", "XXL", "", true));
        ix.push(entry("Bum Bum.mp3", "Bum Bum", "Mabel", true));
        ix.push(entry("Bum Bum (2).mp3", "Bum Bum", "Someone Else", true));
        ix.push(entry("05 Hermeth - Double G.mp3", "", "", false));
        assert_eq!(ix.find("XXL", "", "").unwrap().file_name, "03 XXL.m4a");
        assert_eq!(ix.find("  xxl ", "", "").unwrap().file_name, "03 XXL.m4a");
        assert_eq!(ix.find("Bum Bum", "Mabel", "").unwrap().tags.artist, "Mabel");
        assert_eq!(ix.find("Bum Bum", "Someone Else", "").unwrap().file_name, "Bum Bum (2).mp3");
        // untagged: by its file name, with or without the track number
        assert!(ix.find("05 Hermeth - Double G", "", "").is_some());
        assert!(ix.find("Hermeth - Double G", "", "").is_some());
        assert!(ix.find("Nothing Like It", "", "").is_none());
    }

    #[test]
    fn bare_stems() {
        assert_eq!(bare_stem("03 XXL.m4a").as_deref(), Some("XXL"));
        assert_eq!(bare_stem("12. Track.mp3").as_deref(), Some("Track"));
        assert_eq!(bare_stem("XXL.m4a"), None);
        assert_eq!(bare_stem("2 Times.m4a").as_deref(), Some("Times"));
    }
}
