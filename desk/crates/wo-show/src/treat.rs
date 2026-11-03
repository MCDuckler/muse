//! The treatments a picture can be put through whatever drew it (v1: show_tune.dart and
//! show_common.dart treatOf / slitShapeOf): a pass of sim/dance_fx.frag over the figure —
//! ascii, dither, contour, halftone, thermal, lines, crt — or the stage's own slit-scan; with
//! the hands' knobs (ShowMacros.tune) on each. Pure: a rig and a state in, the stage's numbers
//! out.
use std::collections::BTreeMap;

use crate::json::Named;
use crate::rig::{Figure, ShowRig, Treatment};
use crate::state::{Hsl, ShowState};

/// The treatments that go over a picture whatever drew it (show_tune.dart imageTreatments).
pub const IMAGE_TREATMENTS: &[Treatment] =
    &[Treatment::Ascii, Treatment::Dither, Treatment::Halftone, Treatment::Thermal, Treatment::Lines, Treatment::Contour, Treatment::Crt, Treatment::Slit];

/// dance_fx.frag's mode for a treatment, by name (the dancers' and birds' styles share them).
pub fn fx_mode(name: &str) -> Option<u32> {
    Some(match name {
        "ascii" => 1,
        "dither" => 2,
        "contour" => 3,
        "halftone" => 4,
        "thermal" => 5,
        "lines" => 6,
        "crt" => 8,
        "slit" => 9,
        _ => return None,
    })
}

/// A knob's rest where it is not 1 (show_tune.dart treatmentTunes): the tint of the ascii and
/// the crt.
fn rest(treatment: &str, knob: &str) -> f64 {
    match (treatment, knob) {
        ("ascii" | "crt", "tint") => 0.2,
        _ => 1.0,
    }
}

/// Whether a treatment has a tint knob (the ascii, the crt).
fn has_tint(treatment: &str) -> bool {
    matches!(treatment, "ascii" | "crt")
}

/// The knob `knob` of `treatment` in `tune`, or its rest.
pub fn tune_of(tune: &BTreeMap<String, f64>, treatment: &str, knob: &str) -> f64 {
    tune.get(&format!("{treatment}.{knob}")).copied().unwrap_or_else(|| rest(treatment, knob))
}

/// The shader's knobs (uWeight, uSpacing, uHeight, uGain, uSize) for a treatment, and the
/// multiplier on its own cell (the ridgelines' cell is their gap: the spacing knob; the
/// rest, the size).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FxKnobs {
    pub weight: f64,
    pub spacing: f64,
    pub height: f64,
    pub gain: f64,
    pub size: f64,
    pub cell: f64,
}

pub fn fx_knobs(tune: &BTreeMap<String, f64>, treatment: &str) -> FxKnobs {
    let k = |x| tune_of(tune, treatment, x);
    FxKnobs {
        weight: k("weight"),
        spacing: k("spacing"),
        height: k("height"),
        gain: k("gain"),
        size: k("size"),
        cell: if treatment == "lines" { k("spacing") } else { k("size") },
    }
}

/// v1's memeHash: 0..1 from three numbers, the same every time (a sine's fraction).
pub fn meme_hash(a: f64, b: f64, c: f64) -> f64 {
    let x = (a * 12.9898 + b * 78.233 + c * 37.719).sin() * 43758.5453;
    x - x.floor()
}

/// The slit-scan's shape (0 rows, 1 columns, 2 out from the middle, 3 a wave, 4 bands, 5 out
/// from the middle line) and whether it runs the other way: another every four phrases of
/// the record.
pub fn slit_shape_of(st: &ShowState) -> (f64, bool) {
    let m = st.master();
    let n = (m.bar_index.unwrap_or(0) as f64 / 16.0).floor();
    let salt = (m.track_id.unwrap_or(0) % 9973) as f64;
    ((meme_hash(salt, n, 41.0) * 6.0).floor().clamp(0.0, 5.0), meme_hash(salt, n, 43.0) < 0.3)
}

