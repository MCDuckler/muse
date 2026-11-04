//! Which transition, how long, from where to where — v1's Planner.options
//! (app/lib/src/state/booth/planner.dart) and SetPlanner.keyMove: every move that fits
//! the two records considered, each scored by how much the style likes it (calm moves
//! more for a careful style, wild ones for a bold one), by how well it fits these two,
//! by how many bars of two voices it would make, by the keys, by what was just played
//! and by this person's taste — and a little chance, so a long set is not the same
//! move forty times.
use crate::mix::{self, Style, Timing, Transition};

/// Where the voice is in a record, a bar at a time (the house's /tracks/{id}/vocals).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct VocalMap {
    /// Per bar of the record, how much singing (0..255; [`VocalMap::SUNG`] and up is).
    pub bars: Option<Vec<u8>>,
    /// The hook: its words and the seconds it is sung at.
    pub hook: Option<(String, Vec<f64>)>,
}

impl VocalMap {
    pub const SUNG: u8 = 118;

    pub fn sung_at(&self, bar: i64) -> bool {
        self.bars.as_ref().is_some_and(|b| bar >= 0 && (bar as usize) < b.len() && b[bar as usize] >= Self::SUNG)
    }

    pub fn sung_in(&self, from: i64, to: i64) -> usize {
        (from..to).filter(|&i| self.sung_at(i)).count()
    }
}

/// One record's side of a transition, as the planner sees it.
#[derive(Clone, Copy, Debug)]
pub struct MixSide<'a> {
    pub timing: &'a Timing,
    pub vocals: Option<&'a VocalMap>,
    /// Its stems are on its deck: a stem move can be made with it.
    pub stems: bool,
    pub pitch: f64,
    /// Its deck has the echo and the pitch shift.
    pub fx: bool,
    /// Where it is now (the outgoing): a place already behind it is no place to go out.
    pub position: Option<f64>,
}

/// What the planner decided.
#[derive(Clone, Debug, PartialEq)]
pub struct MixPlan {
    pub kind: Transition,
    pub bars: u32,
    pub out_at: Option<f64>,
    pub in_at: Option<f64>,
    /// The incoming moved this many semitones to meet the outgoing's key.
    pub shift: f64,
    pub why: String,
    pub score: f64,
}

/// How a style mixes, as three dials 0..1: how long, how wild, how much two voices
/// together are minded.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Axes {
    pub length: f64,
    pub risk: f64,
    pub vocals: f64,
}

impl Axes {
    pub fn of(style: Style) -> Axes {
        match style {
            Style::Easy => Axes { length: 1.0, risk: 0.1, vocals: 0.0 },
            Style::Normal => Axes { length: 0.6, risk: 0.5, vocals: 0.2 },
            Style::Bold => Axes { length: 0.2, risk: 0.9, vocals: 0.5 },
        }
    }
    fn long_options(&self) -> &'static [u32] {
        if self.length >= 0.8 {
            &[16, 32, 64]
        } else if self.length >= 0.4 {
            &[16, 32]
        } else {
            &[8, 16]
        }
    }
    fn short(&self) -> u32 {
        if self.length >= 0.4 { 16 } else { 8 }
    }
}

/// A key move as DJs read the wheel.
#[derive(Clone, Debug, PartialEq)]
pub struct KeyMove {
    pub score: f64,
    /// A tone or a semitone up: an energy move.
    pub boost: bool,
    pub clash: bool,
    pub why: Option<String>,
}

