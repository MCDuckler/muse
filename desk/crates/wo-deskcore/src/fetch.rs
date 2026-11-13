//! Fetching a song here, for the house (the WetOwl app's Downloader.fetchNow, ported):
//! a YouTube song somebody at this computer asked for is claimed from the house's queue
//! so no other computer takes it, fetched with yt-dlp on this computer's own connection
//! (YouTube refuses the box's), converted to AAC where it did not come as one, measured
//! (ffprobe, ffmpeg's ebur128), kept in the Desk's cache to play at once, and handed in.
//!
//! The same programs as the app: yt-dlp, ffmpeg, ffprobe and a JavaScript runtime (node
//! or deno) — looked for in the WetOwl app's tools folder, then on the PATH. Without
//! them the house's pool fetches it instead (the song is pushed to its front).
//!
//! yt-dlp's words are judged the way the app's are (ytdlp.dart, from worker.py): a rate
//! limit or a bot check gives the job back untouched; an age check or a song that is gone
//! fails it for good; anything else fails it to be tried again.
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use wo_house::{House, IngestJob};

/// The programs a fetch runs.
#[derive(Clone, Debug, PartialEq)]
pub struct Tools {
    pub ytdlp: PathBuf,
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
    /// "node" or "deno" (as yt-dlp's --js-runtimes says it), and where.
    pub js: (&'static str, PathBuf),
}

/// Where programs are looked for: the WetOwl app's tools folder, the PATH, and on a Mac
/// Homebrew's places (an app opened from the Finder has none of them on its PATH).
fn search_path() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = vec![];
    if let Some(app) = wo_house::app_folder() {
        dirs.push(app.join("tools"));
    }
    if cfg!(windows)
        && let Some(exe_dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf))
    {
        dirs.push(exe_dir);
    }
    if let Some(p) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&p));
    }
    if cfg!(target_os = "macos") {
        dirs.extend(["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"].map(PathBuf::from));
    }
    dirs
}

fn which(name: &str, dirs: &[PathBuf]) -> Option<PathBuf> {
    let exe = if cfg!(windows) { format!("{name}.exe") } else { name.to_owned() };
    dirs.iter().map(|d| d.join(&exe)).find(|f| f.is_file())
}

/// The programs, or the names of those missing.
pub fn find_tools() -> Result<Tools, Vec<&'static str>> {
    let dirs = search_path();
    let (ytdlp, ffmpeg, ffprobe) = (which("yt-dlp", &dirs), which("ffmpeg", &dirs), which("ffprobe", &dirs));
    let js = which("node", &dirs).map(|p| ("node", p)).or_else(|| which("deno", &dirs).map(|p| ("deno", p)));
    match (ytdlp, ffmpeg, ffprobe, js) {
        (Some(ytdlp), Some(ffmpeg), Some(ffprobe), Some(js)) => Ok(Tools { ytdlp, ffmpeg, ffprobe, js }),
        (y, f, p, j) => Err([(y.is_none(), "yt-dlp"), (f.is_none(), "ffmpeg"), (p.is_none(), "ffprobe"), (j.is_none(), "node or deno")].into_iter().filter(|m| m.0).map(|m| m.1).collect()),
    }
}

/// What to type to have them, for whoever has to install them.
pub fn how_to_install(missing: &[&str]) -> String {
    if cfg!(windows) {
        "winget install yt-dlp.yt-dlp Gyan.FFmpeg DenoLand.Deno".into()
    } else if cfg!(target_os = "macos") {
        "brew install yt-dlp ffmpeg deno".into()
    } else {
        let wanted: Vec<&str> = missing.iter().map(|m| if m.starts_with("ff") { "ffmpeg" } else if *m == "node or deno" { "nodejs" } else { m }).collect::<std::collections::BTreeSet<_>>().into_iter().collect();
        format!("pacman -S {0}  ·  apt install {0}", wanted.join(" "))
    }
}

/// One song being fetched here, as the crate shows it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Here {
    /// downloading, converting, measuring, uploading; "done" handed in; "failed".
    pub stage: String,
    pub percent: Option<f64>,
    pub error: Option<String>,
}

