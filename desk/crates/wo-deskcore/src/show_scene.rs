//! A scene's page on the Show page (v1: show_room_scene.dart, show_room_grid.dart): how often
//! it comes; its styles, each a fader with its knobs; the backgrounds, masks, blends and
//! effects as every scene has them, or its own; the grid of its looks, style by background,
//! each square judged in a tap (never, or back) or by its menu (less, more, as it was, let it
//! come however it measured, play it, each mask, blend and effect); its camera's framings;
//! who dances and their moves. And the finish over every scene, the treatments' knobs.
use std::collections::HashMap;

use wo_show::combos::{COMBO_GROUNDS, Combo, Fx, Mask, Mix, OWN_GROUND, WORLD_SCENES, combos_of, is_world, pick_by_weight, shots_of_figure, styles_of_figure};
use wo_show::json::Named;
use wo_show::plan::{PlanAxis, SHARED_AXES, ShowPlan, axis_values, cell_covers, cell_key, cell_of, plan_value};
use wo_show::rig::Figure;
use wo_show::scenes::DRAWN;

use super::{RotationRow, Show, combo_words, value_name};

/// What a square (or one look) is told: a tap (never — or, never or cut already, back), less
/// (×½), more (×2), never, as it was (the levels alone), let it come however it measured,
/// measured again, put on now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SquareDo {
    Tap,
    Less,
    More,
    Never,
    Back,
    Allow,
    Measure,
    Play,
}

/// A treatment's knob, kept as `treatment.knob` (ascii.size).
#[derive(Clone, Debug, PartialEq)]
pub struct TuneRow {
    pub key: String,
    pub label: String,
    pub tip: String,
    pub min: f64,
    pub max: f64,
    pub rest: f64,
    pub value: f64,
}

/// A treatment's knobs, as `tune` has them.
pub fn tune_rows(tune: &std::collections::BTreeMap<String, f64>, treatment: &str) -> Vec<TuneRow> {
    wo_show::treat::tunes_of(treatment)
        .iter()
        .map(|s| TuneRow {
            key: format!("{treatment}.{}", s.knob),
            label: s.label.into(),
            tip: s.tip.into(),
            min: s.min,
            max: s.max,
            rest: s.rest,
            value: wo_show::treat::tune_of(tune, treatment, s.knob),
        })
        .collect()
}

/// A style of the scene: its row, its knobs where a treatment draws it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StyleRow {
    pub row: RotationRow,
    pub knobs: Vec<TuneRow>,
}

/// A scene's backgrounds, masks, blends or effects: as every scene has them (`own` false: what
/// is on, in words), or its own (its rows).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct OwnRows {
    pub axis: String,
    pub title: String,
    pub hint: String,
    pub own: bool,
    pub rows: Vec<RotationRow>,
    pub summary: String,
}

/// One square of the grid: a style on a background, every mask, blend and effect of it (a
/// world's: its effects) — or one look.
#[derive(Clone, Debug, PartialEq)]
pub struct Square {
    pub style: String,
    pub ground: String,
    /// The likeliest of its looks (the one its picture shows).
    pub face: Combo,
    /// Its share of the scene's time.
    pub share: f64,
    /// Every look's levels say none (its style or background off).
    pub levels_off: bool,
    /// The hands said never (to all of it, to some).
    pub never: bool,
    pub some_never: bool,
    /// The measuring keeps all of it out, some of it.
    pub cut: bool,
    pub some_cut: bool,
    /// Comes however it measured.
    pub allowed: bool,
    /// The hands' less or more (a cell over 0).
    pub cell: Option<f64>,
    /// How often NEXT skipped it.
    pub skipped: u32,
    /// On the stage now.
    pub live: bool,
    /// Its background is here (else nothing of it comes now).
    pub here: bool,
    pub note: Option<String>,
    /// What it is, in words.
    pub words: String,
    /// Its face's mask and blend (by name), and key.
    pub mask: String,
    pub mix: String,
    pub key: String,
}

impl Square {
    /// Whether its picture is dimmed: off, or never.
    pub fn dead(&self) -> bool {
        self.levels_off || self.never
    }

    /// Its word under the picture: never, off, not here, cut, its share.
    pub fn word(&self) -> String {
        if self.never {
            "never".into()
        } else if self.levels_off {
            "off".into()
        } else if !self.here {
            "not here".into()
        } else if self.cut {
            "cut".into()
        } else {
            wo_show::shares::share_word(self.share)
        }
    }
}

/// The grid: the styles down (key, name, on), the backgrounds across (key, name, on, here), a
/// row of squares per style (a world's style in a scene with backgrounds: one, its own).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LooksGrid {
    pub styles: Vec<(String, String, bool)>,
    pub grounds: Vec<(String, String, bool, bool)>,
    pub rows: Vec<Vec<Square>>,
    /// How many styles and backgrounds are off and not shown.
    pub hidden: usize,
    pub all: bool,
}

/// A scene's page.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScenePage {
    pub id: String,
    pub name: String,
    /// Its figure (`dancers`, `kinetic`…): what its stills are.
    pub figure: String,
    /// A world of its own (MilkDrop): no backgrounds, masks or blends.
    pub world: bool,
    pub live: bool,
    /// How often it comes.
    pub level: RotationRow,
    /// When it changes: the bars it stays at least before a phrase may change it (None: the
    /// director's own), how often its look changes while it is on (1 as shipped, 0 never).
    pub stay: Option<i64>,
    pub turn: f64,
    pub styles: Vec<StyleRow>,
    pub shared: Vec<OwnRows>,
    pub grid: LooksGrid,
    /// Its camera's framings (none where it has no camera).
    pub shots: Vec<RotationRow>,
    /// The scenes it can be made like (id, name).
    pub others: Vec<(String, String)>,
    /// The dancers dance in it.
    pub dancers: bool,
    /// What the page's last edit said (an off square tapped, a scene copied…).
    pub said: Option<String>,
    pub working: bool,
}

