//! A pretend Pioneer DDJ-400 on a virtual ALSA MIDI port driving the real desk (silently,
//! on the synthesised records): its own SHIFT, 14-bit knobs (MSB then LSB), hot cues 5–8,
//! the beat-loop pads, the touched platter and the Beat FX as the echo. Its own test
//! binary: the engine is one per process, and the RMX's test has a pretend port of its own.
//! Linux only.
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

/// What the Desk did with control `id`, newest last.
fn did(d: &Desk, id: &str) -> Vec<String> {
    d.control_monitor().1.iter().filter(|l| l.id == id).flat_map(|l| l.did.clone()).collect()
}

#[test]
fn the_ddj_400_plays_the_booth() {
    let Ok(out) = midir::MidiOutput::new("Pretend") else { return eprintln!("no ALSA sequencer: skipped") };
    let Ok(mut ddj) = out.create_virtual("DDJ-400") else { return eprintln!("no virtual ports: skipped") };
    let empty = std::env::temp_dir().join(format!("wo-controller-ddj-{}", std::process::id()));
    std::fs::create_dir_all(&empty).unwrap();
    // SAFETY: before any thread reads the environment.
    unsafe {
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_RECORDS", &empty);
        // never the house: no saved sign-in read, nothing told to any account
        std::env::set_var("WO_HOUSE", "off");
        std::env::set_var("XDG_CONFIG_HOME", &empty);
        std::env::set_var("WO_RESUME", "off");
    }
    let mut d = Desk::open(false);
    assert!(until(&mut d, 8.0, |d| !d.controllers().is_empty()), "the pretend DDJ-400 was not found");
    let found = d.controllers();
    assert!(found[0].layout == "Pioneer DDJ-400" && found[0].trouble.is_none(), "{found:?}");
    sleep(Duration::from_millis(200));
    let mut send = |m: &[u8]| ddj.send(m).unwrap();

    // B's PLAY, on deck 2's channel
    send(&[0x91, 0x0B, 0x7F]);
    send(&[0x91, 0x0B, 0x00]);
    assert!(until(&mut d, 2.0, |d| d.snapshot().decks[1].playing), "B's PLAY did not play B");

    // A's TRIM, 14 bits: far from the booth's (unity) first — not taken; then across it
    send(&[0xB0, 0x04, 0x10]);
    send(&[0xB0, 0x24, 0x00]);
    until(&mut d, 0.3, |_| false);
    assert_eq!(d.snapshot().decks[0].gain, 0.5, "a knob far from the booth's is not taken");
    assert_eq!(did(&d, "deck.a.trim"), ["waits until it reaches the booth's"], "and the monitor says why");
    send(&[0xB0, 0x04, 0x50]);
    send(&[0xB0, 0x24, 0x00]);
    assert!(until(&mut d, 1.0, |d| (d.snapshot().decks[0].gain - 0.625).abs() < 0.01), "crossing unity, the trim takes over: {}", d.snapshot().decks[0].gain);

    // hot cue 6 on B set where it plays; SHIFT + it (the shifted pads' channel) clears it
    send(&[0x99, 0x05, 0x7F]);
    send(&[0x99, 0x05, 0x00]);
    assert!(until(&mut d, 1.0, |d| d.snapshot().decks[1].pads[5].is_some()), "hot cue 6 not set");
    send(&[0x91, 0x3F, 0x7F]);
    send(&[0x9A, 0x05, 0x7F]);
    send(&[0x9A, 0x05, 0x00]);
    send(&[0x91, 0x3F, 0x00]);
    assert!(until(&mut d, 1.0, |d| d.snapshot().decks[1].pads[5].is_none()), "SHIFT + hot cue 6 did not clear it");
    let shifts: Vec<_> = d.control_monitor().1.into_iter().filter(|l| l.id == "deck.b.shift").collect();
    assert!(shifts.len() == 2 && shifts.iter().all(|l| l.did.is_empty()), "SHIFT down and up, and nothing done for either (no STOP): {shifts:?}");
    assert!(d.snapshot().decks[1].playing, "still playing");

    // the BEAT LOOP pad for 4 beats, then the same again lets go
    send(&[0x99, 0x64, 0x7F]);
    send(&[0x99, 0x64, 0x00]);
    assert!(until(&mut d, 1.0, |d| d.snapshot().decks[1].looped.is_some() && d.snapshot().decks[1].loop_beats == Some(4.0)), "no 4-beat loop");
    send(&[0x99, 0x64, 0x7F]);
    assert!(until(&mut d, 1.0, |d| d.snapshot().decks[1].looped.is_none()), "the same pad again did not let go");

    // true scratching: the platter touched holds B's record still; turned back a quarter
    // of a second's worth, the record goes back with it; let go, it plays on
    send(&[0x91, 0x36, 0x7F]);
    assert!(until(&mut d, 1.0, |d| d.snapshot().decks[1].held), "touched: a hand on B's record");
    assert!(until(&mut d, 1.0, |d| did(d, "deck.b.jog.touch").iter().any(|w| w == "a hand on B's record")), "{:?}", did(&d, "deck.b.jog.touch"));
    until(&mut d, 0.2, |_| false);
    let held = d.snapshot().decks[1].heard;
    until(&mut d, 0.3, |_| false);
    let still = d.snapshot().decks[1].heard;
    assert!((still - held).abs() < 0.01 && d.snapshot().decks[1].playing, "held still, the motor on: {held} → {still}");
    // five turns of the top, 20 of its 720 ticks back each: 1.8 s a turn → 0.25 s back
    for _ in 0..5 {
        send(&[0xB1, 0x22, 0x40 - 20]);
        sleep(Duration::from_millis(10));
    }
    assert!(still > 0.3, "far enough in to go back: {still}");
    assert!(until(&mut d, 1.0, |d| (d.snapshot().decks[1].heard - (still - 0.25)).abs() < 0.02), "back with the hand: {still} → {}", d.snapshot().decks[1].heard);
    assert!(until(&mut d, 1.0, |d| did(d, "deck.b.jog.scratch").iter().any(|w| w == "B's record -50.0 ms")), "{:?}", did(&d, "deck.b.jog.scratch").last());
    send(&[0x91, 0x36, 0x00]);
    assert!(until(&mut d, 1.0, |d| !d.snapshot().decks[1].held && (d.snapshot().decks[1].speed - d.snapshot().decks[1].rate).abs() < 0.01), "let go: up to speed");
    let from = d.snapshot().decks[1].heard;
    until(&mut d, 0.5, |_| false);
    let on = d.snapshot().decks[1].heard - from;
    assert!((0.4..0.6).contains(&on), "plays on: {on} s in half a second");

    // the platter's top turned with no touch heard (the touch's note missed): the bend
    // as before, in the booth's ticks
    send(&[0xB1, 0x22, 0x40 + 9]);
    assert!(until(&mut d, 1.0, |d| did(d, "deck.b.jog.scratch").iter().any(|a| a.contains("scratch: true") && a.contains("ticks: 1.6"))), "{:?}", did(&d, "deck.b.jog.scratch"));

    // Beat FX: on → the echo on both decks (MASTER), CH SELECT 2 → B's only
    send(&[0x94, 0x47, 0x7F]);
    assert!(until(&mut d, 1.0, |d| did(d, "fx.on").iter().any(|a| a == "Echo(0, 0.5)")), "{:?}", did(&d, "fx.on"));
    send(&[0x94, 0x11, 0x7F]);
    assert!(until(&mut d, 1.0, |d| did(d, "fx.to.b") == ["Echo(0, 0.0)", "Echo(1, 0.5)"]), "{:?}", did(&d, "fx.to.b"));

    // the monitor names a 14-bit control's first half as its own, not as unknown
    let (packets, _) = d.control_monitor();
    let msb = packets.iter().find(|p| p.bytes == [0xB0, 0x04, 0x50]).expect("the TRIM's MSB kept");
    assert!(msb.read.iter().any(|r| r.starts_with("deck.a.trim")), "{msb:?}");
}
