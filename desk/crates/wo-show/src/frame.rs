//! What the stage draws this frame, as plain numbers (v1: native_stage.dart's frame(), with
//! show_common.dart's finishOf, trailRecipe and stageWhite and show_canvas.dart's coverageOf):
//! the figure's shader and knobs, the one being left under a dissolve, the ground and how the
//! figure meets it, the trails' recipe, the particles, the finish, the palette and the hands.
//! wo-render draws a [StageFrame]; a test or a replay can make one without a GPU.
use crate::combos::{Mask, Mix};
use crate::json::Named;
use crate::mosh::{MoshDrive, mosh_cut};
use crate::rig::{Ground, ShowRig, pulse_variant};
use crate::scenes::{Scene, SceneBook, SceneLayer};
use crate::state::{ShowState, common_block, layer_knob};
use crate::treat::{Kaleido, SlitDraw, Style, style_of, transform_of};

/// A scene shader to draw (shaders/show/<shader>.frag) with its four knobs (uM1..uM4).
#[derive(Clone, Debug, PartialEq)]
pub struct ShaderLayer {
    pub shader: String,
    pub knobs: [f32; 4],
    /// It reads MilkDrop's picture (uMilk).
    pub milk: bool,
}

/// What lies under the figure, as the stage draws it.
#[derive(Clone, Debug, PartialEq)]
pub enum GroundDraw {
    Black,
    White,
    /// Two of the palette's colours, breathing slowly.
    Wash,
    /// MilkDrop's picture, filled and cropped to the stage.
    Milk,
    /// The record's cover, filled and cropped.
    Cover,
    /// A scene shader drawn whole as a backdrop (a field, or the pulse with its variant).
    Field(ShaderLayer),
}

/// How the figure meets the ground (shaders/show/under.frag).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Blend {
    pub mix: Mix,
    pub mask: Mask,
    /// Which pixels are the figure: 0 the marked bodies, 1 the alpha, 2 the light.
    pub coverage: u32,
    pub strength: f32,
}

/// The finish's numbers: trails (the feedback's decay), bloom, vignette, grain, the film
/// curve's share, the colour fringe.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Post {
    pub trails: f32,
    pub bloom: f32,
    pub vignette: f32,
    pub grain: f32,
    pub tone: f32,
    pub fringe: f32,
}

/// One frame of the stage.
#[derive(Clone, Debug, PartialEq)]
pub struct StageFrame {
    /// The scene on (its id), and its shader; None where the scene is not one the stage
    /// draws with a shader (yet): black, the finish over it.
    pub scene: Option<String>,
    pub figure: Option<ShaderLayer>,
    /// The scene being left under the dissolve, and how far across (1: wholly the new one).
    pub from: Option<ShaderLayer>,
    pub k: f32,
    /// uTime .. uBarIndex for the figure (its knobs at uM1..uM4).
    pub common: [f32; 35],
    /// The ground and the blend, where the look has one (None: the figure as it is drawn).
    pub ground: GroundDraw,
    pub ground_dim: f32,
    pub blend: Option<Blend>,
    pub post: Post,
    /// feedback.frag's recipe: decay, zoom, rotate, tint, the tint's RGB, fold, warp, hue
    /// turn, drift x and y.
    pub recipe: [f32; 12],
    pub particles: Vec<String>,
    /// Primary, secondary, accent, as RGB 0..1.
    pub palette: [[f32; 3]; 3],
    /// White over everything (the strobe, the hit) and the blackout, 0..1.
    pub white: f32,
    pub black: f32,
    pub freeze: bool,
    /// The datamoshes so far (a new count: a mosh from the picture on), and how long and how
    /// hard the next one is.
    pub mosh: i64,
    pub mosh_cut: (f32, f32),
    /// The datamosh held over the whole picture (the stage's clock plays it: Play::mosh).
    pub mosh_hold: MoshDrive,
    /// The transformation between the figure and its style: the slit-scan as the layer, then
    /// the kaleidoscope.
    pub slit: Option<SlitDraw>,
    pub kaleido: Option<Kaleido>,
    /// The style over the figure: a treatment, or the slit-scan.
    pub style: Option<Style>,
    /// The finished picture moved as a camera would (a 3D figure's: the stage's clock plays
    /// it, wo_dance::clock::PictureCam): its scale, its shift (a share of the size), its roll.
    pub camera: [f32; 4],
}

