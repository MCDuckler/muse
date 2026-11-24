//! MilkDrop for the Rust stage (plan §2.4): the wetowl-milk helper (app/native/milk: projectM
//! drawn offscreen through EGL, WGL or CGL) started as a child and driven over its pipes —
//! commands on stdin, frames on stdout (`MILK` + u32 width + height + sequence, then RGBA,
//! top row first), its word on stderr. The stage keeps only the newest frame: one that waits
//! is dropped for the next, as the v1 feed does.
//!
//! Nothing said to it waits on it: its stdin is written on a thread of its own. A helper only
//! reads once it has OpenGL and projectM open (a second or so after it starts), and a pipe
//! holds a few KB, so the stage's frame used to stop there, every time MilkDrop came on. What
//! is said again every frame (the numbers, the levels, the sound) is dropped while it is
//! behind; commands (a preset, the rate, the lock) always go.
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

/// Every-frame words held for a helper that is behind, at most: past this they are dropped.
const BEHIND: usize = 32 * 1024;

/// A frame of MilkDrop's.
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub seq: u32,
    pub rgba: Vec<u8>,
}

#[derive(Default)]
struct Shared {
    newest: Mutex<Option<Frame>>,
    said: Mutex<Vec<String>>,
    frames: AtomicU64,
    /// Times the reader lost step with the frames.
    resyncs: AtomicU64,
    alive: AtomicBool,
    out: Mutex<Outbox>,
    ring: Condvar,
}

/// What waits to be written to the helper.
#[derive(Default)]
struct Outbox {
    q: VecDeque<Vec<u8>>,
    bytes: usize,
    /// No more: the writer goes once it has written what is held.
    closed: bool,
    /// Writing failed (the helper is gone).
    broken: bool,
    dropped: u64,
}

impl Outbox {
    /// Holds `b` to be written; one `may_drop` is not held while more than BEHIND waits.
    fn put(&mut self, b: Vec<u8>, may_drop: bool) -> bool {
        if may_drop && self.bytes > BEHIND {
            self.dropped += 1;
            return false;
        }
        self.bytes += b.len();
        self.q.push_back(b);
        true
    }

    fn next(&mut self) -> Option<Vec<u8>> {
        let b = self.q.pop_front()?;
        self.bytes -= b.len();
        Some(b)
    }
}

pub struct Milk {
    child: Child,
    shared: Arc<Shared>,
}

