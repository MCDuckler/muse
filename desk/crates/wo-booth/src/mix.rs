//! The booth mixing on its own, the v1 booth's rules (app/lib/src/state/booth/
//! automix.dart, booth.dart): where to come out of a record, where to come into the
//! next, which kind of transition and over how many bars — and, bar by bar, what the
//! transition does with the crossfader, the EQs, the filter, a loop and the brake.
//! Pure: the desk runs it (wo-deskcore), tests check it here. Times are seconds.
use crate::grid::Grid;

/// How far a record's tempo may be pulled to sit with another's (±16 %).
pub const BRIDGE_REACH: f64 = 0.16;

/// How the booth mixes when left to itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Style {
    /// Nothing sudden: long blends, long fades.
    Easy,
    #[default]
    Normal,
    /// Something to land on: rolls, sweeps, brakes, short blends.
    Bold,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Transition {
    /// The incoming enters with its bass killed, the bass swaps half way, the
    /// outgoing's top rolls off at the end. The classic.
    Blend,
    /// On the one: the incoming takes over on a downbeat, no overlap.
    Cut,
    /// Levels only, crossed over the bars.
    Fade,
    /// The outgoing climbs out through a high-pass while the incoming comes up under it.
    Sweep,
    /// The outgoing caught in a loop that halves as it goes, let go as the new one lands.
    Roll,
    /// The incoming comes up; on the last beat the outgoing brakes to a stop.
    Brake,
}

impl Transition {
    pub fn word(self) -> &'static str {
        match self {
            Transition::Blend => "Blend",
            Transition::Cut => "Cut",
            Transition::Fade => "Fade",
            Transition::Sweep => "Sweep",
            Transition::Roll => "Roll",
            Transition::Brake => "Brake",
        }
    }
}

/// A section of a record, as the house's structure read it.
#[derive(Clone, Debug, PartialEq)]
pub struct Section {
    pub label: String,
    pub start: f64,
    pub end: f64,
}

/// A place to come in or go out, and why (the house's structure).
#[derive(Clone, Debug, PartialEq)]
pub struct Place {
    pub at: f64,
    pub why: String,
}

/// What a record is made of in time, for mixing: its grid and what the house found.
#[derive(Clone, Debug, Default)]
pub struct Timing {
    pub grid: Grid,
    pub bpm: Option<f64>,
    pub camelot: Option<String>,
    /// "cold", "fade", or "" when it could not be said.
    pub ends: String,
    pub duration: f64,
    pub first_downbeat: Option<f64>,
    pub mix_in: Option<f64>,
    pub mix_out: Option<f64>,
    pub sound_end: Option<f64>,
    /// The record's four-bar markers and its phrase starts.
    pub markers: Vec<f64>,
    pub phrases: Vec<f64>,
    pub drops: Vec<f64>,
    pub sections: Vec<Section>,
    pub outs: Vec<Place>,
    pub ins: Vec<Place>,
    /// Each bar's start and loudness (dBFS), the structure's.
    pub bars_db: Vec<(f64, f64)>,
    /// Where a hand said it leaves, and comes in.
    pub hand_out: Option<f64>,
    pub hand_in: Option<f64>,
}

impl Timing {
    /// A record with a grid and nothing else known (no house analysis).
    pub fn from_grid(grid: Grid, duration: f64) -> Timing {
        let bpm = grid.spb().map(|s| 60.0 / s);
        let first = grid.beats.get(grid.bar_one).copied();
        let mut t = Timing { grid, bpm, duration, first_downbeat: first, ..Default::default() };
        t.markers = t.bar_beats().into_iter().step_by(4).collect();
        t
    }

    pub fn has_beats(&self) -> bool {
        self.grid.beats.len() > 8 && self.bpm.is_some()
    }

    /// Seconds a bar, of the record.
    pub fn bar(&self) -> Option<f64> {
        self.grid.spb().map(|s| 4.0 * s)
    }

    fn bar_beats(&self) -> Vec<f64> {
        self.grid.beats.iter().enumerate().filter(|(i, _)| self.grid.is_bar(*i)).map(|(_, &b)| b).collect()
    }

