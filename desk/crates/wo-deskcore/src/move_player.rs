//! The moves watched on the Desk (v1: show_moves.dart's viewer and strips): a move of the
//! dancers' bank played on its own — the scan skinned on the CPU (wo-dance's rig), seen
//! square on as the stage's front shot sees it, its triangles back to front for a toolkit to
//! draw as one mesh; and a strip of its poses, flat, for the list. A few hundred pixels
//! across, a pose costs about a millisecond.
use std::path::Path;

use wo_dance::Rig;
use wo_dance::clock::{Frame, Shot, Troupe, V3};

/// How a body is drawn: its scan's skin, chrome, a flat silhouette.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum MoveLook {
    #[default]
    Textured,
    Chrome,
    Silhouette,
}

/// One body in a pose, for a picture `w`×`h`: each corner's place (pixels), its skin
/// coordinate and its light (0..1); its triangles far to near.
#[derive(Clone, Debug, Default)]
pub struct Body {
    /// Which dancer (its skin).
    pub model: usize,
    pub at: Vec<[f32; 2]>,
    pub uv: Vec<[f32; 2]>,
    pub light: Vec<f32>,
    pub tris: Vec<u32>,
    /// How far it is, for two bodies drawn one after the other.
    pub depth: f32,
}

/// The dancers' rigs, loaded once.
pub struct MovePlayer {
    rigs: Vec<(String, String, Rig)>,
}

/// A move's facts: its tempo, beats, whether it is a duet.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MoveFacts {
    pub bpm: f64,
    pub beats: usize,
    pub duo: bool,
}

impl MovePlayer {
    /// The dancers from their folder (None where it is not there).
    pub fn load() -> Option<MovePlayer> {
        Self::load_from(&wo_show::scenes::dance_dir()?)
    }

    pub fn load_from(dir: &Path) -> Option<MovePlayer> {
        let rigs: Vec<(String, String, Rig)> =
            wo_show::scenes::DANCERS.iter().filter_map(|(id, name)| Rig::load(&dir.join(id)).ok().map(|r| (id.to_string(), name.to_string(), r))).collect();
        (!rigs.is_empty()).then_some(MovePlayer { rigs })
    }

    /// The dancers: id, name.
    pub fn models(&self) -> Vec<(String, String)> {
        self.rigs.iter().map(|(id, name, _)| (id.clone(), name.clone())).collect()
    }

    /// A dancer's skin picture (RGBA).
    pub fn skin(&self, model: usize) -> Option<(u32, u32, Vec<u8>)> {
        self.rigs.get(model)?.2.skin_rgba()
    }

    pub fn facts(&self, id: &str) -> Option<MoveFacts> {
        let r = &self.rigs.first()?.2;
        let m = &r.moves[r.move_by_id(id)?];
        Some(MoveFacts { bpm: m.bpm, beats: m.beats, duo: m.duo.is_some() })
    }

