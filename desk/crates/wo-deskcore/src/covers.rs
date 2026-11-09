//! Records' covers for the Desk's sleeves (decks, crate rows, up next): fetched small from
//! the house on worker threads, kept on disk (the cache folder, per house) and in memory,
//! square and [SIDE] px — the UI turns each into a texture once. A stick's records' covers
//! are read off the stick the same way.
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;

use wo_house::House;

/// A sleeve's side: a 72 pt deck sleeve on a 2× screen.
pub const SIDE: u32 = 144;
/// Fetches at once.
const WORKERS: usize = 3;
/// Covers kept in memory (the UI keeps its own textures; these are only their sources).
const KEPT: usize = 400;

/// One cover: [SIDE] × [SIDE] RGBA8, rows top first.
pub struct Cover {
    pub side: u32,
    pub rgba: Vec<u8>,
}

#[derive(Default)]
struct Got {
    /// id → the cover, or None where there is none to be had.
    covers: HashMap<i64, Option<Arc<Cover>>>,
    /// In the order they came, to forget the oldest.
    order: Vec<i64>,
}

/// Where a cover comes from.
enum Job {
    House(i64, House),
    File(i64, PathBuf),
}

#[derive(Default)]
pub(crate) struct Covers {
    tx: Option<mpsc::Sender<Job>>,
    got: Arc<Mutex<Got>>,
    asked: HashSet<i64>,
    /// Covers arrived, counted (the window repaints when it moves).
    pub(crate) arrived: Arc<AtomicU64>,
}

/// Where a house's covers are kept on disk.
fn folder(house: &House) -> Option<PathBuf> {
    let host: String = house.session.server.trim_start_matches("https://").trim_start_matches("http://").chars().map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' { c } else { '_' }).collect();
    dirs::cache_dir().map(|d| d.join("wetowl-desk").join("covers").join(host))
}

/// The bytes made a square sleeve: the middle of the picture, [SIDE] px.
pub(crate) fn square(bytes: &[u8]) -> Option<Cover> {
    let img = image::load_from_memory(bytes).ok()?;
    let (w, h) = (img.width(), img.height());
    let s = w.min(h);
    let img = img.crop_imm((w - s) / 2, (h - s) / 2, s, s).resize_exact(SIDE, SIDE, image::imageops::FilterType::Triangle);
    Some(Cover { side: SIDE, rgba: img.to_rgba8().into_raw() })
}

fn fetch(id: i64, house: &House) -> Option<Cover> {
    let file = folder(house).map(|d| d.join(format!("{id}.jpg")));
    if let Some(f) = &file
        && let Ok(bytes) = std::fs::read(f)
        && let Some(c) = square(&bytes)
    {
        return Some(c);
    }
    let bytes = house.cover_small(id).ok()?;
    let c = square(&bytes)?;
    if let Some(f) = &file {
        let _ = std::fs::create_dir_all(f.parent().unwrap());
        let _ = std::fs::write(f, &bytes);
    }
    Some(c)
}

impl Covers {
    /// `id`'s cover where it has come; asks the house for it the first time.
    pub(crate) fn get(&mut self, id: i64, house: Option<&House>) -> Option<Arc<Cover>> {
        if let Some(c) = self.got.lock().unwrap().covers.get(&id) {
            return c.clone();
        }
        let house = house?;
        if self.asked.insert(id) {
            let tx = self.tx.get_or_insert_with(|| start(self.got.clone(), self.arrived.clone()));
            let _ = tx.send(Job::House(id, house.clone()));
        }
        None
    }

    /// `id`'s cover from a picture file (a stick's), read the first time it is wanted.
    pub(crate) fn get_file(&mut self, id: i64, path: &std::path::Path) -> Option<Arc<Cover>> {
        if let Some(c) = self.got.lock().unwrap().covers.get(&id) {
            return c.clone();
        }
        if self.asked.insert(id) {
            let tx = self.tx.get_or_insert_with(|| start(self.got.clone(), self.arrived.clone()));
            let _ = tx.send(Job::File(id, path.to_owned()));
        }
        None
    }

    /// Signed out (or into another house): what was fetched is not this house's.
    pub(crate) fn forget(&mut self) {
        self.asked.clear();
        *self.got.lock().unwrap() = Got::default();
    }
}

fn start(got: Arc<Mutex<Got>>, arrived: Arc<AtomicU64>) -> mpsc::Sender<Job> {
    let (tx, rx) = mpsc::channel::<Job>();
    let rx = Arc::new(Mutex::new(rx));
    for n in 0..WORKERS {
        let (rx, got, arrived) = (rx.clone(), got.clone(), arrived.clone());
        let _ = thread::Builder::new().name(format!("covers {n}")).spawn(move || {
            loop {
                let Ok(job) = rx.lock().unwrap().recv() else { return };
                let (id, c) = match job {
                    Job::House(id, house) => (id, fetch(id, &house)),
                    Job::File(id, path) => (id, std::fs::read(&path).ok().and_then(|b| square(&b))),
                };
                let c = c.map(Arc::new);
                let mut g = got.lock().unwrap();
                g.covers.insert(id, c);
                g.order.push(id);
                if g.order.len() > KEPT {
                    let old = g.order.remove(0);
                    g.covers.remove(&old);
                }
                arrived.fetch_add(1, Ordering::Relaxed);
            }
        });
    }
    tx
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cover_is_cut_square_from_its_middle() {
        // 40 × 20: red left quarter, green middle half, blue right quarter
        let mut img = image::RgbImage::new(40, 20);
        for (x, _, p) in img.enumerate_pixels_mut() {
            *p = if x < 10 { image::Rgb([255, 0, 0]) } else if x < 30 { image::Rgb([0, 255, 0]) } else { image::Rgb([0, 0, 255]) };
        }
        let mut png = Vec::new();
        image::DynamicImage::ImageRgb8(img).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        let c = square(&png).unwrap();
        assert_eq!(c.rgba.len(), (SIDE * SIDE * 4) as usize);
        // the middle half only: green throughout
        assert!(c.rgba.chunks(4).all(|p| p[1] > 200 && p[0] < 40 && p[2] < 40));
    }
}
