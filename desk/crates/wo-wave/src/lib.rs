//! A record's waveform in three bands — lows, mids, highs — made from its samples as
//! they decode (a [`Tee`] beside the engine's source), one column every 1/150 s.
//! Each column holds each band's peak, 0..255 on a gentle curve so quiet parts still
//! show. The booth draws lows in the deck's colour, mids paler, highs white.
use std::sync::{Arc, Mutex};

/// Columns a second.
pub const RATE: f64 = 150.0;

#[derive(Clone, Debug, Default)]
pub struct Wave {
    /// [low, mid, high] per column.
    pub cols: Vec<[u8; 3]>,
    pub done: bool,
}

impl Wave {
    pub fn seconds(&self) -> f64 {
        self.cols.len() as f64 / RATE
    }

    /// The bands' peaks over source time [a, b), 0..1 each.
    pub fn span(&self, a: f64, b: f64) -> [f32; 3] {
        let n = self.cols.len() as i64;
        let (i0, i1) = ((a * RATE).floor() as i64, ((b * RATE).ceil() as i64).max((a * RATE).floor() as i64 + 1));
        let mut m = [0u8; 3];
        for i in i0.max(0)..i1.min(n) {
            let c = self.cols[i as usize];
            for k in 0..3 {
                m[k] = m[k].max(c[k]);
            }
        }
        [m[0] as f32 / 255.0, m[1] as f32 / 255.0, m[2] as f32 / 255.0]
    }
}

/// One biquad, direct form I.
#[derive(Clone, Copy, Default)]
struct Biquad {
    b: [f32; 3],
    a: [f32; 2],
    x: [f32; 2],
    y: [f32; 2],
}

impl Biquad {
    fn new(low_pass: bool, hz: f32, rate: f32) -> Self {
        let w = 2.0 * std::f32::consts::PI * hz / rate;
        let (s, c) = w.sin_cos();
        let alpha = s / (2.0 * std::f32::consts::FRAC_1_SQRT_2);
        let a0 = 1.0 + alpha;
        let b = if low_pass {
            [(1.0 - c) / 2.0, 1.0 - c, (1.0 - c) / 2.0]
        } else {
            [(1.0 + c) / 2.0, -(1.0 + c), (1.0 + c) / 2.0]
        };
        Biquad { b: [b[0] / a0, b[1] / a0, b[2] / a0], a: [-2.0 * c / a0, (1.0 - alpha) / a0], ..Default::default() }
    }

    fn run(&mut self, x: f32) -> f32 {
        let y = self.b[0] * x + self.b[1] * self.x[0] + self.b[2] * self.x[1] - self.a[0] * self.y[0] - self.a[1] * self.y[1];
        self.x = [x, self.x[0]];
        self.y = [y, self.y[0]];
        y
    }
}

/// Analyses stereo 16-bit frames at `rate` into a shared [`Wave`], columns appended as
/// they complete (a UI can draw the part that is in).
pub struct Analyser {
    wave: Arc<Mutex<Wave>>,
    per_col: usize,
    at: usize,
    peak: [f32; 3],
    low: Biquad,
    mid_hp: Biquad,
    mid_lp: Biquad,
    high: Biquad,
    batch: Vec<[u8; 3]>,
}

impl Analyser {
    pub fn new(rate: u32) -> Self {
        let r = rate as f32;
        Analyser {
            wave: Arc::new(Mutex::new(Wave::default())),
            per_col: (rate as f64 / RATE).round() as usize,
            at: 0,
            peak: [0.0; 3],
            low: Biquad::new(true, 200.0, r),
            mid_hp: Biquad::new(false, 200.0, r),
            mid_lp: Biquad::new(true, 2500.0, r),
            high: Biquad::new(false, 2500.0, r),
            batch: vec![],
        }
    }

    pub fn wave(&self) -> Arc<Mutex<Wave>> {
        self.wave.clone()
    }

    pub fn feed(&mut self, stereo: &[i16]) {
        for f in stereo.chunks_exact(2) {
            let x = (f[0] as f32 + f[1] as f32) * (0.5 / 32768.0);
            let b = [self.low.run(x), self.mid_lp.run(self.mid_hp.run(x)), self.high.run(x)];
            for k in 0..3 {
                self.peak[k] = self.peak[k].max(b[k].abs());
            }
            self.at += 1;
            if self.at == self.per_col {
                // Lows carry the most energy: each band scaled to read alike, then a soft curve.
                let gain = [1.15f32, 1.9, 3.2];
                let col = [0, 1, 2].map(|k| ((self.peak[k] * gain[k]).min(1.0).powf(0.7) * 255.0) as u8);
                self.batch.push(col);
                self.peak = [0.0; 3];
                self.at = 0;
            }
        }
        if self.batch.len() >= 150 {
            self.flush();
        }
    }

    pub fn finish(&mut self) {
        self.flush();
        self.wave.lock().unwrap().done = true;
    }

    fn flush(&mut self) {
        let mut w = self.wave.lock().unwrap();
        w.cols.append(&mut self.batch);
    }
}

/// Decoded frames to two places at once: the engine's source and a waveform.
pub struct Tee<'a, S: wo_decode::Sink> {
    pub sink: &'a mut S,
    pub analyser: &'a mut Analyser,
}

impl<S: wo_decode::Sink> wo_decode::Sink for Tee<'_, S> {
    fn take(&mut self, pcm: &[i16]) -> Result<(), wo_decode::Error> {
        self.analyser.feed(pcm);
        self.sink.take(pcm)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(hz: f32, seconds: f32) -> Vec<i16> {
        let n = (48_000.0 * seconds) as usize;
        (0..n).flat_map(|i| {
            let v = ((i as f32 * hz * 2.0 * std::f32::consts::PI / 48_000.0).sin() * 16_000.0) as i16;
            [v, v]
        }).collect()
    }

    #[test]
    fn a_tone_lands_in_its_band() {
        for (hz, band) in [(60.0, 0), (800.0, 1), (8000.0, 2)] {
            let mut a = Analyser::new(48_000);
            a.feed(&tone(hz, 1.0));
            a.finish();
            let w = a.wave();
            let w = w.lock().unwrap();
            assert_eq!(w.cols.len(), 150);
            let s = w.span(0.3, 0.9);
            let loudest = (0..3).max_by(|&i, &j| s[i].total_cmp(&s[j])).unwrap();
            assert_eq!(loudest, band, "{hz} Hz read as {s:?}");
        }
    }
}
