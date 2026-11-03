//! What the show puts on, as a combination of five (v1: show_combos.dart): a background, a
//! scene, the scene's style, a mask and a blend — and an effect. How often each comes is the
//! plan's say (plan.rs). A scene or style that is a world of its own has one combination: on
//! its own background, unmasked, as drawn.
use crate::json::Named;
use crate::named;
use crate::rig::{Figure, Ground, RigGround};

named!(pub enum Mask { None = "none", Keyhole = "keyhole", Inverted = "inverted" });
named!(pub enum Mix { Normal = "normal", Add = "add", Screen = "screen", Contrast = "contrast" });
named!(
    /// The transformation layer: none; the kaleidoscope; the slit-scan; the slit-scan then the
    /// kaleidoscope of it; the datamosh held over the whole picture.
    pub enum Fx { None = "none", Kaleidoscope = "kaleidoscope", Slit = "slit", Both = "both", Mosh = "mosh" }
);

impl Fx {
    /// Every effect, as a slice for combos_of.
    pub const ALL_REF: &'static [Fx] = &[Fx::None, Fx::Kaleidoscope, Fx::Slit, Fx::Both, Fx::Mosh];
}

/// The backgrounds, by key: a ground's kind, and its variant after a dot.
pub const COMBO_GROUNDS: &[&str] = &["black", "white", "milk", "wash", "pulse.grid", "pulse.rays", "pulse.smoke", "pulse.stars", "field.drift", "cover", "camera"];

/// The background of a world: its own.
pub const OWN_GROUND: &str = "own";

/// The ground a background's key means (with the dim it has always had).
pub fn ground_of_key(key: &str) -> RigGround {
    let (kind, field) = match key.split_once('.') {
        Some((k, f)) => (k, Some(f)),
        None => (key, None),
    };
    let g = |kind, field: Option<&str>, dim| RigGround { kind, field: field.map(str::to_owned), dim, knobs: vec![] };
    match kind {
        "white" => g(Ground::White, None, 1.0),
        "milk" => g(Ground::Milk, None, 1.0),
        "wash" => g(Ground::Wash, None, 1.0),
        "pulse" => g(Ground::Pulse, Some(field.unwrap_or("grid")), 1.0),
        "field" => g(Ground::Field, Some(field.unwrap_or("drift")), 0.6),
        "cover" => g(Ground::Cover, None, 0.6),
        "camera" => g(Ground::Camera, None, 0.8),
        _ => RigGround::default(),
    }
}

/// A ground's key, the other way.
pub fn key_of_ground(g: &RigGround) -> String {
    match g.kind {
        Ground::Pulse => format!("pulse.{}", g.field.as_deref().unwrap_or("grid")),
        Ground::Field => format!("field.{}", g.field.as_deref().unwrap_or("drift")),
        k => k.name().to_owned(),
    }
}

/// The image treatments any scene may go through (dance_fx.frag's), as styles.
pub const TREATMENT_STYLES: &[&str] = &["ascii", "dither", "halftone", "thermal", "lines", "contour", "crt", "slit"];

/// A figure's styles: its own where it has them, else the scene as drawn and the treatments.
pub fn styles_of_figure(f: Figure) -> Vec<&'static str> {
    match f {
        // (not v1's fluid: the Rust stage has no fluid sim, P5)
        Figure::Dancers => vec!["plain", "mono", "trails", "ascii", "dither", "chrono", "contour", "halftone", "thermal", "lines", "viewports", "disco", "crt", "slit", "dust"],
        Figure::Birds => vec!["ink", "sky", "embers", "neon", "wire", "chrono", "ascii", "dither", "contour", "halftone", "thermal", "lines", "radar", "crt"],
        Figure::Words => vec!["poster", "serif", "grotesk", "wide", "mono", "marker", "light"],
        Figure::None | Figure::Meme => vec!["raw"],
        _ => std::iter::once("raw").chain(TREATMENT_STYLES.iter().copied()).collect(),
    }
}

/// Whether a figure's style is its own drawing (the figure lit and drawn for it).
pub fn own_style(f: Figure) -> bool {
    matches!(f, Figure::Dancers | Figure::Birds | Figure::Words)
}

/// The scenes that are a world of their own, whatever the style.
pub const WORLD_SCENES: &[&str] = &["milk", "siebenschlaefer"];

/// The styles that are a world of their own, by `figure.style`.
pub const WORLD_STYLES: &[&str] = &["dancers.disco", "dancers.viewports", "birds.sky"];

pub fn is_world(scene: &str, kind: Figure, style: &str) -> bool {
    WORLD_SCENES.contains(&scene) || kind == Figure::None || WORLD_STYLES.contains(&format!("{}.{style}", kind.name()).as_str())
}

/// One combination.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Combo {
    pub ground: String,
    pub scene: String,
    pub style: String,
    pub mask: Mask,
    pub mix: Mix,
    pub fx: Fx,
}

impl Combo {
    pub fn new(ground: &str, scene: &str, style: &str) -> Combo {
        Combo { ground: ground.into(), scene: scene.into(), style: style.into(), mask: Mask::None, mix: Mix::Normal, fx: Fx::None }
    }

    pub fn world(&self) -> bool {
        self.ground == OWN_GROUND
    }

    /// `ground|scene|style|mask|mix`, and `|fx` where it has one.
    pub fn key(&self) -> String {
        let fx = if self.fx == Fx::None { String::new() } else { format!("|{}", self.fx.name()) };
        format!("{}|{}|{}|{}|{}{fx}", self.ground, self.scene, self.style, self.mask.name(), self.mix.name())
    }

