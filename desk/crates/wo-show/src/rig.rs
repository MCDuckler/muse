//! The rig (v1: show_rig.dart): what the stage draws, as layers — the ground under
//! everything, the figure with its own ways of being rendered, how the figure sits on the
//! ground (the blend), the transformation, and the finish over both. A look is a rig with a
//! name and the director's facts (SceneMeta).
use serde_json::{Value, json};

use crate::combos::{Combo, Fx, Mask, Mix, ground_of_key, own_style};
use crate::json::{Named, Obj, f, knobs, knobs_json, num, obj, str_or, strings, text};
use crate::named;

named!(
    /// What lies under the figure.
    pub enum Ground { Black = "black", Wash = "wash", Milk = "milk", Camera = "camera", Field = "field", Cover = "cover", Pulse = "pulse", White = "white" }
);
named!(
    /// What stands in the middle (none: a look that is its own whole picture).
    pub enum Figure {
        None = "none", Dancers = "dancers", Birds = "birds", Kinetic = "kinetic", Blocks = "blocks", Flash = "flash", Glide = "glide",
        Turntable = "turntable", Fluid = "fluid", Veins = "veins", Meme = "meme", Words = "words", Field = "field", Room = "room", Type3d = "type3d"
    }
);
named!(pub enum Shade { Auto = "auto", Textured = "textured", Chrome = "chrome", Silhouette = "silhouette", Flat = "flat", Toon = "toon" });
named!(pub enum Dressing { Auto = "auto", None = "none", Disco = "disco", Neon = "neon", Shadow = "shadow", Studio = "studio", Sky = "sky" });
named!(
    pub enum Treatment {
        Auto = "auto", Raw = "raw", Ascii = "ascii", Dither = "dither", Halftone = "halftone", Thermal = "thermal", Lines = "lines", Contour = "contour",
        Chrono = "chrono", Trails = "trails", Fluid = "fluid", Viewports = "viewports", Radar = "radar", Crt = "crt", Slit = "slit"
    }
);
named!(
    /// When a change the hands ask for lands.
    pub enum Quantise { Now = "now", Beat = "beat", Bar = "bar", Phrase = "phrase" }
);

/// The pulse field's variants (shaders/show/pulse.frag, by uM1).
pub const PULSE_VARIANTS: &[&str] = &["grid", "rays", "smoke", "stars"];

pub fn pulse_variant(name: Option<&str>) -> usize {
    PULSE_VARIANTS.iter().position(|v| *v == name.unwrap_or("grid")).unwrap_or(0)
}

#[derive(Clone, Debug, PartialEq)]
pub struct RigGround {
    pub kind: Ground,
    /// A field's shader or simulation (`drift`…); a pulse's variant (`grid`…).
    pub field: Option<String>,
    /// How much of it, 0..1.
    pub dim: f64,
    /// uM1..uM4 for a field's shader.
    pub knobs: Vec<(String, f64)>,
}

impl Default for RigGround {
    fn default() -> Self {
        RigGround { kind: Ground::Black, field: None, dim: 1.0, knobs: vec![] }
    }
}

impl RigGround {
    pub fn label(&self) -> String {
        match self.kind {
            Ground::Field => format!("field {}", self.field.as_deref().unwrap_or("?")),
            Ground::Pulse => format!("pulse {}", self.field.as_deref().unwrap_or("grid")),
            k => k.name().to_owned(),
        }
    }

    pub fn to_json(&self) -> Value {
        let mut m = Obj::new();
        m.insert("kind".into(), self.kind.name().into());
        if let Some(fl) = &self.field {
            m.insert("field".into(), fl.clone().into());
        }
        if self.dim != 1.0 {
            m.insert("dim".into(), f(self.dim));
        }
        if !self.knobs.is_empty() {
            m.insert("knobs".into(), knobs_json(&self.knobs));
        }
        Value::Object(m)
    }

