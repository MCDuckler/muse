//! The Rust stage's renderer (plan: ~/.claude/plans/wetowl-stage-rust.md §2.4): wgpu on
//! Vulkan, Direct3D 12 and Metal, drawing the show's shaders as wo-shaders fits them.
//!
//! - [Gpu]: a device, with a window's surface or none (a test, a shot, a bench);
//! - [Pass]: a full-screen pass built from a fitted shader (its floats in Flutter's order,
//!   its samplers in theirs);
//! - [Stage]: the show's frame (wo_show::frame::StageFrame) drawn the native stage's way —
//!   ground, figure, particles, blend, trails, bloom, finish;
//! - [Arena]: the frame's uniforms, in one buffer written once a frame.
use std::borrow::Cow;

pub use wgpu;
pub use wo_shaders::{self, Fitted};

pub mod looks;
pub mod particles;
pub mod stage;
pub use stage::Stage;

/// One frame's uniform blocks, side by side in one buffer at the device's alignment, written
/// once before the frame's commands are submitted (a buffer written twice before a submit
/// holds the last write for every draw that reads it).
pub struct Arena {
    buf: wgpu::Buffer,
    data: Vec<u8>,
    align: usize,
    cap: usize,
    /// The most a frame wanted, for the next [Arena::begin] to grow to.
    wanted: usize,
}

impl Arena {
    pub fn new(gpu: &Gpu, cap: usize) -> Arena {
        let align = gpu.device.limits().min_uniform_buffer_offset_alignment as usize;
        Arena { buf: Arena::buffer(gpu, cap), data: Vec::with_capacity(cap), align, cap, wanted: 0 }
    }

    fn buffer(gpu: &Gpu, cap: usize) -> wgpu::Buffer {
        gpu.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("uniforms"),
            size: cap as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        })
    }

    /// A new frame: empty, and bigger where the last one wanted more than there was.
    pub fn begin(&mut self, gpu: &Gpu) {
        if self.wanted > self.cap {
            self.cap = self.wanted.next_power_of_two();
            self.buf = Arena::buffer(gpu, self.cap);
        }
        self.data.clear();
        self.wanted = 0;
    }

    /// A block for this frame: where it sits (None when the frame has run out of room; the
    /// next one has more).
    pub fn push(&mut self, bytes: &[u8]) -> Option<wgpu::BufferBinding<'_>> {
        let at = self.data.len().div_ceil(self.align) * self.align;
        let size = bytes.len().max(16);
        self.wanted = self.wanted.max(at + size);
        if at + size > self.cap {
            return None;
        }
        self.data.resize(at, 0);
        self.data.extend_from_slice(bytes);
        self.data.resize(at + size, 0);
        Some(wgpu::BufferBinding { buffer: &self.buf, offset: at as u64, size: wgpu::BufferSize::new(size as u64) })
    }

    /// The frame's blocks up to the GPU, before its commands are submitted.
    pub fn upload(&self, gpu: &Gpu) {
        if !self.data.is_empty() {
            gpu.queue.write_buffer(&self.buf, 0, &self.data);
        }
    }
}

/// The values of a pass's floats in its order, by name: `f(name, comps)` for each.
pub fn values_by(floats: &[wo_shaders::Float], f: impl Fn(&str, u32) -> Vec<f32>) -> Vec<f32> {
    let mut out = vec![];
    for fl in floats {
        let mut v = f(&fl.name, fl.comps);
        v.resize(fl.comps as usize, 0.0);
        out.extend(v);
    }
    out
}

/// A GPU with no window: for a bench, a test, a shot.
pub struct Gpu {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub info: wgpu::AdapterInfo,
    pub adapter: wgpu::Adapter,
    vertex: wgpu::ShaderModule,
}

