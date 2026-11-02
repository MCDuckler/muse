//! The Desk's end: a WebSocket on the loopback that stage windows connect to
//! (`/stage?t=<token>`, as the v1 booth's link serves them), each read and written on
//! a thread of its own. What the Desk says goes to every stage; a stage that falls
//! behind misses frames rather than holding the Desk up.
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::io::{self, ErrorKind};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tungstenite::{Message, WebSocket};

use crate::Shown;

/// At most this many stages at once (v1's limit).
const MOST: usize = 4;
/// Lines waiting for a slow stage before its next frames are dropped.
const BACKLOG: usize = 16;

/// The stage's picture: RGBA, top row first.
#[derive(Clone, Debug, PartialEq)]
pub struct Thumb {
    pub width: usize,
    pub height: usize,
    pub rgba: Vec<u8>,
}

impl Thumb {
    /// Four bytes of size (little-endian width, height), then the pixels; None for
    /// anything else.
    pub fn parse(b: &[u8]) -> Option<Thumb> {
        if b.len() < 4 {
            return None;
        }
        let (w, h) = (u16::from_le_bytes([b[0], b[1]]) as usize, u16::from_le_bytes([b[2], b[3]]) as usize);
        if w == 0 || h == 0 || w > 1024 || h > 1024 || b.len() != 4 + w * h * 4 {
            return None;
        }
        Some(Thumb { width: w, height: h, rgba: b[4..].to_vec() })
    }
}

struct Link {
    tx: SyncSender<Message>,
    alive: Arc<AtomicBool>,
}

#[derive(Default)]
struct Heard {
    links: Vec<Link>,
    /// The newest picture, counted.
    thumb: Option<(u64, Arc<Thumb>)>,
    shown: Option<Shown>,
    /// What a stage is told first (crate::hello), with the Desk's house once signed in.
    hello: Option<String>,
    /// Lines a stage connecting later is told after the hello, newest by key (v2: each
    /// deck's record, the cue).
    kept: std::collections::BTreeMap<String, String>,
    /// Stages that said they are v2 (the Rust stage).
    v2: usize,
}

pub struct Server {
    port: u16,
    token: String,
    heard: Arc<Mutex<Heard>>,
    stop: Arc<AtomicBool>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        // the accepting thread wakes on a connection
        let _ = TcpStream::connect(("127.0.0.1", self.port));
    }
}

fn token() -> String {
    let mut h = RandomState::new().build_hasher();
    h.write_u64(std::process::id() as u64);
    let a = h.finish();
    let mut h = RandomState::new().build_hasher();
    h.write_u64(a);
    format!("{a:016x}{:016x}", h.finish())
}

