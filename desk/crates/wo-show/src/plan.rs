//! The plan (v1: show_plan.dart): how often everything the show puts on comes. Which scene:
//! its level against the others' (the director weighs the music's fit too). Which look of
//! that scene: a combination, as likely as every level that applies to it, multiplied —
//! style × background × mask × blend × effect × cells × (the background takes that mask and
//! blend). A 0 anywhere is never. A world has no background, mask or blend to weigh.
use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use crate::combos::{COMBO_GROUNDS, Combo, Fx, Mask, Mix, OWN_GROUND, combos_of};
use crate::json::{Named, Obj, f, obj};
use crate::named;
use crate::rig::Figure;

named!(
    /// The rows a look is made of, as the plan weighs them; and the camera (framings).
    pub enum PlanAxis { Style = "style", Ground = "ground", Mask = "mask", Mix = "mix", Fx = "fx", Shot = "shot" }
);

/// The rows every scene shares unless it has its own.
pub const SHARED_AXES: &[PlanAxis] = &[PlanAxis::Ground, PlanAxis::Mask, PlanAxis::Mix, PlanAxis::Fx];

/// The levels a fader stops at: off, then a quarter to four.
pub const LEVEL_STEPS: &[f64] = &[0.0, 0.25, 1.0 / 3.0, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0];

/// The most a level may be.
pub const LEVEL_MOST: f64 = 4.0;

pub type Levels = BTreeMap<String, f64>;

/// A level in words: `off`, `×1/3`, `×1.5`.
pub fn level_word(v: f64) -> String {
    if v <= 0.0 {
        return "off".into();
    }
    for (x, w) in [(0.25, "1/4"), (1.0 / 3.0, "1/3"), (0.5, "1/2"), (2.0 / 3.0, "2/3"), (0.75, "3/4")] {
        if (v - x).abs() < 0.004 {
            return format!("×{w}");
        }
    }
    let mut t = format!("{v:.2}");
    while t.contains('.') && (t.ends_with('0') || t.ends_with('.')) {
        t.pop();
    }
    format!("×{t}")
}

/// The levels the app comes with, by row.
pub fn shipped_level(a: PlanAxis, v: &str) -> Option<f64> {
    let table: &[(&str, f64)] = match a {
        PlanAxis::Ground => &[("milk", 3.0), ("white", 0.8), ("pulse.grid", 0.5), ("pulse.rays", 0.5), ("pulse.smoke", 0.5), ("pulse.stars", 0.5), ("field.drift", 0.6), ("cover", 0.6)],
        PlanAxis::Mask => &[("none", 2.0), ("keyhole", 0.6), ("inverted", 0.6)],
        PlanAxis::Mix => &[("screen", 0.7), ("contrast", 1.5)],
        // no effect most of the time: a sixth of the looks with one, as many of each
        PlanAxis::Fx => &[("none", 4.0), ("kaleidoscope", 0.25), ("slit", 0.25), ("both", 0.0), ("mosh", 0.25)],
        PlanAxis::Style => &[("contour", 0.0)],
        PlanAxis::Shot => &[],
    };
    table.iter().find(|(k, _)| *k == v).map(|(_, l)| *l)
}

/// The masks and blends a background does not take, as shipped.
pub fn shipped_not_with() -> BTreeMap<String, BTreeSet<String>> {
    let set = |xs: &[&str]| xs.iter().map(|s| s.to_string()).collect::<BTreeSet<_>>();
    BTreeMap::from([("black".into(), set(&["keyhole", "inverted", "add", "screen", "contrast"])), ("white".into(), set(&["add", "screen"]))])
}

/// A row's values, by name (a style's are the scene's own).
pub fn axis_values(a: PlanAxis) -> Vec<String> {
    match a {
        PlanAxis::Ground => COMBO_GROUNDS.iter().map(|s| s.to_string()).collect(),
        PlanAxis::Mask => Mask::ALL.iter().map(|m| m.name().into()).collect(),
        PlanAxis::Mix => Mix::ALL.iter().map(|m| m.name().into()).collect(),
        PlanAxis::Fx => Fx::ALL.iter().map(|m| m.name().into()).collect(),
        PlanAxis::Style | PlanAxis::Shot => vec![],
    }
}

