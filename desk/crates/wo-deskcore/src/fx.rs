//! The booth's own sounds (v1's fx_sounds.dart + fx_channel.dart): a riser under a
//! build, a noise sweep into a change and away from it, a wash of noise over one, a hit
//! on the one. Rendered here, sample by sample as v1 does (noise through state-variable
//! filters, a comb, a small room), and played on the engine's spare decks C and D — a
//! third voice off to the side of the crossfader, with no record, beat or tempo.
//!
//! A transition's sounds are rendered on a worker as soon as it is planned (a sixteen-bar
//! riser is a lot of arithmetic, and one that lands a beat late is worse than none), and
//! fired as their step is reached.
use std::f64::consts::PI;
use std::sync::mpsc;
use std::thread;

use wo_booth::steps::{FxShot, FxSound};
use wo_engine::{Channels, DeckId, Engine, Gains, Source};

const RATE: f64 = crate::RATE as f64;

/// Renders `sound`, `seconds` long over beats `beat` seconds long: interleaved stereo,
/// peaking at `peak`.
pub fn render(sound: FxSound, seconds: f64, beat: f64, peak: f32) -> Vec<f32> {
    let n = ((seconds * RATE).round() as usize).max(1);
    let mut out = vec![0f32; n * 2];
    match sound {
        FxSound::Riser => riser(&mut out, n, beat),
        FxSound::SweepUp => sweep(&mut out, n, true),
        FxSound::SweepDown => sweep(&mut out, n, false),
        FxSound::Hydrant => hydrant(&mut out, n, beat),
        FxSound::Impact => impact(&mut out, n),
    }
    edges(&mut out, n);
    normalise(&mut out, peak);
    out
}

fn noise(seed: u64, i: u64) -> f64 {
    let mut x = (seed.wrapping_mul(0x9E3779B1).wrapping_add(i.wrapping_mul(0x85EBCA77))) & 0xFFFF_FFFF;
    if x == 0 {
        x = 0x2545F491;
    }
    x ^= (x << 13) & 0xFFFF_FFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFF_FFFF;
    (x & 0xFF_FFFF) as f64 / 0x7F_FFFF as f64 - 1.0
}

#[derive(Default)]
struct Pink {
    b0: f64,
    b1: f64,
    b2: f64,
}

impl Pink {
    fn step(&mut self, w: f64) -> f64 {
        self.b0 = 0.99765 * self.b0 + w * 0.0990460;
        self.b1 = 0.96300 * self.b1 + w * 0.2965164;
        self.b2 = 0.57000 * self.b2 + w * 1.0526913;
        (self.b0 + self.b1 + self.b2 + w * 0.1848) * 0.28
    }
}

/// Andrew Simper's state-variable filter: low, band, high at once.
#[derive(Default)]
struct Svf {
    ic1: f64,
    ic2: f64,
    k: f64,
    a1: f64,
    a2: f64,
    a3: f64,
}

impl Svf {
    fn set(&mut self, hz: f64, q: f64) {
        let fc = hz.clamp(15.0, RATE * 0.45);
        let g = (PI * fc / RATE).tan();
        self.k = 1.0 / q.clamp(0.4, 24.0);
        self.a1 = 1.0 / (1.0 + g * (g + self.k));
        self.a2 = g * self.a1;
        self.a3 = g * self.a2;
    }
    fn step(&mut self, x: f64) -> (f64, f64, f64) {
        let v3 = x - self.ic2;
        let v1 = self.a1 * self.ic1 + self.a2 * v3;
        let v2 = self.ic2 + self.a2 * self.ic1 + self.a3 * v3;
        self.ic1 = 2.0 * v1 - self.ic1;
        self.ic2 = 2.0 * v2 - self.ic2;
        (v2, v1, x - self.k * v1 - v2)
    }
}

#[derive(Default)]
struct Band {
    a: Svf,
    b: Svf,
}

impl Band {
    fn set(&mut self, hz: f64, q: f64) {
        self.a.set(hz, q);
        self.b.set(hz, q);
    }
    fn step(&mut self, x: f64) -> f64 {
        let one = self.a.step(x).1;
        self.b.step(one).1
    }
}

struct Level {
    k: f64,
    sq: f64,
}

