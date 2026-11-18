//! What a record's waveforms carry beside its pads, the rekordbox way: its memory cues,
//! each hot cue's colour and name, and its phrases (rekordbox's own off a stick, else the
//! house's sections in rekordbox's words).
use wo_booth::Timing;

/// A hot cue's look: its colour (0xRRGGBB) and its name, where rekordbox gave them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PadLook {
    pub rgb: Option<u32>,
    pub name: String,
}

/// A phrase's kind, by rekordbox's words (it colours the phrase band).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhraseKind {
    Intro,
    Verse,
    Bridge,
    Chorus,
    Up,
    Down,
    Outro,
}

impl PhraseKind {
    /// A house section's label in rekordbox's words.
    pub fn of_label(label: &str) -> PhraseKind {
        let l = label.to_ascii_lowercase();
        if l.contains("intro") {
            PhraseKind::Intro
        } else if l.contains("outro") {
            PhraseKind::Outro
        } else if l.contains("drop") || l.contains("chorus") {
            PhraseKind::Chorus
        } else if l.contains("break") {
            PhraseKind::Down
        } else if l.contains("build") || l.contains("up") {
            PhraseKind::Up
        } else if l.contains("bridge") {
            PhraseKind::Bridge
        } else {
            PhraseKind::Verse
        }
    }

    fn of_usb(k: wo_usb::anlz::PhraseKind) -> PhraseKind {
        use wo_usb::anlz::PhraseKind as K;
        match k {
            K::Intro => PhraseKind::Intro,
            K::Verse(_) | K::Other(_) => PhraseKind::Verse,
            K::Bridge => PhraseKind::Bridge,
            K::Chorus => PhraseKind::Chorus,
            K::Up => PhraseKind::Up,
            K::Down => PhraseKind::Down,
            K::Outro => PhraseKind::Outro,
        }
    }

    /// rekordbox's word for it, as its phrase band says it.
    pub fn word(self) -> &'static str {
        match self {
            PhraseKind::Intro => "Intro",
            PhraseKind::Verse => "Verse",
            PhraseKind::Bridge => "Bridge",
            PhraseKind::Chorus => "Chorus",
            PhraseKind::Up => "Up",
            PhraseKind::Down => "Down",
            PhraseKind::Outro => "Outro",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Phrase {
    pub kind: PhraseKind,
    /// Its own name: rekordbox's ("Verse 2") or the house's section label.
    pub label: String,
    pub start: f64,
    pub end: f64,
}

/// A deck's record's marks.
#[derive(Clone, Debug, Default)]
pub struct Marks {
    /// rekordbox's memory cues, seconds.
    pub memory: Vec<f64>,
    /// Each hot cue's look (A–H), where the stick gave one.
    pub looks: [Option<PadLook>; 8],
    /// rekordbox's own phrases (PSSI), seconds; empty where it had none.
    pub phrases: Vec<Phrase>,
}

impl Marks {
    /// A stick's analysis: memory cues, hot cue looks, phrases (on its grid, `beats`).
    pub fn from_usb(a: &wo_usb::Analysis, beats: &[f64], seconds: f64) -> Marks {
        let mut m = Marks::default();
        for c in &a.cues {
            match c.kind {
                wo_usb::CueKind::Memory => m.memory.push(c.ms as f64 / 1000.0),
                wo_usb::CueKind::Hot(n) if (n as usize) < 8 && m.looks[n as usize].is_none() => {
                    m.looks[n as usize] = Some(PadLook { rgb: c.rgb, name: c.comment.clone() });
                }
                _ => {}
            }
        }
        if let Some(p) = &a.phrases {
            let at = |beat: u16| beats.get((beat as usize).saturating_sub(1)).copied();
            let end = at(p.end_beat).unwrap_or(seconds);
            for (i, x) in p.list.iter().enumerate() {
                let Some(start) = at(x.beat) else { break };
                let stop = p.list.get(i + 1).and_then(|n| at(n.beat)).unwrap_or(end);
                if stop > start {
                    m.phrases.push(Phrase { kind: PhraseKind::of_usb(x.kind), label: x.kind.name(), start, end: stop });
                }
            }
        }
        m
    }

    /// The phrases to draw: rekordbox's own, else the house's sections in its words.
    pub fn phrases_or(&self, timing: &Timing) -> Vec<Phrase> {
        if !self.phrases.is_empty() {
            return self.phrases.clone();
        }
        timing.sections.iter().filter(|s| s.end > s.start).map(|s| Phrase { kind: PhraseKind::of_label(&s.label), label: s.label.clone(), start: s.start, end: s.end }).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wo_usb::anlz::{Phrase as P, PhraseKind as K, Phrases};

    #[test]
    fn a_sticks_phrases_land_on_its_grid() {
        let beats: Vec<f64> = (0..256).map(|i| i as f64 * 0.5).collect();
        let a = wo_usb::Analysis {
            phrases: Some(Phrases { mood: 1, end_beat: 129, list: vec![P { beat: 1, kind: K::Intro, fill: None }, P { beat: 65, kind: K::Up, fill: None }, P { beat: 97, kind: K::Chorus, fill: None }] }),
            cues: vec![wo_usb::Cue { kind: wo_usb::CueKind::Memory, ms: 1500, loop_end_ms: None, rgb: None, comment: String::new() }, wo_usb::Cue { kind: wo_usb::CueKind::Hot(2), ms: 3000, loop_end_ms: None, rgb: Some(0xff0000), comment: "Vox".into() }],
            ..Default::default()
        };
        let m = Marks::from_usb(&a, &beats, 128.0);
        assert_eq!(m.memory, vec![1.5]);
        assert_eq!(m.looks[2], Some(PadLook { rgb: Some(0xff0000), name: "Vox".into() }));
        let p: Vec<_> = m.phrases.iter().map(|p| (p.kind, p.start, p.end)).collect();
        assert_eq!(p, vec![(PhraseKind::Intro, 0.0, 32.0), (PhraseKind::Up, 32.0, 48.0), (PhraseKind::Chorus, 48.0, 64.0)]);
    }

    #[test]
    fn house_labels_in_rekordbox_words() {
        for (l, k) in [("intro", PhraseKind::Intro), ("drop", PhraseKind::Chorus), ("breakdown", PhraseKind::Down), ("build", PhraseKind::Up), ("inst", PhraseKind::Verse), ("outro", PhraseKind::Outro)] {
            assert_eq!(PhraseKind::of_label(l), k, "{l}");
        }
    }
}