/// The key move from `a` to `b` (SetPlanner.keyMove): weighed towards "nothing to say"
/// (0.5) as the house is less sure of either key.
pub fn key_move(a: &Timing, b: &Timing) -> KeyMove {
    let none = KeyMove { score: 0.5, boost: false, clash: false, why: None };
    let (Some(ca), Some(cb)) = (a.camelot.as_deref(), b.camelot.as_deref()) else { return none };
    let parse = |c: &str| -> Option<(i64, char)> {
        let l = c.chars().last()?;
        Some((c[..c.len() - 1].parse().ok()?, l))
    };
    let (Some((na, la)), Some((nb, lb))) = (parse(ca), parse(cb)) else { return none };
    let same = la == lb;
    let d = (nb - na).rem_euclid(12);
    let (score, boost, clash, words) = match (d, same) {
        (0, true) => (1.0, false, false, "the same key"),
        (0, false) => (0.9, false, false, "relative major and minor"),
        (1 | 11, true) => (0.85, false, false, "a fifth apart"),
        (2, true) => (0.6, true, false, "a tone up: a boost"),
        (7, true) => (0.55, true, false, "a semitone up: a boost"),
        (10, true) => (0.4, false, false, "a tone down"),
        (5, true) => (0.35, false, false, "a semitone down"),
        _ => (0.15, false, true, "keys clash"),
    };
    let conf = a.key_confidence.min(b.key_confidence);
    let w = ((conf - 0.1) / 0.4).clamp(0.0, 1.0);
    if w == 0.0 {
        return none;
    }
    KeyMove { score: 0.5 + (score - 0.5) * w, boost: boost && w >= 0.5, clash: clash && w >= 0.5, why: Some(format!("{words} ({ca}→{cb})")) }
}

/// How much the planner likes each move, and whether it is a calm one.
fn likes(kind: Transition) -> Option<(f64, bool)> {
    use Transition as T;
    Some(match kind {
        T::Blend => (0.8, true),
        T::StemBlend => (0.9, true),
        T::FilterRide => (0.65, true),
        T::Sweep => (0.6, true),
        T::Fade => (0.3, true),
        T::Announce => (0.9, false),
        T::AcapellaOut => (0.75, false),
        T::DropSwap => (0.85, false),
        T::BreakSwap => (0.9, false),
        T::LoopBuild => (0.7, false),
        T::EchoOut => (0.6, false),
        T::Roll => (0.5, false),
        T::Swap => (0.6, false),
        T::Brake => (0.4, false),
        T::Riser => (0.85, false),
        T::NoiseSweep => (0.7, true),
        T::Hydrant => (0.7, false),
        T::Dissolve => (0.6, true),
        T::LunarEcho => (0.65, false),
        T::Tremolo => (0.7, false),
        T::Cut => return None,
    })
}

/// What the booth can do here.
#[derive(Clone, Copy, Debug)]
pub struct Can {
    /// Play a sound of its own.
    pub sound: bool,
    /// Chop a record.
    pub gate: bool,
}

