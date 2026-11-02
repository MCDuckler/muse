//! How every combination looks, measured (v1: combo_scores.dart; the audit's table,
//! assets/show/combo_scores.json): for each scene in each style, under each background, mask
//! and blend, how good it looks and how intense it is — one base-36 digit each. The ugly ones
//! never come by themselves (an allow of the plan's lets one); the intensity is matched to
//! where the record is. And MilkDrop's presets the same (assets/show/milk_scores.json).
use std::collections::HashMap;

use serde_json::Value;

use crate::combos::Combo;
use crate::json::Named;
use crate::plan::ShowPlan;

const DIGITS: &str = "0123456789abcdefghijklmnopqrstuvwxyz";

fn value(ch: char) -> Option<f64> {
    DIGITS.find(ch).map(|i| i as f64 / 35.0)
}

#[derive(Clone, Debug, Default)]
pub struct ComboScores {
    grounds: HashMap<String, usize>,
    masks: HashMap<String, usize>,
    mixes: HashMap<String, usize>,
    figures: HashMap<String, (String, String)>,
}

impl ComboScores {
    /// Below this a combination does not come by itself.
    pub const FLOOR: f64 = 0.3;

    /// The audit's table as the app ships it (taken in at build time).
    pub fn shipped() -> Option<ComboScores> {
        ComboScores::parse(include_str!("../../../../app/assets/show/combo_scores.json"))
    }

    pub fn parse(text: &str) -> Option<ComboScores> {
        let j: Value = serde_json::from_str(text).ok()?;
        let ix = |k: &str| -> Option<HashMap<String, usize>> { Some(j.get(k)?.as_array()?.iter().enumerate().filter_map(|(i, v)| v.as_str().map(|s| (s.to_owned(), i))).collect()) };
        let figures = j
            .get("figures")?
            .as_object()?
            .iter()
            .filter_map(|(k, v)| Some((k.clone(), (v.get("q")?.as_str()?.to_owned(), v.get("i")?.as_str()?.to_owned()))))
            .collect();
        Some(ComboScores { grounds: ix("grounds")?, masks: ix("masks")?, mixes: ix("mixes")?, figures })
    }

    fn at(&self, c: &Combo, quality: bool) -> Option<f64> {
        let (q, i) = self.figures.get(&format!("{}.{}", c.scene, c.style))?;
        let s = if quality { q } else { i };
        if s.chars().count() == 1 {
            return value(s.chars().next()?);
        }
        let (g, m, x) = (*self.grounds.get(&c.ground)?, *self.masks.get(c.mask.name())?, *self.mixes.get(c.mix.name())?);
        let k = (g * self.masks.len() + m) * self.mixes.len() + x;
        s.chars().nth(k).and_then(value)
    }

    /// How good `c` looks, 0..1; None where it was never measured.
    pub fn quality(&self, c: &Combo) -> Option<f64> {
        self.at(c, true)
    }

    /// How intense `c` is, 0 (dark, still, spare) to 1 (bright, busy, hard).
    pub fn intensity(&self, c: &Combo) -> Option<f64> {
        self.at(c, false)
    }

    /// `c`'s weight within its scene by the plan and how it looks: less as it looks worse,
    /// none under the floor — but a look the hands let come comes as the levels say.
    pub fn weigh(c: &Combo, plan: &ShowPlan, scores: Option<&ComboScores>) -> f64 {
        let w = plan.look_weight(c);
        if w <= 0.0 || plan.allowed(c) {
            return w;
        }
        w * Self::lean(scores.and_then(|s| s.quality(c)))
    }

    /// What a quality does to a weight: nothing for a good one, less towards the floor,
    /// nothing under it.
    pub fn lean(q: Option<f64>) -> f64 {
        let Some(q) = q else { return 1.0 };
        if q < Self::FLOOR {
            return 0.0;
        }
        let t = ((q - Self::FLOOR) / (0.7 - Self::FLOOR)).clamp(0.0, 1.0);
        0.15 + 0.85 * t * t * (3.0 - 2.0 * t)
    }
}

/// How every shipped MilkDrop preset looks, by its full name.
#[derive(Clone, Debug, Default)]
pub struct MilkScores {
    presets: HashMap<String, String>,
}

impl MilkScores {
    pub fn parse(text: &str) -> Option<MilkScores> {
        let j: Value = serde_json::from_str(text).ok()?;
        let presets = j.get("presets")?.as_object()?.iter().map(|(k, v)| (k.clone(), crate::json::text(Some(v)).unwrap_or_default())).collect();
        Some(MilkScores { presets })
    }

    fn at(&self, name: &str, i: usize) -> Option<f64> {
        self.presets.get(name)?.chars().nth(i).and_then(value)
    }

    /// How good on its own, 0..1 (None: never measured).
    pub fn alone(&self, name: &str) -> Option<f64> {
        self.at(name, 0)
    }
    /// How good under a figure.
    pub fn ground(&self, name: &str) -> Option<f64> {
        self.at(name, 1)
    }
    /// How intense.
    pub fn intensity(&self, name: &str) -> Option<f64> {
        self.at(name, 2)
    }
    /// How much it moves with the music by itself.
    pub fn react(&self, name: &str) -> Option<f64> {
        self.at(name, 3)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::combos::{COMBO_GROUNDS, Mask, Mix};
    use crate::plan::cell_key;

    fn table() -> ComboScores {
        let j = serde_json::json!({
            "grounds": COMBO_GROUNDS,
            "masks": ["none", "keyhole", "inverted"],
            "mixes": ["normal", "add", "screen", "contrast"],
            "figures": {"dance-art.plain": {"q": "0", "i": "h"}},
        });
        ComboScores::parse(&j.to_string()).unwrap()
    }

    #[test]
    fn an_allow_lets_a_look_come_however_it_measured() {
        // v1's show_plan_test: plain measured 0 never comes; an allow lets it
        let c = Combo::new("milk", "dance-art", "plain");
        assert_eq!(ComboScores::weigh(&c, &ShowPlan::default(), Some(&table())), 0.0);
        let p = ShowPlan::default().with_allow("dance-art", &cell_key("plain", "milk", "*", "*", "*"), true);
        assert_eq!(ComboScores::weigh(&c, &p, Some(&table())), 24.0);
    }

    #[test]
    fn a_digit_a_score_and_one_per_ground_mask_and_blend() {
        let s = table();
        let c = Combo::new("milk", "dance-art", "plain");
        assert_eq!(s.quality(&c), Some(0.0));
        assert_eq!(s.intensity(&c), Some(17.0 / 35.0));
        assert_eq!(s.quality(&Combo::new("milk", "kinetic", "raw")), None);
        assert_eq!(ComboScores::lean(None), 1.0);
        assert_eq!(ComboScores::lean(Some(0.29)), 0.0);
        assert!((ComboScores::lean(Some(0.7)) - 1.0).abs() < 1e-9);
        let _ = (Mask::None, Mix::Normal);
    }

    #[test]
    fn the_shipped_tables_read() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show");
        if let Ok(t) = std::fs::read_to_string(dir.join("combo_scores.json")) {
            let s = ComboScores::parse(&t).expect("combo_scores.json");
            assert!(s.quality(&Combo::new("milk", "kinetic", "raw")).is_some());
        }
        if let Ok(t) = std::fs::read_to_string(dir.join("milk_scores.json")) {
            let m = MilkScores::parse(&t).expect("milk_scores.json");
            assert!(m.presets.len() > 400);
        }
    }
}