    /// `at` onto the grid: the nearest beat, or with `every` 4 the nearest bar's one.
    pub fn on_grid(&self, at: f64, every: usize) -> f64 {
        let b = &self.grid.beats;
        if b.is_empty() {
            return at;
        }
        let near = |i: usize| (b[i] - at).abs();
        let candidates = (0..b.len()).filter(|&i| every < 4 || self.grid.is_bar(i));
        candidates.min_by(|&i, &j| near(i).total_cmp(&near(j))).map(|i| b[i]).unwrap_or(at)
    }

    pub fn marker_at_or_before(&self, at: f64) -> Option<f64> {
        self.markers.iter().copied().take_while(|&m| m <= at + 1e-6).last().or(self.markers.first().copied())
    }

    pub fn on_marker(&self, at: f64) -> f64 {
        match self.markers.iter().copied().min_by(|a, b| (a - at).abs().total_cmp(&(b - at).abs())) {
            Some(m) => self.on_grid(m, 4),
            None => at,
        }
    }

    pub fn drop_after(&self, at: f64) -> Option<f64> {
        self.drops.iter().copied().find(|&d| d >= at)
    }

    pub fn section_at(&self, at: f64) -> Option<&Section> {
        self.sections.iter().find(|s| s.start <= at && at < s.end)
    }

    pub fn in_key_with(&self, other: &Timing) -> bool {
        camelot_near(self.camelot.as_deref(), other.camelot.as_deref())
    }
}

/// Two Camelot keys that sit together: the same, one step round the wheel, or the
/// relative major/minor.
pub fn camelot_near(a: Option<&str>, b: Option<&str>) -> bool {
    let parse = |k: &str| -> Option<(i32, char)> {
        let letter = k.chars().last()?;
        Some((k.strip_suffix(letter)?.parse().ok()?, letter))
    };
    let (Some((na, ma)), Some((nb, mb))) = (a.and_then(parse), b.and_then(parse)) else { return false };
    if ma == mb {
        let d = (na - nb).abs();
        d <= 1 || d == 11
    } else {
        na == nb
    }
}

/// The rate that puts `from` bpm on `to`'s, half or double time folded the way the ear
/// counts; None when it is further than `reach` away.
pub fn sync_ratio(from: f64, to: f64, reach: f64) -> Option<f64> {
    if from <= 0.0 || to <= 0.0 {
        return None;
    }
    let mut target = to;
    while target / from > std::f64::consts::SQRT_2 {
        target /= 2.0;
    }
    while target / from < std::f64::consts::FRAC_1_SQRT_2 {
        target *= 2.0;
    }
    let ratio = target / from;
    ((ratio - 1.0).abs() <= reach).then_some(ratio)
}

/// Which kind of transition, over how many bars, from `from` (at `from_pitch`) into `to`.
pub fn choose(from: Option<&Timing>, to: Option<&Timing>, style: Style, from_pitch: f64) -> (Transition, u32) {
    let (Some(from), Some(to)) = (from, to) else { return (Transition::Fade, 4) };
    if !from.has_beats() || !to.has_beats() {
        return (Transition::Fade, 4);
    }
    // Two speeds that cannot be one are handed over, not laid on top of each other.
    if sync_ratio(to.bpm.unwrap(), from.bpm.unwrap() * from_pitch, BRIDGE_REACH).is_none() {
        return if from.ends == "cold" { (Transition::Cut, 1) } else { (Transition::Fade, 4) };
    }
    // A record that fades itself goes out as it was made to — but in step.
    if from.ends == "fade" {
        return (Transition::Fade, 8);
    }
    let in_key = from.in_key_with(to);
    if from.ends == "cold" && in_key {
        return (Transition::Cut, 1);
    }
    match style {
        Style::Easy => if in_key { (Transition::Blend, 32) } else { (Transition::Fade, 16) },
        // a clash goes out through the filter: a high-passed record has hardly any key left
        Style::Normal => if in_key { (Transition::Blend, 16) } else { (Transition::Sweep, 8) },
        Style::Bold => {
            let drops = !to.drops.is_empty();
            if drops && in_key {
                (Transition::Roll, 8)
            } else if drops {
                (Transition::Sweep, 8)
            } else if from.ends == "cold" {
                (Transition::Brake, 8)
            } else if in_key {
                (Transition::Blend, 8)
            } else {
                (Transition::Sweep, 8)
            }
        }
    }
}

