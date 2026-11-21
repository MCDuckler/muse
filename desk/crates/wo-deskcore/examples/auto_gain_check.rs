//! A file's loudness as Auto Gain measures it: `auto_gain_check <file>…`.
fn main() {
    for a in std::env::args().skip(1) {
        let p = std::path::Path::new(&a);
        let t = std::time::Instant::now();
        let l = wo_deskcore::autogain::measure(p, false);
        println!("{a}: {l:?} LUFS in {:.2} s", t.elapsed().as_secs_f64());
    }
}
