//! The director (v1: show_director.dart): which scene is on, in which combination, and when
//! they change. Which scene: the one that fits the music best among the ones the plan has on —
//! each tiring the faster the lower its level, so over a night the scenes share the time by
//! their levels. A drop cuts to one full at once; a section turning, or a phrase after a while,
//! changes it; a section that comes back brings back its scene and its combination. Which
//! combination: by the plan's weight, how it measured, its intensity against where the record is,
//! the record's own leanings, the hands' taste.
use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::combos::{COMBO_GROUNDS, Combo, Fx, combos_of, pick_by_weight, styles_of_figure};
use crate::deck::ShowDeck;
use crate::events::{EventKind, ShowEvent};
use crate::plan::ShowPlan;
use crate::rig::{Figure, SceneMeta};
use crate::rng::Rng;
use crate::scores::ComboScores;
use crate::state::ShowState;

/// How the director got from one scene to the next.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SceneChange {
    Cut,
    Dissolve,
    Hit,
    Mosh,
}

pub const DISSOLVE_BARS: f64 = 1.0;
pub const CALM_SECTIONS: &[&str] = &["intro", "outro", "breakdown", "break"];
pub const LOUD_SECTIONS: &[&str] = &["drop", "chorus"];
/// A scene is kept at least this long, in bars, unless a drop or the hands say.
pub const KEEP_BARS: i64 = 8;
pub const GROUND_HOLD_BARS: i64 = 16;
/// How many bars a style, mask and blend are kept at least.
pub const STYLE_BARS: i64 = 8;
pub const FATIGUE_HALF_LIFE: f64 = 20.0 * 60.0;
/// How far from the target a combination may be and still come often.
pub const INTENSITY_WIDTH: f64 = 0.2;

fn calm(s: Option<&str>) -> bool {
    s.is_some_and(|s| CALM_SECTIONS.contains(&s))
}

fn loud(s: Option<&str>) -> bool {
    s.is_some_and(|s| LOUD_SECTIONS.contains(&s))
}

/// How many bars a dissolve into `section` takes.
pub fn dissolve_for(section: Option<&str>) -> f64 {
    if section == Some("outro") {
        3.0
    } else if calm(section) {
        2.0
    } else {
        DISSOLVE_BARS
    }
}

/// How often a change is datamoshed, by where the record is.
pub fn mosh_chance(share: f64, section: Option<&str>, drop: bool) -> f64 {
    if share <= 0.0 {
        return 0.0;
    }
    if drop {
        return (share * 1.6).min(0.9);
    }
    if calm(section) {
        return 0.0;
    }
    if loud(section) {
        return (share * 1.3).min(0.8);
    }
    if section == Some("build") {
        return share * 0.5;
    }
    share
}

/// What a section asks for, before the bar's energy.
pub fn section_intensity(section: Option<&str>, build_k: f64) -> f64 {
    match section {
        Some("intro") => 0.2,
        Some("outro") => 0.18,
        Some("breakdown") => 0.15,
        Some("break") => 0.22,
        Some("verse") => 0.4,
        Some("inst") => 0.5,
        Some("chorus") => 0.68,
        Some("drop") => 0.92,
        Some("build") => 0.3 + 0.55 * build_k,
        _ => 0.3 + 0.5 * build_k,
    }
}

/// The intensity the master deck asks for.
pub fn intensity_for(m: &ShowDeck, bias: f64) -> f64 {
    let energy = (m.energy * (0.5 + 0.5 * m.channel.level) + bias * 0.25).clamp(0.0, 1.0);
    let section = if m.breakdown { Some("breakdown") } else { m.section.as_deref() };
    let mut t = 0.65 * section_intensity(section, m.build_k) + 0.35 * energy;
    if m.section.is_none() && m.build_k <= 0.0 {
        t = 0.2 + 0.7 * energy;
    }
    t.clamp(0.0, 1.0)
}

/// How hard the picture works with the music now, 0 (still) to 1 (a drop).
pub fn drive(m: &ShowDeck) -> f64 {
    let x = ((intensity_for(m, 0.0) - 0.45) / 0.45).clamp(0.0, 1.0);
    x * x * (3.0 - 2.0 * x)
}