/// Where the outgoing record's transition (`length` seconds of it) starts: where a hand
/// said; else the structure's best place to leave with room before it; else the plain
/// cue; else far enough from the end for the move. Off the middle of a chorus or a
/// drop, and on a phrase (or the grid where the structure chose).
pub fn out_point(from: &Timing, length: f64) -> f64 {
    let end = from.sound_end.unwrap_or(from.duration);
    let latest = end - length;
    let first = from.first_downbeat.unwrap_or(0.0);
    if let Some(hand) = from.hand_out {
        let at = if latest > 0.0 && hand > latest { from.marker_at_or_before(latest).unwrap_or(latest) } else { hand };
        return from.on_grid(at, 4);
    }
    let mix_out = match (from.mix_out, from.mix_in) {
        (Some(o), Some(i)) if o <= i => None,
        (o, _) => o,
    };
    let bar = from.bar();
    let mut chosen = None;
    if let Some(bar) = bar.filter(|_| !from.outs.is_empty()) {
        let earliest = from.mix_in.unwrap_or(first) + 16.0 * bar;
        let rank = |p: &Place| if p.why.contains("outro") { 3 } else if p.why.starts_with("after") { 2 } else { 1 };
        chosen = from
            .outs
            .iter()
            .filter(|p| !(latest > 0.0 && p.at > latest) && p.at >= earliest)
            .max_by(|a, b| rank(a).cmp(&rank(b)).then(a.at.total_cmp(&b.at)))
            .map(|p| p.at);
    }
    let mut at = chosen.or(mix_out).unwrap_or(end - length).max(0.0);
    if latest > 0.0 && at > latest {
        at = latest;
    }
    // not in the middle of the payoff
    if let (Some(bar), Some(sec)) = (bar, from.section_at(at))
        && (sec.label == "chorus" || sec.label == "drop")
        && at > sec.start + bar
    {
        if latest <= 0.0 || sec.end <= latest {
            at = sec.end;
        } else if sec.start >= first + 16.0 * bar {
            at = sec.start;
        }
    }
    let on = if chosen.is_some() { from.on_grid(at, 4) } else { on_phrase(from, at) };
    if latest > 0.0 && on > latest { from.marker_at_or_before(latest).unwrap_or(on) } else { on }
}

/// `at`, moved off a drop the transition would run over: brought forward to finish
/// there (on the marker before), so the old record never drops under the new one.
pub fn clear_of_drops(from: &Timing, at: f64, length: f64) -> f64 {
    let first = from.first_downbeat.unwrap_or(0.0);
    for &d in &from.drops {
        if d > at && d < at + length {
            let earlier = from.marker_at_or_before(d - length).unwrap_or(d - length);
            return if earlier >= first { earlier } else { at };
        }
    }
    at
}

/// `at` moved to the nearest phrase start within eight bars (one on a marker), else
/// to the nearest marker: a mix started mid-phrase lands mid-phrase.
pub fn on_phrase(t: &Timing, at: f64) -> f64 {
    if t.markers.is_empty() {
        return at;
    }
    let reach = t.bar().map(|b| 8.0 * b).unwrap_or(8.0);
    let on_marker = |p: f64| t.markers.iter().any(|&m| (m - p).abs() < 0.002);
    match t.phrases.iter().copied().filter(|&p| on_marker(p) && (p - at).abs() <= reach).min_by(|a, b| (a - at).abs().total_cmp(&(b - at).abs())) {
        Some(p) => t.on_grid(p, 4),
        None => t.on_marker(at),
    }
}

