//! rekordbox's effects (the engine's fx.h), rendered offline over a record of a click a
//! beat at 120 BPM with its grid: each BEAT FX changes the sound and stays finite, a
//! one-beat DELAY lands one beat later, an ECHO rings on after it is turned off and the
//! deck stopped, a SOUND COLOR FX at its middle is the record untouched, a RELEASE FX
//! ECHO holds the last beat as the record drops away, a unit on the master works there.
use std::sync::Mutex;

use wo_engine::{BeatFx, BeatFxKind, Channels, ColorFxKind, DeckId, Engine, FxTarget, Gains, Output, ReleaseFxKind, Source};

const R: u32 = 48_000;
const BLOCK: usize = 480;
const SPB: f64 = 0.5;

static TURN: Mutex<()> = Mutex::new(());

/// A click on every beat (a short decaying burst), and the grid.
fn record(e: &Engine, d: DeckId, seconds: f64) -> Source {
    let n = (seconds * R as f64) as usize;
    let mut pcm = vec![0i16; n * 2];
    let per = (SPB * R as f64) as usize;
    let mut s = 7u32;
    for i in 0..n {
        let k = i % per;
        if k < 2400 {
            s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let noise = ((s >> 16) as i32 - 32_768) as f32 / 32_768.0;
            let v = (noise * (-(k as f32) / 300.0).exp() * 16_000.0) as i16;
            pcm[i * 2] = v;
            pcm[i * 2 + 1] = v;
        }
    }
    let mut src = e.new_source(Channels::Stereo, n as i64).unwrap();
    src.append(&pcm).unwrap();
    src.finish();
    let deck = e.deck(d);
    deck.set_source(0, &src);
    deck.set_gains(0, Gains::FULL, 0.0);
    deck.set_level(1.0, 0.0);
    let beats: Vec<f64> = (0..(seconds / SPB) as usize).map(|i| i as f64 * SPB).collect();
    deck.set_beats(&beats);
    src
}

/// Renders `seconds`: deck `d`'s output (or the master's, `d` None), interleaved.
fn render(e: &Engine, d: Option<usize>, seconds: f64) -> Vec<f32> {
    let n = (seconds * R as f64 / BLOCK as f64).round() as usize;
    let (mut m, mut a) = (vec![0f32; BLOCK * 2], vec![0f32; BLOCK * 2]);
    let mut out = Vec::with_capacity(n * BLOCK * 2);
    for _ in 0..n {
        let mut outs: [Option<&mut [f32]>; 4] = [None, None, None, None];
        if let Some(d) = d {
            outs[d] = Some(&mut a);
        }
        e.render(&mut m, &mut outs).unwrap();
        out.extend_from_slice(if d.is_some() { &a } else { &m });
    }
    out
}

/// `seconds` of deck `d` from `at`, started from rest (each take the same way: a seek
/// on a playing deck crossfades, and would move the clicks).
fn take(e: &Engine, d: DeckId, at: f64, seconds: f64) -> Vec<f32> {
    let deck = e.deck(d);
    deck.play(false);
    render(e, Some(d.index()), 0.02);
    deck.seek(at);
    deck.play(true);
    render(e, Some(d.index()), seconds)
}

fn rms(x: &[f32]) -> f32 {
    (x.iter().map(|v| (*v as f64).powi(2)).sum::<f64>() / x.len().max(1) as f64).sqrt() as f32
}

fn fx(kind: BeatFxKind, on: bool, level: f32, beats: f64, target: FxTarget) -> BeatFx {
    BeatFx { kind, on, level, beats, param: 0.5, target, tempo: DeckId::new(0).unwrap(), bpm: None }
}

