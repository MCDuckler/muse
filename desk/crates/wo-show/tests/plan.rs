//! v1's plan tests (app/test/show/show_plan_test.dart), the spec: every level that applies to
//! a look multiplied (a 0 anywhere is never), the shared rows or a scene's own, the cells, the
//! allows, a scene made like another, JSON both ways.
use wo_show::combos::{Combo, Fx, Mask, Mix, OWN_GROUND, styles_of_figure};
use wo_show::plan::{PlanAxis, ScenePlan, ShowPlan, cell_covers, cell_key, cell_matches, cell_of, level_word};
use wo_show::rig::Figure;

fn plain_on_milk() -> Combo {
    Combo::new("milk", "dance-art", "plain")
}

fn styles(f: Figure) -> Vec<String> {
    styles_of_figure(f).into_iter().map(String::from).collect()
}

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

#[test]
fn as_shipped_every_level_that_applies_multiplied() {
    let p = ShowPlan::default();
    let c = plain_on_milk();
    // MilkDrop ×3 · no mask ×2 · normal ×1 · no effect ×4
    assert_eq!(p.look_weight(&c), 24.0);
    assert_eq!(p.look_weight(&Combo { mix: Mix::Contrast, ..c.clone() }), 36.0);
    assert_eq!(p.look_weight(&Combo { ground: "black".into(), ..c.clone() }), 8.0);
    assert_eq!(p.look_weight(&Combo { fx: Fx::Mosh, ..c.clone() }), 1.5);
    assert_eq!(p.look_weight(&Combo { fx: Fx::Both, ..c.clone() }), 0.0);
    assert_eq!(p.look_weight(&Combo { ground: "black".into(), mask: Mask::Keyhole, ..c.clone() }), 0.0);
    assert_eq!(p.look_weight(&Combo { ground: "black".into(), mix: Mix::Add, ..c.clone() }), 0.0);
    assert_eq!(p.look_weight(&Combo { ground: "white".into(), mix: Mix::Screen, ..c.clone() }), 0.0);
    assert!(close(p.look_weight(&Combo { ground: "white".into(), mix: Mix::Contrast, ..c.clone() }), 0.8 * 2.0 * 1.5 * 4.0));
    assert_eq!(p.look_weight(&Combo { style: "contour".into(), ..c.clone() }), 0.0);
    // a world: its style and its effect alone
    assert_eq!(p.look_weight(&Combo::new(OWN_GROUND, "milk", "raw")), 4.0);
    assert_eq!(p.look_weight(&Combo { fx: Fx::Kaleidoscope, ..Combo::new(OWN_GROUND, "milk", "raw") }), 0.25);
    assert_eq!(p.scene_level("flash"), 1.0);
}

#[test]
fn a_level_a_mute_that_keeps_it_and_nothing_else_moved() {
    let c = plain_on_milk();
    let mut p = ShowPlan::default().with_shared(PlanAxis::Ground, "milk", Some(1.5), false, None);
    assert_eq!(p.look_weight(&c), 12.0);
    p = p.with_shared(PlanAxis::Ground, "milk", None, false, Some(true));
    assert_eq!(p.look_weight(&c), 0.0);
    assert_eq!(p.shared_fader(PlanAxis::Ground, "milk"), 1.5, "the level kept");
    assert_eq!(p.with_shared(PlanAxis::Ground, "milk", None, false, Some(false)).look_weight(&c), 12.0);
    let q = ShowPlan::default().with_scene("dance-art", Some(1.0 / 3.0), None);
    assert!(close(q.scene_level("dance-art"), 1.0 / 3.0));
    assert_eq!(q.look_weight(&c), 24.0);
    assert_eq!(q.with_scene("dance-art", None, Some(true)).scene_level("dance-art"), 0.0);
    assert!(!q.with_scene("dance-art", None, Some(true)).is_on(&c));
    assert!(ShowPlan::default().with_shared(PlanAxis::Ground, "milk", Some(3.0), false, None).levels.is_empty());
}