/// Whether `bars` bars from `at` are quiet: 8 dB under the record's loud bars.
pub fn quiet_bars(t: &Timing, at: f64, bars: usize) -> bool {
    let mut heard: Vec<f64> = t.bars_db.iter().map(|b| b.1).filter(|&v| v > -90.0).collect();
    if heard.is_empty() {
        return false;
    }
    heard.sort_by(|a, b| a.total_cmp(b));
    let loud = heard[((heard.len() as f64 * 0.9) as usize).min(heard.len() - 1)];
    let i = t.bars_db.iter().rposition(|b| b.0 <= at).unwrap_or(0);
    let span: Vec<f64> = t.bars_db[i..(i + bars).min(t.bars_db.len())].iter().map(|b| b.1).filter(|&v| v > -90.0).collect();
    !span.is_empty() && span.iter().sum::<f64>() / (span.len() as f64) < loud - 8.0
}

/// Where the incoming record is parked: `bars` bars before its intro ends (or before
/// its drop, aiming at it), on one of its four-bar markers, never before its first
/// downbeat; later where those bars are quiet, so a blend never goes into a hole.
pub fn in_point(to: &Timing, bars: u32, on_the_drop: bool) -> f64 {
    let lead = to.grid.beats.first().copied().unwrap_or(0.0);
    let Some(first) = to.first_downbeat else { return lead };
    let Some(bar) = to.bar() else { return first };
    if let Some(hand) = to.hand_in {
        return to.on_grid(hand.max(first), 1);
    }
    let drop = if on_the_drop { to.drop_after(first) } else { None };
    let intro_end = to.ins.iter().find(|p| p.why.contains("intro")).map(|p| p.at);
    let target = drop.or(intro_end).or(to.mix_in).unwrap_or(first);
    let bars = bars as f64;
    let mut at = (target - bar * bars).max(first);
    if drop.is_none() && quiet_bars(to, at, bars as usize) {
        let half_bars = (bars / 2.0).floor().max(1.0);
        let half = target - bar * half_bars;
        at = if quiet_bars(to, half, half_bars as usize) { target } else { half };
        at = at.max(first);
    }
    if let Some(m) = to.markers.iter().rev().copied().find(|&m| m <= at + 1e-6 && m >= first - 1e-6) {
        return to.on_grid(m, 4);
    }
    match to.grid.beats.iter().enumerate().rev().find(|(i, b)| to.grid.is_bar(*i) && **b <= at + 1e-6 && **b >= first - 1e-6) {
        Some((_, &b)) => b,
        None => to.on_grid(at, 1),
    }
}

/// What a transition does at `p` (0..1 through its bars), with the outgoing on the
/// crossfader's left: the crossfader, each side's EQ knobs (low, mid, high: 0 kill,
/// 0.5 flat), the outgoing's filter knob (0.5 off, 1 all high-pass), a loop on the
/// outgoing (beats), and whether it brakes now.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Moves {
    pub crossfader: f32,
    pub from_eq: [f32; 3],
    pub to_eq: [f32; 3],
    pub from_filter: f32,
    pub from_loop: Option<f64>,
    pub from_brake: bool,
}

