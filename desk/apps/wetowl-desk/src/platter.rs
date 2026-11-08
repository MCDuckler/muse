//! The platter: the record on a deck, turning — v1's spinning disc (console_deck.dart,
//! record_stage.dart, booth_clock.dart) made over for the Desk.
//!
//! Two pictures make it. The vinyl — the grooves, the bands between songs, the dead wax,
//! the edge, and the two lamps' light on it — holds still: its rings are round, so a turn
//! would not change them, and a picture that is not turned cannot shimmer. Over it the
//! label (the record's cover, or a plain pressing in its sleeve's inks) and a few specks of
//! dust turn, at 33⅓ a minute times the deck's rate, speeding up and running down with a
//! platter's weight. Round it, the record's progress (the CDJ's ring): what was played in
//! the deck's colour, the pads as ticks, the loop. The hand on it is the jog wheel.
use eframe::egui::{self, Align2, Color32, ColorImage, CornerRadius, Mesh, Painter, Pos2, Rect, Response, Sense, Shape, Stroke, TextureHandle, TextureOptions, Ui, emath::Rot2, pos2, vec2};
use wo_deskcore::{Cover, DeckView, Desk, theme};

use crate::paint::{col, label_sized, pad_colour};
use crate::ui::kit::alpha_of;
use crate::ui::motion::{self, Ease};
use crate::ui::tokens::{self as t, mix};

/// One turn of a record at 33⅓: 1.8 s (v1's BoothClock).
const TURN: f64 = 1.8;
/// A platter's weight: up to speed, and run down (v1: 0.33 s, 0.5 s).
const UP: f64 = 0.33;
const DOWN: f64 = 0.5;
/// Jog ticks a turn of the hand: a turn of the record moves it as far as a turn of vinyl.
const TICKS_A_TURN: f64 = 90.0;

/// A deck's platter as it turns, and its pictures.
#[derive(Default)]
pub(crate) struct Spin {
    /// Turns, and turns a second.
    angle: f64,
    speed: f64,
    at: Option<f64>,
    /// The hand's angle on it while it drags.
    hand: Option<f32>,
    /// The still vinyl and the turning label, with what they were made for.
    vinyl: Option<((i64, usize, u16), TextureHandle)>,
    top: Option<((i64, usize, bool, u16), TextureHandle)>,
}

pub(crate) type Platters = [Spin; 2];

/// A small seeded noise.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((self.0 >> 40) as f32) / (1u64 << 24) as f32
    }
}

