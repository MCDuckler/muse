//! TEMPO RETURN: a deck's tempo back to the record's own over the time set, eased; a hand
//! on the fader stops it there; a synced follower has none of its own to go back to.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::Desk;

fn run(d: &mut Desk, ms: u64) {
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_millis(ms) {
        d.tick();
        sleep(Duration::from_millis(20));
    }
}

#[test]
fn the_tempo_goes_back_slowly_and_a_hand_stops_it() {
    let empty = std::env::temp_dir().join(format!("wo-no-records-tempo-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: set before any thread of this test reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("WO_RECORDS", &empty);
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("WO_RESUME", "off");
        std::env::set_var("XDG_CONFIG_HOME", &empty);
    }
    let mut d = Desk::open(false);
    d.set_auto(false);
    d.set_tempo_return_secs(1.0);
    d.set_pitch(0, 0.5);
    let pitch = |d: &Desk| d.snapshot().decks[0].pitch;
    assert!(d.tempo_return(0));
    run(&mut d, 500);
    let half = pitch(&d);
    assert!(half > 0.05 && half < 0.45, "on its way, not there at once: {half}");
    run(&mut d, 800);
    assert_eq!(pitch(&d), 0.0, "at its own tempo");
    assert!(d.tempo_returning(0).is_none(), "done");
    assert!(!d.tempo_return(0), "nothing to do at its own tempo");

    // a hand on the fader stops it where it is
    d.set_pitch(0, -0.4);
    d.set_tempo_return_secs(4.0);
    assert!(d.tempo_return(0));
    run(&mut d, 600);
    let was = pitch(&d);
    assert!(was < -0.05, "{was}");
    d.set_pitch(0, was);
    run(&mut d, 600);
    assert_eq!(pitch(&d), was, "the hand has it");

    // pressed again while it goes: it stops there
    assert!(d.tempo_return(0));
    run(&mut d, 400);
    assert!(d.tempo_return(0));
    let stopped = pitch(&d);
    run(&mut d, 400);
    assert_eq!(pitch(&d), stopped);
}
