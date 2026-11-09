//! The house's library as the crate shows it: one shelf at a time (everything, a
//! playlist, a search), filled by worker threads that report back through a channel
//! the desk drains once a frame. Nothing here blocks the UI.
use std::sync::mpsc::Sender;
use std::thread;

use wo_booth::{Grid, PadKind};
use wo_house::{HandPads, House, PlaylistSummary};

use crate::records::Record;

/// What the crate shows.
#[derive(Clone, Debug, PartialEq)]
pub enum Shelf {
    /// Everything ready on the house, newest first.
    All,
    Playlist { id: i64, name: String },
    Search(String),
    /// The records that would follow this one best (the house's partners, in key first).
    Fits { from: i64, title: String },
    /// The records a hand queued for the Auto DJ, in order.
    Queue,
    /// Records that go with what is on (the house's /recommend): `fresh` in hundredths —
    /// 0 this person's own, 100 new to them; `seeds` the decks' and the queue's.
    Similar { fresh: u8, seeds: Vec<i64>, exclude: Vec<i64> },
    /// Records to check by ear: the grid said of, the pads where a DJ leaves them.
    Check,
    /// A rekordbox USB stick's records: all of them, or one playlist's (rekordbox's id
    /// and name), in its order.
    Usb { root: std::path::PathBuf, stick: String, playlist: Option<(u32, String)> },
}

/// A rekordbox stick plugged in, as the crate lists it.
#[derive(Clone, Debug, PartialEq)]
pub struct StickView {
    pub root: std::path::PathBuf,
    pub name: String,
    pub records: usize,
    /// rekordbox's id, the name (with its folders, " / " between), how many records.
    pub playlists: Vec<(u32, String, usize)>,
}

impl StickView {
    pub(crate) fn of(s: &wo_usb::Stick) -> StickView {
        StickView {
            root: s.root.clone(),
            name: s.name.clone(),
            records: s.tracks.len(),
            playlists: s.playlists.iter().map(|p| (p.id, p.folders.iter().chain([&p.name]).cloned().collect::<Vec<_>>().join(" / "), p.tracks.len())).collect(),
        }
    }
}

/// The library this frame.
#[derive(Clone, Debug)]
pub struct Library {
    pub shelf: Shelf,
    pub rows: Vec<Record>,
    /// How many the house has on this shelf (all of them, not only those fetched).
    pub total: i64,
    pub loading: bool,
    pub playlists: Vec<PlaylistSummary>,
    pub signing_in: bool,
    /// The last thing the house said no to, in words.
    pub error: Option<String>,
    /// A word on a row (why it was picked, what a check said), by record.
    pub notes: std::collections::HashMap<i64, String>,
    /// The cue check's records already checked, by record: what their grid was said to be.
    pub checked: std::collections::HashMap<i64, Option<String>>,
    /// The rekordbox sticks plugged in.
    pub sticks: Vec<StickView>,
}

impl Default for Library {
    fn default() -> Self {
        Library {
            shelf: Shelf::All,
            rows: vec![],
            total: 0,
            loading: false,
            playlists: vec![],
            signing_in: false,
            error: None,
            notes: Default::default(),
            checked: Default::default(),
            sticks: vec![],
        }
    }
}

/// The cue check's verdicts on a grid: the house's word, the button's, what it means.
pub const GRID_VERDICTS: &[(&str, &str, &str)] = &[
    ("ok", "Grid OK", "The beat, the bars and the four-bar lines are where they should be"),
    ("double", "×2 fast", "The tempo shown is twice the record's"),
    ("half", "÷2 slow", "The tempo shown is half the record's"),
    ("off", "Off beat", "The right tempo, but the beat lines sit between the beats"),
    ("one", "One wrong", "The beat is right but the bar starts on the wrong beat"),
    ("other", "Other", "Something else: a wrong tempo, a grid that drifts, no beat at all"),
];

/// A grid verdict in words.
pub fn verdict_word(grid: Option<&str>) -> String {
    GRID_VERDICTS.iter().find(|v| Some(v.0) == grid).map_or("no word on the grid".to_owned(), |v| v.1.to_lowercase())
}

/// A record's analysis, ready for its deck.
pub(crate) struct Analysed {
    pub grid: Grid,
    pub timing: wo_booth::Timing,
    pub auto: Vec<(usize, f64, PadKind)>,
    pub hand: HandPads,
    pub camelot: Option<String>,
    pub bpm: Option<f64>,
    /// Where it sings (none where the house has not mapped it).
    pub vocals: Option<wo_booth::planner::VocalMap>,
    /// Where CUE goes back to (a stick's first memory cue).
    pub cue: Option<f64>,
}

