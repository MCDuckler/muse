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
}

impl Default for Library {
    fn default() -> Self {
        Library { shelf: Shelf::All, rows: vec![], total: 0, loading: false, playlists: vec![], signing_in: false, error: None, notes: Default::default(), checked: Default::default() }
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
            Shelf::Queue => Ok((vec![], 0)),
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
    Ok(Analysed { grid: a.grid(), timing: a.timing(), auto: a.auto_pads(), hand, camelot: a.camelot.clone(), bpm: a.bpm, vocals })
}