/// Every move that fits, best first (v1's Planner.options). `taste`: this person's
/// leaning towards a kind (−0.3..0.3); `chance`: 0..1 draws.
pub fn options(
    from: MixSide,
    to: MixSide,
    style: Style,
    axes: Option<Axes>,
    recent: &[Transition],
    can: Can,
    taste: &dyn Fn(Transition) -> f64,
    chance: &mut dyn FnMut() -> f64,
) -> Vec<MixPlan> {
    let dials = axes.unwrap_or(Axes::of(style));
    let (base, base_bars) = mix::choose(Some(from.timing), Some(to.timing), style, from.pitch);
    if base == Transition::Fade || base == Transition::Cut || !from.timing.has_beats() || !to.timing.has_beats() {
        let past = clear_of_voices(&from, &to, base_bars, None);
        let mut bars = base_bars;
        let mut words = vec!["the only way these two go together".to_string()];
        if past.is_some() {
            words.push("in past its voice".into());
        } else if base == Transition::Fade && clash(&from, &to, bars, None, None) > bars as usize / 2 {
            bars = (bars / 2).max(2);
            words.push("short: both singing".into());
        }
        return vec![MixPlan { kind: base, bars, out_at: None, in_at: past, shift: 0.0, why: words.join(" · "), score: 0.0 }];
    }
    let key = key_move(from.timing, to.timing);
    let in_key = !key.clash;
    let mend = if key.clash && to.fx { shift_to_fit(from.timing, to.timing) } else { None };
    let stems = from.stems && to.stems;
    let intro = bars_between(to.timing, to.timing.first_downbeat, to.timing.mix_in);
    let outro = bars_between(from.timing, from.timing.mix_out, from.timing.sound_end);
    let longest = |opts: &[u32], room: u32| opts.iter().copied().filter(|&b| b <= room.max(opts[0])).fold(opts[0], u32::max);
    let mut cands: Vec<MixPlan> = vec![];
    let mut consider = |kind: Transition, bars: u32, fit: f64, why: &str, out_at: Option<f64>, in_at: Option<f64>, designed: bool, shift: f64| {
        let Some((like, calm)) = likes(kind) else { return };
        let mut score = like * if calm { 0.4 + 0.6 * (1.0 - dials.risk) } else { 0.4 + 0.6 * dials.risk } * fit;
        let mut words = vec![why.to_string()];
        let mut in_at = in_at;
        if !designed {
            let mut c = clash(&from, &to, bars, out_at, in_at);
            if c > 0 && in_at.is_none() && dials.vocals < 0.7 {
                if let Some(past) = clear_of_voices(&from, &to, bars, out_at) {
                    let less = clash(&from, &to, bars, out_at, Some(past));
                    if less < c {
                        c = less;
                        in_at = Some(past);
                        words.push("in past its voice".into());
                    }
                }
            }
            if c > 0 {
                score *= 1.0 - 0.8 * (1.0 - dials.vocals) * (c as f64 / bars as f64).clamp(0.0, 1.0);
                words.push(format!("{c} bars of two voices"));
            }
        }
        if recent.last() == Some(&kind) {
            score -= 0.4;
        }
        if recent.len() > 1 && recent[recent.len().saturating_sub(4)..].contains(&kind) {
            score -= 0.12;
        }
        if shift != 0.0 {
            score *= 0.55;
            words.push(format!("{}{} semitone{} to meet the key", if shift > 0.0 { "+" } else { "" }, shift.round(), if shift.abs() == 1.0 { "" } else { "s" }));
        } else if !in_key && !matches!(kind, Transition::Sweep | Transition::FilterRide | Transition::DropSwap | Transition::Hydrant | Transition::LunarEcho) {
            score -= 0.2;
        }
        if key.boost && !designed && kind != Transition::Sweep
            && let Some(w) = &key.why
        {
            words.push(w.clone());
        }
        let leaning = taste(kind);
        if leaning.abs() >= 0.03 {
            score += leaning;
            words.push(if leaning > 0.0 { "one you like" } else { "one you tend not to" }.into());
        }
        score += chance() * 0.22;
        cands.push(MixPlan { kind, bars, out_at, in_at, shift, why: words.join(" · "), score });
    };
    macro_rules! mended {
        ($kind:expr, $bars:expr, $fit:expr, $why:expr) => {{
            consider($kind, $bars, $fit, $why, None, None, false, 0.0);
            if let Some(m) = mend {
                consider($kind, $bars, $fit, $why, None, None, false, m);
            }
        }};
    }
    let room = intro.min(outro);
    mended!(Transition::Blend, longest(dials.long_options(), room), 1.0, "the ordinary blend");
    if stems {
        let opts: &[u32] = if dials.length >= 0.4 { &[32, 64] } else { &[16] };
        mended!(Transition::StemBlend, longest(opts, room), 1.0, "stem by stem, nothing doubled");
    }
    consider(Transition::Sweep, dials.short(), if in_key { 0.8 } else { 1.1 }, if in_key { "through the filter" } else { "keys clash: out through the filter" }, None, None, false, 0.0);
    if room >= 16 {
        consider(Transition::FilterRide, longest(&[16, 32], room), if in_key { 0.85 } else { 1.0 }, "a long ride through the filters, both ways", None, None, false, 0.0);
    }
    if from.fx {
        mended!(Transition::EchoOut, dials.short(), 0.9, "goes out on its echo");
        consider(Transition::Dissolve, longest(&[16, 32], room), 0.85, "the old record evaporates into its echo", None, None, false, 0.0);
        consider(
            Transition::LunarEcho,
            dials.short(),
            if in_key { 0.8 } else { 1.05 },
            if in_key { "let go of, falling, into its echo" } else { "keys clash: pulled down out of the way and left ringing" },
            None,
            None,
            false,
            0.0,
        );
    }
    if stems {
        let bars = if dials.length >= 0.8 { 32 } else { 16 };
        if let Some(hook_at) = announce_from(&to)
            && room_after(to.timing, hook_at, bars + 32)
        {
            let why = match to.vocals.and_then(|v| v.hook.as_ref()).filter(|h| !h.1.is_empty()) {
                Some((text, _)) => format!("\"{}\" over the beat before", short(text)),
                None => "its voice first, over the beat before".into(),
            };
            consider(Transition::Announce, bars, 1.1, &why, None, Some(hook_at), true, 0.0);
        }
        if let Some(sung_out) = last_sung(&from, 16)
            && quiet_start(&to, 16)
        {
            consider(Transition::AcapellaOut, 16, 1.05, "goes out singing over the next intro", Some(sung_out), None, true, 0.0);
        }
    }
    let drop = to.timing.drop_after(to.timing.first_downbeat.unwrap_or(0.0));
    let short_bars = dials.short();
    if let Some(drop) = drop.filter(|&d| room_before(to.timing, d, short_bars)) {
        consider(Transition::DropSwap, short_bars, 1.1, "lands on its drop", None, Some(in_before(to.timing, drop, short_bars)), false, 0.0);
        if in_key && room_before(to.timing, drop, 8) {
            consider(Transition::Roll, 8, 0.9, "rolled into its drop", None, Some(in_before(to.timing, drop, 8)), false, 0.0);
        }
        if room_before(to.timing, drop, 16) {
            consider(Transition::LoopBuild, 16, 1.0, "looped up into its drop", None, Some(in_before(to.timing, drop, 16)), false, 0.0);
        }
        if let Some((start, bars)) = breakdown_ahead(&from) {
            let bars = bars.clamp(8, 32);
            if room_before(to.timing, drop, bars) {
                consider(Transition::BreakSwap, bars, 1.15, "its breakdown under the next one's drop", Some(start), Some(in_before(to.timing, drop, bars)), false, 0.0);
            }
        }
    }
    if can.sound {
        let rb = if dials.length >= 0.4 { 16 } else { 8 };
        let landing = drop.filter(|&d| room_before(to.timing, d, rb)).map(|d| in_before(to.timing, d, rb));
        consider(
            Transition::Riser,
            rb,
            if landing.is_some() { 1.2 } else { 0.9 },
            if landing.is_some() { "built up into its drop" } else { "built up, and the sound does the work" },
            None,
            landing,
            false,
            0.0,
        );
        consider(Transition::NoiseSweep, short_bars, 0.95, "a whoosh over the change", None, None, false, 0.0);
        consider(
            Transition::Hydrant,
            short_bars,
            if in_key { 0.85 } else { 1.1 },
            if in_key { "the join made inside the noise" } else { "keys clash: the join made inside the noise" },
            None,
            None,
            false,
            0.0,
        );
    }
    if can.gate {
        consider(Transition::Tremolo, short_bars, 0.9, "chopped away in time with itself", None, None, false, 0.0);
    }
    if from.timing.ends == "cold" {
        consider(Transition::Brake, 8, 1.0, "stopped dead on a cold ending", None, None, false, 0.0);
    }
    if stems {
        consider(Transition::Swap, 16, if in_key { 1.0 } else { 0.8 }, "the drums change hands", None, None, false, 0.0);
    }
    if cands.is_empty() {
        return vec![MixPlan { kind: base, bars: base_bars, out_at: None, in_at: None, shift: 0.0, why: "the ordinary way".into(), score: 0.0 }];
    }
    cands.sort_by(|a, b| b.score.total_cmp(&a.score));
    cands
}

