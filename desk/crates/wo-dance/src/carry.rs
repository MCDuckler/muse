//! What is left of the pose a dancer was in when it stepped into a new move (v1:
//! show_dance_rig.dart DanceCarry): per bone the turn from the new move's rotation to the old
//! one (an axis times an angle) and the hips' shift, each with how fast it was changing,
//! faded to nothing over a few beats on a quintic that leaves no kink (inertialisation, Bollo
//! 2016). The new move plays whole underneath — its own timing, its own steps — and the body
//! carries its momentum across.
use crate::Pose;

#[derive(Clone, Debug)]
pub struct Carry {
    x: Vec<f64>,
    v: Vec<f64>,
    a: Vec<f64>,
    b: Vec<f64>,
    c: Vec<f64>,
    d: Vec<f64>,
    /// Beats it fades over; 0 none.
    pub len: f64,
}

impl Carry {
    pub fn new(bones: usize) -> Carry {
        let z = vec![0.0; bones * 3 + 3];
        Carry { x: z.clone(), v: z.clone(), a: z.clone(), b: z.clone(), c: z.clone(), d: z, len: 0.0 }
    }

    /// From `from` (the old pose now) and `from_was` (it `h` beats ago) to `to` and `to_was`
    /// (the new move at its entry, and `h` before it), faded over `len` beats.
    pub fn start(&mut self, from: &Pose, from_was: &Pose, to: &Pose, to_was: &Pose, h: f64, len: f64) {
        self.len = len;
        if len <= 0.0 {
            return;
        }
        let n = from.q.len();
        for b in 0..n {
            let r0 = log_diff(&from.q[b], &to.q[b]);
            let r1 = log_diff(&from_was.q[b], &to_was.q[b]);
            for k in 0..3 {
                self.x[b * 3 + k] = r0[k];
                self.v[b * 3 + k] = (r0[k] - r1[k]) / h;
            }
        }
        for k in 0..3 {
            let x0 = from.hips[k] - to.hips[k];
            let x1 = from_was.hips[k] - to_was.hips[k];
            self.x[n * 3 + k] = x0;
            self.v[n * 3 + k] = (x0 - x1) / h;
        }
        // the fade's coefficients, a quintic each: from x0 at speed v0 to rest at len; a
        // speed far beyond what the gap explains is held in, or it would overshoot
        let t1 = len;
        for i in 0..self.x.len() {
            let x0 = self.x[i];
            let cap = 4.0 * x0.abs() / t1 + 0.6;
            let v0 = self.v[i].clamp(-cap, cap);
            self.v[i] = v0;
            let a0 = (-8.0 * v0 * t1 - 20.0 * x0) / (t1 * t1);
            self.a[i] = -(a0 * t1 * t1 + 6.0 * v0 * t1 + 12.0 * x0) / (2.0 * t1.powi(5));
            self.b[i] = (3.0 * a0 * t1 * t1 + 16.0 * v0 * t1 + 30.0 * x0) / (2.0 * t1.powi(4));
            self.c[i] = -(3.0 * a0 * t1 * t1 + 12.0 * v0 * t1 + 20.0 * x0) / (2.0 * t1 * t1 * t1);
            self.d[i] = a0 / 2.0;
        }
    }

    /// `pose` (the new move's) with what is left of the old one `t` beats after the step.
    pub fn apply(&self, pose: &mut Pose, t: f64) {
        if self.len <= 0.0 || t >= self.len || t < 0.0 {
            return;
        }
        let n = pose.q.len();
        let (t2, t3) = (t * t, t * t * t);
        let (t4, t5) = (t3 * t, t3 * t * t);
        let at = |i: usize| self.a[i] * t5 + self.b[i] * t4 + self.c[i] * t3 + self.d[i] * t2 + self.v[i] * t + self.x[i];
        for b in 0..n {
            let (x, y, z) = (at(b * 3), at(b * 3 + 1), at(b * 3 + 2));
            let ang = (x * x + y * y + z * z).sqrt();
            if ang < 1e-6 {
                continue;
            }
            let s = (ang / 2.0).sin() / ang;
            let (dw, dx, dy, dz) = ((ang / 2.0).cos(), x * s, y * s, z * s);
            let [w, qx, qy, qz] = pose.q[b];
            // d · q
            pose.q[b] = [
                dw * w - dx * qx - dy * qy - dz * qz,
                dw * qx + dx * w + dy * qz - dz * qy,
                dw * qy - dx * qz + dy * w + dz * qx,
                dw * qz + dx * qy - dy * qx + dz * w,
            ];
        }
        for k in 0..3 {
            pose.hips[k] += at(n * 3 + k);
        }
    }
}

/// The turn taking a rotation `b` to `a` (a · b⁻¹, the short way), as an axis times its angle.
fn log_diff(a: &[f64; 4], b: &[f64; 4]) -> [f64; 3] {
    let [aw, ax, ay, az] = *a;
    let (bw, bx, by, bz) = (b[0], -b[1], -b[2], -b[3]);
    let mut w = aw * bw - ax * bx - ay * by - az * bz;
    let mut x = aw * bx + ax * bw + ay * bz - az * by;
    let mut y = aw * by - ax * bz + ay * bw + az * bx;
    let mut z = aw * bz + ax * by - ay * bx + az * bw;
    if w < 0.0 {
        (w, x, y, z) = (-w, -x, -y, -z);
    }
    let sn = (x * x + y * y + z * z).sqrt();
    if sn < 1e-9 {
        return [0.0; 3];
    }
    let ang = 2.0 * sn.atan2(w);
    [x / sn * ang, y / sn * ang, z / sn * ang]
}
