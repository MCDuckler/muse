//! How much of a night each thing gets by the plan (v1: plan_shares.dart), for the Desk to
//! say beside the levels: a scene's share of the night is its level against the other
//! scenes' on (the director shares the time so, over a night — the music says when); a
//! look's share of its scene is its weight against the scene's other looks', as the director
//! draws them (how they measured counted); a look's share of the night, the two multiplied.
//! "About": the music leans every pick, these are what the plan alone would give.
use std::collections::{BTreeMap, BTreeSet};

use crate::combos::{COMBO_GROUNDS, Combo, Fx, combos_of};
use crate::json::Named;
use crate::plan::{PlanAxis, ShowPlan, plan_value};
use crate::rig::Figure;
use crate::scores::ComboScores;

/// What a scene's looks depend on: its own part of the plan (but its level), the shared rows,
/// the backgrounds here. A scene whose key is the same weighs its looks the same.
#[derive(Clone, Debug, PartialEq)]
struct LooksKey {
    scene: crate::plan::ScenePlan,
    levels: BTreeMap<PlanAxis, crate::plan::Levels>,
    off: BTreeSet<String>,
    not_with: BTreeMap<String, BTreeSet<String>>,
    grounds: BTreeSet<String>,
}

fn looks_key(plan: &ShowPlan, scene: &str, grounds: &BTreeSet<String>) -> LooksKey {
    let mut sp = plan.of(scene);
    sp.level = 1.0;
    sp.muted = false;
    LooksKey { scene: sp, levels: plan.levels.clone(), off: plan.off.clone(), not_with: plan.not_with.clone(), grounds: grounds.clone() }
}

#[derive(Clone, Debug, Default)]
pub struct PlanShares {
    /// Each scene's looks with their share of the scene's time (0 for the ones never on), and
    /// what they were weighed by.
    looks: BTreeMap<String, (LooksKeyBox, Vec<(Combo, f64)>)>,
    /// Each scene's share of the night.
    pub scenes: BTreeMap<String, f64>,
    /// Each row's values' share of the night, every scene's looks counted.
    night: BTreeMap<PlanAxis, BTreeMap<String, f64>>,
}

#[derive(Clone, Debug, Default)]
struct LooksKeyBox(Option<Box<LooksKey>>);

impl PlanShares {
    /// The shares by `plan` for the scenes `kinds` (their figures, by id), with the
    /// backgrounds `grounds` here. A scene whose looks weigh as they did in `before` keeps
    /// them (a scene's fader moving re-weighs nothing).
    pub fn of(plan: &ShowPlan, kinds: &BTreeMap<String, Figure>, grounds: &BTreeSet<String>, scores: Option<&ComboScores>, before: Option<&PlanShares>) -> PlanShares {
        let here: Vec<&str> = COMBO_GROUNDS.iter().copied().filter(|g| grounds.contains(*g)).collect();
        let mut looks = BTreeMap::new();
        for (scene, kind) in kinds {
            let key = looks_key(plan, scene, grounds);
            if let Some((k, l)) = before.and_then(|b| b.looks.get(scene))
                && k.0.as_deref() == Some(&key)
            {
                looks.insert(scene.clone(), (k.clone(), l.clone()));
                continue;
            }
            let all: Vec<(Combo, f64)> = combos_of(scene, *kind, &here, Fx::ALL).into_iter().map(|c| {
                let w = ComboScores::weigh(&c, plan, scores);
                (c, w)
            }).collect();
            let total: f64 = all.iter().map(|(_, w)| w).sum();
            let shares = all.into_iter().map(|(c, w)| (c, if total <= 0.0 { 0.0 } else { w / total })).collect();
            looks.insert(scene.clone(), (LooksKeyBox(Some(Box::new(key))), shares));
        }
        let any_on = |s: &str| looks.get(s).is_some_and(|(_, l)| l.iter().any(|(_, v)| *v > 0.0));
        let levels: BTreeMap<String, f64> = kinds.keys().map(|s| (s.clone(), if any_on(s) { plan.scene_level(s) } else { 0.0 })).collect();
        let total: f64 = levels.values().sum();
        let scenes: BTreeMap<String, f64> = levels.into_iter().map(|(s, l)| (s, if total <= 0.0 { 0.0 } else { l / total })).collect();
        let mut night: BTreeMap<PlanAxis, BTreeMap<String, f64>> = BTreeMap::new();
        for a in [PlanAxis::Style, PlanAxis::Ground, PlanAxis::Mask, PlanAxis::Mix, PlanAxis::Fx] {
            let out = night.entry(a).or_default();
            for (s, k) in &scenes {
                if *k <= 0.0 {
                    continue;
                }
                for (c, v) in looks.get(s).map(|(_, l)| l.as_slice()).unwrap_or_default() {
                    *out.entry(plan_value(c, a)).or_insert(0.0) += k * v;
                }
            }
        }
        PlanShares { looks, scenes, night }
    }