    pub fn from_json(j: &Obj) -> RigGround {
        RigGround {
            kind: Ground::of(j.get("kind"), Ground::Black),
            field: str_or(j.get("field")),
            dim: num(j.get("dim"), 1.0).clamp(0.0, 1.0),
            knobs: knobs(j.get("knobs")),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RigFigure {
    pub kind: Figure,
    pub shade: Shade,
    pub dressing: Dressing,
    pub treatment: Treatment,
    /// The figure's own named look (a dancer's art, a flock's look), held by the hands.
    pub style: Option<String>,
    /// uM1..uM4 for a shader figure.
    pub knobs: Vec<(String, f64)>,
}

impl Default for RigFigure {
    fn default() -> Self {
        RigFigure { kind: Figure::None, shade: Shade::Auto, dressing: Dressing::Auto, treatment: Treatment::Auto, style: None, knobs: vec![] }
    }
}

impl RigFigure {
    /// Bodies in a space: a shade and a camera mean something.
    pub fn is_3d(&self) -> bool {
        matches!(self.kind, Figure::Dancers | Figure::Birds | Figure::Turntable)
    }

    /// One shader drawing the whole picture (shaders/show/<kind>.frag).
    pub fn is_shader(&self) -> bool {
        matches!(self.kind, Figure::Kinetic | Figure::Blocks | Figure::Flash | Figure::Glide)
    }

    /// A simulation: the picture it keeps between frames.
    pub fn is_sim(&self) -> bool {
        matches!(self.kind, Figure::Dancers | Figure::Birds | Figure::Turntable | Figure::Fluid | Figure::Veins | Figure::Meme | Figure::Words | Figure::Type3d)
    }

    pub fn label(&self) -> String {
        let mut p = vec![self.kind.name().to_owned()];
        if let Some(s) = &self.style {
            p.push(s.clone());
        }
        if self.shade != Shade::Auto {
            p.push(self.shade.name().into());
        }
        if self.dressing != Dressing::Auto {
            p.push(self.dressing.name().into());
        }
        if self.treatment != Treatment::Auto {
            p.push(self.treatment.name().into());
        }
        p.join(" ")
    }

    pub fn to_json(&self) -> Value {
        let mut m = Obj::new();
        m.insert("kind".into(), self.kind.name().into());
        if self.shade != Shade::Auto {
            m.insert("shade".into(), self.shade.name().into());
        }
        if self.dressing != Dressing::Auto {
            m.insert("dressing".into(), self.dressing.name().into());
        }
        if self.treatment != Treatment::Auto {
            m.insert("treatment".into(), self.treatment.name().into());
        }
        if let Some(s) = &self.style {
            m.insert("style".into(), s.clone().into());
        }
        if !self.knobs.is_empty() {
            m.insert("knobs".into(), knobs_json(&self.knobs));
        }
        Value::Object(m)
    }

    pub fn from_json(j: &Obj) -> RigFigure {
        RigFigure {
            kind: Figure::of(j.get("kind"), Figure::None),
            shade: Shade::of(j.get("shade"), Shade::Auto),
            dressing: Dressing::of(j.get("dressing"), Dressing::Auto),
            treatment: Treatment::of(j.get("treatment"), Treatment::Auto),
            style: str_or(j.get("style")),
            knobs: knobs(j.get("knobs")),
        }
    }
}

/// How the figure goes onto the ground: the mask and the blend.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RigBlend {
    pub mask: Mask,
    pub mix: Mix,
    /// How much of the blend, 0..1.
    pub strength: f64,
}

impl Default for RigBlend {
    fn default() -> Self {
        RigBlend { mask: Mask::None, mix: Mix::Normal, strength: 1.0 }
    }
}

impl RigBlend {
    pub fn plain(&self) -> bool {
        self.mask == Mask::None && self.mix == Mix::Normal
    }

    pub fn label(&self) -> String {
        if self.mask == Mask::None { self.mix.name().into() } else { format!("{} · {}", self.mask.name(), self.mix.name()) }
    }

    pub fn to_json(&self) -> Value {
        let mut m = Obj::new();
        m.insert("mask".into(), self.mask.name().into());
        m.insert("mix".into(), self.mix.name().into());
        if self.strength != 1.0 {
            m.insert("strength".into(), f(self.strength));
        }
        Value::Object(m)
    }

    pub fn from_json(j: &Obj) -> RigBlend {
        RigBlend { mask: Mask::of(j.get("mask"), Mask::None), mix: Mix::of(j.get("mix"), Mix::Normal), strength: num(j.get("strength"), 1.0).clamp(0.0, 1.0) }
    }
}

/// The transformation between the figure as drawn and its style: the slit-scan, then the
/// kaleidoscope (`count` mirrors; 0 none); or the datamosh held over the whole picture.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RigTransform {
    pub count: i64,
    pub differ: f64,
    pub slit: bool,
    pub turn: f64,
    pub line: f64,
    pub blend: Mix,
    pub amount: f64,
    pub mosh: bool,
    pub grain: f64,
    pub melt: f64,
    pub keys: f64,
}

impl Default for RigTransform {
    fn default() -> Self {
        RigTransform { count: 0, differ: 0.5, slit: false, turn: 0.0, line: 0.0, blend: Mix::Normal, amount: 1.0, mosh: false, grain: 0.7, melt: 0.5, keys: 0.5 }
    }
}

impl RigTransform {
    /// The most mirrors there may be.
    pub const MOST: i64 = 6;