/// A combination's value on a row.
pub fn plan_value(c: &Combo, a: PlanAxis) -> String {
    match a {
        PlanAxis::Style => c.style.clone(),
        PlanAxis::Ground => c.ground.clone(),
        PlanAxis::Mask => c.mask.name().into(),
        PlanAxis::Mix => c.mix.name().into(),
        PlanAxis::Fx => c.fx.name().into(),
        PlanAxis::Shot => String::new(),
    }
}

// ------------------------------------------------------------------ cells

/// A cell's key: `style|ground|mask|mix|fx`, `*` for any (the effect left off where any).
pub fn cell_key(style: &str, ground: &str, mask: &str, mix: &str, fx: &str) -> String {
    if fx == "*" { format!("{style}|{ground}|{mask}|{mix}") } else { format!("{style}|{ground}|{mask}|{mix}|{fx}") }
}

/// The key of exactly `c`.
pub fn cell_of(c: &Combo) -> String {
    cell_key(&c.style, &c.ground, c.mask.name(), c.mix.name(), c.fx.name())
}

/// A cell key's five rows (a key of four: the effect any).
pub fn cell_parts(key: &str) -> Option<[String; 5]> {
    let p: Vec<&str> = key.split('|').collect();
    match p.len() {
        4 => Some([p[0].into(), p[1].into(), p[2].into(), p[3].into(), "*".into()]),
        5 => Some([p[0].into(), p[1].into(), p[2].into(), p[3].into(), p[4].into()]),
        _ => None,
    }
}

pub fn is_cell_key(key: &str) -> bool {
    cell_parts(key).is_some()
}

/// Whether the cell `key` is about `c`.
pub fn cell_matches(key: &str, c: &Combo) -> bool {
    let Some(p) = cell_parts(key) else { return false };
    let at = |i: usize, v: &str| p[i] == "*" || p[i] == v;
    at(0, &c.style) && at(1, &c.ground) && at(2, c.mask.name()) && at(3, c.mix.name()) && at(4, c.fx.name())
}

/// Whether every look `inner` is about, `outer` is about too.
pub fn cell_covers(outer: &str, inner: &str) -> bool {
    match (cell_parts(outer), cell_parts(inner)) {
        (Some(o), Some(i)) => (0..5).all(|k| o[k] == "*" || o[k] == i[k]),
        _ => false,
    }
}

/// Whether two cells are about a look in common.
pub fn cells_meet(a: &str, b: &str) -> bool {
    match (cell_parts(a), cell_parts(b)) {
        (Some(x), Some(y)) => (0..5).all(|k| x[k] == "*" || y[k] == "*" || x[k] == y[k]),
        _ => false,
    }
}

fn levels_of(v: Option<&Value>) -> Levels {
    obj(v).map(|m| m.iter().filter_map(|(k, v)| v.as_f64().map(|x| (k.clone(), x.clamp(0.0, LEVEL_MOST)))).collect()).unwrap_or_default()
}

fn names_of(v: Option<&Value>) -> BTreeSet<String> {
    v.and_then(Value::as_array).map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_owned)).collect()).unwrap_or_default()
}

fn levels_json(l: &Levels) -> Value {
    Value::Object(l.iter().map(|(k, v)| (k.clone(), f(*v))).collect())
}

fn names_json(s: &BTreeSet<String>) -> Value {
    Value::Array(s.iter().map(|x| Value::String(x.clone())).collect())
}

/// One scene's part of the plan.
#[derive(Clone, Debug, PartialEq)]
pub struct ScenePlan {
    /// How often it comes against the other scenes (1 as shipped).
    pub level: f64,
    /// Never, the level kept for when it is back.
    pub muted: bool,
    /// Its styles' levels (absent: as shipped).
    pub styles: Levels,
    /// Its camera's framings' levels (absent: 1).
    pub shots: Levels,
    /// The rows it has its own of: the whole row's levels, in place of the shared ones.
    pub own: BTreeMap<PlanAxis, Levels>,
    /// What of its own is muted: `style.ascii`, `shot.fisheye`, `ground.white`…
    pub off: BTreeSet<String>,
    /// The hands' word on some of its looks, by cell key: multiplied in (0 never).
    pub cells: Levels,
    /// The cells whose looks come however they measured.
    pub allow: BTreeSet<String>,
}

