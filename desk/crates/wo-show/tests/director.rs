//! v1's director tests (app/test/show/show_director_test.dart), the spec: scenes turned off are
//! stepped past and never reached for, though chosen by name one still goes on; fatigue and
//! families; the bias; combinations by weight with the background held; the hands' one
//! combination held; a launch kept through the section turn it landed on.
use std::collections::{BTreeMap, BTreeSet};

use wo_show::combos::{Combo, Mask, Mix};
use wo_show::deck::{Channel, ShowDeck};
use wo_show::director::{Director, SceneChange};
use wo_show::events::{EventKind, ShowEvent};
use wo_show::plan::{PlanAxis, ShowPlan, cell_key};
use wo_show::rig::{Figure, SceneMeta};
use wo_show::state::ShowState;

fn deck(name: &str, section: Option<&str>, energy: f64, level: f64) -> ShowDeck {
    ShowDeck { name: name.into(), section: section.map(String::from), energy, channel: Channel { level, ..Default::default() }, ..Default::default() }
}

fn frame(section: Option<&str>, energy: f64, dt: f64) -> ShowState {
    ShowState { a: deck("A", section, energy, 1.0), b: deck("B", None, 0.0, 0.0), dt, ..Default::default() }
}

fn st() -> ShowState {
    frame(Some("drop"), 0.8, 0.0)
}

fn make() -> Director {
    let one = SceneMeta { priority: 3.0, ..SceneMeta::new("one") };
    Director::new(vec![one, SceneMeta::new("two"), SceneMeta::new("three")], 1)
}

fn ev(k: EventKind) -> ShowEvent {
    ShowEvent::on_master(k)
}

#[test]
fn the_arrows_step_past_a_scene_that_is_off() {
    let mut d = make();
    d.set_plan(ShowPlan::default().with_scene("two", None, Some(true)));
    d.choose("one", SceneChange::Dissolve);
    d.next(1, SceneChange::Dissolve);
    assert_eq!(d.scene(), Some("three"));
    d.next(1, SceneChange::Dissolve);
    assert_eq!(d.scene(), Some("one"));
    d.next(-1, SceneChange::Dissolve);
    assert_eq!(d.scene(), Some("three"));
}

#[test]
fn the_director_never_reaches_for_one_however_well_it_fits_but_by_name_it_goes_on() {
    let mut d = make();
    d.set_plan(ShowPlan::default().with_scene("one", None, Some(true)));
    assert!(!d.fitting(&st()).iter().any(|s| s.id == "one"));
    d.direct(&st(), &[]);
    assert_ne!(d.scene(), Some("one"));
    d.choose("one", SceneChange::Dissolve);
    assert_eq!(d.scene(), Some("one"));
}

#[test]
fn one_switched_off_while_it_is_on_goes_at_once() {
    let mut d = make();
    d.direct(&st(), &[]);
    assert_eq!(d.scene(), Some("one"));
    d.set_plan(ShowPlan::default().with_scene("one", None, Some(true)));
    d.direct(&st(), &[]);
    assert_ne!(d.scene(), Some("one"));
    d.choose("one", SceneChange::Dissolve);
    d.direct(&st(), &[]);
    assert_eq!(d.scene(), Some("one"), "the hands' choice holds");
    d.locked = true;
    d.direct(&st(), &[]);
    assert_eq!(d.scene(), Some("one"));
}

#[test]
fn every_one_off_is_none_off() {
    let mut d = make();
    d.set_plan(ShowPlan::default().with_scene("one", None, Some(true)).with_scene("two", None, Some(true)).with_scene("three", None, Some(true)));
    assert_eq!(d.on().len(), 3);
    d.direct(&st(), &[]);
    assert!(d.scene().is_some());
}

#[test]
fn what_has_been_on_a_lot_scores_less_another_family_a_little_more() {
    let mut d = make();
    d.families = BTreeMap::from([("one".into(), "geometric".into()), ("two".into(), "figurative".into()), ("three".into(), "geometric".into())]);
    d.choose("one", SceneChange::Dissolve);
    let f = frame(Some("drop"), 0.8, 1.0);
    for _ in 0..1200 {
        d.direct(&f, &[]);
    }
    assert!(d.fatigue["one"] > 600.0);
    let order: Vec<String> = d.fitting(&f).into_iter().map(|s| s.id).collect();
    assert_eq!(order[0], "two", "the other family first: {order:?}");
}

#[test]
fn the_bias_moves_the_energy_a_scene_is_matched_against() {
    let calm = SceneMeta { energy: (0.0, 0.4), ..SceneMeta::new("calm") };
    let busy = SceneMeta { energy: (0.6, 1.0), ..SceneMeta::new("busy") };
    let mut d = Director::new(vec![calm, busy], 1);
    let mid = frame(None, 0.5, 0.0);
    d.bias = -1.0;
    assert_eq!(d.fitting(&mid)[0].id, "calm");
    d.bias = 1.0;
    assert_eq!(d.fitting(&mid)[0].id, "busy");
}

