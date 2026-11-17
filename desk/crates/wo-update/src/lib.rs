//! The Desk keeping itself up to date, on Linux, Windows and macOS.
//!
//! Every push to the desk branch publishes each OS's build to a rolling GitHub release
//! (.github/workflows/desk.yml: wetowl-desk-linux, wetowl-desk-windows, wetowl-desk-macos),
//! and beside the download a manifest, `<release>.json`: the build's commit and stamp, the
//! download's name, size and SHA-256.
//!
//! A build CI made knows its release (WO_UPDATE_CHANNEL, WO_BUILD_STAMP and WO_BUILD_COMMIT
//! at compile time). It reads the manifest soon after it starts and every few hours; a
//! newer build is fetched in the background, checked against the manifest and unpacked
//! beside the install (`.update/` in the Desk's folder; on a Mac `.WetOwl Desk update/`
//! beside the app), but nothing changes under a running set: the new build goes in at the
//! next start ([at_start]), or at once when the DJ asks ([Updater::restart] then
//! [relaunch_into_update] once the window is gone). Going in = renames on the same disk:
//! each of the folder's files (Linux, Windows: a running program may be renamed, never
//! overwritten) or the whole app (macOS), the old ones kept until the start after.
//!
//! A build made by hand (install-local.sh, cargo run) has no channel and never updates
//! itself; nor does any build with WO_UPDATE=off, or one benching (`--bench`).
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Where the rolling releases' files are: `<BASE>/<channel>/<file>`.
const BASE: &str = match option_env!("WO_UPDATE_BASE") {
    Some(b) => b,
    None => "https://github.com/MCDuckler/muse/releases/download",
};
/// How often a running Desk looks again.
const EVERY: Duration = Duration::from_secs(4 * 3600);
/// The first look, a little after the start (the Desk busy loading first).
const FIRST: Duration = Duration::from_secs(20);

/// This build, as CI stamped it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Build {
    /// The rolling release it came from (wetowl-desk-linux, …); none for a build made by hand.
    pub channel: Option<&'static str>,
    /// UTC yyyymmddHHMM.
    pub stamp: Option<&'static str>,
    /// The commit, short.
    pub commit: Option<&'static str>,
}

pub const fn this_build() -> Build {
    Build { channel: option_env!("WO_UPDATE_CHANNEL"), stamp: option_env!("WO_BUILD_STAMP"), commit: option_env!("WO_BUILD_COMMIT") }
}

impl Build {
    /// "202611171230 f23d8f0", or "made here".
    pub fn words(&self) -> String {
        match (self.stamp, self.commit) {
            (Some(s), Some(c)) => format!("{} · {c}", pretty_stamp(s)),
            (Some(s), None) => pretty_stamp(s),
            _ => "made here".into(),
        }
    }
}

/// yyyymmddHHMM as "2026-11-17 12:30 UTC" (anything else as it is).
pub fn pretty_stamp(s: &str) -> String {
    if s.len() == 12 && s.bytes().all(|b| b.is_ascii_digit()) {
        format!("{}-{}-{} {}:{} UTC", &s[0..4], &s[4..6], &s[6..8], &s[8..10], &s[10..12])
    } else {
        s.to_owned()
    }
}

/// What a release says of its newest build.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    pub commit: String,
    pub stamp: String,
    /// The download's file name in the release.
    pub asset: String,
    pub size: u64,
    pub sha256: String,
}

impl Manifest {
    /// Newer than this build: a later stamp of another commit.
    pub fn newer_than(&self, b: &Build) -> bool {
        match b.stamp {
            Some(s) => self.stamp.as_str() > s && b.commit != Some(self.commit.as_str()),
            None => false,
        }
    }
}

/// Where the updater stands, for the settings to say.
#[derive(Clone, Debug, PartialEq)]
pub enum State {
    /// Never updates itself here, and why.
    Off(String),
    /// Not looked yet.
    Waiting,
    Checking,
    /// The newest; when that was seen.
    UpToDate(Instant),
    /// Fetching this build: bytes so far.
    Fetching(Manifest, u64),
    /// This build is unpacked and goes in at the next start.
    Ready(Manifest),
    /// The last try went wrong (tried again later).
    Failed(String),
}

