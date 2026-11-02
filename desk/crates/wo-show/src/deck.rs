//! One deck as the show sees it (v1: show_deck.dart's deriveDeck, show_state.dart's ShowDeck
//! and ShowAudio): where the record is on its own grid, what the analysis says of that bar,
//! what is heard of it. The record's facts are sent by the Desk once per load (its grid as the
//! Desk plays it, the four-bar markers, sections, drops, the bars' energy, key, voice), so the
//! stage never asks the house and both read a position the same way.
use std::collections::BTreeMap;

pub type Flat = BTreeMap<String, f64>;

/// The record's sound at the needle, 0..1 each.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ShowAudio {
    pub sub: f64,
    pub low: f64,
    pub mid: f64,
    pub high: f64,
    pub air: f64,
    pub kick: f64,
    pub snare: f64,
    pub hat: f64,
    pub onset: f64,
    pub drums: f64,
    pub rest: f64,
    pub vocals: f64,
}

impl ShowAudio {
    pub const SILENCE: ShowAudio = ShowAudio { sub: 0.0, low: 0.0, mid: 0.0, high: 0.0, air: 0.0, kick: 0.0, snare: 0.0, hat: 0.0, onset: 0.0, drums: 0.0, rest: 0.0, vocals: 0.0 };

    /// The loudest band.
    pub fn level(&self) -> f64 {
        [self.sub, self.low, self.mid, self.high, self.air].into_iter().fold(0.0, f64::max)
    }

    fn fields(&self) -> [f64; 12] {
        [self.sub, self.low, self.mid, self.high, self.air, self.kick, self.snare, self.hat, self.onset, self.drums, self.rest, self.vocals]
    }

    fn from_fields(f: [f64; 12]) -> ShowAudio {
        ShowAudio { sub: f[0], low: f[1], mid: f[2], high: f[3], air: f[4], kick: f[5], snare: f[6], hat: f[7], onset: f[8], drums: f[9], rest: f[10], vocals: f[11] }
    }

    pub fn scaled(&self, k: f64) -> ShowAudio {
        Self::from_fields(self.fields().map(|v| v * k))
    }

    /// Two summed, each capped at 1.
    pub fn plus(&self, o: &ShowAudio) -> ShowAudio {
        let (a, b) = (self.fields(), o.fields());
        Self::from_fields(std::array::from_fn(|i| (a[i] + b[i]).min(1.0)))
    }

    pub fn flat_into(&self, m: &mut Flat, at: &str) {
        const NAMES: [&str; 12] = ["sub", "low", "mid", "high", "air", "kick", "snare", "hat", "onset", "drums", "rest", "vocals"];
        for (n, v) in NAMES.iter().zip(self.fields()) {
            m.insert(format!("{at}.{n}"), v);
        }
        m.insert(format!("{at}.level"), self.level());
    }
}

/// A section of the record (its form): intro, verse, build, drop, breakdown, outro…
#[derive(Clone, Debug, PartialEq)]
pub struct Section {
    pub label: String,
    pub start_ms: f64,
    pub end_ms: f64,
}

/// What the Desk knows of a record and sends once per load.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RecordFacts {
    pub track_id: Option<i64>,
    pub title: Option<String>,
    pub artist: Option<String>,
    /// The beats, ms (the analysis's).
    pub beats_ms: Vec<f64>,
    /// The steady grid the Desk plays the record by (origin ms, period ms), where it is one.
    pub steady: Option<(f64, f64)>,
    /// Which beat of four the bar starts on.
    pub bar_starts_on: i64,
    /// Where each bar starts, ms.
    pub downbeats_ms: Vec<f64>,
    /// The four-bar markers, ms.
    pub markers_ms: Vec<f64>,
    /// How loud each bar is, 0..255.
    pub energy: Vec<u8>,
    /// Where it drops (the structure's where it has them, else the energy's), ms.
    pub drops_ms: Vec<f64>,
    pub sections: Vec<Section>,
    pub key: Option<String>,
    pub camelot: Option<String>,
    /// The voice's share of each bar, 0..255.
    pub vocal_bars: Option<Vec<u8>>,
    /// Where the hook starts, ms.
    pub hook_ms: Vec<f64>,
    /// The cover's colour, 0xRRGGBB.
    pub cover_rgb: Option<u32>,
}

