//! A record's parts on the real engine (WO_AUDIO=off): a synthesised record has no stems
//! and plays whole whatever is pressed; a record the WetOwl app keeps stems for gets
//! them on its deck, and its parts change what the deck plays.
use std::path::PathBuf;
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::parts::{Part, Stems};
use wo_deskcore::records::{Audio, Record};
use wo_deskcore::Desk;

/// The deck's peak over a while of playing, the engine's own reading.
fn loudness(d: &mut Desk, deck: usize) -> f32 {
    let mut most = 0f32;
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_millis(600) {
        d.tick();
        most = most.max(d.snapshot().decks[deck].peak);
        sleep(Duration::from_millis(20));
    }
    most
}

/// A record on this computer with stems the WetOwl app made or fetched, if there is one.
fn kept_with_stems() -> Option<Record> {
    let app = PathBuf::from(std::env::var("HOME").ok()?).join(".local/share/io.wetowl.muse");
    let mut ids: Vec<i64> = std::fs::read_dir(app.join("stems"))
        .ok()?
        .filter_map(|e| e.ok()?.file_name().to_str()?.strip_suffix("-stems-v2.opus")?.parse().ok())
        .filter(|id| app.join("fetched").join(format!("{id}.m4a")).exists())
        .collect();
    ids.sort();
    let id = *ids.first()?;
    Some(Record {
        id,
        title: format!("kept {id}"),
        artist: String::new(),
        bpm: 120.0,
        key: String::new(),
        seconds: 300,
        audio: Audio::File { path: app.join("fetched").join(format!("{id}.m4a")), beats: vec![], bar_one: 0 },
        cover: false,
        cover_rgb: None,
        loudness: Default::default(),
    })
}

#[test]
fn parts_reach_the_engine() {
    let empty = std::env::temp_dir().join(format!("wo-no-records-parts-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: set before any thread of this test reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("WO_RECORDS", &empty);
        // never the house: no saved sign-in read, nothing told to any account
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("XDG_CONFIG_HOME", &empty);
    }
    let mut d = Desk::open(true);
    d.set_auto(false);
    // both records all in (a deck plays silence past what is decoded so far)
    let t0 = Instant::now();
    while d.snapshot().decks.iter().any(|v| v.decoded < 1.0) && t0.elapsed() < Duration::from_secs(10) {
        d.tick();
        sleep(Duration::from_millis(20));
    }
    // synthesised: no stems; a part pressed is kept but the record plays whole
    assert_eq!(d.part(0).1, Stems::None);
    d.set_part(0, Part::Drums);
    assert_eq!(d.part(0), (Part::Drums, Stems::None));
    d.seek_to(0, 30.0);
    assert!(loudness(&mut d, 0) > 0.05, "a synthesised record with no stems still sounds whole");
    d.set_part(0, Part::Whole);

    let Some(rec) = kept_with_stems() else {
        eprintln!("no record with stems kept by the WetOwl app here: the rest skipped");
        return;
    };
    eprintln!("record {} with its stems", rec.id);
    d.load(0, rec);
    assert_eq!(d.part(0), (Part::Whole, Stems::Asking), "a new record's stems are asked for");
    let t0 = Instant::now();
    while !d.part(0).1.ready() && t0.elapsed() < Duration::from_secs(30) {
        d.tick();
        sleep(Duration::from_millis(50));
    }
    eprintln!("stems on the deck after {:.1} s", t0.elapsed().as_secs_f64());
    assert_eq!(d.part(0).1, Stems::Ready);

    // The same second of the record (a minute in) under each part, read by the engine:
    // each part sounds, the parts are quieter than the whole, and the whole comes back.
    if !d.snapshot().decks[0].playing {
        d.toggle_play(0);
    }
    let mut at = |d: &mut Desk, part: Part| {
        d.set_part(0, part);
        d.seek_to(0, 60.0);
        loudness(d, 0)
    };
    let whole = at(&mut d, Part::Whole);
    let peaks: Vec<f32> = Part::ALL[1..].iter().map(|p| at(&mut d, *p)).collect();
    let back = at(&mut d, Part::Whole);
    eprintln!("peaks at 1:00: whole {whole:.3}, drums/music/no vox/vocals {peaks:.3?}, whole again {back:.3}");
    assert!(whole > 0.05 && (back - whole).abs() < 0.02, "the whole record sounds, the same before and after");
    assert!(peaks.iter().all(|p| *p > 0.002), "every part sounds");
    assert!(peaks[0] < whole * 0.95, "the drums alone are not the whole record");
    assert_eq!(d.part(0).0, Part::Whole);
}
