//! A record put on a deck starts at its start: the deck's place (its progress ring) does
//! not carry over from the record before.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::Desk;

#[test]
fn a_new_record_starts_at_its_start() {
    let empty = std::env::temp_dir().join(format!("wo-no-records-load-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: set before any thread of this test reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("WO_RECORDS", &empty);
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("XDG_CONFIG_HOME", &empty);
    }
    let mut d = Desk::open(true);
    d.set_auto(false);
    let t0 = Instant::now();
    while d.snapshot().decks.iter().any(|v| v.decoded < 1.0) && t0.elapsed() < Duration::from_secs(10) {
        sleep(Duration::from_millis(50));
    }
    // A plays from its drop: well into its record
    assert!(d.snapshot().decks[0].heard > 5.0, "A plays from its drop: {}", d.snapshot().decks[0].heard);
    let other = d.snapshot().decks[1].record.clone();
    d.load(0, other);
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_millis(400) {
        d.tick();
        sleep(Duration::from_millis(20));
    }
    let heard = d.snapshot().decks[0].heard;
    assert!(heard < 0.5, "the new record on A starts at its start, not where the last one was: {heard}");
}
