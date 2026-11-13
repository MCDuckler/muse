//! The headphones (the cue bus), offline: a cued deck is heard in them before its fader,
//! an uncued one not; the blend goes from the cued decks alone to the master alone; the
//! level scales them; and with no headphones routed nothing is rendered for them.
use std::sync::Mutex;

use wo_engine::{Channels, Cue, DeckId, Engine, Gains, Output, Route, Source};

const R: u32 = 48_000;
static TURN: Mutex<()> = Mutex::new(());

/// `seconds` of a sine at `hz`, `amp`.
fn sine(e: &Engine, seconds: f64, hz: f64, amp: f32) -> Source {
    let n = (seconds * R as f64) as usize;
    let mut pcm = vec![0i16; n * 2];
    for i in 0..n {
        let v = (amp as f64 * (std::f64::consts::TAU * hz * i as f64 / R as f64).sin() * 32_767.0) as i16;
        pcm[i * 2] = v;
        pcm[i * 2 + 1] = v;
    }
    let mut s = e.new_source(Channels::Stereo, n as i64).unwrap();
    s.append(&pcm).unwrap();
    s.finish();
    s
}

/// `seconds` of the master and the headphones.
fn render(e: &Engine, seconds: f64) -> (Vec<f32>, Vec<f32>) {
    const BLOCK: usize = 480;
    let (mut m, mut c) = (vec![], vec![]);
    let (mut mb, mut cb) = (vec![0f32; BLOCK * 2], vec![0f32; BLOCK * 2]);
    while m.len() < (seconds * R as f64) as usize * 2 {
        e.render_cue(&mut mb, &mut cb).unwrap();
        m.extend_from_slice(&mb);
        c.extend_from_slice(&cb);
    }
    (m, c)
}

fn rms(x: &[f32]) -> f32 {
    (x.iter().map(|v| v * v).sum::<f32>() / x.len().max(1) as f32).sqrt()
}

/// The last half of it (ramps and the limiter's look-ahead past).
fn tail(x: &[f32]) -> &[f32] {
    &x[x.len() / 2..]
}

fn setup(e: &Engine, d: usize, src: &Source, level: f32) {
    let deck = e.deck(DeckId::new(d).unwrap());
    deck.set_source(0, src);
    deck.set_gains(0, Gains::FULL, 0.0);
    deck.set_level(level, 0.0);
    deck.play(true);
}

#[test]
fn a_cued_deck_is_heard_before_its_fader() {
    let _t = TURN.lock().unwrap_or_else(|e| e.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    e.route(&Route { cue: Cue::Device { name: None, ch: 0 }, ..Default::default() }).unwrap();
    let a = sine(&e, 2.0, 440.0, 0.3);
    let b = sine(&e, 2.0, 660.0, 0.3);
    setup(&e, 0, &a, 0.0); // fader down: only in the headphones
    setup(&e, 1, &b, 1.0); // on air, not cued
    e.deck(DeckId::new(0).unwrap()).set_cue(1.0, 0.0);
    e.set_cue_mix(0.0, 1.0);
    let (m, c) = render(&e, 0.5);
    // the master: B alone; the headphones: A alone (the same as B would be at its level)
    let (m, c) = (tail(&m), tail(&c));
    assert!(rms(m) > 0.05, "the master plays B: {}", rms(m));
    assert!((rms(c) - rms(m)).abs() < 0.01, "A in the headphones as loud as B on air: {} vs {}", rms(c), rms(m));
    // A is not B: the headphones' signal does not follow the master's
    let diff: Vec<f32> = c.iter().zip(m).map(|(x, y)| x - y).collect();
    assert!(rms(&diff) > 0.05, "the headphones are not the master");
}

#[test]
fn the_blend_and_the_level() {
    let _t = TURN.lock().unwrap_or_else(|e| e.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    e.route(&Route { cue: Cue::Split, ..Default::default() }).unwrap();
    let a = sine(&e, 2.0, 440.0, 0.3);
    setup(&e, 0, &a, 1.0);
    // not cued, the master alone in them: what the master is
    e.set_cue_mix(1.0, 1.0);
    let (m, c) = render(&e, 0.4);
    let diff: Vec<f32> = tail(&c).iter().zip(tail(&m)).map(|(x, y)| x - y).collect();
    assert!(rms(&diff) < 1e-4, "mix 1 is the master: {}", rms(&diff));
    // the cued decks alone, none cued: silent
    e.set_cue_mix(0.0, 1.0);
    let (_, c) = render(&e, 0.4);
    assert!(rms(tail(&c)) < 1e-4, "nothing cued, nothing heard: {}", rms(tail(&c)));
    // the level halves it
    e.set_cue_mix(1.0, 0.5);
    let (m, c) = render(&e, 0.4);
    let k = rms(tail(&c)) / rms(tail(&m));
    assert!((k - 0.5).abs() < 0.02, "level 0.5: {k}");
}

#[test]
fn no_headphones_routed_none_rendered() {
    let _t = TURN.lock().unwrap_or_else(|e| e.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let a = sine(&e, 2.0, 440.0, 0.3);
    setup(&e, 0, &a, 0.0);
    e.deck(DeckId::new(0).unwrap()).set_cue(1.0, 0.0);
    e.set_cue_mix(0.0, 1.0);
    let (_, c) = render(&e, 0.4);
    assert!(rms(tail(&c)) < 1e-6, "no route, no headphones: {}", rms(tail(&c)));
    // routed, then back to none
    e.route(&Route { cue: Cue::Device { name: None, ch: 0 }, ..Default::default() }).unwrap();
    let (_, c) = render(&e, 0.4);
    assert!(rms(tail(&c)) > 0.05);
    e.route(&Route::default()).unwrap();
    let (_, c) = render(&e, 0.4);
    assert!(rms(tail(&c)) < 1e-6);
}