impl Milk {
    /// Starts the helper at `program`, drawing `width`×`height` at `fps`, presets'
    /// textures looked for in `textures`.
    pub fn start(program: &Path, width: u32, height: u32, fps: u32, textures: Option<&Path>) -> std::io::Result<Milk> {
        let mut cmd = Command::new(program);
        cmd.arg("--size").arg(format!("{width}x{height}")).arg("--fps").arg(fps.to_string());
        if let Some(t) = textures {
            cmd.arg("--textures").arg(t);
        }
        let mut child = cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
        let mut stdin = child.stdin.take().expect("piped");
        let mut stdout = child.stdout.take().expect("piped");
        let stderr = child.stderr.take().expect("piped");
        let shared = Arc::new(Shared::default());
        shared.alive.store(true, Ordering::Relaxed);
        let s = shared.clone();
        thread::Builder::new().name("milk words in".into()).spawn(move || {
            loop {
                let b = {
                    let mut out = s.out.lock().unwrap();
                    loop {
                        if let Some(b) = out.next() {
                            break b;
                        }
                        if out.closed {
                            return;
                        }
                        out = s.ring.wait(out).unwrap();
                    }
                };
                if stdin.write_all(&b).and_then(|_| stdin.flush()).is_err() {
                    let mut out = s.out.lock().unwrap();
                    out.broken = true;
                    out.q.clear();
                    out.bytes = 0;
                    return;
                }
            }
        })?;
        let s = shared.clone();
        thread::Builder::new().name("milk frames".into()).spawn(move || {
            let mut head = [0u8; 16];
            loop {
                if stdout.read_exact(&mut head).is_err() {
                    break;
                }
                if head[..4] != *b"MILK" {
                    // out of step: look for the next header a byte at a time, and take the
                    // header found whole (its size and number follow the four letters)
                    s.resyncs.fetch_add(1, Ordering::Relaxed);
                    let mut b = [0u8; 1];
                    let mut tail: Vec<u8> = head[1..].to_vec();
                    while tail[..4] != *b"MILK" {
                        if stdout.read_exact(&mut b).is_err() {
                            s.alive.store(false, Ordering::Relaxed);
                            return;
                        }
                        tail.remove(0);
                        tail.push(b[0]);
                    }
                    head[..15].copy_from_slice(&tail);
                    if stdout.read_exact(&mut head[15..]).is_err() {
                        break;
                    }
                }
                let word = |i: usize| u32::from_le_bytes(head[i..i + 4].try_into().unwrap());
                let (w, h, seq) = (word(4), word(8), word(12));
                if w == 0 || h == 0 || w > 8192 || h > 8192 {
                    break;
                }
                let mut rgba = vec![0u8; (w * h * 4) as usize];
                if stdout.read_exact(&mut rgba).is_err() {
                    break;
                }
                *s.newest.lock().unwrap() = Some(Frame { width: w, height: h, seq, rgba });
                s.frames.fetch_add(1, Ordering::Relaxed);
            }
            s.alive.store(false, Ordering::Relaxed);
        })?;
        let s = shared.clone();
        thread::Builder::new().name("milk words".into()).spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                let mut said = s.said.lock().unwrap();
                said.push(line);
                if said.len() > 200 {
                    said.remove(0);
                }
            }
        })?;
        Ok(Milk { child, shared })
    }

    fn put(&mut self, b: Vec<u8>, may_drop: bool) -> std::io::Result<()> {
        let mut out = self.shared.out.lock().unwrap();
        if out.broken || out.closed {
            return Err(std::io::ErrorKind::BrokenPipe.into());
        }
        if out.put(b, may_drop) {
            self.shared.ring.notify_one();
        }
        Ok(())
    }

    /// A command line (`preset PATH`, `size W H`, `fps N`, `lock N`), always sent, in order.
    /// It never waits for the helper.
    pub fn say(&mut self, line: &str) -> std::io::Result<()> {
        self.put(format!("{line}\n").into_bytes(), false)
    }

    /// A line said again every frame (`vars …`, `audio …`): dropped while the helper is
    /// behind, as the next frame's says it again.
    pub fn feed(&mut self, line: &str) -> std::io::Result<()> {
        self.put(format!("{line}\n").into_bytes(), true)
    }

    /// Mono 16-bit samples at 44.1 kHz (the room's sound); dropped, like `feed`, while the
    /// helper is behind.
    pub fn pcm(&mut self, samples: &[i16]) -> std::io::Result<()> {
        let mut b = Vec::with_capacity(16 + samples.len() * 2);
        b.extend_from_slice(format!("pcm {}\n", samples.len()).as_bytes());
        for s in samples {
            b.extend_from_slice(&s.to_le_bytes());
        }
        self.put(b, true)
    }

    /// Every-frame words dropped so far because the helper was behind.
    pub fn dropped(&self) -> u64 {
        self.shared.out.lock().unwrap().dropped
    }

    /// The newest frame, if one came since the last take.
    pub fn take(&self) -> Option<Frame> {
        self.shared.newest.lock().unwrap().take()
    }

    /// Frames read so far.
    pub fn frames(&self) -> u64 {
        self.shared.frames.load(Ordering::Relaxed)
    }

    /// Times the reader lost step with the frames (and found it again).
    pub fn resyncs(&self) -> u64 {
        self.shared.resyncs.load(Ordering::Relaxed)
    }

    pub fn alive(&self) -> bool {
        self.shared.alive.load(Ordering::Relaxed)
    }

    /// What it said on stderr since the last ask.
    pub fn said(&self) -> Vec<String> {
        std::mem::take(&mut *self.shared.said.lock().unwrap())
    }
}

