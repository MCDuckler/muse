//! Finding controllers and listening to them: every couple of seconds the MIDI ports
//! and the USB HID devices are looked over for one a layout names (a port by its name,
//! a device by its vendor and product), each one found is opened and read on its own,
//! and its events come through one channel. Lights go back the same way. A lane may see
//! each event first, on the reading thread itself, for what cannot wait for the Desk's
//! next frame (a hand on a record): what it did comes through with the event. A doorbell
//! rings with each, so whoever acts on them need not wait out a poll.
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use crate::decode::{Decoder, Event};
use crate::layout::{Layout, Protocol, bundled};

/// One packet a controller sent, as it came and as it was read (the controllers page's
/// monitor: what to watch when new hardware first meets the Desk).
#[derive(Clone, Debug, PartialEq)]
pub struct Packet {
    pub at: std::time::Instant,
    pub from: String,
    pub bytes: Vec<u8>,
    /// The controls it moved, `id value` (none: nothing in the layout says this packet).
    pub read: Vec<String>,
}

/// How many packets the monitor keeps.
pub const MONITOR: usize = 200;

/// Sees every event as it is read, on the reading thread; returns what it did with it
/// (in words, for the monitor) — None leaves it to the binding.
pub type Lane = Arc<dyn Fn(&Event) -> Option<String> + Send + Sync>;

/// An event, and what the lane did with it.
pub type Heard = (Event, Option<String>);

/// Rung by the reading threads each time a controller says something: the Desk's clock
/// waits on it (with its own beat as the timeout) rather than sleeping through a press.
#[derive(Default)]
pub struct Doorbell {
    rung: Mutex<bool>,
    cv: Condvar,
}

impl Doorbell {
    pub fn ring(&self) {
        *self.rung.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.cv.notify_all();
    }

    /// Until it rings (or rang since the last wait), or `timeout`: whether it rang.
    pub fn wait(&self, timeout: Duration) -> bool {
        let g = self.rung.lock().unwrap_or_else(|e| e.into_inner());
        let (mut g, _) = self.cv.wait_timeout_while(g, timeout, |rung| !*rung).unwrap_or_else(|e| e.into_inner());
        std::mem::take(&mut *g)
    }
}

type Monitor = Arc<Mutex<VecDeque<Packet>>>;

fn keep(m: &Monitor, from: &str, bytes: &[u8], events: &[Event], half: Option<&str>) {
    let mut m = m.lock().unwrap();
    if m.len() >= MONITOR {
        m.pop_front();
    }
    let mut read: Vec<String> = events.iter().map(|e| format!("{} {:.3}", e.id, e.value)).collect();
    if let Some(id) = half {
        read.push(format!("{id} (its high half; the low one says)"));
    }
    m.push_back(Packet { at: std::time::Instant::now(), from: from.to_owned(), bytes: bytes.to_vec(), read });
}

/// A controller as the Desk shows it.
#[derive(Clone, Debug, PartialEq)]
pub struct Controller {
    pub name: String,
    pub layout: String,
    /// Found but not opened (no permission, busy): why, in words.
    pub trouble: Option<String>,
}

enum Link {
    Midi {
        _input: midir::MidiInputConnection<()>,
        output: Option<midir::MidiOutputConnection>,
        lights: Decoder,
    },
    Hid {
        lights: Decoder,
        send: Sender<Vec<u8>>,
        alive: Arc<AtomicBool>,
    },
}

struct Open {
    controller: Controller,
    link: Option<Link>,
}

#[derive(Default)]
struct Shared {
    open: HashMap<String, Open>,
}

pub struct Manager {
    events: Receiver<Heard>,
    shared: Arc<Mutex<Shared>>,
    stop: Arc<AtomicBool>,
    monitor: Monitor,
    layouts: Vec<Layout>,
    bell: Arc<Doorbell>,
}

impl Drop for Manager {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

impl Manager {
    /// Starts looking for controllers (the bundled layouts) on a thread of its own.
    pub fn start() -> Manager {
        Self::with_layouts(bundled(), None)
    }

    /// [Manager::start], with a lane that sees each event first.
    pub fn start_with(lane: Lane) -> Manager {
        Self::with_layouts(bundled(), Some(lane))
    }