impl Default for ScenePlan {
    fn default() -> Self {
        ScenePlan { level: 1.0, muted: false, styles: Levels::new(), shots: Levels::new(), own: BTreeMap::new(), off: BTreeSet::new(), cells: Levels::new(), allow: BTreeSet::new() }
    }
}

impl ScenePlan {
    pub fn is_empty(&self) -> bool {
        *self == ScenePlan::default()
    }

    /// The level as it counts (0 muted).
    pub fn weight(&self) -> f64 {
        if self.muted { 0.0 } else { self.level }
    }

    pub fn to_json(&self) -> Value {
        let mut m = Obj::new();
        if self.level != 1.0 {
            m.insert("level".into(), f(self.level));
        }
        if self.muted {
            m.insert("muted".into(), true.into());
        }
        if !self.styles.is_empty() {
            m.insert("styles".into(), levels_json(&self.styles));
        }
        if !self.shots.is_empty() {
            m.insert("shots".into(), levels_json(&self.shots));
        }
        if !self.own.is_empty() {
            m.insert("own".into(), Value::Object(self.own.iter().map(|(a, l)| (a.name().to_owned(), levels_json(l))).collect()));
        }
        if !self.off.is_empty() {
            m.insert("off".into(), names_json(&self.off));
        }
        if !self.cells.is_empty() {
            m.insert("cells".into(), levels_json(&self.cells));
        }
        if !self.allow.is_empty() {
            m.insert("allow".into(), names_json(&self.allow));
        }
        Value::Object(m)
    }

    pub fn from_json(j: Option<&Value>) -> ScenePlan {
        let Some(j) = obj(j) else { return ScenePlan::default() };
        let own = obj(j.get("own"))
            .map(|m| m.iter().filter_map(|(k, v)| PlanAxis::by_name(k).filter(|a| SHARED_AXES.contains(a)).map(|a| (a, levels_of(Some(v))))).collect())
            .unwrap_or_default();
        ScenePlan {
            level: j.get("level").and_then(Value::as_f64).map(|l| l.clamp(0.0, LEVEL_MOST)).unwrap_or(1.0),
            muted: j.get("muted") == Some(&Value::Bool(true)),
            styles: levels_of(j.get("styles")),
            shots: levels_of(j.get("shots")),
            own,
            off: names_of(j.get("off")),
            cells: obj(j.get("cells"))
                .map(|m| m.iter().filter(|(k, _)| is_cell_key(k)).filter_map(|(k, v)| v.as_f64().map(|x| (k.clone(), x.clamp(0.0, 16.0)))).collect())
                .unwrap_or_default(),
            allow: names_of(j.get("allow")).into_iter().filter(|k| is_cell_key(k)).collect(),
        }
    }
}

/// The whole plan: each scene's part, and the rows every scene shares.
#[derive(Clone, Debug, PartialEq)]
pub struct ShowPlan {
    /// Each scene's part, by id (absent: as shipped).
    pub scenes: BTreeMap<String, ScenePlan>,
    /// The shared rows' levels the hands set, over the shipped ones.
    pub levels: BTreeMap<PlanAxis, Levels>,
    /// What of the shared rows is muted: `ground.wash`, `mix.add`.
    pub off: BTreeSet<String>,
    /// The masks and blends each background does not take, by its key.
    pub not_with: BTreeMap<String, BTreeSet<String>>,
}

impl Default for ShowPlan {
    fn default() -> Self {
        ShowPlan { scenes: BTreeMap::new(), levels: BTreeMap::new(), off: BTreeSet::new(), not_with: shipped_not_with() }
    }
}

thread_local! {
    static NONE: ScenePlan = ScenePlan::default();
}

impl ShowPlan {
    pub fn of(&self, scene: &str) -> ScenePlan {
        self.scenes.get(scene).cloned().unwrap_or_default()
    }

    fn with_of<R>(&self, scene: &str, f: impl FnOnce(&ScenePlan) -> R) -> R {
        match self.scenes.get(scene) {
            Some(p) => f(p),
            None => NONE.with(f),
        }
    }

