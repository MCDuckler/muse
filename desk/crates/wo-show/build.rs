//! The shipped scenes (app/assets/show/scenes/*.json) taken into the crate: a Desk or a stage
//! needs no files beside it (SceneBook::shipped).
use std::path::PathBuf;

fn main() {
    let dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../../app/assets/show/scenes");
    println!("cargo:rerun-if-changed={}", dir.display());
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir).map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "json")).collect()).unwrap_or_default();
    files.sort();
    let mut src = String::from("/// Every shipped scene's JSON.\npub static SHIPPED_SCENES: &[&str] = &[\n");
    for p in &files {
        println!("cargo:rerun-if-changed={}", p.display());
        src.push_str(&format!("    include_str!({:?}),\n", p.canonicalize().unwrap()));
    }
    src.push_str("];\n");
    std::fs::write(PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("scenes.rs"), src).unwrap();
}
