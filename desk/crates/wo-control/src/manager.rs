//! Finding controllers and listening to them: every couple of seconds the MIDI ports
//! and the USB HID devices are looked over for one a layout names (a port by its name,
//! a device by its vendor and product), each one found is opened and read on its own,
//! and its events come through one channel. Lights go back the same way. A lane may see
//! each event first, on the reading thread itself, for what cannot wait for the Desk's
//! next frame (a hand on a record): what it did comes through with the event. A doorbell
//! rings with each, so whoever acts on them need not wait out a poll.
//!
//! A MIDI port no layout names is opened too once something on it is mapped by hand, and
//! every port is while a control is being mapped (learn.rs): the next control moved on any
//! of them is the one. Only then: on Windows a port opened is a port no other program has.
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::thread;
use std::time::Duration;

use crate::decode::{Decoder, Event};
use crate::layout::{Layout, Protocol, bundled};
use crate::learn::{Learner, Mapped, Mappings, Target};

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
    let mut read: Vec<String> = events.iter().map(|e| format!("{} {:.3}", e.id, e.value)).collect();
    if let Some(id) = half {
        read.push(format!("{id} (its high half; the low one says)"));
    }
    keep_read(m, from, bytes, read);
}

fn keep_read(m: &Monitor, from: &str, bytes: &[u8], read: Vec<String>) {
    let mut m = m.lock().unwrap();
    if m.len() >= MONITOR {
        m.pop_front();
    }
    m.push_back(Packet { at: std::time::Instant::now(), from: from.to_owned(), bytes: bytes.to_vec(), read });
}

/// A control being mapped by hand: the booth's chosen, the controller's listened for.
#[derive(Clone, Debug, PartialEq)]
pub enum Learning {
    Off,
    /// Waiting for a control to move.
    Listening(Target),
    /// The control moved is mapped (until the next [Manager::learn] or [Manager::stop_learning]).
    Caught(Target, Mapped),
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
        /// The reading thread's: swapped for a new one when the port's mappings change.
        decoder: Arc<Mutex<Decoder>>,
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

/// What the scanning thread, the reading threads and the Desk share.
struct Ctx {
    shared: Mutex<Shared>,
    layouts: Vec<Layout>,
    mappings: Mutex<Mappings>,
    learner: Mutex<Option<Learner>>,
    caught: Mutex<Option<(Target, Mapped)>>,
    /// The MIDI input ports there are (as of the last look), whether opened or not.
    ports: Mutex<Vec<String>>,
    /// Rung to look again now rather than in a couple of seconds.
    rescan: Doorbell,
}

impl Ctx {
    fn known(&self, name: &str) -> Option<&Layout> {
        self.layouts.iter().find(|l| l.protocol == Protocol::Midi && l.names_match(name))
    }

    /// Port `name`'s layout as it stands (the Desk's with the hand's over it; None: neither),
    /// and in words.
    fn midi_layout(&self, name: &str) -> (Option<Layout>, String) {
        let known = self.known(name);
        let maps = self.mappings.lock().unwrap();
        let n = maps.inputs(name).len();
        let words = match (known, n) {
            (Some(l), 0) => l.name.clone(),
            (Some(l), n) => format!("{} (+{n} mapped by hand)", l.name),
            (None, 0) => "listened to while mapping".to_owned(),
            (None, n) => format!("{n} control{} mapped by hand", if n == 1 { "" } else { "s" }),
        };
        (maps.layout(name, known), words)
    }

    /// Every open MIDI port read anew: its mappings changed.
    fn refresh(&self) {
        let keys: Vec<String> = self.shared.lock().unwrap().open.keys().filter(|k| k.starts_with("midi:")).cloned().collect();
        for key in keys {
            let name = &key["midi:".len()..];
            let (layout, words) = self.midi_layout(name);
            let layout = layout.unwrap_or_else(|| listening(name));
            let mut s = self.shared.lock().unwrap();
            let Some(o) = s.open.get_mut(&key) else { continue };
            if let Some(Link::Midi { decoder, .. }) = &o.link {
                *decoder.lock().unwrap() = Decoder::new(layout);
            }
            if o.controller.trouble.is_none() {
                o.controller.layout = words;
            }
        }
    }

