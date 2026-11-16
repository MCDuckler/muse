//! A line's distance field (v1: show_type3d.dart's TypeField): the line set in its face (one
//! row, a little letter-spaced, 1.05 high), drawn a few times larger than the field as a
//! coverage mask, Felzenszwalb's distances each way, averaged down, softened, and packed in
//! sixteen bits (red the high byte, green the low) for type3d.frag's uSdf.
use ab_glyph::{Font, FontRef, ScaleFont};
use wo_show::type3d::TypeFont;

/// The type's height in pixels as it is set, and how far the field reaches.
pub const FONT_PX: f64 = 150.0;
pub const RANGE_PX: f64 = 20.0;

/// The face's file (app/assets/fonts), built in.
pub fn font_bytes(f: TypeFont) -> &'static [u8] {
    macro_rules! font {
        ($f:literal) => {
            include_bytes!(concat!("../../../../app/assets/fonts/", $f))
        };
    }
    match f {
        TypeFont::Bebas => font!("BebasNeue-Regular.ttf"),
        TypeFont::Orbitron => font!("Orbitron.ttf"),
        TypeFont::Bungee => font!("Bungee-Regular.ttf"),
        TypeFont::Pixel => font!("PressStart2P-Regular.ttf"),
        TypeFont::Monoton => font!("Monoton-Regular.ttf"),
        TypeFont::Rubik => font!("RubikMonoOne-Regular.ttf"),
        TypeFont::Righteous => font!("Righteous-Regular.ttf"),
        TypeFont::Syne => font!("Syne.ttf"),
        TypeFont::Archivo => font!("Archivo.ttf"),
        TypeFont::Serif => font!("InstrumentSerif-Regular.ttf"),
        TypeFont::Marker => font!("PermanentMarker.ttf"),
        TypeFont::Courier => font!("CourierPrime-Regular.ttf"),
    }
}

/// A line made: its field (RGBA, `w`×`h`), and what it measures in the object's units (a
/// line of type is 1 high): half its width and height, the field's reach.
#[derive(Clone, Debug)]
pub struct TypeField {
    pub text: String,
    pub font: TypeFont,
    pub w: u32,
    pub h: u32,
    pub rgba: Vec<u8>,
    pub half_x: f64,
    pub half_y: f64,
    pub range: f64,
}

/// A line set: each glyph and where its pen stands (the baseline's), the row's width and
/// height.
struct Set {
    glyphs: Vec<(ab_glyph::GlyphId, f64)>,
    width: f64,
    height: f64,
    baseline: f64,
}

/// The em size `px` as ab_glyph's scale (its scale is the ascent-to-descent height).
fn scale_for(font: &FontRef<'_>, px: f64) -> ab_glyph::PxScale {
    let em = font.units_per_em().unwrap_or(1000.0) as f64;
    ab_glyph::PxScale::from((px * font.height_unscaled() as f64 / em) as f32)
}

/// `text` in one row at `px`: as Flutter's TextPainter sets it with height 1.05 and a letter
/// spacing of 0.03 em after every letter (the extra height shared out over and under the face
/// as its own ascent and descent are).
fn set(font: &FontRef<'_>, text: &str, px: f64) -> Set {
    let sf = font.as_scaled(scale_for(font, px));
    let mut glyphs = vec![];
    let mut x = 0.0;
    let mut prev = None;
    for c in text.chars() {
        let id = sf.glyph_id(c);
        if let Some(p) = prev {
            x += sf.kern(p, id) as f64;
        }
        glyphs.push((id, x));
        x += sf.h_advance(id) as f64 + px * 0.03;
        prev = Some(id);
    }
    let (asc, desc) = (sf.ascent() as f64, -sf.descent() as f64);
    let height = 1.05 * px;
    let baseline = if asc + desc > 0.0 { height * asc / (asc + desc) } else { height * 0.8 };
    Set { glyphs, width: x, height, baseline }
}

impl TypeField {
    pub fn key(&self) -> String {
        format!("{}|{}", self.font.name(), self.text)
    }

