//! A record's integrated loudness, as ITU-R BS.1770-4 / EBU R128 measure it (the same
//! number ffmpeg's ebur128 and the house give): K-weighted, 400 ms blocks overlapping by
//! 75 %, gated at −70 LUFS and then 10 LU under the blocks' own loudness.

/// A biquad in direct form I, f64 (a record's worth of K-weighting without drift).
#[derive(Clone, Copy)]
struct Stage {
    b: [f64; 3],
    a: [f64; 2],
    x: [f64; 2],
    y: [f64; 2],
}

impl Stage {
    fn run(&mut self, x: f64) -> f64 {
        let y = self.b[0] * x + self.b[1] * self.x[0] + self.b[2] * self.x[1] - self.a[0] * self.y[0] - self.a[1] * self.y[1];
        self.x = [x, self.x[0]];
        self.y = [y, self.y[0]];
        y
    }
}

/// The K-weighting's two stages at `rate` (libebur128's design: the standard's 48 kHz
/// coefficients exactly, and the same curve at any other rate).
fn k_weighting(rate: f64) -> [Stage; 2] {
    use std::f64::consts::PI;
    // the head's shelf
    let (f0, g, q) = (1681.974450955533, 3.999843853973347, 0.7071752369554196);
    let k = (PI * f0 / rate).tan();
    let vh = 10f64.powf(g / 20.0);
    let vb = vh.powf(0.4996667741545416);
    let a0 = 1.0 + k / q + k * k;
    let shelf = Stage {
        b: [(vh + vb * k / q + k * k) / a0, 2.0 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    // the high pass (RLB)
    let (f0, q) = (38.13547087602444, 0.5003270373238773);
    let k = (PI * f0 / rate).tan();
    let a0 = 1.0 + k / q + k * k;
    let high = Stage { b: [1.0, -2.0, 1.0], a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0], x: [0.0; 2], y: [0.0; 2] };
    [shelf, high]
}

/// Fed stereo 16-bit frames as they decode; [`Meter::integrated`] once they are all in.
pub struct Meter {
    k: [[Stage; 2]; 2],
    /// Frames to a 100 ms step, and those of the step under way.
    step: usize,
    at: usize,
    /// The step's sum of squares, both channels.
    sum: f64,
    /// Each finished step's mean square (both channels summed, as the standard's L + R).
    steps: Vec<f64>,
    peak: f32,
}

impl Meter {
    pub fn new(rate: u32) -> Self {
        let k = k_weighting(rate as f64);
        Meter { k: [k, k], step: (rate as usize / 10).max(1), at: 0, sum: 0.0, steps: Vec::with_capacity(4096), peak: 0.0 }
    }

    pub fn feed(&mut self, stereo: &[i16]) {
        for f in stereo.as_chunks::<2>().0 {
            let mut e = 0.0;
            for c in 0..2 {
                let x = f[c] as f64 / 32768.0;
                self.peak = self.peak.max(x.abs() as f32);
                let s = self.k[c][0].run(x);
                let y = self.k[c][1].run(s);
                e += y * y;
            }
            self.sum += e;
            self.at += 1;
            if self.at == self.step {
                self.steps.push(self.sum / self.step as f64);
                self.sum = 0.0;
                self.at = 0;
            }
        }
    }

    /// Its loudness, LUFS: None for silence (or under 400 ms of sound).
    pub fn integrated(&self) -> Option<f32> {
        let blocks: Vec<f64> = self.steps.windows(4).map(|w| w.iter().sum::<f64>() / 4.0).collect();
        let lufs = |z: f64| -0.691 + 10.0 * z.log10();
        let mean = |zs: &mut dyn Iterator<Item = f64>| {
            let (s, n) = zs.fold((0.0, 0usize), |(s, n), z| (s + z, n + 1));
            (n > 0).then(|| s / n as f64)
        };
        let loud: Vec<f64> = blocks.into_iter().filter(|&z| z > 0.0 && lufs(z) > -70.0).collect();
        let gate = lufs(mean(&mut loud.iter().copied())?) - 10.0;
        let z = mean(&mut loud.iter().copied().filter(|&z| lufs(z) > gate))?;
        Some(lufs(z) as f32)
    }

    /// The highest sample, 0..1 (full scale).
    pub fn peak(&self) -> f32 {
        self.peak
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(hz: f64, dbfs: f64, seconds: f64, rate: u32) -> Vec<i16> {
        let a = 10f64.powf(dbfs / 20.0) * 32767.0;
        (0..(rate as f64 * seconds) as usize)
            .flat_map(|i| {
                let v = (a * (i as f64 * hz * 2.0 * std::f64::consts::PI / rate as f64).sin()).round() as i16;
                [v, v]
            })
            .collect()
    }

    fn measure(pcm: &[i16], rate: u32) -> Option<f32> {
        let mut m = Meter::new(rate);
        for c in pcm.chunks(4096) {
            m.feed(c);
        }
        m.integrated()
    }

    #[test]
    fn the_standards_48k_coefficients() {
        let [s, h] = k_weighting(48_000.0);
        let near = |a: f64, b: f64| (a - b).abs() < 1e-9;
        assert!(near(s.b[0], 1.53512485958697) && near(s.b[1], -2.69169618940638) && near(s.b[2], 1.19839281085285));
        assert!(near(s.a[0], -1.69065929318241) && near(s.a[1], 0.73248077421585));
        assert!(near(h.a[0], -1.99004745483398) && near(h.a[1], 0.99007225036621));
    }

    #[test]
    fn a_1k_sine_on_both_channels_is_its_level_in_lufs() {
        // EBU Tech 3341: 1 kHz at −23 dBFS on both channels reads −23 LUFS (±0.1)
        for rate in [44_100, 48_000] {
            let l = measure(&sine(1000.0, -23.0, 20.0, rate), rate).unwrap();
            assert!((l + 23.0).abs() < 0.1, "{rate}: {l}");
        }
        let l = measure(&sine(1000.0, -10.0, 10.0, 48_000), 48_000).unwrap();
        assert!((l + 10.0).abs() < 0.1, "{l}");
    }

    #[test]
    fn quiet_passages_are_gated_out() {
        // EBU Tech 3341 case 3-ish: −36 dBFS, −23 dBFS, −36 dBFS: the quiet parts fall under
        // the relative gate, the record reads −23
        let mut pcm = sine(1000.0, -36.0, 10.0, 48_000);
        pcm.extend(sine(1000.0, -23.0, 60.0, 48_000));
        pcm.extend(sine(1000.0, -36.0, 10.0, 48_000));
        let l = measure(&pcm, 48_000).unwrap();
        assert!((l + 23.0).abs() < 0.1, "{l}");
        // silence counts for nothing
        let mut pcm = vec![0i16; 48_000 * 2 * 30];
        pcm.extend(sine(1000.0, -20.0, 10.0, 48_000));
        let l = measure(&pcm, 48_000).unwrap();
        assert!((l + 20.0).abs() < 0.1, "{l}");
        assert_eq!(measure(&vec![0i16; 48_000 * 2 * 5], 48_000), None);
    }

    #[test]
    fn the_k_weighting_lifts_the_highs_and_drops_the_lows() {
        let hi = measure(&sine(8000.0, -20.0, 5.0, 48_000), 48_000).unwrap();
        let lo = measure(&sine(30.0, -20.0, 5.0, 48_000), 48_000).unwrap();
        assert!(hi > -20.0 + 3.0, "{hi}");
        assert!(lo < -20.0 - 1.0, "{lo}");
    }
}