    // ---------------------------------------------------------------- levels

    /// A scene's level as it counts (0: muted).
    pub fn scene_level(&self, scene: &str) -> f64 {
        self.with_of(scene, ScenePlan::weight)
    }

    /// A shared row's level, as the hands left it (muted: 0).
    pub fn shared(&self, a: PlanAxis, v: &str) -> f64 {
        if self.shared_muted(a, v) { 0.0 } else { self.shared_fader(a, v) }
    }

    /// A shared row's level before its mute.
    pub fn shared_fader(&self, a: PlanAxis, v: &str) -> f64 {
        self.levels.get(&a).and_then(|r| r.get(v)).copied().or_else(|| shipped_level(a, v)).unwrap_or(1.0)
    }

    pub fn shared_muted(&self, a: PlanAxis, v: &str) -> bool {
        self.off.contains(&format!("{}.{v}", a.name()))
    }

    /// Whether `scene` has its own of row `a`.
    pub fn owns(&self, scene: &str, a: PlanAxis) -> bool {
        self.with_of(scene, |p| p.own.contains_key(&a))
    }

    /// `v`'s level on row `a` in `scene`.
    pub fn level_in(&self, scene: &str, a: PlanAxis, v: &str) -> f64 {
        if self.muted_in(scene, a, v) { 0.0 } else { self.fader_in(scene, a, v) }
    }

    /// `level_in` before its mute.
    pub fn fader_in(&self, scene: &str, a: PlanAxis, v: &str) -> f64 {
        self.with_of(scene, |p| match a {
            PlanAxis::Style => p.styles.get(v).copied().or_else(|| shipped_level(PlanAxis::Style, v)).unwrap_or(1.0),
            PlanAxis::Shot => p.shots.get(v).copied().unwrap_or(1.0),
            _ => match p.own.get(&a) {
                Some(mine) => mine.get(v).copied().or_else(|| shipped_level(a, v)).unwrap_or(1.0),
                None => self.shared_fader(a, v),
            },
        })
    }

    /// Whether `v` of row `a` is muted in `scene` (its own mute, or the shared row's).
    pub fn muted_in(&self, scene: &str, a: PlanAxis, v: &str) -> bool {
        self.with_of(scene, |sp| sp.off.contains(&format!("{}.{v}", a.name())) || (SHARED_AXES.contains(&a) && !sp.own.contains_key(&a) && self.shared_muted(a, v)))
    }

    /// Whether the background `ground` takes the mask or blend `mask_or_mix`.
    pub fn takes(&self, ground: &str, mask_or_mix: &str) -> bool {
        !self.not_with.get(ground).is_some_and(|s| s.contains(mask_or_mix))
    }

    /// The cells of `c`'s scene about it, multiplied.
    pub fn cells_for(&self, c: &Combo) -> f64 {
        self.with_of(&c.scene, |p| p.cells.iter().filter(|(k, _)| cell_matches(k, c)).map(|(_, v)| *v).product())
    }

    /// Whether `c` comes however it measured.
    pub fn allowed(&self, c: &Combo) -> bool {
        self.with_of(&c.scene, |p| p.allow.iter().any(|k| cell_matches(k, c)))
    }

    /// How likely `c` is within its scene, before how it measured.
    pub fn look_weight(&self, c: &Combo) -> f64 {
        let w = self.base_weight(c);
        if w <= 0.0 { 0.0 } else { w * self.cells_for(c) }
    }

    /// `look_weight` before the cells.
    pub fn base_weight(&self, c: &Combo) -> f64 {
        let s = &c.scene;
        let w = self.level_in(s, PlanAxis::Style, &c.style) * self.level_in(s, PlanAxis::Fx, c.fx.name());
        if w <= 0.0 || c.world() {
            return w;
        }
        if !self.takes(&c.ground, c.mask.name()) || !self.takes(&c.ground, c.mix.name()) {
            return 0.0;
        }
        w * self.level_in(s, PlanAxis::Ground, &c.ground) * self.level_in(s, PlanAxis::Mask, c.mask.name()) * self.level_in(s, PlanAxis::Mix, c.mix.name())
    }

