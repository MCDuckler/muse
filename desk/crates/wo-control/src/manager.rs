//! Finding controllers and listening to them: every couple of seconds the MIDI ports
//! and the USB HID devices are looked over for one a layout names (a port by its name,
//! a device by its vendor and product), each one found is opened and read on its own,
//! and its events come through one channel. Lights go back the same way.
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
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

type Monitor = Arc<Mutex<VecDeque<Packet>>>;

fn keep(m: &Monitor, from: &str, bytes: &[u8], events: &[Event]) {
    let mut m = m.lock().unwrap();
    if m.len() >= MONITOR {
        m.pop_front();
    }
    m.push_back(Packet { at: std::time::Instant::now(), from: from.to_owned(), bytes: bytes.to_vec(), read: events.iter().map(|e| format!("{} {:.3}", e.id, e.value)).collect() });
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
    events: Receiver<Event>,
    shared: Arc<Mutex<Shared>>,
    stop: Arc<AtomicBool>,
    monitor: Monitor,
    layouts: Vec<Layout>,
}

impl Drop for Manager {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

impl Manager {
    /// Starts looking for controllers (the bundled layouts) on a thread of its own.
    pub fn start() -> Manager {
        Self::with_layouts(bundled())
    }

    pub fn with_layouts(layouts: Vec<Layout>) -> Manager {
        let (tx, rx) = mpsc::channel();
        let shared = Arc::new(Mutex::new(Shared::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let monitor: Monitor = Arc::new(Mutex::new(VecDeque::new()));
        let (s, st, m, known) = (shared.clone(), stop.clone(), monitor.clone(), layouts.clone());
        thread::spawn(move || {
            while !st.load(Ordering::Relaxed) {
                scan_midi(&known, &s, &tx, &m);
                scan_hid(&known, &s, &tx, &m);
                thread::sleep(Duration::from_secs(2));
            }
        });
        Manager { events: rx, shared, stop, monitor, layouts }
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
        let mut s = self.shared.lock().unwrap();
        for o in s.open.values_mut() {
            match &mut o.link {
                Some(Link::Midi { output: Some(out), lights, .. }) => {
                    if let Some(bytes) = lights.light(id, on) {
                        let _ = out.send(&bytes);
                    }
                }
                Some(Link::Hid { lights, send, .. }) => {
                    if let Some(bytes) = lights.light(id, on) {
                        let _ = send.send(bytes);
                    }
                }
                _ => {}
            }
        }
    }
}

fn scan_midi(layouts: &[Layout], shared: &Arc<Mutex<Shared>>, tx: &Sender<Event>, monitor: &Monitor) {
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
        let tx = tx.clone();
        let (m, from) = (monitor.clone(), name.clone());
        let controller = Controller { name: name.clone(), layout: layout.name.clone(), trouble: None };
        let link = match input.connect(&port, "WetOwl Desk in", move |_, msg, _| {
            let events = decoder.decode(msg);
            keep(&m, &from, msg, &events);
            for e in events {
                let _ = tx.send(e);
            }
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

fn scan_hid(layouts: &[Layout], shared: &Arc<Mutex<Shared>>, tx: &Sender<Event>, monitor: &Monitor) {
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
        let (tx, a) = (tx.clone(), alive.clone());
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
                            keep(&m, &from, &buf[..n], &events);
                        }
                        for e in events {
                            let _ = tx.send(e);
                        }
                    }
                    Err(_) => a.store(false, Ordering::Relaxed),
                }
            }
        });
        shared.lock().unwrap().open.insert(key, Open { controller, link: Some(Link::Hid { lights: Decoder::new((*layout).clone()), send, alive }) });
    }
}