/// The slit-scan as the stage draws it (native fx.h Slit): its shape, which way, how far back
/// the far edge is (the weight knob: 1 the whole ring), how many frames a layer of the ring
/// holds (the spacing knob × 2).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlitDraw {
    pub shape: f32,
    pub flip: bool,
    pub reach: f32,
    pub slower: f32,
}

fn slit_draw(st: &ShowState) -> SlitDraw {
    let (shape, flip) = slit_shape_of(st);
    let k = fx_knobs(&st.macros.tune, "slit");
    SlitDraw { shape: shape as f32, flip, reach: k.weight as f32, slower: k.spacing as f32 }
}

/// A pass of dance_fx.frag: its mode, its ink and paper, its cell (`max(min, h / div)` of a
/// picture h high, through the knob; 0 where `div` is 0), its tint and its knobs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FxDraw {
    pub mode: u32,
    pub ink: [f32; 3],
    pub paper: [f32; 3],
    pub cell_min: f32,
    pub cell_div: f32,
    pub cell_k: f32,
    pub tint: f32,
    /// uWeight, uSpacing, uHeight, uGain, uSize.
    pub knobs: [f32; 5],
}

impl FxDraw {
    /// The cell, pixels, on a picture `h` high.
    pub fn cell(&self, h: f32) -> f32 {
        if self.cell_div <= 0.0 { 0.0 } else { (h / self.cell_div).max(self.cell_min) * self.cell_k }
    }
}

/// The style over the figure: a pass of dance_fx.frag, or the slit-scan.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Style {
    Fx(FxDraw),
    Slit(SlitDraw),
}

fn rgb(c: u32) -> [f32; 3] {
    [(c >> 16) & 255, (c >> 8) & 255, c & 255].map(|v| v as f32 / 255.0)
}

fn hsl(h: f64, s: f64, l: f64) -> [f32; 3] {
    Hsl { h, s, l }.rgb().map(|v| v as f32)
}

/// The crt's lavender white and its near-black (dance_fx.frag's ramp ends).
pub const CRT_INK: u32 = 0xf6dcff;
pub const CRT_PAPER: u32 = 0x07020f;

/// The style `rig` puts its figure through, as the stage draws it: its pass and colours from
/// `st`'s palette, through the knobs; None where there is none for the stage to draw (none
/// asked for, or the figure draws it itself as its own style — the dancers', the birds').
pub fn style_of(rig: &ShowRig, st: &ShowState) -> Option<Style> {
    let fig = &rig.figure;
    let style = fig.style.as_deref();
    // under a transformation, a style a figure draws for itself (the dancers' ascii) is the
    // stage's: it goes over what the transformation made
    let staged = rig.transform.before_style() && style.is_some_and(|s| fx_mode(s).is_some() && s != "slit");
    let t = if style == Some("slit") {
        Treatment::Slit
    } else if staged {
        Treatment::by_name(style.unwrap()).unwrap_or(fig.treatment)
    } else {
        fig.treatment
    };
    if fig.kind == Figure::None || !IMAGE_TREATMENTS.contains(&t) || (style == Some(t.name()) && t != Treatment::Slit && !staged) {
        return None;
    }
    if t == Treatment::Slit {
        return Some(Style::Slit(slit_draw(st)));
    }
    let pal = &st.palette;
    let dark = hsl(pal.primary.h, 0.45, 0.035);
    let name = t.name();
    // (ink, paper, cell min, cell div, tint): the looks as the dancers' finish draws them
    let (ink, paper, min, div, tint) = match t {
        Treatment::Dither => (rgb(0xeee7d6), hsl(pal.primary.h, 0.4, 0.07), 2.0, 220.0, 0.0),
        Treatment::Contour => (hsl(pal.accent.h, 0.85, 0.62), dark, 0.0, 0.0, 0.0),
        Treatment::Halftone => (hsl(pal.primary.h, 0.9, 0.55), rgb(0x050506), 4.0, 110.0, 0.0),
        Treatment::Thermal => ([1.0; 3], [0.0; 3], 0.0, 0.0, 0.0),
        Treatment::Crt => (rgb(CRT_INK), rgb(CRT_PAPER), 3.0, 135.0, 0.2),
        Treatment::Lines => (hsl(pal.accent.h, 0.35, 0.85), rgb(0x030303), 5.0, 72.0, 0.0),
        _ => (hsl(pal.accent.h, 0.55, 0.78), rgb(0x040404), 0.0, 44.0, 0.2),
    };
    let tune = &st.macros.tune;
    let k = fx_knobs(tune, name);
    let tint = if has_tint(name) { tune.get(&format!("{name}.tint")).copied().unwrap_or(tint) } else { tint };
    Some(Style::Fx(FxDraw {
        mode: fx_mode(name).unwrap_or(1),
        ink,
        paper,
        cell_min: min,
        cell_div: div,
        cell_k: k.cell as f32,
        tint: tint as f32,
        knobs: [k.weight, k.spacing, k.height, k.gain, k.size].map(|v| v as f32),
    }))
}