    pub fn on(&self) -> bool {
        self.count >= 1
    }
    pub fn any(&self) -> bool {
        self.on() || self.slit || self.mosh
    }
    /// The kaleidoscope and the slit-scan go between the figure and its style; the mosh after.
    pub fn before_style(&self) -> bool {
        self.on() || self.slit
    }
    pub fn turn_radians(&self) -> f64 {
        self.turn * 3.14159265
    }

    pub fn to_json(&self) -> Value {
        let mut m = Obj::new();
        m.insert("count".into(), self.count.into());
        m.insert("differ".into(), f(self.differ));
        let d = RigTransform::default();
        if self.slit {
            m.insert("slit".into(), true.into());
        }
        if self.turn != 0.0 {
            m.insert("turn".into(), f(self.turn));
        }
        if self.line != 0.0 {
            m.insert("line".into(), f(self.line));
        }
        if self.blend != Mix::Normal {
            m.insert("blend".into(), self.blend.name().into());
        }
        if self.amount != 1.0 {
            m.insert("amount".into(), f(self.amount));
        }
        if self.mosh {
            m.insert("mosh".into(), true.into());
        }
        for (k, v, dv) in [("grain", self.grain, d.grain), ("melt", self.melt, d.melt), ("keys", self.keys, d.keys)] {
            if v != dv {
                m.insert(k.into(), f(v));
            }
        }
        Value::Object(m)
    }

    pub fn from_json(j: Option<&Value>) -> RigTransform {
        let Some(j) = obj(j) else { return RigTransform::default() };
        RigTransform {
            count: j.get("count").and_then(Value::as_f64).map(|c| c.round() as i64).unwrap_or(0).clamp(0, Self::MOST),
            differ: num(j.get("differ"), 0.5).clamp(0.0, 1.0),
            slit: j.get("slit") == Some(&Value::Bool(true)),
            turn: num(j.get("turn"), 0.0).clamp(0.0, 1.0),
            line: num(j.get("line"), 0.0).clamp(0.0, 1.0),
            blend: Mix::of(j.get("blend"), Mix::Normal),
            amount: num(j.get("amount"), 1.0).clamp(0.0, 1.0),
            mosh: j.get("mosh") == Some(&Value::Bool(true)),
            grain: num(j.get("grain"), 0.7).clamp(0.0, 1.0),
            melt: num(j.get("melt"), 0.5).clamp(0.0, 1.0),
            keys: num(j.get("keys"), 0.5).clamp(0.0, 1.0),
        }
    }
}

/// The hands' settings of the effects (which effect comes is the plan's).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransformSet {
    pub count: i64,
    pub differ: f64,
    pub turn: f64,
    pub line: f64,
    pub blend: Mix,
    pub amount: f64,
    pub grain: f64,
    pub melt: f64,
    pub keys: f64,
}

impl Default for TransformSet {
    fn default() -> Self {
        TransformSet { count: 2, differ: 0.3, turn: 0.0, line: 0.3, blend: Mix::Screen, amount: 0.85, grain: 0.7, melt: 0.5, keys: 0.5 }
    }
}

impl TransformSet {
    /// What the effect `fx` puts on, with these settings.
    pub fn of(&self, fx: Fx) -> RigTransform {
        RigTransform {
            count: if matches!(fx, Fx::Kaleidoscope | Fx::Both) { self.count } else { 0 },
            differ: self.differ,
            slit: matches!(fx, Fx::Slit | Fx::Both),
            turn: self.turn,
            line: self.line,
            blend: self.blend,
            amount: self.amount,
            mosh: fx == Fx::Mosh,
            grain: self.grain,
            melt: self.melt,
            keys: self.keys,
        }
    }

