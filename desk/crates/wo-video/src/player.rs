//! The frames the stage asks for, decoded on a thread of their own: the one wanted now first,
//! then the few after it (the clock says which come next), kept a while — a stutter shows
//! the same frames again and again, a cut jumps back.
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

use crate::proxy::{Picture, Proxy};

/// Frames kept decoded (540p RGBA: 1.5 MB each).
const KEPT: usize = 24;

#[derive(Default)]
struct Ask {
    path: Option<PathBuf>,
    frame: usize,
    ahead: Vec<usize>,
    seq: u64,
    quit: bool,
}

/// A decoded frame of a clip.
#[derive(Clone, Debug)]
pub struct Shown {
    pub path: PathBuf,
    pub frame: usize,
    pub picture: Arc<Picture>,
}

#[derive(Default)]
struct Out {
    newest: Option<Shown>,
    /// The proxy that would not open (the stage says so once).
    broken: Option<(PathBuf, String)>,
    decoded: u64,
}

pub struct Player {
    ask: Arc<(Mutex<Ask>, Condvar)>,
    out: Arc<Mutex<Out>>,
    thread: Option<JoinHandle<()>>,
}

impl Default for Player {
    fn default() -> Self {
        Player::new()
    }
}

impl Player {
    pub fn new() -> Player {
        let ask = Arc::new((Mutex::new(Ask::default()), Condvar::new()));
        let out = Arc::new(Mutex::new(Out::default()));
        let (a, o) = (ask.clone(), out.clone());
        let thread = std::thread::Builder::new().name("wo-video".into()).spawn(move || run(a, o)).ok();
        Player { ask, out, thread }
    }

    /// Frame `frame` of the proxy at `path` wanted now, and `ahead` soon.
    pub fn ask(&self, path: &Path, frame: usize, ahead: &[usize]) {
        let (m, cv) = &*self.ask;
        let mut a = m.lock().unwrap();
        if a.path.as_deref() == Some(path) && a.frame == frame && a.ahead == ahead {
            return;
        }
        a.path = Some(path.into());
        a.frame = frame;
        a.ahead = ahead.to_vec();
        a.seq += 1;
        cv.notify_one();
    }

    /// Nothing wanted (the frames kept are let go).
    pub fn idle(&self) {
        let (m, cv) = &*self.ask;
        let mut a = m.lock().unwrap();
        if a.path.is_some() {
            a.path = None;
            a.seq += 1;
            cv.notify_one();
        }
    }

    /// The newest frame decoded of what was asked.
    pub fn newest(&self) -> Option<Shown> {
        self.out.lock().unwrap().newest.clone()
    }

    /// A proxy that would not open, once.
    pub fn take_broken(&self) -> Option<(PathBuf, String)> {
        self.out.lock().unwrap().broken.take()
    }

    pub fn decoded(&self) -> u64 {
        self.out.lock().unwrap().decoded
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        {
            let (m, cv) = &*self.ask;
            m.lock().unwrap().quit = true;
            cv.notify_one();
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn run(ask: Arc<(Mutex<Ask>, Condvar)>, out: Arc<Mutex<Out>>) {
    let mut open: Option<(PathBuf, Proxy)> = None;
    let mut failed: Option<PathBuf> = None;
    let mut kept: VecDeque<(usize, Arc<Picture>)> = VecDeque::new();
    let mut seen = 0u64;
    let mut shown: Option<usize> = None;
    loop {
        // what is wanted, waiting while nothing is new and nothing is left to get ahead
        let (path, frame, ahead) = {
            let (m, cv) = &*ask;
            let mut a = m.lock().unwrap();
            loop {
                if a.quit {
                    return;
                }
                let more_ahead = a.ahead.iter().any(|f| !kept.iter().any(|(k, _)| k == f));
                if a.seq != seen || (a.path.is_some() && more_ahead && failed.as_ref() != a.path.as_ref()) {
                    break;
                }
                a = cv.wait(a).unwrap();
            }
            seen = a.seq;
            (a.path.clone(), a.frame, a.ahead.clone())
        };
        let Some(path) = path else {
            open = None;
            kept.clear();
            shown = None;
            continue;
        };
        if open.as_ref().is_none_or(|(p, _)| *p != path) {
            kept.clear();
            shown = None;
            match Proxy::open(&path) {
                Ok(p) => {
                    open = Some((path.clone(), p));
                    failed = None;
                }
                Err(e) => {
                    open = None;
                    if failed.as_ref() != Some(&path) {
                        out.lock().unwrap().broken = Some((path.clone(), e.to_string()));
                    }
                    failed = Some(path);
                    continue;
                }
            }
        }
        let (_, proxy) = open.as_mut().unwrap();
        let last = proxy.frames().saturating_sub(1);
        let frame = frame.min(last);
        let mut get = |f: usize, kept: &mut VecDeque<(usize, Arc<Picture>)>| -> Option<Arc<Picture>> {
            if let Some(i) = kept.iter().position(|(k, _)| *k == f) {
                let e = kept.remove(i).unwrap();
                kept.push_back(e.clone());
                return Some(e.1);
            }
            let p = Arc::new(proxy.rgba(f).ok()?);
            kept.push_back((f, p.clone()));
            while kept.len() > KEPT {
                kept.pop_front();
            }
            out.lock().unwrap().decoded += 1;
            Some(p)
        };
        if shown != Some(frame)
            && let Some(p) = get(frame, &mut kept)
        {
            shown = Some(frame);
            out.lock().unwrap().newest = Some(Shown { path: path.clone(), frame, picture: p });
        }
        // one frame ahead, then back to see whether the ask has changed
        if let Some(&f) = ahead.iter().find(|f| !kept.iter().any(|(k, _)| k == *f)) {
            let f = f.min(last);
            if get(f, &mut kept).is_none() {
                // a frame that will not decode: kept as the one before, so it is not tried forever
                if let Some(last) = kept.back().map(|k| k.1.clone()) {
                    kept.push_back((f, last));
                }
            }
        }
    }
}
