//! A record's waveform the way rekordbox keeps it: one column every 1/150 s with three
//! band heights (its 3Band waveform), a colour and a height (RGB), and a height and a
//! whiteness (BLUE).
//!
//! A record off a rekordbox stick brings rekordbox's own columns ([`Wave::set_exact`]),
//! drawn as they are. Any other record's are made from the Desk's own columns as it
//! decodes, on curves fitted to rekordbox's own (rb_fit.rs, made by data/make_rb_fit.py
//! from a real stick: 75 records, 2.4 million columns, each record's audio decoded as
//! rekordbox decodes it beside rekordbox's columns for it). rekordbox's heights follow
//! the absolute level (no record is scaled to its own loudest); each band is the Desk's
//! band's peak held with a release (lows 0.95 a column, mids 0.92, highs 0.88: the tails
//! rekordbox's waveforms have), through its fitted curve; RGB's and BLUE's heights the
//! whole signal's peak through theirs. Off by 4.5, 6.0 and 4.2 of 127 on the bands and
//! 1.2 and 0.65 of 31 on the heights, on average. The colour is looked up from the bands
//! in a table measured on the same stick (`data/rb_colour.lut`).
use crate::{Col, Wave, decode};

/// One column, in rekordbox's own units.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RbCol {
    /// Lows, mids, highs: 0–127.
    pub bands: [u8; 3],
    /// Red, green, blue: 0–7.
    pub rgb: [u8; 3],
    /// The RGB waveform's height: 0–31.
    pub height: u8,
    /// The BLUE waveform's height (0–31) and whiteness (0–7).
    pub blue: u8,
    pub white: u8,
}

impl RbCol {
    /// A stick's column from its three waveforms (PWV3, PWV5, PWV7), any of them missing.
    pub fn from_stick(blue: Option<u8>, rgb: Option<u16>, bands: Option<[u8; 3]>) -> RbCol {
        let mut c = RbCol::default();
        if let Some(b) = blue {
            c.blue = b & 31;
            c.white = b >> 5;
        }
        if let Some(v) = rgb {
            c.rgb = [(v >> 13) as u8 & 7, (v >> 10) as u8 & 7, (v >> 7) as u8 & 7];
            c.height = (v >> 2) as u8 & 31;
        }
        match bands {
            Some(b) => c.bands = b.map(|x| x.min(127)),
            // no three-band waveform (an older rekordbox): the colour one's height in the
            // lows, so a 3Band picture still has a shape
            None => c.bands = [c.height.max(c.blue) * 4, 0, 0],
        }
        if blue.is_none() {
            c.blue = c.height;
            c.white = colour_of(c.bands)[3] / 32;
        }
        if rgb.is_none() {
            c.height = c.blue;
            let l = colour_of(c.bands);
            c.rgb = [l[0] / 32, l[1] / 32, l[2] / 32];
        }
        c
    }
}

/// Columns drawn as one: each 0..1 of its own full scale.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RbBin {
    pub bands: [f32; 3],
    pub rgb: [f32; 3],
    pub height: f32,
    pub blue: f32,
    pub white: f32,
}

/// How columns are folded into a bin: the loudest of them (a scrolling waveform: a
/// transient stays as tall however far out it is zoomed), or their mean (an overview,
/// as rekordbox's own previews are made).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fold {
    Max,
    Mean,
}

static LUT: &[u8; 16 * 16 * 16 * 4] = include_bytes!("../data/rb_colour.lut");

/// The colour rekordbox gives a column with these bands: red, green, blue, whiteness,
/// each its 0–7 value ×32.
pub fn colour_of(bands: [u8; 3]) -> [u8; 4] {
    let q = |b: u8| (b as usize * 16 / 128).min(15);
    let i = (q(bands[0]) * 256 + q(bands[1]) * 16 + q(bands[2])) * 4;
    [LUT[i], LUT[i + 1], LUT[i + 2], LUT[i + 3]]
}

/// A fitted curve: a level (linear), held with `release` a column, its log placed between
/// `lo` and `hi` on 64 steps, read off `at` (rekordbox's own units).
pub(crate) struct Curve {
    pub release: f32,
    pub lo: f32,
    pub hi: f32,
    pub at: [u8; 64],
}

impl Curve {
    pub(crate) fn of(&self, x: f32) -> u8 {
        let pos = ((x.max(1e-5).ln() - self.lo) / (self.hi - self.lo) * 64.0 - 0.5).clamp(0.0, 63.0);
        let i = pos.floor() as usize;
        let j = (i + 1).min(63);
        let f = pos - i as f32;
        (self.at[i] as f32 * (1.0 - f) + self.at[j] as f32 * f).round() as u8
    }
}