    /// Whether `c` is in the rotation at all.
    pub fn is_on(&self, c: &Combo) -> bool {
        self.scene_level(&c.scene) > 0.0 && self.look_weight(c) > 0.0
    }

    /// `look_weight` as the factors it is made of, in words and numbers.
    pub fn factors(&self, c: &Combo) -> Vec<(String, f64)> {
        let s = &c.scene;
        let own = |a| if self.owns(s, a) { "its own " } else { "" };
        let mut out = vec![
            (format!("style {}", c.style), self.level_in(s, PlanAxis::Style, &c.style)),
            (format!("{}effect {}", own(PlanAxis::Fx), c.fx.name()), self.level_in(s, PlanAxis::Fx, c.fx.name())),
        ];
        if !c.world() {
            for (a, v) in [(PlanAxis::Ground, c.ground.as_str()), (PlanAxis::Mask, c.mask.name()), (PlanAxis::Mix, c.mix.name())] {
                out.push((format!("{}{} {v}", own(a), a.name()), self.level_in(s, a, v)));
            }
            if !self.takes(&c.ground, c.mask.name()) {
                out.push((format!("{} takes no {}", c.ground, c.mask.name()), 0.0));
            }
            if !self.takes(&c.ground, c.mix.name()) {
                out.push((format!("{} takes no {}", c.ground, c.mix.name()), 0.0));
            }
        }
        self.with_of(s, |p| {
            for (k, v) in &p.cells {
                if cell_matches(k, c) {
                    out.push((format!("cell {k}"), *v));
                }
            }
        });
        out
    }

    /// A framing's level in `scene`.
    pub fn shot_level(&self, scene: &str, shot: &str) -> f64 {
        self.level_in(scene, PlanAxis::Shot, shot)
    }

    // ---------------------------------------------------------------- changes

    /// `scene`'s part changed by `f` (back to none where it comes to nothing).
    pub fn with_scene_of(&self, scene: &str, f: impl FnOnce(ScenePlan) -> ScenePlan) -> ShowPlan {
        let next = f(self.of(scene));
        let mut out = self.clone();
        out.scenes.remove(scene);
        if !next.is_empty() {
            out.scenes.insert(scene.into(), next);
        }
        out
    }

    /// A scene's level, or its mute.
    pub fn with_scene(&self, scene: &str, level: Option<f64>, muted: Option<bool>) -> ShowPlan {
        self.with_scene_of(scene, |mut p| {
            if let Some(l) = level {
                p.level = l;
            }
            if let Some(m) = muted {
                p.muted = m;
            }
            p
        })
    }

    fn toggled(s: &BTreeSet<String>, k: String, on: bool) -> BTreeSet<String> {
        let mut s = s.clone();
        if on {
            s.insert(k);
        } else {
            s.remove(&k);
        }
        s
    }

    /// A shared row's level (`clear`: as shipped), or its mute.
    pub fn with_shared(&self, a: PlanAxis, v: &str, level: Option<f64>, clear: bool, muted: Option<bool>) -> ShowPlan {
        let mut next = self.clone();
        if level.is_some() || clear {
            let mut row = next.levels.get(&a).cloned().unwrap_or_default();
            row.remove(v);
            if let Some(l) = level
                && l != shipped_level(a, v).unwrap_or(1.0)
            {
                row.insert(v.into(), l);
            }
            next.levels.remove(&a);
            if !row.is_empty() {
                next.levels.insert(a, row);
            }
        }
        if let Some(m) = muted {
            next.off = Self::toggled(&next.off, format!("{}.{v}", a.name()), m);
        }
        next
    }