#[test]
fn a_scene_with_its_own_row() {
    let mut p = ShowPlan::default().with_shared(PlanAxis::Ground, "wash", None, false, Some(true)).with_own("kinetic", PlanAxis::Ground, true);
    assert!(p.owns("kinetic", PlanAxis::Ground));
    assert_eq!(p.level_in("kinetic", PlanAxis::Ground, "milk"), 3.0, "copied");
    assert!(p.muted_in("kinetic", PlanAxis::Ground, "wash"), "the mute copied too");
    p = p.with_in("kinetic", PlanAxis::Ground, "milk", Some(0.5), None).with_in("kinetic", PlanAxis::Ground, "wash", None, Some(false));
    assert_eq!(p.level_in("kinetic", PlanAxis::Ground, "milk"), 0.5);
    assert_eq!(p.level_in("kinetic", PlanAxis::Ground, "wash"), 1.0);
    assert_eq!(p.level_in("dance-art", PlanAxis::Ground, "milk"), 3.0, "the others share the row still");
    assert_eq!(p.level_in("dance-art", PlanAxis::Ground, "wash"), 0.0);
    p = p.with_shared(PlanAxis::Ground, "milk", Some(4.0), false, None);
    assert_eq!(p.level_in("kinetic", PlanAxis::Ground, "milk"), 0.5);
    p = p.with_own("kinetic", PlanAxis::Ground, false);
    assert_eq!(p.level_in("kinetic", PlanAxis::Ground, "milk"), 4.0);
    assert_eq!(p.of("kinetic"), ScenePlan::default());
}

#[test]
fn cells_multiply_in_and_a_wider_never_is_cut_round_what_is_let_out() {
    let white = cell_key("*", "white", "*", "*", "*");
    let mut p = ShowPlan::default().with_cell("dance-art", &white, Some(0.0));
    let ascii_white = Combo { ground: "white".into(), style: "ascii".into(), ..plain_on_milk() };
    assert_eq!(p.look_weight(&ascii_white), 0.0);
    assert_eq!(p.look_weight(&plain_on_milk()), 24.0, "another background");
    assert!(p.look_weight(&Combo::new("white", "kinetic", "raw")) > 0.0, "another scene");
    p = p.with_unvetoed("dance-art", &cell_key("ascii", "white", "*", "*", "*"), &styles(Figure::Dancers));
    assert!(p.look_weight(&ascii_white) > 0.0);
    assert_eq!(p.look_weight(&Combo { ground: "white".into(), ..plain_on_milk() }), 0.0, "the rest of the never stays");
    let k = cell_of(&plain_on_milk());
    let mut q = ShowPlan::default().scale_cell("dance-art", &k, 0.5).scale_cell("dance-art", &k, 0.5);
    assert_eq!(q.look_weight(&plain_on_milk()), 6.0);
    q = q.scale_cell("dance-art", &k, 2.0).scale_cell("dance-art", &k, 2.0);
    assert!(q.of("dance-art").cells.is_empty());
    let r = ShowPlan::default().with_cell("dance-art", &cell_key("plain", "*", "*", "*", "*"), Some(2.0)).with_cell("dance-art", &k, Some(0.5));
    assert_eq!(r.look_weight(&plain_on_milk()), 24.0);
    let what: Vec<String> = r.factors(&plain_on_milk()).into_iter().map(|f| f.0).collect();
    assert!(what.contains(&"cell plain|*|*|*".to_string()) && what.contains(&format!("cell {k}")));
}

#[test]
fn an_allow_and_a_wider_one_taken_away() {
    let p = ShowPlan::default().with_allow("dance-art", &cell_key("plain", "milk", "*", "*", "*"), true);
    assert!(p.allowed(&plain_on_milk()));
    assert!(!p.with_allow("dance-art", &cell_key("plain", "*", "*", "*", "*"), false).allowed(&plain_on_milk()), "a wider one takes the narrower away");
}

#[test]
fn a_scene_made_like_another() {
    let p = ShowPlan::default()
        .with_in("dance-art", PlanAxis::Style, "ascii", Some(0.5), None)
        .with_in("dance-art", PlanAxis::Style, "mono", None, Some(true))
        .with_own("dance-art", PlanAxis::Mix, true)
        .with_cell("dance-art", &cell_key("ascii", "white", "*", "*", "*"), Some(0.0))
        .with_cell("dance-art", &cell_key("mono", "milk", "*", "*", "*"), Some(0.0))
        .with_scene("dance-art", Some(2.0), None)
        .copy_scene("dance-art", "kinetic", &styles(Figure::Kinetic));
    let k = p.of("kinetic");
    assert_eq!(k.styles.into_iter().collect::<Vec<_>>(), vec![("ascii".to_string(), 0.5)]);
    assert!(!k.off.contains("style.mono"), "kinetic has no mono");
    assert_eq!(k.own.keys().copied().collect::<Vec<_>>(), vec![PlanAxis::Mix]);
    assert_eq!(k.cells.keys().cloned().collect::<Vec<_>>(), vec![cell_key("ascii", "white", "*", "*", "*")]);
    assert_eq!(k.level, 1.0, "how often it comes is its own");
}