    /// `text` in `font` as a distance field.
    pub fn bake(text: &str, font: TypeFont) -> TypeField {
        let face = FontRef::try_from_slice(font_bytes(font)).expect("a built-in face");
        let mut size = FONT_PX;
        let mut tp = set(&face, text, size);
        // a long line set smaller, the field no wider than a texture should be
        let max_w = 2000.0;
        let pad = RANGE_PX + 4.0;
        if tp.width > max_w - 2.0 * pad {
            size = size * (max_w - 2.0 * pad) / tp.width;
            tp = set(&face, text, size);
        }
        let w = (tp.width + 2.0 * pad).ceil().max(1.0) as usize;
        let h = (tp.height + 2.0 * pad).ceil().max(1.0) as usize;
        // set larger than the field and measured there, then averaged down: a field from a
        // mask a pixel sharp is a staircase along every slant
        let ss = if w * h * 9 <= 4_000_000 { 3 } else { 2 };
        let (ws, hs) = (w * ss, h * ss);
        let mut alpha = vec![0u8; ws * hs];
        let scale = scale_for(&face, size * ss as f64);
        let k = ss as f64;
        for (id, x) in &tp.glyphs {
            let g = id.with_scale_and_position(scale, ab_glyph::point(((pad + x) * k) as f32, ((pad + tp.baseline) * k) as f32));
            let Some(o) = face.outline_glyph(g) else { continue };
            let b = o.px_bounds();
            o.draw(|gx, gy, c| {
                let (px, py) = (b.min.x as i64 + gx as i64, b.min.y as i64 + gy as i64);
                if px < 0 || py < 0 || px >= ws as i64 || py >= hs as i64 {
                    return;
                }
                let i = py as usize * ws + px as usize;
                alpha[i] = (alpha[i] as f32 + c * 255.0).round().min(255.0) as u8;
            });
        }
        let line_h = tp.height;
        let range = RANGE_PX * size / FONT_PX;
        let rgba = field(&alpha, w, h, ss, range);
        TypeField { text: text.into(), font, w: w as u32, h: h as u32, rgba, half_x: w as f64 / 2.0 / line_h, half_y: h as f64 / 2.0 / line_h, range: range / line_h }
    }
}

/// Felzenszwalb's squared distance transform along one row of `f`, into `d`.
fn pass(f: &[f64], d: &mut [f64], v: &mut [usize], z: &mut [f64]) {
    const INF: f64 = 1e20;
    let len = f.len();
    let sq = |q: usize| (q * q) as f64;
    let mut k = 0usize;
    v[0] = 0;
    z[0] = -INF;
    z[1] = INF;
    for q in 1..len {
        let mut s = ((f[q] + sq(q)) - (f[v[k]] + sq(v[k]))) / (2.0 * q as f64 - 2.0 * v[k] as f64);
        while s <= z[k] {
            k -= 1;
            s = ((f[q] + sq(q)) - (f[v[k]] + sq(v[k]))) / (2.0 * q as f64 - 2.0 * v[k] as f64);
        }
        k += 1;
        v[k] = q;
        z[k] = s;
        z[k + 1] = INF;
    }
    k = 0;
    for (q, out) in d.iter_mut().enumerate().take(len) {
        while z[k + 1] < q as f64 {
            k += 1;
        }
        let dq = q as f64 - v[k] as f64;
        *out = dq * dq + f[v[k]];
    }
}

/// The squared distance of every pixel to the nearest one inside (`inside`) or outside.
fn squared(alpha: &[u8], w: usize, h: usize, inside: bool) -> Vec<f64> {
    let mut g: Vec<f64> = alpha.iter().map(|a| if (*a >= 128) == inside { 0.0 } else { 1e20 }).collect();
    let n = w.max(h);
    let (mut f, mut d, mut z, mut v) = (vec![0.0; n], vec![0.0; n], vec![0.0; n + 1], vec![0usize; n]);
    for x in 0..w {
        for y in 0..h {
            f[y] = g[y * w + x];
        }
        pass(&f[..h], &mut d[..h], &mut v, &mut z);
        for y in 0..h {
            g[y * w + x] = d[y];
        }
    }
    for y in 0..h {
        f[..w].copy_from_slice(&g[y * w..y * w + w]);
        pass(&f[..w], &mut d[..w], &mut v, &mut z);
        g[y * w..y * w + w].copy_from_slice(&d[..w]);
    }
    g
}

