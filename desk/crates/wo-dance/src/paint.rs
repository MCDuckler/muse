//! The dancer scene's stages, painted as commands (v1: show_dance.dart's _artStage and its
//! helpers — the disco floor, the viewports, the ribbons of light, the chronophotograph's
//! stamps, the studio floor, the beams, the rings, the mirror ball, the dust — and the
//! finishes through dance_fx.frag). Each rendering:
//!
//! - plain, slit: the scans as they are under a plain daylight (the slit-scan is the stage's);
//! - mono: flat silhouettes, light on black;
//! - trails: chrome figures, ribbons of light behind hands, feet and head;
//! - ascii, dither, contour, halftone, thermal, lines, crt: chrome on black, then the finish;
//! - chrono: the figure stamped every half beat, the older stamps darker;
//! - viewports: a model editor's grid of viewports, the selection stepping on the beat;
//! - disco: an LED floor that plays the record;
//! - dust: the bodies as points a drop blows off them.
//!
//! (Not the fluid: the Rust stage has no fluid yet; its dancers never pick it.)
use wo_show::state::{Hsl, ShowState};
use wo_show::treat::{fx_knobs, meme_hash};

use crate::clock::{self, Art, Cam, FISHEYE_EDGE, FISHEYE_FOV, Mood, Spot, V3};
use crate::cmd::{Blend, Cmd, Dust, Look3, Post, Rgba};
use crate::sim::{Company, DanceSim, Scene};
use crate::{M34, Rig};

const TILES_X: usize = 15;
const TILES_Y: usize = 11;
const TILE_M: f64 = 0.56;

/// What the stages keep between frames: the disco floor's lit tiles and sparks, its rings.
#[derive(Clone, Debug)]
pub struct PaintState {
    floor_lit: Vec<f32>,
    floor_spark: Vec<f32>,
    floor_rings: Vec<(f64, f64, f64)>,
    kick_was: f64,
    snare_was: f64,
    sparks: i64,
}

impl Default for PaintState {
    fn default() -> Self {
        PaintState { floor_lit: vec![0.0; TILES_X * TILES_Y], floor_spark: vec![0.0; TILES_X * TILES_Y], floor_rings: vec![], kick_was: 0.0, snare_was: 0.0, sparks: 0 }
    }
}

type Rgb = [f32; 3];

fn hsl(h: f64, s: f64, l: f64) -> Rgb {
    Hsl { h, s, l }.rgb().map(|v| v as f32)
}

fn argb(c: u32) -> Rgb {
    let x = crate::cmd::rgba(c);
    [x[0], x[1], x[2]]
}

fn a(c: Rgb, alpha: f64) -> Rgba {
    [c[0], c[1], c[2], alpha.clamp(0.0, 1.0) as f32]
}

fn lerp(x: Rgb, y: Rgb, t: f64) -> Rgb {
    let t = t as f32;
    [x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t]
}

const WHITE: Rgb = [1.0; 3];
const BLACK: Rgb = [0.0; 3];

/// Flat triangles in one draw: already on the picture, or quads in the world through the
/// camera (a quad behind the camera is dropped).
#[derive(Default)]
struct Quads {
    v: Vec<[f32; 6]>,
}

impl Quads {
    fn tri(&mut self, p: [(f64, f64); 3], c: [Rgba; 3]) {
        for k in 0..3 {
            self.v.push([p[k].0 as f32, p[k].1 as f32, c[k][0], c[k][1], c[k][2], c[k][3]]);
        }
    }

    fn quad(&mut self, cam: &Cam, p: [V3; 4], c: Rgba) {
        let q = p.map(|x| cam.project(x));
        if q.iter().any(|x| x.2 < Cam::NEAR) {
            return;
        }
        let o = q.map(|x| (x.0, x.1));
        self.tri([o[0], o[1], o[2]], [c; 3]);
        self.tri([o[0], o[2], o[3]], [c; 3]);
    }

    fn draw(&mut self, out: &mut Vec<Cmd>, blend: Blend) {
        if !self.v.is_empty() {
            out.push(Cmd::Tris { verts: std::mem::take(&mut self.v), blend });
        }
    }
}

fn at(cam: &Cam, p: V3) -> (f64, f64) {
    let (x, y, _) = cam.project(p);
    (x, y)
}

fn scale_at(cam: &Cam, z: f64) -> f64 {
    cam.focal / z.max(Cam::NEAR)
}

/// Where bone `bone` of a body is, `tip` metres along it, on the floor of the world.
fn joint_world(rig: &Rig, world: &[M34], spot: &Spot, bone: &str, tip: f64) -> Option<V3> {
    let i = rig.bone(bone)?;
    let p = Rig::joint_at(world, i, tip);
    let x = if spot.mirror { -p[0] } else { p[0] };
    let (c, sn, k) = (spot.yaw.cos(), spot.yaw.sin(), spot.scale);
    Some(V3::new(spot.x + (c * x - sn * p[1]) * k, spot.y + (sn * x + c * p[1]) * k, spot.lift + p[2] * k))
}

/// The look's numbers this frame (v1's _Look).
struct Look<'a> {
    st: &'a ShowState,
    mood: Mood,
    beats: f64,
    since: Option<f64>,
    kick: f64,
    beat: f64,
    snare: f64,
    top: f64,
    low: f64,
    mid: f64,
    high: f64,
    build: f64,
    energy: f64,
    t: f64,
}

impl Look<'_> {
    /// On black the stage draws its own setting; on any other background that is the setting.
    fn own_setting(&self) -> bool {
        self.st.rig.ground.kind == wo_show::rig::Ground::Black
    }
    fn rage(&self) -> bool {
        self.mood == Mood::Rage
    }
    fn sleep(&self) -> bool {
        self.mood == Mood::Sleep
    }
}

/// The figure in polished chrome: the studio in its surface, faintly the record's colour.
fn chrome(l: &Look, rim: Rgb, dim: f64) -> Look3 {
    let s = l.st.palette.secondary;
    Look3 { textured: false, chrome: true, key_colour: lerp(WHITE, hsl(s.h, 0.6, 0.75), 0.18), rim, rim_k: (0.25 + 0.2 * l.beat) as f32, dim: dim as f32, ..Default::default() }
}