/// One square's masks and blends under an effect (a world's: its effects), each judged alone.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Variants {
    pub title: String,
    pub world: bool,
    /// The effects (key, name, share of the scene's time with this style on this background, on).
    pub fxs: Vec<(String, String, f64, bool)>,
    pub masks: Vec<(String, String)>,
    pub mixes: Vec<(String, String)>,
    /// mask × mix (a world: one row of its effects).
    pub rows: Vec<Vec<Square>>,
}

/// A move of the dancers' bank (dancer.json), with the hands' say on it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MoveRow {
    pub id: String,
    pub style: String,
    pub tier: String,
    pub bpm: f64,
    pub beats: u32,
    pub energy: f64,
    /// A duet's (its pair's name), and which half.
    pub duo: Option<String>,
    pub lead: bool,
    pub on: bool,
    pub star: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct MovesView {
    pub moves: Vec<MoveRow>,
    /// The move asked for, while it waits.
    pub asked: Option<String>,
    /// Where the moves were read from (None: no dancers found).
    pub found: bool,
}

/// The finish over every scene, as the page draws it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FinishView {
    /// The hands' over every scene (else the scene on's own, shown).
    pub mine: bool,
    pub finish: Option<wo_show::rig::RigFinish>,
    pub strength: f64,
    /// The slit-scan's knobs (the effect's, not a style's).
    pub slit: Vec<TuneRow>,
}

/// A square's looks: a world's style, its effects on its own background; else every mask,
/// blend and effect on `ground`.
fn looks_of(scene: &str, kind: Figure, style: &str, ground: &str) -> Vec<Combo> {
    if is_world(scene, kind, style) {
        return Fx::ALL.iter().map(|f| Combo { fx: *f, ..Combo::new(OWN_GROUND, scene, style) }).collect();
    }
    let mut out = Vec::with_capacity(60);
    for m in Mask::ALL {
        for x in Mix::ALL {
            for f in Fx::ALL {
                out.push(Combo { mask: *m, mix: *x, fx: *f, ..Combo::new(ground, scene, style) });
            }
        }
    }
    out
}

/// What the grid needs to judge squares by: the plan, the looks' shares of the scene's time,
/// what NEXT skipped, the look on.
struct Judge<'a> {
    plan: &'a ShowPlan,
    weigh: Weigh,
    shares: HashMap<&'a Combo, f64>,
    skips: HashMap<&'a str, f64>,
    live: Option<&'a Combo>,
    looks: &'a std::collections::BTreeMap<String, wo_show::rig::Look>,
}

/// A scene's part of the plan as tables (plan.rs's base_weight, cells_for and allowed, without
/// working each level and cell out again for each of a grid's thousands of looks).
struct Weigh {
    levels: HashMap<PlanAxis, HashMap<String, f64>>,
    cells: Vec<([String; 5], f64)>,
    allow: Vec<[String; 5]>,
}

impl Weigh {
    fn of(plan: &ShowPlan, scene: &str, styles: &[&str]) -> Weigh {
        let mut levels: HashMap<PlanAxis, HashMap<String, f64>> = HashMap::new();
        levels.insert(PlanAxis::Style, styles.iter().map(|st| (st.to_string(), plan.level_in(scene, PlanAxis::Style, st))).collect());
        for a in [PlanAxis::Ground, PlanAxis::Mask, PlanAxis::Mix, PlanAxis::Fx] {
            levels.insert(a, axis_values(a).into_iter().map(|v| (v.clone(), plan.level_in(scene, a, &v))).collect());
        }
        let sp = plan.of(scene);
        let cells = sp.cells.iter().filter_map(|(k, v)| wo_show::plan::cell_parts(k).map(|p| (p, *v))).collect();
        let allow = sp.allow.iter().filter_map(|k| wo_show::plan::cell_parts(k)).collect();
        Weigh { levels, cells, allow }
    }

    fn level(&self, plan: &ShowPlan, c: &Combo, a: PlanAxis, v: &str) -> f64 {
        self.levels.get(&a).and_then(|m| m.get(v)).copied().unwrap_or_else(|| plan.level_in(&c.scene, a, v))
    }

    fn matches(p: &[String; 5], c: &Combo) -> bool {
        let at = |i: usize, v: &str| p[i] == "*" || p[i] == v;
        at(0, &c.style) && at(1, &c.ground) && at(2, c.mask.name()) && at(3, c.mix.name()) && at(4, c.fx.name())
    }

    /// plan.base_weight.
    fn base(&self, plan: &ShowPlan, c: &Combo) -> f64 {
        let w = self.level(plan, c, PlanAxis::Style, &c.style) * self.level(plan, c, PlanAxis::Fx, c.fx.name());
        if w <= 0.0 || c.world() {
            return w;
        }
        if !plan.takes(&c.ground, c.mask.name()) || !plan.takes(&c.ground, c.mix.name()) {
            return 0.0;
        }
        w * self.level(plan, c, PlanAxis::Ground, &c.ground) * self.level(plan, c, PlanAxis::Mask, c.mask.name()) * self.level(plan, c, PlanAxis::Mix, c.mix.name())
    }

