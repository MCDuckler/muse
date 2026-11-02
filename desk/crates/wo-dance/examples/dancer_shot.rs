//! P0 spike: a dancer drawn on wgpu — the scan skinned on the CPU into one move's pose at
//! four beats, lit, its skin on, side by side in one picture.
//!   cargo run --release -p wo-dance --example dancer_shot -- <dancer dir> <move id> <out.png>
use std::path::PathBuf;

use wgpu::util::DeviceExt;

const SHADER: &str = "
struct U { view: mat4x4<f32> };
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var skin_t: texture_2d<f32>;
@group(0) @binding(2) var skin_s: sampler;
struct VIn { @location(0) pos: vec3<f32>, @location(1) nrm: vec3<f32>, @location(2) uv: vec2<f32> };
struct VOut { @builtin(position) p: vec4<f32>, @location(0) n: vec3<f32>, @location(1) uv: vec2<f32> };
@vertex fn vs(v: VIn) -> VOut {
    var o: VOut;
    o.p = u.view * vec4<f32>(v.pos, 1.0);
    o.n = v.nrm;
    o.uv = v.uv;
    return o;
}
@fragment fn fs(i: VOut) -> @location(0) vec4<f32> {
    let c = textureSample(skin_t, skin_s, i.uv).rgb;
    let l = max(dot(normalize(i.n), normalize(vec3<f32>(-0.4, -1.0, 0.7))), 0.0) * 0.8 + 0.3;
    return vec4<f32>(c * l, 1.0);
}
";

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let dir = PathBuf::from(&a[1]);
    let rig = wo_dance::Rig::load(&dir).expect("the dancer");
    let mi = rig.move_by_id(&a[2]).expect("the move");
    let out = PathBuf::from(&a[3]);
    let gpu = wo_render::Gpu::headless().expect("a GPU");
    let d = &gpu.device;
    let skin = image::load_from_memory(&rig.skin).expect("the skin").to_rgba8();
    let skin_tex = wo_render::upload(&gpu, skin.width(), skin.height(), &skin);
    let skin_view = skin_tex.create_view(&Default::default());
    let sampler = d.create_sampler(&wgpu::SamplerDescriptor { mag_filter: wgpu::FilterMode::Linear, min_filter: wgpu::FilterMode::Linear, ..Default::default() });
    // a camera in front (−y) looking along +y: x across, z up; ±1.1 m wide, −0.1..2.1 m high
    #[rustfmt::skip]
    let view: [f32; 16] = [
        1.0 / 1.1, 0.0, 0.0, 0.0,
        0.0, 0.0, 0.25, 0.0,
        0.0, 2.0 / 2.2, 0.0, 0.0,
        0.0, -1.0 + 0.1 * 2.0 / 2.2, 0.5, 1.0,
    ];
    let ubuf = d.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: None, contents: &view.iter().flat_map(|f| f.to_le_bytes()).collect::<Vec<u8>>(), usage: wgpu::BufferUsages::UNIFORM });
    let module = d.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some("dancer"), source: wgpu::ShaderSource::Wgsl(SHADER.into()) });
    let layout = d.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: None,
        entries: &[
            wgpu::BindGroupLayoutEntry { binding: 0, visibility: wgpu::ShaderStages::VERTEX, ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None }, count: None },
            wgpu::BindGroupLayoutEntry { binding: 1, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: true }, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false }, count: None },
            wgpu::BindGroupLayoutEntry { binding: 2, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering), count: None },
        ],
    });
    let group = d.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout: &layout,
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: ubuf.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(&skin_view) },
            wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::Sampler(&sampler) },
        ],
    });
    let pl = d.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &[Some(&layout)], ..Default::default() });
    let stride = 8 * 4;
    let pipeline = d.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("dancer"),
        layout: Some(&pl),
        vertex: wgpu::VertexState {
            module: &module,
            entry_point: Some("vs"),
            buffers: &[Some(wgpu::VertexBufferLayout { array_stride: stride, step_mode: wgpu::VertexStepMode::Vertex, attributes: &wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3, 2 => Float32x2] })],
            compilation_options: Default::default(),
        },
        fragment: Some(wgpu::FragmentState { module: &module, entry_point: Some("fs"), targets: &[Some(wgpu::TextureFormat::Rgba8Unorm.into())], compilation_options: Default::default() }),
        primitive: wgpu::PrimitiveState::default(),
        depth_stencil: Some(wgpu::DepthStencilState { format: wgpu::TextureFormat::Depth32Float, depth_write_enabled: Some(true), depth_compare: Some(wgpu::CompareFunction::Less), stencil: Default::default(), bias: Default::default() }),
        multisample: Default::default(),
        multiview_mask: None,
        cache: None,
    });
    let (cw, ch) = (400u32, 760u32);
    let beats = [0.0, 0.5, 1.0, 1.5];
    let target = wo_render::target(&gpu, cw * beats.len() as u32, ch);
    let depth = d.create_texture(&wgpu::TextureDescriptor { label: None, size: wgpu::Extent3d { width: target.width(), height: ch, depth_or_array_layers: 1 }, mip_level_count: 1, sample_count: 1, dimension: wgpu::TextureDimension::D2, format: wgpu::TextureFormat::Depth32Float, usage: wgpu::TextureUsages::RENDER_ATTACHMENT, view_formats: &[] });
    let mut buffers = vec![];
    for &beat in &beats {
        let skinning = rig.skinning(&rig.solve(&rig.sample(mi, beat)));
        for (k, m) in rig.meshes.iter().enumerate() {
            let (pos, nrm) = rig.deform(k, &skinning);
            let mut v: Vec<f32> = Vec::with_capacity(m.corners() * 8);
            for c in 0..m.corners() {
                let s = m.src[c] as usize;
                v.extend_from_slice(&pos[s * 3..s * 3 + 3]);
                v.extend_from_slice(&nrm[s * 3..s * 3 + 3]);
                v.extend_from_slice(&m.uv[c * 2..c * 2 + 2]);
            }
            let vb = d.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: None, contents: &v.iter().flat_map(|f| f.to_le_bytes()).collect::<Vec<u8>>(), usage: wgpu::BufferUsages::VERTEX });
            let ib = d.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: None, contents: &m.tris.iter().flat_map(|i| i.to_le_bytes()).collect::<Vec<u8>>(), usage: wgpu::BufferUsages::INDEX });
            buffers.push((vb, ib, m.tris.len() as u32));
        }
    }
    let mut enc = d.create_command_encoder(&Default::default());
    {
        let view = target.create_view(&Default::default());
        let dview = depth.create_view(&Default::default());
        let mut rp = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: None,
            color_attachments: &[Some(wgpu::RenderPassColorAttachment { view: &view, depth_slice: None, resolve_target: None, ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.05, g: 0.05, b: 0.07, a: 1.0 }), store: wgpu::StoreOp::Store } })],
            depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment { view: &dview, depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Clear(1.0), store: wgpu::StoreOp::Store }), stencil_ops: None }),
            ..Default::default()
        });
        rp.set_pipeline(&pipeline);
        rp.set_bind_group(0, &group, &[]);
        let per = rig.meshes.len();
        for (i, (vb, ib, n)) in buffers.iter().enumerate() {
            rp.set_viewport((i / per) as f32 * cw as f32, 0.0, cw as f32, ch as f32, 0.0, 1.0);
            rp.set_vertex_buffer(0, vb.slice(..));
            rp.set_index_buffer(ib.slice(..), wgpu::IndexFormat::Uint16);
            rp.draw_indexed(0..*n, 0, 0..1);
        }
    }
    gpu.queue.submit([enc.finish()]);
    let px = wo_render::read(&gpu, &target);
    image::RgbaImage::from_raw(target.width(), ch, px).unwrap().save(&out).unwrap();
    println!("{} ({} bones, {} moves) {} at beats {:?} on {} → {}", dir.display(), rig.bones(), rig.moves.len(), rig.moves[mi].id, beats, gpu.info.name, out.display());
}