#[test]
fn every_beat_fx_changes_the_sound_and_stays_finite() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let a = DeckId::new(0).unwrap();
    let _src = record(&e, a, 120.0);
    let deck = e.deck(a);
    deck.set_keylock(false);
    let mut at = 1.0;
    for kind in BeatFxKind::ALL {
        // the same stretch of the record dry, then with the effect
        let dry = take(&e, a, at, 2.0);
        let level = if kind == BeatFxKind::Pitch { 0.9 } else { 0.8 };
        deck.play(false);
        e.set_beat_fx(0, &fx(kind, true, level, kind.first_beats(), FxTarget::Deck(a)));
        let wet = take(&e, a, at, 2.0);
        e.set_beat_fx(0, &fx(kind, false, level, kind.first_beats(), FxTarget::Deck(a)));
        deck.play(false);
        render(&e, Some(0), 30.0); // the tails rung out (a SPIRAL turned up rings long)
        let again = take(&e, a, at, 2.0);
        deck.play(false);
        assert!(wet.iter().all(|v| v.is_finite() && v.abs() <= 1.0), "{}: a sample out of range", kind.name());
        // (the first half second left out: an effect's own start)
        let skip = (R as usize / 2) * 2;
        let diff: Vec<f32> = dry[skip..].iter().zip(&wet[skip..]).map(|(x, y)| x - y).collect();
        let changed = rms(&diff) / rms(&dry[skip..]).max(1e-6);
        assert!(changed > 0.05, "{} leaves the sound as it was ({changed:.3})", kind.name());
        // and off, rung out: the record as it was
        let diff: Vec<f32> = dry.iter().zip(&again).map(|(x, y)| x - y).collect();
        assert!(rms(&diff) < 0.01 * rms(&dry), "{} off is not the record again ({})", kind.name(), rms(&diff) / rms(&dry));
        at += 6.0;
    }
}

#[test]
fn a_one_beat_delay_lands_a_beat_later_and_an_echo_rings_on() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let a = DeckId::new(0).unwrap();
    let _src = record(&e, a, 30.0);
    let deck = e.deck(a);
    deck.set_keylock(false);
    deck.seek(4.0);
    deck.play(true);
    render(&e, Some(0), 0.2);
    e.set_beat_fx(0, &fx(BeatFxKind::Delay, true, 1.0, 1.0, FxTarget::Deck(a)));
    render(&e, Some(0), 1.8);
    // the record stops on a beat's click: what comes a beat later is the delay's
    deck.play(false);
    let after = render(&e, Some(0), 1.0);
    let env: Vec<f32> = after.chunks(2).map(|c| c[0].abs()).collect();
    let loud = env.iter().cloned().fold(0f32, f32::max);
    assert!(loud > 0.01, "the delay heard after the record stopped: {loud}");

    // an echo turned off and the deck stopped: it rings on, then dies away
    e.set_beat_fx(0, &fx(BeatFxKind::Echo, true, 0.9, 0.5, FxTarget::Deck(a)));
    deck.play(true);
    render(&e, Some(0), 2.0);
    e.set_beat_fx(0, &fx(BeatFxKind::Echo, false, 0.9, 0.5, FxTarget::Deck(a)));
    deck.play(false);
    let ring = render(&e, Some(0), 1.0);
    assert!(rms(&ring) > 0.002, "the echo rings on: {}", rms(&ring));
    render(&e, Some(0), 8.0);
    let gone = render(&e, Some(0), 0.5);
    assert!(rms(&gone) < 0.0005, "and dies away: {}", rms(&gone));
}

#[test]
fn the_delay_keeps_the_beat() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let a = DeckId::new(0).unwrap();
    // one click only, at 1 s, on a grid of 0.5 s beats
    let n = 6 * R as usize;
    let mut pcm = vec![0i16; n * 2];
    for k in 0..480 {
        let v = (12_000.0 * (-(k as f32) / 60.0).exp()) as i16;
        pcm[(R as usize + k) * 2] = v;
        pcm[(R as usize + k) * 2 + 1] = v;
    }
    let mut src = e.new_source(Channels::Stereo, n as i64).unwrap();
    src.append(&pcm).unwrap();
    src.finish();
    let deck = e.deck(a);
    deck.set_source(0, &src);
    deck.set_gains(0, Gains::FULL, 0.0);
    deck.set_level(1.0, 0.0);
    deck.set_beats(&(0..12).map(|i| i as f64 * SPB).collect::<Vec<_>>());
    deck.set_keylock(false);
    // (half way: the original whole and the delay whole; all the way, the delay alone)
    e.set_beat_fx(0, &fx(BeatFxKind::Delay, true, 0.5, 1.0, FxTarget::Deck(a)));
    deck.seek(0.0);
    deck.play(true);
    let out = render(&e, Some(0), 3.0);
    let env: Vec<f32> = out.chunks(2).map(|c| c[0].abs()).collect();
    let click = env.iter().position(|v| *v > 0.02).expect("the click");
    let later = env[click + 2400..].iter().position(|v| *v > 0.01).expect("its repeat") + click + 2400;
    let gap = (later - click) as f64 / R as f64;
    assert!((gap - SPB).abs() < 0.003, "a beat later: {gap:.4} s");
    let _ = src;
}

