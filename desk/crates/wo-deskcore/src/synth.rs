//! A made-up techno record: kick, offbeat hats, a rolling bass, claps in the drops,
//! in sections (intro 16 bars, build 16, drop 32, break 16, drop 32, outro 16), on an
//! exact grid. For computers without the app's fetched records — and for public CI,
//! where no one's music may go.
const RATE: f64 = 48_000.0;
const BARS: usize = 128;

pub fn seconds(bpm: f64) -> f64 {
    BARS as f64 * 4.0 * 60.0 / bpm
}

/// Stereo 16-bit at 48 kHz, and its beat times.
pub fn render(bpm: f64, seed: u32) -> (Vec<i16>, Vec<f64>) {
    let spb = 60.0 / bpm;
    let n = (seconds(bpm) * RATE) as usize;
    let mut out = vec![0i16; n * 2];
    let mut s = seed.wrapping_mul(2_654_435_761);
    let mut noise = move || {
        s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        (s >> 8) as f32 / 8_388_608.0 - 1.0
    };
    let root = [49.0f32, 55.0, 46.25, 41.2][(seed as usize) % 4];
    let (mut lp, mut hp_prev, mut hp) = (0.0f32, 0.0f32, 0.0f32);
    for i in 0..n {
        let t = i as f64 / RATE;
        let beat = t / spb;
        let bar = (beat / 4.0) as usize;
        let ph = (beat.fract()) as f32;
        let sixteenth = ((beat * 4.0).fract()) as f32;
        let section = match bar {
            0..=15 => 0,   // intro
            16..=31 => 1,  // build
            32..=63 => 2,  // drop
            64..=79 => 3,  // break
            80..=111 => 2, // drop
            _ => 4,        // outro
        };
        let kick_on = section != 3;
        let pt = ph as f64 * spb;
        let kick = if kick_on {
            let f = 45.0 + 75.0 * (-pt * 30.0).exp();
            ((2.0 * std::f64::consts::PI * f * pt).sin() * (-pt * 9.0).exp()) as f32 * 0.9
        } else {
            0.0
        };
        let hat_t = ((ph - 0.5).rem_euclid(1.0)) as f64 * spb;
        let hat_raw = noise();
        hp = 0.85 * (hp + hat_raw - hp_prev);
        hp_prev = hat_raw;
        let hat = if ph >= 0.5 { hp * (-hat_t * 60.0).exp() as f32 * 0.35 } else { 0.0 };
        let bass_on = matches!(section, 1..=3);
        let bass = if bass_on && sixteenth > 0.25 {
            let saw = ((t as f32 * root).fract() * 2.0 - 1.0) * (1.0 - (sixteenth - 0.25) * 1.2).max(0.0);
            lp += 0.06 * (saw - lp);
            lp * if section == 3 { 0.25 } else { 0.55 }
        } else {
            lp *= 0.995;
            lp * 0.55
        };
        let clap = if section == 2 && (beat as usize) % 2 == 1 { hp * (-pt * 25.0).exp() as f32 * 0.5 } else { 0.0 };
        let riser = if section == 1 { noise() * 0.12 * ((bar - 16) as f32 / 16.0) } else { 0.0 };
        let x = (kick + hat + bass + clap + riser).clamp(-1.0, 1.0);
        let v = (x * 26_000.0) as i16;
        out[i * 2] = v;
        out[i * 2 + 1] = v;
    }
    let beats = (0..BARS * 4).map(|b| b as f64 * spb).collect();
    (out, beats)
}

/// Where the first drop starts, seconds.
pub fn first_drop(bpm: f64) -> f64 {
    32.0 * 4.0 * 60.0 / bpm
}