impl StageFrame {
    /// uTime .. uBarIndex with another layer's knobs (the scene being left, a field).
    pub fn common_with(&self, knobs: [f32; 4]) -> [f32; 35] {
        let mut c = self.common;
        c[18..22].copy_from_slice(&knobs);
        c
    }
}

/// The finish for a scene in `st`: the frame's rig's, or the scene file's own where the frame
/// carries no rig (a feed that knows no looks, a test).
pub fn finish_of<'a>(scene: Option<&'a Scene>, st: &'a ShowState) -> std::borrow::Cow<'a, crate::rig::RigFinish> {
    match scene {
        Some(s) if st.rig == ShowRig::default() => std::borrow::Cow::Owned(s.finish.clone()),
        _ => std::borrow::Cow::Borrowed(&st.rig.finish),
    }
}

fn knobs_of(layer: &SceneLayer, st: &ShowState) -> [f32; 4] {
    let shader = layer.shader.as_deref().unwrap_or("");
    [1, 2, 3, 4].map(|k| layer_knob(shader, layer.knob(k), k, &st.genome) as f32)
}

fn shader_layer(scene: &Scene, st: &ShowState) -> Option<ShaderLayer> {
    let layer = scene.layers.first()?;
    if layer.sim.is_some() {
        return None;
    }
    Some(ShaderLayer { shader: layer.shader.clone()?, knobs: knobs_of(layer, st), milk: layer.samplers.iter().any(|s| s == "milk") })
}

/// The trails' recipe (shaders/show/feedback.frag): the record's genome, as much of it as the
/// finish takes (its `recipe`, 0..1).
pub fn trail_recipe(fin: &crate::rig::RigFinish, st: &ShowState) -> [f32; 12] {
    let k = fin.recipe;
    let g = &st.genome;
    let gene = |name: &str, or: f64| if g.is_empty() { or } else { or + (g.get(name) - or) * k };
    let energy = st.master().energy;
    let [r, gr, b] = st.palette.secondary.rgb();
    [
        gene("feedback.decay", fin.trails),
        gene("feedback.zoom", 1.0 + 0.010 * energy),
        gene("feedback.rotate", 0.003),
        0.12,
        r,
        gr,
        b,
        if k >= 0.5 && !g.is_empty() { g.get("feedback.fold") } else { 0.0 },
        gene("feedback.warp", 0.0),
        gene("feedback.hueTurn", 0.0),
        gene("feedback.shiftX", 0.0),
        gene("feedback.shiftY", 0.0),
    ]
    .map(|v| v as f32)
}

/// White over the stage: the strobe (on every other sixteenth while held) and the hands' hit.
pub fn stage_white(st: &ShowState) -> f64 {
    let beat = st.master().beat_phase;
    let strobe = if st.macros.strobe > 0.0 && ((beat * 4.0).floor() as i64) % 2 == 0 { st.macros.strobe } else { 0.0 };
    strobe.max(st.macros.hit * 0.7)
}

/// Which pixels of a scene's picture are its figure (under.frag's uCoverage), as the native
/// stage draws them: the alpha for the words, the 3D type and the dancers; the light for
/// everything else.
pub fn coverage_of(scene: Option<&Scene>) -> u32 {
    let layer = scene.and_then(|s| if s.layers.len() == 1 { s.layers.first() } else { None });
    match layer.and_then(|l| l.sim.as_deref()) {
        Some("words" | "type3d") => 1,
        Some(s) if s.starts_with("dance.") => 1,
        _ => 2,
    }
}

