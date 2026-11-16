//! The footage on this machine, for the show: the folder the hands put clips in
//! (`~/Videos/WetOwl`) looked at every so often on a thread of its own, each new clip made
//! into a proxy there (wo_video::import, one at a time), proxies of clips taken away removed —
//! and what there is, for the director and the Footage page.
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use wo_show::video::ClipMeta;
use wo_video::Library;

/// How often the folder is looked at (sooner when asked).
const EVERY: Duration = Duration::from_secs(20);

/// The footage as the Desk shows it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct VideoShelf {
    /// The clips made, by name.
    pub clips: Vec<ClipMeta>,
    /// The clip being made now, and how far.
    pub making: Option<(String, f64)>,
    /// Clips waiting to be made.
    pub waiting: usize,
    /// Clips that could not be made: their names and why.
    pub failed: Vec<(String, String)>,
    /// Where the clips go, and where their proxies are.
    pub folder: Option<PathBuf>,
    pub proxies: Option<PathBuf>,
    /// ffmpeg and ffprobe found.
    pub tools: bool,
    /// A new number each time the clips change.
    pub version: u64,
}

struct Inner {
    shelf: Mutex<VideoShelf>,
    poke: (Mutex<bool>, Condvar),
    stop: AtomicBool,
}

pub struct Videos {
    lib: Option<Library>,
    inner: Arc<Inner>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Videos {
    /// This machine's footage, looked after on a thread.
    pub fn here() -> Videos {
        Videos::of(Library::here())
    }

    /// No footage (tests, a Desk with no home).
    pub fn none() -> Videos {
        Videos { lib: None, inner: Arc::new(Inner { shelf: Mutex::new(VideoShelf::default()), poke: (Mutex::new(false), Condvar::new()), stop: AtomicBool::new(false) }), thread: None }
    }

    pub fn of(lib: Option<Library>) -> Videos {
        let mut v = Videos::none();
        let Some(lib) = lib else { return v };
        {
            let mut s = v.inner.shelf.lock().unwrap();
            s.folder = Some(lib.sources.clone());
            s.proxies = Some(lib.proxies.clone());
            // what was made before shows at once
            s.clips = lib.clips();
            s.version = 1;
        }
        let (l, inner) = (lib.clone(), v.inner.clone());
        v.thread = std::thread::Builder::new().name("wo-videos".into()).spawn(move || run(l, inner)).ok();
        v.lib = Some(lib);
        v
    }

    pub fn shelf(&self) -> VideoShelf {
        self.inner.shelf.lock().unwrap().clone()
    }

    /// The clips' version (cheap: for a change).
    pub fn version(&self) -> u64 {
        self.inner.shelf.lock().unwrap().version
    }

    /// The folder looked at now.
    pub fn rescan(&self) {
        let (m, cv) = &self.inner.poke;
        *m.lock().unwrap() = true;
        cv.notify_one();
    }

    /// The folder made where it is not, and its path (for the hands to open).
    pub fn folder(&self) -> Option<PathBuf> {
        let lib = self.lib.as_ref()?;
        std::fs::create_dir_all(&lib.sources).ok()?;
        Some(lib.sources.clone())
    }

    /// A clip's poster frame.
    pub fn poster(&self, id: &str) -> Option<PathBuf> {
        self.lib.as_ref().map(|l| l.poster(id)).filter(|p| p.is_file())
    }
}

impl Drop for Videos {
    fn drop(&mut self) {
        self.inner.stop.store(true, Ordering::Relaxed);
        self.rescan();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn run(lib: Library, inner: Arc<Inner>) {
    let tools = wo_video::tools_found();
    inner.shelf.lock().unwrap().tools = tools;
    let mut failed: Vec<(String, String, String)> = vec![]; // id, name, why
    loop {
        if inner.stop.load(Ordering::Relaxed) {
            return;
        }
        let gone = lib.prune();
        let ids: Vec<String> = failed.iter().map(|f| f.0.clone()).collect();
        let pending = if tools { lib.pending(&ids) } else { vec![] };
        {
            let mut s = inner.shelf.lock().unwrap();
            let clips = lib.clips();
            if clips != s.clips || gone > 0 {
                s.clips = clips;
                s.version += 1;
            }
            s.waiting = pending.len();
        }
        for (i, p) in pending.iter().enumerate() {
            if inner.stop.load(Ordering::Relaxed) {
                return;
            }
            let name = p.rel.clone();
            // a file still being copied in: its size still changing
            let size = std::fs::metadata(&p.path).map(|m| m.len()).unwrap_or(0);
            std::thread::sleep(Duration::from_millis(400));
            if std::fs::metadata(&p.path).map(|m| m.len()).unwrap_or(0) != size {
                continue;
            }
            {
                let mut s = inner.shelf.lock().unwrap();
                s.making = Some((name.clone(), 0.0));
                s.waiting = pending.len() - i - 1;
            }
            let shelf = &inner.shelf;
            let r = wo_video::import(&p.path, &p.rel, &lib.proxies, &inner.stop, |k| {
                if let Some(m) = shelf.lock().unwrap().making.as_mut() {
                    m.1 = k;
                }
            });
            let mut s = inner.shelf.lock().unwrap();
            s.making = None;
            match r {
                Ok(_) => {
                    s.clips = lib.clips();
                    s.version += 1;
                }
                Err(e) if e == "stopped" => return,
                Err(e) => {
                    eprintln!("footage: {name}: {e}");
                    failed.push((wo_video::import::clip_id(&p.rel, p.size), name.clone(), e.clone()));
                    s.failed = failed.iter().map(|f| (f.1.clone(), f.2.clone())).collect();
                }
            }
        }
        // until it is time, or asked
        let (m, cv) = &inner.poke;
        let mut poked = m.lock().unwrap();
        if !*poked {
            poked = cv.wait_timeout(poked, EVERY).unwrap().0;
        }
        if *poked {
            // asked: the ones that failed are tried again
            failed.clear();
            inner.shelf.lock().unwrap().failed.clear();
        }
        *poked = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clip_put_in_the_folder_is_made_and_shown() {
        if !wo_video::tools_found() {
            eprintln!("no ffmpeg here: skipped");
            return;
        }
        let root = std::env::temp_dir().join(format!("wo-deskcore-videos-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (src, prox) = (root.join("src"), root.join("prox"));
        std::fs::create_dir_all(&src).unwrap();
        let made = std::process::Command::new(wo_video::import::tool("ffmpeg"))
            .args(["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=2", "-pix_fmt", "yuv420p", "-y"])
            .arg(src.join("a.mp4"))
            .status()
            .unwrap();
        assert!(made.success());
        let v = Videos::of(Some(Library::at(&src, &prox)));
        let t = std::time::Instant::now();
        while v.shelf().clips.is_empty() && t.elapsed() < Duration::from_secs(30) {
            std::thread::sleep(Duration::from_millis(100));
        }
        let s = v.shelf();
        assert_eq!(s.clips.len(), 1, "{s:?}");
        assert!(v.poster(&s.clips[0].id).is_some());
        // taken away: its proxy goes too
        std::fs::remove_file(src.join("a.mp4")).unwrap();
        v.rescan();
        let t = std::time::Instant::now();
        while !v.shelf().clips.is_empty() && t.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(v.shelf().clips.is_empty());
        drop(v);
        std::fs::remove_dir_all(&root).ok();
    }
}