/// The body lit for the room: the key warm from the front left, the rim the light's.
fn lit(l: &Look, light: Rgb, dim: f64, lead: bool, alpha: f64) -> Look3 {
    let p = l.st.palette.secondary;
    Look3 {
        key_colour: lerp(argb(0xfffff2e6), light, 0.25),
        key_k: (0.6 + 0.2 * l.beat) as f32,
        fill: hsl(p.h, p.s, 0.55),
        fill_k: 0.25,
        ambient: 0.5,
        rim: light,
        rim_k: if dim < 1.0 || !lead { 0.0 } else { (0.55 + 0.5 * l.kick * if l.rage() { 1.0 } else { 0.4 }) as f32 },
        dim: dim as f32,
        alpha: alpha as f32,
        ..Default::default()
    }
}

/// A body drawn: as the native surface draws one, a textured body's rim a glow behind it.
fn body(out: &mut Vec<Cmd>, slot: usize, look: Look3, under_floor: bool, blend: Blend, textured_here: bool) {
    let textured = look.textured && look.flat.is_none() && textured_here;
    if textured && look.rim_k > 0.01 && !under_floor {
        out.push(Cmd::Outline { slot, width: 0.009, colour: [look.rim[0], look.rim[1], look.rim[2], 0.6 * look.rim_k.clamp(0.0, 1.0)], blend: Blend::Plus });
    }
    out.push(Cmd::Body { slot, look, under_floor, blend });
}

fn fill(out: &mut Vec<Cmd>, w: f64, h: f64, c: Rgb) {
    out.push(Cmd::Fill { rect: [0.0, 0.0, w as f32, h as f32], colour: a(c, 1.0), blend: Blend::Over });
}

/// A backdrop washed from `top` to `bottom` down the picture.
fn wash(out: &mut Vec<Cmd>, w: f64, h: f64, top: Rgb, bottom: Rgb) {
    let mut q = Quads::default();
    q.tri([(0.0, 0.0), (w, 0.0), (w, h)], [a(top, 1.0), a(top, 1.0), a(bottom, 1.0)]);
    q.tri([(0.0, 0.0), (w, h), (0.0, h)], [a(top, 1.0), a(bottom, 1.0), a(bottom, 1.0)]);
    q.draw(out, Blend::Src);
}

/// A backdrop of `outer` with a soft glow of `inner` at `at`, `radius` wide.
fn glow(out: &mut Vec<Cmd>, w: f64, h: f64, at: (f64, f64), radius: f64, inner: Rgb, outer: Rgb) {
    fill(out, w, h, outer);
    let mut q = Quads::default();
    let seg = 32;
    for i in 0..seg {
        let (a0, a1) = (i as f64 / seg as f64 * std::f64::consts::TAU, (i + 1) as f64 / seg as f64 * std::f64::consts::TAU);
        q.tri([at, (at.0 + a0.cos() * radius, at.1 + a0.sin() * radius), (at.0 + a1.cos() * radius, at.1 + a1.sin() * radius)], [a(inner, 1.0), a(outer, 1.0), a(outer, 1.0)]);
    }
    q.draw(out, Blend::Over);
}

