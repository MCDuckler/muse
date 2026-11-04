//! The plan view (v1's console_plan.dart, key P): what the Auto DJ is about to do,
//! drawn out, with a hand on it. The two records as two lanes on one ruler of bars —
//! the one playing above, the one coming below, lined up the way the mix will line them
//! up — each with its phrases, how hard each bar hits, where the voice is, its drops,
//! sections and hook; over them the move itself (each side's level, stems, bass,
//! filter); beside it every move the planner weighed, best first, and why — any of them
//! chosen instead, made longer or shorter, or moved a phrase either way.
use std::thread;

use wo_booth::steps::{self, EqSet, Side, Step};
use wo_booth::Transition;
use wo_engine::DeckId;

use crate::autodj::LogKind;
use crate::records::{Audio, Record};
use crate::transition::{Running, law};
use crate::Desk;

/// One record's lane, in bars from where the move starts on it (its out point, or the
/// incoming's in point): negative before, `bars` at the move's end.
#[derive(Clone, Debug)]
pub struct Lane {
    pub record: Record,
    /// Seconds a bar of the record.
    pub bar: f64,
    /// The record's place (seconds) at bar 0.
    pub start: f64,
    /// How loud each bar is (dB, its start in lane bars).
    pub bars_db: Vec<(f64, f64)>,
    /// The bars it sings in (lane bars).
    pub sung: Vec<f64>,
    pub phrases: Vec<f64>,
    pub drops: Vec<f64>,
    /// Sections: label, from, to (lane bars).
    pub sections: Vec<(String, f64, f64)>,
    /// Where its hook is sung (lane bars), and its words.
    pub hook: Vec<f64>,
    pub hook_words: Option<String>,
    /// Where it is now (lane bars).
    pub now: f64,
}

/// The move at a point `k` (0..1) through it.
#[derive(Clone, Copy, Debug, Default)]
pub struct Curve {
    pub k: f64,
    /// Each side's level by the fader's law.
    pub from: f32,
    pub to: f32,
    /// Each side's stems (drums, rest, voice) where the move sets them.
    pub from_stems: Option<[f32; 3]>,
    pub to_stems: Option<[f32; 3]>,
    /// Each side's bass, dB (0 flat, −40 gone).
    pub from_low: f32,
    pub to_low: f32,
    /// Each side's filter, −1 (low-pass shut) .. 1 (high-pass shut).
    pub from_filter: f32,
    pub to_filter: f32,
}

/// A move the planner weighed.
#[derive(Clone, Debug)]
pub struct Option_ {
    pub kind: Transition,
    pub bars: u32,
    pub why: String,
    pub score: f64,
    pub chosen: bool,
}

#[derive(Clone, Debug)]
pub struct PlanView {
    pub from: usize,
    pub to: usize,
    pub kind: Transition,
    pub bars: u32,
    pub mixing: bool,
    pub progress: f64,
    pub why: String,
    pub lanes: [Lane; 2],
    pub curves: Vec<Curve>,
    pub options: Vec<Option_>,
    /// Bars of each record shown before the move and after it.
    pub context: f64,
}

/// The bands one side has at `k`: being turned, else the last set (flat before any).
fn eq_held(steps: &[Step], side: Side, k: f64, beat_k: f64) -> EqSet {
    steps::eq_at(steps, side, k, EqSet::FLAT, beat_k).unwrap_or_else(|| {
        steps.iter().take_while(|s| s.at <= k).filter_map(|s| s.deck(side).and_then(|d| d.eq)).last().unwrap_or(EqSet::FLAT)
    })
}

/// The move `kind` over `bars` sampled `n` times.
pub fn curves(kind: Transition, bars: u32, n: usize) -> Vec<Curve> {
    let run = Running::new(kind, bars);
    let st = &run.steps;
    let beat_k = 1.0 / (bars.max(1) as f64 * 4.0);
    (0..=n)
        .map(|i| {
            let k = i as f64 / n as f64;
            let (from, to) = law(steps::fader_at(st, k), kind.full());
            Curve {
                k,
                from,
                to,
                from_stems: steps::stems_at(st, Side::From, k).map(|l| l.as_array()),
                to_stems: steps::stems_at(st, Side::To, k).map(|l| l.as_array()),
                from_low: eq_held(st, Side::From, k, beat_k).low,
                to_low: eq_held(st, Side::To, k, beat_k).low,
                from_filter: steps::filter_at(st, Side::From, k).unwrap_or(0.0),
                to_filter: steps::filter_at(st, Side::To, k).unwrap_or(0.0),
            }
        })
        .collect()
}

