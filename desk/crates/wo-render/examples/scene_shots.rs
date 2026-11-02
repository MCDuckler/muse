//! P0 spike: every in-scope scene shader drawn once, headless, on this machine's GPU, with
//! the show's numbers at a made-up moment — and one sheet of them.
//!   cargo run --release -p wo-render --example scene_shots -- <out dir>
use std::path::PathBuf;

use wo_render::{Gpu, Pass};

/// The common block's floats after uResolution (shaders/show/common.glsl), at a moment
/// in a loud bar: name → value.
const COMMON: &[(&str, f32)] = &[
    ("uTime", 4.0), ("uBeat", 0.3), ("uBar", 0.3), ("uPhrase", 0.2), ("uEnergy", 0.7), ("uIntensity", 1.0),
    ("uKick", 0.6), ("uLow", 0.6), ("uMid", 0.4), ("uHigh", 0.3), ("uAir", 0.2), ("uOnset", 0.3),
    ("uHue", 0.92), ("uHue2", 0.55), ("uDropNear", 0.0), ("uBuild", 0.0), ("uHit", 0.0), ("uVocal", 0.0),
    ("uM1", 0.5), ("uM2", 0.5), ("uM3", 0.5), ("uM4", 0.5), ("uHitKick", 0.5), ("uHitSnare", 0.2),
    ("uHitTop", 0.3), ("uBeatDecay", 0.5), ("uBarDecay", 0.4), ("uBarSaw", 0.3), ("uPhraseSaw", 0.2),
    ("uDownbeat", 0.2), ("uExposure", 0.9), ("uBandLow", 0.6), ("uBandMid", 0.4), ("uBandHigh", 0.3), ("uBarIndex", 5.0),
];

fn value(name: &str) -> Option<f32> {
    COMMON.iter().find(|(n, _)| *n == name).map(|(_, v)| *v)
}

fn main() {
    let out = PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| "scene-shots".into()));
    std::fs::create_dir_all(&out).unwrap();
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../app/shaders/show");
    let gpu = Gpu::headless().expect("a GPU");
    println!("{} on {:?} ({})", gpu.info.name, gpu.info.backend, gpu.info.driver);
    let (w, h) = (640u32, 360u32);
    // a picture for the samplers: MilkDrop's frame, the scene's last
    let mut rgba = vec![0u8; (w * h * 4) as usize];
    for y in 0..h {
        for x in 0..w {
            let i = ((y * w + x) * 4) as usize;
            let r = ((x as f32 / w as f32) * 255.0) as u8;
            let g = ((y as f32 / h as f32) * 160.0) as u8;
            let rings = ((((x as f32 - 320.0).hypot(y as f32 - 180.0)) / 18.0).sin() * 0.5 + 0.5) * 255.0;
            rgba[i..i + 4].copy_from_slice(&[r, g, rings as u8, 255]);
        }
    }
    let picture = wo_render::upload(&gpu, w, h, &rgba);
    let picture_view = picture.create_view(&Default::default());
    let names = ["kinetic", "flash", "blocks", "glide", "drift", "milk", "pulse", "field"];
    let mut sheet = image::RgbaImage::new(w * 4, h * 2);
    for (k, name) in names.iter().enumerate() {
        let src = std::fs::read_to_string(dir.join(format!("{name}.frag"))).unwrap();
        let f = wo_render::wo_shaders::fit(name, &src).unwrap_or_else(|t| panic!("{t}"));
        // the floats by name; a pack's four from the common names in order
        let mut values = vec![];
        for fl in &f.floats {
            if fl.name == "uResolution" {
                values.extend([w as f32, h as f32]);
            } else if let Some(k) = fl.name.strip_prefix("uP").and_then(|n| n.parse::<usize>().ok()).filter(|_| fl.comps == 4) {
                values.extend((0..4).map(|c| COMMON[4 * k + c].1));
            } else {
                let v = value(&fl.name).unwrap_or(0.5);
                values.extend(std::iter::repeat_n(v, fl.comps as usize));
            }
        }
        let target = wo_render::target(&gpu, w, h);
        let view = target.create_view(&Default::default());
        let pass = Pass::new(&gpu, &f, wgpu::TextureFormat::Rgba8Unorm);
        let textures: Vec<&wgpu::TextureView> = f.samplers.iter().map(|_| &picture_view).collect();
        let mut enc = gpu.device.create_command_encoder(&Default::default());
        let t0 = std::time::Instant::now();
        pass.draw(&gpu, &mut enc, &view, &values, &textures);
        gpu.queue.submit([enc.finish()]);
        let px = wo_render::read(&gpu, &target);
        let img = image::RgbaImage::from_raw(w, h, px).unwrap();
        img.save(out.join(format!("{name}.png"))).unwrap();
        image::imageops::overlay(&mut sheet, &img, ((k % 4) as u32 * w) as i64, ((k / 4) as u32 * h) as i64);
        let mean: f64 = img.pixels().map(|p| (p[0] as f64 + p[1] as f64 + p[2] as f64) / 3.0).sum::<f64>() / (w * h) as f64;
        println!("{name}: {} floats, {} samplers, mean {:.1}, {:.1} ms", f.float_count(), f.samplers.len(), mean, t0.elapsed().as_secs_f32() * 1000.0);
    }
    sheet.save(out.join("sheet.png")).unwrap();
}