impl DanceSim {
    /// The scene's picture as commands, for a `w`×`h` picture (the scene's camera's).
    pub fn paint(&mut self, co: &Company, scene: &Scene, st: &ShowState, dt: f64) -> Vec<Cmd> {
        let (w, h) = (scene.cam.w, scene.cam.h);
        let n = |k: &str| st.num(k);
        let l = Look {
            st,
            mood: scene.mood,
            beats: scene.beats,
            since: scene.since_drop,
            kick: scene.kick,
            beat: n("dyn.beat.decay"),
            snare: n("dyn.hit.snare"),
            top: n("dyn.hit.top"),
            low: n("dyn.band.low"),
            mid: n("dyn.band.mid"),
            high: n("dyn.band.high"),
            build: st.master().build_k,
            energy: n("dyn.energy"),
            t: scene.t,
        };
        let cam = scene.cam;
        let mut out = vec![Cmd::Camera(cam)];
        // the bodies into their slots, far first
        for (i, b) in scene.bodies.iter().enumerate() {
            out.push(Cmd::Pose { slot: i, model: b.model, mesh: b.mesh, skin: b.skin.clone(), spot: b.spot });
        }
        let textured = |slot: usize| scene.bodies.get(slot).is_some_and(|b| !co.rig(b.model).1.skin.is_empty());
        let slots: Vec<usize> = (0..scene.bodies.len()).collect();
        let lead_slot = scene.bodies.iter().position(|b| b.lead).unwrap_or(0);
        let pal = st.palette;
        let mid = at(&cam, V3::new(0.0, 0.0, 1.15));
        let pop_at = [(mid.0 / w) as f32, (mid.1 / h) as f32];
        match scene.art {
            Art::Disco => self.disco(co, scene, &l, &mut out, dt),
            Art::Mono => {
                fill(&mut out, w, h, BLACK);
                // the kick: the figure a hair bigger for a moment
                if let Some(Cmd::Pose { spot, .. }) = out.iter_mut().find(|c| matches!(c, Cmd::Pose { slot, .. } if *slot == lead_slot)) {
                    spot.scale *= 1.0 + 0.018 * l.kick;
                }
                for &s in &slots {
                    out.push(Cmd::Body { slot: s, look: Look3 { flat: Some(a(argb(0xfff3f2ee), 1.0)), textured: false, shade_flat: false, ..Default::default() }, under_floor: false, blend: Blend::Over });
                }
            }
            Art::Trails => {
                fill(&mut out, w, h, BLACK);
                if l.own_setting() {
                    wash(&mut out, w, h, hsl(pal.primary.h, 0.35, 0.035), argb(0xff020203));
                    studio_floor(&mut out, &cam, &l, &slots, hsl(pal.accent.h, 0.3, 0.7));
                }
                let cols = [hsl(pal.accent.h, 0.9, 0.65), hsl(pal.secondary.h, 0.9, 0.6), hsl(pal.primary.h, 0.8, 0.7)];
                self.ribbons(co, scene, &l, &mut out, cols);
                for &s in &slots {
                    out.push(Cmd::Body { slot: s, look: chrome(&l, hsl(pal.accent.h, pal.accent.s, 0.7), 1.0), under_floor: false, blend: Blend::Over });
                }
            }
            Art::Dither => {
                if l.own_setting() {
                    glow(&mut out, w, h, (w / 2.0, h * 0.42), h * 0.9, hsl(pal.primary.h, 0.25, 0.3), BLACK);
                } else {
                    fill(&mut out, w, h, BLACK);
                }
                for &s in &slots {
                    out.push(Cmd::Body { slot: s, look: chrome(&l, WHITE, 1.0), under_floor: false, blend: Blend::Over });
                }
            }
            Art::Ascii | Art::Contour | Art::Halftone | Art::Thermal | Art::Lines | Art::Crt | Art::Fluid => {
                fill(&mut out, w, h, BLACK);
                for &s in &slots {
                    out.push(Cmd::Body { slot: s, look: chrome(&l, WHITE, 1.0), under_floor: false, blend: Blend::Over });
                }
            }
            Art::Viewports => self.viewports(co, scene, &l, &mut out),
            Art::Dust => {
                fill(&mut out, w, h, BLACK);
                let d = dust_now(&l, scene.bodies.len());
                for &s in &slots {
                    out.push(Cmd::Dust { slot: s, dust: d });
                }
            }
            Art::Plain | Art::Slit => {
                fill(&mut out, w, h, BLACK);
                let look = Look3 {
                    key: V3::new(-0.35, -0.8, 0.65),
                    key_colour: argb(0xfffffaf2),
                    key_k: 0.55,
                    fill: argb(0xffc8ccd4),
                    fill_k: 0.3,
                    ambient: 0.5,
                    rim_k: 0.0,
                    alpha: 254.0 / 255.0,
                    ..Default::default()
                };
                for &s in &slots {
                    body(&mut out, s, look, false, Blend::Src, textured(s));
                }
            }
            Art::Chrono => {
                fill(&mut out, w, h, if l.own_setting() { argb(0xff060606) } else { BLACK });
                if l.own_setting() {
                    studio_floor(&mut out, &cam, &l, &slots, hsl(pal.primary.h, 0.3, 0.7));
                }
                self.stamps(co, scene, &l, &mut out, hsl(pal.primary.h, 0.3, 0.6));
                for &s in &slots {
                    out.push(Cmd::Body { slot: s, look: chrome(&l, WHITE, 1.0), under_floor: false, blend: Blend::Over });
                }
            }
        }
        // the finish: a treatment the dancers draw for themselves, unless the stage draws it
        // over a transformation (wo_show::treat::style_of)
        let staged = st.rig.transform.before_style() && st.rig.figure.style.as_deref() == Some(scene.art.name());
        if let Some(mode) = scene.art.fx_mode().filter(|_| !staged) {
            let (ink, paper, cell, tint) = post_drawn(&l, scene.art, h);
            let k = fx_knobs(&st.macros.tune, scene.art.name());
            let tint = if matches!(scene.art, Art::Ascii | Art::Crt) { st.macros.tune.get(&format!("{}.tint", scene.art.name())).copied().unwrap_or(tint) } else { tint };
            out.push(Cmd::Post(Post {
                mode,
                cell: (cell * k.cell) as f32,
                ink,
                paper,
                tint: tint as f32,
                glyphs: 0,
                pop: l.kick.clamp(0.0, 1.0) as f32,
                pop_at,
                time: scene.t as f32,
                knobs: [k.weight, k.spacing, k.height, k.gain, k.size].map(|v| v as f32),
            }));
        }
        if clock::is_fisheye(scene.shot) {
            out.push(Cmd::Post(Post {
                mode: 7,
                cell: FISHEYE_EDGE as f32,
                ink: WHITE,
                paper: BLACK,
                tint: (FISHEYE_FOV / 2.0).tan() as f32,
                glyphs: 0,
                pop: l.kick.clamp(0.0, 1.0) as f32,
                pop_at: [0.5, 0.5],
                time: scene.t as f32,
                knobs: [0.0; 5],
            }));
        }
        out
    }

    /// Light swept behind the hands, the feet and the head over the last beat or two.
    fn ribbons(&self, co: &Company, scene: &Scene, l: &Look, out: &mut Vec<Cmd>, cols: [Rgb; 3]) {
        let Some(lead) = scene.bodies.iter().find(|b| b.lead) else { return };
        let (_, rig) = co.rig(lead.model);
        let span = match l.mood {
            Mood::Rage => 1.75,
            Mood::Sleep => 2.0,
            Mood::Wake => 1.25,
            Mood::Vibe => 1.4,
        };
        const N: usize = 30;
        let joints = [("Hand_L", 0.09, 0.07, 0), ("Hand_R", 0.09, 0.07, 0), ("Toes_L", 0.05, 0.045, 1), ("Toes_R", 0.05, 0.045, 1), ("Head", 0.16, 0.05, 2)];
        let ids: Vec<Option<usize>> = joints.iter().map(|j| rig.bone(j.0)).collect();
        let mut pts = vec![[(0.0, 0.0); N + 1]; joints.len()];
        let mut px = vec![[0.0; N + 1]; joints.len()];
        let scale = lead.spot.scale;
        for k in 0..=N {
            let Some(pose) = self.lead.pose(rig, l.beats - span * k as f64 / N as f64, false) else { return };
            let world = rig.solve(&pose);
            for (j, id) in ids.iter().enumerate() {
                let Some(id) = id else { continue };
                let p = Rig::joint_at(&world, *id, joints[j].1);
                let (x, y, d) = scene.cam.project(V3::new(p[0], p[1], p[2]) * scale);
                pts[j][k] = (x, y);
                px[j][k] = scale_at(&scene.cam, d);
            }
        }
        let mut q = Quads::default();
        let glow = 0.75 + 0.25 * l.beat;
        for (j, id) in ids.iter().enumerate() {
            if id.is_none() {
                continue;
            }
            let p = &pts[j];
            let col = cols[joints[j].3];
            let side = |k: usize| {
                let (a, b) = (p[k.saturating_sub(1)], p[(k + 1).min(N)]);
                let (dx, dy) = (b.0 - a.0, b.1 - a.1);
                let len = (dx * dx + dy * dy).sqrt();
                if len < 1e-3 { (0.0, 0.0) } else { (-dy / len, dx / len) }
            };
            for k in 0..N {
                let (t0, t1) = (k as f64 / N as f64, (k + 1) as f64 / N as f64);
                let kw = 1.0 + 0.45 * l.kick;
                let w0 = joints[j].2 * kw * px[j][k] * (1.0 - t0).powf(0.6);
                let w1 = joints[j].2 * kw * px[j][k + 1] * (1.0 - t1).powf(0.6);
                let c0 = a(col, glow * (1.0 - t0).powf(1.5));
                let c1 = a(col, glow * (1.0 - t1).powf(1.5));
                let (s0, s1) = (side(k), side(k + 1));
                let (s0, s1) = ((s0.0 * w0, s0.1 * w0), (s1.0 * w1, s1.1 * w1));
                let (pk, pk1) = (p[k], p[k + 1]);
                q.tri([(pk.0 + s0.0, pk.1 + s0.1), (pk.0 - s0.0, pk.1 - s0.1), (pk1.0 - s1.0, pk1.1 - s1.1)], [c0, c0, c1]);
                q.tri([(pk.0 + s0.0, pk.1 + s0.1), (pk1.0 - s1.0, pk1.1 - s1.1), (pk1.0 + s1.0, pk1.1 + s1.1)], [c0, c1, c1]);
            }
        }
        q.draw(out, Blend::Plus);
    }

