//! A record's waveform in three bands — lows, mids, highs — made from its samples as
//! they decode (a [`Tee`] beside the engine's source), one column every 1/150 s.
//! Each column holds each band's peak and its RMS, kept with headroom (nothing pegs at the
//! top); the record's own ceiling — the loudest it gets, near enough — is counted as it
//! decodes, and the booth draws every record against its own, so a loud master is not a
//! slab and a quiet one is not a line. The booth draws lows in the deck's colour, mids
//! paler, highs white; the RMS as the body, the peaks as its outline.
use std::sync::{Arc, Mutex};

/// Columns a second.
pub const RATE: f64 = 150.0;

/// The loudest a band is kept to (×1 is full scale after its band's gain): above it, it pegs.
const HEAD: f32 = 2.0;

/// Each band scaled to read alike (lows carry the most energy).
const GAIN: [f32; 3] = [1.15, 1.9, 3.2];

/// The curve a level is drawn on, over the record's ceiling: quiet parts still show.
const CURVE: f32 = 0.7;

/// A level, `x` linear (its band's gain applied), into a byte: square-root steps, so the
/// quiet end keeps its detail.
fn encode(x: f32) -> u8 {
    ((x / HEAD).clamp(0.0, 1.0).sqrt() * 255.0).round() as u8
}

/// A byte back to a linear level.
fn decode(q: u8) -> f32 {
    let v = q as f32 / 255.0;
    v * v * HEAD
}

/// One column: each band's peak and RMS.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Col {
    pub peak: [u8; 3],
    pub rms: [u8; 3],
}

/// Columns drawn as one: each band's peak and RMS, 0..1 against the record's ceiling, on
/// the drawing curve.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Bin {
    pub peak: [f32; 3],
    pub rms: [f32; 3],
}

#[derive(Clone, Debug)]
pub struct Wave {
    pub cols: Vec<Col>,
    pub done: bool,
    /// How many columns had each loudest-band peak byte: the ceiling's count.
    hist: [u32; 256],
}

impl Default for Wave {
    fn default() -> Self {
        Wave { cols: vec![], done: false, hist: [0; 256] }
    }
}

impl Wave {
    pub fn seconds(&self) -> f64 {
        self.cols.len() as f64 / RATE
    }

    fn push(&mut self, c: Col) {
        self.hist[*c.peak.iter().max().unwrap() as usize] += 1;
        self.cols.push(c);
    }

    /// The record's ceiling, linear: the level only its loudest 0.5 % of columns pass (a
    /// stray click does not set it), never under a quarter of full scale (a record still
    /// coming in, or a quiet one, is not blown up).
    pub fn ceiling(&self) -> f32 {
        let n: u32 = self.hist.iter().sum();
        if n == 0 {
            return 1.0;
        }
        let over = (n as f32 * 0.005).ceil() as u32;
        let mut seen = 0;
        for q in (0..256).rev() {
            seen += self.hist[q];
            if seen > over {
                return decode(q as u8).max(0.25);
            }
        }
        0.25
    }

    /// The bands' peaks over source time [a, b), 0..1 each, on the old curve (full scale
    /// at 1): how hard a stretch hits, for those that measure (the plan view's bars).
    pub fn span(&self, a: f64, b: f64) -> [f32; 3] {
        let n = self.cols.len() as i64;
        let (i0, i1) = ((a * RATE).floor() as i64, ((b * RATE).ceil() as i64).max((a * RATE).floor() as i64 + 1));
        let mut m = [0u8; 3];
        for i in i0.max(0)..i1.min(n) {
            let c = self.cols[i as usize];
            for k in 0..3 {
                m[k] = m[k].max(c.peak[k]);
            }
        }
        m.map(|q| decode(q).min(1.0).powf(CURVE))
    }

    /// Columns [i0, i1) as one bin, against `ceiling`; None where none of them is in (before
    /// the record, past its end, or not decoded yet).
    pub fn bin(&self, i0: i64, i1: i64, ceiling: f32) -> Option<Bin> {
        let (a, b) = (i0.max(0), i1.min(self.cols.len() as i64));
        if b <= a {
            return None;
        }
        let mut peak = [0u8; 3];
        let mut sq = [0.0f32; 3];
        for c in &self.cols[a as usize..b as usize] {
            for k in 0..3 {
                peak[k] = peak[k].max(c.peak[k]);
                let r = decode(c.rms[k]);
                sq[k] += r * r;
            }
        }
        let n = (b - a) as f32;
        let shape = |x: f32| (x / ceiling).clamp(0.0, 1.0).powf(CURVE);
        Some(Bin { peak: peak.map(|q| shape(decode(q))), rms: [0, 1, 2].map(|k| shape((sq[k] / n).sqrt())) })
    }

