//! MilkDrop coming on, as the stage sees it: starts the helper and says to it what a 75 fps
//! stage frame says (the numbers, the levels, the sound) while it opens OpenGL and projectM,
//! timing each frame: the longest is what the stage would have stalled.
//!   cargo run --release -p wo-milk --example milk_start -- <wetowl-milk> <preset.milk> [times]
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let program = PathBuf::from(a.get(1).expect("the helper"));
    let preset = a.get(2).expect("a preset").clone();
    let times: u32 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(3);
    let frame = Duration::from_micros(1_000_000 / 75);
    for run in 1..=times {
        let t0 = Instant::now();
        let mut m = wo_milk::Milk::start(&program, 960, 540, 60, None).expect("the helper");
        let started = t0.elapsed();
        let (mut worst, mut first, mut n) = (Duration::ZERO, None, 0u32);
        let mut loaded = false;
        while t0.elapsed() < Duration::from_secs(8) {
            let f0 = Instant::now();
            if !loaded {
                let _ = m.say(&format!("preset {preset}"));
                let _ = m.say("lock 0");
                loaded = true;
            }
            let _ = m.feed(&format!("vars {}", (0..40).map(|i| format!("v{i}=0.5000")).collect::<Vec<_>>().join(" ")));
            let _ = m.feed("audio 1.000 1.000 1.000 1.000 1.000 1.000");
            let _ = m.pcm(&[0i16; 588]);
            if m.take().is_some() && first.is_none() {
                first = Some(t0.elapsed());
            }
            for l in m.said() {
                if l.starts_with("preset ") || l.starts_with("egl") || l == "ready" {
                    println!("    {:>6.0} ms  {l}", t0.elapsed().as_secs_f64() * 1000.0);
                }
            }
            let took = f0.elapsed();
            worst = worst.max(took);
            n += 1;
            if let Some(rest) = frame.checked_sub(took) {
                std::thread::sleep(rest);
            }
        }
        println!(
            "run {run}: spawn {:.1} ms, longest frame {:.1} ms over {n} frames, first picture at {}, dropped {}",
            started.as_secs_f64() * 1000.0,
            worst.as_secs_f64() * 1000.0,
            first.map(|t| format!("{:.0} ms", t.as_secs_f64() * 1000.0)).unwrap_or("-".into()),
            m.dropped()
        );
    }
}