/// How much where the record is leans on an effect.
pub fn fx_lean(f: Fx, section: Option<&str>, build_k: f64) -> f64 {
    match f {
        Fx::Mosh => match section {
            Some("build") => 1.5 + 1.5 * build_k,
            Some("breakdown" | "break") => 1.8,
            Some("drop") => 1.2,
            Some("intro" | "outro") => 0.6,
            _ => 1.0,
        },
        _ => 1.0,
    }
}

/// v1's FNV over code units, kept to 31 bits.
fn hash31(s: &str) -> u32 {
    let mut h: u32 = 0x811c_9dc5;
    for c in s.encode_utf16() {
        h = (h ^ c as u32).wrapping_mul(0x0100_0193) & 0x7fff_ffff;
    }
    h
}

/// The hands' taste for a combination.
pub type Taste = Box<dyn Fn(&Combo) -> f64 + Send>;

pub struct Director {
    pub scenes: Vec<SceneMeta>,
    rng: Rng,
    mosh_rng: Rng,
    dissolve_bars: f64,
    /// The section the record is in (a breakdown said as one), as of the last frame.
    now: Option<String>,
    scene: Option<String>,
    from: Option<String>,
    k: f64,
    /// How many of the changes are datamoshes, 0..1 (the pool's); and how many there have been.
    pub mosh_share: f64,
    pub moshes: i64,
    how: SceneChange,
    since_bar: i64,
    held_by: Option<String>,
    last_section: Option<String>,
    /// Held on one scene for good: the rules stay out of it.
    pub locked: bool,
    /// Each scene's figure, by id.
    pub kinds: BTreeMap<String, Figure>,
    pub scores: Option<ComboScores>,
    plan: ShowPlan,
    levels_cache: Option<(String, BTreeMap<String, f64>)>,
    /// The backgrounds there are now (None: all).
    pub grounds_here: Option<BTreeSet<String>>,
    combo: Option<Combo>,
    from_combo: Option<Combo>,
    combo_since_bar: i64,
    ground_since_bar: i64,
    /// One background held by the hands.
    pub held_ground: Option<String>,
    /// How intense the picture should be now (None: no record to say).
    pub target: Option<f64>,
    record: Option<String>,
    record_seed: Option<u32>,
    scene_book: HashMap<String, String>,
    combo_book: HashMap<String, Combo>,
    /// The hands' taste for a combination (taste.rs); None: no lean.
    pub taste: Option<Taste>,
    /// The family a scene belongs to, by id.
    pub families: BTreeMap<String, String>,
    /// How much each scene has been on, seconds, fading with a twenty-minute half-life.
    pub fatigue: BTreeMap<String, f64>,
    /// Calm (-1) to busy (+1).
    pub bias: f64,
    build_k: f64,
    /// Why the scene on is on, in words.
    pub why: String,
}

impl Director {
    pub fn new(scenes: Vec<SceneMeta>, seed: u64) -> Director {
        Director {
            scenes,
            rng: Rng::new(seed),
            mosh_rng: Rng::new(0x6d6f_7368),
            dissolve_bars: DISSOLVE_BARS,
            now: None,
            scene: None,
            from: None,
            k: 1.0,
            mosh_share: 0.0,
            moshes: 0,
            how: SceneChange::Cut,
            since_bar: 0,
            held_by: None,
            last_section: None,
            locked: false,
            kinds: BTreeMap::new(),
            scores: None,
            plan: ShowPlan::default(),
            levels_cache: None,
            grounds_here: None,
            combo: None,
            from_combo: None,
            combo_since_bar: 0,
            ground_since_bar: 0,
            held_ground: None,
            target: None,
            record: None,
            record_seed: None,
            scene_book: HashMap::new(),
            combo_book: HashMap::new(),
            taste: None,
            families: BTreeMap::new(),
            fatigue: BTreeMap::new(),
            bias: 0.0,
            build_k: 0.0,
            why: String::new(),
        }
    }

