//! Indexes rekordbox's library on this computer and shows what the Desk would take from it.
//! `rb_library [--music <dir>]… [title]…`: no title lists every record; a title shows its
//! sections. Read only.
use std::path::PathBuf;
use std::time::Instant;

fn main() {
    let mut music = vec![];
    let mut titles = vec![];
    let mut a = std::env::args().skip(1);
    while let Some(x) = a.next() {
        if x == "--music" {
            music.extend(a.next().map(PathBuf::from));
        } else {
            titles.push(x);
        }
    }
    if music.is_empty() {
        music.extend(wo_rekordbox::default_music());
    }
    let Some(lib) = wo_rekordbox::library_dir() else {
        eprintln!("no rekordbox library here");
        std::process::exit(1);
    };
    let t0 = Instant::now();
    let ix = wo_rekordbox::Index::build(&wo_rekordbox::anlz_root(&lib), &music);
    println!("{:?} in {} ms (music: {music:?})", ix.stats, t0.elapsed().as_millis());
    if titles.is_empty() {
        for e in &ix.entries {
            let r = wo_rekordbox::record(e);
            let (beats, phrases) = r.as_ref().map_or((0, 0), |r| (r.beats.len(), r.phrased.sections.len()));
            println!(
                "{:50} | {:20} | beats {beats:4} phrases {phrases:3} | wetowl {:?} | {}",
                e.title(),
                e.tags.artist,
                e.wetowl_id,
                e.audio.as_deref().map_or("(audio not found)".into(), |p| p.display().to_string())
            );
        }
        return;
    }
    for t in titles {
        let Some(e) = ix.find(&t, "", "") else {
            println!("{t:?}: not found");
            continue;
        };
        let r = wo_rekordbox::record(e).unwrap();
        println!("{t:?} → {} ({:?}) mood {:?}, {} beats, bar one {}", e.file_name, e.audio, r.mood, r.beats.len(), r.bar_one);
        for s in &r.phrased.sections {
            println!("  {:>8.2}s – {:>8.2}s  {:10} ({:?})", s.start_ms / 1000.0, s.end_ms / 1000.0, s.label, s.name);
        }
        println!("  drops at {:?} s", r.phrased.drops_ms.iter().map(|d| (d / 10.0).round() / 100.0).collect::<Vec<_>>());
    }
}
