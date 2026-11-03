//! The Stage: the show in a window and a process of its own. For now that is the v1
//! app's stage window (`wetowl --stage <url>`), which directs the show itself over the
//! Desk's decks (app/lib/src/state/show/desk_show_source.dart); the Desk serves the
//! wire (wo-wire), starts the window, sends it a frame each tick and keeps its picture
//! for the booth.
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub use wo_wire::{Hand, Screen, SetRef, Shown, Thumb};

/// Frames a second to the stage (it draws at its own rate, carrying the decks on
/// between them).
const EVERY: Duration = Duration::from_millis(16);
/// A window started that has not connected by then is given up on.
const PATIENCE: Duration = Duration::from_secs(40);

#[derive(Default)]
pub(crate) struct Stage {
    wire: Option<wo_wire::Server>,
    child: Option<Child>,
    started: Option<Instant>,
    last: Option<Instant>,
    /// The engine's clock the sound was read up to.
    pub(crate) heard_to: Option<f64>,
    trouble: Option<String>,
    blackout: bool,
    freeze: bool,
    /// The screen kept (read once, written on a change).
    kept: std::cell::OnceCell<Kept>,
    /// Since when a stage has been reading.
    reading: Option<Instant>,
    /// What a stage is told first: the Desk's house, once signed in.
    hello: Option<String>,
    /// The Desk's director (ShowWire v2), from the first frame a stage reads.
    show: Option<crate::show::Show>,
    /// What each deck's facts were made from, to make them again only on a change.
    facts_key: [Option<FactsKey>; 2],
    /// Each deck's cover as the wire carries it (wo_wire::cover), for stages now and to come.
    covers: [Option<Vec<u8>>; 2],
}

/// A deck's record and how much of its timing is known.
pub(crate) type FactsKey = (i64, String, usize, usize, usize, usize, usize);

/// A stage reading this long without saying what it shows is one from before the Desk
/// (a WetOwl app whose stage does not direct the show itself).
const UNTOLD: Duration = Duration::from_secs(20);

/// The stage as the booth shows it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StageView {
    /// Stages reading the Desk.
    pub stages: usize,
    /// A window started that is not reading yet.
    pub starting: bool,
    /// Why there is none, in words.
    pub trouble: Option<String>,
    /// The scene on, and whether a hand holds it.
    pub scene: Option<String>,
    /// A stage reads but says nothing of what it shows: an older WetOwl app's.
    pub untold: bool,
    pub held: bool,
    pub blackout: bool,
    pub freeze: bool,
    /// All the stage told of itself (its look, holds, sets, screens, what it said).
    pub told: Shown,
    /// The screen the Desk keeps the stage on (full screen there when it opens).
    pub kept_screen: Option<String>,
    /// The stage is the Rust one (the Desk directs), asked for; and whether it is here.
    pub rust: bool,
    pub rust_here: bool,
    /// Why the director chose the scene on, in words (the Rust stage's show).
    pub why: Option<String>,
}

/// What the Desk keeps of the stage between runs: the screen it fills.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
struct Kept {
    screen: Option<String>,
    /// The Rust stage rather than the WetOwl app's.
    #[serde(default)]
    rust: bool,
}

impl Kept {
    fn file() -> Option<PathBuf> {
        dirs::config_dir().map(|d| d.join("wetowl-desk").join("stage.json"))
    }

    fn read() -> Kept {
        Self::file().and_then(|f| std::fs::read_to_string(f).ok()).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
    }

    fn save(&self) {
        if let Some(f) = Self::file() {
            let _ = std::fs::create_dir_all(f.parent().unwrap());
            let _ = std::fs::write(f, serde_json::to_string_pretty(self).unwrap());
        }
    }
}

/// The Rust stage's program: beside the Desk's own (on a Mac, in its bundle's MacOS).
pub fn rust_program() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("WO_STAGE_RUST").filter(|p| !p.is_empty() && p != "1") {
        return Some(PathBuf::from(p));
    }
    let name = if cfg!(windows) { "wetowl-stage.exe" } else { "wetowl-stage" };
    std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join(name))).filter(|p| p.is_file())
}