impl Drop for Milk {
    fn drop(&mut self) {
        let _ = self.say("quit");
        {
            let mut out = self.shared.out.lock().unwrap();
            out.closed = true;
            self.shared.ring.notify_one();
        }
        // the writer, stuck on a helper that does not read, is let go by its end
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    #[test]
    fn a_helper_not_reading_yet_holds_nothing_up() {
        // a stand-in that reads nothing for seconds, as the helper while it opens OpenGL
        let (program, args): (&str, &[&str]) = if cfg!(windows) { ("ping", &["-n", "4", "127.0.0.1"]) } else { ("sleep", &["3"]) };
        let dir = std::env::temp_dir().join(format!("wo-milk-slow-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = if cfg!(windows) {
            let s = dir.join("slow.cmd");
            std::fs::write(&s, format!("@{program} {} >nul\r\n", args.join(" "))).unwrap();
            s
        } else {
            let s = dir.join("slow.sh");
            std::fs::write(&s, format!("#!/bin/sh\n{program} {}\n", args.join(" "))).unwrap();
            std::process::Command::new("chmod").arg("+x").arg(&s).status().unwrap();
            s
        };
        let mut m = super::Milk::start(&script, 960, 540, 60, None).unwrap();
        let t0 = Instant::now();
        m.say("preset a.milk").unwrap();
        // two seconds of a stage's frames: the numbers, the levels and the sound
        let second = vec![0i16; 588];
        for _ in 0..150 {
            m.feed(&format!("vars {}", "x=0.5000 ".repeat(60))).unwrap();
            m.feed("audio 1.000 1.000 1.000 1.000 1.000 1.000").unwrap();
            m.pcm(&second).unwrap();
        }
        m.say("lock 1").unwrap();
        let took = t0.elapsed();
        assert!(took < Duration::from_millis(300), "the caller waited {took:?}");
        assert!(m.dropped() > 0, "what came again every frame dropped while it was behind");
        {
            let out = m.shared.out.lock().unwrap();
            let held: Vec<String> = out.q.iter().map(|b| String::from_utf8_lossy(&b[..b.len().min(12)]).into_owned()).collect();
            assert!(held.iter().any(|l| l.starts_with("lock 1")), "a command is never dropped");
            assert!(out.bytes <= super::BEHIND + 4096, "{} bytes held", out.bytes);
        }
        let t1 = Instant::now();
        drop(m);
        assert!(t1.elapsed() < Duration::from_secs(2), "let go of at once");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn noise_between_frames_is_skipped_and_the_frames_go_on() {
        // a stand-in helper: three frames with noise before and between them
        let dir = std::env::temp_dir().join(format!("wo-milk-noise-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let frame = |seq: u8| {
            let mut b = b"MILK".to_vec();
            b.extend(2u32.to_le_bytes());
            b.extend(1u32.to_le_bytes());
            b.extend((seq as u32).to_le_bytes());
            b.extend([seq; 8]);
            b
        };
        let mut bytes = b"noise MIL".to_vec();
        bytes.extend(frame(1));
        bytes.extend(b"xyz");
        bytes.extend(frame(2));
        bytes.extend(frame(3));
        let data = dir.join("frames.bin");
        std::fs::write(&data, &bytes).unwrap();
        let script = dir.join("helper.sh");
        std::fs::write(&script, format!("#!/bin/sh\ncat '{}'\nsleep 2\n", data.display())).unwrap();
        std::process::Command::new("chmod").arg("+x").arg(&script).status().unwrap();
        let m = super::Milk::start(&script, 2, 1, 60, None).unwrap();
        let t0 = std::time::Instant::now();
        while m.frames() < 3 && t0.elapsed().as_secs() < 2 {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(m.frames(), 3, "every frame read");
        assert_eq!(m.resyncs(), 2, "found again twice");
        let f = m.take().unwrap();
        assert_eq!((f.width, f.height, f.seq, f.rgba[0]), (2, 1, 3, 3));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
