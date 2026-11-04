//! How a stems file decoded here compares with ffmpeg's decode (native or libopus),
//! channel by channel: `cargo run --release --example stems_diff -- <file> [libopus]`.
use std::path::Path;
use std::process::Command;
fn main() {
    let s = std::env::args().nth(1).expect("a stems file");
    let lib = std::env::args().nth(2).is_some();
    let mut cmd = Command::new("ffmpeg");
    cmd.args(["-v", "error"]);
    if lib {
        cmd.args(["-c:a", "libopus"]);
    }
    let out = cmd.args(["-i", &s, "-f", "s16le", "-ac", "6", "-"]).output().unwrap();
    let want: Vec<i16> = out.stdout.as_chunks::<2>().0.iter().map(|b| i16::from_le_bytes(*b)).collect();
    let mut got = vec![];
    wo_decode::decode_stems(Path::new(&s), 48000, &mut got).unwrap();
    for c in 0..6 {
        for w in 0..6 {
            let (mut d2, mut e) = (0f64, 0f64);
            for f in (48000..got.len().min(want.len()) / 6).step_by(7) {
                let a = got[f * 6 + c] as f64;
                let b = want[f * 6 + w] as f64;
                d2 += (a - b) * (a - b);
                e += b * b;
            }
            print!("{:8.4} ", (d2 / e.max(1.0)).sqrt());
        }
        println!("  <- here ch{c} vs ffmpeg ch0..5 (relative rms diff)");
    }
    let n = got.len().min(want.len());
    let big = (0..n).filter(|&i| (got[i] as i32 - want[i] as i32).abs() > 100).count();
    let worst = (0..n).map(|i| (got[i] as i32 - want[i] as i32).abs()).max().unwrap_or(0);
    println!("samples off by >100: {big} of {n}; worst {worst}");
}