impl Level {
    fn new(tau: f64) -> Level {
        Level { k: 1.0 - (-1.0 / (tau * RATE)).exp(), sq: 0.0 }
    }
    fn flatten(&mut self, x: f64) -> f64 {
        self.sq += (x * x - self.sq) * self.k;
        x / (self.sq.sqrt() + 1e-4)
    }
}

struct Comb {
    buf: Vec<f64>,
    at: usize,
}

impl Comb {
    fn new(frames: usize) -> Comb {
        Comb { buf: vec![0.0; frames.max(4)], at: 0 }
    }
    fn step(&mut self, x: f64, delay: f64) -> f64 {
        let len = self.buf.len();
        self.buf[self.at] = x;
        let d = delay.clamp(1.0, len as f64 - 2.0);
        let back = self.at as f64 - d;
        let i = back.floor();
        let f = back - i;
        let idx = |j: f64| ((j as i64).rem_euclid(len as i64)) as usize;
        let (a, b) = (self.buf[idx(i)], self.buf[idx(i + 1.0)]);
        self.at = (self.at + 1) % len;
        a + (b - a) * f
    }
}

struct FeedbackComb {
    buf: Vec<f64>,
    fb: f64,
    at: usize,
    lp: f64,
}

impl FeedbackComb {
    fn step(&mut self, x: f64) -> f64 {
        let y = self.buf[self.at];
        self.lp += (y - self.lp) * 0.35;
        self.buf[self.at] = x + self.lp * self.fb;
        self.at = (self.at + 1) % self.buf.len();
        y
    }
}

struct Allpass {
    buf: Vec<f64>,
    g: f64,
    at: usize,
}

impl Allpass {
    fn step(&mut self, x: f64) -> f64 {
        let d = self.buf[self.at];
        let y = -self.g * x + d;
        self.buf[self.at] = x + self.g * d;
        self.at = (self.at + 1) % self.buf.len();
        y
    }
}

struct Room {
    combs: Vec<FeedbackComb>,
    ap: Allpass,
}

impl Room {
    fn new(rt60: f64, spread: f64) -> Room {
        let combs = [29.7, 37.1, 41.1]
            .iter()
            .map(|ms| {
                let frames = ((ms * spread * RATE / 1000.0).round() as usize).max(2);
                FeedbackComb { buf: vec![0.0; frames], fb: 0.001f64.powf(ms * spread / 1000.0 / rt60), at: 0, lp: 0.0 }
            })
            .collect();
        let ap = Allpass { buf: vec![0.0; ((5.0 * spread * RATE / 1000.0).round() as usize).max(2)], g: 0.7, at: 0 };
        Room { combs, ap }
    }
    fn step(&mut self, x: f64) -> f64 {
        let sum: f64 = self.combs.iter_mut().map(|c| c.step(x)).sum();
        self.ap.step(sum / 3.0)
    }
}

fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}
fn glide(a: f64, b: f64, t: f64) -> f64 {
    a * (b / a).powf(t.clamp(0.0, 1.0))
}
fn swell(db: f64, t: f64, curve: f64) -> f64 {
    10f64.powf(db * (1.0 - t.clamp(0.0, 1.0).powf(curve)) / 20.0)
}
fn soft(x: f64, drive: f64) -> f64 {
    (x * drive).tanh() / drive.tanh()
}