impl Gpu {
    /// The best adapter for `surface` (or none: no window). WGPU_BACKEND, WGPU_ADAPTER_NAME
    /// and WGPU_POWER_PREF choose, as wgpu reads them.
    pub fn new(instance: &wgpu::Instance, surface: Option<&wgpu::Surface<'_>>) -> Result<Gpu, String> {
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::from_env().unwrap_or(wgpu::PowerPreference::HighPerformance),
            force_fallback_adapter: false,
            compatible_surface: surface,
            apply_limit_buckets: false,
        }))
        .map_err(|e| format!("no GPU adapter: {e}"))?;
        let info = adapter.get_info();
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("wo-render"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::downlevel_defaults().using_resolution(adapter.limits()),
            ..Default::default()
        }))
        .map_err(|e| format!("no device: {e}"))?;
        let vertex = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("full-screen triangle"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(wo_shaders::VERTEX_WGSL)),
        });
        Ok(Gpu { device, queue, info, vertex, adapter })
    }

    /// A GPU with no window: for a bench, a test, a shot.
    pub fn headless() -> Result<Gpu, String> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle_from_env());
        Gpu::new(&instance, None)
    }
}

/// One full-screen pass: a fitted shader's pipeline, its float block, its samplers.
pub struct Pass {
    pub name: String,
    pipeline: wgpu::RenderPipeline,
    layout: wgpu::BindGroupLayout,
    floats: Option<wgpu::Buffer>,
    fitted_floats: Vec<wo_shaders::Float>,
    block_size: u32,
    samplers: usize,
    sampler: wgpu::Sampler,
}

impl Pass {
    pub fn new(gpu: &Gpu, f: &Fitted, target: wgpu::TextureFormat) -> Pass {
        let d = &gpu.device;
        let mut entries = vec![];
        if f.block_size > 0 {
            entries.push(wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: wgpu::BufferSize::new(f.block_size as u64),
                },
                count: None,
            });
        }
        for i in 0..f.samplers.len() as u32 {
            entries.push(wgpu::BindGroupLayoutEntry {
                binding: 1 + 2 * i,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            });
            entries.push(wgpu::BindGroupLayoutEntry {
                binding: 2 + 2 * i,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            });
        }
        let layout = d.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some(&f.name), entries: &entries });
        let pl = d.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some(&f.name),
            bind_group_layouts: &[Some(&layout)],
            ..Default::default()
        });
        let fragment = d.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some(&f.name),
            source: wgpu::ShaderSource::Naga(Cow::Owned(f.module.clone())),
        });
        let pipeline = d.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(&f.name),
            layout: Some(&pl),
            vertex: wgpu::VertexState { module: &gpu.vertex, entry_point: Some("main"), buffers: &[], compilation_options: Default::default() },
            fragment: Some(wgpu::FragmentState {
                module: &fragment,
                entry_point: Some("main"),
                targets: &[Some(wgpu::ColorTargetState { format: target, blend: None, write_mask: wgpu::ColorWrites::ALL })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });
        let floats = (f.block_size > 0).then(|| {
            d.create_buffer(&wgpu::BufferDescriptor {
                label: Some(&f.name),
                size: f.block_size as u64,
                usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            })
        });
        let sampler = d.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("linear, clamped"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        Pass {
            name: f.name.clone(),
            pipeline,
            layout,
            floats,
            fitted_floats: f.floats.clone(),
            block_size: f.block_size,
            samplers: f.samplers.len(),
            sampler,
        }
    }

    /// The pass's floats, in its order.
    pub fn floats(&self) -> &[wo_shaders::Float] {
        &self.fitted_floats
    }

    /// Draws into `target` with `values` (setFloat order) and `textures` (the samplers'
    /// order), its floats in this frame's [Arena]: a pass can be drawn more than once a frame.
    #[allow(clippy::too_many_arguments)]
    pub fn draw_in(&self, gpu: &Gpu, encoder: &mut wgpu::CommandEncoder, arena: &mut Arena, target: &wgpu::TextureView, values: &[f32], textures: &[&wgpu::TextureView]) {
        assert_eq!(textures.len(), self.samplers, "{}: {} samplers", self.name, self.samplers);
        let block = (self.block_size > 0).then(|| wo_shaders::Fitted::block_of(&self.fitted_floats, self.block_size, values));
        let binding = match &block {
            Some(b) => match arena.push(b) {
                Some(binding) => Some(binding),
                None => return,
            },
            None => None,
        };
        let mut entries = vec![];
        if let Some(b) = binding {
            entries.push(wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Buffer(b) });
        }
        for (i, t) in textures.iter().enumerate() {
            entries.push(wgpu::BindGroupEntry { binding: 1 + 2 * i as u32, resource: wgpu::BindingResource::TextureView(t) });
            entries.push(wgpu::BindGroupEntry { binding: 2 + 2 * i as u32, resource: wgpu::BindingResource::Sampler(&self.sampler) });
        }
        let group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor { label: Some(&self.name), layout: &self.layout, entries: &entries });
        let mut rp = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some(&self.name),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        rp.set_pipeline(&self.pipeline);
        rp.set_bind_group(0, &group, &[]);
        rp.draw(0..3, 0..1);
    }

    /// Draws into `target` with `values` (setFloat order) and `textures` (the samplers' order).
    /// Once a submit: the floats are the pass's own buffer (see [Pass::draw_in]).
    pub fn draw(&self, gpu: &Gpu, encoder: &mut wgpu::CommandEncoder, target: &wgpu::TextureView, values: &[f32], textures: &[&wgpu::TextureView]) {
        assert_eq!(textures.len(), self.samplers, "{}: {} samplers", self.name, self.samplers);
        if let Some(buf) = &self.floats {
            let block = wo_shaders::Fitted::block_of(&self.fitted_floats, self.block_size, values);
            gpu.queue.write_buffer(buf, 0, &block);
        }
        let mut entries = vec![];
        if let Some(buf) = &self.floats {
            entries.push(wgpu::BindGroupEntry { binding: 0, resource: buf.as_entire_binding() });
        }
        for (i, t) in textures.iter().enumerate() {
            entries.push(wgpu::BindGroupEntry { binding: 1 + 2 * i as u32, resource: wgpu::BindingResource::TextureView(t) });
            entries.push(wgpu::BindGroupEntry { binding: 2 + 2 * i as u32, resource: wgpu::BindingResource::Sampler(&self.sampler) });
        }
        let group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor { label: Some(&self.name), layout: &self.layout, entries: &entries });
        let mut rp = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some(&self.name),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: target,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        rp.set_pipeline(&self.pipeline);
        rp.set_bind_group(0, &group, &[]);
        rp.draw(0..3, 0..1);
    }
}