/// The semitones (+1 or −1) that put `to` in a key that sits with `from`'s.
fn shift_to_fit(from: &Timing, to: &Timing) -> Option<f64> {
    let c = to.camelot.as_deref()?;
    let letter = c.chars().last()?;
    let n: i64 = c[..c.len() - 1].parse().ok()?;
    for (semis, steps) in [(1i64, 7i64), (-1, 5)] {
        let shifted = Timing { camelot: Some(format!("{}{letter}", (n - 1 + steps).rem_euclid(12) + 1)), key_confidence: to.key_confidence, ..Timing::default() };
        let m = key_move(from, &shifted);
        if !m.clash && !m.boost && m.score >= 0.7 {
            return Some(semis as f64);
        }
    }
    None
}

fn short(s: &str) -> String {
    if s.chars().count() > 40 { format!("{}…", s.chars().take(38).collect::<String>()) } else { s.to_string() }
}

fn in_before(t: &Timing, drop: f64, bars: u32) -> f64 {
    let bar = t.bar().unwrap_or(2.0);
    let at = (drop - bar * bars as f64).max(t.first_downbeat.unwrap_or(0.0));
    t.on_grid(at, 1)
}

/// The outgoing's next breakdown, more than 8 s ahead: where it starts and its bars.
fn breakdown_ahead(from: &MixSide) -> Option<(f64, u32)> {
    let now = from.position.unwrap_or(0.0);
    let bar = from.timing.bar()?;
    from.timing
        .sections
        .iter()
        .find(|s| s.label == "breakdown" && s.start > now + 8.0)
        .map(|s| (s.start, ((s.end - s.start) / bar).round().max(1.0) as u32))
}