/// The songs fetched here, by the house's record id.
pub type HereMap = Arc<Mutex<HashMap<i64, Here>>>;

/// A YouTube video id and nothing else: it goes on a command line.
pub fn is_video_id(s: &str) -> bool {
    s.len() == 11 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// yt-dlp's arguments for one song (ytdlp.dart's ytdlpArgs).
pub fn ytdlp_args(video_id: &str, out_dir: &Path, js: &str) -> Vec<String> {
    vec![
        "--js-runtimes".into(),
        js.into(),
        // AAC in an m4a first, so the common path is a copy and not a transcode
        "-f".into(),
        "140/bestaudio[acodec^=mp4a]/bestaudio".into(),
        "--no-playlist".into(),
        "-o".into(),
        format!("{}/%(id)s.%(ext)s", out_dir.display()),
        "--newline".into(),
        "--progress-template".into(),
        "MUSEPROGRESS %(progress._percent_str)s %(progress._speed_str)s".into(),
        format!("https://music.youtube.com/watch?v={video_id}"),
    ]
}

/// What to do about a fetch that did not work (ytdlp.dart's judge).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Verdict {
    /// The connection is being throttled or challenged: give the job back.
    BackOff,
    /// YouTube wants an age-verified account: it will not fetch here.
    NeedsAge,
    /// Will still be an error in five minutes.
    Dead,
    /// Worth another go later.
    Retry,
}

pub fn judge(last_error: &str, throttled: bool) -> Verdict {
    let said = last_error.to_lowercase();
    if throttled {
        return Verdict::BackOff;
    }
    // before the bot check: "confirm your age" and "confirm you're not a bot" are one word apart
    if ["confirm your age", "age-restricted", "age restricted"].iter().any(|w| said.contains(w)) {
        return Verdict::NeedsAge;
    }
    if ["sign in to confirm you're not a bot", "sign in to confirm you\u{2019}re not a bot", "not a bot", "po token", "login_required"].iter().any(|w| said.contains(w)) {
        return Verdict::BackOff;
    }
    if ["unavailable", "not available", "private video", "removed by the uploader", "members-only", "copyright", "does not exist"].iter().any(|w| said.contains(w)) {
        return Verdict::Dead;
    }
    Verdict::Retry
}

/// One line of yt-dlp's: its progress (0..1 and the speed), whether it says "slow down",
/// and whether it would be the error remembered if it is the last word.
pub fn read_line(raw: &str) -> (Option<(f64, String)>, bool, Option<String>) {
    let line = raw.trim();
    let low = line.to_lowercase();
    let throttled = low.contains("http error 429") || low.contains("too many requests");
    if let Some(rest) = line.strip_prefix("MUSEPROGRESS") {
        let mut it = rest.split_whitespace();
        let p = it.next().and_then(|p| p.trim_end_matches('%').parse::<f64>().ok());
        let speed = it.next().unwrap_or("").to_owned();
        return (p.map(|p| (p / 100.0, speed)), throttled, None);
    }
    if line.is_empty() {
        return (None, throttled, None);
    }
    let error = (line.starts_with("ERROR") || !line.starts_with('[')).then(|| line.to_owned());
    (None, throttled, error)
}

/// The integrated loudness out of ffmpeg's ebur128 report (its last "I:" line).
pub fn lufs_of(stderr: &str) -> Option<f64> {
    stderr.lines().filter_map(|l| l.trim().strip_prefix("I:")).filter_map(|v| v.trim().split_whitespace().next()?.parse::<f64>().ok()).last()
}

fn set(map: &HereMap, id: i64, stage: &str, percent: Option<f64>, error: Option<String>) {
    if let Ok(mut m) = map.lock() {
        m.insert(id, Here { stage: stage.into(), percent, error });
    }
}

