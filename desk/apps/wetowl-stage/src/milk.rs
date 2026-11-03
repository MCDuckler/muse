//! MilkDrop on the Rust stage (v1: milk_feed.dart's helper half): the wetowl-milk helper run
//! while a frame wants MilkDrop's picture (the milk scene, a milk ground), the Desk's preset
//! put on as its cue says (cut, or blended over its seconds), fed every frame — the show's
//! numbers by name, the accents, MilkDrop's levels from the show's own hits, the room's sound —
//! and its newest frame made a texture for the stage.
//!
//! Unwanted for two seconds it draws two frames a second (warm for when it is looked at
//! again); for half a minute, it stops. A helper that dies is started again after a second,
//! then longer while it keeps dying soon after starting, up to half a minute; the preset it
//! died on is told to the Desk (and not put on again this run).
use std::path::PathBuf;
use std::time::{Duration, Instant};

use wo_milk::Milk;
use wo_render::wgpu;
use wo_show::milk::{MilkAccent, MilkCue, levels, vars_of};
use wo_show::state::ShowState;
use wo_wire::MilkShown;

/// MilkDrop's picture: a quarter of 1080p, scaled up (P0: 720p was the HP's limit beside the
/// stage; v1 drew 960×540 too).
pub const WIDTH: u32 = 960;
pub const HEIGHT: u32 = 540;
const FPS: u32 = 60;
const IDLE_FPS: u32 = 2;

/// The helper: WETOWL_MILK, beside this program, in the WetOwl app's bundle beside the Desk
/// (Linux: stage/lib; a Mac: the nested WetOwl.app), or the WetOwl app's own install.
pub fn program() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("WETOWL_MILK").map(PathBuf::from).filter(|p| p.is_file()) {
        return Some(p);
    }
    let name = if cfg!(windows) { "wetowl-milk.exe" } else { "wetowl-milk" };
    let exe = std::env::current_exe().ok().and_then(|e| e.parent().map(PathBuf::from));
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let mut c = vec![];
    if let Some(d) = &exe {
        c.push(d.join(name));
        c.push(d.join("stage").join("lib").join(name));
        c.push(d.join("lib").join(name));
        if let Some(contents) = d.parent() {
            c.push(contents.join("Helpers/WetOwl.app/Contents/MacOS").join(name));
        }
    }
    if let Some(h) = home.filter(|_| cfg!(target_os = "linux")) {
        c.push(h.join(".local/opt/wetowl/lib").join(name));
    }
    c.into_iter().find(|p| p.is_file())
}

pub struct MilkRun {
    program: Option<PathBuf>,
    milk: Option<Milk>,
    loaded: u64,
    on_path: Option<String>,
    lock: Option<bool>,
    started: Option<Instant>,
    not_before: Option<Instant>,
    crashes: u32,
    crashed: Vec<String>,
    preset: Option<String>,
    trouble: Option<String>,
    wanted: Instant,
    idle: bool,
    accent: MilkAccent,
    att: [f64; 3],
    /// The room's sound waiting for the helper, 44.1 kHz.
    pcm: Vec<i16>,
    texture: Option<(wgpu::Texture, wgpu::TextureView)>,
    frames: u64,
    fps: (Instant, u64, f32),
}

impl MilkRun {
    pub fn new() -> MilkRun {
        let now = Instant::now();
        MilkRun {
            program: program(),
            milk: None,
            loaded: 0,
            on_path: None,
            lock: None,
            started: None,
            not_before: None,
            crashes: 0,
            crashed: vec![],
            preset: None,
            trouble: None,
            wanted: now - Duration::from_secs(3600),
            idle: false,
            accent: MilkAccent::default(),
            att: [1.0; 3],
            pcm: vec![],
            texture: None,
            frames: 0,
            fps: (now, 0, 0.0),
        }
    }

    /// There is a helper to run.
    pub fn ok(&self) -> bool {
        self.program.is_some()
    }