    /// Move `id` danced by `model`, `beat` beats in (round its loop), seen square on in a
    /// picture `w`×`h` (`mirror`: flipped): the body — and a duet's partner, danced by the
    /// other — far first.
    pub fn bodies(&self, model: usize, id: &str, beat: f64, mirror: bool, w: f32, h: f32) -> Vec<Body> {
        let Some((_, _, rig)) = self.rigs.get(model) else { return vec![] };
        let Some(i) = rig.move_by_id(id) else { return vec![] };
        let mut who = vec![(model, i)];
        if rig.moves[i].duo.is_some() {
            let other = (model + 1) % self.rigs.len();
            let p = rig.partner_of(i);
            if p != i
                && let Some(pi) = self.rigs[other].2.move_by_id(&rig.moves[p].id)
            {
                who.push((other, pi));
            }
        }
        // the poses, and the middle they are framed about (the hips; a duet's between)
        let poses: Vec<(usize, &Rig, Vec<wo_dance::M34>)> = who
            .iter()
            .map(|&(m, i)| {
                let r = &self.rigs[m].2;
                (m, r, r.solve(&r.sample(i, beat)))
            })
            .collect();
        let hips = |world: &[wo_dance::M34]| [world[0][3], world[0][7]];
        let mid = poses.iter().map(|(_, _, w)| hips(w)).fold([0.0; 2], |a, h| [a[0] + h[0], a[1] + h[1]]).map(|v| v / poses.len() as f64);
        let wide = if poses.len() > 1 { Troupe::Duo } else { Troupe::Solo };
        let cam = Frame::of(Shot::Front, wide).cam(w as f64, h as f64, 0.0);
        let key = V3::new(-0.35, -0.8, 0.65).unit();
        let mut out: Vec<Body> = poses
            .into_iter()
            .map(|(m, r, world)| {
                let skin = r.skinning(&world);
                let mut b = Body { model: m, ..Default::default() };
                let mut depth = 0.0f64;
                let mut n = 0usize;
                let mut tri_depth: Vec<(f32, [u32; 3])> = vec![];
                for (k, mesh) in r.meshes.iter().enumerate() {
                    let (pos, nrm) = r.deform(k, &skin);
                    let base = b.at.len() as u32;
                    let place: Vec<(f64, f64, f64)> = (0..mesh.positions())
                        .map(|v| {
                            let mut x = pos[v * 3] as f64 - mid[0];
                            if mirror {
                                x = -x;
                            }
                            cam.project(V3::new(x, pos[v * 3 + 1] as f64 - mid[1], pos[v * 3 + 2] as f64))
                        })
                        .collect();
                    let light: Vec<f32> = (0..mesh.positions())
                        .map(|v| {
                            let nx = if mirror { -nrm[v * 3] } else { nrm[v * 3] };
                            let d = nx as f64 * key.x + nrm[v * 3 + 1] as f64 * key.y + nrm[v * 3 + 2] as f64 * key.z;
                            d.max(0.0) as f32
                        })
                        .collect();
                    for c in 0..mesh.corners() {
                        let s = mesh.src[c] as usize;
                        let (x, y, z) = place[s];
                        b.at.push([x as f32, y as f32]);
                        b.uv.push([mesh.uv[c * 2], mesh.uv[c * 2 + 1]]);
                        b.light.push(light[s]);
                        depth += z;
                        n += 1;
                    }
                    for t in mesh.tris.as_chunks::<3>().0 {
                        let [a, bb, c] = [t[0] as usize, t[1] as usize, t[2] as usize];
                        let z = (place[mesh.src[a] as usize].2 + place[mesh.src[bb] as usize].2 + place[mesh.src[c] as usize].2) as f32;
                        tri_depth.push((z, [base + a as u32, base + bb as u32, base + c as u32]));
                    }
                }
                tri_depth.sort_unstable_by(|a, b| b.0.total_cmp(&a.0));
                b.tris = tri_depth.into_iter().flat_map(|(_, t)| t).collect();
                b.depth = (depth / n.max(1) as f64) as f32;
                b
            })
            .collect();
        out.sort_by(|a, b| b.depth.total_cmp(&a.depth));
        out
    }

    /// `n` poses of move `id` (evenly through its loop) as flat figures side by side, each
    /// `cell_w`×`cell_h`: RGBA, the figures white on clear.
    pub fn strip(&self, model: usize, id: &str, n: usize, cell_w: u32, cell_h: u32) -> Vec<u8> {
        let (w, h) = (cell_w * n as u32, cell_h);
        let mut px = vec![0u8; (w * h * 4) as usize];
        let Some(f) = self.facts(id) else { return px };
        for k in 0..n {
            let beat = k as f64 * f.beats as f64 / n as f64;
            for b in self.bodies(model, id, beat, false, cell_w as f32, cell_h as f32) {
                let ink = if b.model == model { 235 } else { 150 };
                for t in b.tris.as_chunks::<3>().0 {
                    let p = [b.at[t[0] as usize], b.at[t[1] as usize], b.at[t[2] as usize]];
                    fill(&mut px, w, h, k as u32 * cell_w, cell_w, p, ink);
                }
            }
        }
        px
    }
}

