//! Every shader the Rust stage draws (plan §1: the scenes in scope and the passes around
//! them) fitted, read by naga, and written out for each desktop's GPU — Metal (MSL), Direct3D
//! (HLSL) and Vulkan (SPIR-V) — so a shader that one of them would refuse is found here, on
//! any machine.
use std::path::PathBuf;

use naga::back::{hlsl, msl, spv};

/// The in-scope shaders, by path under app/shaders/show.
pub const IN_SCOPE: &[&str] = &[
    // the scenes
    "kinetic.frag", "flash.frag", "blocks.frag", "glide.frag", "drift.frag", "milk.frag",
    // the grounds (pulse.*, field.*), the passes: trails, blur, composite, the blend, the
    // kaleidoscope, the finish
    "pulse.frag", "field.frag", "feedback.frag", "blur.frag", "composite.frag", "under.frag", "ghosts.frag", "finish.frag",
    // the treatments, the fluid's five passes, the 3D text
    "sim/dance_fx.frag", "sim/fluid_advect.frag", "sim/fluid_div.frag", "sim/fluid_jacobi.frag", "sim/fluid_project.frag",
    "sim/fluid_look.frag", "sim/type3d.frag",
];

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../app/shaders/show")
}

fn fitted(name: &str) -> wo_shaders::Fitted {
    let src = std::fs::read_to_string(dir().join(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
    match wo_shaders::fit(name, &src) {
        Ok(f) => f,
        Err(t) => panic!("{t}"),
    }
}

#[test]
fn every_shader_reads_and_passes() {
    let mut bad = vec![];
    for name in IN_SCOPE {
        let src = std::fs::read_to_string(dir().join(name)).unwrap();
        if let Err(t) = wo_shaders::fit(name, &src) {
            bad.push(t.to_string());
        }
    }
    assert!(bad.is_empty(), "{} of {} would not fit:\n\n{}", bad.len(), IN_SCOPE.len(), bad.join("\n\n"));
}

#[test]
fn every_shader_writes_out_for_metal_direct3d_and_vulkan() {
    let mut bad = vec![];
    for name in IN_SCOPE {
        let src = std::fs::read_to_string(dir().join(name)).unwrap();
        let Ok(f) = wo_shaders::fit(name, &src) else { continue };
        let ep = naga::back::PipelineConstants::default();
        // Metal
        let pipeline = msl::PipelineOptions { entry_point: Some((naga::ShaderStage::Fragment, "main".into())), ..Default::default() };
        if let Err(e) = msl::write_string(&f.module, &f.info, &msl::Options::default(), &pipeline) {
            bad.push(format!("{name} → MSL: {e}"));
        }
        // Direct3D
        let mut out = String::new();
        let options = hlsl::Options { shader_model: hlsl::ShaderModel::V5_1, ..Default::default() };
        if let Err(e) = hlsl::Writer::new(&mut out, &options, &hlsl::PipelineOptions::default()).write(&f.module, &f.info, None) {
            bad.push(format!("{name} → HLSL: {e}"));
        }
        // Vulkan
        if let Err(e) = spv::write_vec(&f.module, &f.info, &spv::Options::default(), None) {
            bad.push(format!("{name} → SPIR-V: {e}"));
        }
        let _ = ep;
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

#[test]
fn the_floats_keep_flutters_order_and_the_block_holds_them() {
    // kinetic: uResolution, then the packs, then the three floats
    let k = fitted("kinetic.frag");
    let names: Vec<&str> = k.floats.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(&names[..3], &["uResolution", "uP0", "uP1"]);
    assert_eq!(k.float_count(), 2 + 32 + 3, "the 37 floats Flutter numbers");
    assert_eq!(k.samplers, Vec::<String>::new());
    // std140: the vec4s on 16, the vec2 at 0
    let at = |n: &str| k.floats.iter().find(|f| f.name == n).unwrap().offset;
    assert_eq!(at("uResolution"), 0);
    assert_eq!(at("uP0") % 16, 0);
    // values land where their names are
    let values: Vec<f32> = (0..k.float_count()).map(|i| i as f32).collect();
    let b = k.block(&values);
    let read = |o: u32| f32::from_le_bytes(b[o as usize..o as usize + 4].try_into().unwrap());
    assert_eq!(read(at("uResolution") + 4), 1.0);
    assert_eq!(read(at("uP0")), 2.0, "uTime is the third float");
    assert_eq!(read(at("uP1") + 12), 2.0 + 7.0, "uLow is uP1.w");
}

#[test]
fn the_samplers_keep_their_order() {
    let u = fitted("under.frag");
    assert_eq!(u.samplers.len(), 2);
    let src = std::fs::read_to_string(dir().join("under.frag")).unwrap();
    let declared: Vec<String> = src
        .lines()
        .filter_map(|l| l.trim().strip_prefix("uniform sampler2D "))
        .map(|r| r.split(';').next().unwrap().trim().to_owned())
        .collect();
    assert_eq!(u.samplers, declared);
}