    /// The room's sound from the Desk (wo_wire::pcm: `PCM1`, the rate, mono 16-bit), at
    /// 44.1 kHz for projectM; a second at most kept.
    pub fn pcm(&mut self, b: &[u8]) {
        if b.len() < 8 || &b[..4] != b"PCM1" {
            return;
        }
        let rate = u32::from_le_bytes([b[4], b[5], b[6], b[7]]).max(1) as f64;
        let src: Vec<i16> = b[8..].as_chunks::<2>().0.iter().map(|c| i16::from_le_bytes(*c)).collect();
        if src.is_empty() || self.milk.is_none() {
            return;
        }
        let n = ((src.len() as f64) * 44_100.0 / rate).round() as usize;
        let step = rate / 44_100.0;
        for i in 0..n {
            let x = i as f64 * step;
            let j = x as usize;
            let (a, c) = (src[j.min(src.len() - 1)] as f64, src[(j + 1).min(src.len() - 1)] as f64);
            self.pcm.push((a + (c - a) * (x - j as f64)).round() as i16);
        }
        let over = self.pcm.len().saturating_sub(44_100);
        self.pcm.drain(..over);
    }

    /// Sound already at 44.1 kHz (a stage on its own makes its own).
    pub fn pcm_44k(&mut self, samples: &[i16]) {
        if self.milk.is_none() {
            return;
        }
        self.pcm.extend_from_slice(samples);
        let over = self.pcm.len().saturating_sub(44_100);
        self.pcm.drain(..over);
    }

    fn stop(&mut self) {
        self.milk = None;
        self.texture = None;
        self.preset = None;
        self.pcm.clear();
    }

