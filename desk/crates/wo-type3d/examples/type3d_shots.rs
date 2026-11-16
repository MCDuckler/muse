//! The 3D text through the whole Rust stage, headless: each look (its own frame, a few
//! seconds into a loud bar), on black and over MilkDrop-like ground (glass bends it), one sheet.
//!   cargo run --release -p wo-type3d --example type3d_shots -- <out dir> [WxH] [font] [text]
use std::path::PathBuf;

use wo_render::{Gpu, Stage};
use wo_show::deck::{Channel, RecordFacts, ShowAudio, ShowDeck};
use wo_show::frame::stage_frame;
use wo_show::scenes::SceneBook;
use wo_show::state::{Dynamics, ShowMacros, ShowPalette, ShowState};
use wo_show::type3d::{TypeFont, TypeLook, TypeSpec};
use wo_type3d::Type3dSim;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let out = PathBuf::from(args.first().cloned().unwrap_or_else(|| "type3d-shots".into()));
    std::fs::create_dir_all(&out).unwrap();
    let (w, h) = args.get(1).and_then(|s| s.split_once('x')).map(|(a, b)| (a.parse().unwrap(), b.parse().unwrap())).unwrap_or((960u32, 540u32));
    let font = args.get(2).and_then(|f| TypeFont::by_name(f)).unwrap_or(TypeFont::Bebas);
    let text = args.get(3).cloned().unwrap_or_else(|| "WETOWL".into());
    let gpu = Gpu::headless().expect("a GPU");
    eprintln!("{} on {:?}", gpu.info.name, gpu.info.backend);
    let book = SceneBook::shipped();
    let period = 60_000.0 / 128.0;
    let beats: Vec<f64> = (0..1024).map(|i| i as f64 * period).collect();
    let r = RecordFacts {
        track_id: Some(4242),
        title: Some("Night Drive".into()),
        artist: Some("Wet Owl".into()),
        steady: Some((0.0, period)),
        downbeats_ms: beats.iter().step_by(4).copied().collect(),
        beats_ms: beats,
        energy: vec![210; 256],
        camelot: Some("8A".into()),
        ..Default::default()
    };
    let target = wo_render::target(&gpu, w, h);
    let view = target.create_view(&Default::default());
    let looks = TypeLook::ALL;
    let cols = 4u32;
    let rows = (looks.len() as u32).div_ceil(cols);
    let mut sheet = image::RgbaImage::new(w / 2 * cols, h / 2 * rows);
    for (n, look) in looks.iter().enumerate() {
        let mut stage = Stage::new(&gpu, wgpu::TextureFormat::Rgba8Unorm).unwrap();
        assert!(stage.has_type3d(), "the 3D text's pass");
        let mut sim = Type3dSim::default();
        sim.at_once = true;
        let spec = TypeSpec { lines: vec![text.clone()], font, looks: vec![*look], ..Default::default() };
        let mut dyns = Dynamics::default();
        let frames = 120;
        let mut took = 0.0;
        for i in 0..frames {
            let t = i as f64 / 60.0 + n as f64 * 0.37;
            let kick = if (t * 1000.0) % period < 60.0 { 0.95 } else { 0.15 };
            let audio = ShowAudio { low: 0.6, mid: 0.4, high: 0.35, air: 0.2, kick, onset: kick * 0.5, ..Default::default() };
            let a = ShowDeck::derive("A", Some(&r), true, 60_000.0 + t * 1000.0, Channel::default(), audio);
            let dyn_ = dyns.frame(&audio, &a, 1.0 / 60.0, true);
            let mut st = ShowState { dt: 1.0 / 60.0, palette: ShowPalette::HOUSE, audio, a, scene: Some("type3d".into()), dyn_, ..Default::default() };
            st.macros = ShowMacros { type3d: Some(spec.clone()), ..Default::default() };
            st.rig = book.scenes["type3d"].rig();
            // glass over a ground (the wash), so it has something to bend
            if *look == TypeLook::Glass {
                st.rig.ground.kind = wo_show::rig::Ground::Pulse;
                st.rig.blend.mix = wo_show::combos::Mix::Normal;
                st.rig.blend.strength = 1.0;
            }
            let f = stage_frame(&st, &book, 10.0 + t);
            let (ww, wh) = stage.work_size(w, h);
            let p = sim.tick(&st, 1.0 / 60.0, ww as f64, wh as f64, f.blend.is_some());
            for (slot, fld) in sim.take_placed() {
                stage.type3d_field(&gpu, slot, fld.w, fld.h, &fld.rgba);
            }
            stage.type3d = Some(p.flat());
            let t0 = std::time::Instant::now();
            let cmd = stage.draw(&gpu, &f, 1.0 / 60.0, Some(&view), w, h, None);
            gpu.queue.submit([cmd]);
            let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
            if i >= frames - 30 {
                took += t0.elapsed().as_secs_f64() * 1000.0 / 30.0;
            }
        }
        let px = wo_render::read(&gpu, &target);
        let img = image::RgbaImage::from_raw(w, h, px).unwrap();
        let lit = img.pixels().filter(|p| p[0] as u32 + p[1] as u32 + p[2] as u32 > 60).count() as f64 / (w * h) as f64;
        eprintln!("{}: {:.1} ms a frame, {:.0} % lit, bends {:?}", look.name(), took, lit * 100.0, sim.bends());
        img.save(out.join(format!("{}.png", look.name()))).unwrap();
        let small = image::imageops::resize(&img, w / 2, h / 2, image::imageops::FilterType::Triangle);
        image::imageops::overlay(&mut sheet, &small, ((n as u32 % cols) * w / 2) as i64, ((n as u32 / cols) * h / 2) as i64);
    }
    sheet.save(out.join("sheet.png")).unwrap();
    eprintln!("{}", out.join("sheet.png").display());
}