impl State {
    /// The state in a few words.
    pub fn words(&self) -> String {
        match self {
            State::Off(why) => why.clone(),
            State::Waiting => "Looks for a newer build soon".into(),
            State::Checking => "Looking for a newer build…".into(),
            State::UpToDate(_) => "Up to date".into(),
            State::Fetching(m, got) => {
                let pct = if m.size > 0 { (*got as f64 / m.size as f64 * 100.0).min(100.0) } else { 0.0 };
                format!("Fetching {} ({pct:.0} %)", pretty_stamp(&m.stamp))
            }
            State::Ready(m) => format!("{} is ready: it goes in when the Desk next starts", pretty_stamp(&m.stamp)),
            State::Failed(e) => format!("Could not update: {e}"),
        }
    }
}

/// Where this build is installed, and where its updates are unpacked.
#[derive(Clone, Debug)]
struct Install {
    /// Linux, Windows: the folder of the Desk's program. macOS: the .app.
    root: PathBuf,
    /// Beside or in it, on the same disk (renames, not copies).
    work: PathBuf,
}

impl Install {
    fn here() -> Result<Install, String> {
        let exe = std::env::current_exe().map_err(|e| format!("where am I? {e}"))?;
        let exe = exe.canonicalize().unwrap_or(exe);
        let dir = exe.parent().ok_or("no folder")?.to_path_buf();
        if cfg!(target_os = "macos") {
            // …/WetOwl Desk.app/Contents/MacOS/wetowl-desk
            let app = dir.parent().and_then(Path::parent).filter(|a| a.extension().is_some_and(|e| e == "app")).ok_or("not inside an app")?.to_path_buf();
            if app.to_string_lossy().contains("/AppTranslocation/") {
                return Err("macOS runs this copy from a locked place (opened straight from the download). Move WetOwl Desk.app to another folder with Finder, or clear its quarantine as READ ME FIRST.txt says, and it updates itself".into());
            }
            let name = app.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| "WetOwl Desk".into());
            let work = app.parent().ok_or("no folder")?.join(format!(".{name} update"));
            Ok(Install { root: app, work })
        } else {
            Ok(Install { work: dir.join(".update"), root: dir })
        }
    }

    fn ready_marker(&self) -> PathBuf {
        self.work.join("ready.json")
    }
    fn ready_dir(&self) -> PathBuf {
        self.work.join("ready")
    }

    /// The build unpacked and waiting, if whole.
    fn staged(&self) -> Option<Manifest> {
        let m: Manifest = serde_json::from_slice(&std::fs::read(self.ready_marker()).ok()?).ok()?;
        self.ready_dir().is_dir().then_some(m)
    }

    /// The program to start (Linux, Windows) or the app to open (macOS).
    fn program(&self) -> PathBuf {
        if cfg!(target_os = "macos") {
            self.root.clone()
        } else {
            self.root.join(if cfg!(windows) { "wetowl-desk.exe" } else { "wetowl-desk" })
        }
    }
}

/// Why this build never updates itself, if it does not.
fn off_because(build: &Build, args: &[String]) -> Option<String> {
    if std::env::var("WO_UPDATE").is_ok_and(|v| v == "off" || v == "0") {
        return Some("Off (WO_UPDATE=off)".into());
    }
    if args.iter().any(|a| a == "--bench") {
        return Some("Off while benching".into());
    }
    if build.channel.is_none() || build.stamp.is_none() {
        return Some("A build made here: it updates itself only as downloaded".into());
    }
    None
}

/// The updater of a running Desk: looks, fetches and unpacks on a thread of its own.
#[derive(Clone)]
pub struct Updater {
    shared: Arc<(Mutex<Shared>, Condvar)>,
}

struct Shared {
    state: State,
    /// Look again now.
    poke: bool,
    /// Asked to restart into the update.
    restart: bool,
}

impl Updater {
    /// Starts looking (unless this build never updates itself).
    pub fn start() -> Updater {
        let args: Vec<String> = std::env::args().collect();
        let build = this_build();
        let off = off_because(&build, &args).map(Err).unwrap_or_else(|| Install::here().map_err(|e| format!("Off: {e}")));
        let state = match &off {
            Err(why) => State::Off(why.clone()),
            Ok(_) => State::Waiting,
        };
        let u = Updater { shared: Arc::new((Mutex::new(Shared { state, poke: false, restart: false }), Condvar::new())) };
        if let Ok(install) = off {
            let me = u.clone();
            let _ = thread::Builder::new().name("desk updates".into()).spawn(move || me.run(build, install));
        }
        u
    }

