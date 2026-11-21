//! A proxy's frames, each decoded as the stage decodes them, looked at for pure black
//! (a frame that decodes with blocks left out): WO_PROBE_PROXY=<proxy.wov>, run by hand.
#[test]
#[ignore]
fn a_proxy_s_frames_for_black_blocks() {
    let Ok(path) = std::env::var("WO_PROBE_PROXY") else { return };
    let mut p = wo_video::proxy::Proxy::open(std::path::Path::new(&path)).expect("a proxy");
    let n = p.frames();
    let (mut bad, mut failed) = (vec![], 0);
    for i in 0..n {
        match p.rgba(i) {
            Ok(pic) => {
                let px = pic.rgba.chunks_exact(4).count().max(1);
                let black = pic.rgba.chunks_exact(4).filter(|c| c[0] as u32 + c[1] as u32 + c[2] as u32 <= 3).count();
                let share = black as f64 / px as f64;
                if share > 0.02 {
                    bad.push((i, share));
                }
            }
            Err(_) => failed += 1,
        }
    }
    eprintln!("{n} frames: {failed} would not decode; {} with more than 2 % pure black", bad.len());
    // WO_PROBE_SHARE: the frames nearest that share of black first (else the blackest)
    let want: f64 = std::env::var("WO_PROBE_SHARE").ok().and_then(|v| v.parse().ok()).unwrap_or(2.0);
    bad.sort_by(|a, b| (a.1 - want).abs().total_cmp(&(b.1 - want).abs()));
    for (i, s) in bad.iter().take(6) {
        eprintln!("  frame {i}: {:.1} %", s * 100.0);
        if let Some(dir) = std::env::var_os("WO_SHOTS") {
            let pic = p.rgba(*i).unwrap();
            std::fs::create_dir_all(&dir).unwrap();
            image::RgbaImage::from_raw(pic.w, pic.h, pic.rgba).unwrap().save(std::path::Path::new(&dir).join(format!("frame{i}.png"))).unwrap();
        }
    }
}
