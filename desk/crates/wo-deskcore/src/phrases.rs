//! Phrases for a record rekordbox has none for (a stick exported without its phrase
//! analysis): found here, in rekordbox's words for dance music (its "high" mood: Intro, Up,
//! Down, Chorus, Outro), on rekordbox's own grid, eight bars a block.
//!
//! Each block is weighed by its lows (the kick and the bass: what a drop is made of) and
//! by all of it: a full block is a Chorus; a thin one an Intro before the first Chorus,
//! an Outro after the last, a Down between them; the thin block that leads into a Chorus,
//! louder than the one before it, an Up. Blocks of one kind in a row are one phrase.
use crate::marks::{Phrase, PhraseKind};

/// Bars a block.
const BLOCK_BARS: usize = 8;

/// `lows` and `all`: each column's level (any scale; 150 columns a second); `beats` the
/// grid (seconds) and `bar_one` its first bar's beat; `seconds` how long the record is.
pub fn detect(lows: &[f32], all: &[f32], beats: &[f64], bar_one: usize, seconds: f64) -> Vec<Phrase> {
    let per_block = BLOCK_BARS * 4;
    if beats.len() < bar_one + per_block * 2 || lows.is_empty() {
        return vec![];
    }
    // the blocks' bounds: from the grid's first bar, every eight bars, to the record's end
    let mut bounds: Vec<f64> = (bar_one..beats.len()).step_by(per_block).map(|i| beats[i]).collect();
    if seconds > bounds.last().copied().unwrap_or(0.0) + 1.0 {
        bounds.push(seconds);
    }
    let mean = |x: &[f32], a: f64, b: f64| {
        let (i, j) = (((a * wo_wave::RATE) as usize).min(x.len()), ((b * wo_wave::RATE) as usize).min(x.len()));
        if j <= i { 0.0 } else { x[i..j].iter().sum::<f32>() / (j - i) as f32 }
    };
    let blocks: Vec<(f64, f64, f32, f32)> = bounds.windows(2).map(|w| (w[0], w[1], mean(lows, w[0], w[1]), mean(all, w[0], w[1]))).collect();
    if blocks.len() < 2 {
        return vec![];
    }
    let q = |v: &mut Vec<f32>, k: f32| {
        v.sort_by(f32::total_cmp);
        v[((v.len() - 1) as f32 * k).round() as usize]
    };
    let mut l: Vec<f32> = blocks.iter().map(|b| b.2).collect();
    let (lo, hi) = (q(&mut l, 0.2), q(&mut l, 0.85));
    let mut t: Vec<f32> = blocks.iter().map(|b| b.3).collect();
    let t_hi = q(&mut t, 0.85);
    // full: its lows well up toward the record's fullest, and itself loud
    let full: Vec<bool> = if hi - lo < 0.08 * hi.max(1e-6) {
        // all of one weight (no drops to tell): the middle full, the ends thin
        (0..blocks.len()).map(|i| i > 0 && i + 1 < blocks.len()).collect()
    } else {
        blocks.iter().map(|b| b.2 >= lo + 0.55 * (hi - lo) && b.3 >= 0.6 * t_hi).collect()
    };
    let first = full.iter().position(|f| *f);
    let last = full.iter().rposition(|f| *f);
    let mut kinds: Vec<PhraseKind> = (0..blocks.len())
        .map(|i| match (first, last) {
            (Some(a), _) if i < a => PhraseKind::Intro,
            (_, Some(z)) if i > z => PhraseKind::Outro,
            _ if full[i] => PhraseKind::Chorus,
            _ => PhraseKind::Down,
        })
        .collect();
    // the thin block leading into a Chorus, louder than the one before it: an Up
    for i in 1..blocks.len().saturating_sub(1) {
        if kinds[i] == PhraseKind::Down && kinds[i + 1] == PhraseKind::Chorus && blocks[i].3 > blocks[i - 1].3 * 1.05 {
            kinds[i] = PhraseKind::Up;
        }
    }
    // a run of one kind is one phrase
    let mut out: Vec<Phrase> = vec![];
    for (i, b) in blocks.iter().enumerate() {
        match out.last_mut() {
            Some(p) if p.kind == kinds[i] => p.end = b.1,
            _ => out.push(Phrase { kind: kinds[i], label: kinds[i].word().to_owned(), start: b.0, end: b.1 }),
        }
    }
    // what comes before the grid's first bar is the intro's too
    if let Some(p) = out.first_mut() {
        p.start = 0.0;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A record of 8-bar blocks at 120 BPM with these levels (lows, all).
    fn record(levels: &[(f32, f32)]) -> (Vec<f32>, Vec<f32>, Vec<f64>, f64) {
        let block_s = 8.0 * 4.0 * 0.5;
        let cols = (levels.len() as f64 * block_s * wo_wave::RATE) as usize;
        let (mut lows, mut all) = (vec![0f32; cols], vec![0f32; cols]);
        for i in 0..cols {
            let b = ((i as f64 / wo_wave::RATE) / block_s) as usize;
            lows[i] = levels[b.min(levels.len() - 1)].0;
            all[i] = levels[b.min(levels.len() - 1)].1;
        }
        let beats = (0..levels.len() * 32).map(|i| i as f64 * 0.5).collect();
        (lows, all, beats, levels.len() as f64 * block_s)
    }

    #[test]
    fn a_techno_record_reads_as_rekordbox_would_name_it() {
        // intro thin, the drop full twice, a break between with a build into the second
        let (l, a, b, s) = record(&[(20.0, 60.0), (25.0, 70.0), (90.0, 150.0), (95.0, 160.0), (15.0, 60.0), (30.0, 100.0), (95.0, 160.0), (90.0, 150.0), (20.0, 60.0)]);
        let p = detect(&l, &a, &b, 0, s);
        let kinds: Vec<_> = p.iter().map(|p| p.kind).collect();
        assert_eq!(kinds, [PhraseKind::Intro, PhraseKind::Chorus, PhraseKind::Down, PhraseKind::Up, PhraseKind::Chorus, PhraseKind::Outro], "{p:?}");
        assert_eq!(p[0].start, 0.0);
        assert_eq!(p[1].start, 32.0, "the drop on its block's bar");
        assert!(p.windows(2).all(|w| w[0].end == w[1].start), "end to end: {p:?}");
    }

    #[test]
    fn too_short_or_gridless_has_none() {
        assert!(detect(&[1.0; 100], &[1.0; 100], &[0.0, 0.5], 0, 1.0).is_empty());
    }
}
