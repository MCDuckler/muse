//! The Auto DJ on the real engine, silently, with the two synthesised records (8A at
//! 128 bpm, 9A at 130: in key, with drops): planned, started on the bar by Mix now,
//! made bar by bar, and handed over.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::{Desk, Style, Transition};

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

#[test]
fn a_roll_planned_made_and_handed_over() {
    let empty = std::env::temp_dir().join(format!("wo-autodj-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("WO_RECORDS", &empty);
    }
    let mut d = Desk::open(true);
    d.style = Style::Bold;
    assert!(until(&mut d, 15.0, |d| d.snapshot().mix.is_some()), "nothing planned");
    let m = d.snapshot().mix.unwrap();
    assert_eq!((m.from, m.to), (0, 1));
    assert_eq!((m.kind, m.bars), (Transition::Roll, 8), "in key with a drop to land on, bold: a roll");
    assert!(!d.snapshot().decks[1].playing, "the incoming waits, parked");

    d.mix_now();
    assert!(until(&mut d, 4.0, |d| d.snapshot().mix.is_some_and(|m| m.mixing)), "Mix now did not start it on the bar");
    assert!(until(&mut d, 1.0, |d| d.snapshot().decks[1].playing && d.snapshot().decks[1].synced), "the incoming is not playing in step");

    // half way through: the outgoing is caught in a 2-beat loop
    assert!(until(&mut d, 12.0, |d| d.snapshot().mix.is_some_and(|m| m.bar >= 4.5)));
    let a = d.snapshot().decks[0].clone();
    let beat = 60.0 / 128.0;
    let (la, lb) = a.looped.expect("the outgoing rolls");
    assert!(((lb - la) - 2.0 * beat).abs() < 1e-6, "a 2-beat loop at bar 5 of 8, not {:.3} s", lb - la);

    // handed over: B is the master, A stopped and loaded with the next record
    assert!(until(&mut d, 15.0, |d| d.snapshot().mix.is_none() || d.snapshot().decks[1].master), "the roll never finished");
    // the engine takes commands at its next block: let it
    until(&mut d, 0.15, |_| false);
    let s = d.snapshot();
    assert!(s.decks[1].master && s.decks[1].playing, "B carries on as the master");
    assert!(!s.decks[0].playing && s.decks[0].looped.is_none(), "A stopped and let go");
    assert!((s.crossfader - 1.0).abs() < 1e-3, "the crossfader over on B");
}
