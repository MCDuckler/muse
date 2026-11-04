//! Every transition of v1's, made end to end on the real engine (silently, the two
//! synthesised records): planned, swapped for the kind by a hand on the plan, started
//! by Mix now, run to the end and handed over — and the outgoing put back plain (no
//! loop, no echo, no chop, no shift, flat), the crossfader across.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::{Desk, Transition};

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
fn every_move_runs_and_hands_over() {
    let empty = std::env::temp_dir().join(format!("wo-moves-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("WO_RECORDS", &empty);
    }
    let mut d = Desk::open(true);
    for kind in Transition::ALL {
        assert!(until(&mut d, 20.0, |d| d.snapshot().mix.is_some_and(|m| !m.mixing)), "{kind:?}: nothing planned");
        let from = d.snapshot().mix.unwrap().from;
        d.choose_move(kind, Some(2));
        let m = d.snapshot().mix.unwrap();
        assert_eq!((m.kind, m.bars), (kind, 2));
        d.mix_now();
        assert!(until(&mut d, 4.0, |d| d.snapshot().mix.is_some_and(|m| m.mixing)), "{kind:?}: not started");
        assert!(until(&mut d, 15.0, |d| d.snapshot().mix.is_none()), "{kind:?}: never finished");
        until(&mut d, 0.1, |_| false);
        let s = d.snapshot();
        let (old, new) = (&s.decks[from], &s.decks[1 - from]);
        assert!(new.master && new.playing, "{kind:?}: the incoming carries on as the master");
        assert!(old.looped.is_none() && !old.playing, "{kind:?}: the outgoing stopped and let go");
        assert!((s.crossfader - if from == 0 { 1.0 } else { 0.0 }).abs() < 1e-3, "{kind:?}: the fader across");
        assert!(old.eq.iter().all(|k| (k - 0.5).abs() < 1e-3) && (old.filter - 0.5).abs() < 1e-3, "{kind:?}: the outgoing put back flat");
        eprintln!("{:16} made and handed over", kind.word());
    }
}