    /// The chronophotograph's stamps: the figure where it was every half beat (a quarter in
    /// a drop), added, fading with age; the newest comes in bright.
    fn stamps(&self, co: &Company, scene: &Scene, l: &Look, out: &mut Vec<Cmd>, tint: Rgb) {
        let Some(lead) = scene.bodies.iter().find(|b| b.lead) else { return };
        let (model, rig) = co.rig(lead.model);
        let step = if l.rage() { 0.25 } else { 0.5 };
        let count = if l.rage() { 8 } else { 6 };
        let beats = l.beats;
        let last = (beats / step).floor() * step;
        let mesh = if rig.meshes.len() > 1 { 1 } else { 0 };
        let base = scene.bodies.len();
        for k in (1..=count).rev() {
            let at = last - (k - 1) as f64 * step - if beats - last < 0.02 { step } else { 0.0 };
            let Some(pose) = self.lead.pose(rig, at, false) else { return };
            let world = rig.solve(&pose);
            let slot = base + k - 1;
            out.push(Cmd::Pose { slot, model, mesh, skin: rig.skinning(&world), spot: Spot { scale: lead.spot.scale, ..Default::default() } });
            let age = (k - 1) as f64 / count as f64;
            let fresh = if k == 1 { (1.0 - (beats - last) / (step * 0.6)).clamp(0.0, 1.0) } else { 0.0 };
            let k0 = 0.42 * (1.0 - age).powf(1.6) + 0.25 * fresh;
            out.push(Cmd::Body { slot, look: chrome(l, lerp(tint, WHITE, 0.3), k0), under_floor: false, blend: Blend::Plus });
        }
    }

    /// A model editor's viewports: the picture cut into panels, each a dancer straight on
    /// over the editor's ground grid, shaded by turns; the panel whose turn it is outlined.
    fn viewports(&self, co: &Company, scene: &Scene, l: &Look, out: &mut Vec<Cmd>) {
        let st = l.st;
        let (w, h) = (scene.cam.w, scene.cam.h);
        let salt = st.master().track_id.unwrap_or(0);
        let (cols, rows) = match l.mood {
            Mood::Sleep => (2, 2),
            Mood::Rage => {
                if meme_hash(salt.rem_euclid(9973) as f64, (l.beats / 16.0).floor(), 5.0) < 0.5 {
                    (4, 3)
                } else {
                    (3, 3)
                }
            }
            _ => (3, 2),
        };
        fill(out, w, h, argb(0xff050506));
        let models = clock::models_on(&st.macros.dancers_off);
        let bob = if l.sleep() { 0.0 } else { 0.022 * l.kick };
        const GUTTER: f64 = 3.0;
        let (cw, ch) = (w / cols as f64, h / rows as f64);
        let step = (l.beats * if l.rage() { 2.0 } else { 1.0 }).floor() as i64;
        let pal = st.palette;
        let sel = hsl(30.0, 0.95, 0.58);
        let mut posed: std::collections::HashMap<&str, Vec<M34>> = std::collections::HashMap::new();
        let mut slot = scene.bodies.len() + 16;
        for r in 0..rows {
            for k in 0..cols {
                let i = r * cols + k;
                let rect = [k as f64 * cw + GUTTER, r as f64 * ch + GUTTER, (k + 1) as f64 * cw - GUTTER, (r + 1) as f64 * ch - GUTTER];
                let (top, bot) = (a(argb(0xff19191c), 1.0), a(argb(0xff0c0c0e), 1.0));
                let mut q = Quads::default();
                q.tri([(rect[0], rect[1]), (rect[2], rect[1]), (rect[2], rect[3])], [top, top, bot]);
                q.tri([(rect[0], rect[1]), (rect[2], rect[3]), (rect[0], rect[3])], [top, bot, bot]);
                q.draw(out, Blend::Src);
                out.push(Cmd::Clip(Some(rect.map(|v| v as f32))));
                // a front camera framing one dancer in this panel: the whole picture's size,
                // its focal the panel's, its middle moved to the panel's
                let (fov, dist, height, aim) = (0.6f64, 4.0, 1.15, 0.92);
                let ph = rect[3] - rect[1];
                let focal = ph / 2.0 / (fov / 2.0).tan();
                let full = 2.0 * (h / 2.0 / focal).atan();
                let centre = ((rect[0] + rect[2]) / 2.0, (rect[1] + rect[3]) / 2.0);
                let cam = Cam::with(V3::new(0.0, -dist, height), V3::new(0.0, 0.0, aim), w, h, full, 0.0, ((centre.0 - w / 2.0) / w, (centre.1 - h / 2.0) / h), 0.0);
                out.push(Cmd::Camera(cam));
                let mut g = Quads::default();
                let grid = a(argb(0xffa0a0a8), 0x33 as f64 / 255.0);
                for x in -4..=4 {
                    let x = x as f64;
                    let col = if x == 0.0 { a(argb(0xff9a3b3b), 0.0) } else { grid };
                    g.quad(&cam, [V3::new(x - 0.008, -2.0, 0.0), V3::new(x + 0.008, -2.0, 0.0), V3::new(x + 0.008, 6.0, 0.0), V3::new(x - 0.008, 6.0, 0.0)], col);
                }
                for y in -2..=6 {
                    let y = y as f64;
                    let col = if y == 0.0 { a(argb(0xff9a3b3b), 1.0) } else { grid };
                    g.quad(&cam, [V3::new(-4.0, y - 0.008, 0.0), V3::new(4.0, y - 0.008, 0.0), V3::new(4.0, y + 0.008, 0.0), V3::new(-4.0, y + 0.008, 0.0)], col);
                }
                g.quad(&cam, [V3::new(-0.01, -2.0, 0.0), V3::new(0.01, -2.0, 0.0), V3::new(0.01, 6.0, 0.0), V3::new(-0.01, 6.0, 0.0)], a(argb(0xff5a8a3a), 1.0));
                g.draw(out, Blend::Over);
                // the dancer: the panels' models by turns, all on the lead's line
                let model = models[(i as i64 + salt).rem_euclid(models.len() as i64) as usize];
                let (model, rig) = co.rig(model);
                let sc = crate::sim::scale_of(rig);
                let skin = match posed.get(model) {
                    Some(s) => s.clone(),
                    None => {
                        let Some(mut pose) = self.lead.pose(rig, l.beats, false) else { return };
                        pose.hips[2] -= bob / sc;
                        let s = rig.skinning(&rig.solve(&pose));
                        posed.insert(model, s.clone());
                        s
                    }
                };
                out.push(Cmd::Pose { slot, model, mesh: 0, skin, spot: Spot { scale: sc, ..Default::default() } });
                let look = match i % 3 {
                    0 => lit(l, hsl(pal.accent.h, pal.accent.s, 0.7), 1.0, true, 1.0),
                    1 => chrome(l, hsl(pal.accent.h, pal.accent.s, 0.75), 1.0),
                    _ => Look3 { flat: Some(a(argb(0xff8a8a90), 1.0)), textured: false, rim: WHITE, rim_k: 0.2, key: V3::new(-0.4, -0.8, 0.6), ..Default::default() },
                };
                out.push(Cmd::FloorShadow { slot, to_light: V3::new(0.25, -0.35, 1.0).unit(), colour: argb(0xff101012) });
                body(out, slot, look, false, Blend::Over, !rig.skin.is_empty());
                out.push(Cmd::Clip(None));
                slot += 1;
                // the selection: the panel whose turn it is, outlined
                if step.rem_euclid((rows * cols) as i64) == i as i64 {
                    let mut o = Quads::default();
                    let t = 2.0;
                    let s = a(sel, 1.0);
                    for e in [
                        [rect[0], rect[1], rect[2], rect[1] + t],
                        [rect[0], rect[3] - t, rect[2], rect[3]],
                        [rect[0], rect[1], rect[0] + t, rect[3]],
                        [rect[2] - t, rect[1], rect[2], rect[3]],
                    ] {
                        o.tri([(e[0], e[1]), (e[2], e[1]), (e[2], e[3])], [s; 3]);
                        o.tri([(e[0], e[1]), (e[2], e[3]), (e[0], e[3])], [s; 3]);
                    }
                    o.draw(out, Blend::Over);
                }
            }
        }
        out.push(Cmd::Camera(scene.cam));
    }

