//! The shipped scenes (v1: ui/show/scene.dart): one look of the stage per JSON file in
//! app/assets/show/scenes — what the director reads of it (SceneMeta), its layers (a shader
//! with its samplers and knobs, or a simulation), its post, text and particles — and each as
//! a look (a rig): a shader figure, MilkDrop alone, a field drawn whole, or a simulation.
use std::collections::BTreeMap;
use std::path::Path;

use serde_json::Value;

use crate::json::{knobs, num, obj, strings, text};
use crate::rig::{Figure, Ground, Look, RigFigure, RigFinish, RigGround, SceneMeta, ShowRig};

include!(concat!(env!("OUT_DIR"), "/scenes.rs"));

/// The scenes the Rust stage draws now: the shader scenes (P2) and MilkDrop (P3); the rest of
/// [IN_SCOPE] come with their phases (the sims P5, the dancers P6, the 3D type P8).
pub const DRAWN: &[&str] = &["kinetic", "flash", "blocks", "glide", "drift", "milk"];

/// The backgrounds the Rust stage draws (not the camera): MilkDrop's where the stage has it,
/// the record's cover where there is one.
pub fn grounds_drawn(milk: bool, cover: bool) -> std::collections::BTreeSet<String> {
    let mut g: std::collections::BTreeSet<String> = ["black", "white", "wash", "pulse.grid", "pulse.rays", "pulse.smoke", "pulse.stars", "field.drift"].iter().map(|s| s.to_string()).collect();
    if milk {
        g.insert("milk".into());
    }
    if cover {
        g.insert("cover".into());
    }
    g
}

/// The scenes the Rust stage draws (plan §1): the rest stay v1's until they are ported, or not.
pub const IN_SCOPE: &[&str] = &["kinetic", "flash", "blocks", "glide", "drift", "milk", "fluid", "veins", "dance-art", "type3d"];

#[derive(Clone, Debug, PartialEq)]
pub struct SceneLayer {
    /// A shader drawn over the layer below (shaders/show/<name>.frag) — or a simulation.
    pub shader: Option<String>,
    pub sim: Option<String>,
    pub samplers: Vec<String>,
    pub knobs: Vec<(String, f64)>,
    pub dim: f64,
}

impl SceneLayer {
    /// uM`i`.
    pub fn knob(&self, i: usize) -> f64 {
        let k = format!("m{i}");
        self.knobs.iter().find(|(n, _)| *n == k).map(|(_, v)| *v).unwrap_or(0.0)
    }

    fn from_json(j: &serde_json::Map<String, Value>) -> SceneLayer {
        SceneLayer {
            shader: text(j.get("shader")),
            sim: text(j.get("sim")),
            samplers: strings(j.get("samplers")),
            knobs: knobs(j.get("knobs")),
            dim: num(j.get("dim"), 1.0),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Scene {
    pub id: String,
    pub name: String,
    pub meta: SceneMeta,
    pub layers: Vec<SceneLayer>,
    pub finish: RigFinish,
}

impl Scene {
    pub fn from_json(j: &serde_json::Map<String, Value>) -> Scene {
        let id = text(j.get("id")).unwrap_or_default();
        let post = obj(j.get("post"));
        let p = |k: &str, d: f64| post.map(|p| num(p.get(k), d)).unwrap_or(d);
        let t = obj(j.get("text"));
        let finish = RigFinish {
            trails: p("trails", 0.0).clamp(0.0, 0.92),
            bloom: p("bloom", 0.5),
            fringe: p("fringe", 0.008),
            vignette: p("vignette", 0.6),
            grain: p("grain", 0.5),
            recipe: p("recipe", 0.0).clamp(0.0, 1.0),
            tone: p("tone", 1.0).clamp(0.0, 1.0),
            title: t.is_some_and(|t| t.get("title") == Some(&Value::Bool(true))),
            lyrics: t.is_some_and(|t| t.get("lyrics") == Some(&Value::Bool(true))),
            where_: t.and_then(|t| text(t.get("where"))).unwrap_or_else(|| "low".into()),
            jitter: t.is_some_and(|t| t.get("jitter") == Some(&Value::Bool(true))),
            particles: strings(j.get("particles")),
        };
        Scene {
            name: text(j.get("name")).unwrap_or_else(|| id.clone()),
            meta: SceneMeta::from_json(j),
            layers: j.get("layers").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_object).map(SceneLayer::from_json).collect()).unwrap_or_default(),
            finish,
            id,
        }
    }

    /// Every shader the scene draws with.
    pub fn shaders(&self) -> Vec<String> {
        self.layers.iter().filter_map(|l| l.shader.clone()).collect()
    }

    /// The scene as a rig: its first layer read as a figure (or MilkDrop alone), the post,
    /// the text and the particles the finish.
    pub fn rig(&self) -> ShowRig {
        let finish = self.finish.clone();
        let Some(layer) = self.layers.first() else { return ShowRig { finish, ..Default::default() } };
        if let Some(sim) = &layer.sim {
            let kind = match sim.as_str() {
                "fluid" => Figure::Fluid,
                "physarum" => Figure::Veins,
                "siebenschlaefer" => Figure::Meme,
                "turntable" => Figure::Turntable,
                "flock" => Figure::Birds,
                "words" => Figure::Words,
                "type3d" => Figure::Type3d,
                "dance.art" | "dance.disco" | "dance.neon" | "dance.shadow" => Figure::Dancers,
                _ => Figure::None,
            };
            return ShowRig { figure: RigFigure { kind, ..Default::default() }, finish, ..Default::default() };
        }
        let Some(shader) = &layer.shader else { return ShowRig { finish, ..Default::default() } };
        if layer.samplers.iter().any(|s| s == "milk") {
            return ShowRig { ground: RigGround { kind: Ground::Milk, knobs: layer.knobs.clone(), ..Default::default() }, finish, ..Default::default() };
        }
        if layer.samplers.iter().any(|s| s == "camera") {
            return ShowRig { figure: RigFigure { kind: Figure::Room, knobs: layer.knobs.clone(), ..Default::default() }, finish, ..Default::default() };
        }
        let kind = match shader.as_str() {
            "kinetic" => Figure::Kinetic,
            "blocks" => Figure::Blocks,
            "flash" => Figure::Flash,
            "glide" => Figure::Glide,
            // any other shader is drawn whole, blended with the ground like any figure
            _ => Figure::Field,
        };
        ShowRig { figure: RigFigure { kind, knobs: layer.knobs.clone(), ..Default::default() }, finish, ..Default::default() }
    }

    pub fn look(&self) -> Look {
        Look { id: self.id.clone(), name: self.name.clone(), rig: self.rig(), meta: self.meta.clone(), shipped: true, hero: false, thumb: None }
    }
}

/// Every scene, by id.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SceneBook {
    pub scenes: BTreeMap<String, Scene>,
}