fn room_before(t: &Timing, at: f64, bars: u32) -> bool {
    t.bar().is_some_and(|bar| at - bar * bars as f64 >= t.first_downbeat.unwrap_or(0.0))
}

fn room_after(t: &Timing, at: f64, bars: u32) -> bool {
    let Some(bar) = t.bar() else { return false };
    t.mix_out.filter(|&e| e > 0.0).is_none_or(|end| at + bar * bars as f64 <= end)
}

fn bars_between(t: &Timing, a: Option<f64>, b: Option<f64>) -> u32 {
    match (a, b, t.bar()) {
        (Some(a), Some(b), Some(bar)) if b > a => ((b - a) / bar).floor() as u32,
        _ => 0,
    }
}

/// The record's downbeats (bar starts), seconds.
fn downbeats(t: &Timing) -> Vec<f64> {
    let g = &t.grid;
    g.beats.iter().enumerate().filter(|(i, _)| g.is_bar(*i)).map(|(_, &b)| b).collect()
}

fn bar_of(t: &Timing, at: f64) -> i64 {
    let d = downbeats(t);
    (d.partition_point(|&b| b <= at + 1e-6) as i64 - 1).max(0)
}

/// Bars of two voices at once, the outgoing from `out_at` (its outro), the incoming
/// from `in_at` (where it would come in).
fn clash(from: &MixSide, to: &MixSide, bars: u32, out_at: Option<f64>, in_at: Option<f64>) -> usize {
    let (Some(fv), Some(tv)) = (from.vocals.filter(|v| v.bars.is_some()), to.vocals.filter(|v| v.bars.is_some())) else { return 0 };
    let Some(out) = out_at.or(from.timing.mix_out) else { return 0 };
    let inn = in_at.unwrap_or_else(|| mix::in_point(to.timing, bars, false));
    let (f0, t0) = (bar_of(from.timing, out), bar_of(to.timing, inn));
    (0..bars as i64).filter(|i| fv.sung_at(f0 + i) && tv.sung_at(t0 + i)).count()
}