/// The beat at a place: its index, how far through it, its length (ms).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BeatAt {
    pub index: i64,
    pub phase: f64,
    pub period: f64,
}

impl RecordFacts {
    pub fn has_beats(&self) -> bool {
        self.beats_ms.len() >= 8
    }

    /// Beats a minute on the grid the Desk plays by.
    pub fn grid_bpm(&self) -> Option<f64> {
        self.steady.map(|(_, p)| 60_000.0 / p).or_else(|| {
            let b = &self.beats_ms;
            (b.len() >= 2).then(|| 60_000.0 * (b.len() - 1) as f64 / (b[b.len() - 1] - b[0]))
        })
    }

    fn bar_ms(&self) -> Option<f64> {
        self.steady.map(|(_, p)| 4.0 * p).or_else(|| self.grid_bpm().map(|bpm| 4.0 * 60_000.0 / bpm))
    }

    /// The four-bar markers, or every fourth downbeat for facts with none.
    pub fn markers(&self) -> Vec<f64> {
        if !self.markers_ms.is_empty() {
            return self.markers_ms.clone();
        }
        let downs: Vec<f64> = if !self.downbeats_ms.is_empty() {
            self.downbeats_ms.clone()
        } else {
            (self.bar_starts_on.max(0) as usize..self.beats_ms.len()).step_by(4).map(|i| self.beats_ms[i]).collect()
        };
        downs.into_iter().step_by(4).collect()
    }

    /// Which beat `ms` is on, read off the fitted grid: the steady one, else a line through
    /// the beats nearby (v1: smoothBeatAt).
    pub fn smooth_beat_at(&self, ms: f64) -> Option<BeatAt> {
        let b = &self.beats_ms;
        if b.len() < 2 {
            return None;
        }
        if let Some((origin, period)) = self.steady {
            if ms < b[0] - 4.0 * period || ms > b[b.len() - 1] + 4.0 * period {
                return None;
            }
            let x = (ms - origin) / period;
            let whole = x.floor();
            return Some(BeatAt { index: whole as i64, phase: x - whole, period });
        }
        if ms < b[0] || ms >= b[b.len() - 1] {
            return None;
        }
        // a least-squares line through the eight beats either side of the nearest one
        let near = b.partition_point(|&t| t <= ms).saturating_sub(1);
        let (from, to) = (near.saturating_sub(8), (near + 9).min(b.len()));
        let n = (to - from) as f64;
        let (mut sx, mut sy, mut sxx, mut sxy) = (0.0, 0.0, 0.0, 0.0);
        for (i, &t) in b.iter().enumerate().take(to).skip(from) {
            let x = i as f64;
            sx += x;
            sy += t;
            sxx += x * x;
            sxy += x * t;
        }
        let period = (n * sxy - sx * sy) / (n * sxx - sx * sx);
        let origin = (sy - period * sx) / n;
        if !(period > 0.0) {
            return None;
        }
        let x = (ms - origin) / period;
        let whole = x.floor();
        Some(BeatAt { index: whole as i64, phase: x - whole, period })
    }

    /// Which bar of its four-bar phrase `ms` falls in, and how many bars that phrase has.
    pub fn place_in_phrase(&self, ms: f64) -> Option<(i64, i64)> {
        let m = self.markers();
        let bar = self.bar_ms()?;
        if m.is_empty() {
            return None;
        }
        // a hair before a marker is that marker
        let slack = bar / 8.0;
        let i = m.iter().rposition(|&t| t <= ms + slack)?;
        let since = ((ms + slack - m[i]) / bar).floor() as i64;
        if i + 1 >= m.len() {
            return Some((since.rem_euclid(4), 4));
        }
        let of = ((m[i + 1] - m[i]) / bar).round().clamp(1.0, 4.0) as i64;
        Some((since.clamp(0, of - 1), of))
    }

    pub fn section_at(&self, ms: f64) -> Option<&Section> {
        self.sections.iter().find(|s| ms >= s.start_ms && ms < s.end_ms)
    }

    /// The key as a hue round the wheel (Camelot's twelve, 1A at the top).
    pub fn key_hue(&self) -> Option<f64> {
        let c = self.camelot.as_deref()?;
        if c.len() < 2 {
            return None;
        }
        let n: i64 = c[..c.len() - 1].parse().ok()?;
        Some(((n - 1).rem_euclid(12)) as f64 / 12.0)
    }
}

