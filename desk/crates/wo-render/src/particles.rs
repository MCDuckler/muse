//! Particles over a scene (v1: the native stage's particles.h, the Flutter stage's
//! show_particles.dart): a few hundred soft points of light, moved on the CPU and drawn in one
//! instanced call, added to the scene's light before the trails and the bloom — so they leave
//! trails and glow like everything else.
//!
//! Four kinds: sparks burst from the middle on the kick and fall away; dust drifts up slowly
//! and twinkles; rise climbs faster as a build rises; rain falls with the top end. In the
//! working picture's pixels, y from the top.
use std::f64::consts::PI;

/// What the particles listen to this frame.
#[derive(Clone, Copy, Debug, Default)]
pub struct Inputs {
    pub kick: f64,
    pub energy: f64,
    pub build: f64,
    pub drop_near: f64,
    pub high: f64,
    pub primary: [f32; 3],
    pub accent: [f32; 3],
    pub time: f64,
}

#[derive(Clone, Copy, Debug, Default)]
struct P {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    life: f64,
    age: f64,
    size: f64,
    seed: f64,
}

/// At most this many of a kind.
const MOST: usize = 600;

pub struct Particles {
    kind: String,
    rng: u64,
    ps: Vec<P>,
    kick_was: f64,
    debt: f64,
}

impl Particles {
    pub fn new(kind: &str) -> Particles {
        Particles { kind: kind.into(), rng: 11, ps: vec![], kick_was: 0.0, debt: 0.0 }
    }

    pub fn kind(&self) -> &str {
        &self.kind
    }

    pub fn len(&self) -> usize {
        self.ps.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ps.is_empty()
    }

    /// 0..1 (SplitMix64).
    fn u(&mut self) -> f64 {
        self.rng = self.rng.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.rng;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        ((z ^ (z >> 31)) >> 11) as f64 / (1u64 << 53) as f64
    }

    /// `dt` seconds on, in a picture `w`×`h` pixels.
    pub fn step(&mut self, i: &Inputs, dt: f64, w: f64, h: f64) {
        let dt = if dt <= 0.0 || dt > 0.25 { 1.0 / 60.0 } else { dt };
        let (kick, energy) = (i.kick, i.energy);
        match self.kind.as_str() {
            "sparks" => {
                if kick > 0.45 && kick > self.kick_was + 0.2 {
                    let n = (14.0 + 50.0 * kick * (0.5 + 0.5 * energy)).round() as usize;
                    for _ in 0..n {
                        if self.ps.len() >= MOST {
                            break;
                        }
                        let a = self.u() * PI * 2.0;
                        let sp = (0.12 + 0.5 * self.u()) * h * (0.6 + kick);
                        let x = w / 2.0 + (self.u() - 0.5) * h * 0.04;
                        let y = h / 2.0 + (self.u() - 0.5) * h * 0.04;
                        let life = 0.5 + self.u() * 0.9;
                        let size = (0.5 + self.u()) * h * 0.012;
                        let seed = self.u();
                        self.ps.push(P { x, y, vx: a.cos() * sp, vy: a.sin() * sp, life, age: 0.0, size, seed });
                    }
                }
                self.kick_was = kick;
            }
            "dust" => {
                let want = 90 + (60.0 * energy).round() as i64;
                self.debt += (want - self.ps.len() as i64).clamp(0, 40) as f64 * dt * 2.0;
                while self.debt >= 1.0 && self.ps.len() < MOST {
                    self.debt -= 1.0;
                    let (x, y) = (self.u() * w, self.u() * h);
                    let vx = (self.u() - 0.5) * h * 0.02;
                    let vy = -(0.01 + 0.03 * self.u()) * h;
                    let life = 6.0 + self.u() * 8.0;
                    let size = (0.2 + 0.8 * self.u()) * h * 0.005;
                    let seed = self.u();
                    self.ps.push(P { x, y, vx, vy, life, age: 0.0, size, seed });
                }
            }
            "rise" => {
                let up = i.build.max(i.drop_near);
                self.debt += (10.0 + 160.0 * up * up) * dt;
                while self.debt >= 1.0 && self.ps.len() < MOST {
                    self.debt -= 1.0;
                    let x = self.u() * w;
                    let vy = -(0.25 + 0.9 * up + 0.5 * self.u()) * h;
                    let life = 1.2 + self.u();
                    let size = (0.3 + 0.5 * self.u()) * h * 0.008;
                    let seed = self.u();
                    self.ps.push(P { x, y: h + 10.0, vx: 0.0, vy, life, age: 0.0, size, seed });
                }
            }
            "rain" => {
                self.debt += (5.0 + 120.0 * i.high) * dt;
                while self.debt >= 1.0 && self.ps.len() < MOST {
                    self.debt -= 1.0;
                    let x = self.u() * w;
                    let vx = (self.u() - 0.5) * h * 0.05;
                    let vy = (0.4 + 0.6 * self.u()) * h;
                    let life = 1.5 + self.u();
                    let size = (0.2 + 0.3 * self.u()) * h * 0.006;
                    let seed = self.u();
                    self.ps.push(P { x, y: -10.0, vx, vy, life, age: 0.0, size, seed });
                }
            }
            _ => {}
        }
        let sparks = self.kind == "sparks";
        let dust = self.kind == "dust";
        for p in &mut self.ps {
            p.age += dt;
            if sparks {
                let k = 0.35f64.powf(dt);
                p.vx *= k;
                p.vy = p.vy * k + h * 0.25 * dt;
            } else if dust {
                p.vx += (p.age * 0.7 + p.seed * 9.0).sin() * h * 0.004 * dt;
            }
            p.x += p.vx * dt;
            p.y += p.vy * dt;
        }
        self.ps.retain(|p| p.age < p.life && p.y >= -40.0 && p.y <= h + 40.0 && p.x >= -40.0 && p.x <= w + 40.0);
    }