/// The kaleidoscope as the stage draws it (shaders/show/ghosts.frag): mirrors, how far the
/// reflections differ, their turn (radians), the mirrors' lines, the blend's index (normal, add,
/// screen, contrast) and how much of them.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Kaleido {
    pub count: u32,
    pub differ: f32,
    pub turn: f32,
    pub line: f32,
    pub blend: u32,
    pub amount: f32,
}

/// The transformation between the figure and its style (none for a look with no figure): the
/// slit-scan as the layer, then the kaleidoscope.
pub fn transform_of(rig: &ShowRig, st: &ShowState) -> (Option<SlitDraw>, Option<Kaleido>) {
    if rig.figure.kind == Figure::None {
        return (None, None);
    }
    let t = &rig.transform;
    let slit = t.slit.then(|| slit_draw(st));
    let k = t.on().then(|| Kaleido {
        count: t.count.clamp(1, crate::rig::RigTransform::MOST) as u32,
        differ: t.differ as f32,
        turn: t.turn_radians() as f32,
        line: t.line as f32,
        blend: t.blend as u32,
        amount: t.amount as f32,
    });
    (slit, k)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::combos::Mix;
    use crate::rig::{RigFigure, RigTransform};

    fn rig(kind: Figure, treatment: Treatment, style: Option<&str>) -> ShowRig {
        ShowRig { figure: RigFigure { kind, treatment, style: style.map(Into::into), ..Default::default() }, ..Default::default() }
    }

    #[test]
    fn a_shader_scene_goes_through_its_treatment() {
        let st = ShowState::default();
        let Some(Style::Fx(d)) = style_of(&rig(Figure::Kinetic, Treatment::Ascii, None), &st) else { panic!() };
        assert_eq!(d.mode, 1);
        assert!((d.cell(440.0) - 10.0).abs() < 1e-5, "an ascii's letter: h / 44");
        assert!((d.tint - 0.2).abs() < 1e-6);
        let Some(Style::Fx(d)) = style_of(&rig(Figure::Flash, Treatment::Dither, None), &st) else { panic!() };
        assert_eq!(d.mode, 2);
        assert_eq!(d.cell(220.0), 2.0, "never under two pixels");
        assert!((d.cell(1100.0) - 5.0).abs() < 1e-5);
        assert_eq!(style_of(&rig(Figure::Flash, Treatment::Contour, None), &st).map(|s| match s { Style::Fx(d) => d.cell(1000.0), _ => -1.0 }), Some(0.0));
        // the crt's colours are its own
        let Some(Style::Fx(d)) = style_of(&rig(Figure::Blocks, Treatment::Crt, None), &st) else { panic!() };
        assert_eq!((d.mode, d.ink, d.paper), (8, rgb(CRT_INK), rgb(CRT_PAPER)));
    }

    #[test]
    fn none_where_there_is_nothing_to_draw() {
        let st = ShowState::default();
        assert_eq!(style_of(&rig(Figure::Kinetic, Treatment::Auto, None), &st), None);
        assert_eq!(style_of(&rig(Figure::Kinetic, Treatment::Raw, None), &st), None);
        assert_eq!(style_of(&rig(Figure::None, Treatment::Ascii, None), &st), None);
        // the dancers' own ascii is theirs, not the stage's
        assert_eq!(style_of(&rig(Figure::Dancers, Treatment::Ascii, Some("ascii")), &st), None);
        // the radar is the birds' own: not an image treatment
        assert_eq!(style_of(&rig(Figure::Kinetic, Treatment::Radar, None), &st), None);
    }

    #[test]
    fn the_slit_scan_and_a_style_under_a_transformation_are_the_stages() {
        let st = ShowState::default();
        assert!(matches!(style_of(&rig(Figure::Dancers, Treatment::Auto, Some("slit")), &st), Some(Style::Slit(_))));
        assert!(matches!(style_of(&rig(Figure::Kinetic, Treatment::Slit, None), &st), Some(Style::Slit(_))));
        let mut r = rig(Figure::Dancers, Treatment::Auto, Some("lines"));
        assert_eq!(style_of(&r, &st), None);
        r.transform = RigTransform { count: 3, ..Default::default() };
        assert!(matches!(style_of(&r, &st), Some(Style::Fx(FxDraw { mode: 6, .. }))));
    }

    #[test]
    fn the_knobs_move_the_cell_and_the_tint() {
        let mut st = ShowState::default();
        st.macros.tune.insert("ascii.size".into(), 2.0);
        st.macros.tune.insert("ascii.tint".into(), 0.9);
        st.macros.tune.insert("lines.spacing".into(), 1.5);
        st.macros.tune.insert("lines.size".into(), 3.0);
        let Some(Style::Fx(d)) = style_of(&rig(Figure::Glide, Treatment::Ascii, None), &st) else { panic!() };
        assert!((d.cell(440.0) - 20.0).abs() < 1e-5);
        assert!((d.tint - 0.9).abs() < 1e-6);
        assert_eq!(d.knobs[4], 2.0, "uSize");
        let Some(Style::Fx(d)) = style_of(&rig(Figure::Glide, Treatment::Lines, None), &st) else { panic!() };
        assert!((d.cell(720.0) - 15.0).abs() < 1e-5, "the ridgelines' gap is the spacing knob's");
    }

    #[test]
    fn the_hash_and_the_slit_shape_are_v1s() {
        // memeHash(1, 2, 3) in Dart
        let x = (12.9898f64 + 2.0 * 78.233 + 3.0 * 37.719).sin() * 43758.5453;
        assert_eq!(meme_hash(1.0, 2.0, 3.0), x - x.floor());
        let mut st = ShowState::default();
        st.a.track_id = Some(12345);
        st.a.bar_index = Some(40);
        let (shape, flip) = slit_shape_of(&st);
        let n = 2.0;
        let salt = (12345 % 9973) as f64;
        assert_eq!(shape, (meme_hash(salt, n, 41.0) * 6.0).floor());
        assert_eq!(flip, meme_hash(salt, n, 43.0) < 0.3);
        // the same for the whole four phrases
        st.a.bar_index = Some(47);
        assert_eq!(slit_shape_of(&st), (shape, flip));
    }

    #[test]
    fn the_kaleidoscope_needs_a_figure() {
        let st = ShowState::default();
        let mut r = rig(Figure::Kinetic, Treatment::Auto, None);
        r.transform = RigTransform { count: 9, turn: 0.5, blend: Mix::Screen, slit: true, ..Default::default() };
        let (slit, k) = transform_of(&r, &st);
        assert!(slit.is_some());
        let k = k.unwrap();
        assert_eq!((k.count, k.blend), (6, 2));
        assert!((k.turn - std::f32::consts::FRAC_PI_2).abs() < 1e-6);
        r.figure.kind = Figure::None;
        assert_eq!(transform_of(&r, &st), (None, None));
    }
}
