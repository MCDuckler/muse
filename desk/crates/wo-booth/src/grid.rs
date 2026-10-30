//! A record's beat grid: the times of its beats (source seconds, ascending) and which
//! of them is a bar's first.
use std::sync::Arc;

#[derive(Clone, Debug, Default)]
pub struct Grid {
    pub beats: Arc<Vec<f64>>,
    pub bar_one: usize,
}

impl Grid {
    pub fn new(beats: Vec<f64>, bar_one: usize) -> Self {
        Grid { beats: Arc::new(beats), bar_one }
    }

    pub fn is_empty(&self) -> bool {
        self.beats.len() < 2
    }

    /// Seconds a beat, of the record (its average over the grid).
    pub fn spb(&self) -> Option<f64> {
        let b = &self.beats;
        (b.len() > 1).then(|| (b[b.len() - 1] - b[0]) / (b.len() - 1) as f64)
    }

    /// Whether beat `i` starts a bar.
    pub fn is_bar(&self, i: usize) -> bool {
        (i + 4 - self.bar_one % 4).is_multiple_of(4)
    }

    /// The first beat at or after `t` that starts a group of `every` (1: any beat, 4: a bar).
    pub fn next_beat(&self, t: f64, every: usize) -> Option<f64> {
        let first = self.beats.partition_point(|&b| b < t - 1e-9);
        (first..self.beats.len()).find(|&i| every <= 1 || (i + every * 4 - self.bar_one % every).is_multiple_of(every)).map(|i| self.beats[i])
    }

    /// The beat nearest `t`.
    pub fn nearest(&self, t: f64) -> Option<f64> {
        let i = self.beats.partition_point(|&b| b < t);
        [i.checked_sub(1), Some(i)].into_iter().flatten().filter_map(|i| self.beats.get(i).copied()).min_by(|a, b| (a - t).abs().total_cmp(&(b - t).abs()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grid() -> Grid {
        // 120 bpm from 0.25 s, the bar's one on beat 1.
        Grid::new((0..64).map(|i| 0.25 + i as f64 * 0.5).collect(), 1)
    }

    #[test]
    fn beats_and_bars() {
        let g = grid();
        assert!((g.spb().unwrap() - 0.5).abs() < 1e-12);
        assert!(g.is_bar(1) && g.is_bar(5) && !g.is_bar(0) && !g.is_bar(2));
        assert_eq!(g.next_beat(1.0, 1), Some(1.25));
        assert_eq!(g.next_beat(1.0, 4), Some(2.75), "the bar's one after 1.0 s is beat 5");
        assert_eq!(g.next_beat(0.75, 4), Some(0.75), "at a bar's one, that one");
        assert_eq!(g.nearest(1.6), Some(1.75));
    }
}
