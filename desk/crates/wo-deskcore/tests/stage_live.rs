//! The Desk and a real stage window (the WetOwl app built from this checkout), on a
//! display: the stage connects and says what it shows, the Desk's PERFORM hands reach
//! its director and come back as words, the screens are listed and one is filled.
//! Opt-in, needs WO_STAGE (the app's program) and a display:
//!
//!   WO_STAGE=…/bundle/wetowl cargo test --release -p wo-deskcore --test stage_live -- --ignored --nocapture
//!
//! Everything the stage and the Desk keep (show.json, prefs, the screen kept) goes to
//! a folder of the test's own: the Desk's and the WetOwl app's real ones are not touched.
use std::thread::sleep;
use std::time::{Duration, Instant};

use wo_deskcore::{Desk, ShowHand, StageView};

fn until(d: &mut Desk, what: &str, secs: u64, mut ok: impl FnMut(&StageView) -> bool) -> StageView {
    let t0 = Instant::now();
    loop {
        d.tick();
        let v = d.stage();
        if ok(&v) {
            println!("{what}: {:.1}s", t0.elapsed().as_secs_f32());
            return v;
        }
        assert!(t0.elapsed() < Duration::from_secs(secs), "{what}: not in {secs}s — {v:?}");
        sleep(Duration::from_millis(10));
    }
}

#[test]
#[ignore]
fn the_desk_performs_a_real_stage() {
    assert!(std::env::var_os("WO_STAGE").is_some(), "WO_STAGE: the WetOwl app's program");
    let home = std::env::temp_dir().join(format!("wo-stage-live-{}", std::process::id()));
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
        std::env::set_var("WETOWL_MILK_HOME", home.join("milk"));
    }
    let mut d = Desk::open(true);
    d.open_stage();
    let v = until(&mut d, "the stage tells its look", 90, |v| v.stages == 1 && v.told.look.is_some());
    println!("look: {:?}; screens: {:?}", v.told.look, v.told.screens);
    let t0 = Instant::now();
    while d.stage_thumb().is_none() {
        d.tick();
        assert!(t0.elapsed() < Duration::from_secs(10), "no picture");
        sleep(Duration::from_millis(10));
    }

    let said = |v: &StageView| v.told.said.clone().unwrap_or_default();
    let n = v.told.said_n;
    d.show(ShowHand::Never);
    let v = until(&mut d, "NEVER THIS", 5, |v| v.told.said_n > n && said(v).starts_with("Never:") && v.told.undo);
    println!("said: {}", said(&v));
    d.show(ShowHand::Undo);
    until(&mut d, "UNDO", 5, |v| said(v) == "Undone" && !v.told.undo);
    d.show(ShowHand::Less);
    until(&mut d, "LESS", 5, |v| said(v).starts_with("Less:"));
    d.show(ShowHand::Hold(true));
    until(&mut d, "HOLD", 5, |v| v.held && v.told.holds > 0);
    d.show(ShowHand::LetGo);
    until(&mut d, "LET GO", 5, |v| !v.held && v.told.holds == 0);
    d.show(ShowHand::Freeze(true));
    until(&mut d, "FREEZE", 5, |v| v.freeze);
    d.show(ShowHand::Freeze(false));
    until(&mut d, "thawed", 5, |v| !v.freeze);
    d.show(ShowHand::Set(String::new()));
    until(&mut d, "the show as shipped", 5, |v| said(v) == "The show as shipped");

    // the screens: the last one filled, then a window again
    let screens = d.stage().told.screens;
    assert!(!screens.is_empty(), "no screens listed");
    let last = screens.last().unwrap().name.clone();
    d.show(ShowHand::Screen(last.clone()));
    let v = until(&mut d, "full screen on the last screen", 10, |v| v.told.full && v.told.screen.as_deref() == Some(last.as_str()));
    assert_eq!(v.kept_screen.as_deref(), Some(last.as_str()), "the Desk keeps the screen");
    // still full screen once the stage has asked its window again (every 4 s)
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_secs(6) {
        d.tick();
        sleep(Duration::from_millis(10));
    }
    assert!(d.stage().told.full, "the window is not full screen: {:?}", d.stage().told);
    d.show(ShowHand::Full(false));
    until(&mut d, "a window again", 10, |v| !v.told.full);
    assert_eq!(d.stage().kept_screen, None);
    d.close_stage();
    let _ = std::fs::remove_dir_all(&home);
}