#[test]
fn the_effects_a_row_like_the_others() {
    let mosh = Combo { fx: Fx::Mosh, ..Combo::new("milk", "kinetic", "raw") };
    let plain = Combo::new("milk", "kinetic", "raw");
    let mut p = ShowPlan::default()
        .with_own("kinetic", PlanAxis::Fx, true)
        .with_in("kinetic", PlanAxis::Fx, "mosh", Some(4.0), None)
        .with_in("kinetic", PlanAxis::Fx, "none", Some(1.0), None);
    assert!(p.look_weight(&mosh) > p.look_weight(&plain));
    assert_eq!(p.level_in("flash", PlanAxis::Fx, "mosh"), 0.25);
    p = p.with_cell("kinetic", &cell_key("*", "milk", "*", "*", "mosh"), Some(0.0));
    assert_eq!(p.look_weight(&mosh), 0.0);
    assert!(p.look_weight(&plain) > 0.0);
    assert_eq!(cell_of(&mosh), "raw|milk|none|normal|mosh");
    assert!(cell_matches("raw|milk|none|normal", &mosh));
    assert!(!cell_matches("raw|milk|none|normal|none", &mosh));
    assert!(cell_covers("raw|milk|*|*", "raw|milk|none|normal|mosh"));
    let q = ShowPlan::default().with_cell("kinetic", &cell_key("raw", "milk", "*", "*", "*"), Some(0.0)).with_unvetoed("kinetic", &cell_of(&mosh), &styles(Figure::Kinetic));
    assert!(q.look_weight(&mosh) > 0.0);
    assert_eq!(q.look_weight(&plain), 0.0);
    assert_eq!(ShowPlan::from_json(Some(&serde_json::from_str(&q.to_json().to_string()).unwrap())), q);
}

#[test]
fn json_both_ways_as_shipped_is_nothing() {
    assert_eq!(ShowPlan::default().to_json(), serde_json::json!({}));
    let p = ShowPlan::default()
        .with_scene("glide", Some(1.0 / 3.0), None)
        .with_scene("flock", None, Some(true))
        .with_shared(PlanAxis::Ground, "wash", None, false, Some(true))
        .with_shared(PlanAxis::Mix, "add", Some(2.0), false, None)
        .with_own("kinetic", PlanAxis::Ground, true)
        .with_in("dance-art", PlanAxis::Shot, "fisheye", Some(0.25), None)
        .with_cell("dance-art", &cell_key("ascii", "white", "*", "*", "*"), Some(0.0))
        .with_allow("type3d", &cell_key("raw", "milk", "none", "contrast", "*"), true)
        .with_takes("white", "add", true);
    let back = ShowPlan::from_json(Some(&serde_json::from_str(&p.to_json().to_string()).unwrap()));
    assert_eq!(back, p);
    assert!(back.takes("white", "add"));
    assert!(!back.takes("white", "screen"));
    assert_eq!(ShowPlan::from_json(None), ShowPlan::default());
}

#[test]
fn a_level_in_words() {
    assert_eq!(level_word(0.0), "off");
    assert_eq!(level_word(1.0 / 3.0), "×1/3");
    assert_eq!(level_word(0.3333), "×1/3");
    assert_eq!(level_word(0.25), "×1/4");
    assert_eq!(level_word(1.5), "×1.5");
    assert_eq!(level_word(2.0), "×2");
}

#[test]
fn a_plan_v1_wrote_reads_and_writes_back_the_same() {
    // the shape of a show.json plan as v1 writes it
    let v1 = r#"{"scenes":{"dance-art":{"level":2.0,"styles":{"ascii":0.5},"shots":{"fisheye":0.25},"own":{"mix":{"normal":1.0,"add":0.0}},"off":["style.mono"],"cells":{"plain|white|*|*":0.0},"allow":["raw|milk|none|contrast"]}},"levels":{"ground":{"milk":2.0}},"off":["ground.wash"]}"#;
    let j: serde_json::Value = serde_json::from_str(v1).unwrap();
    let p = ShowPlan::from_json(Some(&j));
    assert_eq!(p.of("dance-art").level, 2.0);
    assert_eq!(p.to_json(), j);
}
