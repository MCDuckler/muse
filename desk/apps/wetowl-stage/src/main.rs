//! WetOwl's stage in Rust (plan: ~/.claude/plans/wetowl-stage-rust.md): the show in a window
//! of its own, drawn on wgpu (Vulkan, Direct3D 12, Metal).
//!
//!   wetowl-stage --stage <ws url>    the Desk's show: it directs, this draws (ShowWire v2)
//!   wetowl-stage                     on its own: its own director over a made-up record
//!     [--scene <id>]                 that scene held (on its own)
//!     [--screen <name>]              full screen there from the start
//!     [--scale <0.5..1>]             the working size's share of the window's (it adapts)
//!     [--milk-dir <dir>]             MilkDrop's presets (on its own: the Desk says otherwise)
//!     [--shot <file.png>]            with --seconds: the last frame written out (960 wide)
//!     [--seconds N] [--list-screens]
//!
//! From the Desk it reads the decks as the ear hears them (`desk`), each deck's record
//! (`record`) and the director's decision (`cue`); between the Desk's frames it carries the
//! decks on, so it draws at the display's rate. It sends back its picture ten times a second
//! and what it shows (its screens), and goes full screen where the Desk's hands say.
//!
//! Every second it says `STAGE fps=… size=WxH screen=<name> full=0|1 gpu=… scene=… work=WxH`.
mod link;
mod milk;

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use link::{In, Link};
use tungstenite::Message;
use winit::application::ApplicationHandler;
use winit::event::{ElementState, KeyEvent, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::monitor::MonitorHandle;
use winit::window::{Fullscreen, Window, WindowId};
use wo_render::stage::Adapt;
use wo_render::{Gpu, Stage, wgpu};
use wo_show::deck::{Channel, RecordFacts, Section, ShowAudio, ShowDeck};
use wo_show::doc::ShowDoc;
use wo_show::engine::{Cue, Direct, Play, Room};
use wo_show::frame::stage_frame;
use wo_show::scenes::{DRAWN, SceneBook};
use wo_wire::Hand;
use wo_wire::v2::Said;

struct Args {
    url: Option<String>,
    scene: Option<String>,
    screen: Option<String>,
    scale: f32,
    seconds: Option<f64>,
    list: bool,
    milk_dir: Option<String>,
    shot: Option<String>,
}

fn args() -> Args {
    let a: Vec<String> = std::env::args().collect();
    let after = |flag: &str| a.iter().position(|x| x == flag).and_then(|i| a.get(i + 1)).cloned();
    Args {
        url: after("--stage"),
        scene: after("--scene"),
        screen: after("--screen"),
        scale: after("--scale").and_then(|s| s.parse().ok()).unwrap_or(1.0f32).clamp(0.25, 2.0),
        seconds: after("--seconds").and_then(|s| s.parse().ok()),
        list: a.iter().any(|x| x == "--list-screens"),
        milk_dir: after("--milk-dir"),
        shot: after("--shot"),
    }
}

/// A screen's name as the Desk shows it (winit's, else its place).
fn screen_name(m: &MonitorHandle, i: usize) -> String {
    m.name().filter(|n| !n.trim().is_empty()).unwrap_or_else(|| format!("Screen {}", i + 1))
}

/// The screens by the names the Desk shows (each once: Wayland may list an output twice).
fn screens(all: impl Iterator<Item = MonitorHandle>) -> Vec<(String, MonitorHandle)> {
    let mut out: Vec<(String, MonitorHandle)> = vec![];
    for (i, m) in all.enumerate() {
        let n = screen_name(&m, i);
        if !out.iter().any(|(k, _)| *k == n) {
            out.push((n, m));
        }
    }
    out
}

/// An object as a line of the wire: its `t` first (a line is told by how it starts).
fn t_first(t: &str, v: &serde_json::Value) -> String {
    let s = v.to_string();
    format!(r#"{{"t":"{t}",{}"#, &s[1..])
}

/// The made-up record a stage on its own plays: 128 BPM, sixteen bars of each part, round.
fn own_record() -> RecordFacts {
    let period = 60_000.0 / 128.0;
    let bar = 4.0 * period;
    let beats: Vec<f64> = (0..(96 * 4)).map(|i| i as f64 * period).collect();
    let parts = [("intro", 0.0, 16.0), ("build", 16.0, 32.0), ("drop", 32.0, 48.0), ("breakdown", 48.0, 64.0), ("build", 64.0, 72.0), ("drop", 72.0, 88.0), ("outro", 88.0, 96.0)];
    RecordFacts {
        track_id: Some(1),
        title: Some("WetOwl stage".into()),
        steady: Some((0.0, period)),
        downbeats_ms: beats.iter().step_by(4).copied().collect(),
        markers_ms: beats.iter().step_by(16).copied().collect(),
        energy: (0..96).map(|b| if (32..48).contains(&b) || (72..88).contains(&b) { 230 } else if (16..32).contains(&b) { 160 } else { 90 }).collect(),
        drops_ms: vec![32.0 * bar, 72.0 * bar],
        sections: parts.iter().map(|(l, a, b)| Section { label: (*l).into(), start_ms: a * bar, end_ms: b * bar }).collect(),
        beats_ms: beats,
        camelot: Some("8A".into()),
        cover_rgb: Some(0x7040c0),
        ..Default::default()
    }
}

/// The presets in a folder (and its folders), for a stage on its own.
fn own_presets(dir: &str) -> Vec<wo_show::milk::MilkPreset> {
    fn walk(d: &std::path::Path, out: &mut Vec<wo_show::milk::MilkPreset>) {
        for e in std::fs::read_dir(d).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, out);
            } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("milk")) {
                out.push(wo_show::milk::MilkPreset::of(&p.to_string_lossy(), "shipped", 3.0));
            }
        }
    }
    let mut out = vec![];
    walk(std::path::Path::new(dir), &mut out);
    out
}