    pub fn scene(&self) -> Option<&str> {
        self.scene.as_deref()
    }
    pub fn combo(&self) -> Option<&Combo> {
        self.combo.as_ref()
    }
    /// The combination being left (during a dissolve).
    pub fn from_combo(&self) -> Option<&Combo> {
        if self.k < 1.0 { self.from_combo.as_ref() } else { None }
    }
    pub fn bars_on(&self) -> i64 {
        self.since_bar
    }
    pub fn combo_bars(&self) -> i64 {
        self.combo_since_bar
    }
    pub fn ground_bars(&self) -> i64 {
        self.ground_since_bar
    }
    pub fn plan(&self) -> &ShowPlan {
        &self.plan
    }

    pub fn set_plan(&mut self, p: ShowPlan) {
        if p != self.plan {
            self.plan = p;
            self.levels_cache = None;
        }
    }

    pub fn set_scores(&mut self, s: Option<ComboScores>) {
        self.scores = s;
        self.levels_cache = None;
    }

    /// The performer's choice: on until the section turns.
    pub fn choose(&mut self, id: &str, how: SceneChange) {
        if !self.scenes.iter().any(|s| s.id == id) {
            return;
        }
        self.held_by = Some(id.into());
        self.go(id, how, "you chose it", true);
    }

    /// One combination put on by the hands, as it is, held until let go.
    pub fn play(&mut self, c: Combo, how: SceneChange) {
        if !self.scenes.iter().any(|s| s.id == c.scene) {
            return;
        }
        self.locked = true;
        if self.scene.as_deref() != Some(c.scene.as_str()) {
            let id = c.scene.clone();
            self.go(&id, how, "you put it on", true);
        }
        self.set_combo(c);
        self.why = "you put it on".into();
    }