/// The frame for `st` at `time` seconds of the stage's clock, its scenes read from `book`.
pub fn stage_frame(st: &ShowState, book: &SceneBook, time: f64) -> StageFrame {
    let scene = st.scene.as_deref().and_then(|id| book.scenes.get(id));
    let figure = scene.and_then(|s| shader_layer(s, st));
    let fin = finish_of(scene, st);
    let flat = st.flat();
    let knobs = figure.as_ref().map(|f| f.knobs).unwrap_or([0.0; 4]);
    let common = common_block(&flat, knobs.map(f64::from), time);
    // the scene being left, under the dissolve: drawn only where it is a shader
    let from = (st.scene_k < 1.0).then(|| st.scene_from.as_deref().and_then(|id| book.scenes.get(id)).and_then(|s| shader_layer(s, st))).flatten();
    // the ground under the figure and the blend of the two: the frame's rig
    let rig = &st.rig;
    let g = &rig.ground;
    let field = |shader: &str, knobs: [f32; 4]| GroundDraw::Field(ShaderLayer { shader: shader.into(), knobs, milk: false });
    let ground = match g.kind {
        Ground::Black | Ground::Camera => GroundDraw::Black,
        Ground::White => GroundDraw::White,
        Ground::Wash => GroundDraw::Wash,
        Ground::Milk => GroundDraw::Milk,
        Ground::Cover => GroundDraw::Cover,
        Ground::Pulse => field("pulse", [pulse_variant(g.field.as_deref()) as f32, 0.0, 0.0, 0.0]),
        Ground::Field => match g.field.as_deref().and_then(|f| book.scenes.get(f)).and_then(|s| s.layers.first()) {
            // a field that is a shader scene, with the look's knobs (the record's genome
            // where the shader takes it); a simulation as a field is not drawn here: black
            Some(l) if l.shader.is_some() && l.sim.is_none() => {
                let fl = SceneLayer { knobs: g.knobs.clone(), ..l.clone() };
                field(l.shader.as_deref().unwrap(), knobs_of(&fl, st))
            }
            _ => GroundDraw::Black,
        },
    };
    // not under a scene that draws MilkDrop itself (it is the ground), nor for a figure
    // plainly on black (the figure as it is drawn)
    let b = rig.blend;
    let plain = g.kind == Ground::Black && b.mix == Mix::Normal && b.mask == Mask::None;
    let samples_milk = figure.as_ref().is_some_and(|f| f.milk);
    let blend = (!samples_milk && b.strength > 0.0 && !plain).then_some(Blend { mix: b.mix, mask: b.mask, coverage: coverage_of(scene), strength: b.strength as f32 });
    let pal = st.palette;
    let (slit, kaleido) = transform_of(rig, st);
    StageFrame {
        scene: st.scene.clone(),
        figure,
        from,
        k: st.scene_k as f32,
        common,
        ground,
        ground_dim: g.dim as f32,
        blend,
        post: Post {
            trails: fin.trails as f32,
            bloom: fin.bloom as f32,
            vignette: fin.vignette as f32,
            grain: fin.grain as f32,
            tone: fin.tone as f32,
            fringe: fin.fringe as f32,
        },
        recipe: trail_recipe(&fin, st),
        particles: fin.particles.clone(),
        palette: [pal.primary, pal.secondary, pal.accent].map(|c| c.rgb().map(|v| v as f32)),
        white: stage_white(st) as f32,
        black: if st.macros.blackout { 1.0 } else { 0.0 },
        freeze: st.macros.freeze,
        mosh: st.mosh,
        mosh_cut: mosh_cut(st),
        mosh_hold: MoshDrive::default(),
        slit,
        kaleido,
        style: style_of(rig, st),
        camera: [1.0, 0.0, 0.0, 0.0],
    }
}