/// What a worker thread hands back.
pub(crate) enum Done {
    SignedIn(Result<Box<House>, String>),
    Shelf { turn: u64, rows: Result<(Vec<Record>, i64), String>, notes: Vec<(i64, String)>, checked: Vec<(i64, Option<String>)> },
    /// The next page of the shelf (the whole library), for the shelf's turn.
    More { turn: u64, rows: Result<(Vec<Record>, i64), String> },
    Playlists(Result<Vec<PlaylistSummary>, String>),
    Analysed { slot: usize, turn: u64, result: Result<Box<Analysed>, String> },
    /// A record's cover, as the stage's cover ground takes it (None: none to be had).
    Cover { slot: usize, turn: u64, id: i64, cover: Option<Picture> },
    LoadFailed { slot: usize, turn: u64, why: String },
    /// A set from the house (set.rs); `rest`: the rest of one playing, built again.
    Set { turn: u64, got: Result<crate::set::DjSet, String>, rest: bool },
    /// This person's taste in the booth's mixes (autodj.rs).
    Taste(wo_booth::taste::Taste),
    /// The house's choices for after the master (autodj.rs), for an ask by turn.
    Choices { turn: u64, got: Result<Vec<wo_house::SlotChoice>, String> },
    /// A deck's stems: decoded onto a source, or where they are instead (parts.rs).
    Stems { slot: usize, turn: u64, got: crate::parts::Got },
    /// The rekordbox sticks plugged in now, read (sent when they change).
    Sticks(Vec<std::sync::Arc<wo_usb::Stick>>),
}

pub(crate) fn sign_in(tx: &Sender<Done>, server: String, user: String, password: String) {
    let tx = tx.clone();
    thread::spawn(move || {
        let _ = tx.send(Done::SignedIn(House::sign_in(&server, &user, &password).map(Box::new).map_err(|e| e.to_string())));
    });
}

/// The next page of the whole library, from `offset`.
pub(crate) fn fetch_more(tx: &Sender<Done>, house: &House, offset: i64, turn: u64) {
    let (tx, house) = (tx.clone(), house.clone());
    thread::spawn(move || {
        let rows = house.tracks("added", offset, 200).map(|p| (p.items.iter().map(Record::from_house).collect(), p.total)).map_err(|e| e.to_string());
        let _ = tx.send(Done::More { turn, rows });
    });
}

/// The shelf's first page (200 records).
pub(crate) fn fetch_shelf(tx: &Sender<Done>, house: &House, shelf: Shelf, turn: u64) {
    let (tx, house) = (tx.clone(), house.clone());
    thread::spawn(move || {
        let mut notes: Vec<(i64, String)> = vec![];
        let mut checked: Vec<(i64, Option<String>)> = vec![];
        let rows = match shelf {
            Shelf::All => house.tracks("added", 0, 200).map(|p| (p.items, p.total)),
            Shelf::Playlist { id, .. } => house.playlist(id).map(|p| {
                let n = p.items.len() as i64;
                (p.items, n)
            }),
            Shelf::Search(q) => house.search(&q).map(|v| {
                let n = v.len() as i64;
                (v, n)
            }),
            // in key first, then the rest, each lot best first
            Shelf::Fits { from, .. } => house.partners(from, &[from], 24, true).and_then(|keyed| {
                let rest = house.partners(from, &[from], 30, false)?;
                let mut v: Vec<wo_house::Track> = keyed.into_iter().map(|p| p.0).collect();
                for (t, _, _) in rest {
                    if !v.iter().any(|x| x.id == t.id) {
                        v.push(t);
                    }
                }
                let n = v.len() as i64;
                Ok((v, n))
            }),
            // (the Desk lists these itself)
            Shelf::Queue | Shelf::Usb { .. } => Ok((vec![], 0)),
            Shelf::Similar { fresh, seeds, exclude } => house.recommend(&seeds, &exclude, fresh as f64 / 100.0, 30).map(|picks| {
                let v: Vec<wo_house::Track> = picks
                    .into_iter()
                    .filter_map(|p| {
                        let t = p.track?;
                        let mut why = vec![];
                        if p.where_ == "house" {
                            why.push("new to you, the house has it".to_owned());
                        }
                        if !p.why.is_empty() {
                            why.push(p.why);
                        }
                        if !why.is_empty() {
                            notes.push((t.id, why.join(" · ")));
                        }
                        Some(t)
                    })
                    .collect();
                let n = v.len() as i64;
                (v, n)
            }),
            Shelf::Check => house.cue_checks(40).map(|items| {
                let v: Vec<wo_house::Track> = items
                    .into_iter()
                    .map(|c| {
                        if c.checked_at.is_some() {
                            notes.push((c.track.id, format!("checked · {}", verdict_word(c.grid.as_deref()))));
                            checked.push((c.track.id, c.grid));
                        }
                        c.track
                    })
                    .collect();
                let n = v.len() as i64;
                (v, n)
            }),
        }
        .map(|(tracks, total)| (tracks.iter().map(Record::from_house).collect(), total))
        .map_err(|e| e.to_string());
        let _ = tx.send(Done::Shelf { turn, rows, notes, checked });
    });
}