    fn grounds_now(&self) -> BTreeSet<String> {
        if let Some(h) = &self.held_ground {
            return BTreeSet::from([h.clone()]);
        }
        match &self.grounds_here {
            Some(g) if !g.is_empty() => g.clone(),
            _ => COMBO_GROUNDS.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn here_list(&self) -> Vec<&'static str> {
        let here = self.grounds_now();
        COMBO_GROUNDS.iter().copied().filter(|g| here.contains(*g)).collect()
    }

    /// `c`'s weight within its scene: the plan's, less as it looks worse.
    pub fn weigh(&self, c: &Combo) -> f64 {
        ComboScores::weigh(c, &self.plan, self.scores.as_ref())
    }

    /// The combinations of `scene` with their weights, the backgrounds here now.
    pub fn weighted(&self, scene: &str) -> Vec<(Combo, f64)> {
        let kind = self.kinds.get(scene).copied().unwrap_or(Figure::None);
        combos_of(scene, kind, &self.here_list(), Fx::ALL_REF).into_iter().map(|c| {
            let w = self.weigh(&c);
            (c, w)
        }).collect()
    }

    /// The record's own look: a third of the backgrounds and two in five of the styles leaned on.
    pub fn affinity(&self, c: &Combo) -> f64 {
        let Some(seed) = self.record_seed else { return 1.0 };
        let mut k = 1.0;
        if !c.world() && hash31(&format!("{seed}|g|{}", c.ground)) % 100 < 35 {
            k *= 2.5;
        }
        if hash31(&format!("{seed}|s|{}.{}", c.scene, c.style)) % 100 < 40 {
            k *= 1.8;
        }
        k
    }

    /// `c`'s weight now: near the target, the record's look, the taste, the effect's lean.
    pub fn lean_now(&self, c: &Combo, w: f64) -> f64 {
        if w <= 0.0 {
            return 0.0;
        }
        let mut k = self.affinity(c) * self.taste.as_ref().map(|t| t(c)).unwrap_or(1.0) * fx_lean(c.fx, self.now.as_deref(), self.build_k);
        if let (Some(t), Some(i)) = (self.target, self.scores.as_ref().and_then(|s| s.intensity(c))) {
            let d = i - t;
            k *= (-d * d / (2.0 * INTENSITY_WIDTH * INTENSITY_WIDTH)).exp();
        }
        w * k
    }

    fn new_record(&mut self, m: &ShowDeck) {
        let id = m.track_id.map(|i| i.to_string()).or_else(|| m.title.clone());
        if id == self.record {
            return;
        }
        self.record_seed = id.as_deref().map(hash31);
        self.record = id;
        self.scene_book.clear();
        self.combo_book.clear();
    }

    /// Each scene's level (0: muted, or none of its looks on with the backgrounds here).
    pub fn levels(&mut self) -> BTreeMap<String, f64> {
        let key = self.grounds_now().into_iter().collect::<Vec<_>>().join(",");
        if let Some((k, l)) = &self.levels_cache
            && *k == key
        {
            return l.clone();
        }
        let here = self.here_list();
        let l: BTreeMap<String, f64> = self
            .scenes
            .iter()
            .map(|sc| {
                let level = self.plan.scene_level(&sc.id);
                let kind = self.kinds.get(&sc.id).copied().unwrap_or(Figure::None);
                let on = level > 0.0 && combos_of(&sc.id, kind, &here, Fx::ALL_REF).iter().any(|c| self.weigh(c) > 0.0);
                (sc.id.clone(), if on { level } else { 0.0 })
            })
            .collect();
        self.levels_cache = Some((key, l.clone()));
        l
    }

    fn set_combo(&mut self, c: Combo) {
        if self.combo.as_ref().map(|x| x.ground.as_str()) != Some(c.ground.as_str()) {
            self.ground_since_bar = 0;
        }
        self.combo = Some(c);
        self.combo_since_bar = 0;
    }

    fn pick_combo(&mut self, keep_ground: bool, keep_style: bool) {
        let Some(scene) = self.scene.clone() else { return };
        let all = self.weighted(&scene);
        let mut pool = all.clone();
        let narrow = |f: &dyn Fn(&Combo) -> bool| all.iter().filter(|(c, w)| *w > 0.0 && f(c)).cloned().collect::<Vec<_>>();
        if let Some(now) = &self.combo {
            if keep_ground && self.ground_since_bar < GROUND_HOLD_BARS {
                let same = narrow(&|c: &Combo| c.ground == now.ground || c.world());
                if !same.is_empty() {
                    pool = same;
                }
            }
            if keep_style && now.scene == scene {
                let same = narrow(&|c: &Combo| c.style == now.style && (c.ground == now.ground || c.world()));
                if !same.is_empty() {
                    pool = same;
                }
            }
        }
        let leaned: Vec<(Combo, f64)> = pool.iter().map(|(c, w)| (c.clone(), self.lean_now(c, *w))).collect();
        let d = self.rng.next_f64();
        let pick = pick_by_weight(&leaned, d).unwrap_or_else(|| {
            // every combination of the scene is off: drawn as it is, on black
            let kind = self.kinds.get(&scene).copied().unwrap_or(Figure::None);
            Combo::new("black", &scene, styles_of_figure(kind)[0])
        });
        self.set_combo(pick);
    }

    fn tire(&mut self, dt: f64) {
        if dt <= 0.0 {
            return;
        }
        let k = 0.5f64.powf(dt / FATIGUE_HALF_LIFE);
        for v in self.fatigue.values_mut() {
            *v *= k;
        }
        if let Some(on) = &self.scene {
            *self.fatigue.entry(on.clone()).or_default() += dt;
        }
    }

    pub fn family_fatigue(&self) -> BTreeMap<String, f64> {
        let mut out = BTreeMap::new();
        for (k, v) in &self.fatigue {
            if let Some(f) = self.families.get(k) {
                *out.entry(f.clone()).or_default() += v;
            }
        }
        out
    }

    /// The scenes on — all of them, if none is.
    pub fn on(&mut self) -> Vec<SceneMeta> {
        let l = self.levels();
        let on: Vec<SceneMeta> = self.scenes.iter().filter(|s| l.get(&s.id).copied().unwrap_or(1.0) > 0.0).cloned().collect();
        if on.is_empty() { self.scenes.clone() } else { on }
    }

    pub fn next(&mut self, by: i64, how: SceneChange) {
        let on = self.on();
        if on.is_empty() {
            return;
        }
        let i = on.iter().position(|s| Some(s.id.as_str()) == self.scene.as_deref());
        let n = ((i.map(|i| i as i64 + by).unwrap_or(0)).rem_euclid(on.len() as i64)) as usize;
        let id = on[n].id.clone();
        self.choose(&id, how);
    }

    fn go(&mut self, id: &str, mut how: SceneChange, why: &str, may_mosh: bool) {
        if self.scene.as_deref() == Some(id) {
            return;
        }
        if how == SceneChange::Mosh
            || (may_mosh && self.scene.is_some() && self.mosh_share > 0.0 && self.mosh_rng.next_f64() < mosh_chance(self.mosh_share, self.now.as_deref(), how == SceneChange::Hit))
        {
            how = SceneChange::Mosh;
            self.moshes += 1;
        }
        self.dissolve_bars = dissolve_for(self.now.as_deref());
        self.why = why.into();
        self.from = self.scene.take();
        self.from_combo = self.combo.clone();
        self.scene = Some(id.into());
        self.how = how;
        self.k = if how == SceneChange::Dissolve { 0.0 } else { 1.0 };
        self.since_bar = 0;
        self.pick_combo(true, false);
    }

    /// The scenes that suit the frame, best first.
    pub fn fitting(&mut self, s: &ShowState) -> Vec<SceneMeta> {
        let m = s.master();
        let energy = (m.energy * (0.5 + 0.5 * m.channel.level) + self.bias * 0.25).clamp(0.0, 1.0);
        let family = self.scene.as_ref().and_then(|sc| self.families.get(sc)).cloned();
        let section = m.section.clone();
        let has_cover = m.cover_rgb.is_some();
        let tired = self.family_fatigue();
        let cam_on = s.num("cam.on") > 0.5 && s.num("cam.light") > 0.08;
        let cam_motion = s.num("cam.motion");
        let milk_ok = s.num("milk.ok") >= 0.5;
        let levels = self.levels();
        let mut out: Vec<(f64, SceneMeta)> = vec![];
        for sc in self.on() {
            let needs = |n: &str| sc.needs.iter().any(|x| x == n);
            if (needs("cover") && !has_cover) || needs("words") || (needs("camera") && !cam_on) || (needs("milk") && !milk_ok) {
                continue;
            }
            let mut score = 0.0;
            if needs("camera") {
                score += 2.5 * cam_motion - 0.5;
            }
            let (lo, hi) = sc.energy;
            if energy >= lo && energy <= hi {
                score += 2.0;
            } else {
                score -= (if energy < lo { lo - energy } else { energy - hi }) * 4.0;
            }
            if let Some(sec) = &section {
                if sc.sections.contains(sec) {
                    score += 3.0;
                } else if !sc.sections.is_empty() {
                    score -= 1.0;
                } else {
                    score += 2.5;
                }
            }
            if let Some(lean) = s.genome.0.get(&format!("scene.{}", sc.id)) {
                score += lean - 1.0;
            }
            score += sc.priority;
            let level = levels.get(&sc.id).copied().unwrap_or(1.0);
            if level > 0.0 {
                score += level.log2().clamp(-2.0, 2.0) * 0.5;
            }
            score -= self.fatigue.get(&sc.id).copied().unwrap_or(0.0) / 60.0 / level.max(0.1);
            let fam = self.families.get(&sc.id);
            if let Some(f) = fam {
                score -= tired.get(f).copied().unwrap_or(0.0) / 120.0;
            }
            if let (Some(on_fam), Some(f)) = (&family, fam)
                && Some(sc.id.as_str()) != self.scene.as_deref()
                && f != on_fam
            {
                score += 0.6;
            }
            out.push((score, sc));
        }
        out.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        out.into_iter().map(|o| o.1).collect()
    }

    fn booked(&self, section: Option<&str>, fits: &[SceneMeta]) -> Option<String> {
        let was = self.scene_book.get(section?)?;
        if Some(was.as_str()) == self.scene.as_deref() {
            return None;
        }
        fits.iter().take(4).any(|f| &f.id == was).then(|| was.clone())
    }

    fn mosh_combo(&mut self, was: &Combo, drop: bool) {
        if self.combo.as_ref() != Some(was)
            && self.mosh_share > 0.0
            && self.mosh_rng.next_f64() < mosh_chance(self.mosh_share, self.now.as_deref(), drop) * if drop { 1.0 } else { 0.5 }
        {
            self.moshes += 1;
        }
    }

    /// One frame: the scene for it, and the change under way moved on: (scene, the one
    /// being left, how far across).
    pub fn direct(&mut self, s: &ShowState, moments: &[ShowEvent]) -> (Option<String>, Option<String>, f64) {
        if self.scenes.is_empty() {
            return (None, None, 1.0);
        }
        let m = s.master().clone();
        let (mut phrase, mut section, mut drop, mut bar) = (false, false, false, false);
        for e in moments.iter().filter(|e| e.master) {
            match e.kind {
                EventKind::Bar => bar = true,
                EventKind::Phrase => phrase = true,
                EventKind::Section => section = true,
                EventKind::Drop => drop = true,
                _ => {}
            }
        }
        if bar {
            self.since_bar += 1;
            self.ground_since_bar += 1;
            self.combo_since_bar += 1;
        }
        self.new_record(&m);
        self.now = if m.breakdown { Some("breakdown".into()) } else { m.section.clone() };
        self.build_k = m.build_k;
        self.target = (m.playing || m.bpm.is_some()).then(|| intensity_for(&m, self.bias));
        let mut turned = false;
        if section && m.section != self.last_section {
            self.last_section = m.section.clone();
            turned = true;
            if self.since_bar > 2 {
                self.held_by = None;
            }
        }
        self.tire(s.dt);
        let mut fits = self.fitting(s);
        if fits.is_empty() {
            fits = self.on();
        }
        if self.scene.is_none() {
            let id = fits[0].id.clone();
            self.go(&id, SceneChange::Cut, "the best fit for the start", true);
        } else if self.held_by.is_none() && !self.locked {
            let current = fits.iter().position(|f| Some(f.id.as_str()) == self.scene.as_deref());
            let suits = current.is_some_and(|c| c < 2);
            // how long it stays at least before a phrase may change it (the hands' say per
            // scene); one kept longer than the director's own outlasts a section too, for half
            // of it
            let stay = self.scene.as_deref().and_then(|s| self.plan.stay_of(s)).unwrap_or(KEEP_BARS);
            let on = self.on();
            let soft = if m.breakdown { SceneChange::Dissolve } else { SceneChange::Cut };
            if !on.iter().any(|f| Some(f.id.as_str()) == self.scene.as_deref()) {
                let id = fits[0].id.clone();
                self.go(&id, SceneChange::Dissolve, "the one on was switched off: the best fit", true);
            } else if drop {
                // a drop: a scene full the moment it is on, cut with a hit
                let pick = fits.iter().find(|f| f.instant).unwrap_or(&fits[0]).id.clone();
                if Some(pick.as_str()) != self.scene.as_deref() {
                    self.go(&pick, SceneChange::Hit, "the drop: the best fit that is full at once", true);
                }
            } else if let Some(b) = turned.then(|| self.booked(m.section.as_deref(), &fits)).flatten() {
                let why = format!("the {} again: its scene, as the last time", m.section.clone().unwrap_or_default());
                self.go(&b, soft, &why, true);
            } else if section && !suits && (stay <= KEEP_BARS || self.since_bar * 2 >= stay) {
                let why = format!("the section turned{}: the best fit", m.section.as_ref().map(|s| format!(" to the {s}")).unwrap_or_default());
                let id = fits[0].id.clone();
                self.go(&id, soft, &why, true);
            } else if phrase && self.since_bar >= stay && (!suits || self.rng.next_f64() < 0.35) {
                let pool: Vec<SceneMeta> = fits.iter().take(3).filter(|f| Some(f.id.as_str()) != self.scene.as_deref()).cloned().collect();
                if self.scene.as_deref().is_some_and(|s| s.starts_with("dance-")) && fits.iter().any(|f| f.id == "flock") && self.rng.next_f64() < 0.6 {
                    self.go("flock", SceneChange::Dissolve, "after the dancers, the birds", false);
                } else if !pool.is_empty() {
                    let l = self.levels();
                    let items: Vec<(SceneMeta, f64)> = pool.iter().map(|f| (f.clone(), l.get(&f.id).copied().unwrap_or(1.0))).collect();
                    let d = self.rng.next_f64();
                    let pick = pick_by_weight(&items, d).unwrap_or_else(|| pool[0].clone());
                    let how = if loud(self.now.as_deref()) { SceneChange::Cut } else { SceneChange::Dissolve };
                    self.go(&pick.id, how, "a new phrase: another of the three that fit best", true);
                }
            }
        }
        // the combination
        if self.scene.is_some() && !self.locked {
            let c = self.combo.clone();
            let label = if m.breakdown { Some("breakdown".to_string()) } else { m.section.clone() };
            let booked = if turned { label.as_ref().and_then(|l| self.combo_book.get(l).cloned()) } else { None };
            let scene = self.scene.clone().unwrap();
            // how often its look changes while it is on (the hands' say per scene): the bars
            // between changes over it; none at all at 0
            let turn = self.plan.turn_of(&scene);
            let bars = |b: i64| if turn <= 0.0 { i64::MAX } else { ((b as f64 / turn).round() as i64).max(1) };
            match c {
                None => self.pick_combo(true, false),
                Some(c) if c.scene != scene => self.pick_combo(true, false),
                Some(c) if (!c.world() && !self.grounds_now().contains(&c.ground)) || self.weigh(&c) <= 0.0 => self.pick_combo(false, false),
                Some(c) if booked.as_ref() == Some(&c) => {}
                Some(c) => {
                    if turn <= 0.0 {
                        // its look held while it is on
                    } else if let Some(b) = booked.filter(|b| b.scene == scene && self.weigh(b) > 0.0)
                        && self.rng.next_f64() < 0.75
                    {
                        self.set_combo(b);
                        self.mosh_combo(&c, false);
                    } else if drop && self.combo_since_bar > 0 {
                        self.pick_combo(false, false);
                        self.mosh_combo(&c, true);
                    } else if phrase && m.build_k > 0.05 && !m.breakdown && self.combo_since_bar >= bars(4) {
                        self.pick_combo(true, false);
                        self.mosh_combo(&c, false);
                    } else if phrase && self.ground_since_bar >= bars(GROUND_HOLD_BARS) && self.rng.next_f64() < 0.5 {
                        self.pick_combo(false, false);
                        self.mosh_combo(&c, false);
                    } else if (turned && self.combo_since_bar > 2) || (phrase && self.combo_since_bar >= bars(STYLE_BARS) && self.rng.next_f64() < 0.5) {
                        self.pick_combo(true, false);
                        self.mosh_combo(&c, false);
                    }
                }
            }
            if turned && let (Some(l), Some(sc)) = (label, self.scene.clone()) {
                self.scene_book.entry(l.clone()).or_insert(sc);
                if let Some(now) = self.combo.clone() {
                    self.combo_book.entry(l).or_insert(now);
                }
            }
        }
        if self.k < 1.0 {
            let bar_seconds = 240.0 / m.bpm.unwrap_or(120.0);
            self.k = (self.k + s.dt / (bar_seconds * self.dissolve_bars)).clamp(0.0, 1.0);
            if self.k >= 1.0 {
                self.from = None;
            }
        }
        (self.scene.clone(), if self.k < 1.0 { self.from.clone() } else { None }, self.k)
    }

    /// Whether the last change was a hit (the engine flashes on it).
    pub fn take_hit(&mut self) -> bool {
        let was = self.how == SceneChange::Hit && self.since_bar == 0 && self.k >= 1.0;
        if was {
            self.how = SceneChange::Cut;
        }
        was
    }
}
