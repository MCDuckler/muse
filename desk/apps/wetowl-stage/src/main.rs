//! WetOwl's stage in Rust (plan: ~/.claude/plans/wetowl-stage-rust.md): the show in a window
//! of its own, drawn on wgpu (Vulkan, Direct3D 12, Metal).
//!
//!   wetowl-stage --stage <ws url>    the Desk's show: it directs, this draws (ShowWire v2)
//!   wetowl-stage                     on its own: its own director over a made-up record
//!     [--scene <id>]                 that scene held (on its own)
//!     [--screen <name>]              full screen there from the start
//!     [--scale <0.5..1>]             the working size's share of the window's (it adapts)
//!     [--seconds N] [--list-screens]
//!
//! From the Desk it reads the decks as the ear hears them (`desk`), each deck's record
//! (`record`) and the director's decision (`cue`); between the Desk's frames it carries the
//! decks on, so it draws at the display's rate. It sends back its picture ten times a second
//! and what it shows (its screens), and goes full screen where the Desk's hands say.
//!
//! Every second it says `STAGE fps=… size=WxH screen=<name> full=0|1 gpu=… scene=… work=WxH`.
mod link;

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
            Source::Own { direct, facts, t0 } => {
                let len = 96.0 * 4.0 * 60_000.0 / 128.0;
                let ms = (t0.elapsed().as_secs_f64() * 1000.0) % len;
                let beat = (ms / (60_000.0 / 128.0)).fract();
                let loud = facts.energy.get((ms / (4.0 * 60_000.0 / 128.0)) as usize).map_or(0.5, |e| *e as f64 / 255.0);
                let kick = (1.0 - beat * 4.0).max(0.0) * loud;
                let audio = ShowAudio { sub: 0.5 * loud, low: 0.3 + 0.5 * kick, mid: 0.4 * loud, high: 0.2 + 0.3 * (beat * 8.0).fract() * loud, air: 0.2, kick, onset: kick, ..Default::default() };
                let a = ShowDeck::derive("A", Some(facts), true, ms, Channel::default(), audio);
                let room = Room { a, b: ShowDeck { name: "B".into(), ..Default::default() }, audio, ..Default::default() };
                let (cue, _) = direct.tick(dt, room.clone(), Default::default());
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
    missing: Option<String>,
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
            "STAGE fps={:.1} size={}x{} screen={} full={} gpu={} ({:?}) scene={} work={}x{} ms={:.1} heard={} cues={} pictures={} black={}",
            self.frames as f64 / secs,
            size.width,
            size.height,
            screen,
            d.window.fullscreen().is_some() as u8,
            d.gpu.info.name,
            d.gpu.info.backend,
            self.play_scene().unwrap_or("-"),
            ww,
            wh,
            d.took.load(Ordering::Relaxed) as f64 / 1000.0,
            self.heard,
            self.cues,
            self.pictures,
            self.black,
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
        let v = serde_json::json!({"scene": self.play_scene(), "screens": list, "screen": screen, "full": full});
        link.send(Message::text(t_first("shown", &v)));
    }

    /// A frame: into the window (`present`), or — while the window is not shown, so the
    /// compositor asks for no frames (a hidden window on Wayland, headless) — only the
    /// Desk's picture, when one is due. Either way the Desk is heard and told.
    fn draw(&mut self, el: &ActiveEventLoop, present: bool) {
        if self.args.seconds.is_some_and(|s| self.started.elapsed() > Duration::from_secs_f64(s)) {
            self.report();
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
        let f = stage_frame(&st, &self.book, self.started.elapsed().as_secs_f64());
        self.black = f.black;
        let Some(d) = &mut self.win else { return };
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
            d.window.request_redraw();
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
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            color_space: wgpu::SurfaceColorSpace::Auto,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::Fifo,
            desired_maximum_frame_latency: 2,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
        };
        surface.configure(&gpu.device, &config);
        let t0 = Instant::now();
        let mut stage = Stage::new(&gpu, format).unwrap_or_else(|e| panic!("the stage's shaders: {e}"));
        stage.scale = self.args.scale;
        eprintln!("stage: {} shaders ready in {:.0} ms on {} ({:?})", wo_render::stage::stage_shaders().len() + 2, t0.elapsed().as_secs_f64() * 1000.0, gpu.info.name, gpu.info.backend);
        window.request_redraw();
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
        el.set_control_flow(ControlFlow::WaitUntil(Instant::now() + Duration::from_millis(30)));
    }
}

fn main() {
    let args = args();
    let book = SceneBook::shipped().only(DRAWN);
    let source = match &args.url {
        Some(url) => Source::Desk { link: Link::open(url.clone()), frame: None, facts: Box::new([None, None]), cue: Box::default(), joined: false, lost_since: None },
        None => {
            let mut direct = Direct::new(&book, ShowDoc::default(), wo_show::scores::ComboScores::shipped(), 11);
            if let Some(s) = &args.scene {
                direct.director.choose(s, wo_show::director::SceneChange::Cut);
                direct.hold(true);
            }
            Source::Own { direct: Box::new(direct), facts: own_record(), t0: Instant::now() }
        }
    };
    let el = EventLoop::new().expect("an event loop");
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_with_display_handle_from_env(Box::new(el.owned_display_handle())));
    let now = Instant::now();
    let mut app = App { args, instance, book, source, play: Play::default(), win: None, started: now, last: now, frames: 0, since: now, shown_due: now, pictures: 0, heard: 0, cues: 0, black: 0.0, presented: now, missing: None };
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
