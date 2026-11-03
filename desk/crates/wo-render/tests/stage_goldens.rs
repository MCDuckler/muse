//! The stage's whole frame (wo_render::Stage) for every scene it draws and the ways a look
//! puts a figure on a ground, drawn headless on this machine's GPU and held against goldens
//! (tests/goldens/*.png): box-filtered to 160×90, so the grain and a GPU's last bit of
//! rounding do not count, a changed picture does.
//!
//!   cargo test -p wo-render --test stage_goldens            check
//!   WO_GOLDENS=write cargo test -p wo-render --test stage_goldens   write them anew
//!   WO_SHOTS=<dir>   the full-size frames as well
//!
//! With no GPU at all the test says so and passes, unless WO_NEED_GPU is set (CI).
use std::path::PathBuf;

use wo_render::{Gpu, Stage};
use wo_show::combos::{Mask, Mix};
use wo_show::deck::{Channel, RecordFacts, ShowAudio, ShowDeck};
use wo_show::frame::stage_frame;
use wo_show::rig::{Ground, RigBlend, RigGround};
use wo_show::scenes::{DRAWN, SceneBook};
use wo_show::state::{Dynamics, Genome, ShowMacros, ShowPalette, ShowState};

const W: u32 = 640;
const H: u32 = 360;
const SMALL: (u32, u32) = (160, 90);

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

/// The show at `t` seconds into a loud bar of a 128 BPM record, `scene` on.
fn state(scene: &str, t: f64, dyns: &mut Dynamics) -> ShowState {
    let r = record();
    let kick = if (t * 1000.0) % 468.75 < 60.0 { 0.95 } else { 0.15 };
    let audio = ShowAudio { low: 0.6, mid: 0.4, high: 0.35, air: 0.2, kick, onset: kick * 0.5, ..Default::default() };
    let a = ShowDeck::derive("A", Some(&r), true, 30_000.0 + t * 1000.0, Channel::default(), audio);
    let dyn_ = dyns.frame(&audio, &a, 1.0 / 60.0, true);
    ShowState {
        genome: Genome::of(42, Some("8A"), Some(128.0), Some(0x3060c0)),
        palette: ShowPalette::HOUSE,
        audio,
        a,
        scene: Some(scene.into()),
        dyn_,
        ..Default::default()
    }
}

struct Case {
    name: String,
    scene: &'static str,
    edit: fn(&mut ShowState, &SceneBook),
}

fn cases() -> Vec<Case> {
    let mut v: Vec<Case> = DRAWN.iter().map(|s| Case { name: (*s).into(), scene: s, edit: |_, _| {} }).collect();
    fn rig(st: &mut ShowState, b: &SceneBook, ground: RigGround, blend: RigBlend) {
        let mut r = b.scenes[st.scene.as_deref().unwrap()].rig();
        r.ground = ground;
        r.blend = blend;
        st.rig = r;
    }
    v.push(Case {
        name: "glide-on-drift-keyhole-screen".into(),
        scene: "glide",
        edit: |st, b| rig(st, b, RigGround { kind: Ground::Field, field: Some("drift".into()), dim: 0.8, knobs: vec![] }, RigBlend { mask: Mask::Keyhole, mix: Mix::Screen, strength: 1.0 }),
    });
    v.push(Case {
        name: "glide-on-milk-inverted-screen".into(),
        scene: "glide",
        edit: |st, b| rig(st, b, RigGround { kind: Ground::Milk, ..Default::default() }, RigBlend { mask: Mask::Inverted, mix: Mix::Screen, strength: 1.0 }),
    });
    v.push(Case {
        name: "blocks-on-wash-add".into(),
        scene: "blocks",
        edit: |st, b| rig(st, b, RigGround { kind: Ground::Wash, ..Default::default() }, RigBlend { mask: Mask::None, mix: Mix::Add, strength: 1.0 }),
    });
    v.push(Case {
        name: "flash-on-pulse-rays-contrast".into(),
        scene: "flash",
        edit: |st, b| rig(st, b, RigGround { kind: Ground::Pulse, field: Some("rays".into()), dim: 1.0, knobs: vec![] }, RigBlend { mask: Mask::Inverted, mix: Mix::Contrast, strength: 0.9 }),
    });
    v.push(Case {
        name: "kinetic-from-drift-half".into(),
        scene: "kinetic",
        edit: |st, _| {
            st.scene_from = Some("drift".into());
            st.scene_k = 0.5;
        },
    });
    v.push(Case {
        name: "blocks-strobe".into(),
        scene: "blocks",
        edit: |st, _| {
            st.macros = ShowMacros { strobe: 0.6, ..Default::default() };
            st.a.beat_phase = 0.1;
        },
    });
    v
}