/// Claims and fetches `track_id` here, now (on this thread: run it on one of its own).
/// Ok(false): nothing to fetch — it is ready, or another computer has it.
pub fn fetch_now(house: &House, tools: &Tools, track_id: i64, map: &HereMap) -> Result<bool, String> {
    let Some(job) = house.claim(track_id).map_err(|e| e.to_string())? else { return Ok(false) };
    set(map, track_id, "downloading", Some(0.0), None);
    match work(house, tools, &job, map) {
        Ok(()) => {
            set(map, track_id, "done", Some(1.0), None);
            Ok(true)
        }
        Err(e) => {
            set(map, track_id, "failed", None, Some(e.clone()));
            Err(e)
        }
    }
}

fn work(house: &House, tools: &Tools, job: &IngestJob, map: &HereMap) -> Result<(), String> {
    if !is_video_id(&job.video_id) {
        let _ = house.job_fail(job, "not a YouTube video id", false);
        return Err("not a YouTube video id".into());
    }
    let dir = std::env::temp_dir().join(format!("wetowl-desk-fetch-{}-{}", job.id, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let out = fetch_in(house, tools, job, map, &dir);
    let _ = std::fs::remove_dir_all(&dir);
    out
}

fn fetch_in(house: &House, tools: &Tools, job: &IngestJob, map: &HereMap, dir: &Path) -> Result<(), String> {
    let _ = house.job_progress(job, "downloading", Some(0.0), None);
    let mut child = Command::new(&tools.ytdlp)
        .args(ytdlp_args(&job.video_id, dir, tools.js.0))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::null())
        .spawn()
        .map_err(|e| format!("yt-dlp would not start: {e}"))?;
    // both of its streams, line by line, into one channel
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    let mut readers = vec![];
    if let Some(o) = child.stdout.take() {
        let tx = tx.clone();
        readers.push(std::thread::spawn(move || BufReader::new(o).lines().map_while(Result::ok).for_each(|l| drop(tx.send(l)))));
    }
    if let Some(e) = child.stderr.take() {
        let tx = tx.clone();
        readers.push(std::thread::spawn(move || BufReader::new(e).lines().map_while(Result::ok).for_each(|l| drop(tx.send(l)))));
    }
    drop(tx);
    let (mut last_error, mut throttled, mut said_at) = (String::new(), false, Instant::now() - Duration::from_secs(5));
    for line in rx {
        let (progress, slow, error) = read_line(&line);
        throttled |= slow;
        if let Some(e) = error {
            last_error = e;
        }
        if let Some((p, speed)) = progress {
            set(map, job.track_id, "downloading", Some(p), None);
            // once a second is enough: it crosses to the house, which tells every app
            if said_at.elapsed() >= Duration::from_secs(1) {
                said_at = Instant::now();
                let _ = house.job_progress(job, "downloading", Some(p * 100.0), Some(&speed));
            }
        }
    }
    for r in readers {
        let _ = r.join();
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .map_err(|e| e.to_string())?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_file() && !["json", "txt", "part"].iter().any(|x| p.extension().is_some_and(|e| e == *x)))
        .collect();
    files.sort();
    if !status.success() || files.is_empty() {
        let reason = if last_error.is_empty() { "yt-dlp failed".to_owned() } else { last_error };
        return Err(match judge(&reason, throttled) {
            Verdict::BackOff => {
                let _ = house.job_release(job);
                format!("YouTube pushed back on this computer ({}); the house's pool will fetch it", if throttled { "rate limit" } else { "bot check" })
            }
            Verdict::NeedsAge => {
                let _ = house.job_fail(job, "YouTube wants an age-verified account for this one — it will not download here.", false);
                "YouTube wants an age-verified account for this one".into()
            }
            Verdict::Dead => {
                let _ = house.job_fail(job, &reason, false);
                reason
            }
            Verdict::Retry => {
                let _ = house.job_fail(job, &reason, true);
                reason
            }
        });
    }
    let mut audio = files.remove(0);
    if audio.extension().is_none_or(|e| e != "m4a") {
        set(map, job.track_id, "converting", None, None);
        let _ = house.job_progress(job, "converting", Some(0.0), None);
        let to = audio.with_extension("m4a");
        let r = Command::new(&tools.ffmpeg).args(["-v", "error", "-y", "-i"]).arg(&audio).args(["-c:a", "aac", "-b:a", "160k"]).arg(&to).output().map_err(|e| e.to_string())?;
        if !r.status.success() {
            let why = format!("ffmpeg could not convert it: {}", String::from_utf8_lossy(&r.stderr).trim());
            let _ = house.job_fail(job, &why, true);
            return Err(why);
        }
        audio = to;
    }
    // here for the person who asked, to play from this disk now
    if let Some(keep) = wo_house::cache_file(job.track_id) {
        if let Some(parent) = keep.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::copy(&audio, &keep);
    }
    set(map, job.track_id, "measuring", None, None);
    let _ = house.job_progress(job, "measuring", None, None);
    let probed = Command::new(&tools.ffprobe)
        .args(["-v", "error", "-show_entries", "format=duration,bit_rate:stream=codec_name,sample_rate,channels", "-of", "json"])
        .arg(&audio)
        .output()
        .map_err(|e| e.to_string())?;
    let info: serde_json::Value = serde_json::from_slice(&probed.stdout).unwrap_or_default();
    let stream = info.get("streams").and_then(|s| s.get(0)).cloned().unwrap_or_default();
    let format = info.get("format").cloned().unwrap_or_default();
    let num = |v: Option<&serde_json::Value>| v.and_then(|v| v.as_str().and_then(|s| s.parse::<f64>().ok()).or(v.as_f64()));
    let heard = Command::new(&tools.ffmpeg).args(["-nostats", "-hide_banner", "-i"]).arg(&audio).args(["-af", "ebur128=framelog=quiet", "-f", "null", "-"]).output().map_err(|e| e.to_string())?;
    let lufs = lufs_of(&String::from_utf8_lossy(&heard.stderr));
    set(map, job.track_id, "uploading", None, None);
    let _ = house.job_progress(job, "uploading", None, None);
    let meta = serde_json::json!({
        "track_id": job.track_id,
        "video_id": job.video_id,
        "codec": stream.get("codec_name"),
        "bitrate": num(format.get("bit_rate")).map(|b| b as i64),
        "duration_ms": num(format.get("duration")).map(|s| (s * 1000.0).round() as i64),
        "loudness_lufs": lufs,
        "gain_db": lufs.map(|l| ((-14.0 - l) * 100.0).round() / 100.0),
    });
    house.job_complete(job, &audio, &meta).map_err(|e| format!("handing it in: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn video_ids_and_nothing_else() {
        assert!(is_video_id("dQw4w9WgXcQ"));
        assert!(!is_video_id("-oops"));
        assert!(!is_video_id("dQw4w9WgXcQ; rm"));
    }

    #[test]
    fn its_words_judged_as_the_app_judges_them() {
        assert_eq!(judge("ERROR: Sign in to confirm your age", false), Verdict::NeedsAge);
        assert_eq!(judge("ERROR: Sign in to confirm you're not a bot", false), Verdict::BackOff);
        assert_eq!(judge("ERROR: Video unavailable", false), Verdict::Dead);
        assert_eq!(judge("ERROR: Video unavailable", true), Verdict::BackOff, "a 429 reads as unavailable");
        assert_eq!(judge("ERROR: something odd", false), Verdict::Retry);
    }

    #[test]
    fn its_lines_read() {
        let (p, slow, err) = read_line("MUSEPROGRESS  42.5% 1.20MiB/s");
        assert_eq!(p, Some((0.425, "1.20MiB/s".to_owned())));
        assert!(!slow && err.is_none());
        assert!(read_line("WARNING: HTTP Error 429: Too Many Requests").1);
        assert!(read_line("[youtube] Extracting URL").2.is_none());
        assert_eq!(read_line("ERROR: gone").2.as_deref(), Some("ERROR: gone"));
    }

    #[test]
    fn the_loudness_is_the_summarys() {
        let s = "[Parsed_ebur128_0] t: 1 M: -20 S: -20 I: -19.0 LUFS\n  Integrated loudness:\n    I:         -9.4 LUFS\n";
        assert_eq!(lufs_of(s), Some(-9.4));
    }
}
