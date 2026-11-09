//! A hand on the record, rendered offline: held, the record stops and is silent; pulled
//! back it plays backwards; let go it spins back up and goes on at its speed (handed back
//! to its voice); a parked record is scrubbed by the hand and stays where it was left.
use std::sync::Mutex;

use wo_engine::{Channels, DeckId, Engine, Gains, Output, Source};

const R: u32 = 48_000;
const BLOCK: usize = 480;

// One engine per process: the tests take turns.
static TURN: Mutex<()> = Mutex::new(());

/// Noise, loud enough to hear whether anything is played.
fn record(e: &Engine, d: DeckId, seconds: f64) -> Source {
    let n = (seconds * R as f64) as usize;
    let mut pcm = vec![0i16; n * 2];
    let mut s = 7u32;
    for i in 0..n {
        s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        let v = ((s >> 16) as i32 - 32_768) as i16 / 4;
        pcm[i * 2] = v;
        pcm[i * 2 + 1] = v;
    }
    let mut src = e.new_source(Channels::Stereo, n as i64).unwrap();
    src.append(&pcm).unwrap();
    src.finish();
    let deck = e.deck(d);
    deck.set_source(0, &src);
    deck.set_gains(0, Gains::FULL, 0.0);
    deck.set_level(1.0, 0.0);
    src
}

/// Renders `seconds`, `each` run before every block; deck `d`'s output's RMS.
fn render(e: &Engine, d: usize, seconds: f64, mut each: impl FnMut()) -> f32 {
    let n = (seconds * R as f64 / BLOCK as f64).round() as usize;
    let (mut m, mut a) = (vec![0f32; BLOCK * 2], vec![0f32; BLOCK * 2]);
    let mut sum = 0f64;
    for _ in 0..n {
        each();
        let mut outs: [Option<&mut [f32]>; 4] = [None, None, None, None];
        outs[d] = Some(&mut a);
        e.render(&mut m, &mut outs).unwrap();
        sum += a.iter().map(|x| (*x as f64) * (*x as f64)).sum::<f64>();
    }
    (sum / (n * BLOCK * 2).max(1) as f64).sqrt() as f32
}

#[test]
fn held_back_and_let_go() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let a = DeckId::new(0).unwrap();
    let _src = record(&e, a, 20.0);
    let deck = e.deck(a);
    deck.set_keylock(true);
    deck.seek(5.0);
    deck.play(true);
    let playing = render(&e, 0, 0.5, || {});
    assert!(playing > 0.02, "it plays: {playing}");
    let grabbed = deck.read().heard;

    // the hand on it, still: stopped within a few tens of milliseconds, then silent
    deck.scratch(true);
    render(&e, 0, 0.15, || {});
    let held = deck.read().heard;
    assert!(held - grabbed < 0.05, "stopped by the hand: {grabbed} → {held}");
    let quiet = render(&e, 0, 0.3, || {});
    let st = deck.read();
    assert!((st.heard - held).abs() < 0.002, "held still: {held} → {}", st.heard);
    assert!(st.playing, "the motor still runs under the hand");
    assert!(quiet < playing * 0.05, "a record held still is silent: {quiet} against {playing}");

    // pulled back a quarter of a second over a quarter of a second: backwards at its speed
    let mut rates = vec![];
    let back = render(&e, 0, 0.25, || {
        deck.scratch_by(-(BLOCK as f64) / R as f64);
        rates.push(deck.read().rate);
    });
    render(&e, 0, 0.1, || {});
    let st = deck.read();
    assert!((st.heard - (held - 0.25)).abs() < 0.01, "where the hand put it: {} vs {}", st.heard, held - 0.25);
    let mid = rates[rates.len() / 2];
    assert!((-1.15..-0.85).contains(&mid), "backwards at the hand's speed: {mid}");
    assert!(back > playing * 0.5, "heard going backwards: {back}");

    // let go: back up to speed in a tenth of a second, and on as before (key lock: its voice)
    let at = deck.read().heard;
    deck.scratch(false);
    render(&e, 0, 0.15, || {});
    let st = deck.read();
    assert!((st.rate - 1.0).abs() < 0.01 && st.playing, "up to speed: {st:?}");
    let from = st.heard;
    let on = render(&e, 0, 1.0, || {});
    let st = deck.read();
    assert!((st.heard - from - 1.0).abs() < 0.01, "plays on at its speed: {from} → {}", st.heard);
    assert!(from > at && from - at < 0.15, "from where it was let go: {at} → {from}");
    assert!(on > playing * 0.8, "heard as before: {on} against {playing}");
}