fn riser(out: &mut [f32], n: usize, beat: f64) {
    let mut band = [Band::default(), Band::default()];
    let mut scream = [Svf::default(), Svf::default()];
    let mut cut = [Svf::default(), Svf::default()];
    let mut pink = [Pink::default(), Pink::default()];
    let mut flat = [Level::new(0.4), Level::new(0.4)];
    let mut phase = [0f64; 3];
    let (mut sub_phase, mut roll, mut tick) = (0f64, 0f64, 0f64);
    let tick_fall = (-1.0 / (0.012 * RATE)).exp();
    for i in 0..n {
        let t = i as f64 / n as f64;
        let s = i as f64 / RATE;
        let fc = glide(190.0, 9500.0, t.powf(0.85));
        let q = lerp(0.8, 5.5, t);
        let period = glide(beat / 2.0, beat / 8.0, t.powf(1.4));
        let before = roll;
        roll += 1.0 / (period * RATE);
        if roll.floor() > before.floor() {
            tick = 1.0;
        }
        tick *= tick_fall;
        let depth = lerp(0.75, 0.15, t.powf(0.7));
        let gate = 1.0 - depth * (roll - roll.floor()).powf(0.55);
        let air = t.powf(1.5);
        let scream_amt = ((t - 0.66) / 0.34).clamp(0.0, 1.0);
        let k = ((t - 0.4) / 0.6).clamp(0.0, 1.0);
        let vibrato = 1.0 + 0.012 * k * (2.0 * PI * lerp(4.5, 7.0, k) * s).sin();
        let hz = glide(330.0, 2600.0, k.powf(1.3)) * vibrato;
        for (v, det) in [0.9954, 1.0, 1.0046].iter().enumerate() {
            phase[v] += hz * det / RATE;
        }
        sub_phase += hz / 2.0 / RATE;
        let lead_amp = 0.40 * k.powf(2.2);
        let sw = swell(-26.0, t, 1.15);
        for ch in 0..2 {
            let lr = if ch == 0 { 0.97 } else { 1.03 };
            band[ch].set(fc * lr, q);
            scream[ch].set(fc * 2.8 * if ch == 0 { 0.99 } else { 1.01 }, 14.0);
            cut[ch].set(fc * 0.45, 0.7);
            let white = noise(7 + ch as u64, i as u64);
            let src = pink[ch].step(white) * (1.0 - 0.8 * air) + white * (0.25 + 0.75 * air);
            let bp = band[ch].step(src);
            let sc = scream[ch].step(src).1;
            let hp = cut[ch].step(bp * 5.0 + sc * 2.5 * scream_amt).2;
            let noise_out = flat[ch].flatten(hp) * 0.22 * gate;
            let tick_out = noise(31 + ch as u64, i as u64) * tick * 0.16 * t.powf(1.4);
            let mut lead = 0.0;
            for (v, ph) in phase.iter().enumerate() {
                let p = 2.0 * PI * (ph + ch as f64 * 0.11 + v as f64 * 0.23);
                lead += p.sin() + 0.45 * (2.0 * p).sin() + 0.22 * (3.0 * p).sin() + 0.1 * (4.0 * p).sin();
            }
            lead = lead / 3.0 * lead_amp + (2.0 * PI * (sub_phase + ch as f64 * 0.05)).sin() * lead_amp * 0.35;
            out[i * 2 + ch] = (soft(noise_out + tick_out + lead, 1.7) * sw) as f32;
        }
    }
}

fn sweep(out: &mut [f32], n: usize, up: bool) {
    let mut band = [Band::default(), Band::default()];
    let mut cut = [Svf::default(), Svf::default()];
    let mut pink = [Pink::default(), Pink::default()];
    let mut flat = [Level::new(0.05), Level::new(0.05)];
    let mut room = (!up).then(|| [Room::new(0.55, 1.0), Room::new(0.55, 1.07)]);
    for i in 0..n {
        let t = i as f64 / n as f64;
        let fc = if up { glide(240.0, 8800.0, t.powf(0.8)) } else { glide(7000.0, 170.0, t.powf(0.55)) };
        let q = if up { lerp(1.1, 3.6, t) } else { lerp(3.0, 1.0, t) };
        let wobble = 2f64.powf(0.2 * (2.0 * PI * 1.7 * i as f64 / RATE).sin());
        let amp = if up { swell(-22.0, t, 1.3) } else { swell(-34.0, 1.0 - t, 1.1) };
        let air = if up { t.powf(1.2) } else { 1.0 - t.powf(0.8) };
        for ch in 0..2 {
            band[ch].set(fc * wobble * if ch == 0 { 0.96 } else { 1.04 }, q);
            cut[ch].set(fc * 0.4, 0.7);
            let white = noise(21 + ch as u64, i as u64);
            let src = pink[ch].step(white) * (1.0 - 0.7 * air) + white * (0.3 + 0.7 * air);
            let bp = band[ch].step(src);
            let hp = cut[ch].step(bp * 5.2).2;
            let mut y = soft(flat[ch].flatten(hp) * 0.22, 1.5) * amp;
            if let Some(r) = room.as_mut() {
                y += r[ch].step(y) * 0.35;
            }
            out[i * 2 + ch] = y as f32;
        }
    }
}