    /// The disco: an LED floor that plays the record — every step lights the tile it lands
    /// on, every kick sends a ring out from the lead, a snare scatters sparks, the bass
    /// breathes the floor and the wall; a pattern a section under it; a drop lands white.
    fn disco(&mut self, co: &Company, scene: &Scene, l: &Look, out: &mut Vec<Cmd>, dt: f64) {
        let st = l.st;
        let cam = scene.cam;
        let (w, h) = (cam.w, cam.h);
        let pal = st.palette;
        let beat_n = l.beats.floor() as i64;
        let bar_n = beat_n.div_euclid(4);
        let hues = [pal.primary, pal.secondary, pal.accent];
        let hue = |i: i64, light: f64| hsl(hues[i.rem_euclid(3) as usize].h, 0.95, light);
        let drop_k = match l.since {
            Some(s) if (0.0..2.0).contains(&s) => (1.0 - s / 2.0) * (1.0 - s / 2.0),
            _ => 0.0,
        };
        // 1. the room: near black, the back wall lit low in the bar's colour, breathing
        fill(out, w, h, argb(0xff030205));
        let (wx, wy, wd) = cam.project(V3::new(0.0, TILES_Y as f64 * TILE_M / 2.0 + 1.6, 0.5));
        if wd > Cam::NEAR {
            let r = w * 0.8;
            let inner = a(hue(bar_n, 0.5), (0.14 + 0.36 * l.low + 0.18 * l.beat + 0.4 * drop_k).clamp(0.0, 1.0));
            let outer = [inner[0], inner[1], inner[2], 0.0];
            let mut q = Quads::default();
            let seg = 28;
            for i in 0..seg {
                let (a0, a1) = (i as f64 / seg as f64 * std::f64::consts::TAU, (i + 1) as f64 / seg as f64 * std::f64::consts::TAU);
                q.tri([(wx, wy), (wx + a0.cos() * r, wy + a0.sin() * r * 0.42), (wx + a1.cos() * r, wy + a1.sin() * r * 0.42)], [inner, outer, outer]);
            }
            q.draw(out, Blend::Plus);
        }
        // 2. what happened since the last frame: the steps, the kicks, the snares
        let ps = &mut self.paint;
        let (fade, spark_fade) = ((-dt / 0.5).exp() as f32, (-dt / 0.16).exp() as f32);
        for i in 0..ps.floor_lit.len() {
            ps.floor_lit[i] *= fade;
            ps.floor_spark[i] *= spark_fade;
        }
        for b in &scene.bodies {
            let (_, rig) = co.rig(b.model);
            for foot in ["Foot_L", "Foot_R"] {
                let Some(p) = joint_world(rig, &b.world, &b.spot, foot, 0.6) else { continue };
                if p.z > 0.22 {
                    continue;
                }
                let Some(t) = tile_at(p.x, p.y) else { continue };
                let k = ((1.0 - p.z / 0.22) * if b.lead { 1.0 } else { 0.7 }) as f32;
                if ps.floor_lit[t] < k {
                    ps.floor_lit[t] = k;
                }
            }
        }
        let from = scene.bodies.iter().find(|b| b.lead).map(|b| (b.spot.x, b.spot.y)).unwrap_or((0.0, 0.0));
        if l.kick > 0.55 && ps.kick_was < 0.35 {
            ps.floor_rings.push((l.beats, from.0, from.1));
        }
        ps.kick_was = l.kick;
        ps.floor_rings.retain(|r| !(l.beats - r.0 > 1.6 || l.beats < r.0));
        if l.snare > 0.5 && ps.snare_was < 0.3 {
            ps.sparks += 1;
            let many = 4 + (8.0 * l.energy).round() as i64;
            let len = ps.floor_spark.len();
            for n in 0..many {
                ps.floor_spark[((meme_hash(ps.sparks as f64, n as f64, 41.0) * len as f64).floor() as usize) % len] = 1.0;
            }
        }
        ps.snare_was = l.snare;
        // 3. the lead's light: the floor's colour on the dancers, and their steps'
        let rim = lerp(hue(bar_n + 1, 0.62), WHITE, drop_k);
        // 4. the tiles
        let pattern = if l.rage() {
            2
        } else if l.build > 0.25 {
            3
        } else if l.sleep() {
            0
        } else {
            1
        };
        let (mut grout, mut faces, mut halos) = (Quads::default(), Quads::default(), Quads::default());
        let gap = 0.045;
        let dark = argb(0xff07060b);
        for j in 0..TILES_Y {
            for i in 0..TILES_X {
                let x0 = (i as f64 - TILES_X as f64 / 2.0) * TILE_M;
                let y0 = (j as f64 - TILES_Y as f64 / 2.0) * TILE_M;
                let (cx, cy) = (x0 + TILE_M / 2.0, y0 + TILE_M / 2.0);
                let pr = |x: f64, y: f64| cam.project(V3::new(x, y, 0.0));
                let corners = [pr(x0 + gap, y0 + gap), pr(x0 + TILE_M - gap, y0 + gap), pr(x0 + TILE_M - gap, y0 + TILE_M - gap), pr(x0 + gap, y0 + TILE_M - gap)];
                if corners.iter().any(|p| p.2 < Cam::NEAR) {
                    continue;
                }
                let r = (cx * cx + cy * cy).sqrt();
                let away = (1.0 - r / 5.4).clamp(0.12, 1.0);
                let mut base_col = lerp(hue(bar_n, 0.56), hue(bar_n + 1, 0.56), i as f64 / (TILES_X - 1) as f64);
                let mut base = match pattern {
                    0 => 0.02 + 0.3 * (0.5 + 0.5 * (l.beats * std::f64::consts::PI / 4.0 - r * 1.3).sin()).powi(3) * (0.35 + 0.65 * l.low),
                    1 => {
                        let on = (i as i64 + 2 * j as i64 + beat_n).rem_euclid(5) == 0;
                        0.02 + if on { 0.25 + 0.55 * l.beat } else { 0.06 * l.low }
                    }
                    2 => {
                        let side = (i as f64 - (TILES_X - 1) as f64 / 2.0).abs() / ((TILES_X - 1) as f64 / 2.0);
                        let band = if side < 0.5 { l.low + (l.mid - l.low) * side * 2.0 } else { l.mid + (l.high - l.mid) * (side - 0.5) * 2.0 };
                        let tall = band.clamp(0.0, 1.0).powf(1.5) * 0.9 * TILES_Y as f64;
                        base_col = lerp(hue(bar_n, 0.56), hue(bar_n + 2, 0.56), (j as f64 / TILES_Y as f64).clamp(0.0, 1.0));
                        if (j as f64) < tall { 0.35 + 0.55 * (j + 1) as f64 / tall.max(1.0) } else { 0.02 }
                    }
                    _ => {
                        let row = TILES_Y as f64 - 1.0 - (l.beats * (1.0 + 3.0 * l.build)).rem_euclid(TILES_Y as f64);
                        0.02 + 0.85 * (1.0 - (j as f64 - row).abs() / 1.2).max(0.0) * (0.35 + 0.65 * l.build)
                    }
                };
                if pattern != 2 {
                    base *= away;
                }
                let mut ring: f64 = 0.0;
                for &(born, rx, ry) in &ps.floor_rings {
                    let age = l.beats - born;
                    let d = ((cx - rx) * (cx - rx) + (cy - ry) * (cy - ry)).sqrt() - age * 4.5;
                    ring = ring.max((-d * d / 0.1).exp() * (1.0 - age / 1.6) * away);
                }
                let t = j * TILES_X + i;
                let (step, spark) = (ps.floor_lit[t] as f64, ps.floor_spark[t] as f64);
                let sum = base + step + ring + spark + drop_k;
                let k = sum.clamp(0.0, 1.0).powf(1.25);
                let wsum = sum.max(1e-4);
                let mut col = base_col;
                col = lerp(col, rim, (step / wsum).clamp(0.0, 1.0));
                col = lerp(col, hue(bar_n + 2, 0.6), (ring / (base + step + ring).clamp(1e-4, 9.0)).clamp(0.0, 1.0));
                col = lerp(col, WHITE, ((spark + drop_k) / wsum + if k > 0.9 { (k - 0.9) * 4.0 } else { 0.0 }).clamp(0.0, 1.0));
                let centre = a(lerp(dark, col, k), 0.7 + 0.28 * k);
                let edge = a(lerp(dark, col, k * 0.45), 0.6 + 0.3 * k);
                let g = [pr(x0, y0), pr(x0 + TILE_M, y0), pr(x0 + TILE_M, y0 + TILE_M), pr(x0, y0 + TILE_M)];
                if g.iter().all(|p| p.2 > Cam::NEAR) {
                    let gc = a(argb(0xff040307), 1.0);
                    grout.tri([(g[0].0, g[0].1), (g[1].0, g[1].1), (g[2].0, g[2].1)], [gc; 3]);
                    grout.tri([(g[0].0, g[0].1), (g[2].0, g[2].1), (g[3].0, g[3].1)], [gc; 3]);
                }
                let pc = pr(cx, cy);
                let o = (pc.0, pc.1);
                let c2 = corners.map(|p| (p.0, p.1));
                for e in 0..4 {
                    faces.tri([o, c2[e], c2[(e + 1) % 4]], [centre, edge, edge]);
                }
                if k > 0.3 {
                    let spill = 0.5;
                    let out_at = |x: f64, y: f64| {
                        let p = pr(x, y);
                        (p.0, p.1)
                    };
                    let e = [
                        out_at(x0 - TILE_M * spill, y0 - TILE_M * spill),
                        out_at(x0 + TILE_M * (1.0 + spill), y0 - TILE_M * spill),
                        out_at(x0 + TILE_M * (1.0 + spill), y0 + TILE_M * (1.0 + spill)),
                        out_at(x0 - TILE_M * spill, y0 + TILE_M * (1.0 + spill)),
                    ];
                    let (hot, none) = (a(col, 0.38 * k * k), a(col, 0.0));
                    for q in 0..4 {
                        halos.tri([o, e[q], e[(q + 1) % 4]], [hot, none, none]);
                    }
                }
            }
        }
        grout.draw(out, Blend::Over);
        // the reflections in the glass: on the grout, under the lit tiles
        let many = scene.bodies.len() > 4;
        for (s, b) in scene.bodies.iter().enumerate() {
            if many && !b.lead {
                continue;
            }
            out.push(Cmd::Body { slot: s, look: lit(l, rim, 0.3, false, 1.0), under_floor: true, blend: Blend::Over });
        }
        faces.draw(out, Blend::Over);
        halos.draw(out, Blend::Plus);
        for s in 0..scene.bodies.len() {
            out.push(Cmd::FloorShadow { slot: s, to_light: V3::new(-0.2, -0.3, 1.0).unit(), colour: argb(0xff020203) });
        }
        // 5. over it: the mirror ball's glints, the beams in the heat and through a build, a
        // drop's rings; then the dancers, lit by the floor
        let cols = [hue(0, 0.6), hue(1, 0.6), hue(2, 0.62)];
        ball(out, &cam, l);
        if l.rage() || l.build > 0.5 {
            beams(out, &cam, l, &cols, if l.rage() { 0.5 + 0.5 * l.kick } else { l.build });
        }
        rings(out, &cam, l, cols[2]);
        for (s, b) in scene.bodies.iter().enumerate() {
            let look = lit(l, rim, 1.0, b.lead, 1.0);
            body(out, s, look, false, Blend::Over, !co.rig(b.model).1.skin.is_empty());
        }
    }
}