/// What the mixer has this channel set to.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Channel {
    pub level: f64,
    /// The bands' gains as factors (1 flat, 0 killed).
    pub eq_low: f64,
    pub eq_mid: f64,
    pub eq_high: f64,
    /// -1 all the way low-pass, 1 high-pass, 0 open.
    pub filter: f64,
    pub looping: bool,
}

impl Default for Channel {
    fn default() -> Self {
        Channel { level: 1.0, eq_low: 1.0, eq_mid: 1.0, eq_high: 1.0, filter: 0.0, looping: false }
    }
}

/// A band's gain in decibels as a factor; the kill (-40 dB or less) is nothing.
pub fn gain_of(db: f64) -> f64 {
    if db <= -40.0 { 0.0 } else { 10f64.powf(db / 20.0) }
}

/// Within how many beats a drop is looked for ahead, and how long after one it is still
/// "just dropped".
pub const DROP_LOOKAHEAD_BEATS: f64 = 64.0;
pub const DROP_HOLD_BEATS: f64 = 2.0;

/// One deck as the show sees it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ShowDeck {
    pub name: String,
    pub track_id: Option<i64>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub playing: bool,
    pub position_ms: f64,
    pub bpm: Option<f64>,
    pub beat_index: Option<i64>,
    pub beat_phase: f64,
    pub beat_in_bar: Option<i64>,
    pub bar_index: Option<i64>,
    pub bar_phase: f64,
    pub phrase_bar: Option<i64>,
    pub phrase_phase: f64,
    pub section: Option<String>,
    pub section_k: f64,
    pub section_bars_left: Option<f64>,
    pub drop_beats_away: Option<f64>,
    pub breakdown: bool,
    pub build_k: f64,
    pub energy: f64,
    pub vocal: f64,
    pub hook: bool,
    pub key: Option<String>,
    pub camelot: Option<String>,
    pub key_hue: Option<f64>,
    pub cover_rgb: Option<u32>,
    pub channel: Channel,
    pub audio: ShowAudio,
}

/// The index of the last of `sorted` at or before `ms`.
fn last_at_or_before(sorted: &[f64], ms: f64) -> Option<usize> {
    sorted.partition_point(|&t| t <= ms).checked_sub(1)
}

impl ShowDeck {
    /// The deck at `position_ms` (the ear's), from the record's facts and what is heard.
    pub fn derive(name: &str, facts: Option<&RecordFacts>, playing: bool, position_ms: f64, channel: Channel, heard: ShowAudio) -> ShowDeck {
        let ms = position_ms;
        let mut d = ShowDeck { name: name.into(), playing, position_ms, channel, audio: if playing { heard } else { ShowAudio::SILENCE }, ..Default::default() };
        let Some(t) = facts else { return d };
        d.track_id = t.track_id;
        d.title = t.title.clone();
        d.artist = t.artist.clone();
        d.key = t.key.clone();
        d.camelot = t.camelot.clone();
        d.key_hue = t.key_hue();
        d.cover_rgb = t.cover_rgb;
        if !t.has_beats() {
            return d;
        }
        d.bpm = t.grid_bpm();
        let Some(beat) = t.smooth_beat_at(ms) else { return d };
        d.beat_index = Some(beat.index);
        d.beat_phase = beat.phase;
        let from_one = beat.index - t.bar_starts_on;
        let in_bar = from_one.rem_euclid(4);
        d.beat_in_bar = Some(in_bar);
        d.bar_index = Some(from_one.div_euclid(4));
        d.bar_phase = (in_bar as f64 + beat.phase) / 4.0;
        if let Some((bar, of)) = t.place_in_phrase(ms) {
            d.phrase_bar = Some(bar);
            d.phrase_phase = ((bar as f64 + d.bar_phase) / of as f64).clamp(0.0, 1.0);
        }
        let bar = last_at_or_before(&t.downbeats_ms, ms);
        if let Some(b) = bar
            && b < t.energy.len()
        {
            d.energy = t.energy[b] as f64 / 255.0;
        }
        let period = beat.period;
        if let Some(s) = t.section_at(ms) {
            d.section = Some(s.label.clone());
            let span = s.end_ms - s.start_ms;
            d.section_k = if span > 0.0 { ((ms - s.start_ms) / span).clamp(0.0, 1.0) } else { 0.0 };
            d.section_bars_left = Some((s.end_ms - ms) / (4.0 * period));
            d.breakdown = s.label == "breakdown" || s.label == "break";
            if s.label == "build" {
                d.build_k = d.section_k;
            }
        }
        if !t.drops_ms.is_empty() {
            let hold = (DROP_HOLD_BEATS * period).round();
            let i = last_at_or_before(&t.drops_ms, ms + hold);
            // the one just passed, within the hold; else the next ahead
            let at = match i {
                Some(i) if t.drops_ms[i] >= ms - hold => Some(t.drops_ms[i]),
                Some(i) => t.drops_ms.get(i + 1).copied(),
                None => t.drops_ms.first().copied(),
            };
            if let Some(at) = at {
                let away = (at - ms) / period;
                if away <= DROP_LOOKAHEAD_BEATS {
                    d.drop_beats_away = Some(away);
                }
            }
            if let Some(away) = d.drop_beats_away
                && away > 0.0
                && away <= 32.0
                && d.section.as_deref() != Some("build")
            {
                d.build_k = d.build_k.max(1.0 - away / 32.0);
            }
        }
        if let Some(b) = bar {
            if let Some(v) = t.vocal_bars.as_ref().and_then(|v| v.get(b)) {
                d.vocal = *v as f64 / 255.0;
            }
            let bar_ms = 4.0 * period;
            d.hook = t.hook_ms.iter().any(|&h| ms >= h && ms < h + bar_ms * 2.0);
        }
        d
    }