/// `dt` seconds of the made-up record's sound from `t` (44.1 kHz): a kick on each beat at 128
/// BPM, a bass under it, hats on the offbeat.
fn own_sound(t: f64, dt: f64, phase: &mut f64) -> Vec<i16> {
    let n = (dt.clamp(0.0, 0.1) * 44_100.0) as usize;
    let beat = 60.0 / 128.0;
    (0..n)
        .map(|i| {
            let at = t - dt + i as f64 / 44_100.0;
            let b = (at / beat).fract();
            let kick = (-b * 18.0).exp() * (std::f64::consts::TAU * (50.0 + 90.0 * (-b * 30.0).exp()) * b * beat).sin();
            *phase += 55.0 / 44_100.0;
            let bass = 0.4 * (std::f64::consts::TAU * *phase).sin() * (1.0 - (-b * 6.0).exp());
            let h = ((at / beat + 0.5).fract() * beat * 40.0).min(1.0);
            let hat = 0.15 * (1.0 - h) * (((i as f64 * 12.9898).sin() * 43758.5453).fract() - 0.5);
            ((kick + bass + hat) * 12_000.0).clamp(-32_000.0, 32_000.0) as i16
        })
        .collect()
}

/// What the stage draws from: the Desk's word, or its own.
enum Source {
    Desk {
        link: Link,
        frame: Option<(wo_wire::Frame, Instant)>,
        facts: Box<[Option<RecordFacts>; 2]>,
        cue: Box<Cue>,
        joined: bool,
        lost_since: Option<Instant>,
    },
    Own {
        direct: Box<Direct>,
        facts: RecordFacts,
        t0: Instant,
        milk_ok: bool,
    },
}

impl Source {
    /// The room now and the cue to draw it by, `dt` after the last frame.
    fn room(&mut self, dt: f64) -> (Room, Cue, bool) {
        match self {
            Source::Desk { frame, facts, cue, .. } => match frame {
                Some((f, at)) => (wo_wire::v2::room(f, [facts[0].as_ref(), facts[1].as_ref()], at.elapsed().as_secs_f64()), (**cue).clone(), f.heard.is_some()),
                None => (Room::default(), (**cue).clone(), false),
            },
            Source::Own { direct, facts, t0, milk_ok } => {
                let len = 96.0 * 4.0 * 60_000.0 / 128.0;
                let ms = (t0.elapsed().as_secs_f64() * 1000.0) % len;
                let beat = (ms / (60_000.0 / 128.0)).fract();
                let loud = facts.energy.get((ms / (4.0 * 60_000.0 / 128.0)) as usize).map_or(0.5, |e| *e as f64 / 255.0);
                let kick = (1.0 - beat * 4.0).max(0.0) * loud;
                let audio = ShowAudio { sub: 0.5 * loud, low: 0.3 + 0.5 * kick, mid: 0.4 * loud, high: 0.2 + 0.3 * (beat * 8.0).fract() * loud, air: 0.2, kick, onset: kick, ..Default::default() };
                let a = ShowDeck::derive("A", Some(facts), true, ms, Channel::default(), audio);
                let room = Room { a, b: ShowDeck { name: "B".into(), ..Default::default() }, audio, ..Default::default() };
                let mut extra = wo_show::deck::Flat::new();
                extra.insert("milk.ok".into(), if *milk_ok { 1.0 } else { 0.0 });
                let (cue, _) = direct.tick(dt, room.clone(), extra);
                (room, cue, true)
            }
        }
    }
}