    /// A message from port `from`: whether the learner took it (all are, while it listens:
    /// a control moved to be mapped moves nothing in the booth).
    fn learn_from(&self, from: &str, msg: &[u8], monitor: &Monitor) -> bool {
        let caught = {
            let mut l = self.learner.lock().unwrap();
            let Some(learner) = l.as_mut() else { return false };
            let caught = learner.hear(from, msg).map(|m| (learner.target, m));
            if caught.is_some() {
                *l = None;
            }
            caught
        };
        let read = match caught {
            Some((target, m)) => {
                let words = format!("mapped onto {} ({})", target.id, m.words());
                self.mappings.lock().unwrap().set(m.clone());
                *self.caught.lock().unwrap() = Some((target, m));
                self.refresh();
                self.rescan.ring();
                words
            }
            None => "heard while mapping".to_owned(),
        };
        keep_read(monitor, from, msg, vec![read]);
        true
    }
}

/// A layout that reads nothing: a port listened to only while mapping.
fn listening(name: &str) -> Layout {
    Layout { id: "listening".into(), name: "listened to while mapping".into(), protocol: Protocol::Midi, usb: vec![], names: vec![name.to_owned()], inputs: vec![], outputs: vec![], audio: None }
}

pub struct Manager {
    events: Receiver<Heard>,
    ctx: Arc<Ctx>,
    stop: Arc<AtomicBool>,
    monitor: Monitor,
    bell: Arc<Doorbell>,
}

impl Drop for Manager {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.ctx.rescan.ring();
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

    /// [Manager::start_with], the controls mapped by hand kept in file `mappings` (None:
    /// for this run only).
    pub fn start_mapped(lane: Lane, mappings: Option<PathBuf>) -> Manager {
        Self::with(bundled(), Some(lane), Mappings::at(mappings))
    }

    pub fn with_layouts(layouts: Vec<Layout>, lane: Option<Lane>) -> Manager {
        Self::with(layouts, lane, Mappings::at(None))
    }

    pub fn with(layouts: Vec<Layout>, lane: Option<Lane>, mappings: Mappings) -> Manager {
        let (tx, rx) = mpsc::channel();
        let ctx = Arc::new(Ctx {
            shared: Mutex::new(Shared::default()),
            layouts,
            mappings: Mutex::new(mappings),
            learner: Mutex::new(None),
            caught: Mutex::new(None),
            ports: Mutex::new(vec![]),
            rescan: Doorbell::default(),
        });
        let stop = Arc::new(AtomicBool::new(false));
        let monitor: Monitor = Arc::new(Mutex::new(VecDeque::new()));
        let (c, st, m) = (ctx.clone(), stop.clone(), monitor.clone());
        let lane: Lane = lane.unwrap_or_else(|| Arc::new(|_: &Event| None));
        let bell = Arc::new(Doorbell::default());
        let to = Hear { tx, lane, bell: bell.clone() };
        thread::spawn(move || {
            while !st.load(Ordering::Relaxed) {
                scan_midi(&c, &to, &m);
                scan_hid(&c.layouts, &c.shared, &to, &m);
                c.rescan.wait(Duration::from_secs(2));
            }
            // the ports closed here, by the thread that opened them
            let open = std::mem::take(&mut c.shared.lock().unwrap().open);
            drop(open);
        });
        Manager { events: rx, ctx, stop, monitor, bell }
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
        &self.ctx.layouts
    }

    /// The MIDI input ports there are, opened or not (the ones a control can be mapped from).
    pub fn midi_ports(&self) -> Vec<String> {
        self.ctx.ports.lock().unwrap().clone()
    }

