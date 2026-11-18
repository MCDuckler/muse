//! Running rkbx_link for the user: found where it usually is, its `config` set up for
//! WetOwl (the original kept beside it), started without a window, watched (what it says
//! tells whether rekordbox is found), started again if it stops, stopped with the Desk.
//!
//! rkbx_link is grufkork's (GPL-3); WetOwl only runs it as its own program and listens.
use std::io::{self, BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Where rkbx_link is downloaded from.
pub const RELEASES: &str = "https://github.com/grufkork/rkbx_link/releases/latest";

/// The program's file name here.
pub fn exe_name() -> &'static str {
    if cfg!(target_os = "windows") { "rkbx_link.exe" } else { "rkbx_link" }
}

fn home() -> Option<PathBuf> {
    std::env::var_os(if cfg!(target_os = "windows") { "USERPROFILE" } else { "HOME" }).map(PathBuf::from)
}

/// Where WetOwl unpacks a downloaded rkbx_link.
pub fn own_dir() -> Option<PathBuf> {
    if cfg!(target_os = "windows") {
        std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("WetOwl").join("rkbx_link"))
    } else if cfg!(target_os = "macos") {
        home().map(|h| h.join("Library/Application Support/WetOwl/rkbx_link"))
    } else {
        home().map(|h| h.join(".local/share/wetowl/rkbx_link"))
    }
}

/// `p` as rkbx_link: the program itself, or a folder holding it (one level down too, as
/// an unpacked download often is).
fn exe_in(p: &Path) -> Option<PathBuf> {
    if p.is_file() {
        return p.file_name().is_some_and(|n| n.eq_ignore_ascii_case(exe_name())).then(|| p.to_owned());
    }
    let direct = p.join(exe_name());
    if direct.is_file() {
        return Some(direct);
    }
    std::fs::read_dir(p).ok()?.flatten().map(|e| e.path()).filter(|d| d.is_dir()).find_map(|d| Some(d.join(exe_name())).filter(|x| x.is_file()))
}

/// rkbx_link on this computer: `hint` (a program or a folder chosen by hand) first, then
/// WetOwl's own copy, beside the Desk, `~/dev/rkbx_link`, and unpacked in Downloads.
pub fn find(hint: Option<&Path>) -> Option<PathBuf> {
    let mut places: Vec<PathBuf> = hint.map(Path::to_owned).into_iter().collect();
    places.extend(own_dir());
    if let Ok(me) = std::env::current_exe()
        && let Some(dir) = me.parent()
    {
        places.push(dir.join("rkbx_link"));
    }
    if let Some(h) = home() {
        places.push(h.join("dev").join("rkbx_link"));
        if let Ok(rd) = std::fs::read_dir(h.join("Downloads")) {
            let mut dirs: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.is_dir() && starts_rkbx(p)).collect();
            dirs.sort();
            places.extend(dirs);
        }
    }
    places.iter().find_map(|p| exe_in(p))
}

fn starts_rkbx(p: &Path) -> bool {
    p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.to_ascii_lowercase().starts_with("rkbx_link"))
}

/// A downloaded rkbx_link still zipped, in Downloads (the newest).
pub fn downloaded_zip() -> Option<PathBuf> {
    let rd = std::fs::read_dir(home()?.join("Downloads")).ok()?;
    rd.flatten()
        .map(|e| e.path())
        .filter(|p| p.is_file() && starts_rkbx(p) && p.extension().is_some_and(|x| x.eq_ignore_ascii_case("zip")))
        .max_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok())
}

/// `zip` unpacked into [own_dir] (the system's own unzip: `tar` on Windows, `ditto` on a
/// Mac); the program in it.
pub fn unpack(zip: &Path) -> Result<PathBuf, String> {
    let dir = own_dir().ok_or("no folder for it")?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let status = if cfg!(target_os = "windows") {
        Command::new("tar").arg("-xf").arg(zip).arg("-C").arg(&dir).status()
    } else if cfg!(target_os = "macos") {
        Command::new("ditto").args(["-x", "-k"]).arg(zip).arg(&dir).status()
    } else {
        Command::new("unzip").arg("-o").arg(zip).arg("-d").arg(&dir).status()
    };
    match status {
        Ok(s) if s.success() => exe_in(&dir).ok_or_else(|| format!("no {} in {}", exe_name(), zip.display())),
        Ok(s) => Err(format!("unzipping it failed ({s})")),
        Err(e) => Err(format!("unzipping it: {e}")),
    }
}