/// The picture for the Desk: drawn small beside the frame, copied out, sent when it is read.
struct Picture {
    texture: wgpu::Texture,
    view: wgpu::TextureView,
    buffer: wgpu::Buffer,
    w: u32,
    h: u32,
    row: u32,
    /// 0 free, 1 being read, 2 read.
    state: Arc<AtomicU8>,
    due: Instant,
}

impl Picture {
    fn new(gpu: &Gpu, out_w: u32, out_h: u32) -> Picture {
        let w = 640u32;
        let h = ((w as f32 * out_h as f32 / out_w.max(1) as f32).round() as u32).clamp(2, 1024);
        let texture = wo_render::target(gpu, w, h);
        let view = texture.create_view(&Default::default());
        let row = (4 * w).div_ceil(256) * 256;
        let buffer = gpu.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("the picture"),
            size: (row * h) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        Picture { texture, view, buffer, w, h, row, state: Arc::new(AtomicU8::new(0)), due: Instant::now() }
    }

    /// Four bytes of size, then RGBA, top row first (wo_wire::Thumb).
    fn take(&self) -> Option<Vec<u8>> {
        if self.state.load(Ordering::Acquire) != 2 {
            return None;
        }
        let out = {
            let data = self.buffer.slice(..).get_mapped_range().ok()?;
            let mut out = Vec::with_capacity(4 + (4 * self.w * self.h) as usize);
            out.extend_from_slice(&(self.w as u16).to_le_bytes());
            out.extend_from_slice(&(self.h as u16).to_le_bytes());
            for y in 0..self.h as usize {
                let at = y * self.row as usize;
                out.extend_from_slice(&data[at..at + 4 * self.w as usize]);
            }
            out
        };
        self.buffer.unmap();
        self.state.store(0, Ordering::Release);
        Some(out)
    }
}

struct Window_ {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    gpu: Gpu,
    stage: Stage,
    picture: Option<Picture>,
    adapt: Adapt,
    /// The last frame's time, microseconds: from its start to the GPU's end of it.
    took: Arc<AtomicU64>,
    /// Each frame's submission, to the thread that waits for it and notes the time.
    timer: std::sync::mpsc::Sender<(wgpu::SubmissionIndex, Instant)>,
}

/// A thread waiting on each frame's work, noting when it was done (a callback would be
/// heard only at the next poll, a whole frame later).
fn timer(device: wgpu::Device, took: Arc<AtomicU64>) -> std::sync::mpsc::Sender<(wgpu::SubmissionIndex, Instant)> {
    let (tx, rx) = std::sync::mpsc::channel::<(wgpu::SubmissionIndex, Instant)>();
    std::thread::spawn(move || {
        for (index, began) in rx {
            if device.poll(wgpu::PollType::Wait { submission_index: Some(index), timeout: Some(Duration::from_secs(2)) }).is_ok() {
                took.store(began.elapsed().as_micros() as u64, Ordering::Relaxed);
            }
        }
    });
    tx
}

struct App {
    args: Args,
    instance: wgpu::Instance,
    book: SceneBook,
    source: Source,
    play: Play,
    win: Option<Window_>,
    started: Instant,
    last: Instant,
    frames: u32,
    since: Instant,
    shown_due: Instant,
    /// Counted since the start: pictures sent, lines heard, cues among them.
    pictures: u64,
    heard: u64,
    cues: u64,
    black: f32,
    /// When a frame last went to the window.
    presented: Instant,
    /// Not FIFO: the stage paces its frames to the screen's rate, the next one due then.
    paced: bool,
    due: Instant,
    /// The made-up record's bass, where it is.
    phase: f64,
    milk: milk::MilkRun,
    /// Each deck's record cover as the Desk sent it, and once on the GPU its picture.
    covers: [Option<(wo_wire::Cover, Option<wgpu::TextureView>)>; 2],
    missing: Option<String>,
    /// The ground under the figure last frame, as the log names it.
    ground: Option<String>,
    /// The dancers (their rigs, where this stage has them) and their choreography.
    dance: Option<(wo_dance::sim::Company, wo_dance::sim::DanceSim)>,
    picture_cam: wo_dance::clock::PictureCam,
}