/// The vinyl `n` px square, still: grooves with a slow drift of shade (loud passages cut
/// wider), 3–6 songs' gaps, the dead wax, the edge, and the light of two lamps on the
/// grooves — the pair of wedges every record under a lamp has (v1's RecordLight), each with
/// its twin across the record.
fn vinyl(n: usize, seed: i64, label: f32) -> ColorImage {
    let mut rng = Rng(seed as u64 ^ 0x9E37_79B9_7F4A_7C15);
    let r = n as f32 / 2.0;
    let outer = 0.955;
    let inner = (label + 0.085).max(0.36);
    let songs = 3 + (rng.next() * 4.0) as usize;
    let mut gaps: Vec<f32> = (0..songs - 1).map(|_| inner + (outer - inner) * (0.1 + 0.8 * rng.next())).collect();
    gaps.sort_by(f32::total_cmp);
    // the drift of shade across the radius, a random walk
    let steps = n.max(8);
    let mut drift = Vec::with_capacity(steps);
    let mut d = 0.0f32;
    for _ in 0..steps {
        d = (d + (rng.next() - 0.5) * 0.5).clamp(-1.0, 1.0);
        drift.push(d);
    }
    // lamps: (angle, half width, strength), radians, screen y down
    let lamps = [(-2.20f32, 0.72f32, 0.30f32), (-2.20 + std::f32::consts::PI, 0.72, 0.17), (-0.82, 0.5, 0.14), (-0.82 + std::f32::consts::PI, 0.5, 0.08)];
    let mut px = vec![0u8; n * n * 4];
    for y in 0..n {
        for x in 0..n {
            let (dx, dy) = (x as f32 + 0.5 - r, y as f32 + 0.5 - r);
            let dist = (dx * dx + dy * dy).sqrt();
            let k = dist / r;
            let edge = (r - dist + 0.5).clamp(0.0, 1.0);
            if edge <= 0.0 {
                continue;
            }
            let ring = |at: f32, w: f32| (1.0 - ((k - at).abs() * r / w)).clamp(0.0, 1.0);
            // the lamps on the grooves (and a little on the smooth wax)
            let a = dy.atan2(dx);
            let mut light = 0.0;
            for (at, half, s) in lamps {
                let mut da = (a - at).abs() % std::f32::consts::TAU;
                if da > std::f32::consts::PI {
                    da = std::f32::consts::TAU - da;
                }
                if da < half {
                    light += s * (0.5 + 0.5 * (std::f32::consts::PI * da / half).cos());
                }
            }
            let mut v: f32;
            if k > outer {
                // the lead-in, smooth, and the moulded edge
                v = 24.0 + 46.0 * ring(0.993, 1.4);
                light *= 0.5;
            } else if k > inner {
                let i = ((k * steps as f32) as usize).min(steps - 1);
                v = 32.0 + 8.0 * drift[i] + 4.0 * (((dist * 1.7).sin() * 0.5 + 0.5) - 0.5);
                for g in &gaps {
                    v = v * (1.0 - 0.8 * ring(*g, 1.2)) + 58.0 * ring(*g + 1.6 / r, 0.8);
                }
                v += 22.0 * ring(outer, 0.9) + 20.0 * ring(inner, 0.9);
            } else {
                // the dead wax round the label, the run-out groove in it
                v = 20.0 + 24.0 * ring((inner + label) / 2.0 + 0.01, 0.9);
                light *= 0.35;
            }
            let lit = v + 255.0 * light;
            let c = lit.clamp(0.0, 255.0) as u8;
            let o = (y * n + x) * 4;
            px[o] = c;
            px[o + 1] = c;
            px[o + 2] = (c as u16 + 2).min(255) as u8;
            px[o + 3] = (edge * 255.0) as u8;
        }
    }
    ColorImage::from_rgba_unmultiplied([n, n], &px)
}

