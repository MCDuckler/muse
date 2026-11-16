//! The footage through the whole Rust stage, headless: the first clip of a library as the
//! scene (filled, whole, over itself blurred; as it is, the palette's, sepia, grey; through
//! the treatments) and as the ground under kinetic (normal, contrast), one sheet — and each
//! mode's frames over two bars, to see the beat move the clip.
//!   cargo run --release -p wo-video --example video_shots -- <out dir> [sources proxies [clip]]
use std::path::PathBuf;

use wo_render::video::{VideoDraw, VideoLook};
use wo_render::{Gpu, Stage};
use wo_show::combos::Mix;
use wo_show::deck::{Channel, RecordFacts, Section, ShowAudio, ShowDeck};
use wo_show::frame::stage_frame;
use wo_show::json::Named;
use wo_show::rig::{Ground, Treatment};
use wo_show::scenes::SceneBook;
use wo_show::state::{Dynamics, ShowMacros, ShowPalette, ShowState};
use wo_show::video::{VideoChange, VideoCue, VideoFit, VideoMode, VideoSpec, VideoTint};
use wo_video::{Feed, Library};

struct Case {
    name: &'static str,
    scene: &'static str,
    spec: VideoSpec,
    ground: bool,
    mix: Mix,
    treatment: Treatment,
}

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let out = PathBuf::from(a.first().cloned().unwrap_or_else(|| "video-shots".into()));
    std::fs::create_dir_all(&out).unwrap();
    let lib = match (a.get(1), a.get(2)) {
        (Some(s), Some(p)) => Library::at(s.as_ref(), p.as_ref()),
        _ => Library::here().expect("a home"),
    };
    let clips = lib.clips();
    // the clip named (a part of its name), else the first
    let clip = a.get(3).and_then(|n| clips.iter().find(|c| c.name.to_lowercase().contains(&n.to_lowercase()))).or(clips.first()).expect("a clip made (import_dir)").clone();
    eprintln!("{} ({}×{}, {:.1} s, busy {:.2}, colour {:.2})", clip.name, clip.w, clip.h, clip.secs, clip.busy(), clip.colour);
    let (w, h) = (960u32, 540u32);
    let gpu = Gpu::headless().expect("a GPU");
    eprintln!("{} on {:?}", gpu.info.name, gpu.info.backend);
    let book = SceneBook::shipped();
    let period = 60_000.0 / 124.0;
    let beats: Vec<f64> = (0..2048).map(|i| i as f64 * period).collect();
    let bar = 4.0 * period;
    let r = RecordFacts {
        track_id: Some(77),
        steady: Some((0.0, period)),
        downbeats_ms: beats.iter().step_by(4).copied().collect(),
        beats_ms: beats,
        energy: vec![200; 512],
        sections: vec![Section { label: "build".into(), start_ms: 0.0, end_ms: 32.0 * bar }, Section { label: "drop".into(), start_ms: 32.0 * bar, end_ms: 64.0 * bar }, Section { label: "breakdown".into(), start_ms: 64.0 * bar, end_ms: 96.0 * bar }],
        camelot: Some("5A".into()),
        ..Default::default()
    };
    let spec = |f: fn(&mut VideoSpec)| {
        let mut s = VideoSpec::default();
        f(&mut s);
        s
    };
    let plain = |name, spec| Case { name, scene: "video", spec, ground: false, mix: Mix::Normal, treatment: Treatment::Auto };
    let cases = vec![
        plain("fill", spec(|_| {})),
        plain("fit", spec(|s| s.fit = VideoFit::Fit)),
        plain("blur", spec(|s| s.fit = VideoFit::Blur)),
        plain("as-is", spec(|s| s.tint = VideoTint::Off)),
        plain("duotone", spec(|s| s.tint = VideoTint::Duotone)),
        plain("sepia", spec(|s| s.tint = VideoTint::Sepia)),
        plain("mono-mirror", spec(|s| {
            s.tint = VideoTint::Mono;
            s.mirror = true;
            s.contrast = 1.4;
        })),
        Case { treatment: Treatment::Halftone, ..plain("halftone", spec(|_| {})) },
        Case { treatment: Treatment::Ascii, ..plain("ascii", spec(|_| {})) },
        Case { treatment: Treatment::Thermal, ..plain("thermal", spec(|_| {})) },
        Case { scene: "kinetic", ground: true, ..plain("under-kinetic", spec(|_| {})) },
        Case { scene: "kinetic", ground: true, mix: Mix::Contrast, ..plain("under-kinetic-contrast", spec(|_| {})) },
    ];
    let cols = 4u32;
    let rows = (cases.len() as u32).div_ceil(cols);
    let mut sheet = image::RgbaImage::new(w / 2 * cols, h / 2 * rows);
    for (n, c) in cases.iter().enumerate() {
        let (img, took) = render(&gpu, &book, &lib, &clip, &r, c, n, w, h);
        let mean = img.pixels().map(|p| p[0] as f64 + p[1] as f64 + p[2] as f64).sum::<f64>() / (3.0 * (w * h) as f64);
        eprintln!("{}: {:.2} ms a frame, mean {:.0}", c.name, took, mean);
        img.save(out.join(format!("{}.png", c.name))).unwrap();
        let small = image::imageops::resize(&img, w / 2, h / 2, image::imageops::FilterType::Triangle);
        image::imageops::overlay(&mut sheet, &small, ((n as u32 % cols) * w / 2) as i64, ((n as u32 / cols) * h / 2) as i64);
    }
    // the Desk's stills: the scene as drawn, through each treatment, and as a background
    if a.iter().any(|x| x == "--stills") {
        let dir = out.join("stills");
        std::fs::create_dir_all(&dir).unwrap();
        let still = |name: String, c: &Case| {
            let (img, _) = render(&gpu, &book, &lib, &clip, &r, c, 3, 512, 288);
            image::imageops::resize(&img, 256, 144, image::imageops::FilterType::Lanczos3).save(dir.join(format!("{name}.png"))).unwrap();
        };
        still("video".into(), &plain("video", spec(|_| {})));
        still("ground.video".into(), &plain("ground", spec(|s| s.tint = VideoTint::Off)));
        for t in wo_show::combos::TREATMENT_STYLES {
            let tr = Treatment::by_name(t).unwrap();
            still(format!("video.{t}"), &Case { treatment: tr, ..plain("t", spec(|_| {})) });
        }
        eprintln!("stills in {}", dir.display());
    }
    sheet.save(out.join("sheet.png")).unwrap();
    // each mode's frames, a sixteenth of a beat apart over two bars, in the build, the drop
    // and the breakdown
    for (sec, at_bar) in [("build", 28.0), ("drop", 34.0), ("breakdown", 66.0)] {
        for mode in VideoMode::ALL {
            let mut clock = wo_show::video::VideoClock::default();
            let cue = VideoCue { clip: clip.id.clone(), n: 1, how: VideoChange::Cut, spec: VideoSpec { mode: *mode, ..Default::default() } };
            let mut line = vec![];
            for i in 0..32 {
                let t = at_bar * bar + i as f64 * period / 4.0;
                let a = ShowDeck::derive("A", Some(&r), true, t, Channel::default(), ShowAudio::default());
                let st = ShowState { a, ..Default::default() };
                line.push(clock.tick(&cue, &clip, &st, period / 4000.0).frame);
            }
            println!("{sec:>9} {:>7}: {:?}", mode.name(), line);
        }
    }
    eprintln!("{}", out.join("sheet.png").display());
}

