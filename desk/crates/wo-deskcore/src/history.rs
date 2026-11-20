//! rekordbox's HISTORY: a record played for a minute or more in PERFORMANCE mode goes on
//! the day's play history ("HISTORY yyyy-mm-dd", in the tree), in the order played; the
//! records played are marked in the crate. Kept beside the Desk's other files, a file a day
//! (the day in UTC: no time zone is read).
use std::path::PathBuf;
use std::time::Instant;

use crate::records::Record;

/// How long a record plays before it is history: rekordbox's "played for 1 minute or more".
pub const PLAYED_FOR: f64 = 60.0;

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Entry {
    pub record: Record,
    /// When it went on the history, Unix seconds.
    pub at: u64,
}

#[derive(Default)]
pub struct History {
    /// The day's name, `yyyy-mm-dd`.
    pub day: String,
    pub entries: Vec<Entry>,
    /// The days kept and how many records each, newest first (today's as it grows).
    pub kept: Vec<(String, usize)>,
    /// Each deck: how long its record has played since it was loaded, and that load's count.
    played: [f64; 2],
    load: [u64; 2],
    counted: [bool; 2],
    last: Option<Instant>,
}

/// The civil date of Unix seconds `t` (UTC), `yyyy-mm-dd` (Howard Hinnant's days-to-civil).
pub fn day_of(t: u64) -> String {
    let z = (t / 86_400) as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + (m <= 2) as i64;
    format!("{y:04}-{m:02}-{d:02}")
}

fn folder() -> Option<PathBuf> {
    wo_house::folders::config().map(|d| d.join("wetowl-desk").join("history"))
}

fn file(day: &str) -> Option<PathBuf> {
    folder().map(|f| f.join(format!("HISTORY {day}.json")))
}

impl History {
    /// Today's history, as kept.
    pub fn today() -> History {
        let day = day_of(crate::session::now_secs());
        let entries = file(&day).and_then(|f| std::fs::read(f).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let mut h = History { day, entries, ..Default::default() };
        h.kept = History::days().into_iter().map(|d| {
            let n = if d == h.day { h.entries.len() } else { History::of(&d).len() };
            (d, n)
        }).collect();
        h
    }

    fn kept_today(&mut self) {
        let n = self.entries.len();
        match self.kept.iter_mut().find(|(d, _)| *d == self.day) {
            Some(k) => k.1 = n,
            None => self.kept.insert(0, (self.day.clone(), n)),
        }
    }

    /// The days kept, newest first.
    pub fn days() -> Vec<String> {
        let mut v: Vec<String> = folder()
            .and_then(|f| std::fs::read_dir(f).ok())
            .map(|r| r.flatten().filter_map(|e| e.file_name().to_str()?.strip_prefix("HISTORY ")?.strip_suffix(".json").map(str::to_owned)).collect())
            .unwrap_or_default();
        v.sort_by(|a, b| b.cmp(a));
        v
    }

    /// A day's records, in the order played.
    pub fn of(day: &str) -> Vec<Entry> {
        file(day).and_then(|f| std::fs::read(f).ok()).and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    fn save(&self) {
        let Some(f) = file(&self.day) else { return };
        if let Some(dir) = f.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(b) = serde_json::to_vec_pretty(&self.entries) {
            let tmp = f.with_extension("json.tmp");
            if std::fs::write(&tmp, b).is_ok() {
                let _ = std::fs::rename(tmp, f);
            }
        }
    }

    /// Whether a record is on today's history.
    pub fn played(&self, id: i64) -> bool {
        self.entries.iter().any(|e| e.record.id == id)
    }

    /// Each tick: the decks' records (`load`: each deck's load count, `playing`), counted;
    /// one past [PLAYED_FOR] on this load goes on the history. Returns whether it grew.
    pub fn tick(&mut self, records: [&Record; 2], load: [u64; 2], playing: [bool; 2]) -> bool {
        let now = Instant::now();
        let dt = self.last.map_or(0.0, |l| now.duration_since(l).as_secs_f64()).min(1.0);
        self.last = Some(now);
        self.tick_by(dt, records, load, playing)
    }

    fn tick_by(&mut self, dt: f64, records: [&Record; 2], load: [u64; 2], playing: [bool; 2]) -> bool {
        let mut grew = false;
        for d in 0..2 {
            if self.load[d] != load[d] {
                (self.load[d], self.played[d], self.counted[d]) = (load[d], 0.0, false);
            }
            if !playing[d] || !records[d].playable() {
                continue;
            }
            self.played[d] += dt;
            if !self.counted[d] && self.played[d] >= PLAYED_FOR {
                self.counted[d] = true;
                // a new day (a set past midnight): a new history, as rekordbox's
                let at = crate::session::now_secs();
                let day = day_of(at);
                if day != self.day {
                    (self.day, self.entries) = (day, vec![]);
                }
                self.entries.push(Entry { record: records[d].clone(), at });
                self.save();
                self.kept_today();
                grew = true;
            }
        }
        grew
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_record_played_a_minute_is_history_once_per_load() {
        let dir = std::env::temp_dir().join(format!("wo-history-{}", std::process::id()));
        // SAFETY: this test's own folder, set before the history is read or kept.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", &dir) };
        let mut h = History { day: day_of(crate::session::now_secs()), ..Default::default() };
        let rows = crate::records::synth_rows();
        let (a, b) = (rows[0].clone(), rows[1].clone());
        let step = |h: &mut History, secs: f64, load: [u64; 2], playing: [bool; 2]| {
            let mut grew = false;
            for _ in 0..(secs * 2.0) as usize {
                grew |= h.tick_by(0.5, [&a, &b], load, playing);
            }
            grew
        };
        assert!(!step(&mut h, 59.0, [1, 1], [true, false]), "under a minute: not yet");
        assert!(step(&mut h, 2.0, [1, 1], [true, false]), "a minute: history");
        assert!(!step(&mut h, 120.0, [1, 1], [true, false]), "once a load");
        assert!(!step(&mut h, 120.0, [1, 1], [false, false]), "stopped: nothing");
        assert!(step(&mut h, 61.0, [2, 1], [true, true]) && h.entries.len() == 3, "A again (a new load) and B");
        assert!(h.played(a.id) && h.played(b.id) && !h.played(12345));
        assert_eq!(History::of(&h.day).len(), 3, "kept");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn days_by_the_calendar() {
        assert_eq!(day_of(0), "1970-01-01");
        assert_eq!(day_of(1_763_683_200), "2025-11-21");
        assert_eq!(day_of(951_782_400), "2000-02-29");
    }
}