/// The ground's kind as the native stage numbers it (v1's Ground's index), for a dump.
pub fn ground_index(g: &GroundDraw) -> usize {
    match g {
        GroundDraw::Black => Ground::Black.index(),
        GroundDraw::White => Ground::White.index(),
        GroundDraw::Wash => Ground::Wash.index(),
        GroundDraw::Milk => Ground::Milk.index(),
        GroundDraw::Cover => Ground::Cover.index(),
        GroundDraw::Field(l) if l.shader == "pulse" => Ground::Pulse.index(),
        GroundDraw::Field(_) => Ground::Field.index(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::combos::{Mask, Mix};
    use crate::rig::{RigBlend, RigGround};
    use crate::scenes::IN_SCOPE;
    use crate::state::ShowMacros;

    fn book() -> SceneBook {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/scenes");
        SceneBook::from_dir(&dir).only(IN_SCOPE)
    }

    #[test]
    fn a_scene_without_a_rig_draws_with_its_own_finish() {
        let b = book();
        let st = ShowState { scene: Some("kinetic".into()), ..Default::default() };
        let f = stage_frame(&st, &b, 3.0);
        assert_eq!(f.figure.as_ref().unwrap().shader, "kinetic");
        assert_eq!(f.post.trails, 0.35);
        assert_eq!(f.post.bloom, 0.9);
        assert_eq!(f.particles, vec!["sparks".to_owned()]);
        assert!(f.blend.is_none(), "black under a plain figure: no blend");
        assert_eq!(f.common[0], 3.0);
        assert_eq!(f.recipe[0], 0.35, "no genome: the trails as the scene has them");
    }

    #[test]
    fn the_rig_brings_the_ground_and_the_blend() {
        let b = book();
        let mut rig = b.scenes["glide"].rig();
        rig.ground = RigGround { kind: Ground::Field, field: Some("drift".into()), dim: 0.6, knobs: vec![] };
        rig.blend = RigBlend { mask: Mask::Keyhole, mix: Mix::Screen, strength: 0.8 };
        let st = ShowState { scene: Some("glide".into()), rig, ..Default::default() };
        let f = stage_frame(&st, &b, 0.0);
        assert!(matches!(&f.ground, GroundDraw::Field(l) if l.shader == "drift"));
        assert_eq!(f.ground_dim, 0.6);
        assert_eq!(f.blend, Some(Blend { mix: Mix::Screen, mask: Mask::Keyhole, coverage: 2, strength: 0.8 }));
        // a field that is a simulation is black
        let mut st2 = st.clone();
        st2.rig.ground.field = Some("fluid".into());
        assert_eq!(stage_frame(&st2, &b, 0.0).ground, GroundDraw::Black);
        // the pulse with its variant at uM1
        st2.rig.ground = RigGround { kind: Ground::Pulse, field: Some("smoke".into()), ..Default::default() };
        assert!(matches!(stage_frame(&st2, &b, 0.0).ground, GroundDraw::Field(l) if l.shader == "pulse" && l.knobs[0] == 2.0));
    }

    #[test]
    fn the_scene_being_left_is_drawn_under_the_dissolve() {
        let b = book();
        let st = ShowState { scene: Some("flash".into()), scene_from: Some("blocks".into()), scene_k: 0.4, ..Default::default() };
        let f = stage_frame(&st, &b, 0.0);
        assert_eq!(f.from.as_ref().unwrap().shader, "blocks");
        assert_eq!(f.k, 0.4);
        let done = ShowState { scene_k: 1.0, ..st };
        assert!(stage_frame(&done, &b, 0.0).from.is_none());
    }

    #[test]
    fn the_strobe_flashes_on_every_other_sixteenth_and_the_hit_shows() {
        let mut st = ShowState { macros: ShowMacros { strobe: 1.0, ..Default::default() }, ..Default::default() };
        st.a.beat_phase = 0.1;
        assert_eq!(stage_white(&st), 1.0);
        st.a.beat_phase = 0.3;
        assert_eq!(stage_white(&st), 0.0);
        st.macros.hit = 1.0;
        assert!((stage_white(&st) - 0.7).abs() < 1e-9);
        st.macros.blackout = true;
        assert_eq!(stage_frame(&st, &book(), 0.0).black, 1.0);
    }

    #[test]
    fn a_simulation_has_no_shader_figure() {
        let st = ShowState { scene: Some("fluid".into()), ..Default::default() };
        let f = stage_frame(&st, &book(), 0.0);
        assert!(f.figure.is_none());
        assert_eq!(f.scene.as_deref(), Some("fluid"));
    }
}
