//! A set played by hand, step by step as rekordbox plays it (its manual, PERFORMANCE mode,
//! and its DDJ-400 mapping): a record loads onto a deck parked on its CUE point (Auto
//! Cue), the deck's tempo slider and BEAT SYNC kept through the load; CUE while playing
//! goes back and pauses, CUE held plays from the cue and PLAY pressed meanwhile plays on;
//! the master hands itself on when the master stops or its record changes, and is set by
//! hand (MASTER); Instant Doubles put the other deck's record where it plays.
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
        sleep(Duration::from_millis(10));
    }
    false
}

fn wait(d: &mut Desk, secs: f64) {
    until(d, secs, |_| false);
}

#[test]
fn a_set_played_by_hand_as_rekordbox() {
    let empty = std::env::temp_dir().join(format!("wo-lifecycle-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("WO_RECORDS", &empty);
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("XDG_CONFIG_HOME", &empty);
    }
    let mut d = Desk::open(true);
    d.set_auto(false);
    assert!(until(&mut d, 10.0, |d| d.snapshot().decks.iter().all(|v| v.decoded >= 1.0)), "decoded");
    let a = d.master();
    let b = 1 - a;
    let rec_a = d.snapshot().decks[a].record.clone();
    let rec_b = d.snapshot().decks[b].record.clone();

    // B's slider at +4 %, then B synced: a new record on B keeps both
    d.set_pitch(b, 0.4);
    wait(&mut d, 0.1);
    let pitch = d.snapshot().decks[b].pitch;
    d.toggle_sync(b);
    assert!(until(&mut d, 1.0, |d| d.snapshot().decks[b].synced), "B synced");
    d.load_by_hand(b, rec_a.clone());
    assert!(until(&mut d, 5.0, |d| d.snapshot().decks[b].decoded >= 1.0), "B loaded");
    wait(&mut d, 0.2);
    let s = d.snapshot();
    assert!((s.decks[b].pitch - pitch).abs() < 1e-9, "the tempo slider stays where it was: {} vs {pitch}", s.decks[b].pitch);
    assert!(s.decks[b].synced, "BEAT SYNC stays on through a load");
    assert_eq!(s.decks[b].cue, Some(0.0), "Auto Cue: the record parked on a cue point at its start");
    assert!(!s.decks[b].playing && s.decks[b].heard < 0.5, "parked, not playing: {}", s.decks[b].heard);
    d.toggle_sync(b);
    assert!(until(&mut d, 1.0, |d| !d.snapshot().decks[b].synced));

    // CUE while playing: back to the cue point, paused
    d.toggle_play(b);
    wait(&mut d, 0.8);
    assert!(d.snapshot().decks[b].heard > 0.4, "played on: {}", d.snapshot().decks[b].heard);
    d.cue_down(b);
    d.cue_up(b);
    wait(&mut d, 0.1);
    let s = d.snapshot();
    assert!(!s.decks[b].playing && s.decks[b].heard < 0.1, "back cue: on the cue point, paused: {}", s.decks[b].heard);
    // CUE held plays from the cue point; PLAY pressed meanwhile: it plays on when CUE is let go
    d.cue_down(b);
    assert!(until(&mut d, 1.0, |d| d.snapshot().decks[b].playing), "CUE held: playing from the cue");
    d.toggle_play(b);
    d.cue_up(b);
    wait(&mut d, 0.3);
    assert!(d.snapshot().decks[b].playing && d.snapshot().decks[b].heard > 0.2, "CUE + PLAY: plays on");

    // the master hands itself on: A (the master) stopped with B playing → B
    assert_eq!(d.master(), a);
    d.toggle_play(a);
    assert!(until(&mut d, 1.0, |d| d.master() == b), "the master stopped: the playing deck is the master");
    // MASTER by hand (a DDJ's BEAT SYNC held)
    d.toggle_play(a);
    d.set_master(a);
    wait(&mut d, 0.1);
    assert_eq!(d.master(), a, "MASTER pressed on A");
    // a new record on the master's deck: the master is the other's
    d.load_by_hand(a, rec_b.clone());
    wait(&mut d, 0.1);
    assert_eq!(d.master(), b, "the master's record changed: the other deck is the master");

    // Instant Doubles: B's record onto A, where B plays, playing
    d.instant_double(a);
    assert!(until(&mut d, 6.0, |d| d.snapshot().decks[a].playing), "the double plays");
    wait(&mut d, 0.3);
    let s = d.snapshot();
    assert_eq!(s.decks[a].record.id, s.decks[b].record.id, "the same record");
    assert!((s.decks[a].heard - s.decks[b].heard).abs() < 0.15, "where the other plays: {} vs {}", s.decks[a].heard, s.decks[b].heard);
}