    pub fn from_key(key: &str) -> Option<Combo> {
        let p: Vec<&str> = key.split('|').collect();
        if p.len() != 5 && p.len() != 6 {
            return None;
        }
        let fx = if p.len() == 6 { Fx::by_name(p[5])? } else { Fx::None };
        Some(Combo { ground: p[0].into(), scene: p[1].into(), style: p[2].into(), mask: Mask::by_name(p[3])?, mix: Mix::by_name(p[4])?, fx })
    }
}

impl std::fmt::Display for Combo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.key())
    }
}

/// The framings of a figure's camera, by key.
pub fn shots_of_figure(f: Figure) -> Vec<&'static str> {
    match f {
        Figure::Dancers => vec![
            "dancers.front", "dancers.medium", "dancers.close", "dancers.wide", "dancers.extremeLow", "dancers.extremeHigh", "dancers.extremeFront", "dancers.fisheye", "dancers.fisheyeLow",
        ],
        Figure::Birds => vec!["birds.wide", "birds.front", "birds.low", "birds.high", "birds.fish", "birds.fishLow"],
        _ => vec![],
    }
}

/// Every framing there is.
pub fn all_shots() -> Vec<&'static str> {
    let mut v = shots_of_figure(Figure::Dancers);
    v.extend(shots_of_figure(Figure::Birds));
    v
}

/// The combinations of one scene (`kind` its figure): every background, style, mask, blend
/// and effect — or, for a world, its style under each effect. `grounds` and `fxs` narrow them.
pub fn combos_of(scene: &str, kind: Figure, grounds: &[&str], fxs: &[Fx]) -> Vec<Combo> {
    let mut out = vec![];
    for style in styles_of_figure(kind) {
        if is_world(scene, kind, style) {
            for &fx in fxs {
                out.push(Combo { fx, ..Combo::new(OWN_GROUND, scene, style) });
            }
            continue;
        }
        for g in grounds {
            for &mask in Mask::ALL {
                for &mix in Mix::ALL {
                    for &fx in fxs {
                        out.push(Combo { ground: (*g).into(), scene: scene.into(), style: style.into(), mask, mix, fx });
                    }
                }
            }
        }
    }
    out
}

/// One of `items` by `d` (0..1), each as likely as its weight; None where none weighs.
pub fn pick_by_weight<T: Clone>(items: &[(T, f64)], d: f64) -> Option<T> {
    let total: f64 = items.iter().map(|(_, w)| if *w > 0.0 { *w } else { 0.0 }).sum();
    if total <= 0.0 {
        return None;
    }
    let mut x = d * total;
    for (i, w) in items {
        if *w <= 0.0 {
            continue;
        }
        x -= w;
        if x < 0.0 {
            return Some(i.clone());
        }
    }
    items.iter().rev().find(|(_, w)| *w > 0.0).map(|(i, _)| i.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_go_both_ways_and_an_old_key_has_no_effect() {
        let c = Combo { mask: Mask::Keyhole, mix: Mix::Contrast, ..Combo::new("pulse.grid", "kinetic", "ascii") };
        assert_eq!(c.key(), "pulse.grid|kinetic|ascii|keyhole|contrast");
        assert_eq!(Combo::from_key(&c.key()), Some(c.clone()));
        let m = Combo { fx: Fx::Mosh, ..c.clone() };
        assert_eq!(m.key(), "pulse.grid|kinetic|ascii|keyhole|contrast|mosh");
        assert_eq!(Combo::from_key(&m.key()), Some(m));
        assert_eq!(Combo::from_key("a|b|c|nope|add"), None);
        assert_eq!(Combo::from_key("a|b|c"), None);
    }

    #[test]
    fn grounds_by_key() {
        assert_eq!(ground_of_key("field.drift").dim, 0.6);
        assert_eq!(ground_of_key("pulse").field.as_deref(), Some("grid"));
        assert_eq!(ground_of_key("nonsense").kind, Ground::Black);
        for k in COMBO_GROUNDS {
            assert_eq!(key_of_ground(&ground_of_key(k)), *k);
        }
    }

    #[test]
    fn a_scene_has_every_combination_and_a_world_one_per_effect() {
        let k = combos_of("kinetic", Figure::Kinetic, COMBO_GROUNDS, Fx::ALL);
        assert_eq!(k.len(), 9 * 11 * 3 * 4 * 5, "styles × grounds × masks × blends × effects");
        let m = combos_of("milk", Figure::None, COMBO_GROUNDS, Fx::ALL);
        assert_eq!(m.len(), 5);
        assert!(m.iter().all(Combo::world));
        // the dancers' disco is a world, their plain is not
        let d = combos_of("dance-art", Figure::Dancers, &["black"], &[Fx::None]);
        assert_eq!(d.iter().filter(|c| c.style == "disco").count(), 1);
        assert_eq!(d.iter().filter(|c| c.style == "plain").count(), 12);
    }

    #[test]
    fn picked_by_weight() {
        let items = [("a", 1.0), ("b", 0.0), ("c", 3.0)];
        assert_eq!(pick_by_weight(&items, 0.0), Some("a"));
        assert_eq!(pick_by_weight(&items, 0.24), Some("a"));
        assert_eq!(pick_by_weight(&items, 0.26), Some("c"));
        assert_eq!(pick_by_weight(&items, 1.0), Some("c"));
        assert_eq!(pick_by_weight::<&str>(&[("x", 0.0)], 0.5), None);
    }
}