/// The stage window's program: WO_STAGE, else the stage installed beside the Desk
/// (stage/wetowl), else the WetOwl app's own (Linux: ~/.local/opt/wetowl).
///
/// On a Mac the stage is the WetOwl app carried inside the Desk's bundle
/// (WetOwl Desk.app/Contents/Helpers/WetOwl.app, see deploy/macos/bundle.sh), else a
/// WetOwl.app in ~/Applications or /Applications.
pub fn program() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("WO_STAGE").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p));
    }
    let exe_dir = std::env::current_exe().ok().and_then(|e| e.parent().map(PathBuf::from));
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let candidates: Vec<PathBuf> = if cfg!(target_os = "macos") {
        let inside = "WetOwl.app/Contents/MacOS/WetOwl";
        // exe_dir is …/WetOwl Desk.app/Contents/MacOS
        let helpers = exe_dir.as_ref().and_then(|d| d.parent()).map(|c| c.join("Helpers").join(inside));
        let mine = home.map(|h| h.join("Applications").join(inside));
        [helpers, mine, Some(PathBuf::from("/Applications").join(inside))].into_iter().flatten().collect()
    } else {
        let name = if cfg!(windows) { "wetowl.exe" } else { "wetowl" };
        let beside = exe_dir.map(|d| d.join("stage").join(name));
        let app = home.map(|h| h.join(".local/opt/wetowl").join(name)).filter(|_| cfg!(target_os = "linux"));
        [beside, app].into_iter().flatten().collect()
    };
    candidates.into_iter().find(|p| p.is_file())
}

impl Stage {
    fn wire(&mut self) -> Option<&wo_wire::Server> {
        if self.wire.is_none() {
            match wo_wire::Server::open() {
                Ok(s) => {
                    if let Some(h) = &self.hello {
                        s.set_hello(h.clone());
                    }
                    for (i, c) in self.covers.iter().enumerate() {
                        if let Some(c) = c {
                            s.keep_binary(["cover.A", "cover.B"][i], c.clone());
                        }
                    }
                    self.wire = Some(s)
                }
                Err(e) => self.trouble = Some(format!("the Desk could not listen for a stage: {e}")),
            }
        }
        self.wire.as_ref()
    }

    /// Starts a stage window, unless one is reading or starting already (one that never
    /// connected is closed and started again).
    pub(crate) fn open(&mut self) {
        self.reap();
        if self.wire.as_ref().is_some_and(|w| w.stages() > 0) || self.started.is_some_and(|t| self.child.is_some() && t.elapsed() < PATIENCE) {
            return;
        }
        self.close();
        let Some(program) = self.wants_rust().then(rust_program).flatten().or_else(program) else {
            self.trouble = Some("no stage here: install the WetOwl app, or set WO_STAGE to its program".into());
            return;
        };
        let Some(url) = self.wire().map(wo_wire::Server::url) else { return };
        let mut cmd = Command::new(&program);
        cmd.arg("--stage").arg(&url);
        // the screen it was kept on: full screen there from the start
        if let Some(screen) = self.kept().screen.clone() {
            cmd.arg("--screen").arg(screen);
        }
        match cmd
            .env("WETOWL_NON_UNIQUE", "1")
            // its STAGE lines (frames a second, the scene) into the Desk's own log
            .stdin(Stdio::null())
            .spawn()
        {
            Ok(child) => {
                self.child = Some(child);
                self.started = Some(Instant::now());
                self.trouble = None;
            }
            Err(e) => self.trouble = Some(format!("{} would not start: {e}", program.display())),
        }
    }

    /// Closes the window the Desk started.
    pub(crate) fn close(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        self.started = None;
    }

    /// A window that went away is let go of.
    fn reap(&mut self) {
        let gone = match self.child.as_mut().map(Child::try_wait) {
            Some(Ok(Some(status))) => Some(status),
            Some(Err(_)) => Some(Default::default()),
            _ => None,
        };
        if let Some(status) = gone {
            self.child = None;
            if self.wire.as_ref().is_none_or(|w| w.stages() == 0) && !status.success() {
                self.trouble = Some(format!("the stage window closed ({status})"));
            }
        }
    }

