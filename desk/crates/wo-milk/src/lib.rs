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
    /// Times the reader lost step with the frames.
    resyncs: AtomicU64,
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
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
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
