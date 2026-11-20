//! As rekordbox: the crossfader can be turned off (both channels straight through, the
//! channel faders mix, a hand's crossfader does nothing), and a record can be loaded onto
//! any deck at any time — a playing one too, and one in a move of the Auto DJ's (the move
//! stops, the other deck left the master).
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

#[test]
fn the_crossfader_off_and_loading_onto_any_deck() {
    let empty = std::env::temp_dir().join(format!("wo-xf-off-{}", std::process::id()));
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
    // the crossfader all on A's side, B started: B not heard
    d.hand_crossfader(if a == 0 { 0.0 } else { 1.0 });
    if !d.snapshot().decks[b].playing {
        d.toggle_play(b);
    }
    d.set_fader(b, 1.0);
    assert!(until(&mut d, 2.0, |d| d.snapshot().decks[b].playing), "B plays");
    assert!(d.snapshot().decks[b].audible < 1e-3, "on: the crossfader keeps B out: {}", d.snapshot().decks[b].audible);

    // off: both through, the fader alone
    d.set_crossfader_off(true);
    let s = d.snapshot();
    assert!(s.crossfader_off);
    assert!((s.decks[b].audible - 1.0).abs() < 1e-3 && (s.decks[a].audible - s.decks[a].fader * s.decks[a].fader).abs() < 1e-3, "off: both through: {} {}", s.decks[a].audible, s.decks[b].audible);
    d.set_fader(b, 0.5);
    assert!((d.snapshot().decks[b].audible - 0.25).abs() < 1e-3, "off: B's fader mixes it");
    let x = d.crossfader();
    d.hand_crossfader(0.5);
    assert_eq!(d.crossfader(), x, "off: a hand's crossfader does nothing");
    d.set_crossfader_off(false);
    assert!(d.snapshot().decks[b].audible < 1e-3, "on again: as it was");
    d.set_fader(b, 1.0);

    // a record onto the PLAYING master: A stops and waits at the new one's start, B the master
    let other = d.snapshot().decks[b].record.clone();
    d.load_by_hand(a, other.clone());
    until(&mut d, 0.4, |_| false);
    let s = d.snapshot();
    assert_eq!(s.decks[a].record.id, other.id, "loaded onto the playing deck");
    assert!(!s.decks[a].playing && s.decks[a].heard < 0.5, "it waits at its start: {}", s.decks[a].heard);
    assert_eq!(d.master(), b, "the deck still playing is the master");

    // a move of the Auto DJ's, crossfader off: it still mixes (its law inside), and a record
    // loaded onto its incoming deck mid-move stops the move, the outgoing left the master
    d.set_crossfader_off(true);
    d.set_auto(true);
    assert!(until(&mut d, 20.0, |d| d.snapshot().mix.is_some_and(|m| !m.mixing)), "planned");
    d.mix_now();
    assert!(until(&mut d, 4.0, |d| d.snapshot().mix.is_some_and(|m| m.mixing)), "started");
    let m = d.snapshot().mix.unwrap();
    assert!(d.snapshot().decks[m.to].audible < 0.9, "the move's own law while it runs: {}", d.snapshot().decks[m.to].audible);
    let rec = d.snapshot().decks[m.from].record.clone();
    d.load_by_hand(m.to, rec);
    d.set_auto(false);
    until(&mut d, 0.2, |_| false);
    let s = d.snapshot();
    assert!(s.mix.is_none(), "the move stopped");
    assert_eq!(d.master(), m.from, "the outgoing carries on as the master");
    assert!(s.decks[m.from].playing && (s.decks[m.from].audible - s.decks[m.from].fader * s.decks[m.from].fader).abs() < 1e-3, "and is heard whole through its fader: {}", s.decks[m.from].audible);
}
