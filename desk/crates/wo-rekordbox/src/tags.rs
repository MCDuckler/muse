//! An audio file's own tags (title, artist, album, comment), as rekordbox reads them when
//! it imports the file. Only the container is opened; nothing is decoded.
use std::fs::File;
use std::path::Path;

use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::{MetadataOptions, MetadataRevision, RawValue, StandardTag};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Tags {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub comment: String,
}

/// The file's tags; `None` when it cannot be opened as audio.
pub fn read(path: &Path) -> Option<Tags> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let mut format = symphonia::default::get_probe().probe(&hint, mss, FormatOptions::default(), MetadataOptions::default()).ok()?;
    let mut tags = Tags::default();
    let mut m = format.metadata();
    // every revision (an ID3 block before the stream, the container's own…); the first wins
    loop {
        if let Some(rev) = m.current() {
            take(rev, &mut tags);
        }
        if m.pop().is_none() {
            break;
        }
    }
    Some(tags)
}

/// `COMM` (ID3), `©cmt` (MP4), `comment` (Vorbis, RIFF).
fn is_comment_key(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    k == "comm" || k == "com" || k.ends_with("cmt") || k == "comment"
}

fn take(rev: &MetadataRevision, t: &mut Tags) {
    let all = rev.media.tags.iter().chain(rev.per_track.iter().flat_map(|p| p.metadata.tags.iter()));
    for tag in all {
        let (slot, v) = match &tag.std {
            Some(StandardTag::TrackTitle(v)) => (&mut t.title, v),
            Some(StandardTag::Artist(v)) => (&mut t.artist, v),
            Some(StandardTag::Album(v)) => (&mut t.album, v),
            Some(StandardTag::Comment(v)) => (&mut t.comment, v),
            // an ID3 COMM frame is not always mapped to a comment, and ffmpeg writes an
            // MP3's "comment" as a TXXX frame: take those by their key, or by a WetOwl id
            _ => match &tag.raw.value {
                RawValue::String(v) if is_comment_key(&tag.raw.key) || v.starts_with("wetowl:") => (&mut t.comment, v),
                _ => continue,
            },
        };
        if slot.is_empty() {
            *slot = v.trim().to_owned();
        }
    }
}