impl Server {
    /// Listening on the loopback, on a port of the system's choosing.
    pub fn open() -> io::Result<Server> {
        let listener = TcpListener::bind(("127.0.0.1", 0))?;
        let port = listener.local_addr()?.port();
        let token = token();
        let heard = Arc::new(Mutex::new(Heard::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let (h, st, t) = (heard.clone(), stop.clone(), token.clone());
        thread::spawn(move || {
            for stream in listener.incoming() {
                if st.load(Ordering::Relaxed) {
                    break;
                }
                let Ok(stream) = stream else { continue };
                if h.lock().unwrap().links.len() >= MOST {
                    continue;
                }
                let (h, t) = (h.clone(), t.clone());
                thread::spawn(move || serve(stream, &t, h));
            }
        });
        Ok(Server { port, token, heard, stop })
    }

    /// Where a stage connects: `wetowl --stage <url>`.
    pub fn url(&self) -> String {
        format!("ws://127.0.0.1:{}/stage?t={}", self.port, self.token)
    }

    /// A line to every stage.
    pub fn say(&self, line: &str) {
        self.send(Message::text(line));
    }

    /// Binary to every stage (the room's sound, crate::pcm).
    pub fn say_binary(&self, bytes: Vec<u8>) {
        self.send(Message::binary(bytes));
    }

    /// The hello a stage connecting from now on is told, and the stages reading now too.
    pub fn set_hello(&self, line: String) {
        self.heard.lock().unwrap().hello = Some(line.clone());
        self.say(&line);
    }

    fn send(&self, m: Message) {
        let mut h = self.heard.lock().unwrap();
        h.links.retain(|l| l.alive.load(Ordering::Relaxed));
        for l in &h.links {
            match l.tx.try_send(m.clone()) {
                Ok(()) | Err(TrySendError::Full(_)) => {}
                Err(TrySendError::Disconnected(_)) => l.alive.store(false, Ordering::Relaxed),
            }
        }
    }

    /// A line to every stage, and to every stage that connects from now on (the newest of
    /// its `key`).
    pub fn keep(&self, key: &str, line: String) {
        self.heard.lock().unwrap().kept.insert(key.to_owned(), line.clone());
        self.say(&line);
    }

    /// Whether a v2 stage (one the Desk directs) is reading.
    pub fn v2(&self) -> bool {
        self.heard.lock().unwrap().v2 > 0
    }

    /// How many stages are reading.
    pub fn stages(&self) -> usize {
        let h = self.heard.lock().unwrap();
        h.links.iter().filter(|l| l.alive.load(Ordering::Relaxed)).count()
    }

    /// The newest picture a stage sent, and its count (a new count is a new picture).
    pub fn thumb(&self) -> Option<(u64, Arc<Thumb>)> {
        self.heard.lock().unwrap().thumb.clone()
    }

    pub fn shown(&self) -> Option<Shown> {
        self.heard.lock().unwrap().shown.clone()
    }
}

/// One stage, from its handshake to its going.
fn serve(stream: TcpStream, token: &str, heard: Arc<Mutex<Heard>>) {
    let _ = stream.set_nodelay(true);
    let want = format!("t={token}");
    // tungstenite's callback: its error type is its own
    #[allow(clippy::result_large_err)]
    let check = |req: &Request, resp: Response| -> Result<Response, ErrorResponse> {
        let uri = req.uri();
        if uri.path() == "/stage" && uri.query().is_some_and(|q| q.split('&').any(|kv| kv == want)) {
            Ok(resp)
        } else {
            let mut no = ErrorResponse::new(Some("not a stage of this Desk".into()));
            *no.status_mut() = tungstenite::http::StatusCode::FORBIDDEN;
            Err(no)
        }
    };
    let Ok(mut ws) = tungstenite::accept_hdr(stream, check) else { return };
    // woken every few milliseconds to send what the Desk said meanwhile
    let _ = ws.get_ref().set_read_timeout(Some(Duration::from_millis(4)));
    let (tx, rx) = mpsc::sync_channel::<Message>(BACKLOG);
    let alive = Arc::new(AtomicBool::new(true));
    let (hello, kept) = {
        let mut h = heard.lock().unwrap();
        h.links.push(Link { tx, alive: alive.clone() });
        (h.hello.clone().unwrap_or_else(|| crate::hello(None)), h.kept.values().cloned().collect::<Vec<_>>())
    };
    let _ = ws.send(Message::text(hello));
    for k in kept {
        let _ = ws.send(Message::text(k));
    }
    let mut v2 = false;
    run(&mut ws, &rx, &alive, &heard, &mut v2);
    alive.store(false, Ordering::Relaxed);
    let mut h = heard.lock().unwrap();
    if v2 {
        h.v2 -= 1;
    }
    h.links.retain(|l| l.alive.load(Ordering::Relaxed));
    if h.links.is_empty() {
        h.thumb = None;
        h.shown = None;
    }
}

fn run(ws: &mut WebSocket<TcpStream>, rx: &Receiver<Message>, alive: &AtomicBool, heard: &Mutex<Heard>, v2: &mut bool) {
    while alive.load(Ordering::Relaxed) {
        let mut wrote = false;
        while let Ok(m) = rx.try_recv() {
            if ws.write(m).is_err() {
                return;
            }
            wrote = true;
        }
        if wrote && ws.flush().is_err() {
            return;
        }
        match ws.read() {
            Ok(Message::Binary(b)) => {
                if let Some(t) = Thumb::parse(&b) {
                    let mut h = heard.lock().unwrap();
                    let n = h.thumb.as_ref().map_or(0, |(n, _)| n + 1);
                    h.thumb = Some((n, Arc::new(t)));
                }
            }
            Ok(Message::Text(t)) => {
                if t.as_str() == crate::v2::STAGE_HELLO {
                    if !*v2 {
                        *v2 = true;
                        heard.lock().unwrap().v2 += 1;
                    }
                } else if t.starts_with(r#"{"t":"ping""#) {
                    let _ = ws.send(Message::text(t.replacen("\"ping\"", "\"pong\"", 1)));
                } else if let Some(s) = crate::shown(&t) {
                    heard.lock().unwrap().shown = Some(s);
                }
            }
            Ok(Message::Close(_)) => return,
            Ok(_) => {}
            Err(tungstenite::Error::Io(e)) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
            Err(_) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thumbs_read_as_the_stage_writes_them() {
        let mut b = vec![2, 0, 1, 0];
        b.extend([1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(Thumb::parse(&b), Some(Thumb { width: 2, height: 1, rgba: vec![1, 2, 3, 4, 5, 6, 7, 8] }));
        assert_eq!(Thumb::parse(&b[..10]), None, "short");
        assert_eq!(Thumb::parse(&[0, 0, 1, 0]), None);
    }

    #[test]
    fn a_stage_connects_hears_the_desk_and_sends_its_picture() {
        let server = Server::open().unwrap();
        // a stranger without the token is turned away
        let bad = server.url().replace("t=", "t=x");
        assert!(tungstenite::connect(bad).is_err());
        let (mut ws, _) = tungstenite::connect(server.url()).unwrap();
        let hello = ws.read().unwrap();
        assert_eq!(hello.to_text().unwrap(), crate::hello(None));
        for _ in 0..100 {
            if server.stages() == 1 {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(server.stages(), 1);
        server.say(&crate::hand(crate::Hand::Next));
        assert_eq!(ws.read().unwrap().to_text().unwrap(), r#"{"t":"hands","do":"next"}"#);
        ws.send(Message::text(r#"{"t":"ping"}"#)).unwrap();
        assert_eq!(ws.read().unwrap().to_text().unwrap(), r#"{"t":"pong"}"#);
        // the room's sound, binary; a sign-in told to the stage reading
        server.say_binary(crate::pcm(48000, &[0.5]));
        assert_eq!(&ws.read().unwrap().into_data()[..4], b"PCM1");
        let house = crate::House { server: "https://h".into(), token: "tk".into() };
        server.set_hello(crate::hello(Some(&house)));
        assert!(ws.read().unwrap().to_text().unwrap().contains(r#""house":{"server":"https://h""#));
        let mut pic = vec![1, 0, 1, 0];
        pic.extend([9, 9, 9, 255]);
        ws.send(Message::binary(pic)).unwrap();
        ws.send(Message::text(r#"{"t":"shown","scene":"tunnel","held":false}"#)).unwrap();
        for _ in 0..200 {
            if server.shown().is_some() {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(server.thumb().map(|(n, t)| (n, t.rgba.clone())), Some((0, vec![9, 9, 9, 255])));
        assert_eq!(server.shown().and_then(|s| s.scene).as_deref(), Some("tunnel"));
        ws.close(None).unwrap();
        let _ = ws.flush();
        for _ in 0..200 {
            if server.stages() == 0 {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(server.stages(), 0);
        assert!(server.thumb().is_none(), "the picture goes with the last stage");
    }

    #[test]
    fn a_stage_connecting_later_is_told_what_was_kept_and_says_it_is_v2() {
        let server = Server::open().unwrap();
        server.keep("record.A", crate::v2::record("A", None));
        server.keep("cue", r#"{"t":"cue","cue":{"scene":"x"}}"#.into());
        server.keep("cue", r#"{"t":"cue","cue":{"scene":"y"}}"#.into());
        let (mut ws, _) = tungstenite::connect(server.url()).unwrap();
        assert!(ws.read().unwrap().to_text().unwrap().starts_with(r#"{"t":"hello""#));
        // the kept lines by key, the newest of each
        assert_eq!(ws.read().unwrap().to_text().unwrap(), r#"{"t":"cue","cue":{"scene":"y"}}"#);
        assert_eq!(ws.read().unwrap().to_text().unwrap(), crate::v2::record("A", None));
        assert!(!server.v2());
        ws.send(Message::text(crate::v2::STAGE_HELLO)).unwrap();
        for _ in 0..200 {
            if server.v2() {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert!(server.v2());
        drop(ws);
        for _ in 0..200 {
            if !server.v2() {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert!(!server.v2(), "gone with the stage");
    }
}
