//! PAD FX borrows FX2 while a pad is held and gives it back as it was.
use wo_deskcore::Desk;
use wo_deskcore::beat_fx::{BeatFxKind, Target};

#[test]
fn a_pad_fx_gives_fx2_back() {
    let empty = std::env::temp_dir().join(format!("wo-pad-fx-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&empty);
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_RECORDS", &empty);
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("WO_USB", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
        std::env::set_var("XDG_CONFIG_HOME", &empty);
    }
    let mut d = Desk::open(false);
    d.set_fx_kind(1, BeatFxKind::Phaser);
    d.set_fx_level(1, 0.3);
    d.set_fx_target(1, Target::Master);
    let before = d.fx_units()[1].clone();
    d.pad_fx(0, BeatFxKind::Roll, 0.25, true);
    let held = d.fx_units()[1].clone();
    assert!(held.on && held.kind == BeatFxKind::Roll && held.target == Target::Deck(0) && held.beats == 0.25, "{held:?}");
    // a second pad while the first is held: still FX2 as it was in the end
    d.pad_fx(0, BeatFxKind::Echo, 0.5, true);
    d.pad_fx(0, BeatFxKind::Echo, 0.5, false);
    assert_eq!(d.fx_units()[1], before, "FX2 as it was");
    let _ = std::fs::remove_dir_all(&empty);
}
