//! The glass's backdrop: the stage, blurred once and dimmed under the scrim, so a UI
//! draws one image and then plain translucent panels over it — no toolkit has to blur
//! what is behind a panel. (In the Desk proper this is the live stage, blurred on the
//! GPU each frame; here, one of the native stage's frames.) Numbers: design/tokens.json.
const STAGE: &[u8] = include_bytes!("../../../bakeoff/stage-flash.jpg");

pub struct Backdrop {
    pub width: u32,
    pub height: u32,
    /// Opaque RGBA8.
    pub rgba: Vec<u8>,
}

/// The backdrop at `width` × `height` (small: it is drawn stretched, and it is a blur).
pub fn backdrop(width: u32, height: u32) -> Backdrop {
    let img = image::load_from_memory(STAGE).expect("the stage frame").to_rgb8();
    // Cover the box, then blur: 80 px at 1920 wide.
    let small = image::imageops::resize(&img, width, height, image::imageops::FilterType::Triangle);
    let mut px: Vec<[f32; 3]> = small.pixels().map(|p| [p[0] as f32, p[1] as f32, p[2] as f32]).collect();
    let radius = ((80.0 * width as f32 / 1920.0) / 1.7).max(1.0) as usize;
    for _ in 0..3 {
        px = box_blur(&px, width as usize, height as usize, radius, true);
        px = box_blur(&px, width as usize, height as usize, radius, false);
    }
    // brightness 0.6 and saturate 1.5, then the scrim rgba(7,8,11,0.72) over it
    let scrim = [7.0f32, 8.0, 11.0];
    let mut rgba = Vec::with_capacity(px.len() * 4);
    for p in px {
        let grey = 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2];
        for k in 0..3 {
            let sat = grey + (p[k] - grey) * 1.5;
            let v = (sat * 0.6).clamp(0.0, 255.0);
            rgba.push((0.28 * v + 0.72 * scrim[k]).round() as u8);
        }
        rgba.push(255);
    }
    Backdrop { width, height, rgba }
}

fn box_blur(px: &[[f32; 3]], w: usize, h: usize, r: usize, rows: bool) -> Vec<[f32; 3]> {
    let mut out = vec![[0.0; 3]; px.len()];
    let (lines, len) = if rows { (h, w) } else { (w, h) };
    let at = |line: usize, i: usize| if rows { line * w + i } else { i * w + line };
    let norm = 1.0 / (2 * r + 1) as f32;
    for line in 0..lines {
        let mut acc = [0.0f32; 3];
        for i in 0..=2 * r {
            let j = (i as isize - r as isize).clamp(0, len as isize - 1) as usize;
            for k in 0..3 {
                acc[k] += px[at(line, j)][k];
            }
        }
        for i in 0..len {
            for k in 0..3 {
                out[at(line, i)][k] = acc[k] * norm;
            }
            let add = (i + r + 1).min(len - 1);
            let sub = (i as isize - r as isize).max(0) as usize;
            for k in 0..3 {
                acc[k] += px[at(line, add)][k] - px[at(line, sub)][k];
            }
        }
    }
    out
}

/// The disco ball of the WET◉WL mark, RGBA.
pub fn ball() -> Backdrop {
    let img = image::load_from_memory(include_bytes!("../../../bakeoff/ball.png")).expect("the ball").to_rgba8();
    Backdrop { width: img.width(), height: img.height(), rgba: img.into_raw() }
}