    /// `v`'s level on row `a` in `scene` (its style, its framing, or its own row), or its
    /// mute. On a shared row the scene does not own, the shared row's.
    pub fn with_in(&self, scene: &str, a: PlanAxis, v: &str, level: Option<f64>, muted: Option<bool>) -> ShowPlan {
        if SHARED_AXES.contains(&a) && !self.owns(scene, a) {
            return self.with_shared(a, v, level, false, muted);
        }
        self.with_scene_of(scene, |mut p| {
            if let Some(l) = level {
                match a {
                    PlanAxis::Style => {
                        p.styles.remove(v);
                        if l != shipped_level(PlanAxis::Style, v).unwrap_or(1.0) {
                            p.styles.insert(v.into(), l);
                        }
                    }
                    PlanAxis::Shot => {
                        p.shots.remove(v);
                        if l != 1.0 {
                            p.shots.insert(v.into(), l);
                        }
                    }
                    _ => {
                        p.own.entry(a).or_default().insert(v.into(), l);
                    }
                }
            }
            if let Some(m) = muted {
                p.off = Self::toggled(&p.off, format!("{}.{v}", a.name()), m);
            }
            p
        })
    }

    /// `scene` with its own row `a` (the shared levels and mutes copied), or sharing it again.
    pub fn with_own(&self, scene: &str, a: PlanAxis, own: bool) -> ShowPlan {
        self.with_scene_of(scene, |mut p| {
            if own == p.own.contains_key(&a) {
                return p;
            }
            let prefix = format!("{}.", a.name());
            if !own {
                p.own.remove(&a);
                p.off.retain(|k| !k.starts_with(&prefix));
                return p;
            }
            p.own.insert(a, axis_values(a).into_iter().map(|v| (v.clone(), self.shared_fader(a, &v))).collect());
            for v in axis_values(a) {
                if self.shared_muted(a, &v) {
                    p.off.insert(format!("{prefix}{v}"));
                }
            }
            p
        })
    }

    /// Whether `ground` takes the mask or blend `mask_or_mix`.
    pub fn with_takes(&self, ground: &str, mask_or_mix: &str, takes: bool) -> ShowPlan {
        let mut now = self.not_with.get(ground).cloned().unwrap_or_default();
        if takes {
            now.remove(mask_or_mix);
        } else {
            now.insert(mask_or_mix.into());
        }
        let mut next = self.clone();
        next.not_with.remove(ground);
        if !now.is_empty() {
            next.not_with.insert(ground.into(), now);
        }
        next
    }

    /// One cell of `scene` at `v` (None or 1: none).
    pub fn with_cell(&self, scene: &str, key: &str, v: Option<f64>) -> ShowPlan {
        self.with_scene_of(scene, |mut p| {
            p.cells.remove(key);
            if let Some(v) = v
                && v != 1.0
            {
                p.cells.insert(key.into(), v.clamp(0.0, 16.0));
            }
            p
        })
    }

    /// One cell of `scene` times `k` (less, more), kept within a sixteenth to sixteen.
    pub fn scale_cell(&self, scene: &str, key: &str, k: f64) -> ShowPlan {
        let was = self.with_of(scene, |p| p.cells.get(key).copied()).unwrap_or(1.0);
        let next = (was * k).clamp(1.0 / 16.0, 16.0);
        self.with_cell(scene, key, if (next - 1.0).abs() < 1e-6 { None } else { Some(next) })
    }

    /// The looks the cell `key` is about let come however they measured (or measured again).
    pub fn with_allow(&self, scene: &str, key: &str, allow: bool) -> ShowPlan {
        self.with_scene_of(scene, |mut p| {
            if !allow {
                p.allow.retain(|k| !cell_covers(key, k));
            }
            if allow {
                p.allow.insert(key.into());
            }
            p
        })
    }

    /// The looks the cell `target` is about let out of every cell at 0 that keeps them out:
    /// a cell about nothing else taken away; a wider one cut round them. `styles`: the
    /// scene's styles, to cut a `*` style by.
    pub fn with_unvetoed(&self, scene: &str, target: &str, styles: &[String]) -> ShowPlan {
        let mut grounds: Vec<String> = COMBO_GROUNDS.iter().map(|s| s.to_string()).collect();
        grounds.push(OWN_GROUND.into());
        let values: [Vec<String>; 5] = [styles.to_vec(), grounds, axis_values(PlanAxis::Mask), axis_values(PlanAxis::Mix), axis_values(PlanAxis::Fx)];
        let Some(t) = cell_parts(target) else { return self.clone() };
        self.with_scene_of(scene, |mut p| {
            let mut out = Levels::new();
            for (key, v) in &p.cells {
                if *v > 0.0 || !cells_meet(key, target) {
                    out.insert(key.clone(), *v);
                    continue;
                }
                let mut rest = cell_parts(key).unwrap();
                for k in 0..5 {
                    if rest[k] != "*" || t[k] == "*" {
                        continue;
                    }
                    for v in &values[k] {
                        if *v == t[k] {
                            continue;
                        }
                        let mut piece = rest.clone();
                        piece[k] = v.clone();
                        out.insert(cell_key(&piece[0], &piece[1], &piece[2], &piece[3], &piece[4]), 0.0);
                    }
                    rest[k] = t[k].clone();
                }
            }
            p.cells = out;
            p
        })
    }

