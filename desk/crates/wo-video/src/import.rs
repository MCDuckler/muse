//! A clip made into a proxy, once (ffmpeg, beside the Desk or on the PATH):
//!
//! 1. ffprobe: its size, its rate, its length;
//! 2. the black bars burnt into it found (old 4:3 film in a 16:9 file) and cut off;
//! 3. deinterlaced where it says it is interlaced, made 540 high at most (square pixels),
//!    30 frames a second at most, without its sound, every frame a JPEG → `proxy.wov`;
//! 4. each second's light and motion and the colour in it read off the proxy (clip.json),
//!    the part worth showing (the black leader and tail left out), a poster frame.
//!
//! Written into `<id>.part/` and renamed when whole, so a half-made clip is never shown.
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

use wo_show::video::ClipMeta;

use crate::proxy::{JpegSplitter, Proxy, ProxyWriter};

/// The proxies' height at most.
pub const HEIGHT: u32 = 540;
/// Their rate at most.
pub const MAX_FPS: f64 = 30.0;
/// ffmpeg's JPEG quality (2 best .. 31): 4, as 8 flattened a dark passage's noise into
/// 8-pixel squares, some of them pure black — stair-stepped black on the stage once a look
/// or a blend lifted what was round them.
const QUALITY: u32 = 4;
/// What the proxies are made as: a proxy made before (an older version) is made again,
/// played as it is till then.
pub const PROXY_VERSION: u32 = 2;

/// What clip.json holds: the facts, and the source they were made from (to know it again).
#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Stored {
    #[serde(flatten)]
    pub meta: ClipMeta,
    /// The source, relative to the sources' folder; its size and when it was changed.
    pub source: String,
    pub size: u64,
    pub modified: u64,
    /// [PROXY_VERSION] when made (0: before there was one).
    pub version: u32,
}

/// A tool of ffmpeg's: WETOWL_FFMPEG's folder, beside this program, on the PATH.
pub fn tool(name: &str) -> PathBuf {
    let exe = if cfg!(windows) { format!("{name}.exe") } else { name.to_owned() };
    if let Some(p) = std::env::var_os("WETOWL_FFMPEG").map(PathBuf::from) {
        let p = if p.is_dir() { p.join(&exe) } else { p.with_file_name(&exe) };
        if p.is_file() {
            return p;
        }
    }
    if let Some(d) = std::env::current_exe().ok().and_then(|e| e.parent().map(PathBuf::from)) {
        for c in [d.join(&exe), d.join("lib").join(&exe), d.join("stage").join("lib").join(&exe)] {
            if c.is_file() {
                return c;
            }
        }
    }
    PathBuf::from(exe)
}

/// Whether ffmpeg and ffprobe are there.
pub fn tools_found() -> bool {
    let ok = |n: &str| Command::new(tool(n)).arg("-version").stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success());
    ok("ffmpeg") && ok("ffprobe")
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Probe {
    pub w: u32,
    pub h: u32,
    pub fps: f64,
    pub secs: f64,
    /// Its pixels' shape (1: square).
    pub sar: f64,
}

/// "30000/1001" → 29.97.
fn ratio(s: &str) -> Option<f64> {
    let (a, b) = s.split_once(['/', ':']).unwrap_or((s, "1"));
    let (a, b) = (a.trim().parse::<f64>().ok()?, b.trim().parse::<f64>().ok()?);
    (a > 0.0 && b > 0.0).then_some(a / b)
}

pub fn probe(src: &Path) -> Result<Probe, String> {
    let out = Command::new(tool("ffprobe"))
        .args(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,avg_frame_rate,r_frame_rate,sample_aspect_ratio,duration:format=duration", "-of", "json"])
        .arg(src)
        .output()
        .map_err(|e| format!("ffprobe: {e}"))?;
    let j: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|e| format!("ffprobe said no JSON ({e}): {}", String::from_utf8_lossy(&out.stderr).trim()))?;
    let s = j["streams"].get(0).ok_or("no picture in it")?;
    let num = |v: &serde_json::Value| v.as_str().and_then(|t| t.parse::<f64>().ok()).or_else(|| v.as_f64());
    let fps = s["avg_frame_rate"].as_str().and_then(ratio).or_else(|| s["r_frame_rate"].as_str().and_then(ratio)).filter(|f| *f > 1.0 && *f < 241.0).unwrap_or(25.0);
    let secs = num(&s["duration"]).or_else(|| num(&j["format"]["duration"])).unwrap_or(0.0);
    let p = Probe {
        w: s["width"].as_u64().unwrap_or(0) as u32,
        h: s["height"].as_u64().unwrap_or(0) as u32,
        fps,
        secs,
        sar: s["sample_aspect_ratio"].as_str().and_then(ratio).unwrap_or(1.0),
    };
    if p.w == 0 || p.h == 0 {
        return Err("no picture size".into());
    }
    Ok(p)
}

