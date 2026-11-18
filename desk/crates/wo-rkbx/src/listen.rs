//! Listening to rkbx_link on a UDP port, on a thread of its own, optionally writing
//! every message to a capture file as it comes.
use std::io::{self, BufWriter, Write};
use std::net::UdpSocket;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::capture::{self, Heard};
use crate::feed::{Feed, View};

/// Where rkbx_link sends by default (`osc.destination`).
pub const DEFAULT_ADDR: &str = "127.0.0.1:4460";

/// A running listener; it stops when dropped.
pub struct Listener {
    feed: Arc<Mutex<Feed>>,
    stop: Arc<AtomicBool>,
    packets: Arc<AtomicU64>,
    epoch: Instant,
    thread: Option<JoinHandle<()>>,
}

impl Listener {
    /// Listen on `addr` (e.g. [`DEFAULT_ADDR`]); with `capture`, every message also goes
    /// to that file (created anew).
    pub fn start(addr: &str, capture: Option<&Path>) -> io::Result<Listener> {
        let sock = UdpSocket::bind(addr)?;
        sock.set_read_timeout(Some(Duration::from_millis(200)))?;
        let mut out = match capture {
            Some(p) => {
                let mut w = BufWriter::new(std::fs::File::create(p)?);
                writeln!(w, "# wo-rkbx capture: rkbx_link OSC heard on {addr}; seconds since the start")?;
                Some(w)
            }
            None => None,
        };
        let feed = Arc::new(Mutex::new(Feed::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let packets = Arc::new(AtomicU64::new(0));
        let epoch = Instant::now();
        let thread = {
            let (feed, stop, packets) = (feed.clone(), stop.clone(), packets.clone());
            std::thread::Builder::new().name("wo-rkbx".into()).spawn(move || {
                let mut buf = vec![0u8; 65536];
                let mut flushed = Instant::now();
                while !stop.load(Ordering::Relaxed) {
                    let n = match sock.recv(&mut buf) {
                        Ok(n) => n,
                        Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => continue,
                        // Windows reports an ICMP "port unreachable" from an earlier send as an error here
                        Err(e) if e.kind() == io::ErrorKind::ConnectionReset => continue,
                        Err(_) => break,
                    };
                    let t = epoch.elapsed().as_secs_f64();
                    packets.fetch_add(1, Ordering::Relaxed);
                    let msgs = crate::osc::parse(&buf[..n]);
                    if let Some(w) = out.as_mut() {
                        for m in &msgs {
                            let _ = writeln!(w, "{}", capture::line(&Heard { t, msg: m.clone() }));
                        }
                        if flushed.elapsed() > Duration::from_secs(1) {
                            let _ = w.flush();
                            flushed = Instant::now();
                        }
                    }
                    let mut f = feed.lock().unwrap();
                    for m in &msgs {
                        f.apply(m, t);
                    }
                }
                if let Some(w) = out.as_mut() {
                    let _ = w.flush();
                }
            })?
        };
        Ok(Listener { feed, stop, packets, epoch, thread: Some(thread) })
    }

    /// The decks now.
    pub fn view(&self) -> View {
        self.feed.lock().unwrap().view(self.now())
    }

    /// Seconds since the listener started (the clock of its feed and capture).
    pub fn now(&self) -> f64 {
        self.epoch.elapsed().as_secs_f64()
    }

    /// Packets heard so far.
    pub fn packets(&self) -> u64 {
        self.packets.load(Ordering::Relaxed)
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::{Arg, Msg, encode};

    #[test]
    fn hears_and_captures() {
        let dir = std::env::temp_dir().join(format!("wo-rkbx-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let cap = dir.join("cap.txt");
        // a free port: bind, read it back, let go
        let port = UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let addr = format!("127.0.0.1:{port}");
        let l = Listener::start(&addr, Some(&cap)).unwrap();
        let tx = UdpSocket::bind("127.0.0.1:0").unwrap();
        tx.send_to(&encode(&Msg::new("/0/track/title", vec![Arg::Str("Cairo FM".into())])), &addr).unwrap();
        for i in 0..10 {
            tx.send_to(&encode(&Msg::new("/0/time", vec![Arg::Float(40.0 + i as f32 * 0.02)])), &addr).unwrap();
            std::thread::sleep(Duration::from_millis(20));
        }
        let v = l.view();
        assert_eq!(l.packets(), 11);
        assert_eq!(v.decks[0].title, "Cairo FM");
        assert!(v.decks[0].playing);
        drop(l);
        let heard = capture::read(io::BufReader::new(std::fs::File::open(&cap).unwrap())).unwrap();
        assert_eq!(heard.len(), 11);
        assert_eq!(heard[0].msg.text(), Some("Cairo FM"));
        let _ = std::fs::remove_file(&cap);
        let _ = std::fs::remove_dir(&dir);
    }
}
