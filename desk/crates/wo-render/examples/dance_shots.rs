//! The dancer scene in every rendering, drawn by the whole stage (wo_render::Stage, the
//! dancers' painter's commands as its figure) after a few seconds of a made-up record, each a
//! PNG and a contact sheet of them.
//!   cargo run --release -p wo-render --example dance_shots -- <out dir> [WxH] [troupe] [shot]
use std::path::PathBuf;

use wo_dance::clock::{Art, Shot, Troupe};
use wo_dance::sim::{Company, DanceSim};
use wo_render::{Gpu, Stage};
use wo_show::deck::{Channel, RecordFacts, ShowAudio, ShowDeck};
use wo_show::frame::stage_frame;
use wo_show::scenes::SceneBook;
use wo_show::state::{Dynamics, ShowPalette, ShowState};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let out = PathBuf::from(args.first().cloned().unwrap_or_else(|| "dance-shots".into()));
    std::fs::create_dir_all(&out).unwrap();
    let (w, h) = args.get(1).and_then(|s| s.split_once('x')).map(|(a, b)| (a.parse().unwrap(), b.parse().unwrap())).unwrap_or((960u32, 540u32));
    let troupe = args.get(2).and_then(|t| Troupe::by_name(t));
    let shot = args.get(3).and_then(|t| Shot::by_name(t));
    let gpu = Gpu::headless().expect("a GPU");
    eprintln!("{} on {:?}", gpu.info.name, gpu.info.backend);
    let co = Company::load(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/dance")).expect("the dancers");
    let book = SceneBook::shipped();
    let period = 60_000.0 / 124.0;
    let beats: Vec<f64> = (0..1024).map(|i| i as f64 * period).collect();
    let r = RecordFacts {
        track_id: Some(4242),
        steady: Some((0.0, period)),
        downbeats_ms: beats.iter().step_by(4).copied().collect(),
        beats_ms: beats,
        energy: vec![210; 256],
        camelot: Some("8A".into()),
        ..Default::default()
    };
    let target = wo_render::target(&gpu, w, h);
    let view = target.create_view(&Default::default());
    let mut sheet = image::RgbaImage::new(w / 2 * 4, h / 2 * 4);
    let arts: Vec<Art> = Art::ALL.iter().copied().filter(|a| a.drawn()).collect();
    for (n, art) in arts.iter().enumerate() {
        let mut stage = Stage::new(&gpu, wgpu::TextureFormat::Rgba8Unorm).unwrap();
        stage.set_dancers(&gpu, &co);
        let mut sim = DanceSim::default();
        sim.forced_art = Some(*art);
        sim.forced_troupe = troupe;
        sim.forced_shot = shot;
        let mut dyns = Dynamics::default();
        let frames = 150;
        for i in 0..frames {
            let t = i as f64 / 60.0;
            let kick = if (t * 1000.0) % period < 60.0 { 0.95 } else { 0.15 };
            let audio = ShowAudio { low: 0.6, mid: 0.4, high: 0.35, air: 0.2, kick, onset: kick * 0.5, ..Default::default() };
            let a = ShowDeck::derive("A", Some(&r), true, 60_000.0 + t * 1000.0, Channel::default(), audio);
            let dyn_ = dyns.frame(&audio, &a, 1.0 / 60.0, true);
            let mut st = ShowState { dt: 1.0 / 60.0, palette: ShowPalette::HOUSE, audio, a, scene: Some("dance-art".into()), dyn_, ..Default::default() };
            st.rig = book.scenes["dance-art"].rig();
            let (ww, wh) = stage.work_size(w, h);
            let scene = sim.frame(&co, &st, 1.0 / 60.0, ww as f64, wh as f64);
            stage.dance_cmds = sim.paint(&co, &scene, &st, 1.0 / 60.0);
            let f = stage_frame(&st, &book, 10.0 + t);
            let cmd = stage.draw(&gpu, &f, 1.0 / 60.0, Some(&view), w, h, None);
            gpu.queue.submit([cmd]);
            let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
            if i + 1 == frames {
                eprintln!("{}: {} bodies drawn, troupe {:?}, shot {:?}", art.name(), stage.dance.as_ref().unwrap().bodies, scene.troupe, scene.shot);
            }
        }
        let px = wo_render::read(&gpu, &target);
        let img = image::RgbaImage::from_raw(w, h, px).unwrap();
        img.save(out.join(format!("{}.png", art.name()))).unwrap();
        let small = image::imageops::resize(&img, w / 2, h / 2, image::imageops::FilterType::Triangle);
        image::imageops::overlay(&mut sheet, &small, ((n % 4) as u32 * w / 2) as i64, ((n / 4) as u32 * h / 2) as i64);
    }
    sheet.save(out.join("sheet.png")).unwrap();
    eprintln!("{}", out.join("sheet.png").display());
}
