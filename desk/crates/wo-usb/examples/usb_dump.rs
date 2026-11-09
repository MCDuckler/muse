//! What a stick holds, as the Desk reads it: `cargo run -p wo-usb --example usb_dump [ROOT] [--cues]`
//! (no ROOT: every stick plugged in).
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cues_only = args.iter().any(|a| a == "--cues");
    let roots: Vec<std::path::PathBuf> = match args.iter().find(|a| !a.starts_with("--")) {
        Some(r) => vec![r.into()],
        None => wo_usb::find(),
    };
    for root in roots {
        let s = match wo_usb::Stick::open(&root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("{}: {e}", root.display());
                continue;
            }
        };
        println!("{} ({}): {} records", s.name, root.display(), s.tracks.len());
        for p in &s.playlists {
            println!("  playlist {} · {} records", p.name, p.tracks.len());
        }
        for t in &s.tracks {
            let a = t.analysis().unwrap_or_default();
            if cues_only && a.cues.is_empty() {
                continue;
            }
            let spb = if a.beats.len() > 1 { (a.beats[a.beats.len() - 1] - a.beats[0]) / (a.beats.len() - 1) as f64 } else { 0.0 };
            println!(
                "#{:<3} {} — {} [{}] {} · {:.2} BPM (grid {:.3}) · {} s · first beat {:.4} s, one at {} · {}",
                t.id,
                t.title,
                t.artist,
                t.album,
                t.key,
                t.bpm,
                if spb > 0.0 { 60.0 / spb } else { 0.0 },
                t.seconds,
                a.beats.first().copied().unwrap_or(0.0),
                a.bar_one,
                t.path.extension().map(|e| e.to_string_lossy()).unwrap_or_default(),
            );
            for c in &a.cues {
                println!("      {:?} {:.3} s{} {:?} {}", c.kind, c.ms as f64 / 1000.0, c.loop_end_ms.map(|e| format!(" loop → {:.3}", e as f64 / 1000.0)).unwrap_or_default(), c.rgb.map(|c| format!("#{c:06x}")), c.comment);
            }
        }
    }
}
