//! The show's shaders (app/shaders/show) taken into the crate, so a stage needs no files
//! beside it: `shipped("kinetic.frag")`.
use std::path::{Path, PathBuf};

fn walk(dir: &Path, base: &Path, out: &mut Vec<(String, PathBuf)>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, base, out);
        } else if p.extension().is_some_and(|x| x == "frag") {
            let rel = p.strip_prefix(base).unwrap().to_string_lossy().replace('\\', "/");
            out.push((rel, p));
        }
    }
}

fn main() {
    let dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../../app/shaders/show");
    println!("cargo:rerun-if-changed={}", dir.display());
    println!("cargo:rerun-if-changed={}", dir.join("sim").display());
    let mut files = vec![];
    walk(&dir, &dir, &mut files);
    files.sort();
    let mut src = String::from("/// Every .frag under app/shaders/show, by its path there.\npub static SHIPPED: &[(&str, &str)] = &[\n");
    for (rel, p) in &files {
        println!("cargo:rerun-if-changed={}", p.display());
        src.push_str(&format!("    ({rel:?}, include_str!({:?})),\n", p.canonicalize().unwrap()));
    }
    src.push_str("];\n");
    std::fs::write(PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("shipped.rs"), src).unwrap();
}
