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
}

impl Default for Library {
    fn default() -> Self {
        Library { shelf: Shelf::All, rows: vec![], total: 0, loading: false, playlists: vec![], signing_in: false, error: None }
    }
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
    Shelf { turn: u64, rows: Result<(Vec<Record>, i64), String> },
    Playlists(Result<Vec<PlaylistSummary>, String>),
    Analysed { slot: usize, turn: u64, result: Result<Box<Analysed>, String> },
    /// A record's cover, as the stage's cover ground takes it (None: none to be had).
    Cover { slot: usize, turn: u64, id: i64, cover: Option<Picture> },
    LoadFailed { slot: usize, turn: u64, why: String },
    /// A deck's stems: decoded onto a source, or where they are instead (parts.rs).
    Stems { slot: usize, turn: u64, got: crate::parts::Got },
}

pub(crate) fn sign_in(tx: &Sender<Done>, server: String, user: String, password: String) {
    let tx = tx.clone();
    thread::spawn(move || {
        let _ = tx.send(Done::SignedIn(House::sign_in(&server, &user, &password).map(Box::new).map_err(|e| e.to_string())));
    });
}

/// The shelf's first page (200 records).
pub(crate) fn fetch_shelf(tx: &Sender<Done>, house: &House, shelf: Shelf, turn: u64) {
    let (tx, house) = (tx.clone(), house.clone());
    thread::spawn(move || {
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
        }
        .map(|(tracks, total)| (tracks.iter().map(Record::from_house).collect(), total))
        .map_err(|e| e.to_string());
        let _ = tx.send(Done::Shelf { turn, rows });
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