/// The transition `kind` at `p` (clamped to 0..1).
pub fn moves(kind: Transition, p: f64) -> Moves {
    let p = p.clamp(0.0, 1.0) as f32;
    let flat = [0.5f32; 3];
    let killed_low = [0.0, 0.5, 0.5];
    let ramp = |a: f32, b: f32| ((p - a) / (b - a)).clamp(0.0, 1.0);
    // The crossfader law gives each side full level from the centre in: rising from
    // 0 to 0.5 brings the incoming up, from 0.5 to 1 takes the outgoing away.
    let up_then_out = |up_by: f32, out_from: f32| 0.5 * ramp(0.0, up_by) + 0.5 * ramp(out_from, 1.0);
    let mut m = Moves { crossfader: 0.0, from_eq: flat, to_eq: flat, from_filter: 0.5, from_loop: None, from_brake: false };
    match kind {
        Transition::Blend => {
            m.crossfader = up_then_out(0.5, 0.75);
            let swapped = p >= 0.5;
            m.to_eq = if swapped { flat } else { killed_low };
            m.from_eq = if swapped { [0.0, 0.5, 0.5 - 0.5 * ramp(0.8, 1.0)] } else { flat };
        }
        Transition::Cut => m.crossfader = 1.0,
        Transition::Fade => m.crossfader = p,
        Transition::Sweep => {
            m.crossfader = up_then_out(0.6, 0.8);
            m.to_eq = if p >= 0.5 { flat } else { killed_low };
            m.from_filter = 0.5 + 0.45 * ramp(0.0, 1.0);
        }
        Transition::Roll => {
            m.crossfader = up_then_out(0.5, 0.875);
            m.to_eq = if p >= 0.5 { flat } else { killed_low };
            // two bars, one, half, a quarter — then let go
            m.from_loop = match p {
                p if p < 0.25 => Some(8.0),
                p if p < 0.5 => Some(4.0),
                p if p < 0.75 => Some(2.0),
                p if p < 0.875 => Some(1.0),
                _ => None,
            };
        }
        Transition::Brake => {
            m.crossfader = 0.5 * ramp(0.0, 0.875) + 0.5 * ramp(0.97, 1.0);
            m.to_eq = if p >= 0.5 { flat } else { killed_low };
            m.from_brake = p >= 0.875;
        }
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 128 bpm from 0.5 s, bar one on beat 0; markers every 4 bars; an intro to bar 16,
    /// a drop at bar 32, an outro from bar 96; 112 bars long.
    fn timing(camelot: &str) -> Timing {
        let spb = 60.0 / 128.0;
        let grid = Grid::new((0..448).map(|i| 0.5 + i as f64 * spb).collect(), 0);
        let bar = |n: f64| 0.5 + n * 4.0 * spb;
        let mut t = Timing::from_grid(grid, bar(112.0) + 1.0);
        t.camelot = Some(camelot.into());
        t.mix_in = Some(bar(16.0));
        t.mix_out = Some(bar(96.0));
        t.drops = vec![bar(32.0)];
        t.phrases = vec![bar(0.0), bar(16.0), bar(32.0), bar(64.0), bar(96.0)];
        t.ins = vec![Place { at: bar(16.0), why: "the intro is over".into() }];
        t
    }

    #[test]
    fn half_and_double_time_sync() {
        assert!((sync_ratio(140.0, 70.0, 0.16).unwrap() - 1.0).abs() < 1e-12);
        assert!((sync_ratio(128.0, 132.0, 0.16).unwrap() - 132.0 / 128.0).abs() < 1e-12);
        assert_eq!(sync_ratio(128.0, 100.0, 0.16), None);
    }

    #[test]
    fn camelot_neighbours() {
        assert!(camelot_near(Some("8A"), Some("9A")));
        assert!(camelot_near(Some("12B"), Some("1B")));
        assert!(camelot_near(Some("8A"), Some("8B")));
        assert!(!camelot_near(Some("8A"), Some("10A")));
        assert!(!camelot_near(None, Some("8A")));
    }

    #[test]
    fn choose_the_v1_way() {
        let (a, b, clash) = (timing("8A"), timing("9A"), timing("3B"));
        assert_eq!(choose(Some(&a), Some(&b), Style::Normal, 1.0), (Transition::Blend, 16));
        assert_eq!(choose(Some(&a), Some(&clash), Style::Normal, 1.0), (Transition::Sweep, 8));
        assert_eq!(choose(Some(&a), Some(&b), Style::Easy, 1.0), (Transition::Blend, 32));
        assert_eq!(choose(Some(&a), Some(&b), Style::Bold, 1.0), (Transition::Roll, 8), "a drop to land on, in key");
        let mut cold = timing("8A");
        cold.ends = "cold".into();
        assert_eq!(choose(Some(&cold), Some(&b), Style::Normal, 1.0), (Transition::Cut, 1));
        let mut slow = timing("8A");
        slow.grid = Grid::new((0..300).map(|i| i as f64 * 0.6).collect(), 0);
        slow.bpm = Some(100.0);
        assert_eq!(choose(Some(&a), Some(&slow), Style::Normal, 1.0), (Transition::Fade, 4), "128 into 100 cannot sync");
        assert_eq!(choose(None, Some(&b), Style::Normal, 1.0), (Transition::Fade, 4));
    }

    #[test]
    fn out_on_the_phrase_clear_of_drops() {
        let a = timing("8A");
        let spb = 60.0 / 128.0;
        let bar = |n: f64| 0.5 + n * 4.0 * spb;
        let len = 16.0 * 4.0 * spb;
        assert!((out_point(&a, len) - bar(96.0)).abs() < 1e-9, "the outro's start, on its phrase");
        // a drop inside the move brings it forward to finish on the drop's marker
        let mut d = timing("8A");
        d.drops = vec![bar(104.0)];
        let at = clear_of_drops(&d, bar(96.0), len);
        assert!((at - bar(88.0)).abs() < 1e-9, "finishes at the drop: {at} vs {}", bar(88.0));
        // a hand's out point stands, on the grid
        let mut h = timing("8A");
        h.hand_out = Some(bar(70.0) + 0.1);
        assert!((out_point(&h, len) - bar(70.0)).abs() < 1e-9);
    }

    #[test]
    fn in_so_the_intro_is_over_when_the_move_is() {
        let b = timing("9A");
        let spb = 60.0 / 128.0;
        let bar = |n: f64| 0.5 + n * 4.0 * spb;
        assert!((in_point(&b, 16, false) - bar(0.0)).abs() < 1e-9, "16 bars before the intro's end at bar 16");
        assert!((in_point(&b, 8, false) - bar(8.0)).abs() < 1e-9, "8 bars before it, on a marker");
        assert!((in_point(&b, 8, true) - bar(24.0)).abs() < 1e-9, "aimed at the drop at bar 32");
        // a quiet intro comes in half way through the move instead
        let mut q = timing("9A");
        q.bars_db = (0..112).map(|n| (bar(n as f64), if n < 8 { -30.0 } else { -8.0 })).collect();
        assert!((in_point(&q, 16, false) - bar(8.0)).abs() < 1e-9, "the first 8 bars quiet: in half way (bar 8)");
        let mut all = timing("9A");
        all.bars_db = (0..112).map(|n| (bar(n as f64), if n < 16 { -30.0 } else { -8.0 })).collect();
        assert!((in_point(&all, 16, false) - bar(16.0)).abs() < 1e-9, "all 16 quiet: in on the intro's end itself");
    }

    #[test]
    fn a_blend_swaps_the_bass_half_way() {
        let start = moves(Transition::Blend, 0.0);
        assert_eq!(start.crossfader, 0.0);
        assert_eq!(start.to_eq[0], 0.0, "the incoming's bass killed");
        let quarter = moves(Transition::Blend, 0.25);
        assert!((quarter.crossfader - 0.25).abs() < 1e-6, "coming up");
        let half = moves(Transition::Blend, 0.5);
        assert_eq!((half.crossfader, half.to_eq[0], half.from_eq[0]), (0.5, 0.5, 0.0), "both full, the bass swapped");
        let end = moves(Transition::Blend, 1.0);
        assert_eq!((end.crossfader, end.from_eq[2]), (1.0, 0.0), "the outgoing gone, its top rolled off");
    }

    #[test]
    fn a_roll_halves_and_a_brake_stops() {
        let loops: Vec<Option<f64>> = [0.1, 0.3, 0.6, 0.8, 0.95].iter().map(|&p| moves(Transition::Roll, p).from_loop).collect();
        assert_eq!(loops, vec![Some(8.0), Some(4.0), Some(2.0), Some(1.0), None]);
        assert!(!moves(Transition::Brake, 0.8).from_brake && moves(Transition::Brake, 0.9).from_brake);
        assert_eq!(moves(Transition::Cut, 0.0).crossfader, 1.0);
    }
}
