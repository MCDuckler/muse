//! The dancers (plan: ~/.claude/plans/wetowl-stage-rust.md, P6; P0 reads them): a
//! photogrammetry scan as a skinned mesh, its skeleton, and every move as poses sampled
//! eight times a beat — the files tools/show-dance/dance_export3d.py writes
//! (app/assets/show/dance/<who>/dancer.json, dancer.bin, moves.bin, skin.webp), read the way
//! v1 reads them (app/lib/src/ui/show/show_dance_rig.dart).
//!
//! Coordinates are the capture's: metres, z up, the dancer facing −y on average. A pose is
//! a rotation per bone — the hips' in the world, every other bone's against its parent —
//! and where the hips are. Matrices are 3×4 row-major (the fourth row 0 0 0 1 implied).
use std::path::Path;

use serde::Deserialize;

pub type M34 = [f64; 12];

/// A move as the bank lists it.
#[derive(Clone, Debug, Deserialize)]
pub struct Move {
    pub id: String,
    #[serde(default)]
    pub style: String,
    #[serde(default)]
    pub tier: String,
    #[serde(default)]
    pub energy: f64,
    #[serde(default)]
    pub bpm: f64,
    pub beats: usize,
    #[serde(default, rename = "handsUp")]
    pub hands_up: f64,
    /// Where its samples start in moves.bin.
    pub offset: usize,
    #[serde(default)]
    pub duo: Option<String>,
    #[serde(default)]
    pub part: i64,
    /// Beats its loop is turned by so the bounce's dip lands on the beat (worked out on load).
    #[serde(skip)]
    pub shift: f64,
    /// How strongly it bounces once a beat, 0..1 (worked out on load).
    #[serde(skip)]
    pub pulse: f64,
}

#[derive(Deserialize)]
struct BoneJson {
    name: String,
    parent: i64,
    rest: Vec<f64>,
}

#[derive(Deserialize)]
struct MeshJson {
    positions: usize,
    verts: usize,
    tris: usize,
    offset: usize,
}

#[derive(Deserialize)]
struct RigJson {
    bones: Vec<BoneJson>,
    meshes: Vec<MeshJson>,
    moves: Vec<Move>,
    #[serde(default = "eight")]
    fpb: usize,
}

fn eight() -> usize {
    8
}

/// A mesh of the scan: skinned per position (rest place and normal, four bones and
/// weights), drawn per corner (its skin coordinate and the position it is).
#[derive(Clone, Debug)]
pub struct Mesh {
    pub pos: Vec<f32>,
    pub nrm: Vec<f32>,
    pub bone: Vec<u8>,
    pub weight: Vec<u8>,
    pub uv: Vec<f32>,
    pub src: Vec<u16>,
    pub tris: Vec<u16>,
}

impl Mesh {
    pub fn positions(&self) -> usize {
        self.pos.len() / 3
    }
    pub fn corners(&self) -> usize {
        self.uv.len() / 2
    }
}

/// A body's pose: per bone a quaternion (w, x, y, z), and the hips' place.
#[derive(Clone, Debug, PartialEq)]
pub struct Pose {
    pub q: Vec<[f64; 4]>,
    pub hips: [f64; 3],
}

pub struct Rig {
    pub names: Vec<String>,
    pub parent: Vec<i64>,
    /// Each bone's rest in the world.
    pub rest: Vec<M34>,
    pub meshes: Vec<Mesh>,
    pub moves: Vec<Move>,
    pub fpb: usize,
    /// The skin picture (webp), as the files hold it.
    pub skin: Vec<u8>,
    /// The scan's top, metres.
    pub height: f64,
    samples: Vec<u8>,
    inv: Vec<M34>,
    rel: Vec<M34>,
}

#[derive(Debug)]
pub struct LoadError(pub String);

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for LoadError {}

struct Cursor<'a> {
    b: &'a [u8],
    at: usize,
}

impl Cursor<'_> {
    fn take(&mut self, n: usize) -> Result<&[u8], LoadError> {
        let s = self.b.get(self.at..self.at + n).ok_or_else(|| LoadError(format!("dancer.bin ends at {} (wanted {} more)", self.b.len(), n)))?;
        self.at += n;
        Ok(s)
    }
    fn f32s(&mut self, n: usize) -> Result<Vec<f32>, LoadError> {
        Ok(self.take(n * 4)?.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect())
    }
    fn u16s(&mut self, n: usize) -> Result<Vec<u16>, LoadError> {
        Ok(self.take(n * 2)?.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes([c[0], c[1]])).collect())
    }
    fn u8s(&mut self, n: usize) -> Result<Vec<u8>, LoadError> {
        Ok(self.take(n)?.to_vec())
    }
}

