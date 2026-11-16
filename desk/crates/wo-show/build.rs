//! The shipped scenes (app/assets/show/scenes/*.json) taken into the crate: a Desk or a stage
//! needs no files beside it (SceneBook::shipped).
use std::path::PathBuf;

fn main() {
    // the app's scenes (v1's too), then the Rust stage's own (scenes/: footage)
    let here = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let mut files: Vec<PathBuf> = vec![];
    for dir in [here.join("../../../app/assets/show/scenes"), here.join("scenes")] {
        println!("cargo:rerun-if-changed={}", dir.display());
        let mut f: Vec<PathBuf> = std::fs::read_dir(&dir).map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "json")).collect()).unwrap_or_default();
        f.sort();
        files.extend(f);
    }
    let mut src = String::from("/// Every shipped scene's JSON.\npub static SHIPPED_SCENES: &[&str] = &[\n");
    for p in &files {
        println!("cargo:rerun-if-changed={}", p.display());
        src.push_str(&format!("    include_str!({:?}),\n", p.canonicalize().unwrap()));
    }
    src.push_str("];\n");
    std::fs::write(PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("scenes.rs"), src).unwrap();
}