    pub fn on_beat_one(&self) -> bool {
        self.beat_in_bar == Some(0)
    }

    /// Carried on `dt` seconds at its tempo (between two of the Desk's frames).
    pub fn advanced(&self, dt: f64) -> ShowDeck {
        let Some(bpm) = self.bpm.filter(|b| *b > 0.0) else { return self.clone() };
        if !self.playing || dt <= 0.0 {
            return self.clone();
        }
        let beats = dt * bpm / 60.0;
        let beat = self.beat_phase + beats;
        let whole = beat.floor();
        let bar = self.bar_phase + beats / 4.0;
        let phrase = self.phrase_phase + beats / 16.0;
        ShowDeck {
            position_ms: self.position_ms + dt * 1000.0,
            beat_index: self.beat_index.map(|i| i + whole as i64),
            beat_phase: beat - whole,
            beat_in_bar: self.beat_in_bar.map(|b| (b + whole as i64).rem_euclid(4)),
            bar_index: self.bar_index.map(|b| b + bar.floor() as i64),
            bar_phase: bar - bar.floor(),
            phrase_phase: phrase - phrase.floor(),
            section_bars_left: self.section_bars_left.map(|l| l - beats / 4.0),
            drop_beats_away: self.drop_beats_away.map(|a| a - beats),
            ..self.clone()
        }
    }

