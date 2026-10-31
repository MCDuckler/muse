//! The Stage: the show in a window and a process of its own. For now that is the v1
//! app's stage window (`wetowl --stage <url>`), which directs the show itself over the
//! Desk's decks (app/lib/src/state/show/desk_show_source.dart); the Desk serves the
//! wire (wo-wire), starts the window, sends it a frame each tick and keeps its picture
//! for the booth.
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub use wo_wire::{Hand, Thumb};

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
    /// Since when a stage has been reading.
    reading: Option<Instant>,
}

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
}

/// The stage window's program: WO_STAGE, else the stage installed beside the Desk
/// (stage/wetowl), else the WetOwl app's own (Linux: ~/.local/opt/wetowl).
pub fn program() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("WO_STAGE").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p));
    }
    let name = if cfg!(windows) { "wetowl.exe" } else { "wetowl" };
    let beside = std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join("stage").join(name)));
    let app = std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/opt/wetowl").join(name)).filter(|_| cfg!(target_os = "linux"));
    [beside, app].into_iter().flatten().find(|p| p.is_file())
}

impl Stage {
    fn wire(&mut self) -> Option<&wo_wire::Server> {
        if self.wire.is_none() {
            match wo_wire::Server::open() {
                Ok(s) => self.wire = Some(s),
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
        let Some(program) = program() else {
            self.trouble = Some("no stage here: install the WetOwl app, or set WO_STAGE to its program".into());
            return;
        };
        let Some(url) = self.wire().map(wo_wire::Server::url) else { return };
        match Command::new(&program)
            .arg("--stage")
            .arg(&url)
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

    pub(crate) fn hand(&mut self, h: Hand) {
        if let Hand::Blackout(on) = h {
            self.blackout = on;
        }
        self.say(&wo_wire::hand(h));
    }

    pub(crate) fn view(&self) -> StageView {
        let stages = self.wire.as_ref().map_or(0, wo_wire::Server::stages);
        let told = self.wire.as_ref().and_then(wo_wire::Server::shown);
        let untold = stages > 0 && told.is_none() && self.reading.is_some_and(|t| t.elapsed() > UNTOLD);
        let shown = told.unwrap_or_default();
        let waiting = self.started.is_some_and(|t| t.elapsed() < PATIENCE);
        StageView {
            stages,
            starting: stages == 0 && self.child.is_some() && waiting,
            trouble: if stages == 0 { self.trouble.clone() } else { None },
            scene: shown.scene,
            untold,
            held: shown.held,
            blackout: self.blackout && stages > 0,
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
