//! Every rekordbox effect on a record off the plugged-in stick, rendered offline to WAV
//! files to listen to: four bars dry, four with the effect, two after it is turned off
//! (the tails), in time with rekordbox's grid for the record. LEVEL/DEPTH and the COLOR
//! FX's PARAMETER at their middles, each effect's first beats: as rekordbox is recorded
//! for `desk/crates/wo-engine/data/fx_measure.py`, which measures both alike. `dry.wav`
//! (the whole record, decoded as rekordbox does) and `grid.txt` (its beats, seconds;
//! the first line bar one's index) are what the recordings are lined up on.
//!
//!   cargo run --release -p wo-deskcore --example fx_demo -- OUT_DIR [record index on the stick]
use std::path::Path;

use wo_engine::{BeatFx, BeatFxKind, Channels, ColorFxKind, DeckId, Engine, FxTarget, Gains, Output, ReleaseFxKind};

const R: u32 = 48_000;
const BLOCK: usize = 480;

struct Pcm(Vec<i16>);

impl wo_decode::Sink for Pcm {
    fn take(&mut self, pcm: &[i16]) -> Result<(), wo_decode::Error> {
        self.0.extend_from_slice(pcm);
        Ok(())
    }
}

fn wav(path: &Path, lr: &[f32]) {
    let data: Vec<u8> = lr.iter().flat_map(|v| ((v.clamp(-1.0, 1.0) * 32_767.0) as i16).to_le_bytes()).collect();
    let mut f = b"RIFF".to_vec();
    f.extend((36 + data.len() as u32).to_le_bytes());
    f.extend(b"WAVEfmt ");
    f.extend(16u32.to_le_bytes());
    f.extend(1u16.to_le_bytes());
    f.extend(2u16.to_le_bytes());
    f.extend(R.to_le_bytes());
    f.extend((R * 4).to_le_bytes());
    f.extend(4u16.to_le_bytes());
    f.extend(16u16.to_le_bytes());
    f.extend(b"data");
    f.extend((data.len() as u32).to_le_bytes());
    f.extend(data);
    std::fs::write(path, f).unwrap();
}

fn render(e: &Engine, seconds: f64, out: &mut Vec<f32>) {
    let n = (seconds * R as f64 / BLOCK as f64).round() as usize;
    let mut m = vec![0f32; BLOCK * 2];
    for _ in 0..n {
        let mut outs: [Option<&mut [f32]>; 4] = [None, None, None, None];
        e.render(&mut m, &mut outs).unwrap();
        out.extend_from_slice(&m);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out = Path::new(args.get(1).expect("an out dir")).to_path_buf();
    let which: usize = args.get(2).and_then(|n| n.parse().ok()).unwrap_or(0);
    std::fs::create_dir_all(&out).unwrap();
    let root = wo_usb::find().into_iter().next().expect("no stick plugged in");
    let stick = wo_usb::Stick::open(&root).unwrap();
    let t = stick.tracks.iter().filter(|t| t.anlz.is_some()).nth(which).expect("no such record");
    let a = t.analysis().unwrap();
    println!("{} — {} ({:.2} BPM)", t.title, t.artist, t.bpm);
    let mut pcm = Pcm(vec![]);
    wo_decode::decode_as_rekordbox(&t.path, R, &mut pcm).unwrap();
    wav(&out.join("dry.wav"), &pcm.0.iter().map(|v| *v as f32 / 32_768.0).collect::<Vec<_>>());
    let grid: String = std::iter::once(a.bar_one.to_string()).chain(a.beats.iter().map(|b| format!("{b:.6}"))).collect::<Vec<_>>().join("
");
    std::fs::write(out.join("grid.txt"), grid + "
").unwrap();
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let d = DeckId::new(0).unwrap();
    let mut src = e.new_source(Channels::Stereo, (pcm.0.len() / 2) as i64).unwrap();
    src.append(&pcm.0).unwrap();
    src.finish();
    let deck = e.deck(d);
    deck.set_source(0, &src);
    deck.set_gains(0, Gains::FULL, 0.0);
    deck.set_level(1.0, 0.0);
    deck.set_beats(&a.beats);
    deck.set_bar_one(a.bar_one);
    deck.set_keylock(false);
    let spb = 60.0 / t.bpm.max(60.0);
    let bar = 4.0 * spb;
    // from a bar a third of the way in
    let start = a.beats.get(a.beats.len() / 3 / 4 * 4 + a.bar_one).copied().unwrap_or(60.0);
    for kind in BeatFxKind::ALL {
        let mut lr = vec![];
        deck.seek(start);
        deck.play(true);
        render(&e, 4.0 * bar, &mut lr);
        let fx = |on| BeatFx { kind, on, level: 0.5, beats: kind.first_beats(), param: 0.5, target: FxTarget::Deck(d), tempo: d, bpm: None };
        e.set_beat_fx(0, &fx(true));
        render(&e, 4.0 * bar, &mut lr);
        e.set_beat_fx(0, &fx(false));
        render(&e, 2.0 * bar, &mut lr);
        deck.play(false);
        render(&e, 4.0, &mut vec![]);
        let name = format!("beat-{:02}-{}.wav", kind as i32, kind.name().to_lowercase().replace(' ', "-"));
        wav(&out.join(&name), &lr);
        println!("{name}");
    }
    for kind in ColorFxKind::ALL {
        let mut lr = vec![];
        deck.seek(start);
        deck.play(true);
        render(&e, 2.0 * bar, &mut lr);
        // the knob turned left over two bars, then right over two, then back to the middle
        let steps = 64;
        for i in 0..steps * 2 {
            let k = if i < steps { -(i as f32) / steps as f32 } else { (i - steps) as f32 / steps as f32 };
            if kind == ColorFxKind::Filter {
                deck.set_filter(k);
            } else {
                deck.set_color_fx(kind, k, 0.5);
            }
            render(&e, 4.0 * bar / (steps * 2) as f64, &mut lr);
        }
        deck.set_filter(0.0);
        deck.set_color_fx(kind, 0.0, 0.5);
        render(&e, 2.0 * bar, &mut lr);
        deck.play(false);
        render(&e, 4.0, &mut vec![]);
        let name = format!("color-{}.wav", kind.name().to_lowercase().replace(' ', "-"));
        wav(&out.join(&name), &lr);
        println!("{name}");
    }
    for kind in ReleaseFxKind::ALL {
        let mut lr = vec![];
        deck.seek(start);
        deck.play(true);
        render(&e, 4.0 * bar, &mut lr);
        e.release_fx(0, kind, true, 1.0);
        render(&e, 2.0 * bar, &mut lr);
        e.release_fx(0, kind, false, 1.0);
        render(&e, 2.0 * bar, &mut lr);
        deck.play(false);
        render(&e, 4.0, &mut vec![]);
        let name = format!("release-{}.wav", kind.name().to_lowercase().replace(' ', "-"));
        wav(&out.join(&name), &lr);
        println!("{name}");
    }
}
