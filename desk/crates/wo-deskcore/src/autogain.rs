//! Auto Gain, as rekordbox's (Preferences → Controller → Mixer → Auto Gain): every record
//! analysed for its loudness and its deck turned so they all play equally loud, the value
//! shown on the deck and adjustable by hand, the hand's value kept for the record.
//!
//! The loudness is the integrated BS.1770 / EBU R128 one, measured here from the audio as
//! it decodes (the house's number until then, for its records). Measurements and the
//! hand's values are kept in `auto-gain.json` beside the Desk's other files, by record:
//! a house record by its id, a file or a stick's record by its path, size and time.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::records::{Audio, Record};

/// The loudness every record is brought to, LUFS (the house's and the phones' player's).
pub const REFERENCE_LUFS: f32 = -14.0;
/// The most a record is turned down and up, dB. Up as far as rekordbox's own knob: the
/// master's limiter keeps a quiet record's peaks under full scale once it is turned up.
pub const MOST_DOWN: f32 = -24.0;
pub const MOST_UP: f32 = 12.0;

/// The gain for a record measured at `lufs`.
pub fn gain_for(lufs: f32) -> f32 {
    (REFERENCE_LUFS - lufs).clamp(MOST_DOWN, MOST_UP)
}

/// Where a deck's Auto Gain came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// Measured here (now or before).
    Measured,
    /// The house's measurement (until this Desk's own is in).
    House,
    /// Set by hand for this record.
    Hand,
}

/// A deck's Auto Gain: dB, and where it came from; None while the record is still being
/// measured (and has no house number).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct AutoGain {
    pub db: Option<f32>,
    pub source: Option<Source>,
    /// The record's loudness as measured, LUFS (shown beside the gain).
    pub lufs: Option<f32>,
}

/// The record's key in the store (None: not kept, as a synthesised record).
pub fn key(record: &Record) -> Option<String> {
    match &record.audio {
        Audio::House { id } => Some(format!("house:{id}")),
        Audio::File { path, .. } | Audio::Usb { path, .. } => file_key(path),
        Audio::Synth { .. } | Audio::None => None,
    }
}

/// A file's key: its name with its size and time (a stick mounted elsewhere, or the file
/// changed, is measured again).
pub fn file_key(path: &Path) -> Option<String> {
    let m = std::fs::metadata(path).ok()?;
    let t = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs());
    let name = path.file_name()?.to_string_lossy();
    Some(format!("file:{name}:{}:{t}", m.len()))
}

#[derive(Default, serde::Serialize, serde::Deserialize)]
struct Kept {
    #[serde(default)]
    measured: HashMap<String, f32>,
    #[serde(default)]
    by_hand: HashMap<String, f32>,
}

/// The measurements and the hand's values, kept on disk (shared with the stick's sweep).
#[derive(Clone)]
pub struct Store {
    kept: Arc<Mutex<Kept>>,
    file: Option<PathBuf>,
}

impl Store {
    pub fn open() -> Store {
        Store::at(wo_house::folders::config().map(|d| d.join("wetowl-desk").join("auto-gain.json")))
    }

