//! The show's shaders for wgpu. The scene and pass shaders are Flutter runtime-effect
//! GLSL (app/shaders/show/*.frag): GLSL 4.60 with Flutter's header, loose uniforms set by
//! position (Flutter's setFloat(i)), samplers in their order, `out vec4 fragColor`. They
//! stay the source while v1's stages draw them too (plan: ~/.claude/plans/
//! wetowl-stage-rust.md §6.4); here they are fitted to the Vulkan GLSL that naga reads:
//!
//!   #version 460 core, Flutter's #include  →  #version 450
//!   uniform float|vec2|vec3|vec4 uX;       →  members of one block, set 0 binding 0, in
//!                                             the file's order (std140; the offsets are
//!                                             naga's, read back from the module)
//!   uniform sampler2D uS;                  →  a texture and a sampler (bindings 1, 2, …),
//!                                             and `uS` a #define of `sampler2D(t, s)`
//!   out vec4 fragColor;                    →  layout(location = 0)
//!   FlutterFragCoord()                     →  gl_FragCoord (wgpu's origin is the top left,
//!                                             as Flutter's; textures' first row is the top)
//!
//! No turning over, unlike the GLSL ES fitting (app/native/stage/src/glsl.h).
use std::fmt::Write as _;

pub use naga;

include!(concat!(env!("OUT_DIR"), "/shipped.rs"));

/// A shipped shader's source, by its path under app/shaders/show (`kinetic.frag`,
/// `sim/type3d.frag`).
pub fn shipped(path: &str) -> Option<&'static str> {
    SHIPPED.iter().find(|(p, _)| *p == path).map(|(_, s)| *s)
}

/// A shipped shader fitted, by its path.
pub fn fit_shipped(path: &str) -> Result<Fitted, Trouble> {
    let src = shipped(path).ok_or_else(|| Trouble { name: path.into(), what: "no such shader".into(), glsl: None })?;
    fit(path.trim_end_matches(".frag"), src)
}

/// The shaders the Rust stage draws, by path under app/shaders/show (plan §1: the scenes in
/// scope and the passes round them).
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

/// One float uniform as the shader declares it: its name, its floats, and where it sits in
/// the block (bytes).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Float {
    pub name: String,
    pub comps: u32,
    pub offset: u32,
}

/// A shader fitted and checked.
#[derive(Debug)]
pub struct Fitted {
    pub name: String,
    /// The Vulkan GLSL handed to naga.
    pub glsl: String,
    pub module: naga::Module,
    pub info: naga::valid::ModuleInfo,
    /// The floats in the file's order (Flutter's setFloat numbering: each name `comps`
    /// floats after the one before).
    pub floats: Vec<Float>,
    /// The block's size in bytes (0: no floats).
    pub block_size: u32,
    /// The samplers in the file's order; sampler i is the texture at binding 1 + 2i and
    /// the sampler at 2 + 2i.
    pub samplers: Vec<String>,
}

impl Fitted {
    /// How many floats setFloat numbers (the sum of the uniforms' floats).
    pub fn float_count(&self) -> usize {
        self.floats.iter().map(|f| f.comps as usize).sum()
    }

    /// The block's bytes for `values` in setFloat order (missing ones zero).
    pub fn block(&self, values: &[f32]) -> Vec<u8> {
        Self::block_of(&self.floats, self.block_size, values)
    }

    /// [Fitted::block] from the layout alone (a pass keeps that, not the module).
    pub fn block_of(floats: &[Float], block_size: u32, values: &[f32]) -> Vec<u8> {
        let mut out = vec![0u8; block_size as usize];
        let mut at = 0usize;
        for f in floats {
            for c in 0..f.comps as usize {
                let v = values.get(at + c).copied().unwrap_or(0.0);
                let o = f.offset as usize + 4 * c;
                out[o..o + 4].copy_from_slice(&v.to_le_bytes());
            }
            at += f.comps as usize;
        }
        out
    }
}

/// Why a shader could not be fitted.
#[derive(Debug)]
pub struct Trouble {
    pub name: String,
    pub what: String,
    /// The fitted source, when it got that far (its lines numbered in naga's errors).
    pub glsl: Option<String>,
}

impl std::fmt::Display for Trouble {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.name, self.what)
    }
}

impl std::error::Error for Trouble {}

fn comps_of(ty: &str) -> Option<u32> {
    match ty {
        "float" => Some(1),
        "vec2" => Some(2),
        "vec3" => Some(3),
        "vec4" => Some(4),
        _ => None,
    }
}

