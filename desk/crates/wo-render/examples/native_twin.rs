//! The Rust stage fed as the native stage's bench (app/native/stage/tools/stage_bench.cpp)
//! feeds the native stage — the same made-up 128 BPM record frame by frame, the same scene,
//! knobs, finish and looks — so the two pictures can be held side by side (plan §11, P4).
//!
//!   cargo run --release -p wo-render --example native_twin -- --scene kinetic --size 640x360 \
//!       --frames 60 [--treat mode [--cell px]] [--slit shape] [--mosh scene] [--mosh-hold grain] \
//!       [--trails d] [--bloom b] [--m1 v] --ppm out.ppm [--ppm-at f]
//!
//! As the bench: a frame every 1/60 s of the record's clock; the treatment's glyphs a white
//! block four wide; no particles, no ground. The bench's frames come as fast as the GPU draws
//! them and its datamosh runs on the wall clock, so a mosh's frames compare loosely.
use std::io::Write as _;

use wo_render::{Gpu, Stage};
use wo_show::frame::{GroundDraw, Post, ShaderLayer, StageFrame};
use wo_show::mosh::MoshDrive;
use wo_show::treat::{FxDraw, SlitDraw, Style};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let get = |k: &str| args.iter().position(|a| a == k).and_then(|i| args.get(i + 1)).cloned();
    let num = |k: &str, or: f32| get(k).and_then(|v| v.parse().ok()).unwrap_or(or);
    let scene = get("--scene").unwrap_or_else(|| "kinetic".into());
    let (w, h) = get("--size").and_then(|s| s.split_once('x').map(|(a, b)| (a.parse().unwrap(), b.parse().unwrap()))).unwrap_or((640u32, 360u32));
    let frames = num("--frames", 300.0) as i64;
    let trails = num("--trails", 0.0);
    let bloom = num("--bloom", 0.6);
    let m1 = num("--m1", 0.0);
    let treat = num("--treat", 0.0) as u32;
    let cell = num("--cell", 0.0);
    let slit = get("--slit").and_then(|v| v.parse::<f32>().ok());
    let mosh = get("--mosh");
    let mosh_hold = get("--mosh-hold").and_then(|v| v.parse::<f32>().ok());
    let ppm = get("--ppm");
    let ppm_at = get("--ppm-at").and_then(|v| v.parse::<i64>().ok()).unwrap_or(frames - 1);

    let gpu = Gpu::headless().expect("a GPU");
    let mut stage = Stage::new(&gpu, wgpu::TextureFormat::Rgba8Unorm).expect("the stage");
    // the bench's glyphs: a white block, four of them
    stage.set_glyphs(&gpu, 64, 16, &vec![255u8; 64 * 16 * 4], 4);
    let target = wo_render::target(&gpu, w, h);
    let view = target.create_view(&Default::default());
    let mut scene_now = scene.clone();
    let mut moshes = 0;
    for f in 0..frames {
        let t = f as f64 / 60.0;
        let beats = t * 128.0 / 60.0;
        let beat = beats - beats.floor();
        let in_bar = (beats.floor() as i64 % 4) as f64;
        let kick = (-beat * 9.0).exp() as f32;
        let mut v = [0f32; 35];
        v[0] = t as f32;
        v[1] = beat as f32;
        v[2] = ((in_bar + beat) / 4.0) as f32;
        v[3] = (beats / 16.0).rem_euclid(1.0) as f32;
        v[4] = 0.8;
        v[5] = 0.8;
        v[6] = kick;
        v[7] = 0.6 + 0.4 * kick;
        v[8] = 0.5;
        v[9] = 0.4;
        v[10] = 0.3;
        v[11] = kick;
        v[12] = 0.62;
        v[13] = 0.95;
        v[17] = 0.2;
        v[18] = m1;
        v[22] = kick;
        v[23] = if in_bar as i64 % 2 == 1 { (-beat * 7.0).exp() as f32 } else { 0.0 };
        v[24] = ((-(beat * 2.0).rem_euclid(1.0) * 10.0).exp() * 0.5) as f32;
        v[25] = (-beat * 6.0).exp() as f32;
        v[26] = (-((in_bar + beat) / 4.0) * 5.0).exp() as f32;
        v[27] = ((in_bar + beat) / 4.0) as f32;
        v[28] = (beats / 16.0).rem_euclid(1.0) as f32;
        v[29] = if in_bar == 0.0 { (-beat * 6.0).exp() as f32 } else { 0.0 };
        v[30] = 0.9;
        v[31] = 0.5 + 0.5 * kick;
        v[32] = 0.5;
        v[33] = 0.4;
        v[34] = (beats / 4.0).floor() as f32;
        if let Some(m) = &mosh
            && f == frames / 2
        {
            scene_now = m.clone();
            moshes += 1;
        }
        let style = if let Some(shape) = slit {
            Some(Style::Slit(SlitDraw { shape, flip: false, reach: 1.0, slower: 1.0 }))
        } else if treat > 0 {
            let c = if cell > 0.0 { cell } else { 8.0 };
            Some(Style::Fx(FxDraw { mode: treat, ink: [0.965, 0.86, 1.0], paper: [0.027, 0.008, 0.06], cell_min: c, cell_div: 1e9, cell_k: 1.0, tint: 0.2, knobs: [1.0; 5] }))
        } else {
            None
        };
        let mosh_hold = match mosh_hold {
            Some(grain) => {
                let bar_phase = beats.rem_euclid(4.0) / 4.0;
                let pulse = (-bar_phase * 14.0).exp() as f32;
                MoshDrive { on: f >= 10, heal: 0.22 + 0.38 * pulse, strength: 1.2, grain, keys: (beats / 32.0).floor() as i64 }
            }
            None => MoshDrive::default(),
        };
        let frame = StageFrame {
            scene: Some(scene_now.clone()),
            figure: Some(ShaderLayer { shader: scene_now.clone(), knobs: [m1, 0.0, 0.0, 0.0], milk: false }),
            from: None,
            k: 1.0,
            common: v,
            ground: GroundDraw::Black,
            ground_dim: 1.0,
            blend: None,
            post: Post { trails, bloom, vignette: 0.6, grain: 0.4, tone: 1.0, fringe: 0.006 },
            // the native stage's trails where the frame brings no recipe
            recipe: [trails, 1.0 + 0.010 * v[4], 0.003, 0.12, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            particles: vec![],
            palette: [[1.0; 3]; 3],
            white: 0.0,
            black: 0.0,
            freeze: false,
            mosh: moshes,
            mosh_cut: (1.9, 1.0),
            mosh_hold,
            slit: None,
            kaleido: None,
            style,
            camera: [1.0, 0.0, 0.0, 0.0],
        };
        let cmd = stage.draw(&gpu, &frame, 1.0 / 60.0, Some(&view), w, h, None);
        gpu.queue.submit([cmd]);
        if f == ppm_at
            && let Some(p) = &ppm
        {
            let px = wo_render::read(&gpu, &target);
            let mut out = std::fs::File::create(p).unwrap();
            writeln!(out, "P6 {w} {h} 255").unwrap();
            for c in px.chunks(4) {
                out.write_all(&c[..3]).unwrap();
            }
        } else {
            let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
        }
    }
    if let Some(m) = stage.drawn.missing {
        eprintln!("missing: {m}");
    }
}
