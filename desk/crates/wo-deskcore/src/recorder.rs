//! REC (rekordbox's recording): the master as the room hears it into a WAV file, 16-bit
//! stereo at the engine's rate, in the music folder's "WetOwl recordings"; a worker drains
//! the engine's ring every 50 ms and the header is put right when it stops.
use std::io::{Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::{Desk, RATE};

#[derive(Default)]
pub(crate) struct Recorder {
    run: Option<(Arc<AtomicBool>, JoinHandle<Result<PathBuf, String>>, Instant)>,
    frames: Arc<AtomicI64>,
    dropped: Arc<AtomicI64>,
    /// The last recording's file, or why it failed.
    pub(crate) last: Option<Result<PathBuf, String>>,
}

/// Where recordings go: the music folder's "WetOwl recordings" (else the home's).
fn folder() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).map(PathBuf::from)?;
    let music = home.join("Music");
    Some(if music.is_dir() { music } else { home }.join("WetOwl recordings"))
}

fn header(frames: u32) -> Vec<u8> {
    let data = frames * 4;
    let mut h = b"RIFF".to_vec();
    h.extend((36 + data).to_le_bytes());
    h.extend(b"WAVEfmt ");
    h.extend(16u32.to_le_bytes());
    h.extend(1u16.to_le_bytes());
    h.extend(2u16.to_le_bytes());
    h.extend(RATE.to_le_bytes());
    h.extend((RATE * 4).to_le_bytes());
    h.extend(4u16.to_le_bytes());
    h.extend(16u16.to_le_bytes());
    h.extend(b"data");
    h.extend(data.to_le_bytes());
    h
}

/// A recording's state: its time so far, frames lost to a slow disk.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RecView {
    pub on: bool,
    pub seconds: f64,
    pub dropped: i64,
}

impl Desk {
    pub fn recording(&self) -> RecView {
        RecView { on: self.recorder.run.is_some(), seconds: self.recorder.frames.load(Ordering::Relaxed) as f64 / RATE as f64, dropped: self.recorder.dropped.load(Ordering::Relaxed) }
    }

    /// The last recording's file (or why it failed), once one has stopped.
    pub fn last_recording(&self) -> Option<Result<PathBuf, String>> {
        self.recorder.last.clone()
    }

    /// REC on: a new file named for now; off: the file closed.
    pub fn toggle_recording(&mut self) {
        if let Some((stop, h, _)) = self.recorder.run.take() {
            stop.store(true, Ordering::Relaxed);
            self.engine.record(false);
            self.recorder.last = Some(h.join().unwrap_or_else(|_| Err("the recorder stopped".into())));
            self.changes += 1;
            return;
        }
        let Some(dir) = folder() else {
            self.recorder.last = Some(Err("no home folder to record into".into()));
            return;
        };
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let path = dir.join(format!("WetOwl set {stamp}.wav"));
        let engine = self.engine.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let (s2, frames, dropped) = (stop.clone(), self.recorder.frames.clone(), self.recorder.dropped.clone());
        frames.store(0, Ordering::Relaxed);
        dropped.store(0, Ordering::Relaxed);
        engine.record(true);
        let h = thread::Builder::new()
            .name("recorder".into())
            .spawn(move || -> Result<PathBuf, String> {
                std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
                let mut f = std::io::BufWriter::new(std::fs::File::create(&path).map_err(|e| e.to_string())?);
                f.write_all(&header(0)).map_err(|e| e.to_string())?;
                let mut buf = vec![0f32; RATE as usize * 2];
                let mut total: u64 = 0;
                loop {
                    let last = s2.load(Ordering::Relaxed);
                    loop {
                        let (n, lost) = engine.record_read(&mut buf);
                        dropped.store(lost, Ordering::Relaxed);
                        if n == 0 {
                            break;
                        }
                        let bytes: Vec<u8> = buf[..n * 2].iter().flat_map(|v| ((v.clamp(-1.0, 1.0) * 32_767.0) as i16).to_le_bytes()).collect();
                        f.write_all(&bytes).map_err(|e| e.to_string())?;
                        total += n as u64;
                        frames.store(total as i64, Ordering::Relaxed);
                    }
                    if last {
                        break;
                    }
                    thread::sleep(Duration::from_millis(50));
                }
                f.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
                f.write_all(&header(total.min(u32::MAX as u64 / 4) as u32)).map_err(|e| e.to_string())?;
                f.flush().map_err(|e| e.to_string())?;
                Ok(path)
            })
            .expect("the recorder's thread");
        self.recorder.run = Some((stop, h, Instant::now()));
        self.changes += 1;
    }
}