    /// Each look of `scene` with its share of the scene's time.
    pub fn looks_of(&self, scene: &str) -> &[(Combo, f64)] {
        self.looks.get(scene).map(|(_, l)| l.as_slice()).unwrap_or_default()
    }

    /// Whether any look of `scene` can come (with the backgrounds here).
    pub fn any_on(&self, scene: &str) -> bool {
        self.looks_of(scene).iter().any(|(_, v)| *v > 0.0)
    }

    /// `c`'s share of the night.
    pub fn of_night(&self, c: &Combo) -> f64 {
        self.scenes.get(&c.scene).copied().unwrap_or(0.0) * self.looks_of(&c.scene).iter().find(|(x, _)| x == c).map_or(0.0, |(_, v)| *v)
    }

    /// The share of `scene`'s time with `value` on row `a`.
    pub fn within(&self, scene: &str, a: PlanAxis, value: &str) -> f64 {
        self.looks_of(scene).iter().filter(|(c, _)| plan_value(c, a) == value).map(|(_, v)| v).sum()
    }

    /// The share of the night with `value` on row `a`, every scene's looks counted.
    pub fn of_night_by(&self, a: PlanAxis, value: &str) -> f64 {
        self.night.get(&a).and_then(|m| m.get(value)).copied().unwrap_or(0.0)
    }
}

/// A share in words: `12 %`, `0.4 %`, `<0.1 %`, `—` for none.
pub fn share_word(share: f64) -> String {
    let p = share * 100.0;
    if p <= 0.0 {
        "—".into()
    } else if p < 0.1 {
        "<0.1 %".into()
    } else if p < 10.0 {
        format!("{p:.1} %")
    } else {
        format!("{p:.0} %")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scenes::{DRAWN, SceneBook, grounds_drawn};

    fn kinds() -> BTreeMap<String, Figure> {
        SceneBook::shipped().only(DRAWN).kinds()
    }

    #[test]
    fn the_night_is_shared_out_whole() {
        let plan = ShowPlan::default();
        let g = grounds_drawn(false, false);
        let s = PlanShares::of(&plan, &kinds(), &g, ComboScores::shipped().as_ref(), None);
        let total: f64 = s.scenes.values().sum();
        assert!((total - 1.0).abs() < 1e-9, "the scenes' shares make the night: {total}");
        for a in [PlanAxis::Ground, PlanAxis::Mask, PlanAxis::Mix, PlanAxis::Fx] {
            let t: f64 = s.night[&a].values().sum();
            assert!((t - 1.0).abs() < 1e-6, "{a:?}'s values make the night: {t}");
        }
        assert_eq!(s.of_night_by(PlanAxis::Ground, "milk"), 0.0, "no MilkDrop here");
        assert!(s.scenes.iter().all(|(id, v)| *v > 0.0 || !s.any_on(id)));
        for id in s.scenes.keys() {
            if s.any_on(id) {
                let t: f64 = s.looks_of(id).iter().map(|(_, v)| v).sum();
                assert!((t - 1.0).abs() < 1e-6, "{id}'s looks make its time");
            }
        }
        assert_eq!(share_word(0.0), "—");
        assert_eq!(share_word(0.0004), "<0.1 %");
        assert_eq!(share_word(0.042), "4.2 %");
        assert_eq!(share_word(0.31), "31 %");
    }

    #[test]
    fn a_scene_twice_as_loud_has_twice_the_night_and_muted_none() {
        let k = kinds();
        let g = grounds_drawn(false, false);
        let plan = ShowPlan::default();
        let s0 = PlanShares::of(&plan, &k, &g, None, None);
        let (a, b) = {
            let mut on = s0.scenes.iter().filter(|(_, v)| **v > 0.0).map(|(id, _)| id.clone());
            (on.next().unwrap(), on.next().unwrap())
        };
        let louder = plan.with_scene(&a, Some(2.0), None).with_scene(&b, None, Some(true));
        let t = std::time::Instant::now();
        let s1 = PlanShares::of(&louder, &k, &g, None, Some(&s0));
        let reused = t.elapsed();
        assert_eq!(s1.scenes[&b], 0.0, "muted: none of the night");
        let ratio = |s: &PlanShares, x: &str| s.scenes[x] / s.scenes.iter().filter(|(id, _)| **id != a && **id != b).map(|(_, v)| *v).next().unwrap();
        assert!((ratio(&s1, &a) / ratio(&s0, &a) - 2.0).abs() < 1e-9, "twice the level, twice against the others");
        // a scene's level weighs no look again
        let t = std::time::Instant::now();
        let _ = PlanShares::of(&louder, &k, &g, None, None);
        assert!(reused < t.elapsed(), "kept looks are quicker: {reused:?} vs {:?}", t.elapsed());
        // a background switched off: none of its night
        let no_white = louder.with_shared(PlanAxis::Ground, "white", None, false, Some(true));
        let s2 = PlanShares::of(&no_white, &k, &g, None, Some(&s1));
        assert_eq!(s2.of_night_by(PlanAxis::Ground, "white"), 0.0);
    }
}