#[test]
fn color_fx_at_the_middle_is_the_record_and_each_way_is_not() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let a = DeckId::new(0).unwrap();
    let _src = record(&e, a, 200.0);
    let deck = e.deck(a);
    deck.set_keylock(false);
    let mut at = 1.0;
    for kind in ColorFxKind::ALL.into_iter().filter(|k| *k != ColorFxKind::Filter) {
        deck.set_color_fx(kind, 0.0, 0.5);
        let dry = take(&e, a, at, 1.0);
        for knob in [-0.8f32, 0.8] {
            deck.set_color_fx(kind, knob, 0.5);
            let wet = take(&e, a, at, 1.0);
            assert!(wet.iter().all(|v| v.is_finite()), "{}: not finite", kind.name());
            let skip = 9600;
            let diff: Vec<f32> = dry[skip..].iter().zip(&wet[skip..]).map(|(x, y)| x - y).collect();
            assert!(rms(&diff) / rms(&dry[skip..]) > 0.05, "{} at {knob} does nothing", kind.name());
        }
        // back to the middle: rung out, then the record as it is
        deck.set_color_fx(kind, 0.0, 0.5);
        deck.play(false);
        render(&e, Some(0), 10.0);
        let back = take(&e, a, at, 1.0);
        let diff: Vec<f32> = dry.iter().zip(&back).map(|(x, y)| x - y).collect();
        assert!(rms(&diff) < 0.01 * rms(&dry), "{} at the middle is not the record ({} of {})", kind.name(), rms(&diff), rms(&dry));
        deck.play(false);
        at += 16.0;
    }
}

#[test]
fn a_release_echo_holds_the_last_beat_and_a_master_unit_works() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let a = DeckId::new(0).unwrap();
    let _src = record(&e, a, 30.0);
    let deck = e.deck(a);
    deck.set_keylock(false);
    deck.seek(2.0);
    deck.play(true);
    e.set_beat_fx(0, &fx(BeatFxKind::Echo, false, 0.5, 1.0, FxTarget::Deck(a)));
    render(&e, Some(0), 2.0);
    // held: the record goes, the last beat repeats; the deck stopped meanwhile, still heard
    e.release_fx(0, ReleaseFxKind::Echo, true, 1.0);
    render(&e, Some(0), 0.05);
    deck.play(false);
    let held = render(&e, Some(0), 1.0);
    assert!(rms(&held) > 0.002, "the release echo rings: {}", rms(&held));
    e.release_fx(0, ReleaseFxKind::Echo, false, 1.0);
    render(&e, Some(0), 8.0);

    // a unit on the master: its ECHO is heard on the master
    let dry = take(&e, a, 4.0, 1.0);
    deck.play(false);
    e.set_beat_fx(1, &fx(BeatFxKind::Echo, true, 1.0, 0.25, FxTarget::Master));
    deck.seek(4.0);
    deck.play(true);
    let wet = render(&e, None, 1.0);
    e.set_beat_fx(1, &fx(BeatFxKind::Echo, false, 1.0, 0.25, FxTarget::Master));
    let dry_master = {
        deck.play(false);
        render(&e, None, 10.0);
        deck.seek(4.0);
        deck.play(true);
        render(&e, None, 1.0)
    };
    let _ = dry;
    assert!(rms(&wet) > rms(&dry_master) * 1.1, "the master's echo: {} vs {}", rms(&wet), rms(&dry_master));
}


/// One click at 1 s on a grid of 0.5 s beats (8 s long), on deck A, parked at 0.
fn one_click(e: &Engine) -> Source {
    let a = DeckId::new(0).unwrap();
    let n = 8 * R as usize;
    let mut pcm = vec![0i16; n * 2];
    for k in 0..480 {
        let v = (12_000.0 * (-(k as f32) / 60.0).exp()) as i16;
        pcm[(R as usize + k) * 2] = v;
        pcm[(R as usize + k) * 2 + 1] = v;
    }
    let mut src = e.new_source(Channels::Stereo, n as i64).unwrap();
    src.append(&pcm).unwrap();
    src.finish();
    let deck = e.deck(a);
    deck.set_source(0, &src);
    deck.set_gains(0, Gains::FULL, 0.0);
    deck.set_level(1.0, 0.0);
    deck.set_beats(&(0..16).map(|i| i as f64 * SPB).collect::<Vec<_>>());
    deck.set_keylock(false);
    src
}

