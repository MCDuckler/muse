//! What the dancers' stages draw, as commands (v1: show_dance_surface.dart's surface and the
//! native stage's dance.h ops): a filled rectangle, coloured triangles already on the picture,
//! round points, a clip, the camera, a body posed into a slot and its passes (the body, an
//! outline, a shadow on the floor or a wall, the dust), a finish of dance_fx.frag over what is
//! drawn so far. 2D positions are pixels of the picture the camera is for (its `w`×`h`).
//! wo-render draws them.
use crate::M34;
use crate::clock::{Cam, Spot, V3};

/// How a draw meets what is there: over it, added, replacing it, the darker of the two.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Blend {
    Over,
    Plus,
    Src,
    Darken,
}

/// An RGBA colour, 0..1, straight (not premultiplied).
pub type Rgba = [f32; 4];

pub fn rgba(argb: u32) -> Rgba {
    [(argb >> 16) & 255, (argb >> 8) & 255, argb & 255, argb >> 24].map(|v| v as f32 / 255.0)
}

/// How a body is lit and coloured (v1's DanceLook3).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Look3 {
    /// Toward the key light (need not be a unit), its colour and strength.
    pub key: V3,
    pub key_colour: [f32; 3],
    pub key_k: f32,
    pub fill: [f32; 3],
    pub fill_k: f32,
    pub ambient: f32,
    pub rim: [f32; 3],
    pub rim_k: f32,
    pub rim_power: f32,
    /// The scan's own colours, or `flat` (a silhouette's black, a cut-out's colour).
    pub textured: bool,
    pub flat: Option<Rgba>,
    /// Bands of light, a cartoon's; 0 smooth.
    pub toon: u32,
    pub alpha: f32,
    /// All of it darker (the mirror under the floor).
    pub dim: f32,
    /// A flat colour lit a little (a cut-out), or exactly itself (a silhouette).
    pub shade_flat: bool,
    /// Polished metal: what the surface reflects of a studio round it.
    pub chrome: bool,
}

impl Default for Look3 {
    fn default() -> Self {
        let c = |v: u32| { let x = rgba(v); [x[0], x[1], x[2]] };
        Look3 {
            key: V3::new(-0.45, -0.75, 0.55),
            key_colour: c(0xfffff0e0),
            key_k: 0.6,
            fill: c(0xff8090b0),
            fill_k: 0.25,
            ambient: 0.5,
            rim: [1.0; 3],
            rim_k: 0.0,
            rim_power: 2.4,
            textured: true,
            flat: None,
            toon: 0,
            alpha: 1.0,
            dim: 1.0,
            shade_flat: true,
            chrome: false,
        }
    }
}

/// How a body is drawn as dust: points `size` metres across, how far they have left it
/// (`explode` 0 the body, 1 all in the air), swirl and rise, the clock they swirl by, a shiver
/// on the kick; coloured by the skin (`mode` 0), one colour `a` (1), or `a` at the feet to `b`
/// at the head (2); `density` the share of the points drawn.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Dust {
    pub size: f32,
    pub explode: f32,
    pub swirl: f32,
    pub rise: f32,
    pub time: f32,
    pub mode: u32,
    pub a: [f32; 3],
    pub b: [f32; 3],
    pub alpha: f32,
    pub density: f32,
    pub shimmer: f32,
}

impl Default for Dust {
    fn default() -> Self {
        Dust { size: 0.006, explode: 0.0, swirl: 0.8, rise: 0.5, time: 0.0, mode: 0, a: [0.949, 0.937, 0.91], b: [0.416, 0.486, 1.0], alpha: 0.8, density: 1.0, shimmer: 0.0 }
    }
}

/// A finish of dance_fx.frag over what is drawn so far: its mode, cell (pixels of the
/// picture), ink and paper, tint, how many glyphs, the kick's swell and where it starts, the
/// clock, the knobs (weight, spacing, height, gain, size; 0 is the look as drawn).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Post {
    pub mode: u32,
    pub cell: f32,
    pub ink: [f32; 3],
    pub paper: [f32; 3],
    pub tint: f32,
    pub glyphs: u32,
    pub pop: f32,
    pub pop_at: [f32; 2],
    pub time: f32,
    pub knobs: [f32; 5],
}

/// One thing drawn.
#[derive(Clone, Debug, PartialEq)]
pub enum Cmd {
    /// The camera the bodies are seen by from here, and the picture's size every 2D position
    /// is in.
    Camera(Cam),
    Fill { rect: [f32; 4], colour: Rgba, blend: Blend },
    /// x, y (pixels, y down), r, g, b, a per corner, three corners a triangle.
    Tris { verts: Vec<[f32; 6]>, blend: Blend },
    /// Round points `radius` pixels at x, y.
    Points { at: Vec<[f32; 2]>, radius: f32, colour: Rgba, blend: Blend },
    /// Drawing kept inside the rectangle from here, or anywhere again.
    Clip(Option<[f32; 4]>),
    /// A body into `slot`: a model's mesh, its skinning matrices, where it stands.
    Pose { slot: usize, model: &'static str, mesh: usize, skin: Vec<M34>, spot: Spot },
    Body { slot: usize, look: Look3, under_floor: bool, blend: Blend },
    /// The shell's back faces, pushed out by `width` metres: an outline round the body.
    Outline { slot: usize, width: f32, colour: Rgba, blend: Blend },
    /// Flattened onto the floor along `to_light`, darkening what is there.
    FloorShadow { slot: usize, to_light: V3, colour: [f32; 3] },
    /// Thrown from `lamp` onto the wall at y = `wall_y`.
    WallShadow { slot: usize, lamp: V3, wall_y: f32, colour: [f32; 3] },
    Dust { slot: usize, dust: Dust },
    Post(Post),
    ClearDepth,
}