fn hydrant(out: &mut [f32], n: usize, beat: f64) {
    let mut band = [Band::default(), Band::default()];
    let mut cut = [Svf::default(), Svf::default()];
    let mut pink = [Pink::default(), Pink::default()];
    let mut comb = [Comb::new(RATE as usize / 100), Comb::new(RATE as usize / 100)];
    let mut room = [Room::new(0.4, 1.0), Room::new(0.4, 1.09)];
    let seconds = n as f64 / RATE;
    let mut spray_phase = 0.0;
    for i in 0..n {
        let t = i as f64 / n as f64;
        let s = i as f64 / RATE;
        let arch = (PI * t).sin();
        let base = glide(800.0, 5400.0, arch.max(0.0).powf(0.7));
        let wobble = (2.0 * PI * s / (beat * 2.0)).sin();
        let spray_hz = 11.0 + 3.0 * (2.0 * PI * 0.37 * s).sin() + 1.5 * noise(77, (i / 2048) as u64);
        spray_phase += spray_hz / RATE;
        let spray = 1.0 - 0.35 * (0.5 + 0.5 * (2.0 * PI * spray_phase).sin()) * (0.6 + 0.4 * arch);
        let amp = arch.max(0.0).powf(0.65);
        for ch in 0..2 {
            let side = if ch == 0 { 1.0 } else { -1.0 };
            band[ch].set(base * (1.0 + 0.38 * wobble * side), 4.5);
            cut[ch].set(300.0, 0.7);
            let white = noise(43 + ch as u64, i as u64);
            let src = pink[ch].step(white) * 0.55 + white * 0.6;
            let bp = band[ch].step(src);
            let hp = cut[ch].step(bp * 4.4).2;
            let ms = 3.5 + 2.5 * (2.0 * PI * s / seconds.max(0.8) + if ch == 0 { 0.0 } else { PI }).sin();
            let jet = (hp + comb[ch].step(hp, ms * RATE / 1000.0) * 0.8) * spray;
            let y = jet * 0.6;
            out[i * 2 + ch] = ((y + room[ch].step(y) * 0.3) * amp) as f32;
        }
    }
}

fn impact(out: &mut [f32], n: usize) {
    let mut high = [Svf::default(), Svf::default()];
    let mut low = [Svf::default(), Svf::default()];
    let mut room = [Room::new(0.6, 1.0), Room::new(0.6, 1.06)];
    let mut pink = [Pink::default(), Pink::default()];
    let mut sub = 0.0;
    for i in 0..n {
        let s = i as f64 / RATE;
        let hz = glide(150.0, 34.0, (s / 0.32).clamp(0.0, 1.0));
        sub += hz / RATE;
        let boom = soft((2.0 * PI * sub).sin(), 1.25) * (-s * 5.0).exp();
        let crash = (-s * 3.0).exp();
        let click = if s < 0.004 { 1.0 - s / 0.004 } else { 0.0 };
        for ch in 0..2 {
            high[ch].set(1600.0, 0.7);
            low[ch].set(9000.0, 0.7);
            let white = noise(91 + ch as u64, i as u64);
            let hp = high[ch].step(white * 0.7 + pink[ch].step(white) * 0.5).2;
            let lp = low[ch].step(hp).0;
            let dry = boom * 0.95 + lp * crash * 0.32 + white * click * 0.5;
            out[i * 2 + ch] = (dry + room[ch].step(lp * crash * 0.3 + boom * 0.2) * 0.4) as f32;
        }
    }
}

/// 3 ms ramps at each end: no click going on or off.
fn edges(out: &mut [f32], n: usize) {
    let ramp = (n / 2).min((RATE * 0.003).round() as usize);
    for i in 0..ramp {
        let g = i as f32 / ramp as f32;
        let j = n - 1 - i;
        for c in 0..2 {
            out[i * 2 + c] *= g;
            out[j * 2 + c] *= g;
        }
    }
}

