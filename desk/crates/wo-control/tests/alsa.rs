//! A pretend RMX on a virtual ALSA MIDI port: found by its name, connected, and its
//! PLAY press decoded — the whole MIDI path short of the hardware. Linux only.
#![cfg(target_os = "linux")]
use std::thread::sleep;
use std::time::{Duration, Instant};

use midir::os::unix::VirtualOutput;
use wo_control::Manager;

#[test]
fn a_pretend_rmx_is_found_and_heard() {
    let Ok(out) = midir::MidiOutput::new("Pretend") else { return eprintln!("no ALSA sequencer: skipped") };
    let Ok(mut rmx) = out.create_virtual("Hercules DJ Console RMX") else { return eprintln!("no virtual ports: skipped") };
    let m = Manager::start();
    let t0 = Instant::now();
    while m.controllers().is_empty() && t0.elapsed() < Duration::from_secs(8) {
        sleep(Duration::from_millis(100));
    }
    let found = m.controllers();
    assert_eq!(found.len(), 1, "found {found:?}");
    assert!(found[0].layout.contains("RMX") && found[0].trouble.is_none(), "{found:?}");
    sleep(Duration::from_millis(200));
    rmx.send(&[0xB0, 0x0B, 0x7F]).unwrap();
    rmx.send(&[0xB0, 0x31, 0x00]).unwrap(); // the pitch fader, inverted: all the way up is 1
    let t0 = Instant::now();
    let mut got = vec![];
    while got.len() < 2 && t0.elapsed() < Duration::from_secs(3) {
        got.extend(m.poll());
        sleep(Duration::from_millis(20));
    }
    assert!(got.iter().any(|e| e.id == "deck.a.play" && e.pressed()), "{got:?}");
    assert!(got.iter().any(|e| e.id == "deck.a.pitch" && (e.value - 1.0).abs() < 1e-9), "{got:?}");
}
