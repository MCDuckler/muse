//! The shipped MilkDrop presets (app/assets/milk/presets) taken into the Desk: written out
//! once beside the library (the helper reads files), on a machine the WetOwl app never ran on.
use std::path::PathBuf;

fn main() {
    let dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../../app/assets/milk/presets");
    println!("cargo:rerun-if-changed={}", dir.display());
    let mut files: Vec<PathBuf> = std::fs::read_dir(&dir).map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "milk")).collect()).unwrap_or_default();
    files.sort();
    let mut src = String::from("/// Every shipped preset: its file name and bytes.\npub static SHIPPED_MILK: &[(&str, &[u8])] = &[\n");
    for p in &files {
        let name = p.file_name().unwrap().to_string_lossy().into_owned();
        src.push_str(&format!("    ({name:?}, include_bytes!({:?})),\n", p.canonicalize().unwrap()));
    }
    src.push_str("];\n");
    std::fs::write(PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("milk_presets.rs"), src).unwrap();
}
