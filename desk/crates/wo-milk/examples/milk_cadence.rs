//! How the helper's frames come at a command rate: the stage's lines (lock, vars, audio) sent
//! every `period` ms for a few seconds; the frames read.
//!   cargo run --release -p wo-milk --example milk_cadence -- <wetowl-milk> <preset> <period ms>
use std::time::{Duration, Instant};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let _gpu = std::env::var_os("WITH_GPU").map(|_| wo_render::Gpu::headless().unwrap());
    let mut m = wo_milk::Milk::start(std::path::Path::new(&a[1]), 960, 540, 60, None).unwrap();
    let period: u64 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(16);
    m.say(&format!("preset {}", a[2])).unwrap();
    m.say("lock 0").unwrap();
    let vars: Vec<String> = match std::env::var("VARS") {
        Ok(v) => v.split(' ').map(str::to_owned).collect(),
        Err(_) => (0..53).map(|i| format!("wo_v{i}={:.4}", i as f64 / 53.0)).collect(),
    };
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_secs(3) {
        m.say(&format!("vars {}", vars.join(" "))).unwrap();
        m.say("audio 1.296 0.555 1.302 1.000 1.000 1.000").unwrap();
        let _ = m.take();
        std::thread::sleep(Duration::from_millis(period));
    }
    println!("period {period} ms: {} frames in 3 s", m.frames());
    for l in m.said().iter().rev().take(3) {
        println!("  said: {l}");
    }
}
