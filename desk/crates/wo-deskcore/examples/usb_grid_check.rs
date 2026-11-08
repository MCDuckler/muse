//! How well rekordbox's grids sit on the audio as the decks decode it: for each record on
//! a stick, every beat's nearest kick (a low-band onset within ±60 ms), and the median
//! of those offsets. A codec whose records all sit late or early by the same amount has
//! a decoder delay the decks and rekordbox do not share.
//!
//! `cargo run --release -p wo-deskcore --example usb_grid_check [ROOT] [--ffmpeg] [--trimmed]`
//! (`--ffmpeg`: also decoded by ffmpeg, which cuts an MP3's encoder delay, to compare;
//! `--trimmed`: the decks' own decoding cut the same way, as the house's records are)
use std::path::Path;

const RATE: u32 = 48_000;
/// One onset frame: 1 ms.
const HOP: usize = 48;

fn mono(pcm: &[i16]) -> Vec<f32> {
    pcm.chunks_exact(2).map(|f| (f[0] as f32 + f[1] as f32) / 65536.0).collect()
}

/// A kick's onset strength, a frame a millisecond: the rise of the low band's energy.
fn onsets(x: &[f32]) -> Vec<f32> {
    // two one-pole low-passes at ~150 Hz
    let a = (-2.0 * std::f32::consts::PI * 150.0 / RATE as f32).exp();
    let (mut y1, mut y2) = (0.0f32, 0.0f32);
    let mut energy = Vec::with_capacity(x.len() / HOP + 1);
    let mut acc = 0.0f32;
    for (i, &s) in x.iter().enumerate() {
        y1 = (1.0 - a) * s + a * y1;
        y2 = (1.0 - a) * y1 + a * y2;
        acc += y2 * y2;
        if (i + 1) % HOP == 0 {
            energy.push((acc / HOP as f32 + 1e-9).ln());
            acc = 0.0;
        }
    }
    // the rise over 4 ms, only upward
    (0..energy.len()).map(|i| if i >= 4 { (energy[i] - energy[i - 4]).max(0.0) } else { 0.0 }).collect()
}

/// The median offset (ms, + = the kick after the beat) and how many beats had a clear one.
fn offsets(beats: &[f64], on: &[f32]) -> Option<(f64, f64, usize)> {
    let mut v = vec![];
    for &b in beats {
        let c = (b * 1000.0).round() as i64;
        let (lo, hi) = ((c - 60).max(0) as usize, ((c + 60) as usize).min(on.len().saturating_sub(1)));
        if lo >= hi {
            continue;
        }
        let (i, &peak) = on[lo..=hi].iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1))?;
        // a clear kick: well above what the window holds otherwise
        let mean = on[lo..=hi].iter().sum::<f32>() / (hi - lo + 1) as f32;
        if peak > 1.5 && peak > 4.0 * mean {
            v.push((lo + i) as f64 - b * 1000.0);
        }
    }
    if v.len() < 16 {
        return None;
    }
    v.sort_by(f64::total_cmp);
    let med = v[v.len() / 2];
    let mut dev: Vec<f64> = v.iter().map(|x| (x - med).abs()).collect();
    dev.sort_by(f64::total_cmp);
    Some((med, dev[dev.len() / 2], v.len()))
}

fn ffmpeg(path: &Path) -> Option<Vec<i16>> {
    let out = std::process::Command::new("ffmpeg").args(["-v", "error", "-i"]).arg(path).args(["-f", "s16le", "-ac", "2", "-ar", "48000", "-"]).output().ok()?;
    out.status.success().then(|| out.stdout.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let with_ffmpeg = args.iter().any(|a| a == "--ffmpeg");
    // --trimmed: decoded the house's way (an MP3's start-up cut), not the decks' for a stick
    let trimmed = args.iter().any(|a| a == "--trimmed");
    let roots: Vec<std::path::PathBuf> = match args.iter().find(|a| !a.starts_with("--")) {
        Some(r) => vec![r.into()],
        None => wo_usb::find(),
    };
    let mut by_kind: std::collections::BTreeMap<String, Vec<f64>> = Default::default();
    for root in roots {
        let stick = wo_usb::Stick::open(&root).expect("a stick");
        println!("{}: {} records", stick.name, stick.tracks.len());
        for t in &stick.tracks {
            let a = t.analysis().unwrap_or_default();
            let ext = t.path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
            let mut pcm: Vec<i16> = vec![];
            let decoded = if trimmed { wo_decode::decode(&t.path, RATE, &mut pcm) } else { wo_decode::decode_as_rekordbox(&t.path, RATE, &mut pcm) };
            if let Err(e) = decoded {
                println!("  #{} {}: {e}", t.id, t.title);
                continue;
            }
            let ours = offsets(&a.beats, &onsets(&mono(&pcm)));
            let theirs = if with_ffmpeg { ffmpeg(&t.path).and_then(|p| offsets(&a.beats, &onsets(&mono(&p)))) } else { None };
            let f = |o: Option<(f64, f64, usize)>| o.map_or("     —".to_owned(), |(m, d, n)| format!("{m:+6.1} ms ±{d:4.1} ({n:3})"));
            println!("  #{:<3} {:4} {:<44} decks {}{}", t.id, ext, t.title.chars().take(44).collect::<String>(), f(ours), if with_ffmpeg { format!("   ffmpeg {}", f(theirs)) } else { String::new() });
            if let Some((m, _, _)) = ours {
                by_kind.entry(format!("{ext} decks")).or_default().push(m);
            }
            if let Some((m, _, _)) = theirs {
                by_kind.entry(format!("{ext} ffmpeg")).or_default().push(m);
            }
        }
    }
    println!("median of the records' medians:");
    for (k, mut v) in by_kind {
        v.sort_by(f64::total_cmp);
        println!("  {k:<14} {:+6.1} ms over {} records (spread {:+.1} … {:+.1})", v[v.len() / 2], v.len(), v[v.len() / 10], v[v.len() * 9 / 10]);
    }
}