pub(crate) fn fetch_playlists(tx: &Sender<Done>, house: &House) {
    let (tx, house) = (tx.clone(), house.clone());
    thread::spawn(move || {
        let mut lists = house.playlists().map_err(|e| e.to_string());
        if let Ok(l) = &mut lists {
            // pinned first, then the house's order; the empty ones are no use to a DJ
            l.retain(|p| p.items > 0);
            l.sort_by_key(|p| !p.pinned.unwrap_or(false));
        }
        let _ = tx.send(Done::Playlists(lists));
    });
}

/// A picture, RGBA8 rows top first.
pub(crate) type Picture = (u32, u32, Vec<u8>);

/// The longest side of a cover sent to the stage: a ground behind the figure, filled and
/// cropped to the screen, half-dimmed (half a megabyte up the wire per record).
const COVER_SIDE: u32 = 512;

/// A house record's cover, decoded and made small enough for the stage.
pub(crate) fn cover(house: &House, id: i64) -> Result<Picture, String> {
    let bytes = house.cover(id).map_err(|e| e.to_string())?;
    let img = image::load_from_memory(&bytes).map_err(|e| e.to_string())?;
    let img = if img.width().max(img.height()) > COVER_SIDE { img.resize(COVER_SIDE, COVER_SIDE, image::imageops::FilterType::Triangle) } else { img };
    let rgba = img.to_rgba8();
    Ok((rgba.width(), rgba.height(), rgba.into_raw()))
}

/// A house record's analysis and hand pads (the audio follows in the deck's loader).
pub(crate) fn analyse(house: &House, id: i64) -> Result<Analysed, String> {
    let a = house.analysis(id).map_err(|e| e.to_string())?;
    let hand = house.hand_pads(id).unwrap_or_default();
    let vocals = house.vocals(id).ok();
    Ok(Analysed { grid: a.grid(), timing: a.timing(), auto: a.auto_pads(), hand, camelot: a.camelot.clone(), bpm: a.bpm, vocals, cue: None })
}

/// A stick's record's analysis, rekordbox's: its grid; hot cues A–H on pads 1–8 (a hot
/// loop's pad goes to its start); the first memory cue for CUE; the booth's own pads
/// (as for a record of this computer's) where rekordbox left a pad empty.
pub(crate) fn analyse_usb(dat: Option<&std::path::Path>, seconds: f64) -> Result<Analysed, String> {
    let a = match dat {
        Some(d) => wo_usb::analysis_of(d).map_err(|e| format!("its rekordbox analysis: {e}"))?,
        None => wo_usb::Analysis::default(),
    };
    Ok(usb_analysed(a, seconds))
}

fn usb_analysed(a: wo_usb::Analysis, seconds: f64) -> Analysed {
    let grid = Grid::new(a.beats.clone(), a.bar_one);
    let mut hand: HandPads = vec![];
    for c in &a.cues {
        if let wo_usb::CueKind::Hot(n) = c.kind
            && (n as usize) < 8
            && !hand.iter().any(|h| h.0 == n as usize)
        {
            hand.push((n as usize, Some(c.ms as f64 / 1000.0)));
        }
    }
    let cue = a.cues.iter().find(|c| c.kind == wo_usb::CueKind::Memory).map(|c| c.ms as f64 / 1000.0);
    let beats = &a.beats;
    let bar_at = |frac: f64| -> f64 {
        let i = (((frac * beats.len() as f64) as usize).saturating_sub(a.bar_one) / 4) * 4 + a.bar_one;
        beats.get(i).copied().unwrap_or(frac * seconds)
    };
    let auto: Vec<(usize, f64, PadKind)> = if beats.is_empty() {
        vec![]
    } else {
        [(0, beats[a.bar_one.min(beats.len() - 1)], PadKind::Intro), (1, bar_at(0.3), PadKind::Drop), (2, bar_at(0.5), PadKind::Break), (3, bar_at(0.86), PadKind::Out)]
            .into_iter()
            .filter(|p| !hand.iter().any(|h| h.0 == p.0))
            .collect()
    };
    let timing = wo_booth::Timing::from_grid(grid.clone(), seconds);
    Analysed { grid, timing, auto, hand, camelot: None, bpm: None, vocals: None, cue }
}