#[test]
fn a_parked_record_scrubbed() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let b = DeckId::new(1).unwrap();
    let _src = record(&e, b, 20.0);
    let deck = e.deck(b);
    deck.seek(3.0);
    let silent = render(&e, 1, 0.1, || {});
    assert!(silent < 1e-4, "parked: {silent}");
    // a hand from another thread's handle: the same as the deck's
    let hand = e.hand(b);
    hand.scratch(true);
    // half a second on over half a second: at its own speed
    let moving = render(&e, 1, 0.5, || hand.scratch_by(BLOCK as f64 / R as f64));
    assert!(moving > 0.02, "heard under the hand: {moving}");
    render(&e, 1, 0.1, || {});
    hand.scratch(false);
    render(&e, 1, 0.1, || {});
    let st = deck.read();
    assert!(!st.playing && (st.heard - 3.5).abs() < 0.01, "left where the hand put it: {st:?}");
    let after = render(&e, 1, 0.2, || {});
    assert!(after < 1e-4 && (deck.read().heard - st.heard).abs() < 1e-6, "and stays: {after}");
    // pressed PLAY: from there
    deck.play(true);
    render(&e, 1, 0.5, || {});
    assert!((deck.read().heard - 4.0).abs() < 0.02, "{}", deck.read().heard);
    // the hand outlives the engine harmlessly
    drop(e);
    hand.scratch(true);
    hand.scratch_by(1.0);
}

#[test]
fn no_clicks_on_and_off() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let a = DeckId::new(0).unwrap();
    // a 220 Hz sine: its steepest step is 2π·220/48000 of its height
    let (f, amp, secs) = (220.0f64, 0.5f64, 12.0f64);
    let n = (secs * R as f64) as usize;
    let mut pcm = vec![0i16; n * 2];
    for i in 0..n {
        let v = (amp * (2.0 * std::f64::consts::PI * f * i as f64 / R as f64).sin() * 32_767.0) as i16;
        pcm[i * 2] = v;
        pcm[i * 2 + 1] = v;
    }
    let mut src = e.new_source(Channels::Stereo, n as i64).unwrap();
    src.append(&pcm).unwrap();
    src.finish();
    let deck = e.deck(a);
    deck.set_source(0, &src);
    deck.set_gains(0, Gains::FULL, 0.0);
    deck.set_level(1.0, 0.0);
    deck.set_keylock(true);
    deck.seek(2.0);
    deck.play(true);
    let run = |out: &mut Vec<f32>, secs: f64, each: &mut dyn FnMut()| {
        let (mut m, mut x) = (vec![0f32; BLOCK * 2], vec![0f32; BLOCK * 2]);
        for _ in 0..(secs * R as f64 / BLOCK as f64).round() as usize {
            each();
            e.render(&mut m, &mut [Some(&mut x), None, None, None]).unwrap();
            out.extend(x.iter().step_by(2));
        }
    };
    let mut out: Vec<f32> = vec![];
    run(&mut out, 0.5, &mut || {});
    let from = out.len();
    deck.scratch(true);
    run(&mut out, 0.2, &mut || {});
    run(&mut out, 0.2, &mut || deck.scratch_by(-(BLOCK as f64) / R as f64));
    run(&mut out, 0.2, &mut || deck.scratch_by(BLOCK as f64 / R as f64 * 1.5));
    deck.scratch(false);
    run(&mut out, 0.5, &mut || {});
    let top = out[..from].iter().fold(0f32, |m, x| m.max(x.abs()));
    let slope = top as f64 * 2.0 * std::f64::consts::PI * f / R as f64;
    let worst = out.windows(2).skip(from).map(|w| (w[1] - w[0]).abs() as f64).fold(0.0, f64::max);
    // up to 1.5× its speed, a step 1.5× as steep, and a hair for the crossfades
    assert!(worst < slope * 1.5 * 1.15, "a click: a step of {worst:.4} where the sine's steepest is {slope:.4}");
}
