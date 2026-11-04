//! A house record onto a deck, end to end, read-only, with the WetOwl app's sign-in on
//! this computer (not saved into the Desk's). Opt-in:
//! `cargo test -p wo-deskcore --test house -- --ignored`.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::{Desk, Shelf};

fn until(mut done: impl FnMut() -> bool, secs: u64) -> bool {
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_secs(secs) {
        if done() {
            return true;
        }
        sleep(Duration::from_millis(50));
    }
    false
}

#[test]
#[ignore]
fn a_house_record_plays_on_its_grid() {
    let Some(session) = wo_house::Session::from_wetowl_app() else {
        eprintln!("no WetOwl app sign-in here: skipped");
        return;
    };
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
    }
    let mut d = Desk::open(false);
    d.set_auto(false);
    d.use_session(session);
    let filled = until(|| { d.tick(); !d.library().loading && !d.library().rows.is_empty() }, 20);
    assert!(filled, "the shelf never came: {:?}", d.library().error);
    assert_eq!(d.library().shelf, Shelf::All);
    eprintln!("shelf: {} of {}", d.library().rows.len(), d.library().total);

    let record = d.library().rows.iter().find(|r| r.playable()).cloned().expect("a ready record");
    eprintln!("loading {} — {}", record.title, record.artist);
    d.load(1, record.clone());
    let ready = until(|| { d.tick(); let v = &d.snapshot().decks[1]; v.decoded > 0.05 && !v.pads.iter().all(Option::is_none) }, 60);
    let v = d.snapshot().decks[1].clone();
    assert!(ready, "no audio or no grid in time (decoded {:.2}, error {:?})", v.decoded, d.library().error);
    eprintln!("deck B: {} at {:.2} bpm, key {:?}, pads {:?}", v.record.title, v.bpm, v.record.key, v.pads.iter().flatten().map(|p| (p.at, p.auto)).collect::<Vec<_>>());
    assert!(v.bpm > 60.0 && v.bpm < 220.0);

    // it plays on its grid: a 4-beat loop from the bar is 4 of its beats long
    d.toggle_play(1);
    d.loop_beats(1, 4.0);
    let (a, b) = d.snapshot().decks[1].looped.expect("looping");
    assert!(((b - a) - 4.0 * 60.0 / v.bpm).abs() < 0.01, "a 4-beat loop is {:.3} s at {:.2} bpm", b - a, v.bpm);

    // a search reaches the house
    d.open_shelf(Shelf::Search(record.title.split_whitespace().next().unwrap_or("a").to_owned()));
    assert!(until(|| { d.tick(); !d.library().loading }, 20));
    eprintln!("search: {} found", d.library().rows.len());
    assert!(d.library().rows.iter().any(|r| r.id == record.id), "the record finds itself by its title");
}

/// The house's set builder and slot choices, read-only (nothing is kept by either): a
/// short set from the library, read as the Desk reads it.
#[test]
#[ignore]
fn the_house_builds_a_set_and_chooses_a_slot() {
    let Some(session) = wo_house::Session::from_wetowl_app() else {
        eprintln!("no WetOwl app sign-in here: skipped");
        return;
    };
    let house = wo_house::House::new(session);
    let body = serde_json::json!({
        "source": { "library": true },
        "shape": { "energy": [[0.0, 0.3], [1.0, 0.8]], "key": "loose", "variety": { "gap": 3, "smooth": 0.5, "fresh": 0.5 }, "stems": false, "offset": 0.0 },
        "length": { "tracks": 4 },
    });
    let raw = house.build_set(&body).expect("a set");
    let set = raw.get("slots").and_then(|s| s.as_array()).expect("slots");
    eprintln!("{} slots; first: {}", set.len(), set[0]["track"]["title"]);
    assert_eq!(set.len(), 4);
    assert!(set[1]["fit"].is_number() && set[1]["why"].is_string());
    let first = set[0]["track"]["id"].as_i64().unwrap();
    let choices = house
        .slot_choices(&serde_json::json!({ "source": { "library": true }, "shape": body["shape"], "prev": first, "k": 0, "exclude": [first], "limit": 3 }))
        .expect("choices");
    eprintln!("after {first}: {:?}", choices.iter().map(|c| (&c.track.title, c.fit_in, &c.why)).collect::<Vec<_>>());
    assert!(!choices.is_empty());
}
