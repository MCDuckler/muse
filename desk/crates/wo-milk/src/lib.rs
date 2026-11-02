//! MilkDrop for the Rust stage (plan §2.4): the wetowl-milk helper (app/native/milk: projectM
//! drawn offscreen through EGL, WGL or CGL) started as a child and driven over its pipes —
//! commands on stdin, frames on stdout (`MILK` + u32 width + height + sequence, then RGBA,
//! top row first), its word on stderr. The stage keeps only the newest frame: one that waits
//! is dropped for the next, as the v1 feed does.
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

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
    alive: AtomicBool,
}

pub struct Milk {
    child: Child,
    stdin: ChildStdin,
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
        let stdin = child.stdin.take().expect("piped");
        let mut stdout = child.stdout.take().expect("piped");
        let stderr = child.stderr.take().expect("piped");
        let shared = Arc::new(Shared::default());
        shared.alive.store(true, Ordering::Relaxed);
        let s = shared.clone();
        thread::Builder::new().name("milk frames".into()).spawn(move || {
            let mut head = [0u8; 16];
            loop {
                if stdout.read_exact(&mut head).is_err() {
                    break;
                }
                let word = |i: usize| u32::from_le_bytes(head[i..i + 4].try_into().unwrap());
                if word(0) != 0x4b4c_494d {
                    // out of step: look for the next header a byte at a time
                    let mut b = [0u8; 1];
                    let mut tail = head[1..].to_vec();
                    loop {
                        if stdout.read_exact(&mut b).is_err() {
                            return;
                        }
                        tail.push(b[0]);
                        if tail.len() > 15 {
                            tail.remove(0);
                        }
                        if tail.len() == 15 && tail[..3] == *b"MIL" && tail[3] == b'K' {
                            break;
                        }
                    }
                    continue;
                }
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
        Ok(Milk { child, stdin, shared })
    }

    /// A command line (`preset PATH`, `size W H`, `fps N`, `audio …`, `vars …`).
    pub fn say(&mut self, line: &str) -> std::io::Result<()> {
        self.stdin.write_all(line.as_bytes())?;
        self.stdin.write_all(b"\n")?;
        self.stdin.flush()
    }

    /// Mono 16-bit samples at 44.1 kHz (the room's sound).
    pub fn pcm(&mut self, samples: &[i16]) -> std::io::Result<()> {
        let mut b = Vec::with_capacity(16 + samples.len() * 2);
        b.extend_from_slice(format!("pcm {}\n", samples.len()).as_bytes());
        for s in samples {
            b.extend_from_slice(&s.to_le_bytes());
        }
        self.stdin.write_all(&b)?;
        self.stdin.flush()
    }

    /// The newest frame, if one came since the last take.
    pub fn take(&self) -> Option<Frame> {
        self.shared.newest.lock().unwrap().take()
    }

    /// Frames read so far.
    pub fn frames(&self) -> u64 {
        self.shared.frames.load(Ordering::Relaxed)
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
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
