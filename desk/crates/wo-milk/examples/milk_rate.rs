//! P0 spike: MilkDrop's frames into a wgpu texture — how many a second come through at a
//! size, and what the copy costs.
//!   cargo run --release -p wo-milk --example milk_rate -- <wetowl-milk> <preset.milk> [WxH] [seconds]
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let program = PathBuf::from(a.get(1).expect("the helper"));
    let preset = a.get(2).expect("a preset").clone();
    let (w, h) = a.get(3).and_then(|s| s.split_once('x')).map(|(w, h)| (w.parse().unwrap(), h.parse().unwrap())).unwrap_or((1280u32, 720u32));
    let secs: f64 = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(10.0);
    let gpu = wo_render::Gpu::headless().expect("a GPU");
    let tex = wo_render::upload(&gpu, w, h, &vec![0u8; (w * h * 4) as usize]);
    let mut milk = wo_milk::Milk::start(&program, w, h, 60, None).expect("the helper");
    milk.say(&format!("preset {preset}")).unwrap();
    let t0 = Instant::now();
    let cpu0 = cpu_time::ProcessTime::now();
    let (mut shown, mut upload_ms, mut last_seq) = (0u32, 0.0f64, None);
    let mut phase = 0.0f32;
    while t0.elapsed().as_secs_f64() < secs {
        // the room's sound: a kick-ish thump at 128 BPM, a frame's worth
        let mut pcm = vec![0i16; 735];
        for (i, s) in pcm.iter_mut().enumerate() {
            let t = t0.elapsed().as_secs_f32() + i as f32 / 44100.0;
            let env = (-((t * 128.0 / 60.0).fract()) * 8.0).exp();
            phase += 55.0 / 44100.0;
            *s = ((phase * std::f32::consts::TAU).sin() * env * 20000.0) as i16;
        }
        let _ = milk.pcm(&pcm);
        if let Some(f) = milk.take()
            && f.width == w
            && f.height == h
        {
            {
                let u = Instant::now();
                gpu.queue.write_texture(
                    wgpu::TexelCopyTextureInfo { texture: &tex, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
                    &f.rgba,
                    wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4 * w), rows_per_image: Some(h) },
                    wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                );
                gpu.queue.submit([]);
                upload_ms += u.elapsed().as_secs_f64() * 1000.0;
                shown += 1;
                last_seq = Some(f.seq);
            }
        }
        std::thread::sleep(Duration::from_millis(16));
    }
    let wall = t0.elapsed().as_secs_f64();
    let cpu = cpu0.elapsed().as_secs_f64();
    for l in milk.said() {
        if !l.trim().is_empty() {
            println!("milk said: {l}");
        }
    }
    println!(
        "{w}x{h}: read {:.1} frames/s, shown {:.1}/s, copy {:.2} ms each, this process {:.0}% of a core, last seq {:?}, alive {}",
        milk.frames() as f64 / wall,
        shown as f64 / wall,
        upload_ms / shown.max(1) as f64,
        100.0 * cpu / wall,
        last_seq,
        milk.alive()
    );
}