    pub fn to_json(&self) -> Value {
        json!({"count": self.count, "differ": f(self.differ), "turn": f(self.turn), "line": f(self.line), "blend": self.blend.name(),
               "amount": f(self.amount), "grain": f(self.grain), "melt": f(self.melt), "keys": f(self.keys)})
    }

    pub fn from_json(j: Option<&Value>) -> TransformSet {
        let Some(j) = obj(j) else { return TransformSet::default() };
        TransformSet {
            count: j.get("count").and_then(Value::as_f64).map(|c| c.round() as i64).unwrap_or(2).clamp(1, RigTransform::MOST),
            differ: num(j.get("differ"), 0.3).clamp(0.0, 1.0),
            turn: num(j.get("turn"), 0.0).clamp(0.0, 1.0),
            line: num(j.get("line"), 0.3).clamp(0.0, 1.0),
            blend: Mix::of(j.get("blend"), Mix::Screen),
            amount: num(j.get("amount"), 0.85).clamp(0.0, 1.0),
            grain: num(j.get("grain"), 0.7).clamp(0.0, 1.0),
            melt: num(j.get("melt"), 0.5).clamp(0.0, 1.0),
            keys: num(j.get("keys"), 0.5).clamp(0.0, 1.0),
        }
    }
}

/// The finish over everything (a scene file's `post`, `text` and `particles`).
#[derive(Clone, Debug, PartialEq)]
pub struct RigFinish {
    pub trails: f64,
    pub bloom: f64,
    pub tone: f64,
    pub fringe: f64,
    pub vignette: f64,
    pub grain: f64,
    pub recipe: f64,
    pub title: bool,
    pub lyrics: bool,
    pub where_: String,
    pub jitter: bool,
    pub particles: Vec<String>,
}

impl Default for RigFinish {
    fn default() -> Self {
        RigFinish { trails: 0.0, bloom: 0.5, tone: 1.0, fringe: 0.008, vignette: 0.6, grain: 0.5, recipe: 0.0, title: false, lyrics: false, where_: "low".into(), jitter: false, particles: vec![] }
    }
}

impl RigFinish {
    pub fn to_json(&self) -> Value {
        let mut m = Obj::new();
        for (k, v) in [("trails", self.trails), ("bloom", self.bloom), ("tone", self.tone), ("fringe", self.fringe), ("vignette", self.vignette), ("grain", self.grain), ("recipe", self.recipe)] {
            m.insert(k.into(), f(v));
        }
        if self.title {
            m.insert("title".into(), true.into());
        }
        if self.lyrics {
            m.insert("lyrics".into(), true.into());
        }
        if self.where_ != "low" {
            m.insert("where".into(), self.where_.clone().into());
        }
        if self.jitter {
            m.insert("jitter".into(), true.into());
        }
        if !self.particles.is_empty() {
            m.insert("particles".into(), self.particles.clone().into());
        }
        Value::Object(m)
    }

    pub fn from_json(j: &Obj) -> RigFinish {
        RigFinish {
            trails: num(j.get("trails"), 0.0).clamp(0.0, 0.92),
            bloom: num(j.get("bloom"), 0.5),
            tone: num(j.get("tone"), 1.0).clamp(0.0, 1.0),
            fringe: num(j.get("fringe"), 0.008),
            vignette: num(j.get("vignette"), 0.6),
            grain: num(j.get("grain"), 0.5),
            recipe: num(j.get("recipe"), 0.0).clamp(0.0, 1.0),
            title: j.get("title") == Some(&Value::Bool(true)),
            lyrics: j.get("lyrics") == Some(&Value::Bool(true)),
            where_: text(j.get("where")).unwrap_or_else(|| "low".into()),
            jitter: j.get("jitter") == Some(&Value::Bool(true)),
            particles: strings(j.get("particles")),
        }
    }
}

/// What the stage draws: the ground, the figure (transformed, then its style), how it meets
/// the ground, and the finish.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct ShowRig {
    pub ground: RigGround,
    pub figure: RigFigure,
    pub blend: RigBlend,
    pub finish: RigFinish,
    pub transform: RigTransform,
}

impl ShowRig {
    /// `milk / dancers plain · keyhole · contrast`.
    pub fn word(&self) -> String {
        format!("{} / {} · {}", self.ground.label(), self.figure.label(), self.blend.label())
    }

