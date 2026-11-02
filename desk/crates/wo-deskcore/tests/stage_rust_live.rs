//! The Desk and the Rust stage (apps/wetowl-stage), on a display: the Desk directs, the
//! stage connects, says it is v2, sends its picture; the hands move the Desk's director and
//! the picture follows (a blackout goes dark); a screen is filled and let go.
//! Opt-in, needs WO_STAGE_RUST (the stage's program) and a display:
//!
//!   WO_STAGE_RUST=target/release/wetowl-stage cargo test --release -p wo-deskcore --test stage_rust_live -- --ignored --nocapture
//!
//! Everything the Desk keeps goes to a folder of the test's own.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::{Desk, ShowHand, StageView};

fn until(d: &mut Desk, what: &str, secs: u64, mut ok: impl FnMut(&mut Desk, &StageView) -> bool) -> StageView {
    let t0 = Instant::now();
    loop {
        d.tick();
        let v = d.stage();
        if ok(d, &v) {
            println!("{what}: {:.1}s", t0.elapsed().as_secs_f32());
            return v;
        }
        assert!(t0.elapsed() < Duration::from_secs(secs), "{what}: not in {secs}s — {v:?}");
        sleep(Duration::from_millis(10));
    }
}

/// The newest picture's mean light, and its count.
fn light(d: &Desk) -> Option<(u64, f64)> {
    d.stage_thumb().map(|(n, t)| (n, t.rgba.chunks(4).map(|p| (p[0] as f64 + p[1] as f64 + p[2] as f64) / 3.0).sum::<f64>() / (t.width * t.height) as f64))
}

#[test]
#[ignore]
fn the_desk_directs_the_rust_stage() {
    assert!(std::env::var_os("WO_STAGE_RUST").is_some(), "WO_STAGE_RUST: the Rust stage's program");
    let home = std::env::temp_dir().join(format!("wo-stage-rust-live-{}", std::process::id()));
    for d in ["config", "data", "cache", "records"] {
        std::fs::create_dir_all(home.join(d)).unwrap();
    }
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("WO_RECORDS", home.join("records"));
        std::env::set_var("XDG_CONFIG_HOME", home.join("config"));
        std::env::set_var("XDG_DATA_HOME", home.join("data"));
        std::env::set_var("XDG_CACHE_HOME", home.join("cache"));
    }
    let mut d = Desk::open(true);
    d.set_rust_stage(true);
    d.open_stage();
    let v = until(&mut d, "the Rust stage reads and the Desk directs", 60, |_, v| v.stages == 1 && v.rust && v.why.is_some() && v.scene.is_some());
    println!("scene: {:?} ({:?})", v.scene, v.why);
    let lit = until(&mut d, "its picture", 20, |d, _| light(d).is_some_and(|(_, l)| l > 2.0));
    let _ = lit;
    let (n0, l0) = light(&d).unwrap();
    println!("picture {n0}: light {l0:.1}");

    // NEXT: the Desk's director moves on, and the stage draws it
    let before = d.stage().scene.clone();
    d.show(ShowHand::Next);
    until(&mut d, "NEXT", 5, |_, v| v.scene != before);

    // the blackout: the Desk says it, the picture goes dark
    d.show(ShowHand::Blackout(true));
    until(&mut d, "the blackout's picture", 10, |d, v| v.blackout && light(d).is_some_and(|(n, l)| n > n0 + 2 && l < 1.0));
    d.show(ShowHand::Blackout(false));
    until(&mut d, "light again", 10, |d, v| !v.blackout && light(d).is_some_and(|(_, l)| l > 2.0));

    // the screens: one filled, then a window again
    let v = until(&mut d, "the screens told", 10, |_, v| !v.told.screens.is_empty());
    let name = v.told.screens.last().unwrap().name.clone();
    println!("screens: {:?}", v.told.screens.iter().map(|s| (&s.name, s.w, s.h)).collect::<Vec<_>>());
    d.show(ShowHand::Screen(name.clone()));
    until(&mut d, "full screen there", 10, |_, v| v.told.full && v.told.screen.as_deref() == Some(name.as_str()));
    d.show(ShowHand::Full(false));
    until(&mut d, "a window again", 10, |_, v| !v.told.full);
    d.close_stage();
    let _ = std::fs::remove_dir_all(&home);
}