/// What turns, `n` px square: the label — the cover tinted a quarter to its colour (the
/// server's way), or a plain pressing in the sleeve's two inks — its paper edge, the
/// press's ring, and a few specks of dust out on the vinyl; clear elsewhere.
fn turning(n: usize, seed: i64, cover: Option<&Cover>, colour: [u8; 3], label: f32) -> ColorImage {
    let mut rng = Rng(seed as u64 ^ 0xD1B5_4A32_D192_ED03);
    let r = n as f32 / 2.0;
    let lr = r * label;
    let ink = [colour[0].saturating_add(90), colour[1].saturating_add(80), colour[2].saturating_add(70)];
    let mark = rng.next() * std::f32::consts::TAU;
    let mut px = vec![0u8; n * n * 4];
    let sample = |c: &Cover, u: f32, v: f32| -> [f32; 3] {
        let s = c.side as usize;
        let (x, y) = (((u * s as f32) as usize).min(s - 1), ((v * s as f32) as usize).min(s - 1));
        let o = (y * s + x) * 4;
        [c.rgba[o] as f32, c.rgba[o + 1] as f32, c.rgba[o + 2] as f32]
    };
    for y in 0..n {
        for x in 0..n {
            let (dx, dy) = (x as f32 + 0.5 - r, y as f32 + 0.5 - r);
            let dist = (dx * dx + dy * dy).sqrt();
            let edge = (lr - dist + 0.5).clamp(0.0, 1.0);
            if edge <= 0.0 {
                continue;
            }
            let mut c = match cover {
                Some(cv) => {
                    let s = sample(cv, (dx / lr + 1.0) / 2.0, (dy / lr + 1.0) / 2.0);
                    [0, 1, 2].map(|k| s[k] * 0.75 + colour[k] as f32 * 0.25)
                }
                None => {
                    // two inks: the ground, a ring of the ink, a band of it off the middle
                    // (so the turn shows)
                    let k = dist / lr;
                    let a = dy.atan2(dx);
                    let mut da = (a - mark).abs() % std::f32::consts::TAU;
                    if da > std::f32::consts::PI {
                        da = std::f32::consts::TAU - da;
                    }
                    let band = (0.52..0.7).contains(&k) && da < 0.9;
                    let ring = (0.86..0.9).contains(&k);
                    if band || ring { ink.map(|v| v as f32) } else { colour.map(|v| v as f32) }
                }
            };
            // the paper's edge, and the press's ring a third of the way out
            let k = dist / lr;
            let dark = (1.0 - ((k - 1.0).abs() * lr / 2.0)).clamp(0.0, 1.0) * 0.45 + (1.0 - ((k - 0.42).abs() * lr / 1.2)).clamp(0.0, 1.0) * 0.25;
            let shine = (1.0 - ((k - 0.42 - 1.6 / lr).abs() * lr / 0.8)).clamp(0.0, 1.0) * 0.13;
            for v in &mut c {
                *v = *v * (1.0 - dark) + 255.0 * shine;
            }
            let o = (y * n + x) * 4;
            px[o] = c[0].clamp(0.0, 255.0) as u8;
            px[o + 1] = c[1].clamp(0.0, 255.0) as u8;
            px[o + 2] = c[2].clamp(0.0, 255.0) as u8;
            px[o + 3] = (edge * 255.0) as u8;
        }
    }
    // dust on the grooves: a few specks, and one hairline
    for _ in 0..7 {
        let (a, k) = (rng.next() * std::f32::consts::TAU, label + 0.04 + rng.next() * (0.9 - label).max(0.02));
        let (x, y) = ((r + a.cos() * k * r) as usize, (r + a.sin() * k * r) as usize);
        if x < n && y < n {
            let o = (y * n + x) * 4;
            px[o..o + 4].copy_from_slice(&[150, 150, 156, 150]);
        }
    }
    let (a0, k0) = (rng.next() * std::f32::consts::TAU, 0.55 + rng.next() * 0.3);
    for i in 0..(n / 6) {
        let a = a0 + i as f32 * 0.6 / (n / 6) as f32;
        let (x, y) = ((r + a.cos() * k0 * r) as usize, (r + a.sin() * k0 * r) as usize);
        if x < n && y < n {
            let o = (y * n + x) * 4;
            px[o..o + 4].copy_from_slice(&[200, 200, 206, 34]);
        }
    }
    ColorImage::from_rgba_unmultiplied([n, n], &px)
}

/// An arc of the ring round the platter, from `a0` to `a1` turns (0 at the top, clockwise).
fn arc(p: &Painter, c: Pos2, r: f32, a0: f32, a1: f32, w: f32, color: Color32) {
    if a1 - a0 < 1e-4 {
        return;
    }
    let n = ((a1 - a0) * 96.0).ceil().max(2.0) as usize;
    let pts: Vec<Pos2> = (0..=n)
        .map(|i| {
            let a = (a0 + (a1 - a0) * i as f32 / n as f32) * std::f32::consts::TAU - std::f32::consts::FRAC_PI_2;
            pos2(c.x + r * a.cos(), c.y + r * a.sin())
        })
        .collect();
    p.add(Shape::line(pts, Stroke::new(w, color)));
}

/// A soft ring of `color` round `c` from radius `r0` (full) to `r1` (gone): the glow.
fn glow(p: &Painter, c: Pos2, r0: f32, r1: f32, color: Color32) {
    let n = 72;
    let mut m = Mesh::default();
    let clear = Color32::from_rgba_premultiplied(0, 0, 0, 0);
    for i in 0..=n {
        let a = i as f32 / n as f32 * std::f32::consts::TAU;
        let (s, co) = a.sin_cos();
        m.colored_vertex(pos2(c.x + r0 * co, c.y + r0 * s), color);
        m.colored_vertex(pos2(c.x + r1 * co, c.y + r1 * s), clear);
        if i > 0 {
            let k = 2 * (i - 1) as u32;
            m.add_triangle(k, k + 1, k + 2);
            m.add_triangle(k + 1, k + 3, k + 2);
        }
    }
    p.add(Shape::mesh(m));
}

