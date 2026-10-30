//! wo-play: two records on two decks, the second synced to the first — the Desk's
//! engine, decoder and beat grids end to end, before there is a window to show them.
//!
//!   wo-play A.m4a [B.m4a] [--seconds 60] [--b-at 10] [--keylock] [--offline out.wav]
//!
//! B comes in synced on A's bar after --b-at seconds. Beat grids: the desktop app's
//! cached `<id>-beats-v1.json` beside the record's id (a steady tempo fitted through
//! them), else none (B then just plays). --offline renders to a WAV instead of the
//! sound card, as fast as it goes. To listen silently on Linux: PULSE_SINK=<null sink>.
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use wo_engine::{Channels, DeckId, Engine, Gains, Output, Source};

struct Args {
    a: PathBuf,
    b: Option<PathBuf>,
    seconds: f64,
    b_at: f64,
    keylock: bool,
    offline: Option<PathBuf>,
}

fn args() -> Result<Args, String> {
    let mut it = std::env::args().skip(1);
    let mut files = vec![];
    let (mut seconds, mut b_at, mut keylock, mut offline) = (60.0, 10.0, false, None);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--seconds" => seconds = it.next().and_then(|v| v.parse().ok()).ok_or("--seconds N")?,
            "--b-at" => b_at = it.next().and_then(|v| v.parse().ok()).ok_or("--b-at N")?,
            "--keylock" => keylock = true,
            "--offline" => offline = Some(PathBuf::from(it.next().ok_or("--offline out.wav")?)),
            "-h" | "--help" => return Err(String::new()),
            f => files.push(PathBuf::from(f)),
        }
    }
    let mut files = files.into_iter();
    let a = files.next().ok_or("a record to play")?;
    Ok(Args { a, b: files.next(), seconds, b_at, keylock, offline })
}

/// The app's cached beats for a record named by its id, a steady tempo fitted through
/// them (least squares on beat index), and which beat is the first of a bar.
fn beats_for(record: &Path) -> Option<(Vec<f64>, usize)> {
    let id = record.file_stem()?.to_str()?.split('-').next()?.to_owned();
    let home = std::env::var("HOME").ok()?;
    let file = Path::new(&home).join(".local/share/io.wetowl.muse/stems").join(format!("{id}-beats-v1.json"));
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
    let (sx, sy) = ((0..raw.len()).map(|i| i as f64).sum::<f64>(), raw.iter().sum::<f64>());
    let sxx = (0..raw.len()).map(|i| (i * i) as f64).sum::<f64>();
    let sxy = raw.iter().enumerate().map(|(i, y)| i as f64 * y).sum::<f64>();
    let spb = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    let first = (sy - spb * sx) / n;
    let grid: Vec<f64> = (0..raw.len()).map(|i| first + spb * i as f64).collect();
    let down = ms("downbeats_ms");
    let bar_one = down
        .first()
        .and_then(|&d| grid.iter().enumerate().min_by(|a, b| (a.1 - d).abs().total_cmp(&(b.1 - d).abs())).map(|(i, _)| i % 4))
        .unwrap_or(0);
    Some((grid, bar_one))
}

/// A record decoding into a new source on its own thread; the deck can play what is in.
fn load(e: &Engine, d: DeckId, path: &Path) -> Result<thread::JoinHandle<Source>, String> {
    let mut source = e.new_source(Channels::Stereo, e.rate() as i64 * 600).map_err(|e| e.to_string())?;
    let deck = e.deck(d);
    deck.set_source(0, &source);
    deck.set_gains(0, Gains::FULL, 0.0);
    match beats_for(path) {
        Some((grid, bar_one)) => {
            eprintln!("{d:?}: {} beats, {:.2} bpm, bar one at beat {bar_one}", grid.len(), 60.0 / (grid[1] - grid[0]));
            deck.set_beats(&grid);
            deck.set_bar_one(bar_one);
        }
        None => eprintln!("{d:?}: no beat grid"),
    }
    let (path, rate) = (path.to_owned(), e.rate());
    Ok(thread::spawn(move || {
        let t = Instant::now();
        match wo_decode::decode_into_source(&path, &mut source, rate) {
            Ok(info) => eprintln!(
                "{}: {:.1} s decoded in {:.2} s ({} Hz → {rate}, edit {:?})",
                path.display(),
                info.seconds(),
                t.elapsed().as_secs_f64(),
                info.rate_in,
                info.edit
            ),
            Err(err) => eprintln!("{}: {err}", path.display()),
        }
        source
    }))
}