/// A triangle filled into `px` (`w`×`h` RGBA), in the cell from `x0`, `cell_w` wide.
fn fill(px: &mut [u8], w: u32, h: u32, x0: u32, cell_w: u32, p: [[f32; 2]; 3], ink: u8) {
    let min_x = p.iter().map(|q| q[0]).fold(f32::MAX, f32::min).floor().max(0.0) as i64;
    let max_x = p.iter().map(|q| q[0]).fold(f32::MIN, f32::max).ceil().min(cell_w as f32 - 1.0) as i64;
    let min_y = p.iter().map(|q| q[1]).fold(f32::MAX, f32::min).floor().max(0.0) as i64;
    let max_y = p.iter().map(|q| q[1]).fold(f32::MIN, f32::max).ceil().min(h as f32 - 1.0) as i64;
    let edge = |a: [f32; 2], b: [f32; 2], x: f32, y: f32| (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]);
    let area = edge(p[0], p[1], p[2][0], p[2][1]);
    if area.abs() < 1e-6 {
        return;
    }
    for y in min_y..=max_y {
        for x in min_x..=max_x {
            let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
            let (e0, e1, e2) = (edge(p[1], p[2], fx, fy), edge(p[2], p[0], fx, fy), edge(p[0], p[1], fx, fy));
            if (e0 >= 0.0 && e1 >= 0.0 && e2 >= 0.0) || (e0 <= 0.0 && e1 <= 0.0 && e2 <= 0.0) {
                let i = ((y as u32 * w + x0 + x as u32) * 4) as usize;
                if px[i + 3] < ink {
                    px[i..i + 4].copy_from_slice(&[ink, ink, ink, ink]);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn player() -> MovePlayer {
        MovePlayer::load_from(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/dance")).expect("the shipped dancers")
    }

    #[test]
    fn a_move_is_seen_square_on_and_a_strip_of_it_is_drawn() {
        let p = player();
        assert_eq!(p.models().len(), 2);
        let id = "long22";
        let f = p.facts(id).unwrap();
        assert!(f.beats > 0 && f.bpm > 40.0 && !f.duo);
        let t = std::time::Instant::now();
        let bodies = p.bodies(0, id, 1.5, false, 320.0, 360.0);
        let took = t.elapsed();
        assert_eq!(bodies.len(), 1);
        let b = &bodies[0];
        assert!(b.tris.len() >= 9000 * 3 && b.at.len() == b.uv.len() && b.at.len() == b.light.len());
        // the body stands in the picture: its top in the upper half, its feet in the lower
        let ys: Vec<f32> = b.at.iter().map(|a| a[1]).collect();
        let (top, low) = (ys.iter().copied().fold(f32::MAX, f32::min), ys.iter().copied().fold(f32::MIN, f32::max));
        assert!(top > 0.0 && top < 180.0 && low > 180.0 && low < 360.0, "{top}..{low}");
        let xs: Vec<f32> = b.at.iter().map(|a| a[0]).collect();
        let mid = (xs.iter().copied().fold(f32::MAX, f32::min) + xs.iter().copied().fold(f32::MIN, f32::max)) / 2.0;
        assert!((mid - 160.0).abs() < 60.0, "in the middle: {mid}");
        // mirrored: the other way round
        let m = &p.bodies(0, id, 1.5, true, 320.0, 360.0)[0];
        assert!((m.at[0][0] - (320.0 - b.at[0][0])).abs() < 1.0);
        // a duet: its partner too
        let duo = p.rigs[0].2.moves.iter().find(|m| m.duo.is_some()).unwrap().id.clone();
        assert_eq!(p.bodies(0, &duo, 0.5, false, 320.0, 360.0).len(), 2, "{duo}");
        // a strip: six poses, something drawn in each
        let s = p.strip(0, id, 6, 24, 44);
        for k in 0..6 {
            let lit = (0..44).flat_map(|y| (0..24).map(move |x| (y, x))).filter(|(y, x)| s[((y * 144 + k * 24 + x) * 4 + 3) as usize] > 0).count();
            assert!(lit > 30, "pose {k}: {lit}");
        }
        eprintln!("a pose: {took:?}");
    }
}