    pub fn state(&self) -> State {
        self.shared.0.lock().unwrap_or_else(|e| e.into_inner()).state.clone()
    }

    fn set(&self, s: State) {
        self.shared.0.lock().unwrap_or_else(|e| e.into_inner()).state = s;
    }

    /// Look again now.
    pub fn check_now(&self) {
        let mut g = self.shared.0.lock().unwrap_or_else(|e| e.into_inner());
        if matches!(g.state, State::Off(_) | State::Checking | State::Fetching(..)) {
            return;
        }
        g.poke = true;
        self.shared.1.notify_all();
    }

    /// Restart into the update when the window is gone: true when one is ready.
    pub fn restart(&self) -> bool {
        let mut g = self.shared.0.lock().unwrap_or_else(|e| e.into_inner());
        g.restart = matches!(g.state, State::Ready(_));
        g.restart
    }

    /// Asked to restart into the update.
    pub fn restarting(&self) -> bool {
        self.shared.0.lock().unwrap_or_else(|e| e.into_inner()).restart
    }

    fn run(&self, build: Build, install: Install) {
        clear_old(&install);
        let mut wait = FIRST;
        loop {
            {
                let g = self.shared.0.lock().unwrap_or_else(|e| e.into_inner());
                let (mut g, _) = self.shared.1.wait_timeout_while(g, wait, |s| !s.poke).unwrap_or_else(|e| e.into_inner());
                g.poke = false;
            }
            wait = EVERY;
            // (a build already waiting is looked past too: a newer one replaces it)
            self.set(State::Checking);
            let r = self.look(&build, &install);
            match r {
                Ok(s) => self.set(s),
                Err(e) => {
                    eprintln!("updates: {e}");
                    self.set(State::Failed(e));
                    wait = Duration::from_secs(1800);
                }
            }
        }
    }

    /// One look: the manifest, and a newer build fetched and unpacked.
    fn look(&self, build: &Build, install: &Install) -> Result<State, String> {
        let channel = build.channel.expect("a channel");
        let url = format!("{BASE}/{channel}/{channel}.json");
        let m: Manifest = agent()
            .get(&url)
            .call()
            .map_err(|e| format!("the release: {e}"))?
            .body_mut()
            .read_json()
            .map_err(|e| format!("the release's manifest: {e}"))?;
        if !m.newer_than(build) {
            eprintln!("updates: up to date ({} here, {} released)", build.words(), m.stamp);
            return Ok(State::UpToDate(Instant::now()));
        }
        if install.staged().as_ref() == Some(&m) {
            return Ok(State::Ready(m));
        }
        eprintln!("updates: fetching {} ({})", m.stamp, m.commit);
        // a fresh place for it (the last try's leftovers gone)
        let _ = std::fs::remove_file(install.ready_marker());
        let _ = std::fs::remove_dir_all(install.ready_dir());
        let _ = std::fs::remove_dir_all(install.work.join("fetch"));
        std::fs::create_dir_all(install.work.join("fetch")).map_err(|e| format!("{} cannot be written: {e}", install.work.display()))?;
        let file = install.work.join("fetch").join(sanitize(&m.asset)?);
        // a few tries, each on a fresh connection (a dropped one is not taken up again)
        let url = format!("{BASE}/{channel}/{}", m.asset);
        let mut tries = 0;
        while let Err(e) = self.fetch(&agent(), &url, &file, &m) {
            tries += 1;
            if tries == 3 {
                return Err(e);
            }
            eprintln!("updates: {e}; again");
            thread::sleep(Duration::from_secs(5 * tries));
        }
        let out = install.ready_dir();
        std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;
        unpack(&file, &out)?;
        let _ = std::fs::remove_dir_all(install.work.join("fetch"));
        payload(&out)?;
        std::fs::write(install.ready_marker(), serde_json::to_vec_pretty(&m).unwrap()).map_err(|e| e.to_string())?;
        eprintln!("updates: {} ready for the next start", m.stamp);
        Ok(State::Ready(m))
    }