/// Whether `scene` (by id) is one the dancers draw.
fn dancers(book: &SceneBook, scene: Option<&str>) -> bool {
    scene.and_then(|s| book.scenes.get(s)).is_some_and(|s| s.layers.iter().any(|l| l.sim.as_deref().is_some_and(|k| k.starts_with("dance."))))
}

impl App {
    fn report(&mut self) {
        let Some(d) = &self.win else { return };
        let secs = self.since.elapsed().as_secs_f64();
        if secs < 1.0 {
            return;
        }
        let size = d.window.inner_size();
        let screen = d.window.current_monitor().map(|m| m.name().unwrap_or_default()).unwrap_or_default();
        let (ww, wh) = d.stage.drawn.work;
        println!(
            "STAGE fps={:.1} size={}x{} screen={} full={} gpu={} ({:?}) scene={} look={} ground={} work={}x{} ms={:.1} heard={} cues={} pictures={} black={} milk={:.0}fps/{}",
            self.frames as f64 / secs,
            size.width,
            size.height,
            screen,
            d.window.fullscreen().is_some() as u8,
            d.gpu.info.name,
            d.gpu.info.backend,
            self.play_scene().unwrap_or("-"),
            if d.stage.drawn.looks.is_empty() { "-".to_owned() } else { d.stage.drawn.looks.join("+") },
            self.ground.as_deref().unwrap_or("-"),
            ww,
            wh,
            d.took.load(Ordering::Relaxed) as f64 / 1000.0,
            self.heard,
            self.cues,
            self.pictures,
            self.black,
            self.milk.shown().fps,
            self.milk.shown().preset.unwrap_or_else(|| "-".into()),
        );
        self.frames = 0;
        self.since = Instant::now();
    }

    fn play_scene(&self) -> Option<&str> {
        match &self.source {
            Source::Desk { cue, .. } => cue.scene.as_deref(),
            Source::Own { direct, .. } => direct.cue().scene.as_deref(),
        }
    }

    /// Full screen on the screen called `name` (None: where the window is; or a window again).
    fn fill(&mut self, name: Option<&str>, on: bool) {
        let Some(d) = &self.win else { return };
        if !on {
            d.window.set_fullscreen(None);
            d.window.set_cursor_visible(true);
            return;
        }
        let monitors = screens(d.window.available_monitors());
        let m = match name {
            Some(n) => match monitors.iter().find(|(k, _)| k == n) {
                Some((_, m)) => Some(m.clone()),
                None => {
                    eprintln!("stage: no screen called {n}");
                    return;
                }
            },
            None => d.window.current_monitor(),
        };
        d.window.set_fullscreen(Some(Fullscreen::Borderless(m)));
        d.window.set_cursor_visible(false);
    }

    /// The Desk's lines since the last frame.
    fn hear(&mut self, el: &ActiveEventLoop) {
        let mut hands = vec![];
        if let Source::Desk { link, frame, facts, cue, joined, lost_since } = &mut self.source {
            while let Ok(m) = link.rx.try_recv() {
                if matches!(m, In::Said(_)) {
                    self.heard += 1;
                }
                if matches!(m, In::Said(Said::Cue(_))) {
                    self.cues += 1;
                }
                match m {
                    In::Joined => {
                        *joined = true;
                        *lost_since = None;
                    }
                    In::Lost => {
                        lost_since.get_or_insert_with(Instant::now);
                    }
                    In::Said(Said::Desk(f)) => *frame = Some((*f, Instant::now())),
                    In::Said(Said::Record(deck, f)) => facts[if deck == "B" { 1 } else { 0 }] = f.map(|f| *f),
                    In::Said(Said::Cue(c)) => *cue = c,
                    In::Said(Said::Hand(h)) => hands.push(h),
                    In::Said(Said::Other) => {}
                    In::Pcm(b) => self.milk.pcm(&b),
                    In::Cover(c) => {
                        let deck = c.deck.min(1);
                        self.covers[deck] = Some((c, None));
                    }
                }
            }
            // the Desk gone for good (it closes its stage as it goes): so does this
            if lost_since.is_some_and(|t| t.elapsed() > Duration::from_secs(30)) {
                eprintln!("stage: the Desk is gone");
                el.exit();
            }
        }
        for h in hands {
            match h {
                Hand::Screen(name) => self.fill(Some(&name), true),
                Hand::Full(on) => self.fill(None, on),
                // the rest are the Desk's director's: they come back in its cue
                _ => {}
            }
        }
    }