/// The black bars burnt in, as ffmpeg's crop (`w:h:x:y`), where there are some worth cutting.
pub fn black_bars(src: &Path, p: &Probe) -> Option<String> {
    let out = Command::new(tool("ffmpeg"))
        .args(["-hide_banner", "-nostdin", "-skip_frame", "nokey", "-i"])
        .arg(src)
        .args(["-map", "0:v:0", "-an", "-sn", "-vf", "cropdetect=limit=24:round=2:reset=0", "-f", "null", "-"])
        .stdout(Stdio::null())
        .output()
        .ok()?;
    let err = String::from_utf8_lossy(&out.stderr);
    let last = err.lines().rev().find_map(|l| l.split("crop=").nth(1))?.split_whitespace().next()?.to_owned();
    let v: Vec<u32> = last.split(':').filter_map(|x| x.parse().ok()).collect();
    let [w, h, x, y] = v[..] else { return None };
    let worth = (p.w - w.min(p.w)) as f64 / p.w as f64 >= 0.03 || (p.h - h.min(p.h)) as f64 / p.h as f64 >= 0.03;
    let sane = w >= 64 && h >= 64 && (w as f64 * h as f64) >= 0.4 * (p.w as f64 * p.h as f64) && x + w <= p.w && y + h <= p.h;
    (worth && sane).then_some(last)
}

/// The rate the proxy keeps: the source's, halved while above 30.
pub fn proxy_fps(src: f64) -> f64 {
    let mut f = src;
    while f > MAX_FPS + 0.5 {
        f /= 2.0;
    }
    f
}

/// A clip's id: its name made plain, and its path and size hashed.
pub fn clip_id(rel: &str, size: u64) -> String {
    let stem = Path::new(rel).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let mut slug: String = stem.to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    while slug.contains("--") {
        slug = slug.replace("--", "-");
    }
    let slug: String = slug.trim_matches('-').chars().take(32).collect();
    let h = wo_show::rng::hash_str(&format!("{rel}\u{0}{size}"));
    format!("{}-{:08x}", if slug.is_empty() { "clip" } else { &slug }, h as u32)
}

