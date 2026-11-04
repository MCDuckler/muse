//! What this person has thought of the booth's mixes, boiled down to leanings the
//! planner adds to its scores (v1's taste.dart): which moves they thumb up and down,
//! which pairs of records they liked together, which moves they steer the booth away
//! from. Fitted from the house's mix_feedback; every leaning capped, so a single thumb
//! never outweighs the records' own fit.
use std::collections::HashMap;

use crate::mix::Transition;

/// One row of the house's mix feedback, as far as taste reads it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FeedbackRow {
    pub event: String,
    pub from_track: Option<i64>,
    pub to_track: Option<i64>,
    pub kind: Option<String>,
    pub rating: Option<f64>,
    /// A steer's move before the hand changed it (`detail.was`).
    pub was: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Taste {
    kinds: HashMap<String, f64>,
    pairs: HashMap<(i64, i64), f64>,
    pub count: usize,
}

impl Taste {
    pub fn from_feedback(rows: &[FeedbackRow]) -> Taste {
        let mut sum: HashMap<String, f64> = HashMap::new();
        let mut n: HashMap<String, usize> = HashMap::new();
        let mut pairs: HashMap<(i64, i64), f64> = HashMap::new();
        let mut count = 0;
        let mut kind = |k: Option<&str>, v: f64| {
            if let Some(k) = k.filter(|k| !k.is_empty()) {
                *sum.entry(k.to_string()).or_default() += v;
                *n.entry(k.to_string()).or_default() += 1;
            }
        };
        for r in rows {
            match r.event.as_str() {
                "rating" => {
                    let Some(rating) = r.rating.filter(|&v| v != 0.0) else { continue };
                    count += 1;
                    kind(r.kind.as_deref(), rating);
                    if let (Some(f), Some(t)) = (r.from_track, r.to_track) {
                        *pairs.entry((f, t)).or_default() += rating;
                    }
                }
                "steer" => {
                    let Some(was) = r.was.as_deref().filter(|w| Some(*w) != r.kind.as_deref()) else { continue };
                    count += 1;
                    kind(Some(was), -0.4);
                    kind(r.kind.as_deref(), 0.4);
                }
                _ => {}
            }
        }
        // shrunk towards nothing while there are few words on a move
        let kinds = sum.iter().map(|(k, v)| (k.clone(), (v / n[k] as f64) * (n[k] as f64 / (n[k] as f64 + 2.0)))).collect();
        Taste { kinds, pairs, count }
    }

    /// The leaning towards a move, added to its score: ±0.12 at most.
    pub fn of_kind(&self, kind: Transition) -> f64 {
        0.12 * self.kinds.get(kind.name()).copied().unwrap_or(0.0).clamp(-1.0, 1.0)
    }

    /// The leaning towards these two records together: ±0.3 at most.
    pub fn of_pair(&self, from: i64, to: i64) -> f64 {
        self.pairs.get(&(from, to)).map_or(0.0, |v| (0.15 * v).clamp(-0.3, 0.3))
    }

    /// The move liked best, where one is liked clearly.
    pub fn favourite(&self) -> Option<Transition> {
        self.kinds
            .iter()
            .filter(|(_, v)| **v > 0.2)
            .max_by(|a, b| a.1.total_cmp(b.1))
            .and_then(|(k, _)| Transition::from_name(k))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rated(kind: &str, rating: f64) -> FeedbackRow {
        FeedbackRow { event: "rating".into(), from_track: Some(1), to_track: Some(2), kind: Some(kind.into()), rating: Some(rating), was: None }
    }

    #[test]
    fn thumbs_and_steers_lean_it() {
        let rows = vec![
            rated("riser", 1.0),
            rated("riser", 1.0),
            rated("riser", 1.0),
            rated("blend", -1.0),
            FeedbackRow { event: "steer".into(), kind: Some("echoOut".into()), was: Some("tremolo".into()), ..Default::default() },
        ];
        let t = Taste::from_feedback(&rows);
        assert_eq!(t.count, 5);
        assert!(t.of_kind(Transition::Riser) > 0.05, "three thumbs up");
        assert!(t.of_kind(Transition::Blend) < 0.0);
        assert!(t.of_kind(Transition::Tremolo) < 0.0 && t.of_kind(Transition::EchoOut) > 0.0, "steered from one to the other");
        assert_eq!(t.favourite(), Some(Transition::Riser));
        assert!(t.of_pair(1, 2) > 0.0 && t.of_pair(2, 1) == 0.0);
        assert_eq!(Taste::default().of_kind(Transition::Blend), 0.0);
    }
}