    /// plan.cells_for.
    fn cells(&self, c: &Combo) -> f64 {
        self.cells.iter().filter(|(p, _)| Self::matches(p, c)).map(|(_, v)| *v).product()
    }

    /// plan.allowed.
    fn allowed(&self, c: &Combo) -> bool {
        self.allow.iter().any(|p| Self::matches(p, c))
    }
}

impl Judge<'_> {
    #[allow(clippy::too_many_arguments)]
    fn square(&self, scene: &str, style: &str, ground: &str, looks: Vec<Combo>, here: bool, cell: Option<f64>, note: Option<String>) -> Square {
        let p = self.plan;
        // each look's share, levels and cells, once
        let w: Vec<(f64, f64, f64)> = looks.iter().map(|c| (self.shares.get(c).copied().unwrap_or(0.0), self.weigh.base(p, c), self.weigh.cells(c))).collect();
        let share: f64 = w.iter().map(|x| x.0).sum();
        let levels_off = w.iter().all(|x| x.1 <= 0.0);
        let never = !levels_off && w.iter().filter(|x| x.1 > 0.0).all(|x| x.2 <= 0.0);
        let some_never = !never && w.iter().any(|x| x.1 > 0.0 && x.2 <= 0.0);
        let cut = here && !levels_off && !never && share <= 0.0;
        let some_cut = here && !cut && w.iter().any(|x| x.1 * x.2 > 0.0 && x.0 <= 0.0);
        let allowed = looks.iter().any(|c| self.weigh.allowed(c));
        let face = (0..looks.len()).max_by(|&a, &b| (w[a].0 * 1000.0 + w[a].1).total_cmp(&(w[b].0 * 1000.0 + w[b].1))).map(|i| looks[i].clone()).unwrap_or_else(|| Combo::new(ground, scene, style));
        let skipped = if self.skips.is_empty() { 0 } else { looks.iter().map(|c| self.skips.get(c.key().as_str()).copied().unwrap_or(0.0)).sum::<f64>().round() as u32 };
        let live = self.live.is_some_and(|l| if looks.len() == 1 { *l == looks[0] } else { l.scene == scene && l.style == style && (l.ground == ground || (ground == OWN_GROUND && l.world())) });
        let words = combo_words(&face, self.looks);
        let (mask, mix, key) = (face.mask.name().to_owned(), face.mix.name().to_owned(), face.key());
        Square { mask, mix, key, style: style.into(), ground: ground.into(), face, share, levels_off, never, some_never, cut, some_cut, allowed, cell: cell.filter(|v| *v > 0.0), skipped, live, here, note, words }
    }
}

/// The page's marks of what is on the stage, for the look on now (a kept page is marked again
/// as the director changes looks, not worked out again).
fn mark_live(page: &mut ScenePage, on: Option<&Combo>) {
    let on = on.filter(|c| c.scene == page.id);
    page.live = on.is_some();
    page.level.live = on.is_some();
    for s in &mut page.styles {
        s.row.live = on.is_some_and(|c| c.style == s.row.key);
    }
    for o in &mut page.shared {
        let Some(a) = PlanAxis::by_name(&o.axis) else { continue };
        for r in &mut o.rows {
            r.live = on.is_some_and(|c| (a == PlanAxis::Fx || !c.world()) && plan_value(c, a) == r.key);
        }
    }
    for sq in page.grid.rows.iter_mut().flatten() {
        sq.live = on.is_some_and(|l| l.style == sq.style && (l.ground == sq.ground || (sq.ground == OWN_GROUND && l.world())));
    }
}

impl Show {
    fn kind_of(&self, scene: &str) -> Figure {
        self.direct.director.kinds.get(scene).copied().unwrap_or(Figure::None)
    }

    fn styles_of(&self, scene: &str) -> Vec<String> {
        styles_of_figure(self.kind_of(scene)).into_iter().map(str::to_owned).collect()
    }