    /// `n` bins of `k` columns each, the first starting at column `first` (which may be
    /// before the record): fixed to the record's own columns, so a scrolling picture of
    /// them keeps its shape from frame to frame.
    pub fn bins(&self, first: i64, k: usize, n: usize) -> Vec<Option<Bin>> {
        let k = k.max(1) as i64;
        let ceiling = self.ceiling();
        (0..n as i64).map(|i| self.bin(first + i * k, first + (i + 1) * k, ceiling)).collect()
    }

    /// The whole of `length` seconds in `n` bins (an overview).
    pub fn overview(&self, length: f64, n: usize) -> Vec<Option<Bin>> {
        let ceiling = self.ceiling();
        let cols = (length * RATE).max(1.0);
        (0..n)
            .map(|i| {
                let a = (i as f64 * cols / n as f64).floor() as i64;
                let b = (((i + 1) as f64 * cols / n as f64).floor() as i64).max(a + 1);
                self.bin(a, b, ceiling)
            })
            .collect()
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
    sq: [f32; 3],
    low: Biquad,
    mid_hp: Biquad,
    mid_lp: Biquad,
    high: Biquad,
    batch: Vec<Col>,
}

impl Analyser {
    pub fn new(rate: u32) -> Self {
        let r = rate as f32;
        Analyser {
            wave: Arc::new(Mutex::new(Wave::default())),
            per_col: (rate as f64 / RATE).round() as usize,
            at: 0,
            peak: [0.0; 3],
            sq: [0.0; 3],
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
        for f in stereo.as_chunks::<2>().0 {
            let x = (f[0] as f32 + f[1] as f32) * (0.5 / 32768.0);
            let b = [self.low.run(x), self.mid_lp.run(self.mid_hp.run(x)), self.high.run(x)];
            for k in 0..3 {
                self.peak[k] = self.peak[k].max(b[k].abs());
                self.sq[k] += b[k] * b[k];
            }
            self.at += 1;
            if self.at == self.per_col {
                let n = self.per_col as f32;
                let col = Col { peak: [0, 1, 2].map(|k| encode(self.peak[k] * GAIN[k])), rms: [0, 1, 2].map(|k| encode((self.sq[k] / n).sqrt() * GAIN[k])) };
                self.batch.push(col);
                self.peak = [0.0; 3];
                self.sq = [0.0; 3];
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
        for c in self.batch.drain(..) {
            w.push(c);
        }
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

    fn tone_at(hz: f32, seconds: f32, level: f32) -> Vec<i16> {
        let n = (48_000.0 * seconds) as usize;
        (0..n).flat_map(|i| {
            let v = ((i as f32 * hz * 2.0 * std::f32::consts::PI / 48_000.0).sin() * 32_000.0 * level) as i16;
            [v, v]
        }).collect()
    }

    #[test]
    fn the_body_sits_inside_the_outline() {
        let mut a = Analyser::new(48_000);
        a.feed(&tone(60.0, 2.0));
        a.finish();
        let w = a.wave();
        let w = w.lock().unwrap();
        let b = w.bin(60, 240, w.ceiling()).unwrap();
        assert!(b.rms[0] < b.peak[0] && b.rms[0] > 0.6 * b.peak[0], "a sine's RMS under its peak: {b:?}");
    }

    /// A loud record is drawn against its own ceiling: its loud part fills the lane and its
    /// quiet part (a quarter as loud) still reads as quieter — nothing pegs.
    #[test]
    fn a_loud_record_is_not_a_slab() {
        let mut a = Analyser::new(48_000);
        a.feed(&tone_at(60.0, 2.0, 0.25));
        a.feed(&tone_at(60.0, 6.0, 1.0));
        a.finish();
        let w = a.wave();
        let w = w.lock().unwrap();
        let c = w.ceiling();
        let quiet = w.bin(60, 240, c).unwrap();
        let loud = w.bin(450, 900, c).unwrap();
        assert!(loud.peak[0] > 0.97, "the loud part fills: {loud:?}");
        assert!(quiet.peak[0] < 0.55, "the quiet part reads quieter: {quiet:?}");
    }

    /// Bins are fixed to the record's columns: the same columns, the same bin, wherever the
    /// picture starts.
    #[test]
    fn bins_keep_their_shape() {
        let mut a = Analyser::new(48_000);
        a.feed(&tone(800.0, 0.5));
        a.feed(&tone_at(60.0, 1.0, 0.6));
        a.finish();
        let w = a.wave();
        let w = w.lock().unwrap();
        let x = w.bins(40, 3, 30);
        let y = w.bins(43, 3, 30);
        assert_eq!(&x[1..], &y[..29]);
        assert!(w.bins(-9, 3, 4)[..3].iter().all(Option::is_none), "nothing before the record");
        assert_eq!(w.overview(w.seconds(), 10).len(), 10);
    }
}