/// out = a · b
pub fn mul(a: &M34, b: &M34) -> M34 {
    let mut r = [0.0; 12];
    for i in 0..3 {
        let (a0, a1, a2, a3) = (a[i * 4], a[i * 4 + 1], a[i * 4 + 2], a[i * 4 + 3]);
        for j in 0..4 {
            r[i * 4 + j] = a0 * b[j] + a1 * b[4 + j] + a2 * b[8 + j] + if j == 3 { a3 } else { 0.0 };
        }
    }
    r
}

/// The inverse of a rotation with a uniform scale and a translation.
pub fn invert(m: &M34) -> M34 {
    let s2 = m[0] * m[0] + m[4] * m[4] + m[8] * m[8];
    let mut r = [0.0; 12];
    for i in 0..3 {
        for j in 0..3 {
            r[i * 4 + j] = m[j * 4 + i] / s2;
        }
    }
    for i in 0..3 {
        r[i * 4 + 3] = -(r[i * 4] * m[3] + r[i * 4 + 1] * m[7] + r[i * 4 + 2] * m[11]);
    }
    r
}

pub const IDENTITY: M34 = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0];

pub fn from_quat(q: &[f64; 4]) -> M34 {
    let [w, x, y, z] = *q;
    [
        1.0 - 2.0 * (y * y + z * z),
        2.0 * (x * y - z * w),
        2.0 * (x * z + y * w),
        0.0,
        2.0 * (x * y + z * w),
        1.0 - 2.0 * (x * x + z * z),
        2.0 * (y * z - x * w),
        0.0,
        2.0 * (x * z - y * w),
        2.0 * (y * z + x * w),
        1.0 - 2.0 * (x * x + y * y),
        0.0,
    ]
}

impl Rig {
    /// A dancer's folder (dancer.json, dancer.bin, moves.bin, skin.webp).
    pub fn load(dir: &Path) -> Result<Rig, LoadError> {
        let read = |n: &str| std::fs::read(dir.join(n)).map_err(|e| LoadError(format!("{}: {e}", dir.join(n).display())));
        let json: RigJson = serde_json::from_slice(&read("dancer.json")?).map_err(|e| LoadError(format!("dancer.json: {e}")))?;
        let mesh_bytes = read("dancer.bin")?;
        let samples = read("moves.bin")?;
        let skin = read("skin.webp").unwrap_or_default();
        Rig::parse(json, &mesh_bytes, samples, skin)
    }

    fn parse(j: RigJson, mesh_bytes: &[u8], samples: Vec<u8>, skin: Vec<u8>) -> Result<Rig, LoadError> {
        let mut rest = vec![];
        for b in &j.bones {
            if b.rest.len() < 12 {
                return Err(LoadError(format!("bone {}: a rest of {} numbers", b.name, b.rest.len())));
            }
            let mut m = [0.0; 12];
            m.copy_from_slice(&b.rest[..12]);
            rest.push(m);
        }
        let mut meshes = vec![];
        for m in &j.meshes {
            let mut c = Cursor { b: mesh_bytes, at: m.offset };
            let pos = c.f32s(m.positions * 3)?;
            let nrm = c.f32s(m.positions * 3)?;
            let bone = c.u8s(m.positions * 4)?;
            let weight = c.u8s(m.positions * 4)?;
            let uv = c.f32s(m.verts * 2)?;
            let src = c.u16s(m.verts)?;
            let tris = c.u16s(m.tris * 3)?;
            meshes.push(Mesh { pos, nrm, bone, weight, uv, src, tris });
        }
        let parent: Vec<i64> = j.bones.iter().map(|b| b.parent).collect();
        let inv: Vec<M34> = rest.iter().map(invert).collect();
        let rel = (0..rest.len()).map(|i| if parent[i] < 0 { IDENTITY } else { mul(&inv[parent[i] as usize], &rest[i]) }).collect();
        let height = meshes.iter().flat_map(|m| m.pos.as_chunks::<3>().0.iter().map(|p| p[2] as f64)).fold(0.0, f64::max);
        let mut rig = Rig { names: j.bones.iter().map(|b| b.name.clone()).collect(), parent, rest, meshes, moves: j.moves, fpb: j.fpb, skin, height, samples, inv, rel };
        let need = rig.moves.iter().map(|m| m.offset + (m.beats * rig.fpb + 1) * rig.stride()).max().unwrap_or(0);
        if need > rig.samples.len() + rig.stride() {
            return Err(LoadError(format!("moves.bin holds {} bytes, the moves want {need}", rig.samples.len())));
        }
        for i in 0..rig.moves.len() {
            let (pulse, shift) = rig.pulse(i);
            rig.moves[i].pulse = pulse;
            if let Some(s) = shift {
                rig.moves[i].shift = s;
            }
        }
        // a duet's halves bounce to the lead's beat together
        let duos: Vec<(String, f64)> = rig.moves.iter().filter(|m| m.part == 0).filter_map(|m| m.duo.clone().map(|d| (d, m.shift))).collect();
        for (d, s) in duos {
            for m in rig.moves.iter_mut().filter(|m| m.duo.as_deref() == Some(d.as_str())) {
                m.shift = s;
            }
        }
        Ok(rig)
    }