    /// A scene's page (`all`: the styles and backgrounds that are off in the grid too).
    pub(crate) fn scene_page(&mut self, id: &str, all: bool) -> Option<ScenePage> {
        self.refresh_shares();
        let d = &self.direct;
        let meta = d.director.scenes.iter().find(|m| m.id == id && DRAWN.contains(&m.id.as_str()))?;
        let key = (id.to_owned(), all, d.director.plan().clone(), d.director.grounds_here.clone(), self.shares.as_ref().map(|s| s.2), d.doc.taste().len(), d.doc.tune(), self.page_said.clone());
        if let Some((k, page)) = &self.page
            && *k == key
        {
            let mut page = page.clone();
            page.working = self.shares_job.is_some();
            mark_live(&mut page, d.director.combo());
            return Some(page);
        }
        let plan = d.director.plan();
        let shares = &self.shares.as_ref().expect("worked out").3;
        let kind = self.kind_of(id);
        let world = WORLD_SCENES.contains(&id) || kind == Figure::None;
        let live_combo = d.director.combo().filter(|c| c.scene == id);
        let here = d.director.grounds_here.clone().unwrap_or_default();
        let tune = d.doc.tune();
        let sp = plan.of(id);
        let name = d.looks.get(id).map_or(id.to_owned(), |l| l.name.clone());
        let level = RotationRow {
            key: id.into(),
            name: "How often".into(),
            level: sp.level,
            on: !sp.muted,
            share: shares.scenes.get(id).copied().unwrap_or(0.0),
            live: live_combo.is_some(),
            note: (sp.weight() > 0.0 && !shares.any_on(id)).then(|| "none of its looks can come: turn a style, a background or a look on below".to_owned()),
        };
        // each row's values' share of the scene's time, in one pass over its looks
        let mut sums: HashMap<(PlanAxis, &str), f64> = HashMap::new();
        for (c, v) in shares.looks_of(id) {
            for (a, x) in [(PlanAxis::Style, c.style.as_str()), (PlanAxis::Ground, c.ground.as_str()), (PlanAxis::Mask, c.mask.name()), (PlanAxis::Mix, c.mix.name()), (PlanAxis::Fx, c.fx.name())] {
                *sums.entry((a, x)).or_insert(0.0) += v;
            }
        }
        let within = |a: PlanAxis, v: &str| sums.get(&(a, v)).copied().unwrap_or(0.0);
        let in_row = |a: PlanAxis, v: &str, name: String, live: bool, note: Option<String>| RotationRow {
            key: v.into(),
            name,
            level: plan.fader_in(id, a, v),
            on: !plan.muted_in(id, a, v),
            share: within(a, v),
            live,
            note,
        };
        let styles: Vec<StyleRow> = styles_of_figure(kind)
            .into_iter()
            .filter(|_| !world || styles_of_figure(kind).len() > 1)
            .map(|st| StyleRow {
                // (a world of its own — on its own background — is said in its square, not here: a
                // row's note is why it cannot come)
                row: in_row(PlanAxis::Style, st, value_name(PlanAxis::Style, st), live_combo.is_some_and(|c| c.style == st), None),
                knobs: tune_rows(&tune, st),
            })
            .collect();
        let shared = SHARED_AXES
            .iter()
            .filter(|a| !world || **a == PlanAxis::Fx)
            .map(|&a| {
                let (title, hint) = match a {
                    PlanAxis::Ground => ("Backgrounds", "what is under it"),
                    PlanAxis::Mask => ("Masks", "where the background shows"),
                    PlanAxis::Mix => ("Blends", "how it and the background meet"),
                    _ => ("Effects", "what is done to it over time and space"),
                };
                let values: Vec<String> = axis_values(a).into_iter().filter(|v| v != "camera").collect();
                let own = plan.owns(id, a);
                let rows = if own {
                    values
                        .iter()
                        .map(|v| {
                            let live = live_combo.is_some_and(|c| (a == PlanAxis::Fx || !c.world()) && plan_value(c, a) == *v);
                            let note = (a == PlanAxis::Ground && !here.contains(v)).then(|| if v == "milk" { "only with MilkDrop on the stage" } else { "only with a record's cover" }.to_owned());
                            in_row(a, v, value_name(a, v), live, note)
                        })
                        .collect()
                } else {
                    vec![]
                };
                let on: Vec<String> = values
                    .iter()
                    .filter(|v| plan.level_in(id, a, v) > 0.0 && within(a, v) > 0.0)
                    .map(|v| format!("{} {}", value_name(a, v), wo_show::shares::share_word(within(a, v))))
                    .collect();
                OwnRows { axis: a.name().into(), title: title.into(), hint: hint.into(), own, rows, summary: if on.is_empty() { "none on".into() } else { on.join(" · ") } }
            })
            .collect();
        // the grid
        let taste = d.doc.taste();
        let judge = Judge {
            plan,
            weigh: Weigh::of(plan, id, &styles_of_figure(kind)),
            shares: shares.looks_of(id).iter().map(|(c, v)| (c, *v)).collect(),
            skips: taste.iter().map(|(k, v)| (k.as_str(), *v)).collect(),
            live: live_combo,
            looks: &d.looks,
        };
        let style_on = |st: &str| plan.level_in(id, PlanAxis::Style, st) > 0.0;
        let ground_on = |g: &str| g == OWN_GROUND || plan.level_in(id, PlanAxis::Ground, g) > 0.0;
        let all_styles: Vec<&str> = styles_of_figure(kind);
        let all_grounds: Vec<&str> = if world { vec![OWN_GROUND] } else { COMBO_GROUNDS.iter().copied().filter(|g| *g != "camera").collect() };
        let shown_styles: Vec<&str> = all_styles.iter().copied().filter(|s| all || style_on(s)).collect();
        let shown_grounds: Vec<&str> = all_grounds.iter().copied().filter(|g| all || ground_on(g)).collect();
        let hidden = all_styles.len() - shown_styles.len() + all_grounds.len() - shown_grounds.len();
        let cells = &sp.cells;
        let rows = shown_styles
            .iter()
            .map(|st| {
                let one = |g: &str, note: Option<String>| {
                    let looks = looks_of(id, kind, st, g);
                    let ok = g == OWN_GROUND || here.contains(g);
                    judge.square(id, st, g, looks, ok, cells.get(&cell_key(st, g, "*", "*", "*")).copied(), note)
                };
                if is_world(id, kind, st) && !world { vec![one(OWN_GROUND, Some("a world of its own".into()))] } else { shown_grounds.iter().map(|g| one(g, None)).collect() }
            })
            .collect();
        let grid = LooksGrid {
            styles: shown_styles.iter().map(|s| (s.to_string(), value_name(PlanAxis::Style, s), style_on(s))).collect(),
            grounds: shown_grounds.iter().map(|g| (g.to_string(), if *g == OWN_GROUND { "Its own".into() } else { value_name(PlanAxis::Ground, g) }, ground_on(g), *g == OWN_GROUND || here.contains(*g))).collect(),
            rows,
            hidden,
            all,
        };
        let shot_names: Vec<&str> = shots_of_figure(kind).into_iter().filter_map(|k| k.split_once('.').map(|(_, n)| n)).collect();
        let total: f64 = shot_names.iter().map(|n| plan.shot_level(id, n)).sum();
        let shots = shot_names
            .iter()
            .map(|n| RotationRow {
                key: n.to_string(),
                name: shot_name(n),
                level: plan.fader_in(id, PlanAxis::Shot, n),
                on: !plan.muted_in(id, PlanAxis::Shot, n),
                share: if total <= 0.0 { 0.0 } else { plan.shot_level(id, n) / total },
                live: false,
                note: None,
            })
            .collect();
        let others = d
            .director
            .scenes
            .iter()
            .filter(|m| m.id != id && DRAWN.contains(&m.id.as_str()) && !WORLD_SCENES.contains(&m.id.as_str()) && self.kind_of(&m.id) != Figure::None)
            .map(|m| (m.id.clone(), d.looks.get(&m.id).map_or(m.id.clone(), |l| l.name.clone())))
            .collect();
        let page = ScenePage {
            id: id.into(),
            name,
            figure: kind.name().into(),
            world,
            live: live_combo.is_some(),
            level,
            stay: plan.stay_of(id),
            turn: plan.turn_of(id),
            styles,
            shared,
            grid,
            shots,
            others,
            dancers: kind == Figure::Dancers,
            said: self.page_said.clone(),
            working: self.shares_job.is_some(),
        };
        let _ = meta;
        self.page = Some((key, page.clone()));
        Some(page)
    }