    /// What it shows, for the Desk's panel: the screens, which it fills.
    fn tell(&mut self) {
        if Instant::now() < self.shown_due {
            return;
        }
        self.shown_due = Instant::now() + Duration::from_millis(500);
        let (Source::Desk { link, .. }, Some(d)) = (&self.source, &self.win) else { return };
        let monitors = screens(d.window.available_monitors());
        let list: Vec<serde_json::Value> = monitors
            .iter()
            .map(|(n, m)| {
                let s = m.size();
                serde_json::json!({"name": n, "w": s.width, "h": s.height})
            })
            .collect();
        let full = d.window.fullscreen().is_some();
        let here = d.window.current_monitor();
        let screen = full.then(|| monitors.iter().find(|(_, m)| Some(m) == here.as_ref()).map(|(n, _)| n.clone())).flatten();
        let v = serde_json::json!({"scene": self.play_scene(), "screens": list, "screen": screen, "full": full, "milk": self.milk.shown()});
        link.send(Message::text(t_first("shown", &v)));
    }

    /// A frame: into the window (`present`), or — while the window is not shown, so the
    /// compositor asks for no frames (a hidden window on Wayland, headless) — only the
    /// Desk's picture, when one is due. Either way the Desk is heard and told.
    fn draw(&mut self, el: &ActiveEventLoop, present: bool) {
        if self.args.seconds.is_some_and(|s| self.started.elapsed() > Duration::from_secs_f64(s)) {
            self.report();
            self.shoot();
            el.exit();
            return;
        }
        self.hear(el);
        self.tell();
        let now = Instant::now();
        let Some(d) = &mut self.win else { return };
        let (ww, wh) = (d.config.width, d.config.height);
        let picture_h = ((640.0 * wh as f32 / ww.max(1) as f32).round() as u32).clamp(2, 1024);
        // the picture for the Desk, ten times a second, when the last one has been read
        let picture_now = matches!(self.source, Source::Desk { joined: true, .. })
            && d.picture.as_ref().is_none_or(|p| p.state.load(Ordering::Acquire) == 0 && now >= p.due);
        if !present && !picture_now {
            let _ = d.gpu.device.poll(wgpu::PollType::Poll);
            self.send_picture();
            return;
        }
        let out = if present {
            match d.surface.get_current_texture() {
                wgpu::CurrentSurfaceTexture::Success(t) | wgpu::CurrentSurfaceTexture::Suboptimal(t) => Some(t),
                wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                    d.surface.configure(&d.gpu.device, &d.config);
                    d.window.request_redraw();
                    return;
                }
                _ => {
                    d.window.request_redraw();
                    return;
                }
            }
        } else {
            None
        };
        let dt = (now - self.last).as_secs_f64().min(0.25);
        self.last = now;
        let (room, cue, heard) = self.source.room(dt);
        let st = self.play.frame(dt, room, &cue, heard);
        let mut f = stage_frame(&st, &self.book, self.started.elapsed().as_secs_f64());
        // the held datamosh, played by the music on the stage's own clock; a 3D figure's
        // picture moved as a camera would
        f.mosh_hold = self.play.mosh(&st);
        f.camera = self.picture_cam.frame(&st, dt);
        self.black = f.black;
        // on its own, MilkDrop hears the made-up record: a kick and a bass on the beat, hats
        if let Source::Own { t0, .. } = &self.source {
            let samples = own_sound(t0.elapsed().as_secs_f64(), dt, &mut self.phase);
            self.milk.pcm_44k(&samples);
        }
        let Some(d) = &mut self.win else { return };
        // MilkDrop, where the frame draws it: the figure's (the milk scene), the scene being
        // left, or the ground under a blend
        let wants_milk = f.figure.as_ref().is_some_and(|l| l.milk)
            || f.from.as_ref().is_some_and(|l| l.milk)
            || (f.blend.is_some() && f.ground == wo_show::frame::GroundDraw::Milk);
        d.stage.milk = self.milk.frame(&d.gpu, &st, &cue.milk, wants_milk, dt).cloned();
        // the cover ground: the master's record's cover, else the other deck's
        for (c, view) in self.covers.iter_mut().flatten() {
            if view.is_none() && c.w > 0 && c.h > 0 {
                *view = Some(wo_render::upload(&d.gpu, c.w, c.h, &c.rgba).create_view(&Default::default()));
            }
        }
        self.ground = f.blend.is_some().then(|| match &f.ground {
            wo_show::frame::GroundDraw::Field(l) => l.shader.clone(),
            g => format!("{g:?}").to_lowercase(),
        });
        let master = usize::from(st.master_name == "B");
        let view_of = |i: usize| self.covers[i].as_ref().and_then(|(_, v)| v.clone());
        d.stage.cover = view_of(master).or_else(|| view_of(1 - master));
        if present {
            // the working size, let down while frames come late
            let budget = 1.0 / d.window.current_monitor().and_then(|m| m.refresh_rate_millihertz()).map_or(60.0, |r| r as f64 / 1000.0).max(30.0);
            let took = d.took.load(Ordering::Relaxed) as f64 / 1e6;
            if took > 0.0 {
                d.stage.scale = d.adapt.frame(took, budget);
            }
        }
        let view = out.as_ref().map(|o| o.texture.create_view(&Default::default()));
        // unseen, the picture's own size is all there is to draw
        let (w, h) = if present { (ww, wh) } else { (640, picture_h) };
        if picture_now && d.picture.as_ref().is_none_or(|p| p.h != picture_h) {
            d.picture = Some(Picture::new(&d.gpu, ww, wh));
        }
        let pic = if picture_now { d.picture.as_ref() } else { None };
        // the dancers, where the scene is theirs: posed and painted at the working size
        if let Some((co, sim)) = &mut self.dance
            && f.figure.is_none()
            && dancers(&self.book, f.scene.as_deref())
        {
            let (ww, wh) = d.stage.work_size(w, h);
            let scene = sim.frame(co, &st, dt, ww as f64, wh as f64);
            d.stage.dance_cmds = sim.paint(co, &scene, &st, dt);
        }
        let began = Instant::now();
        let cmd = d.stage.draw(&d.gpu, &f, dt, view.as_ref(), w, h, pic.map(|p| &p.view));
        let mut cmds = vec![cmd];
        if let Some(p) = pic {
            let mut enc = d.gpu.device.create_command_encoder(&Default::default());
            enc.copy_texture_to_buffer(
                wgpu::TexelCopyTextureInfo { texture: &p.texture, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
                wgpu::TexelCopyBufferInfo { buffer: &p.buffer, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(p.row), rows_per_image: Some(p.h) } },
                wgpu::Extent3d { width: p.w, height: p.h, depth_or_array_layers: 1 },
            );
            cmds.push(enc.finish());
        }
        let index = d.gpu.queue.submit(cmds);
        if present {
            let _ = d.timer.send((index, began));
        }
        if let Some(p) = pic {
            p.state.store(1, Ordering::Release);
            let state = p.state.clone();
            p.buffer.slice(..).map_async(wgpu::MapMode::Read, move |r| state.store(if r.is_ok() { 2 } else { 0 }, Ordering::Release));
        }
        if let Some(out) = out {
            d.gpu.queue.present(out);
            self.presented = now;
        }
        let _ = d.gpu.device.poll(wgpu::PollType::Poll);
        self.send_picture();
        let missing = self.win.as_ref().and_then(|d| d.stage.drawn.missing.clone());
        if missing != self.missing {
            if let Some(m) = &missing {
                eprintln!("stage: no shader {m} here: black");
            }
            self.missing = missing;
        }
        if present {
            self.frames += 1;
        }
        self.report();
        if let Some(d) = &self.win {
            if !self.paced || !present {
                d.window.request_redraw();
            } else {
                // the next frame at the screen's rate (asked for between events)
                let rate = d.window.current_monitor().and_then(|m| m.refresh_rate_millihertz()).map_or(60.0, |r| r as f64 / 1000.0).clamp(30.0, 240.0);
                self.due = (self.due + Duration::from_secs_f64(1.0 / rate)).max(now);
            }
        }
    }

    /// The frame as it is now, written to --shot's file (960 wide).
    fn shoot(&mut self) {
        let Some(file) = self.args.shot.clone() else { return };
        let (room, cue, heard) = self.source.room(0.0);
        let st = self.play.frame(0.0, room, &cue, heard);
        let mut f = stage_frame(&st, &self.book, self.started.elapsed().as_secs_f64());
        f.mosh_hold = self.play.mosh(&st);
        let Some(d) = &mut self.win else { return };
        let (w, h) = (960u32, ((960.0 * d.config.height as f32 / d.config.width.max(1) as f32).round() as u32).max(2));
        let t = wo_render::target(&d.gpu, w, h);
        let v = t.create_view(&Default::default());
        if let Some((co, sim)) = &mut self.dance
            && f.figure.is_none()
            && dancers(&self.book, f.scene.as_deref())
        {
            let (ww, wh) = d.stage.work_size(w, h);
            let scene = sim.frame(co, &st, 0.0, ww as f64, wh as f64);
            d.stage.dance_cmds = sim.paint(co, &scene, &st, 0.0);
        }
        let cmd = d.stage.draw(&d.gpu, &f, 0.0, None, w, h, Some(&v));
        d.gpu.queue.submit([cmd]);
        let px = wo_render::read(&d.gpu, &t);
        match image::save_buffer(&file, &px, w, h, image::ExtendedColorType::Rgba8) {
            Ok(()) => println!("STAGE shot {file}"),
            Err(e) => eprintln!("stage: the shot: {e}"),
        }
    }

    /// The Desk's picture, once it has been read back.
    fn send_picture(&mut self) {
        let Some(d) = &mut self.win else { return };
        if let (Some(p), Source::Desk { link, .. }) = (d.picture.as_mut(), &self.source)
            && let Some(bytes) = p.take()
        {
            p.due = Instant::now() + Duration::from_millis(100);
            link.send(Message::binary(bytes));
            self.pictures += 1;
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.win.is_some() {
            return;
        }
        let monitors = screens(el.available_monitors());
        if self.args.list {
            for (n, m) in &monitors {
                let s = m.size();
                println!("SCREEN {n} {}x{}", s.width, s.height);
            }
            el.exit();
            return;
        }
        let mut attrs = Window::default_attributes().with_title("WetOwl · Stage").with_inner_size(winit::dpi::LogicalSize::new(1280.0, 720.0));
        let mut full = false;
        if let Some(want) = &self.args.screen {
            match monitors.iter().find(|(n, _)| n == want) {
                Some((_, m)) => {
                    attrs = attrs.with_fullscreen(Some(Fullscreen::Borderless(Some(m.clone()))));
                    full = true;
                }
                None => eprintln!("stage: no screen called {want}"),
            }
        }
        let window = Arc::new(el.create_window(attrs).expect("a window"));
        if full {
            window.set_cursor_visible(false);
        }
        let surface = self.instance.create_surface(window.clone()).expect("a surface");
        let gpu = Gpu::new(&self.instance, Some(&surface)).expect("a GPU");
        let caps = surface.get_capabilities(&gpu.adapter);
        // the shaders write display values, as Flutter's canvas does: not an sRGB format
        let format = caps.formats.iter().copied().find(|f| !f.is_srgb()).unwrap_or(caps.formats[0]);
        let size = window.inner_size();
        // Mailbox where there is one, paced by the stage to the screen's rate: a stage held in
        // FIFO's wait on Wayland held up its MilkDrop helper with it (a frame a second, the
        // helper drawn by a stage presenting in FIFO; sixty with mailbox). FIFO where there
        // is nothing else (a Mac), or WO_PRESENT=fifo.
        let present_mode = match std::env::var("WO_PRESENT").as_deref() {
            Ok("fifo") => wgpu::PresentMode::Fifo,
            Ok("immediate") if caps.present_modes.contains(&wgpu::PresentMode::Immediate) => wgpu::PresentMode::Immediate,
            _ if caps.present_modes.contains(&wgpu::PresentMode::Mailbox) => wgpu::PresentMode::Mailbox,
            _ => wgpu::PresentMode::Fifo,
        };
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            color_space: wgpu::SurfaceColorSpace::Auto,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode,
            desired_maximum_frame_latency: 2,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
        };
        surface.configure(&gpu.device, &config);
        let t0 = Instant::now();
        let mut stage = Stage::new(&gpu, format).unwrap_or_else(|e| panic!("the stage's shaders: {e}"));
        stage.scale = self.args.scale;
        if let Some((co, _)) = &self.dance {
            let t = Instant::now();
            stage.set_dancers(&gpu, co);
            eprintln!("stage: {} dancers up in {:.0} ms", co.rigs.len(), t.elapsed().as_secs_f64() * 1000.0);
        }
        eprintln!("stage: {} shaders ready in {:.0} ms on {} ({:?})", wo_render::stage::stage_shaders().len() + 2, t0.elapsed().as_secs_f64() * 1000.0, gpu.info.name, gpu.info.backend);
        window.request_redraw();
        self.paced = present_mode != wgpu::PresentMode::Fifo;
        eprintln!("stage: presenting {present_mode:?}");
        let took = Arc::new(AtomicU64::new(0));
        let timer = timer(gpu.device.clone(), took.clone());
        self.win = Some(Window_ { window, surface, config, gpu, stage, picture: None, adapt: Adapt::new(self.args.scale), took, timer });
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => el.exit(),
            WindowEvent::Resized(size) => {
                if let Some(d) = &mut self.win {
                    d.config.width = size.width.max(1);
                    d.config.height = size.height.max(1);
                    d.surface.configure(&d.gpu.device, &d.config);
                }
            }
            // F or F11 in and out of full screen, Escape out
            WindowEvent::KeyboardInput { event: KeyEvent { logical_key, state: ElementState::Pressed, repeat: false, .. }, .. } => {
                let full = self.win.as_ref().is_some_and(|d| d.window.fullscreen().is_some());
                match logical_key {
                    Key::Named(NamedKey::F11) => self.fill(None, !full),
                    Key::Character(c) if c.eq_ignore_ascii_case("f") => self.fill(None, !full),
                    Key::Named(NamedKey::Escape) if full => self.fill(None, false),
                    _ => {}
                }
            }
            WindowEvent::RedrawRequested => self.draw(el, true),
            _ => {}
        }
    }

    /// Between the compositor's frames: a window it has stopped asking frames of (hidden,
    /// headless) still hears the Desk and sends it its picture.
    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        if self.win.is_some() && self.presented.elapsed() > Duration::from_millis(150) {
            self.draw(el, false);
        }
        let now = Instant::now();
        let mut wake = now + Duration::from_millis(30);
        if self.paced
            && let Some(d) = &self.win
        {
            if now >= self.due {
                d.window.request_redraw();
            } else {
                wake = wake.min(self.due);
            }
        }
        el.set_control_flow(ControlFlow::WaitUntil(wake));
    }
}

