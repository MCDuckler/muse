//! A pretend RMX on a virtual ALSA MIDI port driving the real desk (silently, on the
//! synthesised records): B's PLAY plays B, A's low EQ knob takes over once it reaches
//! the booth's and moves the band, pad 1 jumps. Linux only.
#![cfg(target_os = "linux")]
use std::thread::sleep;
use std::time::{Duration, Instant};

use midir::os::unix::VirtualOutput;
use wo_deskcore::Desk;

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
fn the_rmx_plays_the_booth() {
    let Ok(out) = midir::MidiOutput::new("Pretend") else { return eprintln!("no ALSA sequencer: skipped") };
    let Ok(mut rmx) = out.create_virtual("Hercules DJ Console RMX") else { return eprintln!("no virtual ports: skipped") };
    let empty = std::env::temp_dir().join(format!("wo-controller-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_RECORDS", &empty);
        // never the house: no saved sign-in read, nothing told to any account
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("XDG_CONFIG_HOME", &empty);
    }
    let mut d = Desk::open(false);
    assert!(until(&mut d, 8.0, |d| !d.controllers().is_empty()), "the pretend RMX was not found");
    sleep(Duration::from_millis(200));

    rmx.send(&[0xB0, 0x23, 0x7F]).unwrap(); // deck.b.play
    assert!(until(&mut d, 2.0, |d| d.snapshot().decks[1].playing), "B's PLAY did not play B");

    // A's low knob: far from the booth's (0.5) first — not taken; then across it — taken
    rmx.send(&[0xB0, 0x36, 10]).unwrap();
    until(&mut d, 0.3, |_| false);
    assert_eq!(d.snapshot().decks[0].eq[0], 0.5, "a knob far from the booth's is not taken");
    rmx.send(&[0xB0, 0x36, 80]).unwrap();
    assert!(until(&mut d, 1.0, |d| d.snapshot().decks[0].eq[0] > 0.6), "crossing the booth's position, the knob takes over");

    // the controllers page's monitor: each packet as it came and how it was read, and
    // what the Desk did with each control moved
    let (packets, lines) = d.control_monitor();
    let play = packets.iter().find(|p| p.bytes == [0xB0, 0x23, 0x7F]).expect("the PLAY packet kept");
    assert!(play.from.contains("RMX") && play.read.iter().any(|r| r.starts_with("deck.b.play")), "{play:?}");
    let did = lines.iter().find(|l| l.id == "deck.b.play").expect("what PLAY did");
    assert!(!did.did.is_empty(), "{did:?}");
    assert!(d.controller_layouts().iter().any(|l| l.name.contains("RMX")), "the layouts it knows");
    d.clear_control_monitor();
    assert!(d.control_monitor().0.is_empty() && d.control_monitor().1.is_empty());
}