/// A later in point for the incoming where its voice does not land on the outgoing's,
/// on a marker where one will do.
fn clear_of_voices(from: &MixSide, to: &MixSide, bars: u32, out_at: Option<f64>) -> Option<f64> {
    let (fv, tv) = (from.vocals.filter(|v| v.bars.is_some())?, to.vocals.filter(|v| v.bars.is_some())?);
    let downs = downbeats(to.timing);
    if downs.is_empty() || to.timing.bar().is_none() {
        return None;
    }
    let usual = mix::in_point(to.timing, bars, false);
    if clash(from, to, bars, out_at, Some(usual)) == 0 {
        return None;
    }
    let out = out_at.or(from.timing.mix_out)?;
    let f0 = bar_of(from.timing, out);
    let start = bar_of(to.timing, usual);
    let tv_len = tv.bars.as_ref().map_or(0, |b| b.len()) as i64;
    let mut t0 = start + 1;
    while t0 <= start + 32 && t0 + bars as i64 <= tv_len {
        if t0 as usize >= downs.len() {
            break;
        }
        let n = (0..bars as i64).filter(|i| fv.sung_at(f0 + i) && tv.sung_at(t0 + i)).count();
        if n == 0 {
            let at = downs[t0 as usize];
            if !mix::quiet_bars(to.timing, at, bars as usize) {
                let Some(marker) = to.timing.marker_at_or_before(at) else { return Some(to.timing.on_grid(at, 1)) };
                if (marker - at).abs() < 1e-6 {
                    return Some(marker);
                }
                let Some(&m) = to.timing.markers.iter().find(|&&m| m >= at) else { return Some(to.timing.on_grid(at, 1)) };
                let mb = bar_of(to.timing, m);
                if (0..bars as i64).all(|i| !(fv.sung_at(f0 + i) && tv.sung_at(mb + i))) {
                    return Some(to.timing.on_grid(m, 4));
                }
            }
        }
        t0 += 1;
    }
    None
}

/// Where the incoming's voice comes first in earnest (its hook, else six bars sung in
/// eight), on the marker before.
fn announce_from(to: &MixSide) -> Option<f64> {
    let v = to.vocals?;
    if let Some((_, at)) = v.hook.as_ref().filter(|h| !h.1.is_empty()) {
        return to.timing.marker_at_or_before(at[0]);
    }
    let bars = v.bars.as_ref()?;
    let start = bar_of(to.timing, to.timing.first_downbeat.unwrap_or(0.0));
    let d = downbeats(to.timing);
    let mut i = start;
    while i + 8 <= bars.len() as i64 {
        if v.sung_in(i, i + 8) >= 6 {
            return d.get(i as usize).and_then(|&b| to.timing.marker_at_or_before(b));
        }
        i += 1;
    }
    None
}

/// Where the outgoing last sings for most of `bars`, near its end.
fn last_sung(from: &MixSide, bars: u32) -> Option<f64> {
    let v = from.vocals?;
    let b = v.bars.as_ref()?;
    let d = downbeats(from.timing);
    let last = from.timing.sound_end.map_or(b.len() as i64, |e| (b.len() as i64).min(bar_of(from.timing, e)));
    let bars = bars as i64;
    let mut i = last - bars;
    while i >= last - bars * 5 && i >= 0 {
        if v.sung_in(i, i + bars) as f64 >= bars as f64 * 0.6 && (i as usize) < d.len() {
            return from.timing.marker_at_or_before(d[i as usize]);
        }
        i -= 1;
    }
    None
}