fn main() {
    let args = args();
    let book = SceneBook::shipped().only(DRAWN);
    let milk = milk::MilkRun::new();
    let source = match &args.url {
        Some(url) => Source::Desk { link: Link::open(url.clone()), frame: None, facts: Box::new([None, None]), cue: Box::default(), joined: false, lost_since: None },
        None => {
            let mut direct = Direct::new(&book, ShowDoc::default(), wo_show::scores::ComboScores::shipped(), 11);
            // MilkDrop's presets from a folder (the Desk keeps the library otherwise)
            let presets = args.milk_dir.as_deref().map(own_presets).unwrap_or_default();
            let milk_ok = milk.ok() && !presets.is_empty();
            if milk_ok {
                let lib = wo_show::milk::MilkLibrary::new(presets, Default::default());
                direct.milk = Some(wo_show::milk::MilkDirector::new(lib, wo_show::scores::MilkScores::shipped(), 11));
            }
            direct.director.grounds_here = Some(wo_show::scenes::grounds_drawn(milk_ok, false));
            if let Some(s) = &args.scene {
                direct.director.choose(s, wo_show::director::SceneChange::Cut);
                direct.hold(true);
            }
            Source::Own { direct: Box::new(direct), facts: own_record(), t0: Instant::now(), milk_ok }
        }
    };
    let el = EventLoop::new().expect("an event loop");
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_with_display_handle_from_env(Box::new(el.owned_display_handle())));
    let now = Instant::now();
    let dance = match wo_show::scenes::dance_dir() {
        Some(dir) => {
            let t = Instant::now();
            let co = wo_dance::sim::Company::load(&dir);
            eprintln!("stage: dancers from {} ({} in {:.0} ms)", dir.display(), co.as_ref().map_or(0, |c| c.rigs.len()), t.elapsed().as_secs_f64() * 1000.0);
            co.map(|c| (c, wo_dance::sim::DanceSim::from_env()))
        }
        None => {
            eprintln!("stage: no dancers here (WETOWL_DANCE, dance/ beside the stage)");
            None
        }
    };
    let mut app = App { args, instance, book, source, play: Play::default(), win: None, started: now, last: now, frames: 0, since: now, shown_due: now, pictures: 0, heard: 0, cues: 0, black: 0.0, presented: now, missing: None, milk, covers: [None, None], ground: None, dance, picture_cam: Default::default(), paced: false, due: now, phase: 0.0 };
    el.run_app(&mut app).expect("the stage ran");
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_shown_line_reads_as_the_desk_reads_it() {
        let v = serde_json::json!({"scene": "glide", "screens": [{"name": "HDMI-1", "w": 1920, "h": 1080}], "screen": "HDMI-1", "full": true});
        let line = super::t_first("shown", &v);
        assert!(line.starts_with(r#"{"t":"shown","#), "{line}");
        let s = wo_wire::shown(&line).expect("read");
        assert_eq!((s.scene.as_deref(), s.screen.as_deref(), s.full, s.screens.len()), (Some("glide"), Some("HDMI-1"), true, 1));
    }
}