#[test]
fn a_combination_by_weight_its_background_held_for_phrases() {
    let mut d = make();
    d.kinds = BTreeMap::from([("one".into(), Figure::Kinetic), ("two".into(), Figure::Kinetic), ("three".into(), Figure::Kinetic)]);
    d.set_plan(ShowPlan::default().with_shared(PlanAxis::Ground, "black", None, false, Some(true)).with_shared(PlanAxis::Mix, "add", None, false, Some(true)));
    d.grounds_here = Some(BTreeSet::from(["black".into(), "milk".into(), "wash".into()]));
    let f = frame(None, 0.5, 0.5);
    d.choose("one", SceneChange::Dissolve);
    d.locked = true;
    d.direct(&f, &[]);
    d.locked = false;
    let first = d.combo().unwrap().clone();
    assert_eq!(first.scene, "one");
    assert!(["milk", "wash"].contains(&first.ground.as_str()), "black is off: {first}");
    assert_ne!(first.mix, Mix::Add);
    d.locked = true;
    for i in 0..15 {
        let mut m = vec![ev(EventKind::Bar)];
        if i % 8 == 7 {
            m.push(ev(EventKind::Phrase));
        }
        d.direct(&f, &m);
        assert_eq!(d.combo().unwrap().ground, first.ground);
    }
    d.locked = false;
    let mut changed = false;
    for i in 0..2000 {
        let mut m = vec![ev(EventKind::Bar)];
        if i % 8 == 7 {
            m.push(ev(EventKind::Phrase));
        }
        d.direct(&f, &m);
        if d.combo().unwrap().ground != first.ground {
            changed = true;
            break;
        }
    }
    assert!(changed, "the other background comes round");
    d.held_ground = Some("white".into());
    d.direct(&f, &[]);
    assert_eq!(d.combo().unwrap().ground, "white");
}

#[test]
fn the_hands_play_one_combination_on_as_it_is_held() {
    let mut d = make();
    d.kinds = BTreeMap::from([("one".into(), Figure::Kinetic), ("two".into(), Figure::Dancers), ("three".into(), Figure::Kinetic)]);
    d.direct(&st(), &[]);
    let c = Combo { mask: Mask::Inverted, mix: Mix::Contrast, ..Combo::new("white", "two", "plain") };
    d.play(c.clone(), SceneChange::Cut);
    assert_eq!(d.scene(), Some("two"));
    assert_eq!(d.combo(), Some(&c));
    assert!(d.locked);
    for _ in 0..200 {
        d.direct(&st(), &[ev(EventKind::Phrase)]);
    }
    assert_eq!(d.combo(), Some(&c));
}

#[test]
fn a_scene_whose_combinations_are_all_off_is_not_reached_for() {
    let mut d = make();
    d.kinds = BTreeMap::from([("one".into(), Figure::Kinetic), ("two".into(), Figure::Kinetic), ("three".into(), Figure::Kinetic)]);
    d.set_plan(ShowPlan::default().with_cell("one", &cell_key("*", "milk", "*", "*", "*"), Some(0.0)).with_cell("one", &cell_key("*", "wash", "*", "*", "*"), Some(0.0)));
    d.grounds_here = Some(BTreeSet::from(["milk".into(), "wash".into()]));
    assert_eq!(d.levels()["one"], 0.0);
    assert_eq!(d.on().into_iter().map(|s| s.id).collect::<Vec<_>>(), vec!["two", "three"]);
}

#[test]
fn a_launch_on_the_bar_a_section_turns_on_is_kept_for_that_section() {
    let mut d = make();
    d.direct(&st(), &[]);
    d.choose("two", SceneChange::Dissolve);
    d.direct(&st(), &[ev(EventKind::Bar)]);
    d.direct(&frame(Some("chorus"), 0.8, 0.0), &[ev(EventKind::Section)]);
    assert_eq!(d.scene(), Some("two"), "the hands' choice survives the turn it landed on");
}

#[test]
fn over_a_night_the_scenes_share_the_time_by_their_levels() {
    // three scenes alike but for their levels 2 : 1 : 0.5; phrases every 8 bars, a bar a
    // second; the share each gets should follow its level
    let mut d = Director::new(vec![SceneMeta::new("a"), SceneMeta::new("b"), SceneMeta::new("c")], 7);
    d.set_plan(ShowPlan::default().with_scene("a", Some(2.0), None).with_scene("c", Some(0.5), None));
    let f = frame(None, 0.5, 2.0);
    let mut on: BTreeMap<String, f64> = BTreeMap::new();
    for i in 0..(4 * 3600 / 2) {
        let mut m = vec![ev(EventKind::Bar)];
        if i % 8 == 7 {
            m.push(ev(EventKind::Phrase));
        }
        d.direct(&f, &m);
        *on.entry(d.scene().unwrap().to_string()).or_default() += 2.0;
    }
    let (a, b, c) = (on["a"], on["b"], on["c"]);
    assert!(a > b && b > c, "a {a} b {b} c {c}");
}