/// Makes `src` into `<proxies>/<id>/` (proxy.wov, clip.json, poster.jpg). `rel` is its
/// path within the sources' folder; `progress` hears 0..1; `stop` cuts it short.
pub fn import(src: &Path, rel: &str, proxies: &Path, stop: &AtomicBool, mut progress: impl FnMut(f64)) -> Result<Stored, String> {
    let md = std::fs::metadata(src).map_err(|e| format!("{}: {e}", src.display()))?;
    let size = md.len();
    let modified = md.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs());
    let id = clip_id(rel, size);
    let p = probe(src)?;
    let crop = black_bars(src, &p);
    let fps = proxy_fps(p.fps);
    // after the crop, in square pixels: 540 high at most, never made bigger
    let ch = crop.as_deref().and_then(|c| c.split(':').nth(1)?.parse::<u32>().ok()).unwrap_or(p.h);
    let h = (ch.min(HEIGHT) / 2 * 2).max(16);
    let mut vf = vec!["bwdif=mode=send_frame:deint=interlaced".to_owned()];
    if let Some(c) = &crop {
        vf.push(format!("crop={c}"));
    }
    vf.push(format!("scale=w=trunc({h}*dar/2)*2:h={h}:flags=bicubic"));
    vf.push("setsar=1".into());
    if (fps - p.fps).abs() > 0.01 {
        vf.push(format!("fps={fps:.4}"));
    }
    vf.push("format=yuvj420p".into());

    std::fs::create_dir_all(proxies).map_err(|e| format!("{}: {e}", proxies.display()))?;
    let part = proxies.join(format!("{id}.part"));
    let _ = std::fs::remove_dir_all(&part);
    std::fs::create_dir_all(&part).map_err(|e| format!("{}: {e}", part.display()))?;
    let fail = |e: String| {
        let _ = std::fs::remove_dir_all(&part);
        e
    };

    let mut child = Command::new(tool("ffmpeg"))
        .args(["-hide_banner", "-nostdin", "-loglevel", "error", "-i"])
        .arg(src)
        .args(["-map", "0:v:0", "-an", "-sn", "-dn", "-vf", &vf.join(","), "-c:v", "mjpeg", "-q:v", &QUALITY.to_string(), "-f", "image2pipe", "pipe:1"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| fail(format!("ffmpeg: {e}")))?;
    let mut err_pipe = child.stderr.take().unwrap();
    let err_thread = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = err_pipe.read_to_string(&mut s);
        s
    });
    let mut out = child.stdout.take().unwrap();
    let mut w = ProxyWriter::create(&part.join("proxy.wov"), fps).map_err(|e| fail(e.to_string()))?;
    let expected = (p.secs * fps).max(1.0);
    let mut split = JpegSplitter::default();
    let mut buf = vec![0u8; 1 << 20];
    let mut wrote: Result<(), String> = Ok(());
    loop {
        if stop.load(Ordering::Relaxed) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(fail("stopped".into()));
        }
        let n = match out.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => return Err(fail(format!("ffmpeg's frames: {e}"))),
        };
        split.feed(&buf[..n], |j| {
            if wrote.is_ok() {
                wrote = w.push(j).map_err(|e| e.to_string());
            }
        });
        wrote.clone().map_err(fail)?;
        progress((w.frames() as f64 / expected).min(1.0) * 0.9);
    }
    let status = child.wait().map_err(|e| fail(e.to_string()))?;
    let said = err_thread.join().unwrap_or_default();
    if !status.success() || w.frames() == 0 {
        return Err(fail(format!("ffmpeg could not read it: {}", said.lines().last().unwrap_or("no frames").trim())));
    }
    let frames = w.frames();
    let (pw, ph) = w.size();
    w.finish().map_err(|e| fail(e.to_string()))?;

    // the facts, read off the proxy
    let mut proxy = Proxy::open(&part.join("proxy.wov")).map_err(|e| fail(e.to_string()))?;
    let secs = frames as f64 / fps;
    let (luma, motion, colour) = analyse(&mut proxy, fps, stop, |k| progress(0.9 + 0.1 * k)).map_err(fail)?;
    let lit = |l: &u8| *l >= 14;
    let first = luma.iter().position(lit).unwrap_or(0) as f64;
    let last = luma.iter().rposition(lit).map_or(secs, |i| (i + 1) as f64).min(secs);
    let (in_s, out_s) = if last - first >= 1.0 { (first, last) } else { (0.0, secs) };
    let name = Path::new(rel).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| id.clone());
    let meta = ClipMeta { id: id.clone(), name, secs, fps, frames, w: pw, h: ph, in_s, out_s, luma, motion, colour };
    // the poster: a lit frame a third of the way in
    let poster_s = poster_second(&meta);
    let poster = proxy.jpeg((poster_s * fps) as usize).map_err(|e| fail(e.to_string()))?;
    std::fs::write(part.join("poster.jpg"), poster).map_err(|e| fail(e.to_string()))?;
    let stored = Stored { meta, source: rel.to_owned(), size, modified, version: PROXY_VERSION };
    std::fs::write(part.join("clip.json"), serde_json::to_vec_pretty(&stored).unwrap()).map_err(|e| fail(e.to_string()))?;
    drop(proxy);
    let done = proxies.join(&id);
    let _ = std::fs::remove_dir_all(&done);
    std::fs::rename(&part, &done).map_err(|e| fail(format!("{}: {e}", done.display())))?;
    progress(1.0);
    Ok(stored)
}

/// The second for the poster: the brightest of those around a third of the way in.
fn poster_second(m: &ClipMeta) -> f64 {
    let (a, b) = m.span();
    let at = a + (b - a) / 3.0;
    let lo = at.floor() as usize;
    let best = (lo.saturating_sub(3)..(lo + 4).min(m.luma.len()))
        .max_by_key(|&s| {
            let l = m.luma[s] as i32;
            // lit, but not white
            -(l - 120).abs()
        })
        .map_or(at, |s| s as f64 + 0.5);
    best.clamp(a, (b - 0.05).max(a))
}