/// A texture to draw into and read back: RGBA8.
pub fn target(gpu: &Gpu, width: u32, height: u32) -> wgpu::Texture {
    gpu.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("target"),
        size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    })
}

/// An RGBA8 picture as a texture (top row first).
pub fn upload(gpu: &Gpu, width: u32, height: u32, rgba: &[u8]) -> wgpu::Texture {
    let t = gpu.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("picture"),
        size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    gpu.queue.write_texture(
        wgpu::TexelCopyTextureInfo { texture: &t, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        rgba,
        wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4 * width), rows_per_image: Some(height) },
        wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
    );
    t
}

/// An RGBA8 texture's pixels, top row first (waits for the GPU).
pub fn read(gpu: &Gpu, t: &wgpu::Texture) -> Vec<u8> {
    let (w, h) = (t.width(), t.height());
    let row = (4 * w).div_ceil(256) * 256;
    let buf = gpu.device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("readback"),
        size: (row * h) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut enc = gpu.device.create_command_encoder(&Default::default());
    enc.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo { texture: t, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        wgpu::TexelCopyBufferInfo { buffer: &buf, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(row), rows_per_image: Some(h) } },
        wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
    );
    gpu.queue.submit([enc.finish()]);
    let slice = buf.slice(..);
    slice.map_async(wgpu::MapMode::Read, |_| {});
    let _ = gpu.device.poll(wgpu::PollType::wait_indefinitely());
    let data = slice.get_mapped_range().expect("the readback mapped");
    let mut out = Vec::with_capacity((4 * w * h) as usize);
    for y in 0..h as usize {
        out.extend_from_slice(&data[y * row as usize..y * row as usize + 4 * w as usize]);
    }
    out
}