/// The signed distance (out positive) of every pixel to the type's edge, a pixel `range`
/// every 0.5, in RGBA: on the mask `ss` times larger (the edge's pixels placed by their
/// coverage), averaged down to `w0`×`h0`, softened twice each way.
fn field(alpha: &[u8], w0: usize, h0: usize, ss: usize, range: f64) -> Vec<u8> {
    let (w, h) = (w0 * ss, h0 * ss);
    let (out, inn) = (squared(alpha, w, h, true), squared(alpha, w, h, false));
    let mut sdf = vec![0.0; w0 * h0];
    for y0 in 0..h0 {
        for x0 in 0..w0 {
            let mut sum = 0.0;
            for dy in 0..ss {
                for dx in 0..ss {
                    let i = (y0 * ss + dy) * w + x0 * ss + dx;
                    let mut sd = out[i].sqrt() - inn[i].sqrt();
                    let a = alpha[i];
                    if a > 0 && a < 255 {
                        sd += 0.5 - a as f64 / 255.0;
                    }
                    sum += sd;
                }
            }
            sdf[y0 * w0 + x0] = sum / (ss * ss) as f64 / ss as f64;
        }
    }
    // softened a little, twice each way: a distance to pixels ripples along a slant, and a
    // normal taken off it ripples the more
    const K: [f64; 5] = [1.0, 4.0, 6.0, 4.0, 1.0];
    for _ in 0..2 {
        for across in [true, false] {
            let mut next = vec![0.0; w0 * h0];
            for y in 0..h0 {
                for x in 0..w0 {
                    let mut acc = 0.0;
                    for k in -2i64..=2 {
                        let (xx, yy) = if across { ((x as i64 + k).clamp(0, w0 as i64 - 1) as usize, y) } else { (x, (y as i64 + k).clamp(0, h0 as i64 - 1) as usize) };
                        acc += sdf[yy * w0 + xx] * K[(k + 2) as usize];
                    }
                    next[y * w0 + x] = acc / 16.0;
                }
            }
            sdf = next;
        }
    }
    let mut rgba = vec![0u8; w0 * h0 * 4];
    for (i, s) in sdf.iter().enumerate() {
        let v = ((0.5 + s / (2.0 * range)).clamp(0.0, 1.0) * 65535.0).round() as u32;
        rgba[i * 4] = (v >> 8) as u8;
        rgba[i * 4 + 1] = (v & 255) as u8;
        rgba[i * 4 + 3] = 255;
    }
    rgba
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(f: &TypeField, x: u32, y: u32) -> f64 {
        let i = ((y * f.w + x) * 4) as usize;
        ((f.rgba[i] as u32) << 8 | f.rgba[i + 1] as u32) as f64 / 65535.0
    }

    #[test]
    fn every_face_sets_a_line() {
        for f in TypeFont::ALL {
            let t = TypeField::bake("WETOWL", *f);
            assert!(t.w > t.h, "{f:?}: a row is wider than high ({}×{})", t.w, t.h);
            assert!(t.half_y > 0.5 && t.half_y < 1.0, "{f:?}: {}", t.half_y);
            // the corner is far outside; somewhere along the middle row is inside
            assert!(at(&t, 0, 0) > 0.99, "{f:?}");
            let inside = (0..t.w).any(|x| at(&t, x, t.h / 2) < 0.5);
            assert!(inside, "{f:?}: no letter on the middle row");
        }
    }

    #[test]
    fn a_long_line_is_set_smaller() {
        let t = TypeField::bake(&"WIDE ".repeat(30), TypeFont::Bebas);
        assert!(t.w <= 2001, "{}", t.w);
        assert!(t.h < TypeField::bake("WIDE", TypeFont::Bebas).h, "set smaller: a lower row");
    }
}