#[allow(clippy::too_many_arguments)]
fn render(gpu: &Gpu, book: &SceneBook, lib: &Library, clip: &wo_show::video::ClipMeta, r: &RecordFacts, c: &Case, n: usize, w: u32, h: u32) -> (image::RgbaImage, f64) {
    let period = 60_000.0 / 124.0;
    let bar = 4.0 * period;
    let target = wo_render::target(gpu, w, h);
    let view = target.create_view(&Default::default());
    let mut stage = Stage::new(gpu, wgpu::TextureFormat::Rgba8Unorm).unwrap();
    let mut feed = Feed::at_once(Some(lib.clone()));
    let mut dyns = Dynamics::default();
    let cue = VideoCue { clip: clip.id.clone(), n: 1, how: VideoChange::Cut, spec: c.spec.clone() };
    let frames = 90;
    let mut took = 0.0;
    for i in 0..frames {
        // in the drop, a little after its start
        let t = 34.0 * bar / 1000.0 + i as f64 / 60.0 + n as f64 * 0.41;
        let kick = if (t * 1000.0) % period < 70.0 { 0.95 } else { 0.1 };
        let audio = ShowAudio { low: 0.6, mid: 0.4, high: 0.3, air: 0.2, kick, onset: kick * 0.5, ..Default::default() };
        let a = ShowDeck::derive("A", Some(r), true, t * 1000.0, Channel::default(), audio);
        let dyn_ = dyns.frame(&audio, &a, 1.0 / 60.0, true);
        let mut st = ShowState { dt: 1.0 / 60.0, palette: ShowPalette::HOUSE, audio, a, scene: Some(c.scene.into()), dyn_, ..Default::default() };
        st.macros = ShowMacros { video: Some(cue.clone()), ..Default::default() };
        st.rig = book.scenes[c.scene].rig();
        st.rig.figure.treatment = c.treatment;
        if c.ground {
            st.rig.ground.kind = Ground::Video;
            st.rig.ground.dim = 0.8;
            st.rig.blend.mix = c.mix;
            st.rig.blend.strength = 1.0;
        }
        let f = stage_frame(&st, book, 10.0 + t);
        let figure = f.figure.is_none() && c.scene == "video";
        stage.video = feed.frame(st.macros.video.as_ref(), &st, 1.0 / 60.0).map(|ff| {
            if let Some(p) = &ff.upload {
                stage.video_frame(gpu, ff.slot, p.w, p.h, &p.rgba);
            }
            let [ink, mid, paper] = wo_render::video::tones(&f.palette);
            VideoDraw {
                slot: ff.slot,
                figure,
                look: VideoLook { aspect: ff.aspect, k: ff.k, fit: ff.fit, tint: ff.tint, dim: ff.dim, contrast: ff.contrast, saturation: ff.saturation, punch: ff.punch, film: ff.film, mirror: ff.mirror, ink, mid, paper },
            }
        });
        assert!(stage.video.is_some(), "the clip is found");
        let t0 = std::time::Instant::now();
        let cmd = stage.draw(gpu, &f, 1.0 / 60.0, Some(&view), w, h, None);
        gpu.queue.submit([cmd]);
        let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
        if i >= frames - 30 {
            took += t0.elapsed().as_secs_f64() * 1000.0 / 30.0;
        }
    }
    let px = wo_render::read(gpu, &target);
    (image::RgbaImage::from_raw(w, h, px).unwrap(), took)
}
