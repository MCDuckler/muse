//! Motion: tweens and springs kept per id in egui's memory, on the real clock, so a 160 ms
//! fade takes 160 ms at 144 Hz and at 50 Hz. Anything still moving asks for another frame;
//! when nothing moves the Desk stops drawing (ui::mod's repaint rule).
//!
//! The rules (plans/wetowl-desk-ui-overhaul.md §2, §5): motion explains a change and stops —
//! no loops, no bounce on information, nothing longer than [GENTLE]. Reduced motion makes the
//! tweens near-instant fades and the springs instant.
use eframe::egui::{Context, Id};

/// Hover in.
pub const QUICK: f32 = 0.09;
/// Presses let go, toggles, popovers.
pub const STANDARD: f32 = 0.16;
/// Pages, overlays, a record loading.
pub const EMPHASIS: f32 = 0.24;
/// Light crossing (the backdrop).
pub const GENTLE: f32 = 0.42;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Ease {
    /// Out-cubic: something arriving.
    Out,
    /// In-out-cubic: something moving from one place to another.
    InOut,
}

impl Ease {
    pub fn at(self, t: f32) -> f32 {
        let t = t.clamp(0.0, 1.0);
        match self {
            Ease::Out => 1.0 - (1.0 - t).powi(3),
            Ease::InOut => {
                if t < 0.5 {
                    4.0 * t * t * t
                } else {
                    1.0 - (-2.0 * t + 2.0).powi(3) / 2.0
                }
            }
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct Tween {
    from: f32,
    to: f32,
    t0: f64,
    dur: f32,
    ease: Ease,
}

#[derive(Clone, Copy, Debug)]
struct Spring {
    x: f32,
    v: f32,
    at: f64,
}

fn now(ctx: &Context) -> f64 {
    ctx.input(|i| i.time)
}

/// Whether the hands asked for less motion (settings).
pub fn reduced(ctx: &Context) -> bool {
    ctx.data(|d| d.get_temp::<bool>(Id::unique("motion.reduced"))).unwrap_or(false)
}

pub fn set_reduced(ctx: &Context, on: bool) {
    ctx.data_mut(|d| d.insert_temp(Id::unique("motion.reduced"), on));
}

/// `id`'s value easing to `target` over `dur` seconds (from wherever it is when the target
/// changes, so a reversed hover turns back smoothly).
pub fn tween(ctx: &Context, id: Id, target: f32, dur: f32, ease: Ease) -> f32 {
    let t = now(ctx);
    let dur = if reduced(ctx) { dur.min(0.06) } else { dur };
    let key = id.with("tween");
    let mut tw = ctx.data(|d| d.get_temp::<Tween>(key)).unwrap_or(Tween { from: target, to: target, t0: t, dur, ease });
    let value = |tw: &Tween| {
        let k = if tw.dur <= 0.0 { 1.0 } else { ((t - tw.t0) as f32 / tw.dur).clamp(0.0, 1.0) };
        tw.from + (tw.to - tw.from) * tw.ease.at(k)
    };
    if (tw.to - target).abs() > f32::EPSILON {
        tw = Tween { from: value(&tw), to: target, t0: t, dur, ease };
    }
    let v = value(&tw);
    ctx.data_mut(|d| d.insert_temp(key, tw));
    if (v - target).abs() > 1e-4 {
        ctx.request_repaint();
    }
    v
}

/// 0..1 for a bool, eased in `dur` (on) and `dur_out` (off).
pub fn tween_bool(ctx: &Context, id: Id, on: bool, dur: f32, dur_out: f32) -> f32 {
    tween(ctx, id, if on { 1.0 } else { 0.0 }, if on { dur } else { dur_out }, Ease::Out)
}

/// `id`'s value following `target` like a critically damped spring that settles in about
/// `settle` seconds, no overshoot: faders and knobs a controller moves, highlights that glide.
pub fn spring(ctx: &Context, id: Id, target: f32, settle: f32) -> f32 {
    let t = now(ctx);
    let key = id.with("spring");
    let Some(mut s) = ctx.data(|d| d.get_temp::<Spring>(key)) else {
        ctx.data_mut(|d| d.insert_temp(key, Spring { x: target, v: 0.0, at: t }));
        return target;
    };
    if reduced(ctx) || settle <= 0.0 {
        s = Spring { x: target, v: 0.0, at: t };
    } else {
        // ω for ~98 % settled in `settle` (critically damped: e^(−ωt)(1+ωt) ≈ 0.02 at ωt ≈ 5.8)
        let w = 5.8 / settle;
        let mut dt = ((t - s.at) as f32).clamp(0.0, 0.05);
        s.at = t;
        while dt > 0.0 {
            let h = dt.min(1.0 / 240.0);
            let a = w * w * (target - s.x) - 2.0 * w * s.v;
            s.v += a * h;
            s.x += s.v * h;
            dt -= h;
        }
        let scale = target.abs().max(1.0);
        if (s.x - target).abs() < 1e-4 * scale && s.v.abs() < 1e-3 * scale {
            s.x = target;
            s.v = 0.0;
        } else {
            ctx.request_repaint();
        }
    }
    ctx.data_mut(|d| d.insert_temp(key, s));
    s.x
}

/// 0..1 over `dur` from the first frame `id` is asked about, eased out: a thing arriving
/// (a record loaded, a toast). Key it by what arrives (the record's id) to replay it.
pub fn appear(ctx: &Context, id: Id, dur: f32) -> f32 {
    let dur = if reduced(ctx) { dur.min(0.06) } else { dur };
    let k = (since(ctx, id) / dur.max(1e-3)).clamp(0.0, 1.0);
    if k < 1.0 {
        ctx.request_repaint();
    }
    Ease::Out.at(k)
}

/// Seconds since the first frame `id` was asked about (staggered arrivals build on it; it
/// asks for no frames itself).
pub fn since(ctx: &Context, id: Id) -> f32 {
    let t = now(ctx);
    let t0 = ctx.data_mut(|d| *d.get_temp_mut_or_insert_with(id.with("appear"), || t));
    (t - t0) as f32
}

/// A one-shot flash: 1 when `fired` turns true (a new count), decaying to 0 over `dur`.
pub fn flash(ctx: &Context, id: Id, count: u64, dur: f32) -> f32 {
    let t = now(ctx);
    let key = id.with("flash");
    let (seen, at) = ctx.data(|d| d.get_temp::<(u64, f64)>(key)).unwrap_or((count, f64::NEG_INFINITY));
    let at = if count != seen { t } else { at };
    ctx.data_mut(|d| d.insert_temp(key, (count, at)));
    let k = 1.0 - ((t - at) as f32 / dur.max(1e-3)).clamp(0.0, 1.0);
    if k > 0.0 {
        ctx.request_repaint();
    }
    k * k
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(ctx: &Context, t: f64, f: impl FnOnce(&Context)) {
        let input = eframe::egui::RawInput { time: Some(t), ..Default::default() };
        let mut f = Some(f);
        let _ = ctx.run_ui(input, |ui| {
            if let Some(f) = f.take() {
                f(ui.ctx());
            }
        });
    }

    #[test]
    fn a_tween_takes_its_time_and_lands() {
        let ctx = Context::default();
        let id = Id::unique("x");
        let mut v = 0.0;
        frame(&ctx, 0.0, |c| v = tween(c, id, 0.0, 0.16, Ease::Out));
        assert_eq!(v, 0.0);
        frame(&ctx, 0.01, |c| v = tween(c, id, 1.0, 0.16, Ease::Out));
        assert!(v < 0.05, "starts where it was: {v}");
        frame(&ctx, 0.09, |c| v = tween(c, id, 1.0, 0.16, Ease::Out));
        assert!((0.5..1.0).contains(&v), "half way and more (out-cubic): {v}");
        frame(&ctx, 0.2, |c| v = tween(c, id, 1.0, 0.16, Ease::Out));
        assert_eq!(v, 1.0);
    }

    #[test]
    fn a_spring_settles_without_overshoot() {
        let ctx = Context::default();
        let id = Id::unique("s");
        let mut v = 0.0;
        frame(&ctx, 0.0, |c| v = spring(c, id, 0.0, 0.2));
        let mut most: f32 = 0.0;
        for i in 1..=40 {
            frame(&ctx, i as f64 / 120.0, |c| v = spring(c, id, 10.0, 0.2));
            most = most.max(v);
        }
        assert!(most <= 10.0 + 1e-3, "no overshoot: {most}");
        assert!((v - 10.0).abs() < 0.3, "settled in about its time: {v}");
    }

    #[test]
    fn eases_end_where_they_should() {
        for e in [Ease::Out, Ease::InOut] {
            assert_eq!(e.at(0.0), 0.0);
            assert!((e.at(1.0) - 1.0).abs() < 1e-6);
        }
    }
}
