//! photocraft-pipeline-time — how long the driver takes to build each of Photocraft's GPU compositor
//! pipelines (crates/gpu `Compositor::build`: one WGSL module, a render pipeline per fragment entry
//! point of `Kernel::DRAWN`, the accumulator format for the RGBA kernels and R32Float + R16Float for
//! the effect maps), one after the other, with the descriptors the compositor uses.
//!
//!   photocraft-pipeline-time [--format rgba32f|rgba16f] [--only ENTRY]... [--threads N]
//!
//! Output: "PPT module <ms>", "PPT <entry> <format> <ms>" per pipeline in build order, "PPT total <ms>"
//! (with --threads N: N threads take the pipelines in turn, "PPT wall <ms>"). For cold numbers run with
//! MESA_SHADER_CACHE_DISABLE=true (Mesa's shader cache would answer from disk); docs/design/photocraft.md P5.

use std::num::NonZeroU64;
use std::time::Instant;

use photocraft_gpu::Kernel;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let value = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let only: Vec<String> = args.windows(2).filter(|w| w[0] == "--only").map(|w| w[1].clone()).collect();
    let threads: usize = value("--threads").and_then(|t| t.parse().ok()).unwrap_or(1).max(1);
    let acc = match value("--format").as_deref() {
        Some("rgba16f") => wgpu::TextureFormat::Rgba16Float,
        _ => wgpu::TextureFormat::Rgba32Float,
    };

    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle_from_env());
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default())).expect("no adapter");
    let info = adapter.get_info();
    println!("PPT adapter {:?} \"{}\" \"{}\"", info.backend, info.name, info.driver_info);
    println!("PPT cpus {:?} (std::thread::available_parallelism, rayon's default pool size)", std::thread::available_parallelism());
    let limits = adapter.limits();
    let required = wgpu::Limits {
        max_texture_dimension_2d: limits.max_texture_dimension_2d,
        max_buffer_size: limits.max_buffer_size,
        ..wgpu::Limits::default().or_worse_values_from(&limits)
    };
    let (device, _queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("photocraft-pipeline-time"),
        required_limits: required,
        ..Default::default()
    }))
    .expect("no device");

    let t = Instant::now();
    let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("pc_compose"),
        source: wgpu::ShaderSource::Wgsl(photocraft_gpu::SHADER.into()),
    });
    println!("PPT module {}", t.elapsed().as_millis());
    let uniform = |binding: u32, size: u64| wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: true, min_binding_size: NonZeroU64::new(size) },
        count: None,
    };
    let bgl0 = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("pc_compose_uniforms"),
        entries: &[uniform(0, 16), uniform(1, 256)],
    });
    let bgl1 = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("pc_compose_textures"),
        entries: &(0..8)
            .map(|binding| wgpu::BindGroupLayoutEntry {
                binding,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    multisampled: false,
                    sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    view_dimension: wgpu::TextureViewDimension::D2,
                },
                count: None,
            })
            .collect::<Vec<_>>(),
    });
    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("pc_compose"),
        bind_group_layouts: &[Some(&bgl0), Some(&bgl1)],
        immediate_size: 0,
    });

    let mut keys: Vec<(&str, wgpu::TextureFormat)> = Vec::new();
    for k in Kernel::DRAWN.iter().filter(|k| !k.is_map()) {
        keys.extend(k.entry().map(|e| (e, acc)));
    }
    for k in Kernel::DRAWN.iter().filter(|k| k.is_map()) {
        if let Some(e) = k.entry() {
            keys.push((e, wgpu::TextureFormat::R32Float));
            keys.push((e, wgpu::TextureFormat::R16Float));
        }
    }
    keys.retain(|(e, _)| only.is_empty() || only.iter().any(|o| o == e));

    let build = |entry: &str, format: wgpu::TextureFormat| {
        let t = Instant::now();
        let _pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some(entry),
            layout: Some(&layout),
            vertex: wgpu::VertexState { module: &module, entry_point: Some("vs"), buffers: &[], compilation_options: Default::default() },
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &module,
                entry_point: Some(entry),
                targets: &[Some(wgpu::ColorTargetState { format, blend: None, write_mask: wgpu::ColorWrites::ALL })],
                compilation_options: Default::default(),
            }),
            multiview_mask: None,
            cache: None,
        });
        let ms = t.elapsed().as_millis();
        println!("PPT {entry} {format:?} {ms}");
        ms
    };
    let t = Instant::now();
    if threads == 1 {
        let total: u128 = keys.iter().map(|&(e, f)| build(e, f)).sum();
        println!("PPT total {total}");
    } else {
        let next = std::sync::atomic::AtomicUsize::new(0);
        std::thread::scope(|s| {
            for _ in 0..threads {
                s.spawn(|| loop {
                    let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    let Some(&(e, f)) = keys.get(i) else { break };
                    build(e, f);
                });
            }
        });
        println!("PPT wall {} ({threads} threads)", t.elapsed().as_millis());
    }
}