/// Where a made record's bands are held (their releases run on from column to column).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) struct Held([f32; 3]);

/// A column of the Desk's own made into rekordbox's, `held` carried from the one before.
pub(crate) fn emulate(c: &Col, held: &mut Held) -> RbCol {
    let curves = [&fit::LOW, &fit::MID, &fit::HIGH];
    let mut bands = [0u8; 3];
    for k in 0..3 {
        held.0[k] = decode(c.peak[k]).max(held.0[k] * curves[k].release);
        bands[k] = curves[k].of(held.0[k]).min(127);
    }
    let all = decode(c.all);
    let l = colour_of(bands);
    RbCol { bands, rgb: [l[0] / 32, l[1] / 32, l[2] / 32], height: fit::HEIGHT.of(all).min(31), blue: fit::BLUE.of(all).min(31), white: l[3] / 32 }
}

#[path = "rb_fit.rs"]
mod fit;

impl Wave {
    /// rekordbox's own columns for the record (off its stick): drawn from now on in place
    /// of the made ones, the whole record at once.
    pub fn set_exact(&mut self, cols: Vec<RbCol>) {
        self.exact = cols;
    }

    /// The record's columns are rekordbox's own.
    pub fn is_exact(&self) -> bool {
        !self.exact.is_empty()
    }

    /// How many rekordbox columns there are (all of them, for a stick's record; else as
    /// many as have decoded).
    pub fn rb_len(&self) -> usize {
        if self.is_exact() { self.exact.len() } else { self.cols.len() }
    }

    /// The made columns brought up to date: those decoded since.
    fn refresh(&mut self) {
        if self.is_exact() {
            return;
        }
        let mut held = self.made_held;
        let from = self.made.len();
        let more: Vec<RbCol> = self.cols[from..].iter().map(|c| emulate(c, &mut held)).collect();
        self.made.extend(more);
        self.made_held = held;
    }

    /// Column `i` as rekordbox's (after [`Wave::refresh`]).
    pub fn rb_col(&self, i: usize) -> Option<RbCol> {
        if self.is_exact() { self.exact.get(i).copied() } else { self.made.get(i).copied() }
    }

    /// Columns [i0, i1) folded into one bin; None where none of them is there.
    fn rb_bin(&self, i0: i64, i1: i64, fold: Fold) -> Option<RbBin> {
        let (a, b) = (i0.max(0), i1.min(self.rb_len() as i64));
        if b <= a {
            return None;
        }
        let (mut bands, mut rgb, mut height, mut blue, mut white) = ([0f32; 3], [0f32; 3], 0f32, 0f32, 0f32);
        let mut best = -1i32;
        let mut weight = 0f32;
        for i in a..b {
            let c = self.rb_col(i as usize)?;
            match fold {
                Fold::Max => {
                    for k in 0..3 {
                        bands[k] = bands[k].max(c.bands[k] as f32);
                    }
                    height = height.max(c.height as f32);
                    blue = blue.max(c.blue as f32);
                    // the colour of the tallest column
                    if c.height as i32 > best {
                        best = c.height as i32;
                        rgb = c.rgb.map(|v| v as f32);
                        white = c.white as f32;
                    }
                }
                Fold::Mean => {
                    for k in 0..3 {
                        bands[k] += c.bands[k] as f32;
                    }
                    height += c.height as f32;
                    blue += c.blue as f32;
                    // colour weighted by height: the loud columns colour a bin
                    let w = c.height as f32 + 1.0;
                    for k in 0..3 {
                        rgb[k] += c.rgb[k] as f32 * w;
                    }
                    white += c.white as f32 * w;
                    weight += w;
                }
            }
        }
        if fold == Fold::Mean {
            let n = (b - a) as f32;
            bands = bands.map(|v| v / n);
            height /= n;
            blue /= n;
            rgb = rgb.map(|v| v / weight);
            white /= weight;
        }
        Some(RbBin { bands: bands.map(|v| v / 127.0), rgb: rgb.map(|v| v / 7.0), height: height / 31.0, blue: blue / 31.0, white: white / 7.0 })
    }

    /// `n` bins of `k` columns each from column `first`, fixed to the record's own
    /// columns (as [`Wave::bins`]).
    pub fn rb_bins(&mut self, first: i64, k: usize, n: usize) -> Vec<Option<RbBin>> {
        self.refresh();
        let k = k.max(1) as i64;
        (0..n as i64).map(|i| self.rb_bin(first + i * k, first + (i + 1) * k, Fold::Max)).collect()
    }