    /// `to` made like `from`: its styles' levels and mutes where `to` has them, its own rows,
    /// and the cells (and allows) about styles it has or any style.
    pub fn copy_scene(&self, from: &str, to: &str, to_styles: &[String]) -> ShowPlan {
        let fp = self.of(from);
        let has: BTreeSet<&str> = to_styles.iter().map(String::as_str).collect();
        let style_ok = |key: &str| cell_parts(key).is_some_and(|p| p[0] == "*" || has.contains(p[0].as_str()));
        self.with_scene_of(to, |mut p| {
            p.styles = fp.styles.iter().filter(|(k, _)| has.contains(k.as_str())).map(|(k, v)| (k.clone(), *v)).collect();
            p.own = fp.own.clone();
            let mut off: BTreeSet<String> = p.off.iter().filter(|k| k.starts_with("shot.")).cloned().collect();
            off.extend(fp.off.iter().filter(|k| !k.starts_with("shot.") && (!k.starts_with("style.") || has.contains(&k[6..]))).cloned());
            p.off = off;
            p.cells = fp.cells.iter().filter(|(k, _)| style_ok(k)).map(|(k, v)| (k.clone(), *v)).collect();
            p.allow = fp.allow.iter().filter(|k| style_ok(k)).cloned().collect();
            p
        })
    }

    // ---------------------------------------------------------------- json

    pub fn to_json(&self) -> Value {
        let mut m = Obj::new();
        if !self.scenes.is_empty() {
            m.insert("scenes".into(), Value::Object(self.scenes.iter().map(|(k, p)| (k.clone(), p.to_json())).collect()));
        }
        if !self.levels.is_empty() {
            m.insert("levels".into(), Value::Object(self.levels.iter().map(|(a, l)| (a.name().to_owned(), levels_json(l))).collect()));
        }
        if !self.off.is_empty() {
            m.insert("off".into(), names_json(&self.off));
        }
        if self.not_with != shipped_not_with() {
            m.insert("notWith".into(), Value::Object(self.not_with.iter().map(|(k, s)| (k.clone(), names_json(s))).collect()));
        }
        Value::Object(m)
    }

    pub fn from_json(j: Option<&Value>) -> ShowPlan {
        let Some(j) = obj(j) else { return ShowPlan::default() };
        let levels = obj(j.get("levels"))
            .map(|m| m.iter().filter_map(|(k, v)| PlanAxis::by_name(k).filter(|a| SHARED_AXES.contains(a)).map(|a| (a, levels_of(Some(v))))).collect())
            .unwrap_or_default();
        ShowPlan {
            scenes: obj(j.get("scenes"))
                .map(|m| m.iter().map(|(k, v)| (k.clone(), ScenePlan::from_json(Some(v)))).filter(|(_, p)| !p.is_empty()).collect())
                .unwrap_or_default(),
            levels,
            off: names_of(j.get("off")),
            not_with: obj(j.get("notWith")).map(|m| m.iter().map(|(k, v)| (k.clone(), names_of(Some(v)))).collect()).unwrap_or_else(shipped_not_with),
        }
    }
}

/// A scene's looks, each with how likely it is within the scene, the backgrounds `grounds` only.
pub fn look_weights(plan: &ShowPlan, scene: &str, kind: Figure, grounds: &[&str]) -> Vec<(Combo, f64)> {
    combos_of(scene, kind, grounds, Fx::ALL).into_iter().map(|c| {
        let w = plan.look_weight(&c);
        (c, w)
    }).collect()
}