/// A dashed circle (an empty deck's place for a record).
fn dashed(p: &Painter, c: Pos2, r: f32, color: Color32) {
    let n = 48;
    for i in 0..n {
        let a0 = i as f32 / n as f32 * std::f32::consts::TAU;
        let a1 = a0 + 0.55 / n as f32 * std::f32::consts::TAU;
        p.line_segment([pos2(c.x + r * a0.cos(), c.y + r * a0.sin()), pos2(c.x + r * a1.cos(), c.y + r * a1.sin())], Stroke::new(1.5, color));
    }
}

impl crate::App {
    /// Deck `d`'s platter in the square `r` (the ring round it inside `r` too); `small`: a
    /// header's (no ticks, a thinner ring). Its response (a drag is the jog wheel).
    pub(crate) fn platter(&mut self, desk: &mut Desk, ui: &mut Ui, p: &Painter, r: Rect, v: &DeckView, d: usize, small: bool) -> Response {
        let ctx = ui.ctx().clone();
        let ppp = ctx.pixels_per_point();
        let c = r.center();
        let ring_w = if small { 2.0 } else { 3.0 };
        let ring_r = r.width() / 2.0 - ring_w / 2.0 - 1.0;
        let rad = ring_r - ring_w / 2.0 - if small { 3.0 } else { 5.0 };
        let id = ui.scope_id().with(("platter", d));
        let resp = ui.interact(r, id, Sense::click_and_drag());
        let empty = !v.record.playable();
        // the turn: v1's speed and weight
        let now = ctx.input(|i| i.time);
        let spin = &mut self.platters[d];
        let dt = spin.at.map_or(0.0, |a| (now - a).clamp(0.0, 0.1));
        spin.at = Some(now);
        let target = if v.playing && !empty { v.rate.max(0.0) / TURN } else { 0.0 };
        let tau = if target > spin.speed { UP } else { DOWN };
        spin.speed += (target - spin.speed) * (1.0 - (-dt / tau).exp());
        if (target - spin.speed).abs() < 1e-4 {
            spin.speed = target;
        }
        spin.angle = (spin.angle + spin.speed * dt).rem_euclid(1024.0);
        if spin.speed.abs() > 1e-4 {
            ctx.request_repaint();
        }
        // the hand on it: the jog wheel (parked: the record moves; playing: it bends)
        if resp.dragged() && !empty {
            if let Some(pos) = resp.interact_pointer_pos() {
                let a = (pos.y - c.y).atan2(pos.x - c.x);
                if let Some(was) = spin.hand {
                    let mut da = a - was;
                    if da > std::f32::consts::PI {
                        da -= std::f32::consts::TAU;
                    } else if da < -std::f32::consts::PI {
                        da += std::f32::consts::TAU;
                    }
                    let turns = da as f64 / std::f64::consts::TAU;
                    spin.angle += turns;
                    let shift = ui.input(|i| i.modifiers.shift);
                    desk.jog(d, turns * TICKS_A_TURN, false, shift);
                }
                spin.hand = Some(a);
            }
        } else {
            spin.hand = None;
        }
        if resp.hovered() && !empty {
            let dy = ui.input(|i| i.smooth_scroll_delta.y);
            if dy.abs() > 0.1 {
                desk.jog(d, dy as f64 / 12.0, false, false);
                self.platters[d].angle += dy as f64 / 12.0 / TICKS_A_TURN;
            }
        }
        let spin = &mut self.platters[d];
        // its pictures, made when the record or the size changes
        let n = ((rad * 2.0 * ppp).round() as usize).clamp(48, 720);
        let rid = v.record.id;
        let colour = v.record.cover_rgb.map(|c| [(c >> 16) as u8, (c >> 8) as u8, c as u8]).unwrap_or_else(|| {
            let s = theme::sleeve(rid);
            [s[0], s[1], s[2]]
        });
        let label = self.prefs.disc_label.clamp(0.18, 0.92);
        let lk = (label * 100.0).round() as u16;
        if !empty {
            if spin.vinyl.as_ref().is_none_or(|(k, _)| *k != (rid, n, lk)) {
                let img = vinyl(n, rid, label);
                match &mut spin.vinyl {
                    Some((k, tex)) => {
                        tex.set(img, TextureOptions::LINEAR);
                        *k = (rid, n, lk);
                    }
                    None => spin.vinyl = Some(((rid, n, lk), ctx.load_texture(format!("vinyl {d}"), img, TextureOptions::LINEAR))),
                }
            }
            let cover = desk.cover(&v.record);
            let key = (rid, n, cover.is_some(), lk);
            if spin.top.as_ref().is_none_or(|(k, _)| *k != key) {
                let img = turning(n, rid, cover.as_deref(), colour, label);
                let opts = TextureOptions { mipmap_mode: Some(egui::TextureFilter::Linear), ..TextureOptions::LINEAR };
                match &mut spin.top {
                    Some((k, tex)) => {
                        tex.set(img, opts);
                        *k = key;
                    }
                    None => spin.top = Some((key, ctx.load_texture(format!("label {d}"), img, opts))),
                }
            }
        }
        // the deck's colour round it while it turns
        let turning_k = motion::tween_bool(&ctx, id.with("lit"), v.playing && !empty, 0.3, 0.5);
        if turning_k > 0.01 && !small {
            glow(p, c, ring_r, ring_r + 12.0, alpha_of(t::deck(d), 0.16 * turning_k));
        }
        // the ring: the record's progress, the loop, the pads
        let len = v.length.max(1.0);
        let k_of = |t: f64| (t / len).clamp(0.0, 1.0) as f32;
        arc(p, c, ring_r, 0.0, 1.0, ring_w, col(theme::LINE));
        if !empty {
            let at = k_of(v.heard);
            let warm = v.length > 0.0 && v.length - v.heard < 30.0;
            let played = mix(alpha_of(t::deck(d), 0.55), t::deck(d), turning_k);
            arc(p, c, ring_r, 0.0, at, ring_w, played);
            if warm {
                arc(p, c, ring_r, at, 1.0, ring_w, alpha_of(t::warm(), 0.55));
            }
            if v.decoded < 1.0 {
                arc(p, c, ring_r, 0.0, v.decoded.clamp(0.0, 1.0), 1.0, alpha_of(t::tint(d), 0.8));
            }
            if let Some((a, b)) = v.looped {
                arc(p, c, ring_r, k_of(a), k_of(b).max(k_of(a) + 0.004), ring_w + 2.0, t::tint(d));
            }
            if !small {
                for pad in v.pads.iter().flatten() {
                    let a = k_of(pad.at) * std::f32::consts::TAU - std::f32::consts::FRAC_PI_2;
                    let (s, co) = a.sin_cos();
                    p.line_segment([pos2(c.x + (ring_r - 4.0) * co, c.y + (ring_r - 4.0) * s), pos2(c.x + (ring_r + 4.0) * co, c.y + (ring_r + 4.0) * s)], Stroke::new(2.0, col(pad_colour(pad.auto))));
                }
            }
            // where it is: a bright tick on the ring
            let a = at * std::f32::consts::TAU - std::f32::consts::FRAC_PI_2;
            let (s, co) = a.sin_cos();
            p.line_segment([pos2(c.x + (ring_r - ring_w) * co, c.y + (ring_r - ring_w) * s), pos2(c.x + (ring_r + ring_w) * co, c.y + (ring_r + ring_w) * s)], Stroke::new(2.0, Color32::WHITE));
        }
        if empty {
            // a place for a record: lit while one is dragged over the deck
            let dragging = egui::DragAndDrop::has_payload_of_type::<wo_deskcore::Record>(&ctx);
            let lit = motion::tween_bool(&ctx, id.with("drop"), dragging, motion::STANDARD, motion::STANDARD);
            dashed(p, c, rad * 0.92, alpha_of(t::deck(d), 0.3 + 0.5 * lit));
            if !small {
                label_sized(p, c - vec2(0.0, 8.0), Align2::CENTER_CENTER, "No record", 11.0, t::label());
                crate::ui::kit::hint(p, c + vec2(0.0, 10.0), Align2::CENTER_CENTER, "drag one here");
            }
            return resp;
        }
        // the record: dropped in when it is put on (a fade, a little growth, a twist settling)
        let k = Ease::Out.at(motion::appear(&ctx, id.with(("in", rid)), 0.32));
        let rr = rad * (0.94 + 0.06 * k);
        let disc = Rect::from_center_size(c, vec2(rr * 2.0, rr * 2.0));
        let tint = Color32::from_white_alpha((255.0 * k) as u8);
        p.add(egui::Shadow { offset: [0, 3], blur: 14, spread: 0, color: Color32::from_black_alpha((110.0 * k) as u8) }.as_shape(disc, CornerRadius::same(255)));
        let uv = Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0));
        if let Some((_, tex)) = &spin.vinyl {
            p.image(tex.id(), disc, uv, tint);
        }
        if let Some((_, tex)) = &spin.top {
            let twist = -(1.0 - k) * 0.08;
            let mut m = Mesh::with_texture(tex.id());
            m.add_rect_with_uv(disc, uv, tint);
            m.rotate(Rot2::from_angle(((spin.angle + twist as f64).fract() as f32) * std::f32::consts::TAU), c);
            p.add(Shape::mesh(m));
        }
        // the spindle: chrome, the one bright thing on it
        let hole = rr * 0.035;
        p.circle_filled(c, hole * 1.3, Color32::from_rgb(12, 12, 14));
        p.circle_filled(c, hole, Color32::from_rgb(168, 170, 176));
        p.circle_filled(c + vec2(-hole * 0.25, -hole * 0.25), hole * 0.45, Color32::from_rgb(232, 234, 238));
        let h = motion::tween_bool(&ctx, id.with("h"), resp.hovered() || resp.dragged(), motion::QUICK, motion::STANDARD);
        if h > 0.01 {
            p.circle_stroke(c, rr + 0.5, Stroke::new(1.0, Color32::from_white_alpha((40.0 * h) as u8)));
        }
        resp.on_hover_cursor(if self.platters[d].hand.is_some() { egui::CursorIcon::Grabbing } else { egui::CursorIcon::Grab })
            .on_hover_text("The jog wheel: a drag bends the record while it plays and moves it while it is parked (shift: further); scroll for a little")
    }
}

/// A rounded tab with a word, laid over the platter's foot (what is coming to the deck).
pub(crate) fn coming_tab(p: &Painter, c: Pos2, words: &str, ink: Color32) {
    let g = p.layout_no_wrap(words.to_owned(), egui::FontId::new(10.5, crate::paint::family("label")), ink);
    let r = Rect::from_center_size(c, vec2(g.size().x + 16.0, 20.0));
    crate::ui::kit::glass_tab(p, r);
    p.galley(pos2(r.center().x - g.size().x / 2.0, r.center().y - g.size().y / 2.0), g, ink);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The vinyl is round and clear outside; the label is clear outside its share.
    #[test]
    fn the_pictures_are_round() {
        let v = vinyl(64, 7, 0.31);
        assert_eq!(v.pixels[0].a(), 0, "a corner is clear");
        assert!(v.pixels[32 * 64 + 32].a() > 200, "the middle is vinyl");
        let l = turning(64, 7, None, [40, 50, 60], 0.31);
        assert_eq!(l.pixels[32 * 64 + 2].a(), 0, "the grooves are clear in the turning picture");
        assert!(l.pixels[32 * 64 + 32].a() > 200, "the label is there");
    }
}
