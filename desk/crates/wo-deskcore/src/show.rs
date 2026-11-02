//! The show's decisions in the Desk (plan §2.1: the Desk decides, the stage draws): the
//! director (wo_show::engine::Direct) over the decks as the Desk plays them, each deck's
//! record as facts for it and for the stages (ShowWire v2's `record`), and its decision as a
//! `cue`. A v1 stage directs itself and ignores these lines; the Rust stage (apps/
//! wetowl-stage) draws what they say.
use std::time::Instant;

use wo_booth::Timing;
use wo_show::deck::{RecordFacts, Section};
use wo_show::doc::ShowDoc;
use wo_show::engine::{Cue, Direct};
use wo_show::scenes::{DRAWN, SceneBook};
use wo_show::scores::ComboScores;
use wo_wire::Hand;

use crate::records::{Audio, Record};

/// The plan, the sets and the director's temper: the WetOwl app's show.json, read (never
/// written) while v1 keeps it; the show as shipped where there is none.
fn v1_doc() -> ShowDoc {
    crate::records::fetched_dir()
        .and_then(|f| f.parent().map(|p| p.join("show.json")))
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| ShowDoc::parse(&t))
        .unwrap_or_default()
}

/// The house's id of a record, as the Desk's frame names it (none for one made here).
pub(crate) fn track_id(r: &Record) -> Option<i64> {
    (r.id > 0 && !matches!(r.audio, Audio::Synth { .. })).then_some(r.id)
}

/// A record's facts for the show, from what the Desk plays it by.
pub(crate) fn facts_of(r: &Record, t: &Timing) -> RecordFacts {
    let ms = |s: f64| s * 1000.0;
    let beats: Vec<f64> = t.grid.beats.iter().map(|&b| ms(b)).collect();
    let bar_one = t.grid.bar_one;
    // a steady grid where the beats lie on a line (a synthesised record, a fitted file)
    let steady = (beats.len() >= 8)
        .then(|| {
            let n = beats.len() as f64;
            let sx: f64 = (0..beats.len()).map(|i| i as f64).sum();
            let sy: f64 = beats.iter().sum();
            let sxx: f64 = (0..beats.len()).map(|i| (i * i) as f64).sum();
            let sxy: f64 = beats.iter().enumerate().map(|(i, y)| i as f64 * y).sum();
            let period = (n * sxy - sx * sy) / (n * sxx - sx * sx);
            let origin = (sy - period * sx) / n;
            let off = beats.iter().enumerate().map(|(i, b)| (b - origin - period * i as f64).abs()).fold(0.0, f64::max);
            (period > 0.0 && off < 12.0).then_some((origin, period))
        })
        .flatten();
    let downbeats: Vec<f64> = beats.iter().enumerate().filter(|(i, _)| *i >= bar_one && (i - bar_one).is_multiple_of(4)).map(|(_, &b)| b).collect();
    let sections: Vec<Section> = t.sections.iter().map(|s| Section { label: s.label.clone(), start_ms: ms(s.start), end_ms: ms(s.end) }).collect();
    // the bars' loudness: the analysis's, else the sections' shape
    let energy = if !t.energy.is_empty() {
        t.energy.clone()
    } else if !sections.is_empty() {
        downbeats
            .iter()
            .map(|&d| match sections.iter().find(|s| d >= s.start_ms && d < s.end_ms).map(|s| s.label.as_str()) {
                Some("drop" | "chorus") => 230,
                Some("build") => 170,
                Some("breakdown" | "break") => 90,
                Some("intro" | "outro") => 110,
                _ => 150,
            })
            .collect()
    } else {
        vec![]
    };
    RecordFacts {
        track_id: track_id(r),
        title: Some(r.title.clone()).filter(|s| !s.is_empty()),
        artist: Some(r.artist.clone()).filter(|s| !s.is_empty()),
        beats_ms: beats,
        steady,
        bar_starts_on: (bar_one % 4) as i64,
        downbeats_ms: downbeats,
        markers_ms: t.markers.iter().map(|&m| ms(m)).collect(),
        energy,
        drops_ms: t.drops.iter().map(|&d| ms(d)).collect(),
        sections,
        key: None,
        camelot: t.camelot.clone().or_else(|| Some(r.key.clone()).filter(|k| !k.is_empty())),
        vocal_bars: None,
        hook_ms: vec![],
        cover_rgb: None,
    }
}

pub(crate) struct Show {
    pub(crate) direct: Direct,
    facts: [Option<RecordFacts>; 2],
    last: Option<Instant>,
    said: String,
}

