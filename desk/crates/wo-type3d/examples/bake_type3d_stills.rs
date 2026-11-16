//! The 3D text's stills for the Desk's scene page (as wo-render's bake_stills does for the
//! shader scenes): the text as drawn and in each image treatment, on black, a second and a
//! half into a loud bar, box-filtered to 256×144.
//!   cargo run --release -p wo-type3d --example bake_type3d_stills -- desk/apps/wetowl-desk/stills
use std::path::PathBuf;

use wo_render::{Gpu, Stage};
use wo_show::combos::{Combo, styles_of_figure};
use wo_show::deck::{Channel, RecordFacts, ShowAudio, ShowDeck};
use wo_show::frame::stage_frame;
use wo_show::json::Named;
use wo_show::scenes::SceneBook;
use wo_show::state::{Dynamics, Genome, ShowMacros, ShowPalette, ShowState};
use wo_show::type3d::{TypeLook, TypeMotion, TypeSpec};
use wo_type3d::Type3dSim;

const W: u32 = 768;
const H: u32 = 432;
const OUT: (u32, u32) = (256, 144);

fn small(rgba: &[u8]) -> image::RgbaImage {
    let (sw, sh) = OUT;
    let (fx, fy) = (W / sw, H / sh);
    image::RgbaImage::from_fn(sw, sh, |x, y| {
        let mut acc = [0u32; 3];
        for yy in 0..fy {
            for xx in 0..fx {
                let i = (((y * fy + yy) * W + x * fx + xx) * 4) as usize;
                for (c, a) in acc.iter_mut().enumerate() {
                    *a += rgba[i + c] as u32;
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
    let kind = book.kinds()["type3d"];
    let period = 60_000.0 / 128.0;
    let beats: Vec<f64> = (0..512).map(|i| i as f64 * period).collect();
    let r = RecordFacts {
        track_id: Some(42),
        steady: Some((0.0, period)),
        downbeats_ms: beats.iter().step_by(4).copied().collect(),
        beats_ms: beats,
        energy: vec![200; 128],
        camelot: Some("8A".into()),
        cover_rgb: Some(0x3060c0),
        ..Default::default()
    };
    // a still is one look: the chrome letters, facing a little turned
    let spec = TypeSpec { looks: vec![TypeLook::Chrome], motions: vec![TypeMotion::Wave], deforms: vec![], ..Default::default() };
    for style in styles_of_figure(kind) {
        let file = if style == "raw" { format!("{}.png", kind.name()) } else { format!("{}.{style}.png", kind.name()) };
        let mut stage = Stage::new(&gpu, wgpu::TextureFormat::Rgba8Unorm).unwrap();
        let target = wo_render::target(&gpu, W, H);
        let view = target.create_view(&Default::default());
        let mut dyns = Dynamics::default();
        let mut sim = Type3dSim::default();
        sim.at_once = true;
        let combo = Combo::new("black", "type3d", style);
        for i in 0..90 {
            let t = i as f64 / 60.0;
            let kick = if (t * 1000.0) % period < 60.0 { 0.95 } else { 0.15 };
            let audio = ShowAudio { low: 0.6, mid: 0.4, high: 0.35, air: 0.2, kick, onset: kick * 0.5, ..Default::default() };
            let a = ShowDeck::derive("A", Some(&r), true, 30_000.0 + t * 1000.0, Channel::default(), audio);
            let dyn_ = dyns.frame(&audio, &a, 1.0 / 60.0, true);
            let mut st = ShowState { dt: 1.0 / 60.0, genome: Genome::of(42, Some("8A"), Some(128.0), Some(0x3060c0)), palette: ShowPalette::HOUSE, audio, a, scene: Some("type3d".into()), dyn_, ..Default::default() };
            st.macros = ShowMacros { type3d: Some(spec.clone()), ..Default::default() };
            st.rig = looks["type3d"].in_combo(Some(&combo));
            let f = stage_frame(&st, &book, 10.0 + t);
            let (ww, wh) = stage.work_size(W, H);
            let p = sim.tick(&st, 1.0 / 60.0, ww as f64, wh as f64, f.blend.is_some());
            for (slot, fld) in sim.take_placed() {
                stage.type3d_field(&gpu, slot, fld.w, fld.h, &fld.rgba);
            }
            stage.type3d = Some(p.flat());
            let cmd = stage.draw(&gpu, &f, 1.0 / 60.0, Some(&view), W, H, None);
            gpu.queue.submit([cmd]);
            let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
        }
        let img = small(&wo_render::read(&gpu, &target));
        let lit = img.pixels().map(|p| (p[0] as f64 + p[1] as f64 + p[2] as f64) / 3.0).sum::<f64>() / (OUT.0 * OUT.1) as f64;
        img.save(out.join(&file)).unwrap();
        eprintln!("{file}: mean light {lit:.1}");
    }
}