    pub fn to_json(&self) -> Value {
        let mut m = Obj::new();
        m.insert("ground".into(), self.ground.to_json());
        m.insert("figure".into(), self.figure.to_json());
        m.insert("blend".into(), self.blend.to_json());
        m.insert("finish".into(), self.finish.to_json());
        if self.transform.any() {
            m.insert("transform".into(), self.transform.to_json());
        }
        Value::Object(m)
    }

    pub fn from_json(j: &Obj) -> ShowRig {
        ShowRig {
            transform: RigTransform::from_json(j.get("transform")),
            ground: obj(j.get("ground")).map(RigGround::from_json).unwrap_or_default(),
            figure: obj(j.get("figure")).map(RigFigure::from_json).unwrap_or_default(),
            blend: obj(j.get("blend")).map(RigBlend::from_json).unwrap_or_default(),
            finish: obj(j.get("finish")).map(RigFinish::from_json).unwrap_or_default(),
        }
    }
}

/// What the director reads of a scene: where it fits.
#[derive(Clone, Debug, PartialEq)]
pub struct SceneMeta {
    pub id: String,
    /// Added to its score where it fits.
    pub priority: f64,
    /// Full the moment it is on (a simulation is not: it comes in on a dissolve).
    pub instant: bool,
    /// The energies it suits, 0..1.
    pub energy: (f64, f64),
    /// The section labels it suits; empty is any.
    pub sections: Vec<String>,
    /// What it cannot do without: cover, words, camera, milk.
    pub needs: Vec<String>,
}

impl SceneMeta {
    pub fn new(id: &str) -> SceneMeta {
        SceneMeta { id: id.into(), priority: 0.0, instant: true, energy: (0.0, 1.0), sections: vec![], needs: vec![] }
    }

    pub fn from_json(j: &Obj) -> SceneMeta {
        let energy = match j.get("energy").and_then(Value::as_array) {
            Some(e) if e.len() >= 2 => (e[0].as_f64().unwrap_or(0.0), e[1].as_f64().unwrap_or(1.0)),
            _ => (0.0, 1.0),
        };
        SceneMeta {
            id: text(j.get("id")).unwrap_or_default(),
            energy,
            sections: strings(j.get("sections")),
            needs: strings(j.get("needs")),
            priority: num(j.get("priority"), 0.0),
            instant: j.get("instant") != Some(&Value::Bool(false)),
        }
    }
}

/// A rig with a name: shipped (a scene file), or the user's own.
#[derive(Clone, Debug, PartialEq)]
pub struct Look {
    pub id: String,
    pub name: String,
    pub rig: ShowRig,
    pub meta: SceneMeta,
    pub shipped: bool,
    /// The director may put the whole look on, as one.
    pub hero: bool,
    pub thumb: Option<String>,
}

impl Look {
    pub fn to_json(&self) -> Value {
        let mut m = Obj::new();
        m.insert("id".into(), self.id.clone().into());
        m.insert("name".into(), self.name.clone().into());
        m.insert("rig".into(), self.rig.to_json());
        m.insert("energy".into(), json!([f(self.meta.energy.0), f(self.meta.energy.1)]));
        if !self.meta.sections.is_empty() {
            m.insert("sections".into(), self.meta.sections.clone().into());
        }
        if !self.meta.needs.is_empty() {
            m.insert("needs".into(), self.meta.needs.clone().into());
        }
        if self.meta.priority != 0.0 {
            m.insert("priority".into(), f(self.meta.priority));
        }
        if !self.meta.instant {
            m.insert("instant".into(), false.into());
        }
        if self.hero {
            m.insert("hero".into(), true.into());
        }
        if let Some(t) = &self.thumb {
            m.insert("thumb".into(), t.clone().into());
        }
        Value::Object(m)
    }

    pub fn from_json(j: &Obj, shipped: bool) -> Look {
        let id = text(j.get("id")).unwrap_or_default();
        Look {
            name: text(j.get("name")).unwrap_or_else(|| id.clone()),
            rig: obj(j.get("rig")).map(ShowRig::from_json).unwrap_or_default(),
            meta: SceneMeta::from_json(j),
            shipped,
            hero: j.get("hero") == Some(&Value::Bool(true)),
            thumb: str_or(j.get("thumb")),
            id,
        }
    }

