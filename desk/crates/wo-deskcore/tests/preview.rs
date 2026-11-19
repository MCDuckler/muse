//! The browser's preview: out loud with the decks still and no headphones (stopped by a
//! second click), refused while a deck plays with no headphones to put it in.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::preview::PreviewWay;
use wo_deskcore::{Audio, Desk, Record};

fn wav(path: &std::path::Path, seconds: f64) {
    let n = (seconds * 48_000.0) as usize;
    let data: Vec<u8> = (0..n).flat_map(|i| {
        let v = ((i as f64 * 440.0 * std::f64::consts::TAU / 48_000.0).sin() * 8000.0) as i16;
        let b = v.to_le_bytes();
        [b[0], b[1], b[0], b[1]]
    }).collect();
    let mut f = b"RIFF".to_vec();
    f.extend((36 + data.len() as u32).to_le_bytes());
    f.extend(b"WAVEfmt ");
    f.extend(16u32.to_le_bytes());
    f.extend(1u16.to_le_bytes());
    f.extend(2u16.to_le_bytes());
    f.extend(48_000u32.to_le_bytes());
    f.extend((48_000u32 * 4).to_le_bytes());
    f.extend(4u16.to_le_bytes());
    f.extend(16u16.to_le_bytes());
    f.extend(b"data");
    f.extend((data.len() as u32).to_le_bytes());
    f.extend(data);
    std::fs::write(path, f).unwrap();
}

#[test]
fn a_preview_plays_stops_and_waits_for_headphones() {
    let empty = std::env::temp_dir().join(format!("wo-preview-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_RECORDS", &empty);
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("WO_USB", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("XDG_CONFIG_HOME", &empty);
    }
    let file = empty.join("tone.wav");
    wav(&file, 20.0);
    let mut d = Desk::open(false);
    let r = Record { id: 4242, title: "Tone".into(), seconds: 20, audio: Audio::File { path: file, beats: vec![], bar_one: 0 }, ..d.snapshot().decks[0].record.clone() };
    assert_eq!(d.preview_way(), PreviewWay::Room, "no headphones here, the decks still: out loud");
    assert!(d.play_preview(&r, 0.5));
    let t0 = Instant::now();
    while d.previewing().is_none() && t0.elapsed() < Duration::from_secs(3) {
        d.tick();
        sleep(Duration::from_millis(20));
    }
    let (id, at) = d.previewing().expect("it plays");
    assert_eq!(id, 4242);
    assert!((0.45..0.7).contains(&at), "from half way: {at}");
    // the same again: stopped
    assert!(d.play_preview(&r, 0.5));
    sleep(Duration::from_millis(100));
    assert!(d.previewing().is_none(), "stopped");
    // a deck playing, no headphones: not now
    d.toggle_play(0);
    let t0 = Instant::now();
    while !d.snapshot().decks[0].playing && t0.elapsed() < Duration::from_secs(3) {
        d.tick();
        sleep(Duration::from_millis(20));
    }
    assert_eq!(d.preview_way(), PreviewWay::NotNow);
    assert!(!d.play_preview(&r, 0.0), "refused: the room would hear it");
    let _ = std::fs::remove_dir_all(&empty);
}