    /// One square's masks and blends under the effect `fx` (a world's: its effects).
    pub(crate) fn variants(&mut self, scene: &str, style: &str, ground: &str, fx: &str) -> Option<Variants> {
        self.refresh_shares();
        let d = &self.direct;
        let kind = self.kind_of(scene);
        let plan = d.director.plan();
        let shares = &self.shares.as_ref()?.3;
        let taste = d.doc.taste();
        let judge = Judge {
            plan,
            weigh: Weigh::of(plan, scene, &styles_of_figure(kind)),
            shares: shares.looks_of(scene).iter().map(|(c, v)| (c, *v)).collect(),
            skips: taste.iter().map(|(k, v)| (k.as_str(), *v)).collect(),
            live: d.director.combo(),
            looks: &d.looks,
        };
        let here = d.director.grounds_here.clone().unwrap_or_default();
        let world = ground == OWN_GROUND;
        let fx = Fx::by_name(fx).unwrap_or(Fx::None);
        let cells = &plan.of(scene).cells;
        let one = |c: Combo, note: Option<String>| {
            let key = cell_of(&c);
            judge.square(scene, style, ground, vec![c], world || here.contains(ground), cells.get(&key).copied(), note)
        };
        let rows = if world {
            vec![Fx::ALL.iter().map(|f| one(Combo { fx: *f, ..Combo::new(OWN_GROUND, scene, style) }, None)).collect()]
        } else {
            Mask::ALL
                .iter()
                .map(|m| {
                    Mix::ALL
                        .iter()
                        .map(|x| {
                            let note = (!(plan.takes(ground, m.name()) && plan.takes(ground, x.name()))).then(|| format!("{} does not take this (Rotation)", value_name(PlanAxis::Ground, ground)));
                            one(Combo { mask: *m, mix: *x, fx, ..Combo::new(ground, scene, style) }, note)
                        })
                        .collect()
                })
                .collect()
        };
        let name = d.looks.get(scene).map_or(scene.to_owned(), |l| l.name.clone());
        let fxs = Fx::ALL
            .iter()
            .map(|f| {
                let share = shares.looks_of(scene).iter().filter(|(c, _)| c.fx == *f && c.style == style && c.ground == ground).map(|(_, v)| v).sum();
                (f.name().to_owned(), value_name(PlanAxis::Fx, f.name()), share, plan.level_in(scene, PlanAxis::Fx, f.name()) > 0.0)
            })
            .collect();
        Some(Variants {
            title: format!("{name} · {}{}", value_name(PlanAxis::Style, style).to_lowercase(), if world { String::new() } else { format!(" on {}", value_name(PlanAxis::Ground, ground)) }),
            world,
            fxs,
            masks: Mask::ALL.iter().map(|m| (m.name().to_owned(), value_name(PlanAxis::Mask, m.name()))).collect(),
            mixes: Mix::ALL.iter().map(|m| (m.name().to_owned(), value_name(PlanAxis::Mix, m.name()))).collect(),
            rows,
        })
    }

