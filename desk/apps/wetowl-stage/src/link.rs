//! The stage's end of ShowWire: a thread that connects to the Desk (and again, a second
//! after it is lost), says it is a v2 stage, hands every line on as it is said, and sends what
//! the stage gives it (its picture, what it shows) — without ever holding up a frame.
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::thread;
use std::time::Duration;

use tungstenite::Message;
use wo_wire::v2::{self, Said};

pub enum In {
    Joined,
    Said(Said),
    Lost,
}

pub struct Link {
    pub rx: Receiver<In>,
    out: SyncSender<Message>,
}

impl Link {
    pub fn open(url: String) -> Link {
        let (tx, rx) = mpsc::channel();
        let (out, out_rx) = mpsc::sync_channel::<Message>(8);
        thread::spawn(move || {
            loop {
                if let Ok((mut ws, _)) = tungstenite::connect(&url) {
                    if let tungstenite::stream::MaybeTlsStream::Plain(tcp) = ws.get_ref() {
                        let _ = tcp.set_nodelay(true);
                        let _ = tcp.set_read_timeout(Some(Duration::from_millis(4)));
                    }
                    let _ = ws.send(Message::text(v2::STAGE_HELLO));
                    if tx.send(In::Joined).is_err() {
                        return;
                    }
                    'read: loop {
                        let mut wrote = false;
                        while let Ok(m) = out_rx.try_recv() {
                            if ws.write(m).is_err() {
                                break 'read;
                            }
                            wrote = true;
                        }
                        if wrote && ws.flush().is_err() {
                            break;
                        }
                        match ws.read() {
                            Ok(Message::Text(t)) => {
                                let said = v2::said(&t);
                                if said != Said::Other && tx.send(In::Said(said)).is_err() {
                                    return;
                                }
                            }
                            Ok(Message::Close(_)) => break,
                            Ok(_) => {}
                            Err(tungstenite::Error::Io(e)) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {}
                            Err(_) => break,
                        }
                    }
                    if tx.send(In::Lost).is_err() {
                        return;
                    }
                }
                thread::sleep(Duration::from_secs(1));
                // the stage gone: nothing to connect for
                if tx.send(In::Lost).is_err() {
                    return;
                }
            }
        });
        Link { rx, out }
    }

    /// To the Desk, or dropped while the line is full.
    pub fn send(&self, m: Message) {
        match self.out.try_send(m) {
            Ok(()) | Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {}
        }
    }
}
