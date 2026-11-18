//! The browser's previews (rekordbox's Preview column): each record's whole waveform in a
//! few bins. A stick's record has rekordbox's own (its analysis files, read on a worker);
//! a house's record one the Desk made, kept on disk once it has decoded on a deck.
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::Arc;

use wo_wave::{RbBin, RbCol, Wave};

use crate::records::{Audio, Record};

/// Bins a preview.
pub const BINS: usize = 96;

pub type Preview = Arc<Vec<Option<RbBin>>>;

enum Ask {
    Usb(i64, PathBuf),
    House(i64, PathBuf),
}

#[derive(Default)]
pub(crate) struct Previews {
    tx: Option<mpsc::Sender<Ask>>,
    rx: Option<mpsc::Receiver<(i64, Option<Preview>)>>,
    got: HashMap<i64, Option<Preview>>,
    asked: HashSet<i64>,
    /// Where the house's are kept (per house), when signed in.
    pub(crate) folder: Option<PathBuf>,
    /// The deck records already kept, by their record.
    pub(crate) kept: HashSet<i64>,
}

/// A preview as bytes: nine a bin (bands, colour, heights, whiteness, ×255), 0xFF first
/// where a bin is empty.
fn to_bytes(p: &[Option<RbBin>]) -> Vec<u8> {
    let q = |v: f32| (v.clamp(0.0, 1.0) * 254.0).round() as u8;
    p.iter()
        .flat_map(|b| match b {
            Some(b) => [q(b.bands[0]), q(b.bands[1]), q(b.bands[2]), q(b.rgb[0]), q(b.rgb[1]), q(b.rgb[2]), q(b.height), q(b.blue), q(b.white)],
            None => [0xFF; 9],
        })
        .collect()
}

fn from_bytes(b: &[u8]) -> Option<Vec<Option<RbBin>>> {
    if b.len() != BINS * 9 {
        return None;
    }
    let v = |x: u8| x as f32 / 254.0;
    Some(b.as_chunks::<9>().0.iter().map(|c| (c[0] != 0xFF).then(|| RbBin { bands: [v(c[0]), v(c[1]), v(c[2])], rgb: [v(c[3]), v(c[4]), v(c[5])], height: v(c[6]), blue: v(c[7]), white: v(c[8]) })).collect())
}

fn usb_preview(dat: &std::path::Path) -> Option<Preview> {
    let a = wo_usb::analysis_of(dat).ok()?;
    let w = &a.waves;
    let n = w.blue.len().max(w.rgb.len()).max(w.bands.len());
    if n == 0 {
        return None;
    }
    let mut wave = Wave::default();
    wave.set_exact((0..n).map(|i| RbCol::from_stick(w.blue.get(i).copied(), w.rgb.get(i).copied(), w.bands.get(i).copied())).collect());
    Some(Arc::new(wave.rb_overview(n as f64 / wo_wave::RATE, BINS)))
}

impl Previews {
    /// `r`'s preview, where it has one and it has come (asked for the first time it is not).
    pub(crate) fn of(&mut self, r: &Record) -> Option<Preview> {
        self.drain();
        if let Some(p) = self.got.get(&r.id) {
            return p.clone();
        }
        if !self.asked.insert(r.id) {
            return None;
        }
        let ask = match &r.audio {
            Audio::Usb { anlz: Some(dat), .. } => Ask::Usb(r.id, dat.clone()),
            Audio::House { id } => Ask::House(r.id, self.folder.as_ref()?.join(format!("{id}.rbp"))),
            _ => return None,
        };
        if self.tx.is_none() {
            let (tx, jobs) = mpsc::channel::<Ask>();
            let (done, rx) = mpsc::channel();
            std::thread::Builder::new()
                .name("previews".into())
                .spawn(move || {
                    for ask in jobs {
                        let (id, p) = match ask {
                            Ask::Usb(id, dat) => (id, usb_preview(&dat)),
                            Ask::House(id, file) => (id, std::fs::read(file).ok().and_then(|b| from_bytes(&b)).map(Arc::new)),
                        };
                        if done.send((id, p)).is_err() {
                            break;
                        }
                    }
                })
                .expect("the previews' worker");
            self.tx = Some(tx);
            self.rx = Some(rx);
        }
        let _ = self.tx.as_ref().unwrap().send(ask);
        None
    }

    /// Those come from the worker taken in: whether any did (the window draws them).
    pub(crate) fn drain(&mut self) -> bool {
        let mut any = false;
        if let Some(rx) = &self.rx {
            while let Ok((id, p)) = rx.try_recv() {
                self.got.insert(id, p);
                any = true;
            }
        }
        any
    }

    /// A house record's preview made (its deck has decoded it all): kept on disk and here.
    pub(crate) fn keep(&mut self, id: i64, house_id: i64, p: Vec<Option<RbBin>>) {
        if !self.kept.insert(id) {
            return;
        }
        if let Some(dir) = &self.folder {
            let _ = std::fs::create_dir_all(dir);
            let _ = std::fs::write(dir.join(format!("{house_id}.rbp")), to_bytes(&p));
        }
        self.got.insert(id, Some(Arc::new(p)));
    }

    /// Signed in or out: the house's previews are another house's.
    pub(crate) fn set_folder(&mut self, folder: Option<PathBuf>) {
        if folder != self.folder {
            self.folder = folder;
            self.got.retain(|id, _| *id < 0);
            self.asked.retain(|id| *id < 0);
            self.kept.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_preview_keeps_through_its_bytes() {
        let p: Vec<Option<RbBin>> = (0..BINS).map(|i| (i % 7 != 0).then(|| RbBin { bands: [0.5, 0.25, i as f32 / BINS as f32], rgb: [1.0, 0.0, 0.5], height: 0.75, blue: 0.7, white: 0.1 })).collect();
        let back = from_bytes(&to_bytes(&p)).unwrap();
        for (a, b) in p.iter().zip(&back) {
            match (a, b) {
                (Some(a), Some(b)) => assert!((a.bands[2] - b.bands[2]).abs() < 0.005 && (a.height - b.height).abs() < 0.005),
                (None, None) => {}
                _ => panic!("an empty bin kept as a full one, or back"),
            }
        }
        assert!(from_bytes(&[0; 10]).is_none());
    }
}