impl SceneBook {
    /// The scene files in `dir`, in their names' order; one bad file is one scene fewer.
    pub fn from_dir(dir: &Path) -> SceneBook {
        let mut paths: Vec<_> = std::fs::read_dir(dir).map(|d| d.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension().is_some_and(|e| e == "json")).collect()).unwrap_or_default();
        paths.sort();
        SceneBook::from_strings(paths.iter().filter_map(|p| std::fs::read_to_string(p).ok()))
    }

    /// The scenes the app ships (taken in at build time).
    pub fn shipped() -> SceneBook {
        SceneBook::from_strings(SHIPPED_SCENES.iter().map(|s| s.to_string()))
    }

    pub fn from_strings(jsons: impl IntoIterator<Item = String>) -> SceneBook {
        let scenes = jsons
            .into_iter()
            .filter_map(|s| serde_json::from_str::<Value>(&s).ok())
            .filter_map(|v| v.as_object().map(Scene::from_json))
            .map(|s| (s.id.clone(), s))
            .collect();
        SceneBook { scenes }
    }

    /// Only the scenes in `ids`.
    pub fn only(&self, ids: &[&str]) -> SceneBook {
        SceneBook { scenes: self.scenes.iter().filter(|(k, _)| ids.contains(&k.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect() }
    }

    pub fn metas(&self) -> Vec<SceneMeta> {
        self.scenes.values().map(|s| s.meta.clone()).collect()
    }

    pub fn looks(&self) -> BTreeMap<String, Look> {
        self.scenes.iter().map(|(k, s)| (k.clone(), s.look())).collect()
    }

    /// Each scene's figure, for the director.
    pub fn kinds(&self) -> BTreeMap<String, Figure> {
        self.scenes.iter().map(|(k, s)| (k.clone(), s.rig().figure.kind)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shipped_scenes_read_as_looks() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/scenes");
        let book = SceneBook::from_dir(&dir);
        assert_eq!(book.scenes.len(), 16);
        let k = book.kinds();
        assert_eq!(k["kinetic"], Figure::Kinetic);
        assert_eq!(k["dance-art"], Figure::Dancers);
        assert_eq!(k["veins"], Figure::Veins);
        assert_eq!(k["drift"], Figure::Field);
        assert_eq!(k["milk"], Figure::None);
        assert_eq!(book.looks()["milk"].rig.ground.kind, Ground::Milk);
        assert_eq!(k["echo"], Figure::Room);
        let ours = book.only(IN_SCOPE);
        assert_eq!(ours.scenes.len(), IN_SCOPE.len(), "every scene in scope is shipped");
        assert!(!ours.scenes.contains_key("flock"));
        let kin = &book.scenes["kinetic"];
        assert_eq!(kin.layers[0].knob(1), 0.0);
        assert_eq!(kin.finish.particles, vec!["sparks"]);
    }
}

#[cfg(test)]
mod shipped_tests {
    use super::*;

    #[test]
    fn the_shipped_scenes_are_the_files() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/scenes");
        assert_eq!(SceneBook::shipped(), SceneBook::from_dir(&dir));
        assert_eq!(SceneBook::shipped().only(DRAWN).scenes.len(), DRAWN.len());
    }
}
