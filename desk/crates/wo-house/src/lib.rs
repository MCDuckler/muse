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
    /// Where its cover is (None: it has none), and the cover's colour (`#rrggbb`).
    #[serde(default)]
    pub cover_url: Option<String>,
    #[serde(default)]
    pub cover_color: Option<String>,
    /// How loud the box measured it (EBU R128): the gain to the house's reference (−14
    /// LUFS), its true peak (dBFS) — how far it can be turned up before it clips.
    #[serde(default)]
    pub gain_db: Option<f64>,
    #[serde(default)]
    pub true_peak_db: Option<f64>,
}

impl Track {
    pub fn ready(&self) -> bool {
        self.state == "ready"
    }

    pub fn artist(&self) -> String {
        self.artists.join(", ")
    }

    /// The cover's colour as 0xRRGGBB.
    pub fn cover_rgb(&self) -> Option<u32> {
        let c = self.cover_color.as_deref()?.trim().trim_start_matches('#');
        (c.len() == 6).then(|| u32::from_str_radix(c, 16).ok()).flatten()
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

/// A record that goes with others (GET /recommend): where it is (`library`: this person's,
/// `house`: here, not theirs yet), why, the record.
#[derive(Clone, Debug, Deserialize)]
pub struct Pick {
    #[serde(default, rename = "where")]
    pub where_: String,
    #[serde(default)]
    pub why: String,
    #[serde(default)]
    pub track: Option<Track>,
}

/// A record to check by ear, and what was said of it.
#[derive(Clone, Debug, Deserialize)]
pub struct CueCheck {
    pub track: Track,
    #[serde(default)]
    pub grid: Option<String>,
    #[serde(default)]
    pub checked_at: Option<String>,
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
    pub duration_ms: Option<i64>,
    /// How loud each bar is, 0..255 (by the downbeats), the song's shape.
    #[serde(default)]
    pub energy: Vec<i64>,
    /// "cold", "fade" or "".
    #[serde(default)]
    pub ends: String,
    #[serde(default)]
    pub four_bars: Vec<i64>,
    #[serde(default)]
    pub phrases: Vec<i64>,
    #[serde(default)]
    pub hand_cues: Option<HandCues>,
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
    pub key_confidence: Option<f64>,
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
    #[serde(default)]
    pub sound_end_ms: Option<i64>,
}

/// Where a hand said a record leaves and comes in.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct HandCues {
    pub out_ms: Option<i64>,
    pub in_ms: Option<i64>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct SectionRow {
    #[serde(default)]
    pub label: String,
    pub start_ms: i64,
    pub end_ms: i64,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct PlaceRow {
    pub ms: i64,
    #[serde(default)]
    pub why: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Places {
    #[serde(default)]
    pub outs: Vec<PlaceRow>,
    #[serde(default)]
    pub ins: Vec<PlaceRow>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Structure {
    #[serde(default)]
    pub drops_ms: Vec<i64>,
    #[serde(default)]
    pub breakdowns_ms: Vec<i64>,
    #[serde(default)]
    pub sections: Vec<SectionRow>,
    #[serde(default)]
    pub cues: Option<Places>,
    #[serde(default)]
    pub bars_ms: Vec<i64>,
    #[serde(default)]
    pub mix_db: Vec<f64>,
}

impl Analysis {
    /// Everything the booth mixes by, in seconds (wo_booth::Timing).
    pub fn timing(&self) -> wo_booth::Timing {
        let s = |ms: i64| ms as f64 / 1000.0;
        let grid = self.grid();
        let mut t = wo_booth::Timing::from_grid(grid, self.duration_ms.map(s).unwrap_or(0.0));
        t.bpm = self.bpm.or(t.bpm);
        t.camelot = self.camelot.clone();
        t.key_confidence = self.key_confidence.unwrap_or(0.0);
        t.ends = self.ends.clone();
        t.first_downbeat = self.cues.first_downbeat_ms.map(s).or(t.first_downbeat);
        t.mix_in = self.cues.mix_in_ms.map(s);
        t.mix_out = self.cues.mix_out_ms.map(s);
        t.sound_end = self.cues.sound_end_ms.map(s);
        if !self.four_bars.is_empty() {
            t.markers = self.four_bars.iter().map(|&m| s(m)).collect();
        }
        t.phrases = self.phrases.iter().map(|&m| s(m)).collect();
        t.energy = self.energy.iter().map(|&e| e.clamp(0, 255) as u8).collect();
        let st = self.structure.clone().unwrap_or_default();
        let drops = if st.drops_ms.is_empty() { &self.drops } else { &st.drops_ms };
        t.drops = drops.iter().map(|&m| s(m)).collect();
        t.sections = st.sections.iter().map(|x| wo_booth::mix::Section { label: x.label.clone(), start: s(x.start_ms), end: s(x.end_ms) }).collect();
        let places = |v: &[PlaceRow]| v.iter().map(|p| wo_booth::mix::Place { at: s(p.ms), why: p.why.clone() }).collect();
        if let Some(c) = &st.cues {
            t.outs = places(&c.outs);
            t.ins = places(&c.ins);
        }
        t.bars_db = st.bars_ms.iter().zip(&st.mix_db).map(|(&b, &d)| (s(b), d)).collect();
        if let Some(h) = &self.hand_cues {
            t.hand_out = h.out_ms.map(s);
            t.hand_in = h.in_ms.map(s);
        }
        t
    }

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

/// The Desk's own folders: as `dirs` gives them, except that XDG_CONFIG_HOME, XDG_CACHE_HOME
/// and XDG_DATA_HOME (absolute) win on every system. On Linux `dirs` reads them itself; on a
/// Mac or Windows it would not, and tests and headless runs that point them at a scratch
/// folder would read and write the computer's real ones (a CI runner's session kept by one
/// test, found by the next).
pub mod folders {
    use std::path::PathBuf;

    fn xdg(var: &str) -> Option<PathBuf> {
        std::env::var_os(var).map(PathBuf::from).filter(|p| p.is_absolute())
    }

    pub fn config() -> Option<PathBuf> {
        xdg("XDG_CONFIG_HOME").or_else(dirs::config_dir)
    }

    pub fn cache() -> Option<PathBuf> {
        xdg("XDG_CACHE_HOME").or_else(dirs::cache_dir)
    }

    pub fn data() -> Option<PathBuf> {
        xdg("XDG_DATA_HOME").or_else(dirs::data_dir)
    }
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
        folders::config().map(|d| d.join("wetowl-desk").join("session.json"))
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
        if cfg!(target_os = "macos") {
            return Self::from_mac_defaults();
        }
        let prefs = app_folder()?.join("shared_preferences.json");
        let v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(prefs).ok()?).ok()?;
        Some(Session {
            server: v.get("flutter.muse.server")?.as_str()?.trim_end_matches('/').to_owned(),
            token: v.get("flutter.muse.token")?.as_str()?.to_owned(),
            user: None,
        })
    }

    /// On a Mac the app's preferences are the user defaults of its bundle id
    /// (io.wetowl.muse), not a file: `defaults read` gives them.
    fn from_mac_defaults() -> Option<Session> {
        let read = |key: &str| -> Option<String> {
            let out = std::process::Command::new("/usr/bin/defaults").args(["read", "io.wetowl.muse", key]).output().ok()?;
            let v = String::from_utf8(out.stdout).ok()?.trim().to_owned();
            (out.status.success() && !v.is_empty()).then_some(v)
        };
        Some(Session {
            server: read("flutter.muse.server")?.trim_end_matches('/').to_owned(),
            token: read("flutter.muse.token")?,
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

    /// A record's cover, as the file is (a JPEG, a PNG…).
    pub fn cover(&self, id: i64) -> Result<Vec<u8>> {
        let mut r = self.get(&format!("/tracks/{id}/cover?size=lg")).call()?;
        Ok(r.body_mut().with_config().limit(16 << 20).read_to_vec()?)
    }

    /// A record's small cover (the house's `sm`: rows and sleeves), as the file is.
    pub fn cover_small(&self, id: i64) -> Result<Vec<u8>> {
        let mut r = self.get(&format!("/tracks/{id}/cover?size=sm")).call()?;
        Ok(r.body_mut().with_config().limit(4 << 20).read_to_vec()?)
    }

    pub fn analysis(&self, id: i64) -> Result<Analysis> {
        self.json(&format!("/tracks/{id}/analysis?structure=1"))
    }

    fn post_json(&self, path: &str, body: &serde_json::Value) -> Result<serde_json::Value> {
        let mut r = self
            .agent
            .post(format!("{}{path}", self.session.server))
            .header("Authorization", &format!("Bearer {}", self.session.token))
            .send_json(body)?;
        Ok(r.body_mut().read_json()?)
    }

    /// Keeps a hand's cues on a record (PUT /tracks/{id}/cues): `out_ms` / `in_ms`
    /// (null clears one), `pads` {"1": ms | null | "auto"} — only what the body names
    /// changes.
    pub fn set_cues(&self, id: i64, body: &serde_json::Value) -> Result<()> {
        self.agent
            .put(format!("{}/tracks/{id}/cues", self.session.server))
            .header("Authorization", &format!("Bearer {}", self.session.token))
            .send_json(body)?;
        Ok(())
    }

    // ------------------------------------------------------------- the show's shared sets

    fn authed(&self, b: ureq::RequestBuilder<ureq::typestate::WithBody>) -> ureq::RequestBuilder<ureq::typestate::WithBody> {
        b.header("Authorization", &format!("Bearer {}", self.session.token))
    }

    /// The show's shared sets, every account's, the newest saved first (each: id, name, doc,
    /// rev, owner, mine, updated_by, updated_at).
    pub fn show_snapshots(&self) -> Result<Vec<serde_json::Value>> {
        let v: serde_json::Value = self.json("/booth/show/snapshots")?;
        Ok(v.get("snapshots").and_then(|s| s.as_array()).cloned().unwrap_or_default())
    }

    /// A set shared with everyone: the one kept, as the list has it.
    pub fn share_show_snapshot(&self, name: &str, doc: &serde_json::Value) -> Result<serde_json::Value> {
        self.post_json("/booth/show/snapshots", &serde_json::json!({"name": name, "doc": doc}))
    }

    /// A shared set saved over — if `rev` is still its revision. Stale: Ok(Err(it as kept)).
    pub fn save_show_snapshot(&self, id: i64, doc: &serde_json::Value, rev: i64, name: Option<&str>) -> Result<std::result::Result<serde_json::Value, serde_json::Value>> {
        let mut body = serde_json::json!({"doc": doc, "rev": rev});
        if let Some(n) = name {
            body["name"] = n.into();
        }
        let mut r = self
            .authed(self.agent.put(format!("{}/booth/show/snapshots/{id}", self.session.server)))
            .config()
            .http_status_as_error(false)
            .build()
            .send_json(&body)?;
        let status = r.status().as_u16();
        let v: serde_json::Value = r.body_mut().read_json().unwrap_or_default();
        match status {
            200..=299 => Ok(Ok(v)),
            409 => Ok(Err(v.get("detail").cloned().unwrap_or(v))),
            c => Err(Error::Status(c)),
        }
    }

    /// A set this account shared, taken away from everyone.
    pub fn unshare_show_snapshot(&self, id: i64) -> Result<()> {
        self.agent.delete(format!("{}/booth/show/snapshots/{id}", self.session.server)).header("Authorization", &format!("Bearer {}", self.session.token)).call()?;
        Ok(())
    }

    /// What this person thought of the booth's mixes, newest first (the thumbs, the hands
    /// on the plan): for the planner's taste.
    pub fn feedback_list(&self, limit: u32) -> Result<Vec<wo_booth::taste::FeedbackRow>> {
        #[derive(Deserialize)]
        struct Row {
            #[serde(default)]
            event: String,
            #[serde(default)]
            from_track: Option<i64>,
            #[serde(default)]
            to_track: Option<i64>,
            #[serde(default)]
            kind: Option<String>,
            #[serde(default)]
            rating: Option<f64>,
            #[serde(default)]
            detail: Option<serde_json::Value>,
        }
        #[derive(Deserialize)]
        struct All {
            #[serde(default)]
            feedback: Vec<Row>,
        }
        let all: All = self.json(&format!("/booth/feedback?limit={limit}"))?;
        Ok(all
            .feedback
            .into_iter()
            .map(|r| wo_booth::taste::FeedbackRow {
                event: r.event,
                from_track: r.from_track,
                to_track: r.to_track,
                kind: r.kind,
                rating: r.rating,
                was: r.detail.as_ref().and_then(|d| d.get("was")).and_then(|w| w.as_str()).map(str::to_owned),
            })
            .collect())
    }

    /// What the booth did between two records, or what was thought of it: kept by the
    /// house for the planner to learn from (POST /booth/feedback).
    pub fn feedback(&self, body: &serde_json::Value) -> Result<()> {
        self.post_json("/booth/feedback", body).map(|_| ())
    }

    /// Records that go with `seeds` (GET /recommend): `fresh` 0..1 how much of the answer is
    /// not this person's already (0 theirs, 1 new to them); never one of `exclude`. Only the
    /// ones the house has (a record found elsewhere is not one the Desk can play).
    pub fn recommend(&self, seeds: &[i64], exclude: &[i64], fresh: f64, limit: u32) -> Result<Vec<Pick>> {
        #[derive(Deserialize)]
        struct All {
            #[serde(default)]
            items: Vec<Pick>,
        }
        let join = |v: &[i64]| v.iter().map(|i| i.to_string()).collect::<Vec<_>>().join("%2C");
        let mut path = format!("/recommend?seeds={}&fresh={fresh}&limit={limit}", join(seeds));
        if !exclude.is_empty() {
            path.push_str(&format!("&exclude={}", join(exclude)));
        }
        let all: All = self.json(&path)?;
        Ok(all.items.into_iter().filter(|p| p.track.is_some()).collect())
    }

    /// Not for me: a pick never offered to this person again.
    pub fn dismiss_pick(&self, track_id: i64) -> Result<()> {
        self.post_json("/recommend/dismiss", &serde_json::json!({"track_id": track_id})).map(|_| ())
    }

    /// Records to check by ear (GET /booth/check): the same list each time, spread over the
    /// tempos, each with what was said of it.
    pub fn cue_checks(&self, n: u32) -> Result<Vec<CueCheck>> {
        #[derive(Deserialize)]
        struct All {
            #[serde(default)]
            items: Vec<CueCheck>,
        }
        Ok(self.json::<All>(&format!("/booth/check?n={n}"))?.items)
    }

    /// One checked: what its grid is like (ok, double, half, off, one, other), and where the
    /// pads were left (pad → ms, and whether the booth placed it).
    pub fn check_cues(&self, id: i64, grid: &str, pads: &[(usize, i64, bool)]) -> Result<()> {
        let pads: serde_json::Map<String, serde_json::Value> = pads.iter().map(|(n, ms, auto)| (n.to_string(), serde_json::json!({"ms": ms, "auto": auto}))).collect();
        self.agent
            .put(format!("{}/booth/check/{id}", self.session.server))
            .header("Authorization", &format!("Bearer {}", self.session.token))
            .send_json(serde_json::json!({"grid": grid, "pads": pads}))?;
        Ok(())
    }

    /// Checked again: what was said of it taken back.
    pub fn uncheck_cues(&self, id: i64) -> Result<()> {
        self.agent.delete(format!("{}/booth/check/{id}", self.session.server)).header("Authorization", &format!("Bearer {}", self.session.token)).call()?;
        Ok(())
    }

    /// The records in the library that would follow `from` best (GET /booth/partners),
    /// coarse, best first; `in_key`: only those in a key that mixes with it.
    pub fn partners(&self, from: i64, exclude: &[i64], limit: u32, in_key: bool) -> Result<Vec<(Track, f64, String)>> {
        #[derive(Deserialize)]
        struct P {
            track: Track,
            #[serde(default)]
            fit: f64,
            #[serde(default)]
            why: String,
        }
        #[derive(Deserialize)]
        struct All {
            #[serde(default)]
            partners: Vec<P>,
        }
        let ex: Vec<String> = exclude.iter().map(|i| i.to_string()).collect();
        let all: All = self.json(&format!("/booth/partners?from_track={from}&limit={limit}&exclude={}{}", ex.join("%2C"), if in_key { "&in_key=true" } else { "" }))?;
        Ok(all.partners.into_iter().map(|p| (p.track, p.fit, p.why)).collect())
    }

    /// Records added to one of this person's playlists (POST /playlists/{id}/items).
    pub fn add_to_playlist(&self, id: i64, tracks: &[i64]) -> Result<()> {
        self.post_json(&format!("/playlists/{id}/items"), &serde_json::json!({ "track_ids": tracks })).map(|_| ())
    }

    /// A set built by the house from a pool to a shape (POST /booth/set): the raw
    /// answer (`slots`, `stats`, `curve`).
    pub fn build_set(&self, body: &serde_json::Value) -> Result<serde_json::Value> {
        self.post_json("/booth/set", body)
    }

    /// The records that would sit best in one slot after `body.prev` (POST /booth/slot:
    /// the set builder's answer, steered by the shape's offset and anchor), best first.
    pub fn slot_choices(&self, body: &serde_json::Value) -> Result<Vec<SlotChoice>> {
        let v = self.post_json("/booth/slot", body)?;
        let rows = v.get("choices").and_then(|c| c.as_array()).cloned().unwrap_or_default();
        Ok(rows.into_iter().filter_map(|c| serde_json::from_value(c).ok()).collect())
    }

    /// Where the voice is in a record, a bar at a time, and its hook (the house's vocal
    /// map; v1's VocalMap).
    pub fn vocals(&self, id: i64) -> Result<wo_booth::planner::VocalMap> {
        #[derive(Deserialize)]
        struct Hook {
            #[serde(default)]
            text: String,
            #[serde(default)]
            at: Vec<i64>,
        }
        #[derive(Deserialize)]
        struct Row {
            #[serde(default)]
            bars: Option<Vec<i64>>,
            #[serde(default)]
            hook: Option<Hook>,
        }
        let r: Row = self.json(&format!("/tracks/{id}/vocals"))?;
        Ok(wo_booth::planner::VocalMap {
            bars: r.bars.map(|b| b.into_iter().map(|v| v.clamp(0, 255) as u8).collect()),
            hook: r.hook.map(|h| (h.text, h.at.into_iter().map(|ms| ms as f64 / 1000.0).collect())),
        })
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
        let cache = folders::cache().ok_or_else(|| Error::Net("no cache folder".into()))?.join("wetowl-desk").join("records");
        let file = cache.join(format!("{id}.m4a"));
        if file.exists() {
            return Ok(file);
        }
        std::fs::create_dir_all(&cache)?;
        download(self.get(&format!("/tracks/{id}/stream")).call()?, &file)?;
        Ok(file)
    }
}

/// One record the set builder would put in a slot, and its words.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct SlotChoice {
    pub track: Track,
    #[serde(default)]
    pub fit_in: Option<f64>,
    #[serde(default)]
    pub why: String,
    #[serde(default)]
    pub energy: Option<f64>,
}

/// Whether a record's stems are here to play.
#[derive(Clone, Debug, PartialEq)]
pub enum Stems {
    /// On this computer (the WetOwl app's, or the Desk's cache, or fetched just now).
    Ready(PathBuf),
    /// Being made by a computer in the pool (asking queued it): ask again in a while.
    Making,
    /// Not for this record (too long to take apart, or no such record).
    Never,
}

/// The stems' file name, as the WetOwl app and the house name them (separator v2).
pub fn stems_file(id: i64) -> String {
    format!("{id}-stems-v2.opus")
}

impl House {
    /// A record's stems: drums, bass and the rest, voice, as one six-channel Opus file
    /// (see wo_decode::opus). From the WetOwl app's own copy on this computer, else the
    /// Desk's cache, else the house — which answers 202 while the pool makes them (the
    /// asking queues them; `soon`: asked ahead, queued behind records wanted now).
    pub fn stems(&self, id: i64, soon: bool) -> Result<Stems> {
        let name = stems_file(id);
        if let Some(local) = app_folder().map(|a| a.join("stems").join(&name)).filter(|p| p.exists()) {
            return Ok(Stems::Ready(local));
        }
        let cache = folders::cache().ok_or_else(|| Error::Net("no cache folder".into()))?.join("wetowl-desk").join("stems");
        let file = cache.join(&name);
        if file.exists() {
            return Ok(Stems::Ready(file));
        }
        let path = if soon { format!("/tracks/{id}/stem/stems?soon=true") } else { format!("/tracks/{id}/stem/stems") };
        let resp = match self.get(&path).call() {
            Ok(r) => r,
            Err(ureq::Error::StatusCode(404)) => return Ok(Stems::Never),
            Err(e) => return Err(e.into()),
        };
        if resp.status().as_u16() == 202 {
            return Ok(Stems::Making);
        }
        std::fs::create_dir_all(&cache)?;
        download(resp, &file)?;
        Ok(Stems::Ready(file))
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
        assert_eq!(t.cover_url.as_deref(), Some("/x"));
        assert_eq!(t.cover_rgb(), None);
        let t: Track = serde_json::from_str(r##"{"id": 8, "title": "x", "cover_color": "#3060C0"}"##).unwrap();
        assert_eq!(t.cover_rgb(), Some(0x3060c0));
    }
}