/// A stick's record's cover, for the stage (as [cover] makes the house's).
pub(crate) fn cover_file(path: &std::path::Path) -> Result<Picture, String> {
    let img = image::open(path).map_err(|e| e.to_string())?;
    let img = if img.width().max(img.height()) > COVER_SIDE { img.resize(COVER_SIDE, COVER_SIDE, image::imageops::FilterType::Triangle) } else { img };
    let rgba = img.to_rgba8();
    Ok((rgba.width(), rgba.height(), rgba.into_raw()))
}

/// Watches for rekordbox sticks: every two seconds a look at where drives are mounted;
/// a stick that came (or whose database changed) is read, and the whole set is sent
/// when it differs from the last. Ends with the Desk (its channel closed).
pub(crate) fn watch_sticks(tx: &Sender<Done>) {
    if std::env::var("WO_USB").is_ok_and(|v| v == "off") {
        return;
    }
    let tx = tx.clone();
    let _ = thread::Builder::new().name("usb sticks".into()).spawn(move || {
        type Seen = (std::path::PathBuf, Option<std::time::SystemTime>, u64);
        let mut last: Vec<(Seen, std::sync::Arc<wo_usb::Stick>)> = vec![];
        let mut first = true;
        loop {
            let mut now = vec![];
            for root in wo_usb::find() {
                let meta = std::fs::metadata(root.join(wo_usb::DATABASE)).ok();
                let seen: Seen = (root.clone(), meta.as_ref().and_then(|m| m.modified().ok()), meta.map_or(0, |m| m.len()));
                match last.iter().find(|(s, _)| *s == seen) {
                    Some((_, stick)) => now.push((seen, stick.clone())),
                    None => match wo_usb::Stick::open(&root) {
                        Ok(stick) => now.push((seen, std::sync::Arc::new(stick))),
                        Err(e) => eprintln!("rekordbox stick at {}: {e}", root.display()),
                    },
                }
            }
            let same = now.len() == last.len() && now.iter().zip(&last).all(|(a, b)| a.0 == b.0);
            if (!same || first) && tx.send(Done::Sticks(now.iter().map(|n| n.1.clone()).collect())).is_err() {
                return;
            }
            first = false;
            last = now;
            thread::sleep(std::time::Duration::from_secs(2));
        }
    });
}

#[cfg(test)]
mod usb_tests {
    use super::*;
    use wo_usb::{Cue, CueKind};

    fn cue(kind: CueKind, ms: u32) -> Cue {
        Cue { kind, ms, loop_end_ms: None, rgb: None, comment: String::new() }
    }

    #[test]
    fn a_sticks_hot_cues_are_the_pads_and_its_memory_cue_the_cue() {
        let spb = 60.0 / 128.0;
        let beats: Vec<f64> = (0..512).map(|i| 0.05 + i as f64 * spb).collect();
        // hot cue A and C, a memory cue, a hot loop E
        let a = wo_usb::Analysis {
            beats,
            bar_one: 1,
            cues: vec![cue(CueKind::Memory, 15_050), cue(CueKind::Hot(0), 30_050), cue(CueKind::Hot(2), 60_050), Cue { loop_end_ms: Some(92_000), ..cue(CueKind::Hot(4), 90_050) }],
        };
        let got = usb_analysed(a, 240.0);
        assert_eq!(got.grid.bar_one, 1);
        assert_eq!(got.cue, Some(15.05));
        assert_eq!(got.hand, vec![(0, Some(30.05)), (2, Some(60.05)), (4, Some(90.05))]);
        // the booth's own pads only where rekordbox left them empty: 2 (drop) and 4 (out)
        let auto: Vec<usize> = got.auto.iter().map(|p| p.0).collect();
        assert_eq!(auto, vec![1, 3]);
        assert!(got.auto.iter().all(|p| got.grid.is_bar(got.grid.beats.iter().position(|&b| b == p.1).unwrap())));
    }

    #[test]
    fn a_record_rekordbox_never_analysed_still_loads() {
        let got = usb_analysed(wo_usb::Analysis::default(), 180.0);
        assert!(got.grid.beats.is_empty() && got.auto.is_empty() && got.hand.is_empty() && got.cue.is_none());
    }

    #[test]
    fn a_sticks_records_have_their_own_ids() {
        let a = crate::records::usb_id("HIHIHI", 1);
        assert!(a < -(1i64 << 32), "clear of the house's and the synth's");
        assert_eq!(a, crate::records::usb_id("HIHIHI", 1), "the same each time it is plugged in");
        assert_ne!(a, crate::records::usb_id("HIHIHI", 2));
        assert_ne!(a, crate::records::usb_id("OTHER", 1));
        assert!(crate::records::usb_id("X", u32::MAX) < 0);
    }
}
