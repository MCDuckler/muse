//! The show's black hole, replayed: a cue line the Desk's watch logged (WO_PROBE_CUE: a
//! file holding the line, or the line itself) played on the stage headless for ten seconds
//! of a loud 128 BPM record, the share of pure black counted each second and the frames
//! kept (WO_SHOTS). Run by hand:
//!
//!   WO_PROBE_CUE=cue.txt WO_SHOTS=/tmp/h cargo test -p wo-type3d --test black_hole -- --ignored --nocapture
//!
//! (Here, beside the 3D text, which the stage feeds as wetowl-stage does.)
use std::path::PathBuf;

use wo_render::{Gpu, Stage};
use wo_show::deck::{Channel, RecordFacts, ShowAudio, ShowDeck};
use wo_show::engine::{Cue, Play, Room};
use wo_show::frame::stage_frame;
use wo_show::scenes::SceneBook;
use wo_show::state::ShowMix;

const W: u32 = 640;
const H: u32 = 360;

fn record() -> RecordFacts {
    let period = 60_000.0 / 128.0;
    let beats: Vec<f64> = (0..2048).map(|i| i as f64 * period).collect();
    RecordFacts {
        track_id: Some(42),
        steady: Some((0.0, period)),
        downbeats_ms: beats.iter().step_by(4).copied().collect(),
        beats_ms: beats,
        energy: vec![220; 512],
        camelot: Some("8A".into()),
        ..Default::default()
    }
}

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

/// Pure black (all three channels at most 1), of every pixel.
fn black_share(px: &[u8]) -> f64 {
    let n = px.len() / 4;
    px.chunks_exact(4).filter(|p| p[0] as u32 + p[1] as u32 + p[2] as u32 <= 3).count() as f64 / n.max(1) as f64
}

#[test]
#[ignore]
fn a_logged_cue_replayed() {
    let Ok(src) = std::env::var("WO_PROBE_CUE") else { return };
    let line = std::fs::read_to_string(&src).unwrap_or(src);
    let json = line.split("; cue ").last().unwrap_or(&line).trim();
    let mut j: serde_json::Value = serde_json::from_str(json).expect("a cue line");
    // WO_PROBE_GROUND: another ground (the probe has no video: "milk" is a bright stand-in)
    if let Ok(g) = std::env::var("WO_PROBE_GROUND")
        && let Some(k) = j.pointer_mut("/cue/rig/ground/kind")
    {
        *k = serde_json::Value::from(g);
    }
    // WO_PROBE_MIX: another way of blending (contrast, screen, add, normal)
    if let Ok(m) = std::env::var("WO_PROBE_MIX")
        && let Some(k) = j.pointer_mut("/cue/rig/blend/mix")
    {
        *k = serde_json::Value::from(m);
    }
    let cue = Cue::from_json(j.get("cue").unwrap_or(&j));
    let gpu = Gpu::headless().expect("a GPU");
    let book = SceneBook::shipped();
    let mut stage = Stage::new(&gpu, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    stage.milk = Some(milk_picture(&gpu));
    let target = wo_render::target(&gpu, W, H);
    let view = target.create_view(&Default::default());
    let shots = std::env::var_os("WO_SHOTS").map(PathBuf::from);
    if let Some(s) = &shots {
        std::fs::create_dir_all(s).unwrap();
    }
    let r = record();
    let mut play = Play::default();
    let mut type3d = wo_type3d::Type3dSim::default();
    let mut cam = wo_dance::clock::PictureCam::default();
    let frames: usize = std::env::var("WO_PROBE_SECONDS").ok().and_then(|s| s.parse::<usize>().ok()).unwrap_or(10) * 60;
    let mut worst = 0.0f64;
    for i in 0..frames {
        let t = i as f64 / 60.0;
        let kick = if (t * 1000.0) % 468.75 < 60.0 { 0.95 } else { 0.15 };
        let audio = ShowAudio { low: 0.6, mid: 0.4, high: 0.35, air: 0.2, kick, onset: kick * 0.5, ..Default::default() };
        let a = ShowDeck::derive("A", Some(&r), true, 30_000.0 + t * 1000.0, Channel::default(), audio);
        let b = ShowDeck::derive("B", None, false, 0.0, Channel::default(), ShowAudio::default());
        let room = Room { a, b, audio, mix: ShowMix::default() };
        let st = play.frame(1.0 / 60.0, room, &cue, true);
        let mut f = stage_frame(&st, &book, 10.0 + t);
        f.mosh_hold = play.mosh(&st);
        f.camera = cam.frame(&st, 1.0 / 60.0);
        // the 3D text, as wetowl-stage feeds it (type3d_frame)
        let typed = st.scene.as_deref().and_then(|s| book.scenes.get(s)).is_some_and(|s| s.layers.iter().any(|l| l.sim.as_deref() == Some("type3d")));
        if typed {
            let (ww, wh) = stage.work_size(W, H);
            let p = type3d.tick(&st, 1.0 / 60.0, ww as f64, wh as f64, f.blend.is_some());
            for (slot, field) in type3d.take_placed() {
                stage.type3d_field(&gpu, slot, field.w, field.h, &field.rgba);
            }
            stage.type3d = Some(p.flat());
        }
        let cmd = stage.draw(&gpu, &f, 1.0 / 60.0, Some(&view), W, H, None);
        gpu.queue.submit([cmd]);
        let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
        if i % 30 == 29 {
            let px = wo_render::read(&gpu, &target);
            let b = black_share(&px);
            worst = worst.max(b);
            eprintln!("t {t:5.2} s: {:5.1} % pure black · looks {:?}", b * 100.0, stage.drawn.looks);
            if let Some(s) = &shots {
                image::RgbaImage::from_raw(W, H, px).unwrap().save(s.join(format!("f{i:04}.png"))).unwrap();
            }
        }
    }
    eprintln!("the most pure black in a second: {:.1} %", worst * 100.0);
}
