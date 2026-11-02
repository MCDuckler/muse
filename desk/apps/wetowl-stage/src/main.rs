//! WetOwl's stage in Rust (plan: ~/.claude/plans/wetowl-stage-rust.md). P0 skeleton: a
//! window, a wgpu surface, one scene drawn at the display's rate, full screen on a screen
//! chosen by name.
//!
//!   wetowl-stage [--scene blocks] [--screen <name>] [--seconds N] [--list-screens]
//!
//! Every second it says `STAGE fps=… size=WxH screen=<name> full=0|1`.
use std::sync::Arc;
use std::time::{Duration, Instant};

use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::monitor::MonitorHandle;
use winit::window::{Fullscreen, Window, WindowId};
use wo_render::{Gpu, Pass, wgpu};

struct Args {
    scene: String,
    screen: Option<String>,
    seconds: Option<f64>,
    list: bool,
}

fn args() -> Args {
    let a: Vec<String> = std::env::args().collect();
    let after = |flag: &str| a.iter().position(|x| x == flag).and_then(|i| a.get(i + 1)).cloned();
    Args {
        scene: after("--scene").unwrap_or_else(|| "blocks".into()),
        screen: after("--screen"),
        seconds: after("--seconds").and_then(|s| s.parse().ok()),
        list: a.iter().any(|x| x == "--list-screens"),
    }
}

/// A screen's name as the Desk shows it (winit's, else its place).
fn screen_name(m: &MonitorHandle, i: usize) -> String {
    m.name().filter(|n| !n.trim().is_empty()).unwrap_or_else(|| format!("Screen {}", i + 1))
}

struct Drawn {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    gpu: Gpu,
    pass: Pass,
    floats: usize,
}

struct Stage {
    args: Args,
    instance: wgpu::Instance,
    drawn: Option<Drawn>,
    started: Instant,
    frames: u32,
    since: Instant,
}

impl Stage {
    fn report(&mut self) {
        let Some(d) = &self.drawn else { return };
        let secs = self.since.elapsed().as_secs_f64();
        if secs < 1.0 {
            return;
        }
        let size = d.window.inner_size();
        let screen = d.window.current_monitor().map(|m| m.name().unwrap_or_default()).unwrap_or_default();
        println!(
            "STAGE fps={:.1} size={}x{} screen={} full={} gpu={} ({:?})",
            self.frames as f64 / secs,
            size.width,
            size.height,
            screen,
            d.window.fullscreen().is_some() as u8,
            d.gpu.info.name,
            d.gpu.info.backend
        );
        self.frames = 0;
        self.since = Instant::now();
    }
}

impl ApplicationHandler for Stage {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        if self.drawn.is_some() {
            return;
        }
        let monitors: Vec<MonitorHandle> = el.available_monitors().collect();
        if self.args.list {
            for (i, m) in monitors.iter().enumerate() {
                let s = m.size();
                println!("SCREEN {} {}x{}", screen_name(m, i), s.width, s.height);
            }
            el.exit();
            return;
        }
        let mut attrs = Window::default_attributes().with_title("WetOwl · Stage").with_inner_size(winit::dpi::LogicalSize::new(1280.0, 720.0));
        if let Some(want) = &self.args.screen {
            match monitors.iter().enumerate().find(|(i, m)| &screen_name(m, *i) == want) {
                Some((_, m)) => attrs = attrs.with_fullscreen(Some(Fullscreen::Borderless(Some(m.clone())))),
                None => eprintln!("stage: no screen called {want}"),
            }
        }
        let window = Arc::new(el.create_window(attrs).expect("a window"));
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
        let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../app/shaders/show");
        let src = std::fs::read_to_string(dir.join(format!("{}.frag", self.args.scene))).expect("the scene's shader");
        let fitted = wo_render::wo_shaders::fit(&self.args.scene, &src).unwrap_or_else(|t| panic!("{t}"));
        assert!(fitted.samplers.is_empty(), "P0 draws scenes with no samplers");
        let pass = Pass::new(&gpu, &fitted, format);
        let floats = fitted.float_count();
        window.request_redraw();
        self.drawn = Some(Drawn { window, surface, config, gpu, pass, floats });
    }

    fn window_event(&mut self, el: &ActiveEventLoop, _: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => el.exit(),
            WindowEvent::Resized(size) => {
                if let Some(d) = &mut self.drawn {
                    d.config.width = size.width.max(1);
                    d.config.height = size.height.max(1);
                    d.surface.configure(&d.gpu.device, &d.config);
                }
            }
            WindowEvent::RedrawRequested => {
                if self.args.seconds.is_some_and(|s| self.started.elapsed() > Duration::from_secs_f64(s)) {
                    self.report();
                    el.exit();
                    return;
                }
                let t = self.started.elapsed().as_secs_f32();
                let Some(d) = &self.drawn else { return };
                let frame = match d.surface.get_current_texture() {
                    wgpu::CurrentSurfaceTexture::Success(f) | wgpu::CurrentSurfaceTexture::Suboptimal(f) => f,
                    wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                        d.surface.configure(&d.gpu.device, &d.config);
                        d.window.request_redraw();
                        return;
                    }
                    _ => {
                        d.window.request_redraw();
                        return;
                    }
                };
                let view = frame.texture.create_view(&Default::default());
                // the common block at a moment moving with the clock (P2 brings the show's)
                let beat = (t * 2.0).fract();
                let mut v = vec![0.5f32; d.floats];
                v[0] = d.config.width as f32;
                v[1] = d.config.height as f32;
                v[2] = t; // uTime
                v[3] = beat; // uBeat
                v[4] = (t / 2.0).fract(); // uBar
                if d.floats > 25 {
                    v[25] = (1.0 - beat).powi(3); // uHitKick
                }
                let mut enc = d.gpu.device.create_command_encoder(&Default::default());
                d.pass.draw(&d.gpu, &mut enc, &view, &v, &[]);
                d.gpu.queue.submit([enc.finish()]);
                d.gpu.queue.present(frame);
                self.frames += 1;
                self.report();
                if let Some(d) = &self.drawn {
                    d.window.request_redraw();
                }
            }
            _ => {}
        }
    }
}

fn main() {
    let el = EventLoop::new().expect("an event loop");
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_with_display_handle_from_env(Box::new(el.owned_display_handle())));
    let mut stage = Stage { args: args(), instance, drawn: None, started: Instant::now(), frames: 0, since: Instant::now() };
    el.run_app(&mut stage).expect("the stage ran");
}
