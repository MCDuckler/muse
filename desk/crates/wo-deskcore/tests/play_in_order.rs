//! A list played in order: each record from its start, the next waiting on the other
//! deck, a plain crossfade at the end of each (no planner's move), then the one after.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::{Desk, Transition};

fn run(d: &mut Desk, ms: u64) {
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_millis(ms) {
        d.tick();
        sleep(Duration::from_millis(20));
    }
}

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
fn a_list_plays_in_order_with_plain_fades() {
    let empty = std::env::temp_dir().join(format!("wo-no-records-order-{}", std::process::id()));
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
    // the two made-up records, and two more made up the same way
    let s0 = d.snapshot();
    let (a, b) = (s0.decks[0].record.clone(), s0.decks[1].record.clone());
    let more = |seed: u32, id: i64| wo_deskcore::Record { id, title: format!("Test Pressing {id}"), audio: wo_deskcore::Audio::Synth { seed }, ..a.clone() };
    let list = vec![b, a.clone(), more(3, -3), more(4, -4)];
    d.play_list("test".into(), list.clone(), 0);

    let s = d.snapshot();
    let m = s.decks.iter().position(|v| v.record.id == list[0].id).expect("the first on a deck");
    assert_eq!(d.master(), m);
    assert_eq!(s.decks[1 - m].record.id, list[1].id, "the second waits on the other deck");
    assert_eq!(s.player.as_ref().map(|p| (p.at, p.len)), Some((0, list.len())));
    assert_eq!(s.up_next.first().map(|r| r.id), Some(list[1].id));
    assert!(s.auto);

    // a plain fade planned for the master's end
    assert!(until(&mut d, 20, |d| d.snapshot().mix.is_some()), "a move planned");
    let mix = d.snapshot().mix.unwrap();
    assert_eq!(mix.kind, Transition::Fade);
    assert_eq!(mix.why, "in order");
    let heard = d.snapshot().decks[m].heard;
    assert!(heard < 3.0, "the first plays from its start: {heard}");
    let left = list[0].seconds as f64 - heard;
    assert!((mix.starts_in - (left - 3.0)).abs() < 4.0, "out 3 s before the end: in {} of {left}", mix.starts_in);

    // to its end: the fade, then the second is the master and the third waits
    let len = d.snapshot().decks[m].length;
    d.seek_to(m, len - 5.0);
    assert!(until(&mut d, 15, |d| d.master() != m && d.snapshot().mix.is_none_or(|x| !x.mixing)), "the second took over");
    let s = d.snapshot();
    assert_eq!(s.decks[1 - m].record.id, list[1].id);
    assert!(s.decks[1 - m].heard < 8.0, "the second from its start: {}", s.decks[1 - m].heard);
    assert_eq!(s.decks[m].record.id, list[2].id, "the third waits");
    assert_eq!(s.player.as_ref().map(|p| p.at), Some(1));

    // back (early in a record): the one before, from its start
    d.list_back();
    run(&mut d, 200);
    let s = d.snapshot();
    assert_eq!(s.decks[d.master()].record.id, list[0].id);
    assert_eq!(s.player.as_ref().map(|p| p.at), Some(0));
    assert!(s.decks[d.master()].playing);

    // stopped: the Auto DJ chooses again (the list's next no longer kept)
    d.stop_list();
    assert!(d.snapshot().player.is_none());
}