fn tile_at(x: f64, y: f64) -> Option<usize> {
    let i = (x / TILE_M + TILES_X as f64 / 2.0).floor();
    let j = (y / TILE_M + TILES_Y as f64 / 2.0).floor();
    (i >= 0.0 && j >= 0.0 && (i as usize) < TILES_X && (j as usize) < TILES_Y).then(|| j as usize * TILES_X + i as usize)
}

/// A studio floor under the figures: a soft pool of light and their shadows in it.
fn studio_floor(out: &mut Vec<Cmd>, cam: &Cam, l: &Look, slots: &[usize], light: Rgb) {
    let mut q = Quads::default();
    let seg = 28;
    let o = at(cam, V3::new(0.0, 0.0, 0.0));
    let k = 0.16 + 0.05 * l.beat;
    for i in 0..seg {
        let (t0, t1) = (i as f64 / seg as f64 * std::f64::consts::TAU, (i + 1) as f64 / seg as f64 * std::f64::consts::TAU);
        q.tri([o, at(cam, V3::new(t0.cos() * 2.4, t0.sin() * 1.6, 0.0)), at(cam, V3::new(t1.cos() * 2.4, t1.sin() * 1.6, 0.0))], [a(light, k), a(light, 0.0), a(light, 0.0)]);
    }
    q.draw(out, Blend::Plus);
    for &s in slots {
        out.push(Cmd::FloorShadow { slot: s, to_light: V3::new(0.25, -0.35, 1.0).unit(), colour: argb(0xff030303) });
    }
}

