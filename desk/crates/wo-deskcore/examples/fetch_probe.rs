//! The fetch pipeline's local half on one video, nothing claimed or handed in: yt-dlp
//! with the Desk's arguments, its lines read, ffprobe and ebur128 measured.
//! `fetch_probe <video id> <out dir>`
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let (vid, dir) = (&a[0], std::path::PathBuf::from(&a[1]));
    let t = wo_deskcore::fetch::find_tools().expect("tools");
    std::fs::create_dir_all(&dir).unwrap();
    let mut c = Command::new(&t.ytdlp).args(wo_deskcore::fetch::ytdlp_args(vid, &dir, t.js.0)).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().unwrap();
    let mut last = None;
    for l in BufReader::new(c.stdout.take().unwrap()).lines().map_while(Result::ok) {
        if let (Some(p), _, _) = wo_deskcore::fetch::read_line(&l) {
            last = Some(p);
        }
    }
    println!("yt-dlp: {:?}, last progress {last:?}", c.wait().unwrap());
    let f = std::fs::read_dir(&dir).unwrap().filter_map(|e| e.ok()).map(|e| e.path()).find(|p| p.extension().is_some_and(|e| e == "m4a")).expect("an m4a");
    let heard = Command::new(&t.ffmpeg).args(["-nostats", "-hide_banner", "-i"]).arg(&f).args(["-af", "ebur128=framelog=quiet", "-f", "null", "-"]).output().unwrap();
    println!("{} · {} bytes · {:?} LUFS", f.display(), std::fs::metadata(&f).unwrap().len(), wo_deskcore::fetch::lufs_of(&String::from_utf8_lossy(&heard.stderr)));
}