    pub fn flat_into(&self, m: &mut Flat, at: &str) {
        let b = |v: bool| if v { 1.0 } else { 0.0 };
        let mut put = |k: &str, v: f64| {
            m.insert(format!("{at}.{k}"), v);
        };
        put("playing", b(self.playing));
        put("position", self.position_ms / 1000.0);
        put("bpm", self.bpm.unwrap_or(0.0));
        put("beat.index", self.beat_index.unwrap_or(0) as f64);
        put("beat.phase", self.beat_phase);
        put("beat.inBar", self.beat_in_bar.unwrap_or(0) as f64);
        put("bar.index", self.bar_index.unwrap_or(0) as f64);
        put("bar.phase", self.bar_phase);
        put("phrase.bar", self.phrase_bar.unwrap_or(0) as f64);
        put("phrase.phase", self.phrase_phase);
        put("section.k", self.section_k);
        put("section.barsLeft", self.section_bars_left.unwrap_or(0.0));
        put("drop.beatsAway", self.drop_beats_away.unwrap_or(999.0));
        put("drop.near", self.drop_beats_away.map(|a| (1.0 - a.abs() / 32.0).clamp(0.0, 1.0)).unwrap_or(0.0));
        put("breakdown", b(self.breakdown));
        put("build.k", self.build_k);
        put("energy", self.energy);
        put("vocal", self.vocal);
        put("lyric.k", 0.0);
        put("hook", b(self.hook));
        put("key.hue", self.key_hue.unwrap_or(0.0));
        put("level", self.channel.level);
        put("eq.low", self.channel.eq_low);
        put("eq.mid", self.channel.eq_mid);
        put("eq.high", self.channel.eq_high);
        put("filter", self.channel.filter);
        put("stems.drums", 1.0);
        put("stems.rest", 1.0);
        put("stems.vocals", 1.0);
        put("loop", b(self.channel.looping));
        self.audio.flat_into(m, &format!("{at}.audio"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A record at 120 BPM (500 ms a beat), bar one on beat 0, a minute long, a build
    /// into a drop at 32 s.
    fn record() -> RecordFacts {
        let beats: Vec<f64> = (0..120).map(|i| i as f64 * 500.0).collect();
        RecordFacts {
            beats_ms: beats.clone(),
            steady: Some((0.0, 500.0)),
            downbeats_ms: beats.iter().step_by(4).copied().collect(),
            energy: (0..30).map(|i| (i * 8) as u8).collect(),
            drops_ms: vec![32_000.0],
            sections: vec![
                Section { label: "intro".into(), start_ms: 0.0, end_ms: 16_000.0 },
                Section { label: "build".into(), start_ms: 16_000.0, end_ms: 32_000.0 },
                Section { label: "drop".into(), start_ms: 32_000.0, end_ms: 60_000.0 },
            ],
            camelot: Some("8A".into()),
            ..Default::default()
        }
    }

    #[test]
    fn the_needle_on_its_grid() {
        let r = record();
        let d = ShowDeck::derive("A", Some(&r), true, 4_250.0, Channel::default(), ShowAudio::SILENCE);
        assert_eq!(d.bpm, Some(120.0));
        assert_eq!(d.beat_index, Some(8));
        assert!((d.beat_phase - 0.5).abs() < 1e-9);
        assert_eq!(d.beat_in_bar, Some(0));
        assert_eq!(d.bar_index, Some(2));
        assert!((d.bar_phase - 0.125).abs() < 1e-9);
        assert_eq!(d.phrase_bar, Some(2), "the third bar of its four");
        assert_eq!(d.section.as_deref(), Some("intro"));
        assert!((d.energy - 16.0 / 255.0).abs() < 1e-9);
        assert_eq!(d.key_hue, Some(7.0 / 12.0));
    }

    #[test]
    fn a_build_climbs_into_the_drop_and_just_after_it_still_says_so() {
        let r = record();
        let at = |ms| ShowDeck::derive("A", Some(&r), true, ms, Channel::default(), ShowAudio::SILENCE);
        let mid_build = at(24_000.0);
        assert_eq!(mid_build.section.as_deref(), Some("build"));
        assert!((mid_build.build_k - 0.5).abs() < 1e-9);
        assert_eq!(mid_build.drop_beats_away, Some(16.0));
        let just_after = at(32_400.0);
        assert!(just_after.drop_beats_away.unwrap() < 0.0, "just dropped: within the hold");
        let mut m = Flat::new();
        just_after.flat_into(&mut m, "deck.a");
        assert!(m["deck.a.drop.near"] > 0.9);
        let past = at(40_000.0);
        assert_eq!(past.drop_beats_away, None);
    }

    #[test]
    fn carried_on_between_frames() {
        let r = record();
        let d = ShowDeck::derive("A", Some(&r), true, 1_900.0, Channel::default(), ShowAudio::SILENCE);
        let e = d.advanced(0.2); // 0.4 beats on
        assert_eq!(e.beat_index, Some(4));
        assert!((e.beat_phase - 0.2).abs() < 1e-9);
        assert_eq!(e.beat_in_bar, Some(0));
        assert_eq!(e.bar_index, Some(1));
    }

    #[test]
    fn beats_without_a_steady_grid_read_off_the_line_through_them() {
        let mut r = record();
        r.steady = None;
        let b = r.smooth_beat_at(4_250.0).unwrap();
        assert_eq!(b.index, 8);
        assert!((b.phase - 0.5).abs() < 1e-6);
        assert!((b.period - 500.0).abs() < 1e-6);
    }

    #[test]
    fn audio_sums_and_caps() {
        let a = ShowAudio { low: 0.7, kick: 0.6, ..Default::default() };
        let s = a.plus(&a);
        assert_eq!(s.low, 1.0);
        assert_eq!(a.scaled(0.5).kick, 0.3);
        assert_eq!(s.level(), 1.0);
    }
}