    /// One frame of the stage: `wanted` where it draws MilkDrop now. Its newest picture.
    pub fn frame(&mut self, gpu: &wo_render::Gpu, st: &ShowState, cue: &MilkCue, wanted: bool, dt: f64) -> Option<&wgpu::TextureView> {
        let now = Instant::now();
        if wanted {
            self.wanted = now;
        }
        let unwanted = now - self.wanted;
        // gone on its own: the preset it was on is not put on again, and it starts again
        // after a while, longer each time it dies soon after starting
        if self.milk.as_ref().is_some_and(|m| !m.alive()) {
            let said = self.milk.as_ref().map(Milk::said).unwrap_or_default();
            let why = said.iter().rev().find(|l| !l.trim().is_empty()).cloned();
            eprintln!("milk: the helper stopped{}", why.as_deref().map(|w| format!(" ({w})")).unwrap_or_default());
            if let Some(p) = self.on_path.take()
                && !self.crashed.contains(&p)
            {
                eprintln!("milk: not again this run: {p}");
                self.crashed.push(p);
            }
            self.crashes = if self.started.is_some_and(|t| now - t < Duration::from_secs(30)) { self.crashes + 1 } else { 1 };
            self.not_before = Some(now + Duration::from_secs((1u64 << (self.crashes - 1).min(5)).min(30)));
            self.trouble = Some("MilkDrop stopped".into());
            self.stop();
        }
        if self.milk.is_some() && unwanted > Duration::from_secs(30) {
            self.stop();
        }
        if self.milk.is_none() && wanted && self.not_before.is_none_or(|t| now >= t) {
            let Some(program) = &self.program else { return None };
            let textures = cue.textures.as_ref().map(PathBuf::from);
            match Milk::start(program, WIDTH, HEIGHT, FPS, textures.as_deref()) {
                Ok(m) => {
                    self.milk = Some(m);
                    self.started = Some(now);
                    self.loaded = 0;
                    self.lock = None;
                    self.idle = false;
                    self.trouble = None;
                }
                Err(e) => {
                    self.trouble = Some(format!("wetowl-milk: {e}"));
                    self.not_before = Some(now + Duration::from_secs(30));
                    return None;
                }
            }
        }
        let m = self.milk.as_mut()?;
        // its rate: two frames a second while nothing looks
        let idle = unwanted > Duration::from_secs(2);
        if idle != self.idle {
            self.idle = idle;
            let _ = m.say(&format!("fps {}", if idle { IDLE_FPS } else { FPS }));
        }
        // the Desk's preset: a cut, or blended into (the first after a start, a cut)
        if cue.n != self.loaded
            && let Some(path) = &cue.path
        {
            if !self.crashed.contains(path) {
                let soft = cue.soft && self.loaded != 0;
                if soft {
                    let _ = m.say(&format!("blend {:.2}", cue.blend));
                }
                let _ = m.say(&format!("{} {path}", if soft { "preset-soft" } else { "preset" }));
                self.on_path = Some(path.clone());
            }
            self.loaded = cue.n;
        }
        if self.lock != Some(cue.lock) {
            self.lock = Some(cue.lock);
            let _ = m.say(&format!("lock {}", cue.lock as u8));
        }
        // the show's numbers, the accents, the levels, the sound
        let mut vars: Vec<(&str, f64)> = vars_of(st);
        if cue.accents {
            vars.extend(self.accent.frame(st.master(), dt, cue.react, st.master().track_id.unwrap_or(0)));
        } else {
            vars.extend(MilkAccent::none());
        }
        let line: Vec<String> = vars.iter().map(|(k, v)| format!("{k}={v:.4}")).collect();
        let _ = m.say(&format!("vars {}", line.join(" ")));
        let lv = levels(st, &mut self.att);
        let _ = m.say(&format!("audio {}", lv.iter().map(|v| format!("{v:.3}")).collect::<Vec<_>>().join(" ")));
        if !self.pcm.is_empty() {
            let s = std::mem::take(&mut self.pcm);
            let _ = m.pcm(&s);
        }
        for line in m.said() {
            if let Some(name) = line.strip_prefix("preset ok ") {
                self.preset = Some(name.to_owned());
                eprintln!("milk: {line}");
            } else if ["egl:", "wgl:", "cgl:", "gl:", "projectm:", "frames:"].iter().any(|p| line.starts_with(p)) {
                // its own word on why it cannot draw
                eprintln!("milk: {line}");
                self.trouble = Some(line);
            } else if line.starts_with("preset failed ") || line.starts_with("egl ") || line.starts_with("wgl ") || line.starts_with("cgl ") {
                // a preset that would not load; the renderer it made
                eprintln!("milk: {line}");
            }
        }
        // its newest frame, as a texture
        if let Some(f) = m.take() {
            self.frames += 1;
            if self.texture.as_ref().is_none_or(|(t, _)| t.width() != f.width || t.height() != f.height) {
                let t = gpu.device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("MilkDrop"),
                    size: wgpu::Extent3d { width: f.width, height: f.height, depth_or_array_layers: 1 },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                    view_formats: &[],
                });
                let v = t.create_view(&Default::default());
                self.texture = Some((t, v));
            }
            let (t, _) = self.texture.as_ref().unwrap();
            gpu.queue.write_texture(
                wgpu::TexelCopyTextureInfo { texture: t, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
                &f.rgba,
                wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4 * f.width), rows_per_image: Some(f.height) },
                wgpu::Extent3d { width: f.width, height: f.height, depth_or_array_layers: 1 },
            );
        }
        let (t0, n0, _) = self.fps;
        if now - t0 >= Duration::from_secs(1) {
            self.fps = (now, self.frames, (self.frames - n0) as f32 / (now - t0).as_secs_f32());
        }
        self.texture.as_ref().map(|(_, v)| v)
    }

    /// For the Desk.
    pub fn shown(&self) -> MilkShown {
        MilkShown {
            ok: self.ok(),
            on: self.milk.is_some() && self.texture.is_some(),
            preset: self.preset.clone(),
            crashed: self.crashed.clone(),
            trouble: self.trouble.clone(),
            fps: self.fps.2,
        }
    }
}