/// Beams from a truss at the back, sweeping the floor.
fn beams(out: &mut Vec<Cmd>, cam: &Cam, l: &Look, colors: &[Rgb], k: f64) {
    let mut q = Quads::default();
    let pi = std::f64::consts::PI;
    for i in 0..6 {
        let x = -3.0 + i as f64 * 1.2;
        let apex = V3::new(x, 4.5, 4.6);
        let sw = (l.beats * pi / 4.0 + i as f64 * 0.9).sin() * 2.6;
        let foot = V3::new(x * 0.4 + sw, -1.0 + (l.beats * pi / 8.0 + i as f64).cos() * 1.2, 0.0);
        let d = (foot - apex).unit();
        let side = d.cross(V3::new(0.0, -1.0, 0.0)).unit() * 0.22;
        let col = colors[i % colors.len()];
        q.tri([at(cam, apex), at(cam, foot + side), at(cam, foot - side)], [a(col, 0.32 * k), a(col, 0.02 * k), a(col, 0.02 * k)]);
    }
    q.draw(out, Blend::Plus);
}

/// On a drop's landing, rings across the floor.
fn rings(out: &mut Vec<Cmd>, cam: &Cam, l: &Look, color: Rgb) {
    let Some(since) = l.since.filter(|s| (0.0..4.0).contains(s)) else { return };
    let r = since / 4.0;
    let mut q = Quads::default();
    let seg = 40;
    let (rad, wdt) = (0.6 + 5.0 * r, 0.08 + 0.2 * r);
    for i in 0..seg {
        let (t0, t1) = (i as f64 / seg as f64 * std::f64::consts::TAU, (i + 1) as f64 / seg as f64 * std::f64::consts::TAU);
        let p = |t: f64, rr: f64| V3::new(t.cos() * rr, t.sin() * rr, 0.01);
        q.quad(cam, [p(t0, rad), p(t1, rad), p(t1, rad + wdt), p(t0, rad + wdt)], a(color, 0.6 * (1.0 - r)));
    }
    q.draw(out, Blend::Plus);
}