    /// The download into `file`, its size and SHA-256 checked against the manifest.
    fn fetch(&self, agent: &ureq::Agent, url: &str, file: &Path, m: &Manifest) -> Result<(), String> {
        self.set(State::Fetching(m.clone(), 0));
        let mut resp = agent.get(url).call().map_err(|e| format!("the download: {e}"))?;
        let mut body = resp.body_mut().as_reader();
        let mut out = std::fs::File::create(file).map_err(|e| e.to_string())?;
        let mut hash = Sha256::new();
        let mut buf = vec![0u8; 1 << 16];
        let mut got = 0u64;
        let mut said = Instant::now();
        loop {
            let n = body.read(&mut buf).map_err(|e| format!("the download: {e}"))?;
            if n == 0 {
                break;
            }
            hash.update(&buf[..n]);
            out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
            got += n as u64;
            if said.elapsed() > Duration::from_millis(250) {
                said = Instant::now();
                self.set(State::Fetching(m.clone(), got));
            }
            if got > m.size.saturating_mul(2).max(1 << 20) {
                return Err("the download is bigger than the release says".into());
            }
        }
        out.sync_all().map_err(|e| e.to_string())?;
        if got != m.size {
            return Err(format!("the download is {got} bytes, the release says {}", m.size));
        }
        let sum = hex(&hash.finalize());
        if !sum.eq_ignore_ascii_case(&m.sha256) {
            return Err("the download does not match the release's checksum".into());
        }
        Ok(())
    }
}

/// An agent for the release's files (each its own: no connection kept between them).
fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_connect(Some(Duration::from_secs(20)))
        .timeout_recv_response(Some(Duration::from_secs(30)))
        .max_idle_connections(0)
        .user_agent("WetOwl Desk")
        .build()
        .into()
}

/// A file name from the manifest, as a plain name.
fn sanitize(name: &str) -> Result<&str, String> {
    if name.is_empty() || name.contains(['/', '\\']) || name.starts_with('.') {
        return Err(format!("a strange file name in the release: {name:?}"));
    }
    Ok(name)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// The download unpacked into `out` with the OS's own tools: tar (Linux; Windows 10 and
/// later carry bsdtar, which reads zips), ditto on a Mac (it keeps the app's links and
/// signatures).
fn unpack(file: &Path, out: &Path) -> Result<(), String> {
    let run = |c: &mut Command| -> Result<(), String> {
        let o = c.output().map_err(|e| format!("{:?}: {e}", c.get_program()))?;
        if o.status.success() {
            Ok(())
        } else {
            Err(format!("unpacking failed: {}", String::from_utf8_lossy(&o.stderr).trim()))
        }
    };
    if cfg!(target_os = "macos") {
        run(Command::new("/usr/bin/ditto").arg("-x").arg("-k").arg(file).arg(out))
    } else if cfg!(windows) {
        let tar = std::env::var_os("SystemRoot").map(|r| PathBuf::from(r).join("System32").join("tar.exe")).filter(|p| p.is_file()).unwrap_or_else(|| "tar".into());
        run(Command::new(tar).arg("-xf").arg(file).arg("-C").arg(out)).or_else(|_| {
            let ps = format!("Expand-Archive -LiteralPath '{}' -DestinationPath '{}' -Force", file.display().to_string().replace('\'', "''"), out.display().to_string().replace('\'', "''"));
            run(Command::new("powershell").args(["-NoProfile", "-NonInteractive", "-Command", &ps]))
        })
    } else {
        run(Command::new("tar").arg("-xzf").arg(file).arg("-C").arg(out))
    }
}

/// What goes in, inside the unpacked download: on a Mac the .app (in the folder "WetOwl
/// Desk"); elsewhere the folder holding the Desk's program (the zip's top, or the one folder
/// the tarball has).
fn payload(out: &Path) -> Result<PathBuf, String> {
    let entries = |d: &Path| -> Vec<PathBuf> {
        std::fs::read_dir(d).map(|r| r.flatten().map(|e| e.path()).filter(|p| !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("__MACOSX"))).collect()).unwrap_or_default()
    };
    if cfg!(target_os = "macos") {
        let mut look = vec![out.to_path_buf()];
        for _ in 0..3 {
            let mut next = vec![];
            for d in look {
                for e in entries(&d) {
                    if e.is_dir() && e.extension().is_some_and(|x| x == "app") && e.join("Contents/MacOS/wetowl-desk").is_file() {
                        return Ok(e);
                    }
                    if e.is_dir() {
                        next.push(e);
                    }
                }
            }
            look = next;
        }
        Err("the download holds no WetOwl Desk.app".into())
    } else {
        let name = if cfg!(windows) { "wetowl-desk.exe" } else { "wetowl-desk" };
        let mut d = out.to_path_buf();
        for _ in 0..2 {
            if d.join(name).is_file() {
                return Ok(d);
            }
            match entries(&d).as_slice() {
                [one] if one.is_dir() => d = one.clone(),
                _ => break,
            }
        }
        Err(format!("the download holds no {name}"))
    }
}