    pub fn bones(&self) -> usize {
        self.names.len()
    }

    fn stride(&self) -> usize {
        self.bones() * 8 + 6
    }

    pub fn bone(&self, name: &str) -> Option<usize> {
        self.names.iter().position(|n| n == name)
    }

    pub fn move_by_id(&self, id: &str) -> Option<usize> {
        self.moves.iter().position(|m| m.id == id)
    }

    fn i16_at(&self, at: usize) -> f64 {
        i16::from_le_bytes([self.samples[at], self.samples[at + 1]]) as f64
    }

    /// The pump below which a move's bounce is too faint to set its beat by.
    pub const MIN_PULSE_SHIFT: f64 = 0.25;

    /// How strongly move `i` bounces once a beat, and (if strongly enough) the beats its
    /// loop is turned by so the dip lands on the beat (v1's DanceRig._pulse).
    fn pulse(&self, i: usize) -> (f64, Option<f64>) {
        let m = &self.moves[i];
        let n = m.beats * self.fpb;
        let z: Vec<f64> = (0..n).map(|j| self.i16_at(m.offset + j * self.stride() + self.bones() * 8 + 4) / 1000.0).collect();
        let mean = z.iter().sum::<f64>() / n as f64;
        let (mut re, mut im, mut var) = (0.0, 0.0, 0.0);
        for (j, zj) in z.iter().enumerate() {
            let d = zj - mean;
            let a = 2.0 * std::f64::consts::PI * j as f64 / self.fpb as f64;
            re += d * a.cos();
            im += d * a.sin();
            var += d * d / n as f64;
        }
        let amp = 2.0 / n as f64 * (re * re + im * im).sqrt();
        let share = amp / ((2.0 * var).sqrt() + 0.004);
        let pulse = (share * (amp / 0.025).clamp(0.0, 1.0)).clamp(0.0, 1.0);
        let shift = (pulse >= Self::MIN_PULSE_SHIFT).then(|| {
            let low = im.atan2(re) / (2.0 * std::f64::consts::PI) + 0.5;
            low - (low + 0.5).floor()
        });
        (pulse, shift)
    }

    /// Move `i`'s pose `beat` capture beats in (round its loop), samples blended.
    pub fn sample(&self, i: usize, beat: f64) -> Pose {
        let m = &self.moves[i];
        let n = m.beats * self.fpb;
        let mut s = ((beat + m.shift) % m.beats as f64) * self.fpb as f64;
        if s < 0.0 {
            s += n as f64;
        }
        let k0 = (s.floor() as usize).min(n - 1);
        let f = s - k0 as f64;
        let a = m.offset + k0 * self.stride();
        let b = a + self.stride();
        let q = (0..self.bones())
            .map(|k| {
                let get = |o: usize| [0, 1, 2, 3].map(|c| self.i16_at(o + k * 8 + c * 2) / 32767.0);
                let mut q = get(a);
                if f > 0.0 {
                    let mut r = get(b);
                    if q.iter().zip(&r).map(|(x, y)| x * y).sum::<f64>() < 0.0 {
                        r = r.map(|v| -v);
                    }
                    for c in 0..4 {
                        q[c] += (r[c] - q[c]) * f;
                    }
                }
                let len = q.iter().map(|v| v * v).sum::<f64>().sqrt();
                q.map(|v| v / len)
            })
            .collect();
        let ha = a + self.bones() * 8;
        let hb = b + self.bones() * 8;
        let hips = [0, 1, 2].map(|k| {
            let x0 = self.i16_at(ha + k * 2) / 1000.0;
            let x1 = if f > 0.0 { self.i16_at(hb + k * 2) / 1000.0 } else { x0 };
            x0 + (x1 - x0) * f
        });
        Pose { q, hips }
    }

    /// Each bone's place in the world for `pose`.
    pub fn solve(&self, pose: &Pose) -> Vec<M34> {
        let mut out: Vec<M34> = Vec::with_capacity(self.bones());
        for i in 0..self.bones() {
            let mut m = from_quat(&pose.q[i]);
            if self.parent[i] < 0 {
                m[3] = pose.hips[0];
                m[7] = pose.hips[1];
                m[11] = pose.hips[2];
                out.push(m);
            } else {
                let t = mul(&out[self.parent[i] as usize], &self.rel[i]);
                out.push(mul(&t, &m));
            }
        }
        out
    }

