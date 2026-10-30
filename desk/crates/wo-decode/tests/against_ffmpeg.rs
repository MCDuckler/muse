//! Decodes a real record both ways — here, and ffmpeg as v1 and the house do (the
//! house's beat grids count from ffmpeg's first sample) — and finds how far apart
//! they are by cross-correlation. They must line up within a sample or two.
//!
//! Records: WO_DECODE_RECORDS=a.m4a:b.mp3:… or the desktop app's fetched folder.
use std::path::{Path, PathBuf};
use std::process::Command;

const RATE: u32 = 48_000;

fn records() -> Vec<PathBuf> {
    if let Ok(list) = std::env::var("WO_DECODE_RECORDS") {
        return list.split(':').map(PathBuf::from).collect();
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let mut v: Vec<PathBuf> = ["fetched", "stems"]
        .iter()
        .filter_map(|d| std::fs::read_dir(Path::new(&home).join(".local/share/io.wetowl.muse").join(d)).ok())
        .flat_map(|r| r.filter_map(|e| e.ok().map(|e| e.path())))
        .filter(|p| p.extension().is_some_and(|e| e == "m4a"))
        .collect();
    v.sort();
    v.truncate(4);
    v
}

fn ffmpeg(path: &Path) -> Option<Vec<i16>> {
    let out = Command::new("ffmpeg")
        .args(["-v", "error", "-i"])
        .arg(path)
        .args(["-f", "s16le", "-ac", "2", "-ar", &RATE.to_string(), "-"])
        .output()
        .ok()?;
    out.status.success().then(|| out.stdout.as_chunks::<2>().0.iter().map(|b| i16::from_le_bytes(*b)).collect())
}

/// The lag of `b` against `a` (positive: b is late), within ±max frames, on the left
/// channel of the first `len` frames past a second in.
fn lag(a: &[i16], b: &[i16], max: i64, len: usize) -> (i64, f64) {
    let at = RATE as usize;
    let l = |x: &[i16], i: i64| -> f64 {
        let i = i as usize;
        if i * 2 < x.len() { x[i * 2] as f64 } else { 0.0 }
    };
    let mut best = (0, f64::MIN);
    for d in -max..=max {
        let mut s = 0.0;
        let (mut ea, mut eb) = (0.0, 0.0);
        for i in 0..len as i64 {
            let x = l(a, at as i64 + i);
            let y = l(b, at as i64 + i + d);
            s += x * y;
            ea += x * x;
            eb += y * y;
        }
        let c = s / (ea * eb).sqrt().max(1.0);
        if c > best.1 {
            best = (d, c);
        }
    }
    best
}

#[test]
fn lines_up_with_ffmpeg() {
    let recs = records();
    if recs.is_empty() || ffmpeg(Path::new("/dev/null")).is_none() && Command::new("ffmpeg").arg("-version").output().is_err() {
        eprintln!("no records or no ffmpeg here: skipped");
        return;
    }
    for r in recs {
        let Some(want) = ffmpeg(&r) else { continue };
        let mut got = vec![];
        let info = wo_decode::decode(&r, RATE, &mut got).unwrap();
        let (d, c) = lag(&want, &got, 4096, 8192);
        let len_diff = got.len() as i64 / 2 - want.len() as i64 / 2;
        eprintln!(
            "{}: {} Hz {} ch, edit {:?}: lag {d} frames ({:.2} ms), corr {c:.4}; length here − ffmpeg {len_diff} frames",
            r.file_name().unwrap().to_string_lossy(),
            info.rate_in,
            info.channels_in,
            info.edit,
            d as f64 * 1000.0 / RATE as f64
        );
        assert!(c > 0.98, "the two decodes don't match at all (corr {c:.3})");
        assert!(len_diff.abs() <= 2, "{len_diff} frames longer than ffmpeg's");
        assert!(d.abs() <= 2, "{} frames off ffmpeg ({:.2} ms): every beat grid would be off by that", d, d as f64 * 1000.0 / RATE as f64);
    }
}