impl Desk {
    fn lane(&self, d: usize, start: f64, now: f64) -> Lane {
        let s = &self.slots[d];
        let t = &s.timing;
        let bar = t.bar().unwrap_or(4.0 * self.spb(d));
        let rel = |x: f64| (x - start) / bar;
        let downbeats: Vec<f64> = t.grid.beats.iter().enumerate().filter(|(i, _)| t.grid.is_bar(*i)).map(|(_, &b)| b).collect();
        let sung = s
            .vocals
            .as_ref()
            .and_then(|v| v.bars.as_ref())
            .map(|b| b.iter().enumerate().filter(|(_, v)| **v >= wo_booth::planner::VocalMap::SUNG).filter_map(|(i, _)| downbeats.get(i).map(|&x| rel(x))).collect())
            .unwrap_or_default();
        let hook = s.vocals.as_ref().and_then(|v| v.hook.as_ref());
        // how hard each bar hits: the house's measure, else the Desk's own waveform
        let mut bars_db: Vec<(f64, f64)> = t.bars_db.iter().map(|&(x, db)| (rel(x), db)).collect();
        if bars_db.is_empty() {
            let wave = s.wave.lock().unwrap();
            let first = t.first_downbeat.unwrap_or(0.0);
            let mut at = first;
            while at < wave.seconds() {
                let a = wave.span(at, at + bar);
                let amp = (a[0] + a[1] + a[2]).max(1e-4) as f64;
                bars_db.push((rel(at), 20.0 * amp.log10() - 4.0));
                at += bar;
            }
        }
        Lane {
            record: s.record.clone(),
            bar,
            start,
            bars_db,
            sung,
            phrases: t.phrases.iter().map(|&x| rel(x)).collect(),
            drops: t.drops.iter().map(|&x| rel(x)).collect(),
            sections: t.sections.iter().map(|x| (x.label.clone(), rel(x.start), rel(x.end))).collect(),
            hook: hook.map(|h| h.1.iter().map(|&x| rel(x)).collect()).unwrap_or_default(),
            hook_words: hook.map(|h| h.0.clone()).filter(|w| !w.is_empty()),
            now: rel(now),
        }
    }

    /// The transition planned (or under way), drawn out.
    pub fn plan_view(&self) -> Option<PlanView> {
        let m = self.mix.as_ref()?;
        let (fd, td) = (DeckId::new(m.from).unwrap(), DeckId::new(m.to).unwrap());
        let from_now = self.engine.deck(fd).position();
        let to_now = self.engine.deck(td).position();
        let from = self.lane(m.from, m.out, from_now);
        // the incoming lines up with the outgoing's bar 0 at its in point: parked there,
        // or, once running, where it was when the move began
        let to_start = if m.started { to_now - (from_now - m.out) / from.bar * self.lane(m.to, 0.0, 0.0).bar } else { m.park };
        let to = self.lane(m.to, to_start, to_now);
        let options = m
            .options
            .iter()
            .map(|o| Option_ { kind: o.kind, bars: o.bars, why: o.why.clone(), score: o.score, chosen: o.kind == m.kind && o.bars == m.bars })
            .collect();
        Some(PlanView {
            from: m.from,
            to: m.to,
            kind: m.kind,
            bars: m.bars,
            mixing: m.started,
            progress: m.progress,
            why: m.why.clone(),
            lanes: [from, to],
            curves: curves(m.kind, m.bars, 96),
            options,
            context: (m.bars as f64 / 2.0).clamp(4.0, 16.0),
        })
    }

    /// A move the planner weighed, chosen by a hand: its kind and length, and where it
    /// would go out and come in.
    pub fn steer_option(&mut self, i: usize) {
        let Some(o) = self.mix.as_ref().filter(|m| !m.started).and_then(|m| m.options.get(i)).cloned() else { return };
        self.steer_move(o.kind, o.bars);
        let Some(m) = self.mix.as_ref() else { return };
        let (from, to) = (m.from, m.to);
        if let Some(at) = o.out_at {
            let at = self.slots[from].timing.on_grid(at, 4);
            if let Some(m) = self.mix.as_mut() {
                m.out = at;
            }
        }
        if let Some(at) = o.in_at {
            self.park_at(to, at);
        }
        if o.shift != 0.0 {
            self.slots[to].shift = o.shift as f32;
            self.engine.deck(DeckId::new(to).unwrap()).set_shift(o.shift);
        }
    }

