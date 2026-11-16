//! Makes every clip in the footage folder that has no proxy yet into one (what the Desk does
//! on its own), and says what is there.
//!   cargo run --release -p wo-video --example import_dir -- [sources dir] [proxies dir]
use std::sync::atomic::AtomicBool;

use wo_video::Library;

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let lib = match (a.first(), a.get(1)) {
        (Some(s), Some(p)) => Library::at(s.as_ref(), p.as_ref()),
        _ => Library::here().expect("a home"),
    };
    eprintln!("footage from {}\nproxies in {}", lib.sources.display(), lib.proxies.display());
    if !wo_video::tools_found() {
        eprintln!("no ffmpeg/ffprobe (WETOWL_FFMPEG, beside the Desk, on the PATH)");
        std::process::exit(1);
    }
    let gone = lib.prune();
    if gone > 0 {
        eprintln!("{gone} proxies of footage no longer there: removed");
    }
    let stop = AtomicBool::new(false);
    for p in lib.pending(&[]) {
        let t = std::time::Instant::now();
        let mut shown = -1i64;
        match wo_video::import(&p.path, &p.rel, &lib.proxies, &stop, |k| {
            let pc = (k * 100.0) as i64;
            if pc / 10 != shown / 10 {
                shown = pc;
                eprint!("\r{} {pc:>3} %", p.rel);
            }
        }) {
            Ok(s) => {
                let m = &s.meta;
                let mb = std::fs::metadata(lib.proxy(&m.id)).map(|x| x.len()).unwrap_or(0) as f64 / 1e6;
                eprintln!("\r{}: {}×{} {:.2} fps {:.1} s ({:.1}–{:.1}), busy {:.2}, colour {:.2}, {mb:.1} MB, {:.1} s", p.rel, m.w, m.h, m.fps, m.secs, m.in_s, m.out_s, m.busy(), m.colour, t.elapsed().as_secs_f64());
            }
            Err(e) => eprintln!("\r{}: {e}", p.rel),
        }
    }
    for c in lib.clips() {
        println!("{}\t{}\t{:.1} s\tbusy {:.2}\tcolour {:.2}", c.id, c.name, c.secs, c.busy(), c.colour);
    }
}
