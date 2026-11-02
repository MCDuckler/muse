//! How long the stage's whole frame takes on this GPU, per scene, at an output size and a
//! working scale: frames drawn back to back into an offscreen picture, each waited for.
//!   cargo run --release -p wo-render --example stage_bench -- [1920x1080] [scale 1.0] [frames 240]
use std::time::Instant;

use wo_render::{Gpu, Stage};
use wo_show::deck::{Channel, RecordFacts, ShowAudio, ShowDeck};
use wo_show::frame::stage_frame;
use wo_show::rig::{Ground, RigBlend, RigGround};
use wo_show::scenes::{DRAWN, SceneBook};
use wo_show::state::{Dynamics, ShowState};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (w, h) = args.first().and_then(|s| s.split_once('x')).map(|(a, b)| (a.parse().unwrap(), b.parse().unwrap())).unwrap_or((1920u32, 1080u32));
    let scale: f32 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(1.0);
    let frames: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(240);
    let gpu = Gpu::headless().expect("a GPU");
    println!("{} on {:?}, {w}x{h}, working scale {scale}", gpu.info.name, gpu.info.backend);
    let book = SceneBook::shipped();
    let period = 60_000.0 / 128.0;
    let beats: Vec<f64> = (0..2048).map(|i| i as f64 * period).collect();
    let r = RecordFacts { track_id: Some(9), steady: Some((0.0, period)), downbeats_ms: beats.iter().step_by(4).copied().collect(), beats_ms: beats, energy: vec![200; 512], ..Default::default() };
    let target = wo_render::target(&gpu, w, h);
    let view = target.create_view(&Default::default());
    type Run<'a> = (String, &'a str, Option<(Ground, Option<&'a str>)>);
    let mut runs: Vec<Run> = DRAWN.iter().map(|s| (s.to_string(), *s, None)).collect();
    runs.push(("glide on drift (field), screen".into(), "glide", Some((Ground::Field, Some("drift")))));
    runs.push(("flash on pulse, add".into(), "flash", Some((Ground::Pulse, Some("smoke")))));
    for (label, scene, ground) in runs {
        let mut stage = Stage::new(&gpu, wgpu::TextureFormat::Rgba8Unorm).unwrap();
        stage.scale = scale;
        let mut dyns = Dynamics::default();
        let mut times = vec![];
        for i in 0..frames + 30 {
            let t = i as f64 / 60.0;
            let kick = if (t * 1000.0) % 468.75 < 60.0 { 0.95 } else { 0.15 };
            let audio = ShowAudio { low: 0.6, mid: 0.4, high: 0.35, kick, ..Default::default() };
            let a = ShowDeck::derive("A", Some(&r), true, 30_000.0 + t * 1000.0, Channel::default(), audio);
            let dyn_ = dyns.frame(&audio, &a, 1.0 / 60.0, true);
            let mut st = ShowState { audio, a, scene: Some(scene.into()), dyn_, ..Default::default() };
            if let Some((kind, field)) = ground {
                let mut rig = book.scenes[scene].rig();
                rig.ground = RigGround { kind, field: field.map(Into::into), ..Default::default() };
                rig.blend = RigBlend { mix: if kind == Ground::Pulse { wo_show::Mix::Add } else { wo_show::Mix::Screen }, ..Default::default() };
                st.rig = rig;
            }
            let f = stage_frame(&st, &book, t);
            let t0 = Instant::now();
            let cmd = stage.draw(&gpu, &f, 1.0 / 60.0, Some(&view), w, h, None);
            gpu.queue.submit([cmd]);
            let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
            if i >= 30 {
                times.push(t0.elapsed().as_secs_f64() * 1000.0);
            }
        }
        // back to back, as a stage runs: the GPU never waits for the CPU between frames
        let t0 = Instant::now();
        let n = frames.min(120);
        for i in 0..n {
            let t = 10.0 + i as f64 / 60.0;
            let a = ShowDeck::derive("A", Some(&r), true, t * 1000.0, Channel::default(), ShowAudio::default());
            let st = ShowState { a, scene: Some(scene.into()), ..Default::default() };
            let f = stage_frame(&st, &book, t);
            let cmd = stage.draw(&gpu, &f, 1.0 / 60.0, Some(&view), w, h, None);
            gpu.queue.submit([cmd]);
            if i % 3 == 2 {
                let _ = gpu.device.poll(wgpu::PollType::Poll);
            }
        }
        let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
        let piped = t0.elapsed().as_secs_f64() * 1000.0 / n as f64;
        times.sort_by(f64::total_cmp);
        let mean = times.iter().sum::<f64>() / times.len() as f64;
        let p95 = times[(times.len() * 95 / 100).min(times.len() - 1)];
        println!("{label:32} waited: mean {mean:5.2} ms p95 {p95:5.2} ms · back to back {piped:5.2} ms/frame ({} particles)", stage.drawn.particles);
    }
}