    /// A square (`key` a cell: `style|ground|*|*`) or one look (`key` its own cell) of
    /// `scene` judged — `looks` what it stands for.
    fn judge_square(&mut self, scene: &str, key: &str, looks: Vec<Combo>, what: SquareDo) {
        let plan = self.direct.director.plan().clone();
        let styles = self.styles_of(scene);
        let here = self.direct.director.grounds_here.clone().unwrap_or_default();
        let Some(first) = looks.first().cloned() else { return };
        let square = {
            let shares = self.shares.as_ref().map(|s| s.3.looks_of(scene).iter().map(|(c, v)| (c, *v)).collect()).unwrap_or_default();
            let weigh = Weigh::of(&plan, scene, &styles_of_figure(self.kind_of(scene)));
            let judge = Judge { plan: &plan, weigh, shares, skips: Default::default(), live: None, looks: &self.direct.looks };
            let ok = first.world() || here.contains(&first.ground);
            judge.square(scene, &first.style, &first.ground, looks, ok, None, None)
        };
        let next = match what {
            SquareDo::Tap if square.levels_off => {
                let st = if first.style == "raw" { "This style".to_owned() } else { first.style.clone() };
                let g = if first.world() { String::new() } else { format!(" on {}", value_name(PlanAxis::Ground, &first.ground)) };
                self.page_said = Some(format!("{st}{g} is off by its levels: turn the style{} on above", if first.world() { "" } else { " and the background" }));
                return;
            }
            SquareDo::Tap if square.never || square.cut => {
                let mut p = plan.clone();
                if square.never {
                    p = p.with_unvetoed(scene, key, &styles);
                }
                if square.cut {
                    p = p.with_allow(scene, key, true);
                }
                p
            }
            SquareDo::Tap | SquareDo::Never => plan.with_cell(scene, key, Some(0.0)),
            SquareDo::Less => plan.scale_cell(scene, key, 0.5),
            SquareDo::More => plan.with_unvetoed(scene, key, &styles).scale_cell(scene, key, 2.0),
            SquareDo::Back => {
                let mut p = plan.with_unvetoed(scene, key, &styles).with_allow(scene, key, false);
                // the cells inside this square go too
                let inner: Vec<String> = p.of(scene).cells.keys().filter(|k| cell_covers(key, k)).cloned().collect();
                for k in inner {
                    p = p.with_cell(scene, &k, None);
                }
                p
            }
            SquareDo::Allow => plan.with_allow(scene, key, true),
            SquareDo::Measure => plan.with_allow(scene, key, false),
            SquareDo::Play => {
                let face = square.face.clone();
                self.page_said = Some(format!("On: {}", square.words));
                self.direct.put_on(face, None);
                return;
            }
        };
        self.page_said = None;
        self.set_plan(next);
    }

    /// The page's edits (ShowEdit's scene-page kinds); the rest are the rotation's.
    pub(crate) fn edit_page(&mut self, e: super::ShowEdit) {
        use super::ShowEdit as E;
        use wo_show::plan::LEVEL_MOST;
        let plan = self.direct.director.plan().clone();
        match e {
            E::InLevel(scene, a, v, x) => {
                if let Some(a) = PlanAxis::by_name(&a) {
                    self.set_plan(plan.with_in(&scene, a, &v, Some(x.clamp(0.0, LEVEL_MOST)), None));
                }
            }
            E::InOn(scene, a, v, on) => {
                if let Some(a) = PlanAxis::by_name(&a) {
                    // back on from a level of 0: at 1
                    let p = if on && plan.fader_in(&scene, a, &v) <= 0.0 { plan.with_in(&scene, a, &v, Some(1.0), None) } else { plan };
                    self.set_plan(p.with_in(&scene, a, &v, None, Some(!on)));
                }
            }
            E::Own(scene, a, own) => {
                if let Some(a) = PlanAxis::by_name(&a) {
                    self.set_plan(plan.with_own(&scene, a, own));
                }
            }
            E::Square(scene, style, ground, what) => {
                let kind = self.kind_of(&scene);
                let looks = looks_of(&scene, kind, &style, &ground);
                self.judge_square(&scene, &cell_key(&style, &ground, "*", "*", "*"), looks, what);
            }
            E::Look(key, what) => {
                if let Some(c) = Combo::from_key(&key) {
                    let scene = c.scene.clone();
                    self.judge_square(&scene, &cell_of(&c), vec![c], what);
                }
            }
            E::CopyFrom(to, from) => {
                let styles = self.styles_of(&to);
                self.set_plan(plan.copy_scene(&from, &to, &styles));
                let name = |s: &str| self.direct.looks.get(s).map_or(s.to_owned(), |l| l.name.clone());
                self.page_said = Some(format!("{} is like {} now: its styles, its own backgrounds, masks and blends, the looks judged", name(&to), name(&from)));
            }
            E::PlayScene(scene) => {
                let looks: Vec<(Combo, f64)> = self.shares.as_ref().map(|s| s.3.looks_of(&scene).iter().filter(|(_, v)| *v > 0.0).cloned().collect()).unwrap_or_default();
                let dice = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.5, |d| (d.subsec_nanos() % 10_007) as f64 / 10_007.0);
                let kind = self.kind_of(&scene);
                let pick = pick_by_weight(&looks, dice).or_else(|| combos_of(&scene, kind, &["black"], Fx::ALL).into_iter().next());
                if let Some(c) = pick {
                    self.page_said = Some(format!("On: {}", combo_words(&c, &self.direct.looks)));
                    self.direct.put_on(c, None);
                }
            }
            E::Stay(scene, bars) => self.set_plan(plan.with_when(&scene, Some(bars), None)),
            E::Turn(scene, k) => self.set_plan(plan.with_when(&scene, None, Some(k))),
            E::MoveOn(id, on) => self.direct.doc.set_move_on(&id, on),
            E::MoveStar(id, star) => self.direct.doc.set_move_star(&id, star),
            E::Audition(id) => self.direct.audition(&id),
            E::Tune(key, v) => {
                let mut tune = self.direct.doc.tune();
                match v {
                    Some(v) => tune.insert(key, v),
                    None => tune.remove(&key),
                };
                self.direct.doc.set_tune(&tune);
            }
            E::Finish(f) => self.direct.doc.set_finish(f.as_ref()),
            E::Set(x) => self.edit_set(x),
            E::Fave(x) => self.edit_fave(x),
            E::Strength(s) => self.direct.doc.set_strength(s),
            _ => {}
        }
    }

    /// The dancers' moves, with the hands' say on each (read once from the first dancer's
    /// dancer.json: the choreography draws from its bank).
    pub(crate) fn moves(&mut self) -> MovesView {
        if self.moves.is_none() {
            self.moves = Some(read_moves());
        }
        let bank = self.moves.as_ref().expect("read");
        let (off, stars) = (self.direct.doc.moves_off(), self.direct.doc.move_stars());
        MovesView {
            moves: bank.iter().map(|m| MoveRow { on: !off.contains(&m.id), star: stars.contains(&m.id), ..m.clone() }).collect(),
            asked: self.direct.auditioning().map(str::to_owned),
            found: !bank.is_empty(),
        }
    }

    /// The finish over every scene, the blend's strength, the slit-scan's knobs.
    pub(crate) fn finish(&self) -> FinishView {
        let d = &self.direct;
        let fin = d.doc.finish();
        FinishView { mine: fin.is_some(), finish: fin.or_else(|| d.cue().rig.finish.clone().into()), strength: d.doc.strength(), slit: tune_rows(&d.doc.tune(), "slit") }
    }
}

