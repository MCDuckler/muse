//! The hands on the Auto DJ, on the real engine (silently, the synthesised records, no
//! house — nothing is told to any account): later and sooner move the planned out
//! point by phrases, longer doubles the move, skip mixes at the next bar, the room's
//! word is kept and undone, the log says what happened, the last mix takes a thumb.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::autodj::LogKind;
use wo_deskcore::{Desk, Style};

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
fn the_hands_on_the_auto_dj() {
    let empty = std::env::temp_dir().join(format!("wo-autodj-hands-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("WO_RECORDS", &empty);
        // never the house: no saved sign-in read, nothing told to any account
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("XDG_CONFIG_HOME", &empty);
    }
    let mut d = Desk::open(true);
    assert!(d.house().is_none(), "never the house in a test");
    d.style = Style::Normal;
    assert!(until(&mut d, 15.0, |d| d.snapshot().mix.is_some()), "nothing planned");
    let spb = 60.0 / 128.0;

    // the hand's queue: kept in order, shown on its shelf, taken off by a hand
    let a = d.snapshot().decks[0].record.clone();
    let b = d.snapshot().decks[1].record.clone();
    d.queue_add(a.clone());
    d.queue_add(b.clone());
    d.queue_add(a.clone());
    assert_eq!(d.queue().iter().map(|r| r.id).collect::<Vec<_>>(), vec![a.id, b.id], "once each, in order");
    d.open_shelf(wo_deskcore::Shelf::Queue);
    assert_eq!(d.library().rows.len(), 2);
    d.queue_remove(a.id);
    assert_eq!(d.library().rows.len(), 1, "the shelf follows the queue");
    d.queue_remove(b.id);
    // the shelf (the two records here) queued whole: each one not queued yet, none twice;
    // mixed: its records not on a deck first (none here: both are), the queue there was after
    d.queue_add(a.clone());
    assert_eq!(d.queue_shelf(), 1);
    assert_eq!(d.queue_shelf(), 0, "none twice");
    assert_eq!(d.queue().iter().map(|r| r.id).collect::<Vec<_>>(), vec![a.id, b.id]);
    d.queue_remove(b.id);
    d.set_auto(false);
    d.mix_shelf();
    assert_eq!(d.queue().iter().map(|r| r.id).collect::<Vec<_>>(), vec![a.id], "the queue there was, kept");
    assert!(d.snapshot().auto, "the Auto DJ on");
    d.queue_remove(a.id);

    // the room's word, kept and undone
    d.more_energy(1);
    assert!((d.steer().energy - 0.12).abs() < 1e-9);
    d.something_different();
    assert!(d.steer().different);
    assert!(d.can_undo().is_some_and(|w| w.contains("different")));
    d.undo();
    assert!(!d.steer().different && (d.steer().energy - 0.12).abs() < 1e-9, "the last word undone, the one before kept");
    d.undo();
    assert!(d.steer().neutral() && d.can_undo().is_none());

    // a short move first, so later/sooner have room
    d.choose_move(wo_deskcore::Transition::Blend, Some(4));
    let out0 = d.snapshot().mix.unwrap().starts_in;
    d.later(2);
    let out1 = d.snapshot().mix.unwrap().starts_in;
    assert!((out1 - out0 - 8.0 * 4.0 * spb).abs() < 0.3, "two phrases later: {out0:.2} → {out1:.2}");
    d.later(-1);
    let out2 = d.snapshot().mix.unwrap().starts_in;
    assert!((out1 - out2 - 4.0 * 4.0 * spb).abs() < 0.3, "a phrase sooner: {out1:.2} → {out2:.2}");
    d.longer();
    assert_eq!(d.snapshot().mix.unwrap().bars, 8, "twice as long");

    // skip: a quick blend at the next bar
    d.skip();
    let m = d.snapshot().mix.unwrap();
    assert_eq!((m.kind, m.bars), (wo_deskcore::Transition::Blend, 4), "Normal skips with four bars");
    assert!(until(&mut d, 4.0, |d| d.snapshot().mix.is_some_and(|m| m.mixing)), "skip mixes at the next bar");
    assert!(until(&mut d, 12.0, |d| d.snapshot().mix.is_none_or(|m| !m.mixing)), "and finishes");

    // the last mix, a thumb on it, the log
    let last = d.last_mix().expect("the last mix kept");
    assert_eq!(last.kind, wo_deskcore::Transition::Blend);
    d.rate(1);
    assert_eq!(d.last_mix().unwrap().rating, Some(1));
    let log = d.log();
    assert!(log.iter().any(|l| l.kind == LogKind::Done && l.text.ends_with("has the room")), "{log:?}");
    assert!(log.iter().any(|l| l.kind == LogKind::Hand && l.text.starts_with("Skip")));
    assert!(log.iter().any(|l| l.text.starts_with("Undone")));
}
