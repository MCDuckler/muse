//! The Auto DJ IN ORDER: the queue played top to bottom, faded, no beat sync; the queue
//! done, nothing new.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::{Desk, Transition};

fn until(d: &mut Desk, secs: u64, mut f: impl FnMut(&mut Desk) -> bool) -> bool {
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_secs(secs) {
        d.tick();
        if f(d) {
            return true;
        }
        sleep(Duration::from_millis(20));
    }
    false
}

#[test]
fn the_queue_plays_top_to_bottom_faded_then_stops() {
    let empty = std::env::temp_dir().join(format!("wo-no-records-queue-{}", std::process::id()));
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
    let s0 = d.snapshot();
    let a = s0.decks[0].record.clone();
    let more = |seed: u32, id: i64| wo_deskcore::Record { id, title: format!("Test Pressing {id}"), audio: wo_deskcore::Audio::Synth { seed }, ..a.clone() };
    let (q1, q2) = (more(3, -3), more(4, -4));
    d.queue_add(q1.clone());
    d.queue_add(q2.clone());
    d.set_fade_secs(4.0);
    d.set_in_order(true);
    assert!(d.in_order());
    d.set_auto(true);
    let m = d.master();
    if !d.snapshot().decks[m].playing {
        d.toggle_play(m);
    }
    // the queue's first waits on the other deck, the Auto DJ's own choice put aside
    assert!(until(&mut d, 10, |d| d.snapshot().decks[1 - m].record.id == q1.id), "the queue's first waits");
    assert_eq!(d.queue().iter().map(|r| r.id).collect::<Vec<_>>(), vec![q2.id], "taken off the queue");

    // a plain fade, the fade's length, not in step
    assert!(until(&mut d, 20, |d| d.snapshot().mix.is_some()), "a move planned");
    let mix = d.snapshot().mix.unwrap();
    assert_eq!((mix.kind, mix.why.as_str()), (Transition::Fade, "in order"));
    let len = d.snapshot().decks[m].length;
    d.seek_to(m, len - 6.0);
    assert!(until(&mut d, 10, |d| d.snapshot().mix.is_some_and(|x| x.mixing)), "fading");
    assert!(!d.snapshot().decks[1 - m].synced, "no beat sync");
    assert!(until(&mut d, 15, |d| d.master() != m && d.snapshot().mix.is_none_or(|x| !x.mixing)), "the first of the queue took over");
    let s = d.snapshot();
    assert_eq!(s.decks[1 - m].record.id, q1.id);
    assert!(s.decks[1 - m].heard < 9.0, "from its start: {}", s.decks[1 - m].heard);
    assert_eq!(s.decks[m].record.id, q2.id, "the queue's next waits");
    assert!(d.queue().is_empty());

    // the last one in: the queue done, nothing new waits
    let m2 = d.master();
    let len = d.snapshot().decks[m2].length;
    d.seek_to(m2, len - 6.0);
    assert!(until(&mut d, 15, |d| d.master() != m2 && d.snapshot().mix.is_none_or(|x| !x.mixing)), "the queue's last took over");
    assert!(until(&mut d, 3, |d| d.log().iter().any(|l| l.text == "The queue is done")), "said");
    let s = d.snapshot();
    assert_eq!(s.decks[d.master()].record.id, q2.id);
    assert!(until(&mut d, 3, |d| !d.snapshot().decks[1 - d.master()].playing), "the one gone out stops");

    // queued again: it goes on
    let q3 = more(5, -5);
    d.queue_add(q3.clone());
    assert!(until(&mut d, 5, |d| d.snapshot().decks[1 - d.master()].record.id == q3.id), "a record queued after the end is next");
}