    /// Whether a frame is due now (a stage reads, and the last went a frame ago).
    pub(crate) fn due(&mut self) -> bool {
        self.reap();
        let reading = self.wire.as_ref().is_some_and(|w| w.stages() > 0);
        if !reading {
            self.heard_to = None;
            self.reading = None;
            return false;
        }
        self.reading.get_or_insert_with(Instant::now);
        let now = Instant::now();
        if self.last.is_some_and(|t| now - t < EVERY) {
            return false;
        }
        self.last = Some(now);
        true
    }

    pub(crate) fn say(&self, line: &str) {
        if let Some(w) = &self.wire {
            w.say(line);
        }
    }

    /// The room's sound since the last frame (wo_wire::pcm).
    pub(crate) fn say_pcm(&self, bytes: Vec<u8>) {
        if let Some(w) = &self.wire {
            w.say_binary(bytes);
        }
    }

    /// The house the Desk reads from, for the stages (now and to come); None signed out.
    pub(crate) fn set_house(&mut self, house: Option<wo_wire::House>) {
        let hello = wo_wire::hello(house.as_ref());
        if let Some(w) = &self.wire {
            w.set_hello(hello.clone());
        }
        self.hello = Some(hello);
    }

    /// The Rust stage asked for: on the Show page, or by WO_STAGE_RUST.
    fn wants_rust(&self) -> bool {
        self.kept().rust || std::env::var_os("WO_STAGE_RUST").is_some()
    }

    fn kept(&self) -> &Kept {
        self.kept.get_or_init(Kept::read)
    }

    fn keep(&mut self, k: Kept) {
        k.save();
        self.kept = std::cell::OnceCell::from(k);
    }

    /// A deck's record, as the show's facts, made again when `key` says it changed: kept for
    /// the stages (now and to come).
    pub(crate) fn record(&mut self, deck: usize, key: FactsKey, facts: impl FnOnce() -> wo_show::deck::RecordFacts) {
        if self.facts_key[deck].as_ref() == Some(&key) {
            return;
        }
        self.facts_key[deck] = Some(key);
        let f = facts();
        let line = self.show.get_or_insert_with(crate::show::Show::new).record(deck, Some(f));
        if let (Some(line), Some(w)) = (line, &self.wire) {
            w.keep(["record.A", "record.B"][deck], line);
        }
    }

    /// A deck's record cover (None: it has none, or not yet), for the cover ground: to the
    /// stages, and to the director (a cover ground only where there is a cover).
    pub(crate) fn cover(&mut self, deck: usize, track_id: i64, cover: Option<crate::library::Picture>) {
        let bytes = match &cover {
            Some((w, h, rgba)) => wo_wire::cover(deck, track_id, *w, *h, rgba),
            None => wo_wire::cover(deck, track_id, 0, 0, &[]),
        };
        if self.covers[deck].as_ref() == Some(&bytes) {
            return;
        }
        if let Some(w) = &self.wire {
            w.keep_binary(["cover.A", "cover.B"][deck], bytes.clone());
        }
        self.covers[deck] = Some(bytes);
        self.show().set_cover(deck, cover.is_some());
    }

    /// The director's frame: its cue to the stages when it changed.
    pub(crate) fn direct(&mut self, frame: &wo_wire::Frame) {
        let milk = self.wire.as_ref().and_then(wo_wire::Server::shown).and_then(|s| s.milk);
        let line = self.show.get_or_insert_with(crate::show::Show::new).tick(frame, milk.as_ref());
        if let (Some(line), Some(w)) = (line, &self.wire) {
            w.keep("cue", line);
        }
    }

    fn show(&mut self) -> &mut crate::show::Show {
        self.show.get_or_insert_with(crate::show::Show::new)
    }

    pub(crate) fn milk(&mut self) -> crate::show::MilkView {
        let told = self.wire.as_ref().and_then(wo_wire::Server::shown).and_then(|s| s.milk);
        self.show().milk(told.as_ref())
    }

