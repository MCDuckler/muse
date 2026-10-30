//! The engine's SYNC and loop numbers, measured through the Rust face the way
//! app/native/engine/test/engine_test.cpp measures them through the C one: click
//! tracks on two decks rendered offline, every click of the follower against the
//! nearest of the master. The bar is the same: within 0.5 ms.
use std::sync::Mutex;

use wo_engine::{DeckId, Engine, Gains, Output, Source};

const R: u32 = 48_000;

// One engine per process: the tests take turns.
static TURN: Mutex<()> = Mutex::new(());

struct Track {
    pcm: Vec<i16>,
    beats: Vec<f64>,
}

/// A noise bed with a click on every beat, louder on each bar's first.
fn clicks(bpm: f64, first: f64, seconds: f64, seed: u32) -> Track {
    let n = (seconds * R as f64) as usize;
    let mut pcm = vec![0i16; n * 2];
    let mut s = seed;
    for i in 0..n {
        s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        let v = (((s >> 16) as i32 - 32_768) / 64) as i16;
        pcm[i * 2] = v;
        pcm[i * 2 + 1] = v;
    }
    let spb = 60.0 / bpm;
    let mut beats = vec![];
    let mut b = first;
    while b < seconds - 0.2 {
        beats.push(b);
        let k = (b * R as f64).round() as usize;
        let amp = if beats.len() % 4 == 1 { 0.9f32 } else { 0.6 };
        for j in 0..240usize {
            if k + j >= n {
                break;
            }
            let x = amp * (-(j as f32) / 40.0).exp() * (j as f32 * 0.9).sin();
            let v = (x * 32_767.0).clamp(-32_767.0, 32_767.0) as i32;
            let mixed = (pcm[(k + j) * 2] as i32 + v).clamp(-32_767, 32_767) as i16;
            pcm[(k + j) * 2] = mixed;
            pcm[(k + j) * 2 + 1] = mixed;
        }
        b += spb;
    }
    Track { pcm, beats }
}

fn load(e: &Engine, d: DeckId, t: &Track) -> Source {
    let mut s = e.new_source(wo_engine::Channels::Stereo, (t.pcm.len() / 2) as i64).unwrap();
    s.append(&t.pcm).unwrap();
    s.finish();
    let deck = e.deck(d);
    deck.set_source(0, &s);
    deck.set_gains(0, Gains::FULL, 0.0);
    deck.set_beats(&t.beats);
    deck.set_bar_one(0);
    s
}

#[derive(Default)]
struct Run {
    a: Vec<f32>,
    b: Vec<f32>,
}

impl Run {
    fn seconds(&self) -> f64 {
        self.a.len() as f64 / 2.0 / R as f64
    }

    /// Renders `seconds` more; `at` runs before each block with the time so far.
    fn render(&mut self, e: &Engine, seconds: f64, mut at: impl FnMut(f64)) {
        const BLOCK: usize = 480;
        let n = (seconds * R as f64) as usize;
        let (mut m, mut a, mut b) = (vec![0f32; BLOCK * 2], vec![0f32; BLOCK * 2], vec![0f32; BLOCK * 2]);
        let mut done = 0;
        while done < n {
            at(self.seconds());
            e.render(&mut m, &mut [Some(&mut a), Some(&mut b), None, None]).unwrap();
            self.a.extend_from_slice(&a);
            self.b.extend_from_slice(&b);
            done += BLOCK;
        }
    }
}

/// Where the clicks are: the half-way rise of a 1 ms energy envelope. Seconds.
fn onsets(x: &[f32]) -> Vec<f64> {
    let n = x.len() / 2;
    let w = 48;
    let mut env = vec![0f64; n];
    let mut acc = 0f64;
    for i in 0..n {
        let v = x[i * 2] as f64;
        acc += v * v;
        if i >= w {
            let o = x[(i - w) * 2] as f64;
            acc -= o * o;
        }
        env[i] = acc / w as f64;
    }
    let floor = 0.0015;
    let mut out = vec![];
    let mut i = (0.05 * R as f64) as usize;
    while i < n {
        if env[i] > floor && env[i - 1] <= floor {
            let mut pk = i;
            for j in i..(i + 288).min(n) {
                if env[j] > env[pk] {
                    pk = j;
                }
            }
            let mut k = pk;
            while k > 0 && env[k] > env[pk] * 0.5 {
                k -= 1;
            }
            out.push((k as f64 - w as f64 / 2.0) / R as f64);
            i = pk + (0.1 * R as f64) as usize;
        }
        i += 1;
    }
    out
}

/// Each of b's clicks in [from, to] against the nearest of a's: errors in ms.
fn apart(a: &[f64], b: &[f64], from: f64, to: f64) -> Vec<f64> {
    b.iter()
        .filter(|&&t| t >= from && t <= to)
        .map(|&t| {
            let nearest = a.iter().map(|&x| x - t).min_by(|p, q| p.abs().total_cmp(&q.abs())).unwrap_or(1e9);
            -nearest * 1000.0
        })
        .collect()
}

