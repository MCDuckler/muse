//! Maps one control by hand without the Desk, through the same manager: lists the MIDI
//! ports, listens on all of them for `target` (default deck.a.eq.low) and prints what was
//! learned and then the events it reads. Nothing is kept on disk.
//!
//!   cargo run --release -p wo-control --example learn -- deck.a.volume 30
use std::sync::Arc;
use std::time::{Duration, Instant};

use wo_control::{Event, Learning, Manager, learn};

fn main() {
    let mut args = std::env::args().skip(1);
    let id = args.next().unwrap_or_else(|| "deck.a.eq.low".to_owned());
    let secs: u64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(20);
    let Some(target) = learn::target(&id) else {
        eprintln!("{id}: no such booth control; one of:");
        for t in learn::targets() {
            eprintln!("  {:22} {:?}  {} · {}", t.id, t.kind, t.group, t.name);
        }
        std::process::exit(2);
    };
    let m = Manager::with(wo_control::layout::bundled(), Some(Arc::new(|_: &Event| None)), wo_control::Mappings::at(None));
    std::thread::sleep(Duration::from_millis(300));
    println!("MIDI in: {:?}", m.midi_ports());
    m.learn(target);
    let until = Instant::now() + Duration::from_secs(secs);
    let mut said = false;
    while Instant::now() < until {
        std::thread::sleep(Duration::from_millis(200));
        if !said {
            let open: Vec<String> = m.controllers().iter().map(|c| format!("{} [{}]{}", c.name, c.layout, c.trouble.as_deref().map(|t| format!(" ! {t}")).unwrap_or_default())).collect();
            if !open.is_empty() {
                println!("listening on: {open:#?}\n{} · {}: move something on the controller ({secs} s)", target.group, target.name);
                said = true;
            }
        }
        if let Learning::Caught(t, mapped) = m.learning() {
            println!("mapped {} ← {} on {}", t.id, mapped.words(), mapped.port);
            break;
        }
    }
    if matches!(m.learning(), Learning::Listening(_)) {
        println!("nothing moved");
        m.stop_learning();
    }
    // what it reads now, for a few seconds
    let until = Instant::now() + Duration::from_secs(5);
    while Instant::now() < until {
        for e in m.poll() {
            println!("  {} {:.3}", e.id, e.value);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    println!("heard (first 40):");
    for p in m.monitor().iter().take(40) {
        let hex: Vec<String> = p.bytes.iter().map(|b| format!("{b:02X}")).collect();
        println!("  {:26} {:9} {}", p.from, hex.join(" "), p.read.join(", "));
    }
    std::thread::sleep(Duration::from_millis(2500));
    println!("open after: {:?}", m.controllers().iter().map(|c| c.name.clone()).collect::<Vec<_>>());
}