    /// The skinning matrices: `world` (from [Rig::solve]) against the rest.
    pub fn skinning(&self, world: &[M34]) -> Vec<M34> {
        world.iter().zip(&self.inv).map(|(w, i)| mul(w, i)).collect()
    }

    /// Mesh `mesh` put in a pose by `skin` (from [Rig::skinning]): positions and normals.
    pub fn deform(&self, mesh: usize, skin: &[M34]) -> (Vec<f32>, Vec<f32>) {
        let m = &self.meshes[mesh];
        let n = m.positions();
        let (mut pos, mut nrm) = (vec![0f32; n * 3], vec![0f32; n * 3]);
        for v in 0..n {
            let mut s = [0.0f64; 12];
            for j in 0..4 {
                let w = m.weight[v * 4 + j];
                if w == 0 {
                    continue;
                }
                let b = &skin[m.bone[v * 4 + j] as usize];
                for k in 0..12 {
                    s[k] += b[k] * w as f64 / 255.0;
                }
            }
            let [x, y, z] = [0, 1, 2].map(|c| m.pos[v * 3 + c] as f64);
            let [a, b, c] = [0, 1, 2].map(|c| m.nrm[v * 3 + c] as f64);
            for r in 0..3 {
                pos[v * 3 + r] = (s[r * 4] * x + s[r * 4 + 1] * y + s[r * 4 + 2] * z + s[r * 4 + 3]) as f32;
                nrm[v * 3 + r] = (s[r * 4] * a + s[r * 4 + 1] * b + s[r * 4 + 2] * c) as f32;
            }
            let l = (nrm[v * 3..v * 3 + 3].iter().map(|x| x * x).sum::<f32>() + 1e-12).sqrt();
            for r in 0..3 {
                nrm[v * 3 + r] /= l;
            }
        }
        (pos, nrm)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chris() -> Option<Rig> {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/dance/chris");
        dir.is_dir().then(|| Rig::load(&dir).expect("chris loads"))
    }

    #[test]
    fn the_scan_reads_whole() {
        let Some(r) = chris() else { return };
        assert_eq!(r.bones(), 21);
        assert_eq!(r.moves.len(), 231);
        assert_eq!(r.meshes.len(), 2);
        assert_eq!(r.meshes[0].positions(), 4290);
        assert_eq!(r.meshes[0].corners(), 9888);
        assert_eq!(r.meshes[0].tris.len(), 9000 * 3);
        assert!((1.5..2.1).contains(&r.height), "a person's height: {}", r.height);
        assert!(r.meshes.iter().all(|m| m.src.iter().all(|&s| (s as usize) < m.positions())));
        assert!(!r.skin.is_empty());
    }

    #[test]
    fn a_pose_is_a_body() {
        let Some(r) = chris() else { return };
        let i = r.move_by_id("long22").unwrap();
        for beat in [0.0, 0.37, 3.5, 7.99, 12.25] {
            let p = r.sample(i, beat);
            for q in &p.q {
                let l: f64 = q.iter().map(|v| v * v).sum();
                assert!((l - 1.0).abs() < 1e-9);
            }
            let world = r.solve(&p);
            let head = &world[r.bone("Head").unwrap()];
            let foot = &world[r.bone("Foot_L").unwrap()];
            // standing: the head well above the feet
            assert!(head[11] - foot[11] > 1.0, "beat {beat}: head {} feet {}", head[11], foot[11]);
            let (pos, _) = r.deform(0, &r.skinning(&world));
            let zs: Vec<f32> = pos.as_chunks::<3>().0.iter().map(|p| p[2]).collect();
            let span = zs.iter().cloned().fold(f32::MIN, f32::max) - zs.iter().cloned().fold(f32::MAX, f32::min);
            assert!((1.2..2.2).contains(&span), "beat {beat}: body {span} m tall");
        }
    }

    #[test]
    fn the_rest_pose_puts_the_mesh_where_it_was() {
        // Every bone at its rest: the skinning is the identity, the mesh unmoved.
        let Some(r) = chris() else { return };
        let skin = r.skinning(&r.rest);
        let (pos, _) = r.deform(0, &skin);
        let worst = pos.iter().zip(&r.meshes[0].pos).map(|(a, b)| (a - b).abs()).fold(0.0, f32::max);
        assert!(worst < 1e-4, "{worst}");
    }

    #[test]
    fn moves_that_bounce_land_the_dip_on_the_beat() {
        let Some(r) = chris() else { return };
        let bouncy = r.moves.iter().filter(|m| m.pulse >= Rig::MIN_PULSE_SHIFT).count();
        assert!(bouncy > 20, "{bouncy} moves bounce");
        assert!(r.moves.iter().all(|m| (-0.5..=0.5).contains(&m.shift)));
    }
}
