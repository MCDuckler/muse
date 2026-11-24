//! BEAT SYNC held over what a set does to it, rendered offline: B synced to A, the two
//! records this computer has fetched (else the two synth ones), keylock on. For each
//! stretch, how far B's beat strays from A's (by their grids, ms): the worst and the
//! last. A stretch: steady; A's tempo fader moved slowly (as a tempo return does); A's
//! jumped a beat on (a hot cue); B looped and let go; B's tempo fader moved; steady again.
//!
//!   cargo run --release -p wo-deskcore --example sync_drift -- [keylock 0|1]
use wo_deskcore::records::{self, Audio};
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
    let keylock = std::env::args().nth(1).is_none_or(|v| v != "0");
    // every fetched record with the app's beats beside it
    let dir = records::fetched_dir().expect("the app's fetched records");
    let mut rows: Vec<records::Record> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| {
            let path = e.ok()?.path();
            let id: i64 = path.file_stem()?.to_str()?.parse().ok()?;
            let (beats, bar_one) = records::beats_for(&dir, id)?;
            let mut r = records::synth_rows().remove(0);
            (r.id, r.title, r.audio) = (id, format!("record {id}"), Audio::File { path, beats, bar_one });
            Some(r)
        })
        .collect();
    rows.truncate(2);
    assert!(rows.len() == 2, "two fetched records with beats wanted");
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let mut grids = vec![];
    let mut srcs = vec![];
    for (k, r) in rows.iter().enumerate() {
        let Audio::File { path, beats, bar_one } = &r.audio else { unreachable!() };
        let mut pcm = Pcm(vec![]);
        wo_decode::decode(path, R, &mut pcm).unwrap();
        let mut src = e.new_source(Channels::Stereo, (pcm.0.len() / 2) as i64).unwrap();
        src.append(&pcm.0).unwrap();
        src.finish();
        let d = e.deck(DeckId::new(k).unwrap());
        d.set_source(0, &src);
        d.set_gains(0, Gains::FULL, 0.0);
        d.set_level(1.0, 0.0);
        d.set_beats(beats);
        d.set_bar_one(*bar_one);
        d.set_keylock(keylock);
        let n = beats.len();
        println!("{}: {} ({:.2} BPM by its grid, {} s)", ["A", "B"][k], r.title, 60.0 * (n - 1) as f64 / (beats[n - 1] - beats[0]), pcm.0.len() / 2 / R as usize);
        grids.push(beats.clone());
        srcs.push(src);
    }
    let (a, b) = (e.deck(DeckId::new(0).unwrap()), e.deck(DeckId::new(1).unwrap()));
    a.seek(20.0);
    b.seek(10.0);
    a.play(true);
    b.play(true);
    let mut m = vec![0f32; BLOCK * 2];
    let render = |n: usize, m: &mut Vec<f32>| {
        for _ in 0..n {
            let mut outs: [Option<&mut [f32]>; 4] = [None, None, None, None];
            e.render(m, &mut outs).unwrap();
        }
    };
    render(R as usize / BLOCK, &mut m);
    b.sync(DeckId::new(0).unwrap(), 4, 0.0);
    render(R as usize / BLOCK, &mut m);
    let off_ms = || {
        let (sa, sb) = (a.read(), b.read());
        let (ba, bb) = (beat_at(&grids[0], sa.heard), beat_at(&grids[1], sb.heard));
        let mut off = (bb - ba).fract();
        if off > 0.5 {
            off -= 1.0;
        } else if off < -0.5 {
            off += 1.0;
        }
        let n = grids[0].len();
        let spb = (grids[0][n - 1] - grids[0][0]) / (n - 1) as f64 / sa.rate;
        off * spb * 1000.0
    };
    let tick = R as usize / BLOCK / 20; // 50 ms
    let stretch = |name: &str, secs: f64, m: &mut Vec<f32>, each: &mut dyn FnMut(usize)| {
        let (mut worst, mut last, mut over) = (0f64, 0f64, 0usize);
        let steps = (secs * 20.0) as usize;
        for i in 0..steps {
            each(i);
            render(tick, m);
            last = off_ms();
            worst = worst.max(last.abs());
            if last.abs() > 5.0 {
                over += 1;
            }
        }
        println!("{name:44} worst {worst:6.1} ms  last {last:6.1} ms  over 5 ms {:5.1} s  (B rate {:.4})", over as f64 / 20.0, b.read().rate);
    };
    stretch("steady, 10 s", 10.0, &mut m, &mut |_| {});
    // A's fader 1.00 → 1.04 over 10 s, in small steps as a fader (or a tempo return) moves
    stretch("A's tempo 1.00→1.04 over 10 s", 10.0, &mut m, &mut |i| a.set_rate(1.0 + 0.04 * (i as f64 / 200.0)));
    stretch("  then held, 5 s", 5.0, &mut m, &mut |_| {});
    stretch("A's tempo 1.04→1.00 over 15 s", 15.0, &mut m, &mut |i| a.set_rate(1.04 - 0.04 * (i as f64 / 300.0)));
    stretch("  then held, 5 s", 5.0, &mut m, &mut |_| {});
    // a hot cue on A: a whole beat on
    let spb_a = (grids[0][grids[0].len() - 1] - grids[0][0]) / (grids[0].len() - 1) as f64;
    stretch("A jumps a beat on (hot cue), 10 s", 10.0, &mut m, &mut |i| {
        if i == 0 {
            a.seek(a.read().heard + spb_a);
        }
    });
    stretch("A jumps a bar on (hot cue), 10 s", 10.0, &mut m, &mut |i| {
        if i == 0 {
            a.seek(a.read().heard + 4.0 * spb_a);
        }
    });
    stretch("B loops 4 beats 8 s, let go, 10 s", 18.0, &mut m, &mut |i| {
        if i == 0 {
            b.loop_beats(4.0, false);
        }
        if i == 160 {
            b.clear_loop();
        }
    });
    stretch("B's own fader moved (synced), 10 s", 10.0, &mut m, &mut |i| b.set_rate(1.0 + 0.02 * (i as f64 / 200.0)));
    stretch("A moved 40 ms by hand (unquantized), 5 s", 5.0, &mut m, &mut |i| {
        if i == 0 {
            a.seek(a.read().heard + 0.04);
        }
    });
    stretch("A nudged 10 ms (keys), 5 s", 5.0, &mut m, &mut |i| {
        if i == 0 {
            a.seek(a.read().heard + 0.01);
        }
    });
    stretch("B rolls half a beat 3 s, let go, 5 s", 8.0, &mut m, &mut |i| {
        if i == 0 {
            b.loop_beats(0.5, false);
        }
        if i == 60 {
            b.clear_loop();
        }
    });
    stretch("steady, 10 s", 10.0, &mut m, &mut |_| {});
    drop(srcs);
}