impl Show {
    /// The director over the scenes the Rust stage draws.
    pub(crate) fn new() -> Show {
        let book = SceneBook::shipped().only(DRAWN);
        let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(7, |d| d.as_secs());
        let direct = Direct::new(&book, v1_doc(), ComboScores::shipped(), seed);
        Show { direct, facts: [None, None], last: None, said: String::new() }
    }

    /// A deck's record as facts: the line to say when they changed.
    pub(crate) fn record(&mut self, deck: usize, facts: Option<RecordFacts>) -> Option<String> {
        if self.facts[deck] == facts {
            return None;
        }
        self.facts[deck] = facts;
        Some(wo_wire::v2::record(["A", "B"][deck], self.facts[deck].as_ref()))
    }

    /// One frame of the Desk: the director's cue, as a line when it changed.
    pub(crate) fn tick(&mut self, frame: &wo_wire::Frame) -> Option<String> {
        let now = Instant::now();
        let dt = self.last.map_or(1.0 / 60.0, |t| (now - t).as_secs_f64().min(0.25));
        self.last = Some(now);
        let room = wo_wire::v2::room(frame, [self.facts[0].as_ref(), self.facts[1].as_ref()], 0.0);
        let (cue, _) = self.direct.tick(dt, room, Default::default());
        let line = wo_wire::v2::cue(&cue);
        if line == self.said {
            return None;
        }
        self.said = line.clone();
        Some(line)
    }

    pub(crate) fn cue(&self) -> &Cue {
        self.direct.cue()
    }

    /// A hand on the show, as the director takes it.
    pub(crate) fn hand(&mut self, h: &Hand) {
        let d = &mut self.direct;
        match h {
            Hand::Hit => d.hit(),
            Hand::Next => d.next(1),
            Hand::Previous => d.next(-1),
            Hand::Mosh => d.mosh_next(),
            Hand::Hold(on) => d.hold(*on),
            Hand::LetGo => d.hold(false),
            Hand::Blackout(on) => d.macros.blackout = *on,
            Hand::Strobe(on) => d.macros.strobe = if *on { 1.0 } else { 0.0 },
            Hand::Freeze(on) => d.macros.freeze = *on,
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wo_booth::Grid;

    #[test]
    fn a_synthesised_record_reads_as_steady_facts() {
        let spb = 60.0 / 128.0;
        let beats: Vec<f64> = (0..256).map(|i| 0.1 + i as f64 * spb).collect();
        let mut t = Timing::from_grid(Grid::new(beats, 1), 120.0);
        t.sections = vec![wo_booth::mix::Section { label: "drop".into(), start: 0.0, end: 60.0 }, wo_booth::mix::Section { label: "breakdown".into(), start: 60.0, end: 120.0 }];
        let r = Record { id: 0, title: "Loop".into(), artist: String::new(), bpm: 128.0, key: "8A".into(), seconds: 120, audio: Audio::Synth { seed: 1 } };
        let f = facts_of(&r, &t);
        assert_eq!(f.track_id, None);
        let (origin, period) = f.steady.unwrap();
        assert!((origin - 100.0).abs() < 1e-6 && (period - spb * 1000.0).abs() < 1e-6);
        assert_eq!(f.bar_starts_on, 1);
        assert_eq!(f.downbeats_ms[0], f.beats_ms[1]);
        assert_eq!(f.energy.len(), f.downbeats_ms.len());
        assert_eq!((f.energy[0], *f.energy.last().unwrap()), (230, 90), "the sections' shape");
        assert_eq!(f.camelot.as_deref(), Some("8A"));
    }

    #[test]
    fn the_desk_directs_and_says_the_cue_only_when_it_changes() {
        let mut show = Show::new();
        let spb = 0.5;
        let r = Record { id: 0, title: "Loop".into(), artist: String::new(), bpm: 120.0, key: String::new(), seconds: 200, audio: Audio::Synth { seed: 1 } };
        let t = Timing::from_grid(Grid::new((0..400).map(|i| i as f64 * spb).collect(), 0), 200.0);
        let line = show.record(0, Some(facts_of(&r, &t))).expect("the record said");
        assert!(line.starts_with(r#"{"t":"record","deck":"A""#), "{line}");
        assert!(show.record(0, Some(facts_of(&r, &t))).is_none(), "said once");
        let frame = wo_wire::Frame { a: wo_wire::Deck { playing: true, position_ms: 4000.0, rate: 1.0, level: 1.0, ..Default::default() }, ..Default::default() };
        let first = show.tick(&frame).expect("a first cue");
        assert!(first.contains(r#""t":"cue""#));
        assert!(DRAWN.contains(&show.cue().scene.as_deref().unwrap()));
        assert!(show.tick(&frame).is_none(), "nothing new");
        show.hand(&Hand::Blackout(true));
        assert!(show.tick(&frame).unwrap().contains(r#""blackout":true"#));
    }
}