/// `uniform <ty> <name>;` (with anything after the semicolon) → (ty, name).
fn uniform_decl(line: &str) -> Option<(&str, &str)> {
    let rest = line.trim_start().strip_prefix("uniform")?;
    if !rest.starts_with(char::is_whitespace) {
        return None;
    }
    let mut words = rest.split_whitespace();
    let ty = words.next()?;
    let name_semi = words.next()?;
    let name = name_semi.split(';').next()?;
    if !name_semi.contains(';') && !words.next().is_some_and(|w| w.starts_with(';')) {
        return None;
    }
    if name.contains(',') || name.is_empty() {
        return None;
    }
    Some((ty, name))
}

/// The Flutter `.frag` source `src` (called `name` in errors) fitted for wgpu and checked.
pub fn fit(name: &str, src: &str) -> Result<Fitted, Trouble> {
    let trouble = |what: String, glsl: Option<String>| Trouble { name: name.to_owned(), what, glsl };
    let mut floats: Vec<(String, u32)> = vec![];
    let mut samplers: Vec<String> = vec![];
    let mut body = String::with_capacity(src.len());
    for (i, line) in src.lines().enumerate() {
        let t = line.trim_start();
        if t.starts_with("#version") || t.starts_with("#include <flutter/runtime_effect.glsl>") || t.starts_with("precision ") {
            body.push('\n');
            continue;
        }
        if let Some((ty, var)) = uniform_decl(line) {
            if ty == "sampler2D" {
                samplers.push(var.to_owned());
            } else if let Some(c) = comps_of(ty) {
                floats.push((var.to_owned(), c));
            } else {
                return Err(trouble(format!("line {}: a uniform of a kind not fitted: {ty}", i + 1), None));
            }
            body.push('\n');
            continue;
        }
        if t.starts_with("uniform ") {
            return Err(trouble(format!("line {}: a uniform declaration not fitted: {}", i + 1, t), None));
        }
        if let Some(rest) = t.strip_prefix("out ") {
            body.push_str("layout(location = 0) out ");
            body.push_str(rest);
            body.push('\n');
            continue;
        }
        body.push_str(line);
        body.push('\n');
    }

    let mut glsl = String::from("#version 450\n");
    if !floats.is_empty() {
        glsl.push_str("layout(set = 0, binding = 0) uniform WsFloats {\n");
        for (n, c) in &floats {
            let ty = match c {
                1 => "float",
                2 => "vec2",
                3 => "vec3",
                _ => "vec4",
            };
            let _ = writeln!(glsl, "    {ty} {n};");
        }
        glsl.push_str("};\n");
    }
    for (i, s) in samplers.iter().enumerate() {
        let (t, sm) = (1 + 2 * i, 2 + 2 * i);
        let _ = writeln!(glsl, "layout(set = 0, binding = {t}) uniform texture2D {s}_wsT;");
        let _ = writeln!(glsl, "layout(set = 0, binding = {sm}) uniform sampler {s}_wsS;");
        let _ = writeln!(glsl, "#define {s} sampler2D({s}_wsT, {s}_wsS)");
    }
    glsl.push_str("vec4 FlutterFragCoord() { return gl_FragCoord; }\n");
    // the body keeps its own line numbers after this many header lines
    let header_lines = glsl.lines().count();
    glsl.push_str(&body);

    let mut front = naga::front::glsl::Frontend::default();
    let options = naga::front::glsl::Options::from(naga::ShaderStage::Fragment);
    let module = front.parse(&options, &glsl).map_err(|e| {
        let said = e.emit_to_string(&glsl);
        trouble(format!("naga could not read it (body line = line − {header_lines}):\n{said}"), Some(glsl.clone()))
    })?;
    let info = naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::default())
        .validate(&module)
        .map_err(|e| trouble(format!("naga would not pass it: {}", e.emit_to_string(&glsl)), Some(glsl.clone())))?;

    // the floats' offsets, as naga laid the block out
    let mut laid: Vec<Float> = vec![];
    let mut block_size = 0;
    if !floats.is_empty() {
        let block = module
            .global_variables
            .iter()
            .find(|(_, g)| g.space == naga::AddressSpace::Uniform)
            .ok_or_else(|| trouble("the float block is gone from the module".into(), Some(glsl.clone())))?
            .1;
        let naga::TypeInner::Struct { members, span } = &module.types[block.ty].inner else {
            return Err(trouble("the float block is not a struct".into(), Some(glsl.clone())));
        };
        block_size = *span;
        for (n, c) in &floats {
            let m = members
                .iter()
                .find(|m| m.name.as_deref() == Some(n.as_str()))
                .ok_or_else(|| trouble(format!("{n} is not in the block"), Some(glsl.clone())))?;
            laid.push(Float { name: n.clone(), comps: *c, offset: m.offset });
        }
    }
    Ok(Fitted { name: name.to_owned(), glsl, module, info, floats: laid, block_size, samplers })
}

/// The full-screen triangle every pass draws with, in WGSL.
pub const VERTEX_WGSL: &str = "@vertex
fn main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    let p = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
}
";
