//! Listens to rkbx_link and prints the decks once a second; with a file, also records a capture.
//! `rkbx_watch [seconds] [capture.txt] [addr]` (defaults: 30, none, 127.0.0.1:4460)
//! `rkbx_watch --replay capture.txt` prints a recorded feed the same way, on its own clock.
use std::time::Duration;

use wo_rkbx::{View, capture};

fn show(t: f64, v: &View) {
    let mut s = format!("{t:7.1}s {} master={:?} lead={:?}", if v.live { "live" } else { "SILENT" }, v.master, v.lead);
    for d in v.decks.iter().filter(|d| d.loaded) {
        s.push_str(&format!(
            " | {} {}{:?} @{} bpm={} rate={:.3} beat={} phrase={:?}->{:?} in {} loads={} jumps={}",
            d.deck,
            if d.playing { "▶ " } else { "■ " },
            d.title,
            d.position.map_or("-".into(), |p| format!("{p:.2}")),
            d.bpm.map_or("-".into(), |b| format!("{b:.2}")),
            d.rate,
            d.beat_phase.map_or("-".into(), |b| format!("{b:.2}")),
            d.phrase,
            d.phrase_next,
            d.beats_to_next.map_or("-".into(), |b| format!("{b:.1}")),
            d.loads,
            d.jumps,
        ));
    }
    println!("{s}");
}

fn main() -> std::io::Result<()> {
    let a: Vec<String> = std::env::args().skip(1).collect();
    if a.first().map(String::as_str) == Some("--replay") {
        let heard = capture::read(std::io::BufReader::new(std::fs::File::open(&a[1])?))?;
        let mut r = capture::Replay::new(heard);
        let end = r.end();
        let mut t = 0.0;
        while t <= end + 1.0 {
            show(t, &r.until(t).view(t));
            t += 1.0;
        }
        return Ok(());
    }
    let secs: u64 = a.first().and_then(|s| s.parse().ok()).unwrap_or(30);
    let cap = a.get(1).filter(|s| !s.is_empty() && *s != "-").map(std::path::PathBuf::from);
    let addr = a.get(2).cloned().unwrap_or_else(|| wo_rkbx::listen::DEFAULT_ADDR.into());
    let l = wo_rkbx::Listener::start(&addr, cap.as_deref())?;
    for _ in 0..secs {
        std::thread::sleep(Duration::from_secs(1));
        show(l.now(), &l.view());
    }
    eprintln!("{} packets", l.packets());
    Ok(())
}
