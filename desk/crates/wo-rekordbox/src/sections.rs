//! rekordbox's phrases as the show's sections: the labels its director reacts to
//! (intro, verse, build, chorus, breakdown, break, outro) and where the drops are.
use wo_usb::anlz::{PhraseKind, Phrases};

/// One phrase, placed.
#[derive(Clone, Debug, PartialEq)]
pub struct Section {
    /// The show's word for it.
    pub label: &'static str,
    /// rekordbox's.
    pub name: PhraseKind,
    pub start_ms: f64,
    pub end_ms: f64,
}

/// A record's sections and drops.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Phrased {
    pub sections: Vec<Section>,
    /// Where a chorus comes in after an Up or a Down (high mood: rekordbox's "chorus" is the
    /// drop there), ms.
    pub drops_ms: Vec<f64>,
}

/// The show's label for a phrase.
pub fn label(name: PhraseKind) -> &'static str {
    match name {
        PhraseKind::Intro => "intro",
        PhraseKind::Up => "build",
        PhraseKind::Down => "breakdown",
        PhraseKind::Verse(_) | PhraseKind::Other(_) => "verse",
        PhraseKind::Bridge => "break",
        PhraseKind::Chorus => "chorus",
        PhraseKind::Outro => "outro",
    }
}

/// `beats` are the grid's, seconds (beat 1 is `beats[0]`); past the grid's end the last
/// beat's length carries on.
pub fn place(p: &Phrases, beats: &[f64]) -> Phrased {
    let at = |beat: u16| -> Option<f64> {
        let i = (beat as usize).checked_sub(1)?;
        if let Some(s) = beats.get(i) {
            return Some(s * 1000.0);
        }
        let n = beats.len();
        if n < 2 {
            return None;
        }
        let period = beats[n - 1] - beats[n - 2];
        Some((beats[n - 1] + period * (i + 1 - n) as f64) * 1000.0)
    };
    let mut out = Phrased::default();
    let mut prev: Option<PhraseKind> = None;
    for (i, ph) in p.list.iter().enumerate() {
        let name = ph.kind;
        let next = p.list.get(i + 1).map_or(p.end_beat, |n| n.beat);
        let (Some(start_ms), Some(end_ms)) = (at(ph.beat), at(next)) else { continue };
        if end_ms <= start_ms {
            continue;
        }
        if name == PhraseKind::Chorus && matches!(prev, Some(PhraseKind::Up | PhraseKind::Down)) {
            out.drops_ms.push(start_ms);
        }
        out.sections.push(Section { label: label(name), name, start_ms, end_ms });
        prev = Some(name);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use wo_usb::anlz::Phrase;

    /// A phrase as rekordbox numbers its kinds for mood (1 high, 2 mid).
    fn ph(mood: u16, beat: u16, kind: u16) -> Phrase {
        let kind = match (mood, kind) {
            (1, 1) => PhraseKind::Intro,
            (1, 2) => PhraseKind::Up,
            (1, 3) => PhraseKind::Down,
            (1, 5) => PhraseKind::Chorus,
            (_, 1) => PhraseKind::Intro,
            (_, n @ 2..=7) => PhraseKind::Verse(n as u8 - 1),
            (_, 8) => PhraseKind::Bridge,
            (_, 9) => PhraseKind::Chorus,
            (_, n) => PhraseKind::Other(n),
        };
        Phrase { beat, kind, fill: None }
    }

    #[test]
    fn a_high_mood_record_builds_and_drops() {
        // 120 bpm: a beat every 0.5 s, from 0.1 s
        let beats: Vec<f64> = (0..200).map(|i| 0.1 + i as f64 * 0.5).collect();
        let p = Phrases { mood: 1, end_beat: 161, list: vec![ph(1, 1, 1), ph(1, 33, 2), ph(1, 65, 5), ph(1, 97, 3), ph(1, 129, 5)] };
        let got = place(&p, &beats);
        let labels: Vec<_> = got.sections.iter().map(|s| s.label).collect();
        assert_eq!(labels, ["intro", "build", "chorus", "breakdown", "chorus"]);
        assert_eq!(got.sections[0].start_ms, 100.0);
        assert_eq!(got.sections[0].end_ms, got.sections[1].start_ms);
        assert_eq!(got.sections[4].end_ms, (0.1 + 160.0 * 0.5) * 1000.0);
        assert_eq!(got.drops_ms, [(0.1 + 64.0 * 0.5) * 1000.0, (0.1 + 128.0 * 0.5) * 1000.0]);
    }

    #[test]
    fn mid_mood_verses_and_bridges() {
        let beats: Vec<f64> = (0..100).map(|i| i as f64 * 0.5).collect();
        let p = Phrases { mood: 2, end_beat: 120, list: vec![ph(2, 1, 1), ph(2, 16, 3), ph(2, 48, 9), ph(2, 80, 8)] };
        let got = place(&p, &beats);
        assert_eq!(got.sections.iter().map(|s| s.label).collect::<Vec<_>>(), ["intro", "verse", "chorus", "break"]);
        assert!(got.drops_ms.is_empty());
        // past the grid: carried on at the last beat's length
        assert_eq!(got.sections[3].end_ms, 119.0 * 0.5 * 1000.0);
    }
}
