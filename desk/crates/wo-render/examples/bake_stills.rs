//! The Desk's scene pages show each look by a still (v1: assets/show/stills, baked by the
//! Flutter stage for the dancers and each scene as drawn). The shader scenes in each image
//! treatment, and the dancers' viewports, drawn here by the Rust stage itself — the figure on
//! black, as the stage would put it on, a second into a loud bar — box-filtered to 256×144.
//!   cargo run --release -p wo-render --example bake_stills -- desk/apps/wetowl-desk/stills
use std::path::PathBuf;

use wo_dance::clock::{Art, Troupe};
use wo_dance::sim::{Company, DanceSim};
use wo_render::{Gpu, Stage};
use wo_show::combos::{Combo, styles_of_figure};
use wo_show::deck::{Channel, RecordFacts, ShowAudio, ShowDeck};
use wo_show::frame::stage_frame;
use wo_show::json::Named;
use wo_show::mosh::MoshClock;
use wo_show::scenes::SceneBook;
use wo_show::state::{Dynamics, Genome, ShowPalette, ShowState};

const W: u32 = 768;
const H: u32 = 432;
const OUT: (u32, u32) = (256, 144);

fn record() -> RecordFacts {
    let period = 60_000.0 / 128.0;
    let beats: Vec<f64> = (0..512).map(|i| i as f64 * period).collect();
    RecordFacts {
        track_id: Some(42),
        steady: Some((0.0, period)),
        downbeats_ms: beats.iter().step_by(4).copied().collect(),
        beats_ms: beats,
        energy: vec![200; 128],
        camelot: Some("8A".into()),
        cover_rgb: Some(0x3060c0),
        ..Default::default()
    }
}

fn state(scene: &str, t: f64, dyns: &mut Dynamics) -> ShowState {
    let r = record();
    let kick = if (t * 1000.0) % 468.75 < 60.0 { 0.95 } else { 0.15 };
    let audio = ShowAudio { low: 0.6, mid: 0.4, high: 0.35, air: 0.2, kick, onset: kick * 0.5, ..Default::default() };
    let a = ShowDeck::derive("A", Some(&r), true, 30_000.0 + t * 1000.0, Channel::default(), audio);
    let dyn_ = dyns.frame(&audio, &a, 1.0 / 60.0, true);
    ShowState { dt: 1.0 / 60.0, genome: Genome::of(42, Some("8A"), Some(128.0), Some(0x3060c0)), palette: ShowPalette::HOUSE, audio, a, scene: Some(scene.into()), dyn_, ..Default::default() }
}

/// RGBA box-filtered down to OUT.
fn small(rgba: &[u8], w: u32, h: u32) -> image::RgbaImage {
    let (sw, sh) = OUT;
    let (fx, fy) = (w / sw, h / sh);
    image::RgbaImage::from_fn(sw, sh, |x, y| {
        let mut acc = [0u32; 3];
        for yy in 0..fy {
            for xx in 0..fx {
                let i = (((y * fy + yy) * w + x * fx + xx) * 4) as usize;
                for c in 0..3 {
                    acc[c] += rgba[i + c] as u32;
                }
            }
        }
        let n = fx * fy;
        let [r, g, b] = acc.map(|a| ((a + n / 2) / n) as u8);
        image::Rgba([r, g, b, 255])
    })
}

fn main() {
    let out = PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| "stills".into()));
    std::fs::create_dir_all(&out).unwrap();
    let gpu = Gpu::headless().expect("a GPU");
    eprintln!("{} on {:?}", gpu.info.name, gpu.info.backend);
    let book = SceneBook::shipped();
    let looks = book.looks();
    let kinds = book.kinds();
    // (scene, style, file, the dancers' rendering)
    let mut jobs: Vec<(String, String, String, Option<Art>)> = vec![];
    for scene in ["kinetic", "flash", "blocks", "glide", "drift"] {
        let kind = kinds[scene];
        for style in styles_of_figure(kind).into_iter().filter(|s| *s != "raw") {
            jobs.push((scene.into(), style.into(), format!("{}.{style}.png", kind.name()), None));
        }
    }
    jobs.push(("dance-art".into(), "viewports".into(), "dancers.viewports.png".into(), Some(Art::Viewports)));
    let co = Company::load(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../app/assets/show/dance")).expect("the shipped dancers");
    for (scene, style, file, art) in jobs {
        let mut stage = Stage::new(&gpu, wgpu::TextureFormat::Rgba8Unorm).unwrap();
        let target = wo_render::target(&gpu, W, H);
        let view = target.create_view(&Default::default());
        let mut dyns = Dynamics::default();
        let mut mosh = MoshClock::new();
        let mut sim = art.map(|a| {
            stage.set_dancers(&gpu, &co);
            let mut sim = DanceSim::default();
            sim.forced_art = Some(a);
            sim.forced_troupe = Some(Troupe::Solo);
            sim
        });
        let combo = Combo::new("black", &scene, &style);
        for i in 0..60 {
            let t = i as f64 / 60.0;
            let mut st = state(&scene, t, &mut dyns);
            st.rig = looks[&scene].in_combo(Some(&combo));
            let mut f = stage_frame(&st, &book, 10.0 + t);
            f.mosh_hold = mosh.frame(&st, &st.rig.transform);
            if let Some(sim) = &mut sim {
                let (ww, wh) = stage.work_size(W, H);
                let sc = sim.frame(&co, &st, 1.0 / 60.0, ww as f64, wh as f64);
                stage.dance_cmds = sim.paint(&co, &sc, &st, 1.0 / 60.0);
            }
            let cmd = stage.draw(&gpu, &f, 1.0 / 60.0, Some(&view), W, H, None);
            gpu.queue.submit([cmd]);
            let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
        }
        let px = wo_render::read(&gpu, &target);
        let img = small(&px, W, H);
        let lit = img.pixels().map(|p| (p[0] as f64 + p[1] as f64 + p[2] as f64) / 3.0).sum::<f64>() / (OUT.0 * OUT.1) as f64;
        img.save(out.join(&file)).unwrap();
        eprintln!("{file}: mean light {lit:.1}");
    }
}
