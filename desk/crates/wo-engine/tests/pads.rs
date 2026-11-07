//! The board's pads on the engine, offline: a pad sounds from the moment it was asked for,
//! to the frame; round and round when it loops; at its gain; from its in to its out; two
//! at once; let go over a fade; and the board's level over them all.
use std::sync::Mutex;

use wo_engine::{Channels, Engine, Output, Source};

const R: u32 = 48_000;
/// The master's limiter looks 3 ms ahead: everything (the decks too) comes out this late.
const LATE: f64 = 145.0 / R as f64;
static TURN: Mutex<()> = Mutex::new(());

/// `seconds` of silence with a blip of `amp` at each of `at` (seconds).
fn blips(e: &Engine, seconds: f64, at: &[f64], amp: f32) -> Source {
    let n = (seconds * R as f64) as usize;
    let mut pcm = vec![0i16; n * 2];
    for &t in at {
        let k = (t * R as f64).round() as usize;
        for j in 0..48usize.min(n.saturating_sub(k)) {
            let v = (amp * 32_767.0) as i16;
            pcm[(k + j) * 2] = v;
            pcm[(k + j) * 2 + 1] = v;
        }
    }
    let mut s = e.new_source(Channels::Stereo, n as i64).unwrap();
    s.append(&pcm).unwrap();
    s.finish();
    s
}

/// The master, `seconds` of it, `before` called ahead of each block with the time.
fn render(e: &Engine, seconds: f64, mut before: impl FnMut(f64)) -> Vec<f32> {
    const BLOCK: usize = 480;
    let mut out = vec![];
    let mut m = vec![0f32; BLOCK * 2];
    while out.len() < (seconds * R as f64) as usize * 2 {
        before(out.len() as f64 / 2.0 / R as f64);
        e.render(&mut m, &mut [None, None, None, None]).unwrap();
        out.extend_from_slice(&m);
    }
    out
}

/// Where the blips start: the frames, seconds, where the left channel rises over half of
/// `amp` after quiet.
fn onsets(x: &[f32], amp: f32) -> Vec<f64> {
    let mut v = vec![];
    let mut quiet = true;
    for i in 0..x.len() / 2 {
        let a = x[i * 2].abs();
        if quiet && a > amp * 0.5 {
            v.push(i as f64 / R as f64);
            quiet = false;
        } else if a < 1e-4 {
            quiet = true;
        }
    }
    v
}

fn peak(x: &[f32]) -> f32 {
    x.iter().fold(0f32, |m, v| m.max(v.abs()))
}

#[test]
fn a_pad_sounds_from_its_moment_loops_and_lets_go() {
    let _t = TURN.lock().unwrap_or_else(|p| p.into_inner());
    let e = Engine::start(Some(R), Output::Offline).unwrap();
    let one = blips(&e, 0.2, &[0.0], 0.4);
    // asked for at 0.5 s (a beat ahead): it starts there, to the frame
    let mut asked = false;
    let out = render(&e, 1.0, |t| {
        if !asked {
            e.pad_play(0, &one, t + 0.5, 0.0, 0.0, false, 1.0);
            asked = true;
        }
    });
    let o = onsets(&out, 0.4);
    assert_eq!(o.len(), 1, "once: {o:?}");
    assert!((o[0] - LATE - 0.5).abs() < 1.5 / R as f64, "on its moment: {}", o[0]);
    assert!((peak(&out) - 0.4).abs() < 0.01, "as it is");
    assert_eq!(e.pad_at(0), None, "done");

    // looping a tenth of a second round; at half its gain
    let tenth = blips(&e, 0.1, &[0.0], 0.4);
    let mut asked = false;
    let out = render(&e, 0.55, |t| {
        if !asked {
            e.pad_play(1, &tenth, t, 0.0, 0.0, true, 0.5);
            asked = true;
        }
    });
    let o = onsets(&out, 0.2);
    assert_eq!(o.len(), 6, "round and round: {o:?}");
    for w in o.windows(2) {
        assert!((w[1] - w[0] - 0.1).abs() < 1.5 / R as f64, "a tenth apart: {o:?}");
    }
    assert!((peak(&out) - 0.2).abs() < 0.01, "at half");
    assert!(e.pad_at(1).is_some(), "still going");
    // let go over 50 ms: quiet after it
    e.pad_stop(1, 0.05);
    let out = render(&e, 0.3, |_| {});
    assert!(peak(&out[(0.06 * R as f64) as usize * 2..]) < 1e-4, "gone after its fade");
    assert_eq!(e.pad_at(1), None);

    // from its in to its out: only the blip between them; two at once add up
    let three = blips(&e, 0.3, &[0.0, 0.1, 0.2], 0.2);
    let mut asked = false;
    let out = render(&e, 0.4, |t| {
        if !asked {
            e.pad_play(2, &three, t, 0.05, 0.15, false, 1.0);
            e.pad_play(3, &three, t, 0.05, 0.15, false, 1.0);
            asked = true;
        }
    });
    let o = onsets(&out, 0.4);
    assert_eq!(o.len(), 1, "the middle blip alone: {o:?}");
    assert!((o[0] - LATE - 0.05).abs() < 2.0 / R as f64, "{o:?}");
    assert!((peak(&out) - 0.4).abs() < 0.01, "two at once add up: {}", peak(&out));

    // the board's level over them all
    e.pads_level(0.25, 0.0);
    let mut asked = false;
    let out = render(&e, 0.3, |t| {
        if !asked {
            e.pad_play(0, &one, t, 0.0, 0.0, false, 1.0);
            asked = true;
        }
    });
    assert!((peak(&out) - 0.1).abs() < 0.01, "a quarter: {}", peak(&out));
}
