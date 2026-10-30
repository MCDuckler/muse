//! The house: the WetOwl server the Desk plays from. Sign-in (or the WetOwl app's own,
//! on this computer), the library, search, playlists; a record's analysis as a beat grid
//! and the booth's pads; the pads a hand set; the audio, kept in a cache.
//!
//! Blocking calls (ureq): the Desk makes them on its worker threads, never the UI's.
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use wo_booth::{Grid, PadKind};

#[derive(Debug)]
pub enum Error {
    /// The house said no (401: the sign-in is gone).
    Status(u16),
    /// The house could not be reached, or answered nonsense.
    Net(String),
    Io(std::io::Error),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Status(401) => write!(f, "the sign-in is no longer good"),
            Error::Status(404) => write!(f, "the house doesn't have that (or it isn't ready)"),
            Error::Status(c) => write!(f, "the house said {c}"),
            Error::Net(e) => write!(f, "can't reach the house: {e}"),
            Error::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<ureq::Error> for Error {
    fn from(e: ureq::Error) -> Self {
        match e {
            ureq::Error::StatusCode(c) => Error::Status(c),
            e => Error::Net(e.to_string()),
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

pub type Result<T> = std::result::Result<T, Error>;

/// A record as the house lists it.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Track {
    pub id: i64,
    pub title: String,
    #[serde(default)]
    pub artists: Vec<String>,
    #[serde(default)]
    pub album: Option<String>,
    #[serde(default)]
    pub bpm: Option<f64>,
    #[serde(default)]
    pub duration_ms: Option<i64>,
    /// "ready" when its audio is on the house.
    #[serde(default)]
    pub state: String,
}

impl Track {
    pub fn ready(&self) -> bool {
        self.state == "ready"
    }

    pub fn artist(&self) -> String {
        self.artists.join(", ")
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct Page {
    pub items: Vec<Track>,
    pub total: i64,
    pub offset: i64,
}

/// A playlist as the house lists them (its records counted, not included).
#[derive(Clone, Debug, Deserialize)]
pub struct PlaylistSummary {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub kind: Option<String>,
    /// How many records.
    #[serde(default)]
    pub items: i64,
    #[serde(default)]
    pub pinned: Option<bool>,
}

/// One playlist, its records with it.
#[derive(Clone, Debug, Deserialize)]
pub struct Playlist {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub items: Vec<Track>,
}

/// The house's analysis of a record (GET /tracks/{id}/analysis?structure=1), the parts
/// the booth plays by.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Analysis {
    #[serde(default)]
    pub bpm: Option<f64>,
    /// Beat times, ms.
    #[serde(default)]
    pub beats: Vec<i64>,
    /// Which beat is a bar's first.
    #[serde(default)]
    pub bar_starts_on: Option<usize>,
    #[serde(default)]
    pub camelot: Option<String>,
    #[serde(default)]
    pub drops: Vec<i64>,
    #[serde(default)]
    pub cues: Cues,
    #[serde(default)]
    pub structure: Option<Structure>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Cues {
    pub first_downbeat_ms: Option<i64>,
    pub mix_in_ms: Option<i64>,
    pub mix_out_ms: Option<i64>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Structure {
    #[serde(default)]
    pub drops_ms: Vec<i64>,
    #[serde(default)]
    pub breakdowns_ms: Vec<i64>,
}

impl Analysis {
    pub fn grid(&self) -> Grid {
        Grid::new(self.beats.iter().map(|&b| b as f64 / 1000.0).collect(), self.bar_starts_on.unwrap_or(0))
    }

    /// The booth's own pads, the v1 booth's way (auto_pads.dart): 1 where to come in, 2
    /// the first drop after that, 3 the first breakdown at least eight bars past the
    /// drop, 4 where to go out — each on a bar's one.
    pub fn auto_pads(&self) -> Vec<(usize, f64, PadKind)> {
        let g = self.grid();
        let Some(spb) = g.spb() else { return vec![] };
        let bar = 4.0 * spb;
        let on_bar = |ms: i64| -> f64 {
            let t = ms as f64 / 1000.0;
            g.next_beat(t - bar / 2.0, 4).unwrap_or(t)
        };
        let first = self.cues.first_downbeat_ms.map(on_bar).unwrap_or(0.0);
        let mix_in = self.cues.mix_in_ms.map(on_bar).unwrap_or(first);
        let drops = self.structure.as_ref().map(|s| s.drops_ms.as_slice()).filter(|d| !d.is_empty()).unwrap_or(&self.drops);
        let drop = drops.iter().map(|&d| on_bar(d)).find(|&d| d >= mix_in);
        let out = self.cues.mix_out_ms.map(on_bar);
        let mut pads = vec![(0, mix_in, PadKind::Intro)];
        if let Some(d) = drop {
            // the intro ending on the drop: one place, the drop's
            if (d - mix_in).abs() < bar / 2.0 {
                pads.clear();
            }
            pads.push((1, d, PadKind::Drop));
            let breaks = self.structure.as_ref().map(|s| s.breakdowns_ms.as_slice()).unwrap_or(&[]);
            if let Some(b) = breaks.iter().map(|&b| on_bar(b)).find(|&b| b >= d + 8.0 * bar && out.is_none_or(|o| b < o)) {
                pads.push((2, b, PadKind::Break));
            }
        }
        if let Some(o) = out.filter(|&o| o > first) {
            pads.push((3, o, PadKind::Out));
        }
        pads
    }
}

/// The pads a hand set (Some(ms)) or cleared (None) on a record, by index 0..8.
pub type HandPads = Vec<(usize, Option<f64>)>;

#[derive(Deserialize)]
struct CuesRow {
    #[serde(default)]
    pads: std::collections::BTreeMap<String, Option<i64>>,
}

/// Where a sign-in is kept between runs.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Session {
    pub server: String,
    pub token: String,
    #[serde(default)]
    pub user: Option<String>,
}

impl Session {
    fn file() -> Option<PathBuf> {
        dirs::config_dir().map(|d| d.join("wetowl-desk").join("session.json"))
    }

    /// The Desk's own saved sign-in.
    pub fn saved() -> Option<Session> {
        serde_json::from_str(&std::fs::read_to_string(Self::file()?).ok()?).ok()
    }

    pub fn save(&self) -> Result<()> {
        let file = Self::file().ok_or_else(|| Error::Net("no config folder".into()))?;
        std::fs::create_dir_all(file.parent().unwrap())?;
        std::fs::write(&file, serde_json::to_string_pretty(self).unwrap())?;
        Ok(())
    }

    pub fn forget() {
        if let Some(f) = Self::file() {
            let _ = std::fs::remove_file(f);
        }
    }

    /// The WetOwl app's sign-in on this computer (its shared_preferences.json), if any.
    pub fn from_wetowl_app() -> Option<Session> {
        let prefs = app_folder()?.join("shared_preferences.json");
        let v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(prefs).ok()?).ok()?;
        Some(Session {
            server: v.get("flutter.muse.server")?.as_str()?.trim_end_matches('/').to_owned(),
            token: v.get("flutter.muse.token")?.as_str()?.to_owned(),
            user: None,
        })
    }
}

/// The WetOwl app's folder on this computer (its fetched records, its sign-in).
pub fn app_folder() -> Option<PathBuf> {
    let candidates = if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(|a| PathBuf::from(a).join("io.wetowl").join("muse"))
    } else if cfg!(target_os = "macos") {
        dirs::home_dir().map(|h| h.join("Library/Application Support/io.wetowl.muse"))
    } else {
        dirs::data_dir().map(|d| d.join("io.wetowl.muse"))
    };
    candidates.filter(|p| p.is_dir())
}

/// A signed-in connection to the house.
#[derive(Clone)]
pub struct House {
    pub session: Session,
    agent: ureq::Agent,
}

pub const DEFAULT_SERVER: &str = "https://89-58-49-140.nip.io";

impl House {
    pub fn new(session: Session) -> House {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .user_agent("WetOwl Desk")
            .build()
            .into();
        House { session, agent }
    }

    /// Signs in with a name and password; the session is saved for next time.
    pub fn sign_in(server: &str, user: &str, password: &str) -> Result<House> {
        let server = server.trim().trim_end_matches('/').to_owned();
        let agent = House::new(Session { server: server.clone(), token: String::new(), user: None }).agent;
        let device = format!("WetOwl Desk ({})", std::env::consts::OS);
        let mut resp = agent
            .post(format!("{server}/auth/login"))
            .send_form([("user", user), ("password", password), ("device", device.as_str()), ("platform", "desk")])?;
        let v: serde_json::Value = resp.body_mut().read_json()?;
        let token = v.get("token").and_then(|t| t.as_str()).ok_or_else(|| Error::Net("no token in the answer".into()))?;
        let session = Session { server, token: token.to_owned(), user: Some(user.to_owned()) };
        session.save()?;
        Ok(House::new(session))
    }

    fn get(&self, path: &str) -> ureq::RequestBuilder<ureq::typestate::WithoutBody> {
        self.agent.get(format!("{}{path}", self.session.server)).header("Authorization", &format!("Bearer {}", self.session.token))
    }

    fn json<T: serde::de::DeserializeOwned>(&self, path: &str) -> Result<T> {
        Ok(self.get(path).call()?.body_mut().read_json()?)
    }

    /// The library, `sort` one of added/title/artist/album/duration/tempo; ready records only.
    pub fn tracks(&self, sort: &str, offset: i64, limit: i64) -> Result<Page> {
        self.json(&format!("/library/tracks?sort={sort}&offset={offset}&limit={limit}&ready_only=true"))
    }

    /// The house's own search (no outside services): ready records first.
    pub fn search(&self, q: &str) -> Result<Vec<Track>> {
        #[derive(Deserialize)]
        struct Found {
            #[serde(default)]
            local: Vec<Track>,
        }
        let q: String = q.bytes().map(|b| if b.is_ascii_alphanumeric() { (b as char).to_string() } else { format!("%{b:02X}") }).collect();
        let mut found: Found = self.json(&format!("/search?q={q}&limit=60&remote=false"))?;
        found.local.sort_by_key(|t| !t.ready());
        Ok(found.local)
    }

    pub fn playlists(&self) -> Result<Vec<PlaylistSummary>> {
        self.json("/playlists")
    }

    pub fn playlist(&self, id: i64) -> Result<Playlist> {
        self.json(&format!("/playlists/{id}"))
    }

    pub fn analysis(&self, id: i64) -> Result<Analysis> {
        self.json(&format!("/tracks/{id}/analysis?structure=1"))
    }

    pub fn hand_pads(&self, id: i64) -> Result<HandPads> {
        let row: CuesRow = self.json(&format!("/tracks/{id}/cues"))?;
        Ok(parse_pads(row))
    }

    /// The record's audio, from the WetOwl app's own fetched copy on this computer, else
    /// the Desk's cache, else downloaded into the cache now.
    pub fn audio(&self, id: i64) -> Result<PathBuf> {
        if let Some(local) = app_folder().map(|a| a.join("fetched").join(format!("{id}.m4a"))).filter(|p| p.exists()) {
            return Ok(local);
        }
        let cache = dirs::cache_dir().ok_or_else(|| Error::Net("no cache folder".into()))?.join("wetowl-desk").join("records");
        let file = cache.join(format!("{id}.m4a"));
        if file.exists() {
            return Ok(file);
        }
        std::fs::create_dir_all(&cache)?;
        download(self.get(&format!("/tracks/{id}/stream")).call()?, &file)?;
        Ok(file)
    }
}

/// The body into `to`, whole or not at all (a partial file never sits in the cache).
fn download(mut resp: ureq::http::Response<ureq::Body>, to: &Path) -> Result<()> {
    let part = to.with_extension("part");
    {
        let mut out = std::fs::File::create(&part)?;
        std::io::copy(&mut resp.body_mut().as_reader(), &mut out)?;
        out.flush()?;
    }
    std::fs::rename(&part, to)?;
    Ok(())
}

fn parse_pads(row: CuesRow) -> HandPads {
    row.pads
        .into_iter()
        .filter_map(|(k, v)| {
            let n: usize = k.parse().ok()?;
            (1..=8).contains(&n).then(|| (n - 1, v.map(|ms| ms as f64 / 1000.0)))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 120 bpm from 0.1 s, the bar's one on beat 2: bars at 1.1, 3.1, 5.1 …
    fn analysis() -> Analysis {
        serde_json::from_str(
            r#"{
              "bpm": 120.0, "camelot": "10B", "bar_starts_on": 2,
              "beats": [100, 600, 1100, 1600, 2100, 2600, 3100, 3600, 4100, 4600, 5100, 5600, 6100, 6600, 7100, 7600, 8100,
                        8600, 9100, 9600, 10100, 10600, 11100, 11600, 12100, 12600, 13100, 13600, 14100, 14600, 15100, 15600,
                        16100, 16600, 17100, 17600, 18100, 18600, 19100, 19600, 20100, 20600, 21100, 21600, 22100, 22600,
                        23100, 23600, 24100, 24600, 25100, 25600, 26100, 26600, 27100, 27600, 28100, 28600, 29100, 29600,
                        30100, 30600, 31100, 31600, 32100, 32600, 33100, 33600, 34100, 34600, 35100, 35600, 36100, 36600],
              "drops": [9100],
              "cues": {"first_downbeat_ms": 1100, "mix_in_ms": 5000, "mix_out_ms": 33100},
              "structure": {"drops_ms": [9100, 25100], "breakdowns_ms": [12100, 27100]},
              "anything_else": [1, 2, 3]
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn the_grid_counts_bars_from_bar_starts_on() {
        let g = analysis().grid();
        assert!((g.spb().unwrap() - 0.5).abs() < 1e-9);
        assert_eq!(g.next_beat(1.0, 4), Some(1.1));
        assert_eq!(g.next_beat(1.2, 4), Some(3.1));
    }

    #[test]
    fn auto_pads_the_v1_way() {
        let pads = analysis().auto_pads();
        let at = |n: usize| pads.iter().find(|p| p.0 == n).map(|p| p.1);
        assert_eq!(at(0), Some(5.1), "IN: mix in, on its bar");
        assert_eq!(at(1), Some(9.1), "DROP: the first drop after mixing in");
        assert_eq!(at(2), Some(27.1), "BREAK: the first breakdown 8 bars (16 s) past the drop; 12.1 is too near");
        assert_eq!(at(3), Some(33.1), "OUT: mix out");
    }

    #[test]
    fn hand_pads_set_and_cleared() {
        let row: CuesRow = serde_json::from_str(r#"{"pads": {"2": 41000, "5": null, "9": 1, "x": 3}}"#).unwrap();
        assert_eq!(parse_pads(row), vec![(1, Some(41.0)), (4, None)]);
    }

    #[test]
    fn a_track_reads_what_it_needs_and_skips_the_rest() {
        let t: Track = serde_json::from_str(
            r#"{"id": 7, "title": "Watch This", "artists": ["SHVDZ", "Ctrl"], "bpm": 155.01, "duration_ms": 152000,
                "state": "ready", "cover_url": "/x", "gain_db": -3.1}"#,
        )
        .unwrap();
        assert!(t.ready());
        assert_eq!(t.artist(), "SHVDZ, Ctrl");
    }
}
