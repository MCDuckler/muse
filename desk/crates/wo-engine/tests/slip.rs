//! SLIP: held by a hand or by a loop, the record's own place runs on; let go, it goes on
//! from there (not from where the hand or the loop left it).
use std::sync::Mutex;

use wo_engine::{Channels, DeckId, Engine, Gains, Output};

const R: u32 = 48_000;
const BLOCK: usize = 480;
static TURN: Mutex<()> = Mutex::new(());

fn setup(e: &Engine) -> wo_engine::Source {
    let a = DeckId::new(0).unwrap();
    let n = 60 * R as usize;
    let mut pcm = vec![0i16; n * 2];
    let mut s = 3u32;
    for v in pcm.iter_mut() {
        s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        *v = ((s >> 16) as i32 - 32_768) as i16 / 8;
    }
    let mut src = e.new_source(Channels::Stereo, n as i64).unwrap();
    src.append(&pcm).unwrap();
    src.finish();
    let deck = e.deck(a);
    deck.set_source(0, &src);
    deck.set_gains(0, Gains::FULL, 0.0);
    deck.set_level(1.0, 0.0);
    deck.set_keylock(false);
    deck.set_beats(&(0..120).map(|i| i as f64 * 0.5).collect::<Vec<_>>());
    src
}

fn render(e: &Engine, seconds: f64) {
    let (mut m, mut a) = (vec![0f32; BLOCK * 2], vec![0f32; BLOCK * 2]);
    for _ in 0..(seconds * R as f64 / BLOCK as f64).round() as usize {
        let mut outs: [Option<&mut [f32]>; 4] = [Some(&mut a), None, None, None];
        e.render(&mut m, &mut outs).unwrap();
    }
}

#[test]
fn a_held_record_slips_on() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let _src = setup(&e);
    let deck = e.deck(DeckId::new(0).unwrap());
    deck.set_slip(true);
    deck.seek(5.0);
    deck.play(true);
    render(&e, 0.5);
    // a hand on it, still, for a second: let go, it is where it would have been
    deck.scratch(true);
    render(&e, 1.0);
    deck.scratch(false);
    render(&e, 0.3);
    let at = deck.read().heard;
    assert!((at - 6.8).abs() < 0.08, "on from SLIP's place: {at} (6.8 had nothing held it)");

    // a loop of a beat for two seconds, let go: on from where it would be
    deck.set_loop(10.0, 10.5);
    deck.seek(10.0);
    deck.slip_loop(true);
    // (the seek and the loop are taken at the next block: SLIP's place starts at 10)
    let t0 = 10.0;
    render(&e, 2.0);
    deck.clear_loop();
    deck.slip_loop(false);
    render(&e, 0.2);
    let at = deck.read().heard;
    assert!((at - (t0 + 2.2)).abs() < 0.08, "a loop let go: on from {:.2}, at {at}", t0 + 2.2);

    // SLIP off: let go of a hand, it goes on from where the hand left it
    deck.set_slip(false);
    let before = deck.read().heard;
    deck.scratch(true);
    render(&e, 1.0);
    deck.scratch(false);
    render(&e, 0.3);
    let at = deck.read().heard;
    assert!(at < before + 0.6, "without SLIP: from where it was held: {before} → {at}");
}