fn worst(e: &[f64]) -> f64 {
    e.iter().fold(0.0, |w, x| w.max(x.abs()))
}

fn sync(keylock: bool, late: bool) {
    let _turn = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let (ta, tb) = (clicks(124.0, 0.37, 120.0, 1), clicks(128.0, 0.21, 120.0, 2));
    let (_sa, _sb) = (load(&e, DeckId::A, &ta), load(&e, DeckId::B, &tb));
    let (a, b) = (e.deck(DeckId::A), e.deck(DeckId::B));
    a.set_keylock(keylock);
    b.set_keylock(keylock);
    a.play(true);
    let mut run = Run::default();
    if late {
        b.seek(3.3); // well off the beat
        b.play(true);
        run.render(&e, 2.0, |_| {});
        b.sync(DeckId::A, 1, 0.0);
    } else {
        run.render(&e, 1.0, |_| {});
        b.seek(10.0);
        b.start_with(DeckId::A, 1, None, 0.0);
        b.sync(DeckId::A, 1, 0.0);
    }
    let t0 = run.seconds();
    run.render(&e, 40.0, |t| {
        if t > t0 + 15.0 && t < t0 + 15.02 {
            a.set_rate(1.04); // the master's fader
        }
        if t > t0 + 27.0 && t < t0 + 27.02 {
            a.set_rate(0.97);
        }
    });
    let (ea, eb) = (onsets(&run.a), onsets(&run.b));
    let first = apart(&ea, &eb, t0 + 0.02, t0 + 0.6);
    let steady = apart(&ea, &eb, t0 + 0.6, t0 + 39.0);
    eprintln!(
        "sync keylock={keylock} late={late}: first worst {:.3} ms; {} clicks, worst {:.3} ms",
        worst(&first),
        steady.len(),
        worst(&steady)
    );
    assert!(!first.is_empty() && worst(&first) < 0.5, "first beats {:.3} ms apart", worst(&first));
    assert!(steady.len() > 60, "only {} clicks found", steady.len());
    assert!(worst(&steady) < 0.5, "held {:.3} ms apart at worst", worst(&steady));
    assert!(b.read().synced);
}

#[test]
fn sync_started_in_step() {
    sync(false, false);
}

#[test]
fn sync_started_in_step_keylocked() {
    sync(true, false);
}

#[test]
fn sync_pressed_with_both_playing() {
    sync(false, true);
}

#[test]
fn sync_pressed_with_both_playing_keylocked() {
    sync(true, true);
}

#[test]
fn a_beat_loop_wraps_on_the_grid() {
    let _turn = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let t = clicks(124.0, 0.37, 60.0, 3);
    let _s = load(&e, DeckId::A, &t);
    let a = e.deck(DeckId::A);
    a.seek(10.0);
    a.play(true);
    let mut run = Run::default();
    run.render(&e, 0.5, |_| {});
    a.loop_beats(4.0, false);
    run.render(&e, 12.0, |_| {});
    let st = a.read();
    let (la, lb) = st.looped.expect("looping");
    let period = 4.0 * 60.0 / 124.0;
    assert!(((lb - la) - period).abs() < 1e-6, "a 4-beat loop is {:.6} s, not {period:.6}", lb - la);
    // Every click while looping lands one beat apart: the wrap leaves no seam in the grid.
    let on: Vec<f64> = onsets(&run.a).into_iter().filter(|&x| x > 1.0).collect();
    let spb = 60.0 / 124.0;
    let worst_gap = on.windows(2).map(|w| ((w[1] - w[0]) - spb).abs() * 1000.0).fold(0.0, f64::max);
    eprintln!("loop: {} clicks, worst gap error {worst_gap:.3} ms, {} wraps", on.len(), st.moves);
    assert!(on.len() > 20);
    assert!(worst_gap < 0.5, "a click {worst_gap:.3} ms off the beat across the wrap");
}

#[test]
fn a_second_engine_waits_for_the_first() {
    let _turn = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    assert_eq!(Engine::start(Some(R), Output::Offline).unwrap_err(), wo_engine::Error::AlreadyRunning);
    let again = e.clone();
    drop(e);
    assert_eq!(Engine::start(Some(R), Output::Offline).unwrap_err(), wo_engine::Error::AlreadyRunning);
    drop(again);
    let fresh = Engine::start(Some(R), Output::Offline).unwrap();
    assert!(fresh.is_offline());
}

#[test]
fn rendering_needs_an_offline_engine_and_whole_buffers() {
    let _turn = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let mut m = vec![0f32; 3];
    assert!(matches!(e.render(&mut m, &mut [None, None, None, None]), Err(wo_engine::Error::Shape(_))));
    let mut s = e.new_source(wo_engine::Channels::Stereo, 10).unwrap();
    assert!(matches!(s.append(&[1, 2, 3]), Err(wo_engine::Error::Shape(_))));
    s.append(&[1, 2, 3, 4]).unwrap();
    assert_eq!(s.frames(), 2);
}