    fn park_at(&mut self, to: usize, at: f64) {
        if let Some(m) = self.mix.as_mut() {
            m.park = at;
        }
        self.engine.deck(DeckId::new(to).unwrap()).seek(at);
    }

    /// The planned move over `bars` instead.
    pub fn set_bars(&mut self, bars: u32) {
        let Some(m) = self.mix.as_ref().filter(|m| !m.started) else { return };
        let kind = m.kind;
        self.steer_move(kind, bars.clamp(1, 64));
    }

    /// The outgoing goes out `phrases` four-bar phrases later (+) or sooner (−), and that
    /// is the record's out cue from now on (kept by the house).
    pub fn nudge_out(&mut self, phrases: i32) {
        self.later(phrases);
        if let Some(m) = self.mix.as_ref() {
            let (d, out) = (m.from, m.out);
            self.keep_cue(d, Some(out), None);
        }
    }

    /// The incoming comes in `phrases` four-bar phrases later (+) or sooner (−) in its
    /// record, and that is its in cue from now on.
    pub fn nudge_in(&mut self, phrases: i32) {
        let Some(m) = self.mix.as_ref().filter(|m| !m.started) else { return };
        let (to, park, bars) = (m.to, m.park, m.bars);
        let t = &self.slots[to].timing;
        let Some(bar) = t.bar() else { return };
        let first = t.first_downbeat.unwrap_or(0.0);
        let at = (park + bar * 4.0 * phrases as f64).max(first);
        if at > t.duration - bar * bars as f64 || (at - park).abs() < 1e-3 {
            return;
        }
        let at = t.on_grid(at, 1);
        self.park_at(to, at);
        let title = self.slots[to].record.title.clone();
        self.note(LogKind::Hand, format!("{title} comes in {} at {}", if at > park { "later" } else { "sooner" }, crate::autodj::clock(at)));
        self.keep_cue(to, None, Some(at));
    }

    /// Back to the planner's own choice: the move planned afresh.
    pub fn let_the_planner_choose(&mut self) {
        if self.mix.as_ref().is_none_or(|m| m.started) {
            return;
        }
        let to = self.mix.as_ref().unwrap().to;
        self.slots[to].stems.mix = None;
        self.mix = None;
        self.note(LogKind::Plan, "Back to the Auto DJ's own choice");
    }

    /// A hand's out / in cue kept on the record at the house.
    fn keep_cue(&mut self, d: usize, out: Option<f64>, inn: Option<f64>) {
        let rec = &self.slots[d].record;
        let (Some(house), Audio::House { id }) = (self.house.clone(), &rec.audio) else { return };
        let mut body = serde_json::json!({});
        if let Some(o) = out {
            body["out_ms"] = serde_json::json!((o * 1000.0) as i64);
            self.slots[d].timing.hand_out = Some(o);
        }
        if let Some(i) = inn {
            body["in_ms"] = serde_json::json!((i * 1000.0) as i64);
            self.slots[d].timing.hand_in = Some(i);
        }
        let id = *id;
        thread::spawn(move || {
            if let Err(e) = house.set_cues(id, &body) {
                eprintln!("cues of {id}: {e}");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_blends_curves() {
        let c = curves(Transition::Blend, 16, 64);
        assert_eq!(c.len(), 65);
        assert_eq!((c[0].from, c[0].to), (1.0, 0.0));
        assert!(c[0].to_low <= -39.0, "the incoming's bass out at the start");
        assert!(c[40].to_low > -1.0, "and back after half way");
        assert!((c[64].to - 1.0).abs() < 1e-6 && c[64].from.abs() < 1e-6);
        let s = curves(Transition::StemBlend, 32, 64);
        assert!(s[0].to_stems.is_some(), "a stem blend sets the stems");
        let f = curves(Transition::Sweep, 16, 64);
        assert!(f[48].from_filter > 0.4, "the outgoing climbs out through the high-pass");
    }
}