    /// Each particle as an instance: x, y (pixels from the top), radius, 0; r, g, b, a.
    pub fn instances(&self, i: &Inputs, out: &mut Vec<[f32; 8]>) {
        for p in &self.ps {
            let k = p.age / p.life;
            let mut size = p.size;
            let alpha = match self.kind.as_str() {
                "sparks" => {
                    size *= 1.0 + k * 0.5;
                    (1.0 - k) * (1.0 - k)
                }
                "dust" => (k * PI).sin() * (0.35 + 0.65 * (0.5 + 0.5 * (i.time * (1.0 + p.seed * 2.0) + p.seed * 20.0).sin())),
                "rise" => {
                    size *= 2.2;
                    (k * PI).sin()
                }
                _ => (k * PI).sin() * 0.8,
            };
            if alpha <= 0.01 {
                continue;
            }
            let s = p.seed as f32;
            let c = |n: usize| i.primary[n] + (i.accent[n] - i.primary[n]) * s;
            out.push([p.x as f32, p.y as f32, size as f32, 0.0, c(0), c(1), c(2), alpha.min(1.0) as f32]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sparks_burst_on_the_kick_and_fall_away() {
        let mut p = Particles::new("sparks");
        let quiet = Inputs { kick: 0.1, energy: 0.5, ..Default::default() };
        p.step(&quiet, 1.0 / 60.0, 640.0, 360.0);
        assert!(p.is_empty());
        let kick = Inputs { kick: 0.9, ..quiet };
        p.step(&kick, 1.0 / 60.0, 640.0, 360.0);
        assert!(p.len() > 20, "{}", p.len());
        // held, no new burst
        let n = p.len();
        p.step(&kick, 1.0 / 60.0, 640.0, 360.0);
        assert_eq!(p.len(), n);
        for _ in 0..200 {
            p.step(&quiet, 1.0 / 60.0, 640.0, 360.0);
        }
        assert!(p.is_empty(), "all gone after a few seconds");
    }

    #[test]
    fn dust_fills_in_and_rain_follows_the_top_end() {
        let mut d = Particles::new("dust");
        let i = Inputs { energy: 0.5, ..Default::default() };
        for _ in 0..240 {
            d.step(&i, 1.0 / 60.0, 640.0, 360.0);
        }
        assert!(d.len() > 60, "{}", d.len());
        let mut out = vec![];
        d.instances(&i, &mut out);
        assert!(!out.is_empty() && out.iter().all(|v| v[7] > 0.0 && v[7] <= 1.0));
        let (mut lo, mut hi) = (Particles::new("rain"), Particles::new("rain"));
        for _ in 0..60 {
            lo.step(&Inputs { high: 0.0, ..i }, 1.0 / 60.0, 640.0, 360.0);
            hi.step(&Inputs { high: 1.0, ..i }, 1.0 / 60.0, 640.0, 360.0);
        }
        assert!(hi.len() > 5 * lo.len().max(1), "{} vs {}", hi.len(), lo.len());
    }
}
