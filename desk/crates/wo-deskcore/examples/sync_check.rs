//! Two records off the plugged-in stick on decks A and B, B synced to A (as BEAT SYNC
//! does), rendered offline: how far apart their beats are, by their rekordbox grids,
//! every half second.
//!
//!   cargo run --release -p wo-deskcore --example sync_check -- [index A] [index B] [keylock 0|1]
use wo_engine::{Channels, DeckId, Engine, Gains, Output};

const R: u32 = 48_000;
const BLOCK: usize = 480;

struct Pcm(Vec<i16>);

impl wo_decode::Sink for Pcm {
    fn take(&mut self, pcm: &[i16]) -> Result<(), wo_decode::Error> {
        self.0.extend_from_slice(pcm);
        Ok(())
    }
}

/// The beat (fractional) at `t` seconds of a record with grid `beats`.
fn beat_at(beats: &[f64], t: f64) -> f64 {
    let i = beats.partition_point(|b| *b <= t);
    if i == 0 {
        return (t - beats[0]) / (beats[1] - beats[0]);
    }
    if i >= beats.len() {
        let n = beats.len();
        return (n - 1) as f64 + (t - beats[n - 1]) / (beats[n - 1] - beats[n - 2]);
    }
    (i - 1) as f64 + (t - beats[i - 1]) / (beats[i] - beats[i - 1])
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let ia: usize = args.get(1).and_then(|v| v.parse().ok()).unwrap_or(0);
    let ib: usize = args.get(2).and_then(|v| v.parse().ok()).unwrap_or(1);
    let keylock = args.get(3).is_none_or(|v| v != "0");
    let root = wo_usb::find().into_iter().next().expect("no stick plugged in");
    let stick = wo_usb::Stick::open(&root).unwrap();
    let tracks: Vec<_> = stick.tracks.iter().filter(|t| t.anlz.is_some()).collect();
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let mut grids = vec![];
    let mut srcs = vec![];
    for (k, i) in [ia, ib].into_iter().enumerate() {
        let t = tracks[i];
        let a = t.analysis().unwrap();
        let mut pcm = Pcm(vec![]);
        wo_decode::decode_as_rekordbox(&t.path, R, &mut pcm).unwrap();
        let mut src = e.new_source(Channels::Stereo, (pcm.0.len() / 2) as i64).unwrap();
        src.append(&pcm.0).unwrap();
        src.finish();
        let d = e.deck(DeckId::new(k).unwrap());
        d.set_source(0, &src);
        d.set_gains(0, Gains::FULL, 0.0);
        d.set_level(1.0, 0.0);
        d.set_beats(&a.beats);
        d.set_bar_one(a.bar_one);
        d.set_keylock(keylock);
        let n = a.beats.len();
        let bpm = 60.0 * (n - 1) as f64 / (a.beats[n - 1] - a.beats[0]);
        println!("{}: {} — {} (stick {:.2} BPM, grid {bpm:.2} BPM, {n} beats, bar one {})", ["A", "B"][k], t.title, t.artist, t.bpm, a.bar_one);
        grids.push(a.beats);
        srcs.push(src);
    }
    let (a, b) = (e.deck(DeckId::new(0).unwrap()), e.deck(DeckId::new(1).unwrap()));
    a.seek(60.0);
    b.seek(90.0);
    a.play(true);
    b.play(true);
    let mut m = vec![0f32; BLOCK * 2];
    let mut render = |secs: f64| {
        for _ in 0..(secs * R as f64 / BLOCK as f64) as usize {
            let mut outs: [Option<&mut [f32]>; 4] = [None, None, None, None];
            e.render(&mut m, &mut outs).unwrap();
        }
    };
    render(2.0);
    b.sync(DeckId::new(0).unwrap(), 4, 0.0);
    println!("   t    A pos   B pos  A rate  B rate  off (ms, by the grids)  engine's phase error (ms)");
    for k in 0..40 {
        // at 7 s B's own tempo set (a tempo fader on the follower), at 12 s A's moved (the
        // master's fader), at 17 s B bent for a moment (a jog wheel)
        match k {
            9 => b.set_rate(1.0),
            19 => a.set_rate(1.02),
            29 => b.bend(1.03),
            30 => b.bend(1.0),
            _ => {}
        }
        render(0.5);
        let (sa, sb) = (a.read(), b.read());
        let (ba, bb) = (beat_at(&grids[0], sa.heard), beat_at(&grids[1], sb.heard));
        let mut off = (bb - ba).fract();
        if off > 0.5 {
            off -= 1.0;
        } else if off < -0.5 {
            off += 1.0;
        }
        let spb_a = 60.0 / (60.0 * (grids[0].len() - 1) as f64 / (grids[0][grids[0].len() - 1] - grids[0][0])) / sa.rate;
        println!("{:5.1} {:8.2} {:7.2} {:7.4} {:7.4} {:9.1} {:22.1}   synced {}", 2.5 + k as f64 * 0.5, sa.heard, sb.heard, sa.rate, sb.rate, off * spb_a * 1000.0, sb.phase_error * 1000.0, sb.synced);
    }
    drop(srcs);
}