/// The loudest sample (left) in each 50 ms window from `from` s for `n` windows.
fn windows(x: &[f32], from: f64, n: usize) -> Vec<f32> {
    let w = (0.05 * R as f64) as usize;
    (0..n).map(|i| x.chunks(2).skip((from * R as f64) as usize + i * w).take(w).map(|c| c[0].abs()).fold(0f32, f32::max)).collect()
}

/// The DJM-900NXS2's rules for its effects, as its manual has them.
#[test]
fn pioneer_s_rules() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let a = DeckId::new(0).unwrap();
    let _src = one_click(&e);
    let deck = e.deck(a);
    let run = |kind: BeatFxKind, level: f32, beats: f64, secs: f64| -> Vec<f32> {
        e.set_beat_fx(0, &fx(kind, true, level, beats, FxTarget::Deck(a)));
        let x = take(&e, a, 0.0, secs);
        e.set_beat_fx(0, &fx(kind, false, level, beats, FxTarget::Deck(a)));
        deck.play(false);
        render(&e, Some(0), 20.0);
        x
    };
    // DELAY all the way: the delay alone (the original off), a beat later
    let x = run(BeatFxKind::Delay, 1.0, 1.0, 2.5);
    let w = windows(&x, 0.95, 14);
    assert!(w[1] < 0.01, "DELAY at full: no original: {w:?}");
    assert!(w[11] > 0.05, "its repeat a beat on: {w:?}");
    // ECHO: each repeat about 4.4 dB under the one before
    let x = run(BeatFxKind::Echo, 0.5, 1.0, 4.0);
    let peaks: Vec<f32> = (1..=4).map(|k| windows(&x, 1.0 + k as f64 * SPB - 0.02, 1)[0]).collect();
    for p in peaks.windows(2) {
        let db = 20.0 * (p[1] / p[0]).log10();
        assert!((-5.5..-3.5).contains(&db), "ECHO's repeats fall {db:.1} dB: {peaks:?}");
    }
    // PITCH and VINYL BRAKE at LEVEL/DEPTH none: the record as it is
    for kind in [BeatFxKind::Pitch, BeatFxKind::VinylBrake] {
        let dry = run(BeatFxKind::Echo, 0.0, 1.0, 2.0);
        let x = run(kind, 0.0, kind.first_beats(), 2.0);
        let d: Vec<f32> = dry.iter().zip(&x).map(|(a, b)| a - b).collect();
        assert!(rms(&d) < 0.02 * rms(&dry), "{} at none changes the record ({})", kind.name(), rms(&d) / rms(&dry));
    }
    // REVERB: more of it (its BEAT buttons, %), a longer tail
    let short = run(BeatFxKind::Reverb, 0.6, 10.0, 3.0);
    let long = run(BeatFxKind::Reverb, 0.6, 100.0, 3.0);
    let tail = |x: &[f32]| rms(&x[(2 * R as usize) * 2..(3 * R as usize) * 2]);
    assert!(tail(&long) > 3.0 * tail(&short), "REVERB 100 % rings longer than 10 %: {} vs {}", tail(&long), tail(&short));
}

#[test]
fn noise_filters_the_noise_not_the_record() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let a = DeckId::new(0).unwrap();
    let _src = record(&e, a, 30.0);
    let deck = e.deck(a);
    deck.set_keylock(false);
    let dry = take(&e, a, 2.0, 1.0);
    // the knob all the way left: the noise's low pass shut, the record's clicks as they were
    deck.set_color_fx(ColorFxKind::Noise, -1.0, 0.0);
    render(&e, Some(0), 0.3);
    let x = take(&e, a, 2.0, 1.0);
    let d: Vec<f32> = dry.iter().zip(&x).map(|(a, b)| a - b).collect();
    assert!(rms(&d) < 0.1 * rms(&dry), "NOISE left filters the record: {}", rms(&d) / rms(&dry));
}