fn status(e: &Engine, t: f64) {
    let (a, b) = (e.deck(DeckId::A).read(), e.deck(DeckId::B).read());
    let l = e.load();
    eprintln!(
        "{t:6.1}s  A {:7.2}s ×{:.4}  |  B {:7.2}s ×{:.4} {} err {:+.2} ms  |  load {:.0}% worst {:.0}% late {}",
        a.heard,
        a.rate,
        b.heard,
        b.rate,
        if b.synced { "SYNC" } else { "    " },
        b.phase_error * 1000.0,
        l.average * 100.0,
        l.worst * 100.0,
        l.late
    );
}

fn main() {
    let args = match args() {
        Ok(a) => a,
        Err(why) => {
            eprintln!("{why}\nwo-play A.m4a [B.m4a] [--seconds 60] [--b-at 10] [--keylock] [--offline out.wav]");
            std::process::exit(2);
        }
    };
    let output = if args.offline.is_some() { Output::Offline } else { Output::Device };
    let e = match Engine::start(Some(48_000), output) {
        Ok(e) => e,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    };
    eprintln!("engine: {} Hz, latency {:.1} ms", e.rate(), e.latency() * 1000.0);
    let ja = load(&e, DeckId::A, &args.a).unwrap();
    let jb = args.b.as_ref().map(|b| load(&e, DeckId::B, b).unwrap());
    let (a, b) = (e.deck(DeckId::A), e.deck(DeckId::B));
    a.set_keylock(args.keylock);
    b.set_keylock(args.keylock);
    b.set_level(0.0, 0.0);
    a.play(true);

    let mut wav = vec![];
    let mut b_in = false;
    let started = Instant::now();
    let mut t = 0.0;
    let mut next_status = 0.0;
    let block = 480;
    let (mut m, mut da, mut db) = (vec![0f32; block * 2], vec![0f32; block * 2], vec![0f32; block * 2]);
    while t < args.seconds {
        if !b_in && args.b.is_some() && t >= args.b_at {
            b.seek(30.0); // into the record, off its first beats
            b.start_with(DeckId::A, 4, None, 0.0);
            b.sync(DeckId::A, 4, 0.0);
            b.set_level(1.0, 4.0);
            a.set_level(0.6, 4.0);
            b_in = true;
        }
        if t >= next_status {
            status(&e, t);
            next_status += 1.0;
        }
        if output == Output::Offline {
            e.render(&mut m, &mut [Some(&mut da), Some(&mut db), None, None]).unwrap();
            wav.extend_from_slice(&m);
            t += block as f64 / e.rate() as f64;
        } else {
            thread::sleep(Duration::from_millis(50));
            t = started.elapsed().as_secs_f64();
        }
    }
    status(&e, t);
    if let Some(out) = args.offline {
        write_wav(&out, e.rate(), &wav).unwrap();
        eprintln!("wrote {}", out.display());
    }
    drop(ja.join());
    if let Some(j) = jb {
        drop(j.join());
    }
}

/// A 16-bit stereo WAV.
fn write_wav(path: &Path, rate: u32, x: &[f32]) -> std::io::Result<()> {
    let data = (x.len() * 2) as u32;
    let mut b = Vec::with_capacity(44 + data as usize);
    b.extend_from_slice(b"RIFF");
    b.extend_from_slice(&(36 + data).to_le_bytes());
    b.extend_from_slice(b"WAVEfmt ");
    b.extend_from_slice(&16u32.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&2u16.to_le_bytes());
    b.extend_from_slice(&rate.to_le_bytes());
    b.extend_from_slice(&(rate * 4).to_le_bytes());
    b.extend_from_slice(&4u16.to_le_bytes());
    b.extend_from_slice(&16u16.to_le_bytes());
    b.extend_from_slice(b"data");
    b.extend_from_slice(&data.to_le_bytes());
    for s in x {
        b.extend_from_slice(&((s * 32767.0).round().clamp(-32767.0, 32767.0) as i16).to_le_bytes());
    }
    std::fs::write(path, b)
}