/// The last update's old files gone (Windows lets go of a program only once it has ended).
fn clear_old(install: &Install) {
    if let Ok(r) = std::fs::read_dir(&install.work) {
        for e in r.flatten() {
            if e.file_name().to_string_lossy().starts_with("old-") {
                let _ = std::fs::remove_dir_all(e.path());
            }
        }
    }
}

/// The staged build put in place of this one: renames on the same disk, undone if one fails.
fn put_in(install: &Install, m: &Manifest) -> Result<(), String> {
    let from = payload(&install.ready_dir())?;
    let old = install.work.join(format!("old-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&old);
    std::fs::create_dir_all(&old).map_err(|e| e.to_string())?;
    if cfg!(target_os = "macos") {
        let keep = old.join("WetOwl Desk.app");
        std::fs::rename(&install.root, &keep).map_err(|e| format!("moving the old app aside: {e}"))?;
        if let Err(e) = std::fs::rename(&from, &install.root) {
            let _ = std::fs::rename(&keep, &install.root);
            return Err(format!("moving the new app in: {e}"));
        }
        // fetched by the Desk itself it carries no quarantine; cleared anyway
        let _ = Command::new("/usr/bin/xattr").args(["-dr", "com.apple.quarantine"]).arg(&install.root).output();
    } else {
        let names: Vec<std::ffi::OsString> = std::fs::read_dir(&from).map_err(|e| e.to_string())?.flatten().map(|e| e.file_name()).collect();
        let mut moved: Vec<(PathBuf, Option<PathBuf>)> = vec![];
        let undo = |moved: &[(PathBuf, Option<PathBuf>)]| {
            for (dest, kept) in moved.iter().rev() {
                if let Some(k) = kept {
                    let _ = std::fs::remove_dir_all(dest).or_else(|_| std::fs::remove_file(dest));
                    let _ = std::fs::rename(k, dest);
                }
            }
        };
        for n in names {
            let dest = install.root.join(&n);
            let kept = if dest.exists() {
                let k = old.join(&n);
                if let Err(e) = std::fs::rename(&dest, &k) {
                    undo(&moved);
                    return Err(format!("moving {} aside: {e}", dest.display()));
                }
                Some(k)
            } else {
                None
            };
            if let Err(e) = std::fs::rename(from.join(&n), &dest) {
                if let Some(k) = &kept {
                    let _ = std::fs::rename(k, &dest);
                }
                undo(&moved);
                return Err(format!("moving {} in: {e}", dest.display()));
            }
            moved.push((dest, kept));
        }
    }
    let _ = std::fs::remove_file(install.ready_marker());
    let _ = std::fs::remove_dir_all(install.ready_dir());
    eprintln!("updates: {} ({}) put in", m.stamp, m.commit);
    Ok(())
}

/// Starts the Desk again (the new one), with these arguments.
fn relaunch(install: &Install, args: &[String]) -> Result<(), String> {
    let r = if cfg!(target_os = "macos") {
        Command::new("/usr/bin/open").arg("-n").arg(install.program()).arg("--args").args(args).spawn()
    } else {
        Command::new(install.program()).args(args).spawn()
    };
    r.map(|_| ()).map_err(|e| format!("starting the new Desk: {e}"))
}

/// First thing at a start: a build waiting from last time put in, and started instead of
/// this one (this process then ends). Nothing happens for a build that never updates itself.
pub fn at_start() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let build = this_build();
    if off_because(&build, &args).is_some() {
        return;
    }
    let Ok(install) = Install::here() else { return };
    let Some(m) = install.staged() else { return };
    if !m.newer_than(&build) {
        // already in (or older): only tidied
        let _ = std::fs::remove_file(install.ready_marker());
        let _ = std::fs::remove_dir_all(install.ready_dir());
        return;
    }
    match put_in(&install, &m).and_then(|()| relaunch(&install, &args)) {
        Ok(()) => std::process::exit(0),
        Err(e) => {
            eprintln!("updates: the waiting build could not go in: {e}");
            let _ = std::fs::remove_file(install.ready_marker());
            let _ = std::fs::remove_dir_all(install.ready_dir());
        }
    }
}

/// After the window closed for [Updater::restart]: the update put in and the new Desk
/// started. An error leaves this build in place.
pub fn relaunch_into_update() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let install = Install::here()?;
    let m = install.staged().ok_or("no update waiting")?;
    put_in(&install, &m)?;
    relaunch(&install, &args)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(stamp: &str, commit: &str) -> Manifest {
        Manifest { commit: commit.into(), stamp: stamp.into(), asset: "x.zip".into(), size: 1, sha256: String::new() }
    }

    #[test]
    fn only_a_later_build_of_another_commit_is_newer() {
        let b = Build { channel: Some("wetowl-desk-linux"), stamp: Some("202611171200"), commit: Some("abc1234") };
        assert!(m("202611171300", "def5678").newer_than(&b));
        assert!(!m("202611171300", "abc1234").newer_than(&b), "the same commit built again");
        assert!(!m("202611171100", "def5678").newer_than(&b));
        assert!(!m("202611171200", "def5678").newer_than(&b));
        let here = Build { channel: None, stamp: None, commit: None };
        assert!(!m("209912312359", "def5678").newer_than(&here), "a build made by hand never updates");
    }

    #[test]
    fn a_build_made_by_hand_stays_off() {
        let b = Build { channel: None, stamp: None, commit: None };
        assert!(off_because(&b, &[]).is_some());
        let ci = Build { channel: Some("wetowl-desk-linux"), stamp: Some("202611171200"), commit: Some("abc1234") };
        assert!(off_because(&ci, &["--bench".into(), "8".into()]).is_some());
    }

    #[test]
    fn strange_names_are_refused() {
        assert!(sanitize("wetowl-desk-linux.tar.gz").is_ok());
        for bad in ["../x", "a/b", "a\\b", ".hidden", ""] {
            assert!(sanitize(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn stamps_read_as_dates() {
        assert_eq!(pretty_stamp("202611171230"), "2026-11-17 12:30 UTC");
        assert_eq!(pretty_stamp("x"), "x");
    }

    /// A staged build goes into a folder file by file, the old ones kept aside, and a
    /// file the build lacks is left alone.
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn a_staged_build_goes_in_by_renames() {
        let t = std::env::temp_dir().join(format!("wo-update-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&t);
        let root = t.join("desk");
        let exe = if cfg!(windows) { "wetowl-desk.exe" } else { "wetowl-desk" };
        std::fs::create_dir_all(root.join("dance/chris")).unwrap();
        std::fs::write(root.join(exe), "old").unwrap();
        std::fs::write(root.join("dance/chris/moves.bin"), "old moves").unwrap();
        std::fs::write(root.join("mine.txt"), "kept").unwrap();
        let install = Install { root: root.clone(), work: root.join(".update") };
        let new = install.ready_dir().join("wetowl-desk");
        std::fs::create_dir_all(new.join("dance/chris")).unwrap();
        std::fs::write(new.join(exe), "new").unwrap();
        std::fs::write(new.join("dance/chris/moves.bin"), "new moves").unwrap();
        std::fs::write(new.join("wetowl-stage"), "stage").unwrap();
        let man = m("202611171300", "def5678");
        std::fs::write(install.ready_marker(), serde_json::to_vec(&man).unwrap()).unwrap();
        assert_eq!(install.staged(), Some(man.clone()));
        put_in(&install, &man).unwrap();
        assert_eq!(std::fs::read_to_string(root.join(exe)).unwrap(), "new");
        assert_eq!(std::fs::read_to_string(root.join("dance/chris/moves.bin")).unwrap(), "new moves");
        assert_eq!(std::fs::read_to_string(root.join("wetowl-stage")).unwrap(), "stage");
        assert_eq!(std::fs::read_to_string(root.join("mine.txt")).unwrap(), "kept");
        assert!(install.staged().is_none(), "the marker went with it");
        clear_old(&install);
        assert!(std::fs::read_dir(&install.work).unwrap().next().is_none(), "the old files tidied");
        let _ = std::fs::remove_dir_all(&t);
    }

    /// The OS's own packer and [unpack]/[payload] agree: a package as CI makes it is
    /// unpacked with the tools the Desk uses (tar; bsdtar reading a zip on Windows; ditto).
    #[test]
    fn a_package_unpacks_with_the_os_tools() {
        let t = std::env::temp_dir().join(format!("wo-update-pack-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&t);
        let src = t.join("src");
        let ok = |c: &mut Command| assert!(c.status().unwrap().success(), "{c:?}");
        let file;
        if cfg!(target_os = "macos") {
            let app = src.join("WetOwl Desk").join("WetOwl Desk.app/Contents/MacOS");
            std::fs::create_dir_all(&app).unwrap();
            std::fs::write(app.join("wetowl-desk"), "new").unwrap();
            std::fs::write(src.join("WetOwl Desk/READ ME FIRST.txt"), "hi").unwrap();
            file = t.join("wetowl-desk-macos.zip");
            ok(Command::new("ditto").args(["-c", "-k", "--sequesterRsrc", "--keepParent"]).arg(src.join("WetOwl Desk")).arg(&file));
        } else if cfg!(windows) {
            std::fs::create_dir_all(src.join("dance/chris")).unwrap();
            std::fs::write(src.join("wetowl-desk.exe"), "new").unwrap();
            std::fs::write(src.join("dance/chris/moves.bin"), "m").unwrap();
            file = t.join("wetowl-desk-windows.zip");
            // as CI packs it (7-Zip), else bsdtar
            let seven = Command::new("7z").arg("a").arg("-tzip").arg(&file).arg(".\\*").current_dir(&src).status();
            if !seven.is_ok_and(|s| s.success()) {
                ok(Command::new("tar").arg("-a").arg("-cf").arg(&file).arg("-C").arg(&src).arg("."));
            }
        } else {
            std::fs::create_dir_all(src.join("wetowl-desk/dance/chris")).unwrap();
            std::fs::write(src.join("wetowl-desk/wetowl-desk"), "new").unwrap();
            std::fs::write(src.join("wetowl-desk/dance/chris/moves.bin"), "m").unwrap();
            file = t.join("wetowl-desk-linux.tar.gz");
            ok(Command::new("tar").arg("-czf").arg(&file).arg("-C").arg(&src).arg("wetowl-desk"));
        }
        let out = t.join("out");
        std::fs::create_dir_all(&out).unwrap();
        unpack(&file, &out).unwrap();
        let p = payload(&out).unwrap();
        if cfg!(target_os = "macos") {
            assert!(p.ends_with("WetOwl Desk.app"), "{p:?}");
        } else {
            let exe = if cfg!(windows) { "wetowl-desk.exe" } else { "wetowl-desk" };
            assert_eq!(std::fs::read_to_string(p.join(exe)).unwrap(), "new");
            assert_eq!(std::fs::read_to_string(p.join("dance").join("chris").join("moves.bin")).unwrap(), "m");
        }
        let _ = std::fs::remove_dir_all(&t);
    }

    /// A Mac's app swapped whole, the old one kept aside.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_staged_app_goes_in_whole() {
        let t = std::env::temp_dir().join(format!("wo-update-app-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&t);
        let app = t.join("WetOwl Desk.app");
        std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        std::fs::write(app.join("Contents/MacOS/wetowl-desk"), "old").unwrap();
        let install = Install { root: app.clone(), work: t.join(".WetOwl Desk update") };
        let new = install.ready_dir().join("WetOwl Desk/WetOwl Desk.app/Contents/MacOS");
        std::fs::create_dir_all(&new).unwrap();
        std::fs::write(new.join("wetowl-desk"), "new").unwrap();
        let man = m("202611171300", "def5678");
        std::fs::write(install.ready_marker(), serde_json::to_vec(&man).unwrap()).unwrap();
        put_in(&install, &man).unwrap();
        assert_eq!(std::fs::read_to_string(app.join("Contents/MacOS/wetowl-desk")).unwrap(), "new");
        clear_old(&install);
        let _ = std::fs::remove_dir_all(&t);
    }
}
