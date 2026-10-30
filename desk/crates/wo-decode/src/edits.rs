//! An MP4's edit list: where the music starts in the decoded samples and how long it
//! plays. An AAC encoder puts priming frames before the music (1600 or 1024 in the
//! house's records, from the edit list's media_time) and pads the last packet; ffmpeg
//! honours the edit list and symphonia 0.6 does not read it ("edits are not currently
//! supported"). The house's beat grids count from ffmpeg's first sample, so a decode
//! that kept the priming would put every beat 36 ms late. Measured in
//! tests/against_ffmpeg.rs.
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Frames at the record's rate.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Edit {
    /// Decoded frames before the music.
    pub skip: u64,
    /// Frames of music after that (None: to the end).
    pub keep: Option<u64>,
}

/// The audio track's first edit, scaled to `rate`; the default (nothing cut) for a
/// file that is not an MP4 or has no edit list.
pub fn read(path: &Path, rate: u32) -> Edit {
    parse(path, rate).unwrap_or_default()
}

fn parse(path: &Path, rate: u32) -> Option<Edit> {
    let mut f = File::open(path).ok()?;
    let end = f.metadata().ok()?.len();
    let moov = find(&mut f, 0, end, b"moov")?;
    let mvhd = find(&mut f, moov.0, moov.1, b"mvhd")?;
    let movie_scale = timescale(&mut f, mvhd)?;
    let mut at = moov.0;
    while let Some(trak) = find(&mut f, at, moov.1, b"trak") {
        at = trak.1;
        let Some(mdia) = find(&mut f, trak.0, trak.1, b"mdia") else { continue };
        let Some(hdlr) = find(&mut f, mdia.0, mdia.1, b"hdlr") else { continue };
        if bytes::<4>(&mut f, hdlr.0 + 8)? != *b"soun" {
            continue;
        }
        let mdhd = find(&mut f, mdia.0, mdia.1, b"mdhd")?;
        let media_scale = timescale(&mut f, mdhd)?;
        let edts = find(&mut f, trak.0, trak.1, b"edts")?;
        let elst = find(&mut f, edts.0, edts.1, b"elst")?;
        let version = bytes::<1>(&mut f, elst.0)?[0];
        let count = u32::from_be_bytes(bytes::<4>(&mut f, elst.0 + 4)?);
        let mut o = elst.0 + 8;
        let mut lead_in = 0u64; // empty edits: silence before the music (rare)
        for _ in 0..count {
            let (dur, media_time) = if version == 1 {
                (u64::from_be_bytes(bytes::<8>(&mut f, o)?), i64::from_be_bytes(bytes::<8>(&mut f, o + 8)?))
            } else {
                (u32::from_be_bytes(bytes::<4>(&mut f, o)?) as u64, i32::from_be_bytes(bytes::<4>(&mut f, o + 4)?) as i64)
            };
            o += if version == 1 { 20 } else { 12 };
            if media_time < 0 {
                lead_in += dur;
                continue;
            }
            let scale = |v: u64, from: u32| (v as u128 * rate as u128 / from.max(1) as u128) as u64;
            let _ = lead_in; // an empty edit's silence is not cut or added: no house record has one
            return Some(Edit {
                skip: scale(media_time as u64, media_scale),
                keep: (dur > 0).then(|| scale(dur, movie_scale)),
            });
        }
        return None;
    }
    None
}

/// The first box of `kind` within [from, to): its contents' start and its end.
fn find(f: &mut File, from: u64, to: u64, kind: &[u8; 4]) -> Option<(u64, u64)> {
    let mut at = from;
    while at + 8 <= to {
        let head = bytes::<8>(f, at)?;
        let mut size = u32::from_be_bytes(head[..4].try_into().ok()?) as u64;
        let mut body = at + 8;
        if size == 1 {
            size = u64::from_be_bytes(bytes::<8>(f, at + 8)?);
            body = at + 16;
        } else if size == 0 {
            size = to - at;
        }
        if size < 8 {
            return None;
        }
        if &head[4..8] == kind {
            return Some((body, (at + size).min(to)));
        }
        at += size;
    }
    None
}

/// mvhd's or mdhd's timescale (same place in both).
fn timescale(f: &mut File, b: (u64, u64)) -> Option<u32> {
    let version = bytes::<1>(f, b.0)?[0];
    Some(u32::from_be_bytes(bytes::<4>(f, b.0 + if version == 1 { 20 } else { 12 })?))
}

fn bytes<const N: usize>(f: &mut File, at: u64) -> Option<[u8; N]> {
    let mut b = [0u8; N];
    f.seek(SeekFrom::Start(at)).ok()?;
    f.read_exact(&mut b).ok()?;
    Some(b)
}
