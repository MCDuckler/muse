//! The crate under a scratch: a desk opened silently (WO_AUDIO=off) on the two
//! synthesised records, the master scratched by hand.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::Desk;

fn desk() -> Desk {
    let empty = std::env::temp_dir().join(format!("wo-no-records-scratch-{}", std::process::id()));
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
    d
}

/// A hand scratching the master (held, pulled back and forth, let go to spin up again)
/// leaves the master's tempo, and so the crate's fits and their order, where they were:
/// the list stayed put under a scratch.
#[test]
fn a_scratch_leaves_the_crate_where_it_was() {
    let mut d = desk();
    let m = d.snapshot().decks.iter().position(|v| v.master).unwrap();
    let before = d.snapshot().master_bpm;
    let order = |d: &Desk| d.rows("", d.snapshot().master_bpm).iter().map(|r| (r.record.id, r.fits)).collect::<Vec<_>>();
    let rows = order(&d);
    let mut seen = vec![];
    d.scratch(m, true);
    for i in 0..30 {
        d.scratch_by(m, if i % 2 == 0 { -0.15 } else { 0.25 });
        sleep(Duration::from_millis(15));
        d.tick();
        seen.push(d.snapshot().master_bpm);
        assert_eq!(order(&d), rows, "the crate moved under the hand");
    }
    d.scratch(m, false);
    for _ in 0..10 {
        sleep(Duration::from_millis(10));
        d.tick();
        seen.push(d.snapshot().master_bpm);
        assert_eq!(order(&d), rows, "the crate moved as the record spun up");
    }
    assert!(seen.iter().all(|b| (b - before).abs() < 1e-9), "the master's tempo swung with the hand: {before} → {seen:?}");
}