/// The mirror ball: its near half, facets glinting.
fn ball(out: &mut Vec<Cmd>, cam: &Cam, l: &Look) {
    let centre = V3::new(0.0, 0.9, 3.6);
    let rad = 0.32;
    let mut q = Quads::default();
    let spin = l.t * 0.6;
    let (la, lo) = (8, 16);
    let pi = std::f64::consts::PI;
    for i in 0..la {
        for j in 0..lo {
            let (t0, t1) = (pi * i as f64 / la as f64 - pi / 2.0, pi * (i + 1) as f64 / la as f64 - pi / 2.0);
            let (p0, p1) = (2.0 * pi * j as f64 / lo as f64 + spin, 2.0 * pi * (j + 1) as f64 / lo as f64 + spin);
            let pt = |t: f64, p: f64| centre + V3::new(t.cos() * p.cos() * rad, t.cos() * p.sin() * rad, t.sin() * rad);
            let mid = pt((t0 + t1) / 2.0, (p0 + p1) / 2.0);
            if (mid - centre).dot(cam.eye - centre) < 0.0 {
                continue;
            }
            let glint = meme_hash(i as f64, (j + (l.t * 4.0).floor() as i64) as f64, 3.0);
            let g = if glint > 0.9 - 0.2 * l.top { WHITE } else { lerp(argb(0xff303038), argb(0xffa0a0b0), glint) };
            q.quad(cam, [pt(t0, p0), pt(t0, p1), pt(t1, p1), pt(t1, p0)], a(g, 1.0));
        }
    }
    q.draw(out, Blend::Over);
}

fn ease_out_cubic(t: f64) -> f64 {
    1.0 - (1.0 - t).powi(3)
}

fn ease_in_out_cubic(t: f64) -> f64 {
    if t < 0.5 { 4.0 * t * t * t } else { 1.0 - (-2.0 * t + 2.0).powi(3) / 2.0 }
}

/// The dust as the record has it now: a drop blows it off the bodies (out in a beat, held in
/// the air six, back over eight), a phrase now and then the same less far, asleep it drifts.
fn dust_now(l: &Look, bodies: usize) -> Dust {
    let pal = l.st.palette;
    let salt = l.st.master().track_id.unwrap_or(0).rem_euclid(9973) as f64;
    let burst = |since: f64| {
        if since < 0.0 {
            0.0
        } else if since < 1.0 {
            ease_out_cubic(since)
        } else if since < 7.0 {
            1.0
        } else if since < 15.0 {
            1.0 - ease_in_out_cubic((since - 7.0) / 8.0)
        } else {
            0.0
        }
    };
    let mut k = l.since.map_or(0.0, burst);
    let phrase = (l.beats / 32.0).floor();
    if !l.sleep() && meme_hash(salt, phrase, 59.0) < 0.35 {
        k = k.max(0.7 * burst(l.beats - phrase * 32.0));
    }
    if l.sleep() {
        k = k.max(0.12 + 0.14 * (0.5 + 0.5 * (l.beats * std::f64::consts::PI / 16.0).sin()));
    }
    let mode = ((meme_hash(salt, (l.beats / 64.0).floor(), 61.0) * 3.0).floor() as i64).clamp(0, 2) as u32;
    Dust {
        size: 0.0055,
        explode: k as f32,
        swirl: (0.6 + 0.8 * l.energy) as f32,
        rise: (0.35 + 0.3 * l.build) as f32,
        time: l.t as f32,
        mode,
        a: if mode == 0 { WHITE } else { hsl(pal.accent.h, 0.45, 0.85) },
        b: hsl(pal.primary.h, 0.8, 0.55),
        alpha: 0.45,
        density: (1.6 / bodies.max(1) as f64).clamp(0.2, 1.0) as f32,
        shimmer: (l.kick + 0.5 * l.snare).clamp(0.0, 1.5) as f32,
    }
}

/// The finish's colours and cell as the look draws them, before the knobs (v1's _postDrawn).
fn post_drawn(l: &Look, art: Art, h: f64) -> ([f32; 3], [f32; 3], f64, f64) {
    let pal = l.st.palette;
    let dark = hsl(pal.primary.h, 0.45, 0.035);
    match art {
        Art::Dither => (argb(0xffeee7d6), hsl(pal.primary.h, 0.4, 0.07), (h / 220.0).max(2.0), 0.0),
        Art::Contour => (hsl(pal.accent.h, 0.85, 0.62), dark, 0.0, 0.0),
        Art::Halftone => (hsl(pal.primary.h, 0.9, 0.55), argb(0xff050506), (h / if l.rage() { 80.0 } else { 110.0 }).max(4.0), 0.0),
        Art::Thermal => (WHITE, BLACK, 0.0, 0.0),
        Art::Crt => (argb(0xfff6dcff), argb(0xff07020f), (h / if l.rage() { 110.0 } else { 135.0 }).max(3.0), 0.2),
        Art::Lines => (hsl(pal.accent.h, 0.35, 0.85), argb(0xff030303), (h / 72.0).max(5.0), 0.0),
        _ => (hsl(pal.accent.h, 0.55, 0.78), argb(0xff040404), h / if l.rage() { 52.0 } else { 40.0 }, 0.2),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wo_show::deck::ShowDeck;

    #[test]
    fn every_rendering_paints() {
        let co = Company::load(&std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/dance")).expect("the shipped dancers");
        for art in Art::ALL.iter().copied().filter(|a| a.drawn()) {
            let mut sim = DanceSim::default();
            sim.forced_art = Some(art);
            let mut cmds = vec![];
            for f in 0..90 {
                let beat = 30.0 + f as f64 * 0.035;
                let b = beat.floor() as i64;
                let deck = ShowDeck { name: "A".into(), track_id: Some(7), playing: true, bpm: Some(124.0), beat_index: Some(b), beat_phase: beat - b as f64, beat_in_bar: Some(b % 4), bar_index: Some(b / 4), section: Some("drop".into()), energy: 0.9, ..Default::default() };
                let st = ShowState { a: deck, dt: 1.0 / 60.0, ..Default::default() };
                let scene = sim.frame(&co, &st, 1.0 / 60.0, 1280.0, 720.0);
                cmds = sim.paint(&co, &scene, &st, 1.0 / 60.0);
            }
            assert!(matches!(cmds[0], Cmd::Camera(_)), "{art:?}");
            let bodies = cmds.iter().filter(|c| matches!(c, Cmd::Body { .. } | Cmd::Dust { .. })).count();
            assert!(bodies >= 1, "{art:?}: no bodies drawn");
            if let Some(m) = art.fx_mode() {
                assert!(cmds.iter().any(|c| matches!(c, Cmd::Post(p) if p.mode == m)), "{art:?}: its finish");
            }
        }
    }
}