/// The `config` lines WetOwl needs, by key; `port` is where the Desk listens.
pub fn wanted(port: u16, rekordbox: Option<&str>) -> Vec<(String, String)> {
    let mut w: Vec<(String, String)> = [
        ("osc.enabled", "true".to_owned()),
        ("osc.destination", format!("127.0.0.1:{port}")),
        ("osc.msg.master/time", "true".into()),
        ("osc.msg.master/phrase", "true".into()),
        ("osc.msg.n/time", "true".into()),
        ("osc.msg.n/phrase", "true".into()),
        ("osc.msg.master/beat/subdiv", "4".into()),
        ("osc.msg.n/beat/subdiv", "1".into()),
        // the Desk shows what it needs; its own window and checks are not wanted
        ("display.enabled", "false".into()),
        ("app.auto_update", "false".into()),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v))
    .collect();
    if let Some(v) = rekordbox {
        w.push(("keeper.rekordbox_version".into(), v.to_owned()));
    }
    w
}

/// `text` (a `config`) with `wanted` set: a key's line replaced where it is, added where
/// it is not; everything else as it was. Whether anything changed.
pub fn set_up(text: &str, wanted: &[(String, String)]) -> (String, bool) {
    let mut lines: Vec<String> = text.lines().map(str::to_owned).collect();
    let mut changed = false;
    for (k, v) in wanted {
        let line = format!("{k} {v}");
        let at = lines.iter().position(|l| l.split_whitespace().next() == Some(k.as_str()));
        match at {
            Some(i) if lines[i].trim() == line => {}
            Some(i) => {
                lines[i] = line;
                changed = true;
            }
            None => {
                lines.push(line);
                changed = true;
            }
        }
    }
    let mut out = lines.join("\n");
    out.push('\n');
    (out, changed)
}

/// rkbx_link's `config` beside `exe` set up for WetOwl; the original is kept once as
/// `config.before-wetowl`.
pub fn configure(exe: &Path, port: u16, rekordbox: Option<&str>) -> io::Result<()> {
    let file = exe.with_file_name("config");
    let old = std::fs::read_to_string(&file).unwrap_or_default();
    let (new, changed) = set_up(&old, &wanted(port, rekordbox));
    if changed {
        let keep = exe.with_file_name("config.before-wetowl");
        if !old.is_empty() && !keep.exists() {
            std::fs::write(&keep, &old)?;
        }
        std::fs::write(&file, new)?;
    }
    Ok(())
}

/// How rkbx_link is doing.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum Link {
    #[default]
    Starting,
    /// Running, rekordbox not found (not open, or not a version it knows).
    Looking,
    Connected,
    /// It stopped (and is started again shortly): its last words.
    Stopped(String),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RunnerView {
    pub state: Link,
    pub exe: PathBuf,
    /// Its own version ("1.2.0").
    pub version: Option<String>,
    /// The rekordbox versions it knows, and the one it looks for.
    pub knows: Vec<String>,
    pub targets: Option<String>,
    /// Times it was started again.
    pub restarts: u32,
    /// Its last lines (escape codes taken out).
    pub last: Vec<String>,
    /// Since when it has looked for rekordbox without finding it.
    pub looking_since: Option<Instant>,
}