    /// The controls mapped by hand.
    pub fn mappings(&self) -> Vec<Mapped> {
        self.ctx.mappings.lock().unwrap().mapped.clone()
    }

    /// Booth control `id` unmapped (from port `port` alone, given one).
    pub fn forget(&self, id: &str, port: Option<&str>) {
        self.ctx.mappings.lock().unwrap().forget(id, port);
        self.ctx.refresh();
        self.ctx.rescan.ring();
    }

    /// Map the next control moved, on any MIDI port, onto booth control `target`: every port
    /// is opened to listen, and what is moved meanwhile moves nothing in the booth.
    pub fn learn(&self, target: Target) {
        *self.ctx.caught.lock().unwrap() = None;
        *self.ctx.learner.lock().unwrap() = Some(Learner::new(target));
        self.ctx.rescan.ring();
    }

    /// No longer listening (the ports opened only for it close).
    pub fn stop_learning(&self) {
        *self.ctx.caught.lock().unwrap() = None;
        *self.ctx.learner.lock().unwrap() = None;
        self.ctx.rescan.ring();
    }

    pub fn learning(&self) -> Learning {
        if let Some((t, m)) = self.ctx.caught.lock().unwrap().clone() {
            return Learning::Caught(t, m);
        }
        match self.ctx.learner.lock().unwrap().as_ref() {
            Some(l) => Learning::Listening(l.target),
            None => Learning::Off,
        }
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
        let s = self.ctx.shared.lock().unwrap();
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
        let mut s = self.ctx.shared.lock().unwrap();
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

fn scan_midi(ctx: &Arc<Ctx>, to: &Hear, monitor: &Monitor) {
    let Ok(mut probe) = midir::MidiInput::new("WetOwl Desk") else { return };
    probe.ignore(midir::Ignore::TimeAndActiveSense);
    // our own ports are not controllers
    let ports: Vec<(midir::MidiInputPort, String)> = probe.ports().into_iter().filter_map(|p| Some((p.clone(), probe.port_name(&p).ok()?))).filter(|(_, n)| !n.contains("WetOwl")).collect();
    let names: Vec<String> = ports.iter().map(|(_, n)| n.clone()).collect();
    *ctx.ports.lock().unwrap() = names.clone();
    let learning = ctx.learner.lock().unwrap().is_some();
    // a port is opened when a layout names it, something on it is mapped, or while mapping
    let wanted = |name: &str| learning || ctx.known(name).is_some() || ctx.mappings.lock().unwrap().has(name);
    // gone ones go, and ones no longer wanted (opened only to map from); closed outside the lock
    let gone: Vec<Open> = {
        let mut s = ctx.shared.lock().unwrap();
        let keys: Vec<String> = s.open.keys().filter(|k| k.strip_prefix("midi:").is_some_and(|n| !names.iter().any(|m| m == n) || !wanted(n))).cloned().collect();
        keys.iter().filter_map(|k| s.open.remove(k)).collect()
    };
    drop(gone);
    for (port, name) in ports {
        let key = format!("midi:{name}");
        if ctx.shared.lock().unwrap().open.contains_key(&key) || !wanted(&name) {
            continue;
        }
        let (layout, words) = ctx.midi_layout(&name);
        let decoder = Arc::new(Mutex::new(Decoder::new(layout.clone().unwrap_or_else(|| listening(&name)))));
        let Ok(mut input) = midir::MidiInput::new("WetOwl Desk") else { continue };
        input.ignore(midir::Ignore::TimeAndActiveSense);
        let to = to.clone();
        // weak: the connection lives in the ctx, so a strong one would keep both forever
        let (m, from, d, weak) = (monitor.clone(), name.clone(), decoder.clone(), Arc::downgrade(ctx));
        let controller = Controller { name: name.clone(), layout: words, trouble: None };
        let link = match input.connect(&port, "WetOwl Desk in", move |_, msg, _| {
            if Weak::upgrade(&weak).is_some_and(|c| c.learn_from(&from, msg, &m)) {
                return;
            }
            let (events, half) = {
                let mut decoder = d.lock().unwrap();
                let events = decoder.decode(msg);
                (events, decoder.half().map(str::to_owned))
            };
            keep(&m, &from, msg, &events, half.as_deref());
            to.all(events);
        }, ()) {
            Ok(conn) => Some(Link::Midi {
                _input: conn,
                // the lights' port only where a layout says where its lights are
                output: layout.as_ref().filter(|l| !l.outputs.is_empty()).and_then(|_| midi_output(&name)),
                lights: Decoder::new(layout.unwrap_or_else(|| listening(&name))),
                decoder,
            }),
            Err(e) => {
                let mut c = controller.clone();
                c.trouble = Some(e.to_string());
                ctx.shared.lock().unwrap().open.insert(key, Open { controller: c, link: None });
                continue;
            }
        };
        ctx.shared.lock().unwrap().open.insert(key, Open { controller, link });
    }
}

/// The output port of the same name, for the lights.
fn midi_output(name: &str) -> Option<midir::MidiOutputConnection> {
    let out = midir::MidiOutput::new("WetOwl Desk").ok()?;
    let port = out.ports().into_iter().find(|p| out.port_name(p).ok().as_deref() == Some(name))?;
    out.connect(&port, "WetOwl Desk out").ok()
}

fn scan_hid(layouts: &[Layout], shared: &Mutex<Shared>, to: &Hear, monitor: &Monitor) {
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
    use crate::learn::{Source, target};
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

    /// The learning path without a port: a knob moved while mapping is taken by the learner
    /// (none of it reaches the booth), mapped and kept; after it, messages are the decoder's.
    #[test]
    fn a_control_moved_while_mapping_is_mapped_not_played() {
        let ctx = Ctx {
            shared: Mutex::new(Shared::default()),
            layouts: bundled(),
            mappings: Mutex::new(Mappings::at(None)),
            learner: Mutex::new(Some(Learner::new(target("mixer.crossfader").unwrap()))),
            caught: Mutex::new(None),
            ports: Mutex::new(vec![]),
            rescan: Doorbell::default(),
        };
        let monitor: Monitor = Arc::new(Mutex::new(VecDeque::new()));
        assert!(ctx.learn_from("Oxygen Pro 49", &[0xB0, 0x14, 10], &monitor));
        assert!(ctx.caught.lock().unwrap().is_none());
        assert!(ctx.learn_from("Oxygen Pro 49", &[0xB0, 0x14, 40], &monitor), "the moving one: taken");
        let (t, m) = ctx.caught.lock().unwrap().clone().unwrap();
        assert_eq!((t.id, m.source, m.number), ("mixer.crossfader", Source::Cc, 0x14));
        assert!(!ctx.learn_from("Oxygen Pro 49", &[0xB0, 0x14, 50], &monitor), "mapped: the rest is the booth's");
        assert!(ctx.mappings.lock().unwrap().has("Oxygen Pro 49"));
        let (layout, words) = ctx.midi_layout("Oxygen Pro 49");
        assert_eq!(words, "1 control mapped by hand");
        let e = Decoder::new(layout.unwrap()).decode(&[0xB0, 0x14, 127]);
        assert_eq!((e[0].id.as_str(), e[0].value), ("mixer.crossfader", 1.0));
        let read: Vec<String> = monitor.lock().unwrap().iter().flat_map(|p| p.read.clone()).collect();
        assert_eq!(read, ["heard while mapping", "mapped onto mixer.crossfader (CC 20 · ch 1)"]);
        assert_eq!(ctx.midi_layout("DDJ-400").1, "Pioneer DDJ-400");
    }
}