    pub fn with_layouts(layouts: Vec<Layout>, lane: Option<Lane>) -> Manager {
        let (tx, rx) = mpsc::channel();
        let shared = Arc::new(Mutex::new(Shared::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let monitor: Monitor = Arc::new(Mutex::new(VecDeque::new()));
        let (s, st, m, known) = (shared.clone(), stop.clone(), monitor.clone(), layouts.clone());
        let lane: Lane = lane.unwrap_or_else(|| Arc::new(|_: &Event| None));
        let bell = Arc::new(Doorbell::default());
        let to = Hear { tx, lane, bell: bell.clone() };
        thread::spawn(move || {
            while !st.load(Ordering::Relaxed) {
                scan_midi(&known, &s, &to, &m);
                scan_hid(&known, &s, &to, &m);
                thread::sleep(Duration::from_secs(2));
            }
        });
        Manager { events: rx, shared, stop, monitor, layouts, bell }
    }

    /// Rings each time a controller says something (see [Doorbell]).
    pub fn doorbell(&self) -> Arc<Doorbell> {
        self.bell.clone()
    }

    /// The packets the controllers sent lately, oldest first.
    pub fn monitor(&self) -> Vec<Packet> {
        self.monitor.lock().unwrap().iter().cloned().collect()
    }

    pub fn clear_monitor(&self) {
        self.monitor.lock().unwrap().clear();
    }

    /// The layouts the Desk knows (a controller one of them names is taken up by itself).
    pub fn layouts(&self) -> &[Layout] {
        &self.layouts
    }

    /// Everything the controllers did since the last call.
    pub fn poll(&self) -> Vec<Event> {
        self.events.try_iter().map(|(e, _)| e).collect()
    }

    /// [Manager::poll], each with what the lane did with it.
    pub fn poll_heard(&self) -> Vec<Heard> {
        self.events.try_iter().collect()
    }

    pub fn controllers(&self) -> Vec<Controller> {
        let s = self.shared.lock().unwrap();
        let mut v: Vec<Controller> = s.open.values().map(|o| o.controller.clone()).collect();
        v.sort_by(|a, b| a.name.cmp(&b.name));
        v
    }

    /// Light `id` on or off on every controller that has it.
    pub fn light(&self, id: &str, on: bool) {
        self.each(|d| d.light(id, on));
    }

    /// Meter `id` at `level` (0..1) on every controller that has it.
    pub fn level(&self, id: &str, level: f32) {
        self.each(|d| d.level(id, level));
    }

    fn each(&self, mut bytes: impl FnMut(&mut Decoder) -> Vec<Vec<u8>>) {
        let mut s = self.shared.lock().unwrap();
        for o in s.open.values_mut() {
            match &mut o.link {
                Some(Link::Midi { output: Some(out), lights, .. }) => {
                    for m in bytes(lights) {
                        let _ = out.send(&m);
                    }
                }
                Some(Link::Hid { lights, send, .. }) => {
                    for m in bytes(lights) {
                        let _ = send.send(m);
                    }
                }
                _ => {}
            }
        }
    }
}

/// Where a reading thread's events go: the lane first, then the channel, the bell rung.
#[derive(Clone)]
struct Hear {
    tx: Sender<Heard>,
    lane: Lane,
    bell: Arc<Doorbell>,
}

impl Hear {
    fn all(&self, events: Vec<Event>) {
        if events.is_empty() {
            return;
        }
        for e in events {
            let did = (self.lane)(&e);
            let _ = self.tx.send((e, did));
        }
        self.bell.ring();
    }
}

fn scan_midi(layouts: &[Layout], shared: &Arc<Mutex<Shared>>, to: &Hear, monitor: &Monitor) {
    let Ok(probe) = midir::MidiInput::new("WetOwl Desk") else { return };
    let ports: Vec<(midir::MidiInputPort, String)> = probe.ports().into_iter().filter_map(|p| Some((p.clone(), probe.port_name(&p).ok()?))).collect();
    let names: Vec<String> = ports.iter().map(|(_, n)| format!("midi:{n}")).collect();
    // gone ones go
    shared.lock().unwrap().open.retain(|k, _| !k.starts_with("midi:") || names.contains(k));
    for (port, name) in ports {
        let key = format!("midi:{name}");
        if shared.lock().unwrap().open.contains_key(&key) {
            continue;
        }
        // our own ports, and anything no layout names, are not controllers
        if name.contains("WetOwl") {
            continue;
        }
        let Some(layout) = layouts.iter().find(|l| l.protocol == Protocol::Midi && l.names_match(&name)) else { continue };
        let Ok(input) = midir::MidiInput::new("WetOwl Desk") else { continue };
        let mut decoder = Decoder::new(layout.clone());
        let to = to.clone();
        let (m, from) = (monitor.clone(), name.clone());
        let controller = Controller { name: name.clone(), layout: layout.name.clone(), trouble: None };
        let link = match input.connect(&port, "WetOwl Desk in", move |_, msg, _| {
            let events = decoder.decode(msg);
            keep(&m, &from, msg, &events, decoder.half());
            to.all(events);
        }, ()) {
            Ok(conn) => Some(Link::Midi { _input: conn, output: midi_output(&name), lights: Decoder::new(layout.clone()) }),
            Err(e) => {
                let mut c = controller.clone();
                c.trouble = Some(e.to_string());
                shared.lock().unwrap().open.insert(key, Open { controller: c, link: None });
                continue;
            }
        };
        shared.lock().unwrap().open.insert(key, Open { controller, link });
    }
}

/// The output port of the same name, for the lights.
fn midi_output(name: &str) -> Option<midir::MidiOutputConnection> {
    let out = midir::MidiOutput::new("WetOwl Desk").ok()?;
    let port = out.ports().into_iter().find(|p| out.port_name(p).ok().as_deref() == Some(name))?;
    out.connect(&port, "WetOwl Desk out").ok()
}

fn scan_hid(layouts: &[Layout], shared: &Arc<Mutex<Shared>>, to: &Hear, monitor: &Monitor) {
    let hid_layouts: Vec<&Layout> = layouts.iter().filter(|l| l.protocol == Protocol::Hid).collect();
    if hid_layouts.is_empty() {
        return;
    }
    let Ok(api) = hidapi::HidApi::new() else { return };
    // gone (the reader saw it go) ones go
    shared.lock().unwrap().open.retain(|k, o| !k.starts_with("hid:") || !matches!(&o.link, Some(Link::Hid { alive, .. }) if !alive.load(Ordering::Relaxed)));
    for info in api.device_list() {
        let (vid, pid) = (info.vendor_id(), info.product_id());
        let Some(layout) = hid_layouts.iter().find(|l| l.usb.contains(&(vid, pid))) else { continue };
        let key = format!("hid:{}", info.path().to_string_lossy());
        if shared.lock().unwrap().open.contains_key(&key) {
            continue;
        }
        let name = info.product_string().unwrap_or("HID controller").to_owned();
        let mut controller = Controller { name, layout: layout.name.clone(), trouble: None };
        let device = match info.open_device(&api) {
            Ok(d) => d,
            Err(e) => {
                controller.trouble = Some(if cfg!(target_os = "linux") {
                    format!("can't open it ({e}); on Linux it needs the udev rule (deploy/udev/99-wetowl-dj.rules)")
                } else {
                    format!("can't open it ({e})")
                });
                shared.lock().unwrap().open.insert(key, Open { controller, link: None });
                continue;
            }
        };
        let alive = Arc::new(AtomicBool::new(true));
        let (send, lights_rx) = mpsc::channel::<Vec<u8>>();
        let mut decoder = Decoder::new((*layout).clone());
        let (to, a) = (to.clone(), alive.clone());
        let (m, from) = (monitor.clone(), controller.name.clone());
        thread::spawn(move || {
            let mut buf = [0u8; 64];
            while a.load(Ordering::Relaxed) {
                for report in lights_rx.try_iter() {
                    let _ = device.write(&report);
                }
                match device.read_timeout(&mut buf, 50) {
                    Ok(0) => {}
                    Ok(n) => {
                        // (a report that moved nothing is not kept: some send theirs all the time)
                        let events = decoder.decode(&buf[..n]);
                        if !events.is_empty() {
                            keep(&m, &from, &buf[..n], &events, None);
                        }
                        to.all(events);
                    }
                    Err(_) => a.store(false, Ordering::Relaxed),
                }
            }
        });
        shared.lock().unwrap().open.insert(key, Open { controller, link: Some(Link::Hid { lights: Decoder::new((*layout).clone()), send, alive }) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn the_doorbell_wakes_a_waiter_at_once() {
        let bell = Arc::new(Doorbell::default());
        assert!(!bell.wait(Duration::from_millis(5)), "not rung: the timeout");
        bell.ring();
        assert!(bell.wait(Duration::from_secs(5)), "rung before the wait: no waiting");
        let b = bell.clone();
        let t = thread::spawn(move || {
            thread::sleep(Duration::from_millis(30));
            b.ring();
        });
        let t0 = Instant::now();
        assert!(bell.wait(Duration::from_secs(5)));
        assert!(t0.elapsed() < Duration::from_secs(1), "woken by the ring, not the timeout: {:?}", t0.elapsed());
        t.join().unwrap();
    }

    #[test]
    fn events_go_through_the_lane_and_ring() {
        let (tx, rx) = mpsc::channel();
        let bell = Arc::new(Doorbell::default());
        let to = Hear { tx, lane: Arc::new(|e: &Event| (e.id == "deck.a.jog.scratch").then(|| "a hand".to_owned())), bell: bell.clone() };
        to.all(vec![]);
        assert!(!bell.wait(Duration::ZERO), "nothing said: no ring");
        let ev = |id: &str| Event { id: id.into(), kind: crate::Kind::Jog, value: 1.0 };
        to.all(vec![ev("deck.a.jog.scratch"), ev("deck.a.jog")]);
        assert!(bell.wait(Duration::ZERO));
        let heard: Vec<Heard> = rx.try_iter().collect();
        assert_eq!(heard, vec![(ev("deck.a.jog.scratch"), Some("a hand".to_owned())), (ev("deck.a.jog"), None)]);
    }
}