fn normalise(out: &mut [f32], peak: f32) {
    let most = out.iter().fold(0f32, |m, v| m.max(v.abs()));
    if most > 1e-6 {
        let g = peak / most;
        out.iter_mut().for_each(|v| *v *= g);
    }
}

fn to_pcm(stereo: &[f32]) -> Vec<i16> {
    stereo.iter().map(|v| (v.clamp(-1.0, 1.0) * 32767.0).round() as i16).collect()
}

/// A sound rendered ahead of its step, by what it was rendered as.
struct Ready {
    shot: FxShot,
    seconds: f64,
    pcm: mpsc::Receiver<Vec<i16>>,
}

/// The booth's own voice: sounds rendered ahead for the planned move, and the engine's
/// decks C and D they play on, by turns (a sweep down starts as a sweep up ends).
#[derive(Default)]
pub(crate) struct Fx {
    ready: Vec<Ready>,
    playing: [Option<Source>; 2],
    turn: usize,
    /// Sounds fired, counted (the log, the tests).
    pub fired: u64,
}

impl Fx {
    /// Renders on a worker every sound a move will fire, so each is there when its step
    /// comes (`move_s`: the move's length heard; `beat`: a beat heard).
    pub fn prepare(&mut self, shots: &[FxShot], move_s: f64, beat: f64) {
        self.ready.clear();
        for shot in shots {
            let seconds = shot.seconds(move_s, beat);
            let (tx, rx) = mpsc::channel();
            let shot = *shot;
            thread::spawn(move || {
                let _ = tx.send(to_pcm(&render(shot.sound, seconds, beat, 0.9)));
            });
            self.ready.push(Ready { shot, seconds, pcm: rx });
        }
    }

    /// `shot`, `seconds` long over beats `beat` seconds long, played now: the one
    /// rendered ahead where there is one, else rendered here.
    pub fn fire(&mut self, engine: &Engine, shot: FxShot, seconds: f64, beat: f64) {
        let ahead = self.ready.iter().position(|r| r.shot == shot && (r.seconds - seconds).abs() < 0.25);
        let pcm = match ahead.map(|i| self.ready.remove(i)) {
            Some(r) => r.pcm.recv().unwrap_or_default(),
            None => to_pcm(&render(shot.sound, seconds, beat, 0.9)),
        };
        if pcm.is_empty() {
            return;
        }
        let Ok(mut source) = engine.new_source(Channels::Stereo, (pcm.len() / 2) as i64) else { return };
        if source.append(&pcm).is_err() {
            return;
        }
        source.finish();
        let deck = engine.deck(DeckId::new(2 + self.turn).unwrap());
        deck.play(false);
        deck.set_source(0, &source);
        deck.set_gains(0, Gains::FULL, 0.0);
        deck.set_level(10f32.powf(shot.gain_db / 20.0), 0.0);
        deck.seek(0.0);
        deck.play(true);
        self.playing[self.turn] = Some(source);
        self.turn = 1 - self.turn;
        self.fired += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_sound_renders_whole_and_in_bounds() {
        for sound in [FxSound::Riser, FxSound::SweepUp, FxSound::SweepDown, FxSound::Hydrant, FxSound::Impact] {
            let out = render(sound, 2.0, 0.47, 0.9);
            assert_eq!(out.len(), 2 * 96_000, "{sound:?}");
            let peak = out.iter().fold(0f32, |m, v| m.max(v.abs()));
            assert!((peak - 0.9).abs() < 1e-3, "{sound:?} peaks at {peak}");
            assert!(out.iter().all(|v| v.is_finite()), "{sound:?} finite");
            assert_eq!((out[0], out[1]), (0.0, 0.0), "{sound:?} starts from nothing");
        }
    }

    #[test]
    fn a_riser_climbs() {
        // louder at the end than the start (it swells), and brighter
        let out = render(FxSound::Riser, 4.0, 0.47, 0.9);
        let rms = |a: usize, b: usize| (out[a * 2..b * 2].iter().map(|v| v * v).sum::<f32>() / ((b - a) * 2) as f32).sqrt();
        let n = out.len() / 2;
        assert!(rms(n * 9 / 10, n - 200) > 3.0 * rms(0, n / 10), "it swells");
    }
}