    /// One at `file` (None: in memory only, for tests).
    pub fn at(file: Option<PathBuf>) -> Store {
        let kept = file.as_ref().and_then(|f| std::fs::read(f).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Store { kept: Arc::new(Mutex::new(kept)), file }
    }

    pub fn measured(&self, key: &str) -> Option<f32> {
        self.kept.lock().unwrap().measured.get(key).copied()
    }

    pub fn by_hand(&self, key: &str) -> Option<f32> {
        self.kept.lock().unwrap().by_hand.get(key).copied()
    }

    pub fn set_measured(&self, key: &str, lufs: f32) {
        self.kept.lock().unwrap().measured.insert(key.to_owned(), lufs);
        self.save();
    }

    pub fn set_by_hand(&self, key: &str, db: Option<f32>) {
        {
            let mut k = self.kept.lock().unwrap();
            match db {
                Some(db) => k.by_hand.insert(key.to_owned(), db),
                None => k.by_hand.remove(key),
            };
        }
        self.save();
    }

    /// A record's Auto Gain from what is known now: the hand's value, else this Desk's
    /// measurement, else the house's.
    pub fn gain_of(&self, record: &Record) -> AutoGain {
        let key = key(record);
        let measured = key.as_deref().and_then(|k| self.measured(k));
        if let Some(db) = key.as_deref().and_then(|k| self.by_hand(k)) {
            return AutoGain { db: Some(db), source: Some(Source::Hand), lufs: measured };
        }
        if let Some(l) = measured {
            return AutoGain { db: Some(gain_for(l)), source: Some(Source::Measured), lufs: Some(l) };
        }
        if let Some(g) = record.loudness.gain_db {
            let g = g.clamp(MOST_DOWN, MOST_UP);
            return AutoGain { db: Some(g), source: Some(Source::House), lufs: Some(REFERENCE_LUFS - g) };
        }
        AutoGain::default()
    }

    fn save(&self) {
        let Some(f) = &self.file else { return };
        let bytes = serde_json::to_vec(&*self.kept.lock().unwrap()).unwrap_or_default();
        let _ = std::fs::create_dir_all(f.parent().unwrap());
        let part = f.with_extension("json.part");
        if std::fs::write(&part, bytes).is_ok() {
            let _ = std::fs::rename(&part, f);
        }
    }
}

/// Measures a stick's records not measured yet, one after another on a quiet thread, as
/// rekordbox analyses before a set: a record put on a deck then has its gain at once.
/// Stops when `stop` says so (the stick taken out).
pub fn sweep(store: Store, paths: Vec<PathBuf>, stop: Arc<std::sync::atomic::AtomicBool>) {
    let _ = std::thread::Builder::new().name("auto gain".into()).spawn(move || {
        lower_priority();
        for path in paths {
            if stop.load(std::sync::atomic::Ordering::Relaxed) {
                return;
            }
            let Some(k) = file_key(&path) else { continue };
            if store.measured(&k).is_some() {
                continue;
            }
            match measure(&path, true) {
                Ok(Some(l)) => store.set_measured(&k, l),
                Ok(None) => {}
                Err(e) => eprintln!("auto gain: {}: {e}", path.display()),
            }
        }
    });
}

/// A file's integrated loudness, LUFS (`rekordbox`: decoded as rekordbox does, its MP3s untrimmed).
pub fn measure(path: &Path, rekordbox: bool) -> Result<Option<f32>, wo_decode::Error> {
    struct M(wo_wave::loudness::Meter);
    impl wo_decode::Sink for M {
        fn take(&mut self, pcm: &[i16]) -> Result<(), wo_decode::Error> {
            self.0.feed(pcm);
            Ok(())
        }
    }
    let mut m = M(wo_wave::loudness::Meter::new(crate::RATE));
    if rekordbox {
        wo_decode::decode_as_rekordbox(path, crate::RATE, &mut m)?;
    } else {
        wo_decode::decode(path, crate::RATE, &mut m)?;
    }
    Ok(m.0.integrated())
}

#[cfg(unix)]
fn lower_priority() {
    unsafe extern "C" {
        fn nice(inc: i32) -> i32;
    }
    // this thread alone on Linux (its own nice value)
    unsafe {
        nice(10);
    }
}

#[cfg(not(unix))]
fn lower_priority() {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::records::Loudness;

    fn house(id: i64, gain: Option<f32>) -> Record {
        let mut r = crate::records::synth_rows().remove(0);
        r.audio = Audio::House { id };
        r.loudness = Loudness { gain_db: gain, true_peak_db: None };
        r
    }

    #[test]
    fn loud_records_go_down_quiet_ones_up_within_the_knob() {
        assert_eq!(gain_for(-8.0), -6.0);
        assert_eq!(gain_for(-20.0), 6.0);
        assert_eq!(gain_for(-40.0), MOST_UP);
        assert_eq!(gain_for(20.0), MOST_DOWN);
    }

    #[test]
    fn the_hand_beats_the_measurement_which_beats_the_house() {
        let s = Store::at(None);
        let r = house(7, Some(-5.0));
        assert_eq!(s.gain_of(&r), AutoGain { db: Some(-5.0), source: Some(Source::House), lufs: Some(-9.0) });
        s.set_measured("house:7", -8.0);
        assert_eq!(s.gain_of(&r), AutoGain { db: Some(-6.0), source: Some(Source::Measured), lufs: Some(-8.0) });
        s.set_by_hand("house:7", Some(-2.5));
        assert_eq!(s.gain_of(&r).db, Some(-2.5));
        assert_eq!(s.gain_of(&r).source, Some(Source::Hand));
        s.set_by_hand("house:7", None);
        assert_eq!(s.gain_of(&r).source, Some(Source::Measured));
        // nothing known: none yet (measured as it decodes)
        assert_eq!(s.gain_of(&house(8, None)), AutoGain::default());
    }

    #[test]
    fn kept_across_starts() {
        let dir = std::env::temp_dir().join(format!("wo-autogain-{}", std::process::id()));
        let f = dir.join("auto-gain.json");
        let s = Store::at(Some(f.clone()));
        s.set_measured("house:1", -9.5);
        s.set_by_hand("house:2", Some(3.0));
        let again = Store::at(Some(f));
        assert_eq!(again.measured("house:1"), Some(-9.5));
        assert_eq!(again.by_hand("house:2"), Some(3.0));
        let _ = std::fs::remove_dir_all(dir);
    }
}
