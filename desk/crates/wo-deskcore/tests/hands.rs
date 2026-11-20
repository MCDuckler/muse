//! The hands on the real engine: a desk opened silently (WO_AUDIO=off) on the two
//! synthesised records (WO_RECORDS at an empty folder), driven the way the booth's
//! buttons drive it, the engine's own state read back.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::Desk;

fn desk() -> Desk {
    let empty = std::env::temp_dir().join(format!("wo-no-records-{}", std::process::id()));
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
    // the synthesised records render in well under a second
    let t0 = Instant::now();
    while d.snapshot().decks.iter().any(|v| v.decoded < 1.0) && t0.elapsed() < Duration::from_secs(10) {
        sleep(Duration::from_millis(50));
    }
    d
}

fn settle() {
    sleep(Duration::from_millis(120)); // a few engine blocks at real time
}

#[test]
fn the_booths_hands_reach_the_engine() {
    let mut d = desk();
    let s = d.snapshot();
    assert!(s.decks[0].record.title.starts_with("Test Pressing"), "synthesised records: {}", s.decks[0].record.title);
    assert!(s.decks[0].playing && !s.decks[1].playing, "A plays from its drop, B is parked");

    // B parked: CUE marks a cue point, a pad press sets pad 5, a loop runs from the bar.
    d.cue_down(1);
    d.cue_up(1);
    let b = &d.snapshot().decks[1];
    assert!(b.cue.is_some(), "CUE on a parked deck marks the cue point");
    d.pad(1, 4);
    assert!(d.snapshot().decks[1].pads[4].is_some(), "an empty pad is set");

    // A playing: a 4-beat loop from the bar, read back from the engine.
    d.loop_beats(0, 4.0);
    settle();
    let a = d.snapshot();
    let (la, lb) = a.decks[0].looped.expect("the hands say looping");
    let spb = 60.0 / 128.0;
    assert!(((lb - la) - 4.0 * spb).abs() < 1e-9, "4 beats at 128 bpm");
    // A loop caught mid-bar starts on the next bar's one: wait till it is reached, then
    // a loop and a half more, and the record must still be inside it.
    let reach = (la - a.decks[0].heard).max(0.0) + 1.5 * (lb - la);
    sleep(Duration::from_secs_f64(reach + 0.1));
    let heard = d.snapshot().decks[0].heard;
    assert!(heard >= la - 0.05 && heard <= lb + 0.05, "the engine plays inside the loop ({heard} in {la}..{lb})");
    d.loop_beats(0, 4.0);
    assert!(d.snapshot().decks[0].looped.is_none(), "the same length again lets go");

    // Beat jump: 4 beats on.
    let before = d.snapshot().decks[0].heard;
    d.jump(0, 4.0);
    settle();
    let after = d.snapshot().decks[0].heard;
    assert!((after - before - 4.0 * spb).abs() < 0.3, "jumped {:.3} s, wanted {:.3}", after - before, 4.0 * spb);

    // Pitch: half the ±10 % range (rekordbox's to begin with) is 5 % faster, the engine's
    // rate with it; the next range (±16 %) keeps the rate, on A alone.
    d.set_pitch(0, 0.5);
    settle();
    let rate = d.snapshot().decks[0].rate;
    assert!((rate - 1.05).abs() < 0.002, "rate {rate}");
    d.cycle_range(0);
    settle();
    let s = d.snapshot();
    assert!(s.decks[0].range == 0.16 && s.decks[1].range == 0.10, "A's range moved alone: {} {}", s.decks[0].range, s.decks[1].range);
    assert!((s.decks[0].rate - 1.05).abs() < 0.002, "rate kept {}", s.decks[0].rate);

    // CUE on the playing deck: it stops.
    d.cue_down(0);
    d.cue_up(0);
    settle();
    assert!(!d.snapshot().decks[0].playing, "CUE stops a playing deck");

    // The jog wheel on the parked deck, as rekordbox on a DDJ-400: a turn of its side
    // nudges the record finely; a hand turning the platter's top a turn moves it more
    // (vinyl at 33⅓); SHIFT + a quarter turn searches half a minute on.
    let heard = |d: &Desk| d.snapshot().decks[0].heard;
    let p0 = heard(&d);
    d.jog(0, 128.0, false, false);
    settle();
    let side = heard(&d) - p0;
    assert!((side - wo_deskcore::NUDGE_A_TURN).abs() < 0.02, "a turn of the side: {side} s");
    let p1 = heard(&d);
    d.scratch(0, true);
    d.scratch_by(0, 128.0 * wo_deskcore::scratch::SECONDS_A_TICK);
    let t0 = Instant::now();
    while heard(&d) - p1 < 1.7 && t0.elapsed() < Duration::from_secs(2) {
        sleep(Duration::from_millis(20));
    }
    d.scratch(0, false);
    settle();
    let top = heard(&d) - p1;
    assert!(top > 2.0 * side && !d.snapshot().decks[0].playing, "a turn of the top ({top} s) is more than one of the side ({side} s), and it stays parked");
    let p2 = heard(&d);
    d.jog(0, 32.0, false, true);
    settle();
    let search = heard(&d) - p2;
    assert!((search - wo_deskcore::SEARCH_A_TURN / 4.0).abs() < 0.05, "SHIFT + a quarter turn: {search} s");
}
