//! The set taken up again after a restart, on the real engine (silently, the synthesised
//! records, no house): kept while it plays, the same records back on the decks at their
//! places, playing where they played; one stopped is not taken up.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::Desk;

fn until(d: &mut Desk, secs: f64, mut done: impl FnMut(&mut Desk) -> bool) -> bool {
    let t0 = Instant::now();
    while t0.elapsed().as_secs_f64() < secs {
        d.tick();
        if done(d) {
            return true;
        }
        sleep(Duration::from_millis(20));
    }
    false
}

/// The Desk closed, and its engine let go (one engine at a time).
fn closed(d: Desk) {
    drop(d);
    sleep(Duration::from_millis(1500));
}

#[test]
fn the_set_is_taken_up_again_where_it_was() {
    let home = std::env::temp_dir().join(format!("wo-session-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("WO_RECORDS", &home);
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("XDG_CONFIG_HOME", &home);
    }
    let mut d = Desk::open(false);
    assert_eq!(d.take_resumed(), None, "nothing kept yet");
    let b_title = d.snapshot().decks[1].record.title.clone();
    // deck B playing from 40 s, its fader down a little, the crossfader over
    assert!(until(&mut d, 10.0, |d| d.snapshot().decks[1].decoded >= 0.5), "B decodes");
    d.seek_to(1, 40.0);
    d.set_fader(1, 0.8);
    d.set_crossfader(1.0);
    d.toggle_play(1);
    let kept = home.join("wetowl-desk").join("booth-session.json");
    assert!(until(&mut d, 10.0, |_| kept.is_file()), "kept while it plays");
    sleep(Duration::from_millis(300));
    closed(d);

    // started again: B back on, from about where it was, playing; A as it was, not playing
    let mut d = Desk::open(false);
    let said = d.take_resumed().expect("taken up again");
    assert!(said.contains(&b_title), "{said}");
    assert!(until(&mut d, 15.0, |d| d.snapshot().decks[1].playing), "B plays again");
    let s = d.snapshot();
    assert_eq!(s.decks[1].record.title, b_title);
    assert!((40.0..60.0).contains(&s.decks[1].heard), "about where it was: {}", s.decks[1].heard);
    assert!(!s.decks[0].playing);
    assert_eq!((s.decks[1].fader, s.crossfader), (0.8, 1.0));
    closed(d);

    // a set that was over is not taken up again
    let text = std::fs::read_to_string(&kept).unwrap().replace("\"live\":true", "\"live\":false");
    std::fs::write(&kept, text).unwrap();
    let mut d = Desk::open(false);
    assert_eq!(d.take_resumed(), None);
    drop(d);
    let _ = std::fs::remove_dir_all(&home);
}
