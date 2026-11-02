//! A small seeded random stream (SplitMix64): the genome and the director's picks go by it,
//! the same numbers for the same seed on every stage and every run. (v1 used Dart's
//! math.Random and String.hashCode, which cannot be reproduced bit for bit: a record keeps
//! its own look in v2, not the one it had in v1.)
#[derive(Clone, Debug)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed ^ 0x9E37_79B9_7F4A_7C15)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// 0..1.
    pub fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }

    /// 0..n.
    pub fn next_int(&mut self, n: usize) -> usize {
        (self.next_f64() * n as f64) as usize % n.max(1)
    }

    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.next_f64()
    }

    pub fn pick<T: Copy>(&mut self, of: &[T]) -> T {
        of[self.next_int(of.len())]
    }
}

/// A string's hash that is the same everywhere (FNV-1a).
pub fn hash_str(s: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}