/// Each second's light (0..255), motion (0..255: how far two frames in a row differ) and
/// the colour in all of it (0..1).
fn analyse(proxy: &mut Proxy, fps: f64, stop: &AtomicBool, mut progress: impl FnMut(f64)) -> Result<(Vec<u8>, Vec<u8>, f64), String> {
    let n = proxy.frames();
    let seconds = ((n as f64 / fps).ceil() as usize).max(1);
    let (mut luma, mut motion) = (Vec::with_capacity(seconds), Vec::with_capacity(seconds));
    let (mut sat, mut sat_n) = (0.0, 0usize);
    for s in 0..seconds {
        if stop.load(Ordering::Relaxed) {
            return Err("stopped".into());
        }
        let i = ((s as f64 + 0.5) * fps) as usize;
        let i = i.min(n - 1);
        let a = proxy.rgba(i).map_err(|e| e.to_string())?;
        let grid = |p: &crate::proxy::Picture| -> Vec<(f64, f64)> {
            let step = (p.w / 64).max(1) as usize;
            let mut v = vec![];
            for y in (0..p.h as usize).step_by(step) {
                for x in (0..p.w as usize).step_by(step) {
                    let o = (y * p.w as usize + x) * 4;
                    let (r, g, b) = (p.rgba[o] as f64, p.rgba[o + 1] as f64, p.rgba[o + 2] as f64);
                    let l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    let s = (r.max(g).max(b) - r.min(g).min(b)) / 255.0;
                    v.push((l, s));
                }
            }
            v
        };
        let ga = grid(&a);
        let l = ga.iter().map(|x| x.0).sum::<f64>() / ga.len().max(1) as f64;
        sat += ga.iter().map(|x| x.1).sum::<f64>();
        sat_n += ga.len();
        let m = if i + 1 < n {
            let b = proxy.rgba(i + 1).map_err(|e| e.to_string())?;
            let gb = grid(&b);
            ga.iter().zip(&gb).map(|(x, y)| (x.0 - y.0).abs()).sum::<f64>() / ga.len().max(1) as f64
        } else {
            0.0
        };
        luma.push(l.round().clamp(0.0, 255.0) as u8);
        motion.push((m * 8.0).round().clamp(0.0, 255.0) as u8);
        progress((s + 1) as f64 / seconds as f64);
    }
    Ok((luma, motion, if sat_n == 0 { 0.0 } else { sat / sat_n as f64 }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_and_rates() {
        assert_eq!(proxy_fps(59.94), 29.97);
        assert_eq!(proxy_fps(25.0), 25.0);
        assert_eq!(proxy_fps(120.0), 30.0);
        let a = clip_id("old/Prelinger Reel #3.mp4", 10);
        assert!(a.starts_with("prelinger-reel-3-"), "{a}");
        assert_ne!(a, clip_id("old/Prelinger Reel #3.mp4", 11));
        assert_eq!(ratio("30000/1001").map(|r| (r * 100.0).round()), Some(2997.0));
        assert_eq!(ratio("0/0"), None);
    }

    /// A real clip through the real ffmpeg: 4:3 picture letterboxed in 16:9, interlaced
    /// flags, 50 fps — cut to 4:3, halved to 25, read back frame by frame.
    #[test]
    fn a_clip_becomes_a_proxy() {
        if !tools_found() {
            eprintln!("no ffmpeg here: skipped");
            return;
        }
        let dir = std::env::temp_dir().join(format!("wo-video-import-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("reel.mp4");
        // 3 s: a second of black, then a moving test picture pillarboxed into 1280×720
        let made = Command::new(tool("ffmpeg"))
            .args(["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=720x540:rate=50:duration=3", "-vf"])
            .arg("drawbox=t=fill:c=black:enable='lt(t,1)',pad=1280:720:280:90:black")
            .args(["-c:v", "libx264", "-g", "25", "-pix_fmt", "yuv420p", "-y"])
            .arg(&src)
            .status()
            .unwrap();
        assert!(made.success());
        let proxies = dir.join("proxies");
        let mut last = 0.0;
        let s = import(&src, "reel.mp4", &proxies, &AtomicBool::new(false), |k| last = k).unwrap();
        assert_eq!(last, 1.0);
        let m = &s.meta;
        assert_eq!(m.fps, 25.0);
        assert!((m.frames as i64 - 75).abs() <= 1, "{}", m.frames);
        assert_eq!((m.w, m.h), (720, 540), "the bars cut off");
        assert_eq!(m.in_s, 1.0, "the black second left out");
        assert!(m.luma[0] < 14 && m.luma[1] > 40, "{:?}", m.luma);
        assert!(m.colour > 0.2, "testsrc2 is colourful: {}", m.colour);
        let d = proxies.join(&m.id);
        assert!(d.join("poster.jpg").is_file() && d.join("clip.json").is_file());
        let mut p = Proxy::open(&d.join("proxy.wov")).unwrap();
        let f = p.rgba(40).unwrap();
        assert_eq!((f.w, f.h, f.rgba.len()), (720, 540, 720 * 540 * 4));
        std::fs::remove_dir_all(&dir).ok();
    }
}