fn quiet_start(to: &MixSide, bars: u32) -> bool {
    let Some(v) = to.vocals.filter(|v| v.bars.is_some()) else { return true };
    let start = bar_of(to.timing, to.timing.first_downbeat.unwrap_or(0.0));
    v.sung_in(start, start + bars as i64) <= bars as usize / 4
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Grid;
    use crate::mix::Section;

    /// 128 bpm, 112 bars: intro to 16, a drop at 32, a breakdown 64–80, outro from 96.
    fn timing(camelot: &str) -> Timing {
        let spb = 60.0 / 128.0;
        let grid = Grid::new((0..448).map(|i| 0.5 + i as f64 * spb).collect(), 0);
        let bar = |n: f64| 0.5 + n * 4.0 * spb;
        let mut t = Timing::from_grid(grid, bar(112.0) + 1.0);
        t.camelot = Some(camelot.into());
        t.key_confidence = 0.8;
        t.first_downbeat = Some(bar(0.0));
        t.mix_in = Some(bar(16.0));
        t.mix_out = Some(bar(96.0));
        t.sound_end = Some(bar(112.0));
        t.drops = vec![bar(32.0)];
        t.markers = (0..28).map(|i| bar(i as f64 * 4.0)).collect();
        t.phrases = vec![bar(0.0), bar(16.0), bar(32.0), bar(64.0), bar(96.0)];
        t.sections = vec![Section { label: "breakdown".into(), start: bar(64.0), end: bar(80.0) }];
        t
    }

    fn side(t: &Timing, stems: bool) -> MixSide<'_> {
        MixSide { timing: t, vocals: None, stems, pitch: 1.0, fx: true, position: Some(10.0) }
    }

    fn opts(a: &Timing, b: &Timing, stems: bool, style: Style) -> Vec<MixPlan> {
        let mut n = 0.0;
        options(side(a, stems), side(b, stems), style, None, &[], Can { sound: true, gate: true }, &|_| 0.0, &mut || {
            n += 0.0;
            n
        })
    }

    #[test]
    fn the_wheel() {
        let (a, b) = (timing("8A"), timing("9A"));
        assert_eq!(key_move(&a, &b).score, 0.5 + (0.85 - 0.5) * 1.0);
        let up = key_move(&a, &timing("10A"));
        assert!(up.boost && !up.clash);
        let c = key_move(&a, &timing("3B"));
        assert!(c.clash);
        // unsure keys say nothing
        let mut unsure = timing("3B");
        unsure.key_confidence = 0.05;
        assert_eq!(key_move(&a, &unsure).score, 0.5);
    }

    #[test]
    fn every_kind_that_fits_is_considered() {
        let (a, b) = (timing("8A"), timing("9A"));
        let all: Vec<Transition> = opts(&a, &b, true, Style::Normal).iter().map(|p| p.kind).collect();
        for k in [
            Transition::Blend,
            Transition::StemBlend,
            Transition::Sweep,
            Transition::FilterRide,
            Transition::EchoOut,
            Transition::Dissolve,
            Transition::LunarEcho,
            Transition::DropSwap,
            Transition::Roll,
            Transition::LoopBuild,
            Transition::BreakSwap,
            Transition::Riser,
            Transition::NoiseSweep,
            Transition::Hydrant,
            Transition::Tremolo,
            Transition::Swap,
        ] {
            assert!(all.contains(&k), "{k:?} considered: {all:?}");
        }
        let no_stems: Vec<Transition> = opts(&a, &b, false, Style::Normal).iter().map(|p| p.kind).collect();
        assert!(!no_stems.iter().any(|k| k.needs_stems()), "no stems, no stem moves: {no_stems:?}");
    }

    #[test]
    fn calm_styles_like_calm_moves_and_bold_ones_wild() {
        let (a, b) = (timing("8A"), timing("9A"));
        let easy = opts(&a, &b, false, Style::Easy);
        let bold = opts(&a, &b, false, Style::Bold);
        let calm = |p: &MixPlan| likes(p.kind).unwrap().1;
        assert!(calm(&easy[0]), "easy: {}", easy[0].kind.word());
        assert!(!calm(&bold[0]), "bold: {}", bold[0].kind.word());
    }

    #[test]
    fn a_clash_mends_or_filters() {
        let (a, b) = (timing("8A"), timing("3B"));
        let best = &opts(&a, &b, false, Style::Normal)[0];
        assert!(
            best.shift != 0.0 || matches!(best.kind, Transition::Sweep | Transition::FilterRide | Transition::DropSwap | Transition::Hydrant | Transition::LunarEcho),
            "clashing keys: {} {}",
            best.kind.word(),
            best.why
        );
    }

    #[test]
    fn voices_keep_apart() {
        let (a, b) = (timing("8A"), timing("9A"));
        // the outgoing sings through its outro; the incoming from its first bar to 24
        let sung = |from: usize, to: usize| VocalMap { bars: Some((0..112).map(|i| if i >= from && i < to { 200 } else { 0 }).collect()), hook: None };
        let (va, vb) = (sung(90, 112), sung(0, 24));
        let f = MixSide { vocals: Some(&va), ..side(&a, false) };
        let t = MixSide { vocals: Some(&vb), ..side(&b, false) };
        assert!(clash(&f, &t, 16, None, None) > 0, "two voices if it came in as usual");
        let past = clear_of_voices(&f, &t, 16, None).expect("a later in point");
        assert_eq!(clash(&f, &t, 16, None, Some(past)), 0, "past its voice: none");
    }
}
