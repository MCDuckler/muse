// Compiles the booth engine (app/native/engine) into this crate: the same sources the
// Flutter app builds with CMake, miniaudio for the sound card and Rubber Band (single
// file) for key lock. Always optimised: a debug Rubber Band cannot keep up with real time.
use std::path::PathBuf;

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../app/native/engine");
    let src = root.join("src");
    let vendor = root.join("vendor");
    let rb = vendor.join("rubberband");
    for f in ["src/engine.cpp", "src/dsp.h", "src/tap.h", "src/we_engine.h", "src/miniaudio.c"] {
        println!("cargo:rerun-if-changed={}", root.join(f).display());
    }

    let msvc = std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc");
    let mut cpp = cc::Build::new();
    cpp.cpp(true)
        .std("c++17")
        .opt_level(2)
        .debug(false)
        .include(&src)
        .include(&vendor)
        .include(&rb)
        .file(src.join("engine.cpp"))
        .file(rb.join("single/RubberBandSingle.cpp"))
        .warnings(false);
    if msvc {
        cpp.define("_USE_MATH_DEFINES", None).define("NOMINMAX", None).flag("/EHsc").flag("/bigobj").flag("/utf-8");
    }
    cpp.compile("wetowl_engine_cpp");

    cc::Build::new()
        .opt_level(2)
        .debug(false)
        .include(&vendor)
        .file(src.join("miniaudio.c"))
        .warnings(false)
        .compile("wetowl_engine_ma");

    match std::env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("linux") => {
            for l in ["pthread", "dl", "m"] {
                println!("cargo:rustc-link-lib={l}");
            }
        }
        Ok("macos") => {
            for f in ["CoreFoundation", "CoreAudio", "AudioToolbox"] {
                println!("cargo:rustc-link-lib=framework={f}");
            }
        }
        _ => {}
    }
}