/// The first dancer's moves (the choreography's bank), as dancer.json says them.
fn read_moves() -> Vec<MoveRow> {
    let Some(dir) = wo_show::scenes::dance_dir() else { return vec![] };
    let Some(j) = wo_show::scenes::DANCERS.iter().find_map(|(id, _)| std::fs::read_to_string(dir.join(id).join("dancer.json")).ok()) else { return vec![] };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&j) else { return vec![] };
    v.get("moves")
        .and_then(|m| m.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|m| {
                    let s = |k: &str| m.get(k).and_then(|x| x.as_str()).unwrap_or_default().to_owned();
                    let n = |k: &str| m.get(k).and_then(|x| x.as_f64()).unwrap_or(0.0);
                    let id = m.get("id")?.as_str()?.to_owned();
                    Some(MoveRow {
                        id,
                        style: s("style"),
                        tier: s("tier"),
                        bpm: n("bpm"),
                        beats: n("beats") as u32,
                        energy: n("energy"),
                        duo: m.get("duo").and_then(|x| x.as_str()).map(str::to_owned),
                        lead: n("part") == 0.0,
                        on: true,
                        star: false,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// A framing's name (v1: _shotName).
pub fn shot_name(shot: &str) -> String {
    match shot {
        "front" => "Front",
        "medium" => "Medium",
        "close" => "Close",
        "wide" => "Wide",
        "extremeLow" => "Floor up",
        "extremeHigh" => "From above",
        "extremeFront" => "Face on",
        "fisheye" | "fish" => "Fisheye",
        "fisheyeLow" | "fishLow" => "Fisheye floor",
        "low" => "Low",
        "high" => "High",
        s => s,
    }
    .to_owned()
}

#[cfg(test)]
mod tests {
    use super::super::ShowEdit as E;
    use super::*;

    /// The page once the shares are worked out for the plan as it is.
    fn settled(show: &mut Show, id: &str, all: bool) -> ScenePage {
        let t = std::time::Instant::now();
        loop {
            let p = show.scene_page(id, all).expect("a drawn scene");
            if show.shares_job.is_none() && show.shares.as_ref().is_some_and(|s| s.0 == *show.direct.director.plan()) {
                return show.scene_page(id, all).unwrap();
            }
            let _ = p;
            assert!(t.elapsed().as_secs() < 10, "the shares never came");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    fn square<'a>(p: &'a ScenePage, style: &str, ground: &str) -> &'a Square {
        p.grid.rows.iter().flatten().find(|s| s.style == style && s.ground == ground).unwrap_or_else(|| panic!("{style} on {ground}"))
    }

    #[test]
    #[ignore = "a measure"]
    fn how_long_a_page_takes() {
        let mut show = Show::new_in(None, None);
        show.tick(&wo_wire::Frame::default(), None);
        for id in ["kinetic", "dance-art"] {
            settled(&mut show, id, false);
            show.page = None;
            let t = std::time::Instant::now();
            show.scene_page(id, false);
            let cold = t.elapsed();
            let t = std::time::Instant::now();
            show.scene_page(id, false);
            eprintln!("{id}: cold {cold:?}, kept {:?}", t.elapsed());
        }
        let t = std::time::Instant::now();
        show.variants("kinetic", "raw", "white", "none");
        eprintln!("variants {:?}", t.elapsed());
    }

    #[test]
    fn a_scenes_page_judges_its_looks_and_is_kept() {
        let dir = std::env::temp_dir().join(format!("wo-show-page-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("show.json");
        std::fs::write(&file, r#"{"v":1,"pool":{}}"#).unwrap();
        let mut show = Show::new_in(None, Some(file.clone()));
        show.tick(&wo_wire::Frame::default(), None);
        assert!(show.scene_page("flock", false).is_none(), "not a scene the Rust stage draws");
        let p = settled(&mut show, "kinetic", false);
        assert_eq!(p.figure, "kinetic");
        assert!(p.styles.iter().any(|s| s.row.key == "raw") && p.styles.iter().any(|s| s.row.key == "ascii" && s.knobs.len() == 4), "as drawn, and the treatments with their knobs");
        assert_eq!(p.shared.len(), 4);
        assert!(p.shared.iter().all(|o| !o.own && !o.summary.is_empty()));
        assert_eq!(p.grid.rows.len(), p.grid.styles.len());
        assert!(p.grid.hidden > 0, "contour is off as shipped");
        let all = settled(&mut show, "kinetic", true);
        assert_eq!(all.grid.hidden, 0);
        assert!(all.grid.styles.iter().any(|(s, _, on)| s == "contour" && !on));
        // the squares' shares are the scene's time
        let t: f64 = p.grid.rows.iter().flatten().map(|s| s.share).sum();
        assert!((t - 1.0).abs() < 1e-6, "{t}");
        assert!(!square(&p, "raw", "milk").here, "no MilkDrop here");
        // a tap: never; again: back
        show.edit(E::Square("kinetic".into(), "raw".into(), "white".into(), SquareDo::Tap));
        let p = settled(&mut show, "kinetic", false);
        let sq = square(&p, "raw", "white");
        assert!(sq.never && sq.share == 0.0 && sq.word() == "never");
        show.edit(E::Square("kinetic".into(), "raw".into(), "white".into(), SquareDo::Tap));
        let sq = square(&settled(&mut show, "kinetic", false), "raw", "white").clone();
        assert!(!sq.never && sq.share > 0.0);
        // more; as it was
        show.edit(E::Square("kinetic".into(), "raw".into(), "white".into(), SquareDo::More));
        assert_eq!(square(&settled(&mut show, "kinetic", false), "raw", "white").cell, Some(2.0));
        show.edit(E::Square("kinetic".into(), "raw".into(), "white".into(), SquareDo::Back));
        assert_eq!(square(&settled(&mut show, "kinetic", false), "raw", "white").cell, None);
        // one look of it never: the square part never
        let v = show.variants("kinetic", "raw", "white", "none").unwrap();
        assert_eq!((v.rows.len(), v.rows[0].len()), (3, 4));
        show.edit(E::Look(v.rows[0][0].face.key(), SquareDo::Never));
        assert!(square(&settled(&mut show, "kinetic", false), "raw", "white").some_never);
        // a style off: its squares off; a tap says why
        show.edit(E::InOn("kinetic".into(), "style".into(), "raw".into(), false));
        let p = settled(&mut show, "kinetic", true);
        assert!(square(&p, "raw", "black").levels_off);
        show.edit(E::Square("kinetic".into(), "raw".into(), "black".into(), SquareDo::Tap));
        assert!(show.scene_page("kinetic", false).unwrap().said.is_some_and(|s| s.contains("off by its levels")));
        show.edit(E::InOn("kinetic".into(), "style".into(), "raw".into(), true));
        // its own backgrounds: white off for it alone
        show.edit(E::Own("kinetic".into(), "ground".into(), true));
        show.edit(E::InOn("kinetic".into(), "ground".into(), "white".into(), false));
        let p = settled(&mut show, "kinetic", false);
        assert!(p.shared[0].own && p.shared[0].rows.iter().any(|r| r.key == "white" && !r.on));
        let plan = show.direct.director.plan().clone();
        assert!(plan.level_in("blocks", PlanAxis::Ground, "white") > 0.0, "the others' untouched");
        // when it changes
        show.edit(E::Stay("kinetic".into(), Some(16)));
        show.edit(E::Turn("kinetic".into(), 0.0));
        let p = settled(&mut show, "kinetic", false);
        assert_eq!((p.stay, p.turn), (Some(16), 0.0));
        // made like it; one of a scene's looks on
        show.edit(E::CopyFrom("blocks".into(), "kinetic".into()));
        assert!(show.direct.director.plan().owns("blocks", PlanAxis::Ground));
        show.edit(E::PlayScene("glide".into()));
        assert_eq!(show.direct.director.scene(), Some("glide"), "nothing plays: on now");
        // the dancers: their framings, their moves
        let d = settled(&mut show, "dance-art", false);
        assert!(d.dancers && d.shots.len() == 9);
        show.edit(E::InLevel("dance-art".into(), "shot".into(), "fisheye".into(), 0.0));
        assert_eq!(show.direct.director.plan().shot_level("dance-art", "fisheye"), 0.0);
        let m = show.moves();
        assert!(m.found && m.moves.len() > 100, "the bank: {}", m.moves.len());
        let id = m.moves[0].id.clone();
        show.edit(E::MoveOn(id.clone(), false));
        show.edit(E::MoveStar(m.moves[1].id.clone(), true));
        show.edit(E::Audition(m.moves[2].id.clone()));
        let m = show.moves();
        assert!(!m.moves[0].on && m.moves[1].star && m.asked.as_deref() == Some(m.moves[2].id.as_str()));
        // the knobs, the finish
        show.edit(E::Tune("ascii.size".into(), Some(2.0)));
        let p = settled(&mut show, "kinetic", false);
        assert_eq!(p.styles.iter().find(|s| s.row.key == "ascii").unwrap().knobs[0].value, 2.0);
        assert!(!show.finish().mine);
        show.edit(E::Finish(Some(wo_show::rig::RigFinish { grain: 0.0, ..Default::default() })));
        show.edit(E::Strength(0.5));
        assert!(show.finish().mine && show.finish().strength == 0.5);
        show.save_doc(true);
        drop(show);
        let back = Show::new_in(None, Some(file));
        let doc = &back.direct.doc;
        assert_eq!(doc.moves_off(), vec![id]);
        assert!(doc.finish().is_some_and(|f| f.grain == 0.0) && doc.tune().get("ascii.size") == Some(&2.0));
        assert!(back.direct.director.plan().owns("kinetic", PlanAxis::Ground));
        drop(back);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
