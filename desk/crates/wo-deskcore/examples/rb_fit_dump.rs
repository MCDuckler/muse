//! rekordbox's waveform columns beside the audio they were made from, for fitting the
//! Desk's own to them (wo-wave rb.rs; plans/wetowl-desk-rekordbox-look.md §A4).
//!
//! For each analysed record on the plugged-in stick (read only): its audio decoded as
//! rekordbox decodes it, through octave bands (40 Hz … 10 kHz) and the Desk's own analyser,
//! one row a column (150 a second, rekordbox's own rate): each octave's peak and RMS, the
//! whole's peak and RMS, the Desk's three bands' peak and RMS; and rekordbox's own columns
//! (PWV7's three bands, PWV5's colour and height, PWV3's height and whiteness).
//!
//!   cargo run --release -p wo-deskcore --example rb_fit_dump -- OUT_DIR [records] [workers]
//!
//! Writes OUT_DIR/<id>.f32 (rows of [`FEATURES`] little-endian f32) and OUT_DIR/<id>.rb
//! (rows of 6 bytes: low, mid, high, PWV5 big endian, PWV3), and OUT_DIR/index.tsv.
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const RATE: u32 = 48_000;
const PER_COL: usize = 320; // 48 000 / 150
const CENTRES: [f32; 9] = [40.0, 80.0, 160.0, 315.0, 630.0, 1250.0, 2500.0, 5000.0, 10_000.0];
/// 9 octaves × (peak, RMS), the whole × (peak, RMS), the Desk's 3 bands × (peak, RMS).
const FEATURES: usize = 9 * 2 + 2 + 6;

#[derive(Clone, Copy, Default)]
struct Bq {
    b: [f32; 3],
    a: [f32; 2],
    x: [f32; 2],
    y: [f32; 2],
}

impl Bq {
    /// RBJ band-pass, 0 dB at its centre.
    fn band(hz: f32, q: f32) -> Bq {
        let w = 2.0 * std::f32::consts::PI * hz / RATE as f32;
        let (s, c) = w.sin_cos();
        let alpha = s / (2.0 * q);
        let a0 = 1.0 + alpha;
        Bq { b: [alpha / a0, 0.0, -alpha / a0], a: [-2.0 * c / a0, (1.0 - alpha) / a0], ..Default::default() }
    }

    fn run(&mut self, x: f32) -> f32 {
        let y = self.b[0] * x + self.b[1] * self.x[0] + self.b[2] * self.x[1] - self.a[0] * self.y[0] - self.a[1] * self.y[1];
        self.x = [x, self.x[0]];
        self.y = [y, self.y[0]];
        y
    }
}

struct Collect {
    mono: Vec<f32>,
    analyser: wo_wave::Analyser,
}

impl wo_decode::Sink for Collect {
    fn take(&mut self, pcm: &[i16]) -> Result<(), wo_decode::Error> {
        self.analyser.feed(pcm);
        self.mono.extend(pcm.as_chunks::<2>().0.iter().map(|f| (f[0] as f32 + f[1] as f32) * (0.5 / 32768.0)));
        Ok(())
    }
}

fn features(mono: &[f32], desk: &wo_wave::Wave) -> Vec<f32> {
    let mut bank: Vec<Bq> = CENTRES.iter().map(|&c| Bq::band(c, std::f32::consts::SQRT_2)).collect();
    let n = mono.len() / PER_COL;
    let mut out = Vec::with_capacity(n * FEATURES);
    let dec = |q: u8| {
        let v = q as f32 / 255.0;
        v * v * 2.0
    };
    for col in 0..n {
        let mut peak = [0f32; 10];
        let mut sq = [0f32; 10];
        for &x in &mono[col * PER_COL..(col + 1) * PER_COL] {
            for (k, b) in bank.iter_mut().enumerate() {
                let y = b.run(x);
                peak[k] = peak[k].max(y.abs());
                sq[k] += y * y;
            }
            peak[9] = peak[9].max(x.abs());
            sq[9] += x * x;
        }
        for k in 0..10 {
            out.push(peak[k]);
            out.push((sq[k] / PER_COL as f32).sqrt());
        }
        let c = desk.cols.get(col).copied().unwrap_or_default();
        for k in 0..3 {
            out.push(dec(c.peak[k]));
            out.push(dec(c.rms[k]));
        }
    }
    out
}

fn one(t: &wo_usb::Track, out: &Path) -> Result<String, String> {
    let a = t.analysis().map_err(|e| e.to_string())?;
    let w = &a.waves;
    if w.bands.is_empty() || w.rgb.is_empty() || w.blue.is_empty() {
        return Err("no waveforms".into());
    }
    let mut sink = Collect { mono: vec![], analyser: wo_wave::Analyser::new(RATE) };
    wo_decode::decode_as_rekordbox(&t.path, RATE, &mut sink).map_err(|e| e.to_string())?;
    sink.analyser.finish();
    let wave = sink.analyser.wave();
    let wave = wave.lock().unwrap();
    let f = features(&sink.mono, &wave);
    let rows = f.len() / FEATURES;
    std::fs::write(out.join(format!("{}.f32", t.id)), f.iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<u8>>()).map_err(|e| e.to_string())?;
    let n = w.bands.len().min(w.rgb.len()).min(w.blue.len());
    let mut rb = Vec::with_capacity(n * 6);
    for i in 0..n {
        rb.extend(w.bands[i]);
        rb.extend(w.rgb[i].to_be_bytes());
        rb.push(w.blue[i]);
    }
    std::fs::write(out.join(format!("{}.rb", t.id)), rb).map_err(|e| e.to_string())?;
    Ok(format!("{}\t{rows}\t{n}\t{}\t{}\t{}", t.id, t.path.extension().and_then(|e| e.to_str()).unwrap_or(""), t.title, t.artist))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out = PathBuf::from(args.get(1).expect("an out dir"));
    let most: usize = args.get(2).and_then(|n| n.parse().ok()).unwrap_or(usize::MAX);
    let workers: usize = args.get(3).and_then(|n| n.parse().ok()).unwrap_or(4);
    std::fs::create_dir_all(&out).unwrap();
    let root = wo_usb::find().into_iter().next().expect("no stick plugged in");
    let stick = wo_usb::Stick::open(&root).unwrap();
    let tracks: Arc<Mutex<Vec<wo_usb::Track>>> = Arc::new(Mutex::new(stick.tracks.iter().take(most).cloned().collect()));
    let index = Arc::new(Mutex::new(vec![]));
    let hs: Vec<_> = (0..workers)
        .map(|_| {
            let (tracks, index, out) = (tracks.clone(), index.clone(), out.clone());
            std::thread::spawn(move || {
                while let Some(t) = { tracks.lock().unwrap().pop() } {
                    match one(&t, &out) {
                        Ok(line) => {
                            eprintln!("{line}");
                            index.lock().unwrap().push(line);
                        }
                        Err(e) => eprintln!("{} {}: {e}", t.id, t.title),
                    }
                }
            })
        })
        .collect();
    for h in hs {
        h.join().unwrap();
    }
    let mut lines = index.lock().unwrap().clone();
    lines.sort();
    std::fs::write(out.join("index.tsv"), lines.join("\n") + "\n").unwrap();
    eprintln!("{} records into {}", lines.len(), out.display());
}