    /// The whole of `length` seconds in `n` bins, each the mean of its columns.
    pub fn rb_overview(&mut self, length: f64, n: usize) -> Vec<Option<RbBin>> {
        self.refresh();
        let cols = (length * crate::RATE).max(1.0);
        (0..n)
            .map(|i| {
                let a = (i as f64 * cols / n as f64).floor() as i64;
                let b = (((i + 1) as f64 * cols / n as f64).floor() as i64).max(a + 1);
                self.rb_bin(a, b, Fold::Mean)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Analyser;

    fn tone(hz: f32, seconds: f32, level: f32) -> Vec<i16> {
        let n = (48_000.0 * seconds) as usize;
        (0..n)
            .flat_map(|i| {
                let v = ((i as f32 * hz * 2.0 * std::f32::consts::PI / 48_000.0).sin() * 32_000.0 * level) as i16;
                [v, v]
            })
            .collect()
    }

    #[test]
    fn a_sticks_column_reads_as_rekordbox_wrote_it() {
        // blue: height 31, whiteness 1; colour: red 7, green 0, blue 0, height 31
        let c = RbCol::from_stick(Some(0x3f), Some(0xe07c), Some([90, 40, 9]));
        assert_eq!(c, RbCol { bands: [90, 40, 9], rgb: [7, 0, 0], height: 31, blue: 31, white: 1 });
        // no three bands (an older rekordbox): the height stands in for the lows
        assert_eq!(RbCol::from_stick(Some(0x0a), Some(0x0028), None).bands[0], 40);
    }

    /// The table: a column loud in the lows reads red, one loud in the highs whiter and
    /// bluer than one loud in the lows.
    #[test]
    fn the_colours_follow_the_bands() {
        let lows = colour_of([110, 20, 5]);
        let highs = colour_of([20, 30, 110]);
        assert!(lows[0] > lows[2], "lows red: {lows:?}");
        assert!(highs[2] > lows[2] && highs[3] > lows[3], "highs bluer and whiter: {highs:?} vs {lows:?}");
    }

    /// A made record: a bass tone lands in the lows, a voice's in the mids, a hi-hat's in
    /// the highs, well up near full scale; what leaks into the other bands stays low; and
    /// as rekordbox's, the heights follow the level (a quieter tone, a lower picture).
    #[test]
    fn a_made_record_lands_in_its_bands() {
        for (hz, band) in [(60.0, 0), (800.0, 1), (8000.0, 2)] {
            let quiet = {
                let mut a = Analyser::new(48_000);
                a.feed(&tone(hz, 2.0, 0.3));
                a.finish();
                let w = a.wave();
                let mut w = w.lock().unwrap();
                w.refresh();
                w.rb_bin(60, 240, Fold::Mean).unwrap()
            };
            let mut a = Analyser::new(48_000);
            a.feed(&tone(hz, 2.0, 0.97));
            a.finish();
            let w = a.wave();
            let mut w = w.lock().unwrap();
            w.refresh();
            let b = w.rb_bin(60, 240, Fold::Mean).unwrap();
            let loudest = (0..3).max_by(|&i, &j| b.bands[i].total_cmp(&b.bands[j])).unwrap();
            assert_eq!(loudest, band, "{hz} Hz: {b:?}");
            assert!(b.bands[band] * 127.0 > 40.0, "{hz} Hz well up: {b:?}");
            assert!((0..3).filter(|&k| k != band).all(|k| b.bands[k] < 0.5 * b.bands[band]), "{hz} Hz leaks: {b:?}");
            assert!(b.height > 0.6, "{hz} Hz near full scale stands tall: {b:?}");
            assert!(quiet.height < b.height && quiet.bands[band] < b.bands[band], "{hz} Hz quieter, lower: {quiet:?} vs {b:?}");
        }
    }

    /// rekordbox's columns, once set, are the picture: the whole record, decoded or not.
    #[test]
    fn exact_columns_win() {
        let mut a = Analyser::new(48_000);
        a.feed(&tone(60.0, 1.0, 0.5));
        let w = a.wave();
        let mut w = w.lock().unwrap();
        assert!(!w.is_exact());
        w.set_exact(vec![RbCol { bands: [127, 0, 0], height: 31, ..Default::default() }; 600]);
        assert_eq!(w.rb_len(), 600);
        let bins = w.rb_bins(0, 4, 150);
        assert!(bins.iter().all(|b| b.is_some_and(|b| b.bands[0] == 1.0)));
        assert_eq!(w.rb_overview(4.0, 10).len(), 10);
        assert!(w.rb_bins(-8, 4, 2).iter().all(Option::is_none));
    }
}
