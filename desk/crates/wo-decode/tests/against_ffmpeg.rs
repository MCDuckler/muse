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

/// Six-channel s16 from ffmpeg, its own Opus decoder or libopus.
fn ffmpeg6(path: &Path, libopus: bool) -> Vec<i16> {
    let mut cmd = Command::new("ffmpeg");
    cmd.args(["-v", "error"]);
    if libopus {
        cmd.args(["-c:a", "libopus"]);
    }
    let out = cmd.arg("-i").arg(path).args(["-f", "s16le", "-ac", "6", "-"]).output().unwrap();
    assert!(out.status.success());
    out.stdout.as_chunks::<2>().0.iter().map(|b| i16::from_le_bytes(*b)).collect()
}

/// For each channel here, ffmpeg's closest channel and how far off (relative rms).
fn closest(got: &[i16], want: &[i16]) -> Vec<(usize, f64)> {
    let frames = got.len().min(want.len()) / 6;
    (0..6)
        .map(|c| {
            (0..6)
                .map(|w| {
                    let (mut d2, mut e) = (0f64, 0f64);
                    for f in (48_000..frames).step_by(5) {
                        let (a, b) = (got[f * 6 + c] as f64, want[f * 6 + w] as f64);
                        d2 += (a - b) * (a - b);
                        e += b * b;
                    }
                    (w, (d2 / e.max(1.0)).sqrt())
                })
                .min_by(|a, b| a.1.total_cmp(&b.1))
                .unwrap()
        })
        .collect()
}

/// The house's stems (six-channel Opus, mapping family 255) decode as libopus decodes
/// them, in the order ffmpeg's own decoder gives (v1 read them through ffmpeg: drums,
/// bass and the rest, voice), as long as ffmpeg makes them, and summed to stereo they
/// are the record they came from, on the record's own timeline.
#[test]
fn stems_line_up_with_ffmpeg() {
    let dir = Path::new(&std::env::var("HOME").unwrap_or_default()).join(".local/share/io.wetowl.muse/stems");
    let mut stems: Vec<PathBuf> = std::fs::read_dir(&dir)
        .map(|r| r.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.to_string_lossy().ends_with("-stems-v2.opus")).collect())
        .unwrap_or_default();
    // Those whose record the app has fetched first: they get the timeline check too.
    let fetched = |p: &PathBuf| {
        let id = p.file_name().unwrap().to_string_lossy().split('-').next().unwrap().to_string();
        dir.parent().unwrap().join("fetched").join(format!("{id}.m4a")).exists()
    };
    stems.sort_by_key(|p| (!fetched(p), p.clone()));
    stems.truncate(3);
    if stems.is_empty() || Command::new("ffmpeg").arg("-version").output().is_err() {
        eprintln!("no stems or no ffmpeg here: skipped");
        return;
    }
    for s in stems {
        let mut got = vec![];
        let info = wo_decode::decode_stems(&s, RATE, &mut got).unwrap();
        assert_eq!((info.channels_in, info.channels_out), (6, 6));
        let native = ffmpeg6(&s, false);
        eprintln!("{}: {} frames here, {} ffmpeg", s.file_name().unwrap().to_string_lossy(), got.len() / 6, native.len() / 6);
        assert_eq!(got.len(), native.len(), "lengths differ");

        // libopus there too: the same samples, near enough (ffmpeg's wrapper reorders the
        // channels into a 5.1 layout, so each is matched to its closest). Not exact:
        // audiopus_sys bundles libopus 1.3.1 and a system's is newer; a record measured
        // 1e-4 and another 0.027 (−31 dB). A wrong channel is ~1.
        let lib = closest(&got, &ffmpeg6(&s, true));
        eprintln!("  vs libopus: {lib:?}");
        assert!(lib.iter().all(|(_, d)| *d < 0.05), "not libopus's samples: {lib:?}");
        let mut seen: Vec<usize> = lib.iter().map(|(w, _)| *w).collect();
        seen.sort();
        assert_eq!(seen, (0..6).collect::<Vec<_>>());

        // The order: each channel nearest the same channel of ffmpeg's own decoder.
        let own = closest(&got, &native);
        eprintln!("  vs ffmpeg's decoder: {own:?}");
        assert!(own.iter().enumerate().all(|(c, (w, _))| *w == c), "channel order: {own:?}");

        // Summed to stereo it is the record, on the record's timeline (where the app
        // has the record).
        let mut st = vec![];
        wo_decode::decode(&s, RATE, &mut st).unwrap();
        assert_eq!(st.len() / 2, got.len() / 6);
        let id = s.file_name().unwrap().to_string_lossy().split('-').next().unwrap().to_string();
        let rec = dir.parent().unwrap().join("fetched").join(format!("{id}.m4a"));
        if let Some(r) = rec.exists().then(|| ffmpeg(&rec)).flatten() {
            let (d, c) = lag(&r, &st, 4096, 8192);
            eprintln!("  against the record {id}: lag {d} frames, corr {c:.4}");
            assert!(d.abs() <= 2 && c > 0.9, "stems off the record: lag {d}, corr {c}");
        }
    }
}