/// rkbx_link's colours and cursor moves out of a line.
fn plain(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut it = line.chars().peekable();
    while let Some(c) = it.next() {
        if c == '\u{1b}' {
            if it.peek() == Some(&'[') {
                it.next();
                for d in it.by_ref() {
                    if d.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
            continue;
        }
        out.push(c);
    }
    out.trim().to_owned()
}

/// What one line of rkbx_link's says, into `v`.
pub fn heard(v: &mut RunnerView, line: &str) {
    let l = plain(line);
    if l.is_empty() || l.chars().all(|c| c == '=') {
        return;
    }
    if let Some(rest) = l.strip_prefix("Rekordbox Link v") {
        v.version = Some(rest.trim().to_owned());
    } else if let Some(rest) = l.split("Rekordbox versions available:").nth(1) {
        v.knows = rest.split(|c: char| !(c.is_ascii_digit() || c == '.')).filter(|s| !s.is_empty()).map(str::to_owned).collect();
    } else if let Some(rest) = l.split("Targeting Rekordbox version:").nth(1) {
        v.targets = Some(rest.trim().to_owned());
    } else if l.contains("Looking for Rekordbox") {
        v.state = Link::Looking;
        v.looking_since.get_or_insert_with(Instant::now);
    } else if l.contains("Connected to Rekordbox") {
        v.state = Link::Connected;
        v.looking_since = None;
    }
    v.last.push(l);
    if v.last.len() > 12 {
        v.last.remove(0);
    }
}

/// A running rkbx_link; stopped when dropped.
pub struct Runner {
    view: Arc<Mutex<RunnerView>>,
    child: Arc<Mutex<Option<Child>>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Runner {
    /// Starts `exe` (in its own folder, where its `config` and data are) and keeps it
    /// running.
    pub fn start(exe: PathBuf) -> Runner {
        let view = Arc::new(Mutex::new(RunnerView { exe: exe.clone(), ..Default::default() }));
        let child: Arc<Mutex<Option<Child>>> = Arc::new(Mutex::new(None));
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let (view, child, stop) = (view.clone(), child.clone(), stop.clone());
            std::thread::Builder::new()
                .name("rkbx_link".into())
                .spawn(move || {
                    let mut first = true;
                    while !stop.load(Ordering::Relaxed) {
                        if !first {
                            view.lock().unwrap().restarts += 1;
                        }
                        first = false;
                        let started = Instant::now();
                        let said = match spawn(&exe) {
                            Ok(mut c) => {
                                let out = c.stdout.take();
                                *child.lock().unwrap() = Some(c);
                                if let Some(out) = out {
                                    for line in BufReader::new(out).lines() {
                                        let Ok(line) = line else { break };
                                        heard(&mut view.lock().unwrap(), &line);
                                    }
                                }
                                if let Some(mut c) = child.lock().unwrap().take() {
                                    let _ = c.wait();
                                }
                                view.lock().unwrap().last.last().cloned().unwrap_or_else(|| "it stopped".into())
                            }
                            Err(e) => format!("could not start it: {e}"),
                        };
                        if stop.load(Ordering::Relaxed) {
                            break;
                        }
                        {
                            let mut v = view.lock().unwrap();
                            v.state = Link::Stopped(said);
                            v.looking_since = None;
                        }
                        // not in a tight loop when it cannot run at all
                        let pause = if started.elapsed() < Duration::from_secs(5) { 5 } else { 2 };
                        for _ in 0..pause * 10 {
                            if stop.load(Ordering::Relaxed) {
                                return;
                            }
                            std::thread::sleep(Duration::from_millis(100));
                        }
                    }
                })
                .expect("a thread")
        };
        Runner { view, child, stop, thread: Some(thread) }
    }

    pub fn view(&self) -> RunnerView {
        self.view.lock().unwrap().clone()
    }
}

fn spawn(exe: &Path) -> io::Result<Child> {
    let mut cmd = Command::new(exe);
    cmd.current_dir(exe.parent().unwrap_or(Path::new("."))).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // no console window of its own
        cmd.creation_flags(0x0800_0000);
    }
    cmd.spawn()
}

impl Drop for Runner {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(c) = self.child.lock().unwrap().as_mut() {
            let _ = c.kill();
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn its_config_is_set_up_and_the_rest_kept() {
        let text = "# == General ==\napp.licensekey evaluation\nosc.enabled false\nosc.destination 127.0.0.1:4460\nosc.msg.n/time false\nkeeper.decks 2\n";
        let (out, changed) = set_up(text, &wanted(4460, Some("7.2.2")));
        assert!(changed);
        assert!(out.contains("app.licensekey evaluation\n"));
        assert!(out.contains("keeper.decks 2\n"));
        assert!(out.contains("osc.enabled true\n"));
        assert!(out.contains("osc.msg.n/time true\n"));
        assert!(out.contains("osc.msg.n/beat/subdiv 1\n"));
        assert!(out.contains("keeper.rekordbox_version 7.2.2\n"));
        assert_eq!(out.matches("osc.destination").count(), 1);
        // set up already: nothing to change
        let (again, changed) = set_up(&out, &wanted(4460, Some("7.2.2")));
        assert!(!changed);
        assert_eq!(again, out);
    }

    #[test]
    fn what_it_says_is_read() {
        let mut v = RunnerView::default();
        for l in [
            "Rekordbox Link v1.2.0",
            "\u{1b}[0m\u{1b}[37m[App]  Rekordbox versions available: [\"7.2.2\", \"7.2.4\"]",
            "\u{1b}[0m\u{1b}[37m[App]  Targeting Rekordbox version: 7.2.2",
            "\u{1b}[0m\u{1b}[37m[BeatKeeper]  Looking for Rekordbox...",
        ] {
            heard(&mut v, l);
        }
        assert_eq!(v.version.as_deref(), Some("1.2.0"));
        assert_eq!(v.knows, ["7.2.2", "7.2.4"]);
        assert_eq!(v.targets.as_deref(), Some("7.2.2"));
        assert_eq!(v.state, Link::Looking);
        assert!(v.looking_since.is_some());
        heard(&mut v, "\u{1b}[0m\u{1b}[32m[BeatKeeper]  Connected to Rekordbox!");
        assert_eq!(v.state, Link::Connected);
        assert_eq!(v.last.last().map(String::as_str), Some("[BeatKeeper]  Connected to Rekordbox!"));
    }

    #[test]
    fn found_in_a_folder_or_one_down() {
        let dir = std::env::temp_dir().join(format!("wo-rkbx-find-{}", std::process::id()));
        let inner = dir.join("rkbx_link_win");
        std::fs::create_dir_all(&inner).unwrap();
        std::fs::write(inner.join(exe_name()), b"").unwrap();
        assert_eq!(exe_in(&dir), Some(inner.join(exe_name())));
        assert_eq!(find(Some(&dir)), Some(inner.join(exe_name())));
        let _ = std::fs::remove_file(inner.join(exe_name()));
        let _ = std::fs::remove_dir(&inner);
        let _ = std::fs::remove_dir(&dir);
    }
}