    /// This look's rig in combination `c`: the background (a world keeps its own), the style
    /// (the figure's own drawing, or a treatment over the frame), the mask and the blend. Not
    /// this look's combination: as it is.
    pub fn in_combo(&self, c: Option<&Combo>) -> ShowRig {
        let Some(c) = c.filter(|c| c.scene == self.id) else { return self.rig.clone() };
        let mut figure = self.rig.figure.clone();
        if own_style(figure.kind) {
            figure.style = Some(c.style.clone());
        } else if c.style != "raw"
            && let Some(t) = Treatment::by_name(&c.style)
        {
            figure.treatment = t;
        }
        if c.world() {
            return ShowRig { figure, blend: RigBlend::default(), ..self.rig.clone() };
        }
        let ground = ground_of_key(&c.ground);
        // the bloom goes over the blend: on a white page it would bloom the whole frame
        let mut finish = self.rig.finish.clone();
        if ground.kind == Ground::White {
            finish.bloom *= 0.25;
        }
        ShowRig { ground, figure, blend: RigBlend { mask: c.mask, mix: c.mix, strength: 1.0 }, finish, transform: self.rig.transform }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rig_goes_to_json_and_back_as_v1_writes_it() {
        let rig = ShowRig {
            ground: RigGround { kind: Ground::Pulse, field: Some("rays".into()), dim: 0.7, knobs: vec![("m1".into(), 0.25)] },
            figure: RigFigure { kind: Figure::Dancers, treatment: Treatment::Ascii, style: Some("chrono".into()), ..Default::default() },
            blend: RigBlend { mask: Mask::Keyhole, mix: Mix::Add, strength: 0.5 },
            finish: RigFinish { trails: 0.35, particles: vec!["sparks".into()], ..Default::default() },
            transform: TransformSet::default().of(Fx::Both),
        };
        let j = rig.to_json();
        let back = ShowRig::from_json(j.as_object().unwrap());
        assert_eq!(back, rig);
        // the defaults are left out, as v1 leaves them
        assert_eq!(j["ground"]["kind"], "pulse");
        assert!(j["figure"].get("shade").is_none());
        assert!(ShowRig::default().to_json().get("transform").is_none());
    }

    #[test]
    fn what_v1_reads_leniently_reads_the_same() {
        let j: Value = serde_json::from_str(r#"{"ground":{"kind":"lava","dim":3},"figure":{"kind":"kinetic","shade":"nope"},"blend":{"mix":"screen","strength":-1},"finish":{"trails":2,"where":"top"},"transform":{"count":9.4,"slit":"yes"}}"#).unwrap();
        let r = ShowRig::from_json(j.as_object().unwrap());
        assert_eq!(r.ground.kind, Ground::Black);
        assert_eq!(r.ground.dim, 1.0);
        assert_eq!(r.figure.shade, Shade::Auto);
        assert_eq!(r.blend.strength, 0.0);
        assert_eq!(r.finish.trails, 0.92);
        assert_eq!(r.finish.where_, "top");
        assert_eq!(r.transform.count, 6);
        assert!(!r.transform.slit);
    }

    #[test]
    fn a_look_in_a_combination() {
        let look = Look {
            id: "kinetic".into(),
            name: "Kinetic".into(),
            rig: ShowRig { figure: RigFigure { kind: Figure::Kinetic, ..Default::default() }, ..Default::default() },
            meta: SceneMeta::new("kinetic"),
            shipped: true,
            hero: false,
            thumb: None,
        };
        let c = Combo { mask: Mask::Inverted, mix: Mix::Contrast, ..Combo::new("white", "kinetic", "ascii") };
        let r = look.in_combo(Some(&c));
        assert_eq!(r.ground.kind, Ground::White);
        assert_eq!(r.figure.treatment, Treatment::Ascii);
        assert_eq!(r.blend, RigBlend { mask: Mask::Inverted, mix: Mix::Contrast, strength: 1.0 });
        assert_eq!(r.finish.bloom, 0.5 * 0.25, "no whole-frame bloom on white");
        // another scene's combination: the look as it is
        assert_eq!(look.in_combo(Some(&Combo::new("milk", "flash", "raw"))), look.rig);
        // a world keeps its own ground, unblended
        let world = Combo::new("own", "kinetic", "raw");
        assert_eq!(look.in_combo(Some(&world)).ground, look.rig.ground);
    }
}