    pub(crate) fn milk_hand(&mut self, h: crate::show::MilkHand) {
        self.show().milk_hand(h);
    }

    pub(crate) fn milk_search(&mut self, query: &str, most: usize) -> Vec<crate::show::MilkRow> {
        self.show().milk_search(query, most)
    }

    /// The Rust stage, or the WetOwl app's, from the next window on (one open now starts
    /// again).
    pub(crate) fn set_rust(&mut self, on: bool) {
        if self.kept().rust == on {
            return;
        }
        let k = Kept { rust: on, ..self.kept().clone() };
        self.keep(k);
        if self.child.is_some() {
            self.close();
            self.open();
        }
    }

    pub(crate) fn hand(&mut self, h: Hand) {
        if let Some(s) = &mut self.show {
            s.hand(&h);
        }
        match &h {
            Hand::Blackout(on) => self.blackout = *on,
            Hand::Freeze(on) => self.freeze = *on,
            // the screen chosen is kept for the next time the stage opens
            Hand::Screen(name) => self.keep(Kept { screen: Some(name.clone()), ..self.kept().clone() }),
            Hand::Full(false) => self.keep(Kept { screen: None, ..self.kept().clone() }),
            _ => {}
        }
        self.say(&wo_wire::hand(h));
    }

    pub(crate) fn view(&self) -> StageView {
        let stages = self.wire.as_ref().map_or(0, wo_wire::Server::stages);
        let told = self.wire.as_ref().and_then(wo_wire::Server::shown);
        let untold = stages > 0 && told.is_none() && self.reading.is_some_and(|t| t.elapsed() > UNTOLD);
        let shown = told.unwrap_or_default();
        let waiting = self.started.is_some_and(|t| t.elapsed() < PATIENCE);
        // a stage that tells its own blackout and freeze (the Desk's PERFORM) is believed;
        // an older one is taken to do as it was told
        let perform = !shown.sets.is_empty() || !shown.screens.is_empty() || shown.said_n > 0 || shown.look.is_some();
        // a Rust stage draws what the Desk directs: the Desk's own word on the show
        let directed = self.wire.as_ref().is_some_and(wo_wire::Server::v2).then_some(self.show.as_ref()).flatten();
        if let Some(s) = directed {
            let cue = s.cue();
            let name = cue.scene.as_ref().map(|id| s.direct.looks.get(id).map_or(id.clone(), |l| l.name.clone()));
            return StageView {
                stages,
                starting: false,
                trouble: None,
                scene: name.clone(),
                untold: false,
                held: s.direct.held(),
                blackout: cue.macros.blackout,
                freeze: cue.macros.freeze,
                told: Shown { scene: name, held: s.direct.held(), blackout: cue.macros.blackout, freeze: cue.macros.freeze, ..shown },
                kept_screen: self.kept().screen.clone(),
                rust: self.wants_rust(),
                rust_here: rust_program().is_some(),
                why: Some(cue.why.clone()).filter(|w| !w.is_empty()),
            };
        }
        StageView {
            stages,
            starting: stages == 0 && self.child.is_some() && waiting,
            trouble: if stages == 0 { self.trouble.clone() } else { None },
            scene: shown.scene.clone(),
            untold,
            held: shown.held,
            blackout: stages > 0 && if perform { shown.blackout } else { self.blackout },
            freeze: stages > 0 && if perform { shown.freeze } else { self.freeze },
            told: shown,
            kept_screen: self.kept().screen.clone(),
            rust: self.wants_rust(),
            rust_here: rust_program().is_some(),
            why: None,
        }
    }

    pub(crate) fn thumb(&self) -> Option<(u64, Arc<Thumb>)> {
        self.wire.as_ref().and_then(wo_wire::Server::thumb)
    }

    /// The url a stage elsewhere connects to (a window started by hand).
    pub(crate) fn url(&mut self) -> Option<String> {
        self.wire().map(wo_wire::Server::url)
    }
}

impl Drop for Stage {
    fn drop(&mut self) {
        self.close();
    }
}