/// A stand-in for MilkDrop's frame: rings of colour on a gradient.
fn milk_picture(gpu: &Gpu) -> wgpu::TextureView {
    let (w, h) = (960u32, 540u32);
    let mut rgba = vec![0u8; (w * h * 4) as usize];
    for y in 0..h {
        for x in 0..w {
            let i = ((y * w + x) * 4) as usize;
            let d = ((x as f32 - 480.0).hypot(y as f32 - 270.0) / 22.0).sin() * 0.5 + 0.5;
            rgba[i..i + 4].copy_from_slice(&[(255.0 * d) as u8, (x * 200 / w) as u8, (y * 255 / h) as u8, 255]);
        }
    }
    wo_render::upload(gpu, w, h, &rgba).create_view(&Default::default())
}

/// RGBA → RGB box-filtered down to SMALL.
fn small(rgba: &[u8], w: u32, h: u32) -> image::RgbImage {
    let (sw, sh) = SMALL;
    let (fx, fy) = (w / sw, h / sh);
    image::RgbImage::from_fn(sw, sh, |x, y| {
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
        image::Rgb(acc.map(|a| ((a + n / 2) / n) as u8))
    })
}

#[test]
fn every_scene_and_way_of_blending_draws_as_its_golden() {
    let gpu = match Gpu::headless() {
        Ok(g) => g,
        Err(e) if std::env::var_os("WO_NEED_GPU").is_none() => {
            eprintln!("no GPU here ({e}): the goldens not checked");
            return;
        }
        Err(e) => panic!("{e}"),
    };
    eprintln!("{} on {:?}", gpu.info.name, gpu.info.backend);
    let book = SceneBook::shipped();
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/goldens");
    let write = std::env::var("WO_GOLDENS").is_ok_and(|v| v == "write");
    let shots = std::env::var_os("WO_SHOTS").map(PathBuf::from);
    if let Some(s) = &shots {
        std::fs::create_dir_all(s).unwrap();
    }
    let mut bad = vec![];
    for case in cases() {
        let mut stage = Stage::new(&gpu, wgpu::TextureFormat::Rgba8Unorm).unwrap();
        // MilkDrop's picture as it comes up its pipe (960×540 RGBA): a fixed stand-in
        stage.milk = Some(milk_picture(&gpu));
        let target = wo_render::target(&gpu, W, H);
        let view = target.create_view(&Default::default());
        let mut dyns = Dynamics::default();
        // a second of frames: the trails and the particles settle as they would
        let frames = 60;
        for i in 0..frames {
            let t = i as f64 / 60.0;
            let mut st = state(case.scene, t, &mut dyns);
            (case.edit)(&mut st, &book);
            let f = stage_frame(&st, &book, 10.0 + t);
            let cmd = stage.draw(&gpu, &f, 1.0 / 60.0, Some(&view), W, H, None);
            gpu.queue.submit([cmd]);
            assert_eq!(stage.drawn.missing, None, "{}", case.name);
        }
        let px = wo_render::read(&gpu, &target);
        if let Some(s) = &shots {
            image::RgbaImage::from_raw(W, H, px.clone()).unwrap().save(s.join(format!("{}.png", case.name))).unwrap();
        }
        let got = small(&px, W, H);
        let file = dir.join(format!("{}.png", case.name));
        if write {
            std::fs::create_dir_all(&dir).unwrap();
            got.save(&file).unwrap();
            continue;
        }
        let Ok(want) = image::open(&file).map(|i| i.to_rgb8()) else {
            bad.push(format!("{}: no golden (WO_GOLDENS=write)", case.name));
            continue;
        };
        let diffs: Vec<u8> = got.as_raw().iter().zip(want.as_raw()).map(|(a, b)| a.abs_diff(*b)).collect();
        let mean = diffs.iter().map(|&d| d as f64).sum::<f64>() / diffs.len() as f64;
        let far = diffs.iter().filter(|&&d| d > 24).count() as f64 / diffs.len() as f64;
        let lit = got.as_raw().iter().map(|&v| v as f64).sum::<f64>() / diffs.len() as f64;
        eprintln!("{}: mean light {lit:.1}, differs by {mean:.2} on average, {:.2}% far", case.name, far * 100.0);
        if mean > 3.0 || far > 0.01 {
            bad.push(format!("{}: differs by {mean:.2} on average, {:.2}% of it far", case.name, far * 100.0));
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}
