//! One compositor pass on a handful of pixels, to reduce a GPU-only difference to the shader code
//! that causes it (#75: `parity::blend_if` on V3D):
//!
//!   photocraft-shader-repro [--wgsl FILE] [--entry NAME] [--adj 0|1]
//!
//! Draws `fs_lerp` (or NAME) of Photocraft's compositor shader (or FILE, a WGSL module with the
//! same bindings) over a 4×1 target with Blend If on: tex_a = the colour beneath, tex_b = an
//! inverted (adjusted) colour, tex_c = the compositor's 1×1 dummy (an adjustment layer has no
//! content of its own), and the "gray this hard" ranges of parity.rs (this layer's gray, a hard
//! step at 90). `--adj 0` sets op.p4.y = 0 (a raster layer: "this layer" is tex_c). Prints each
//! pixel and the value compose::apply_blend_if gives; exit status 0 when all match.
//! `shaders/blend-if-min.wgsl` is the reduced shader V3DV got wrong (#75, mesa dee7e96cb04).

use std::num::NonZeroU64;

const W: u32 = 4;
const F_BLEND_IF: u32 = 524_288;

/// (beneath, adjusted) straight-alpha RGBA in 0..1, per pixel
fn pixels() -> [([f32; 4], [f32; 4]); W as usize] {
    let c = |r: f32, g: f32, b: f32, a: f32| [r / 255.0, g / 255.0, b / 255.0, a];
    let inv = |p: [f32; 4]| [1.0 - p[0], 1.0 - p[1], 1.0 - p[2], p[3]];
    let under = [c(69.0, 201.0, 254.0, 1.0), c(200.0, 30.0, 40.0, 1.0), c(69.0, 201.0, 254.0, 0.5), c(10.0, 20.0, 30.0, 1.0)];
    under.map(|u| (u, inv(u)))
}

/// compose::BlendRange as plan::blend_if_params packs it: (black, white) = (lo·256 + hi, lo·256 + hi)
fn packed(black: [u8; 2], white: [u8; 2]) -> [f32; 2] {
    [f32::from(black[0]) * 256.0 + f32::from(black[1]), f32::from(white[0]) * 256.0 + f32::from(white[1])]
}

fn ramp(lo: f32, hi: f32, x: f32) -> f32 {
    if hi <= lo {
        return if x >= lo { 1.0 } else { 0.0 };
    }
    ((x - lo) / (hi - lo)).clamp(0.0, 1.0)
}

/// The shader's blend_if_weight on the CPU for the gray entry only (the others are full ranges).
fn expected(this_px: Option<[f32; 4]>, under: [f32; 4], adjusted: [f32; 4], f: &[f32; 16]) -> [f32; 4] {
    let mut k = 1.0f32;
    for (s, px) in [this_px, Some(under)].into_iter().enumerate() {
        let Some(px) = px else { continue };
        if px[3] <= 0.0 {
            continue;
        }
        let v: Vec<f32> = px[..3].iter().map(|c| c.clamp(0.0, 1.0) * 255.0).map(|r| if (r - r.round()).abs() < 1e-4 { r.round() } else { r }).collect();
        let gray = 0.299 * v[0] + 0.587 * v[1] + 0.114 * v[2];
        let (black, white) = (f[s * 2], f[s * 2 + 1]);
        let (b_lo, w_lo) = ((black / 256.0).floor(), (white / 256.0).floor());
        let (b_hi, w_hi) = (black - b_lo * 256.0, white - w_lo * 256.0);
        k *= ramp(b_lo, b_hi, gray) * ramp(255.0 - w_hi, 255.0 - w_lo, 255.0 - gray);
    }
    if k >= 1.0 {
        return adjusted;
    }
    let (a, b) = (under, adjusted);
    let alpha = a[3] + (b[3] - a[3]) * k;
    if alpha <= 0.0 {
        return [0.0; 4];
    }
    let ch = |i: usize| ((a[i] * a[3] + (b[i] * b[3] - a[i] * a[3]) * k) / alpha).clamp(0.0, 1.0);
    [ch(0), ch(1), ch(2), alpha]
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let source = match arg("--wgsl") {
        Some(path) => std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}")),
        None => photocraft_gpu::SHADER.to_string(),
    };
    let entry = arg("--entry").unwrap_or_else(|| "fs_lerp".into());
    let adj = arg("--adj").as_deref() != Some("0");
    std::process::exit(run(&source, &entry, adj));
}

fn run(source: &str, entry: &str, adj: bool) -> i32 {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle_from_env());
    let adapter = match pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default())) {
        Ok(a) => a,
        Err(e) => {
            println!("FAIL no adapter: {e}");
            return 2;
        }
    };
    let info = adapter.get_info();
    println!("adapter: {:?} \"{}\" driver \"{}\"", info.backend, info.name, info.driver_info);
    let supported = adapter.limits();
    let limits = wgpu::Limits::default().or_worse_values_from(&supported);
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("photocraft-shader-repro"),
        required_limits: limits,
        ..Default::default()
    }))
    .expect("device");

    let module = device.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some("repro"), source: wgpu::ShaderSource::Wgsl(source.into()) });
    let uniform = |binding: u32, size: u64| wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: true, min_binding_size: NonZeroU64::new(size) },
        count: None,
    };
    let texture = |binding: u32| wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            multisampled: false,
            sample_type: wgpu::TextureSampleType::Float { filterable: false },
            view_dimension: wgpu::TextureViewDimension::D2,
        },
        count: None,
    };
    let bgl0 = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &[uniform(0, 16), uniform(1, 256)] });
    let bgl1 = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &(0..8).map(texture).collect::<Vec<_>>() });
    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &[Some(&bgl0), Some(&bgl1)], immediate_size: 0 });
    let format = wgpu::TextureFormat::Rgba32Float;
    let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
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

    // The uniforms as the compositor lays them out: chunk and op records in one buffer, chosen
    // by dynamic offsets (the op record at its second 256-byte slot, as for a later pass).
    let mut f = [0.0f32; 16];
    let full = packed([0, 0], [255, 255]);
    for e in 0..4 {
        f[e * 4..e * 4 + 2].copy_from_slice(&full);
        f[e * 4 + 2..e * 4 + 4].copy_from_slice(&full);
    }
    f[0..2].copy_from_slice(&packed([90, 90], [255, 255]));
    let mut ubuf = vec![0u8; 768];
    let put = |buf: &mut Vec<u8>, at: usize, v: [u8; 4]| buf[at..at + 4].copy_from_slice(&v);
    // Chunk { origin, size } at 0
    put(&mut ubuf, 8, (W as i32).to_le_bytes());
    put(&mut ubuf, 12, 1i32.to_le_bytes());
    // Op at 512: mode, kind, flags, _pad0, opacity, ... p0..p3 at +80, p4 at +160
    let op = 512;
    put(&mut ubuf, op + 8, F_BLEND_IF.to_le_bytes());
    put(&mut ubuf, op + 16, 1.0f32.to_le_bytes());
    put(&mut ubuf, op + 28, 1.0f32.to_le_bytes());
    for (i, v) in f.iter().enumerate() {
        put(&mut ubuf, op + 80 + i * 4, v.to_le_bytes());
    }
    put(&mut ubuf, op + 164, (if adj { 1.0f32 } else { 0.0 }).to_le_bytes());
    let ub = device.create_buffer(&wgpu::BufferDescriptor { label: None, size: ubuf.len() as u64, usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false });
    queue.write_buffer(&ub, 0, &ubuf);
    let binding = |size: u64| wgpu::BindingResource::Buffer(wgpu::BufferBinding { buffer: &ub, offset: 0, size: NonZeroU64::new(size) });
    let bg0 = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout: &bgl0,
        entries: &[wgpu::BindGroupEntry { binding: 0, resource: binding(16) }, wgpu::BindGroupEntry { binding: 1, resource: binding(256) }],
    });

    let px = pixels();
    let tex = |w: u32, format: wgpu::TextureFormat, usage: wgpu::TextureUsages| {
        device.create_texture(&wgpu::TextureDescriptor {
            label: None,
            size: wgpu::Extent3d { width: w, height: 1, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage,
            view_formats: &[],
        })
    };
    let upload = |rows: Vec<[f32; 4]>| {
        let t = tex(W, format, wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST);
        let bytes: Vec<u8> = rows.iter().flatten().flat_map(|v| v.to_le_bytes()).collect();
        queue.write_texture(
            wgpu::TexelCopyTextureInfo { texture: &t, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
            &bytes,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(W * 16), rows_per_image: Some(1) },
            wgpu::Extent3d { width: W, height: 1, depth_or_array_layers: 1 },
        );
        t.create_view(&Default::default())
    };
    let a = upload(px.iter().map(|p| p.0).collect());
    let b = upload(px.iter().map(|p| p.1).collect());
    let dummy = tex(1, wgpu::TextureFormat::Rgba8Unorm, wgpu::TextureUsages::TEXTURE_BINDING).create_view(&Default::default());
    // a raster layer's own content: the adjusted colour (as if the layer were that colour)
    let c = if adj { dummy.clone() } else { upload(px.iter().map(|p| p.1).collect()) };
    let views = [&a, &b, &dummy, &dummy, &dummy, &c, &dummy, &dummy];
    let bg1 = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout: &bgl1,
        entries: &views.iter().enumerate().map(|(i, v)| wgpu::BindGroupEntry { binding: i as u32, resource: wgpu::BindingResource::TextureView(v) }).collect::<Vec<_>>(),
    });

    let target = tex(W, format, wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC);
    let target_view = target.create_view(&Default::default());
    let read = device.create_buffer(&wgpu::BufferDescriptor { label: None, size: 256, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
    let mut enc = device.create_command_encoder(&Default::default());
    {
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: None,
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &target_view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color { r: -1.0, g: -1.0, b: -1.0, a: -1.0 }), store: wgpu::StoreOp::Store },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &bg0, &[0, op as u32]);
        pass.set_bind_group(1, &bg1, &[]);
        pass.draw(0..3, 0..1);
    }
    enc.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo { texture: &target, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        wgpu::TexelCopyBufferInfo { buffer: &read, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(256), rows_per_image: Some(1) } },
        wgpu::Extent3d { width: W, height: 1, depth_or_array_layers: 1 },
    );
    queue.submit([enc.finish()]);
    read.slice(..).map_async(wgpu::MapMode::Read, |_| {});
    let _ = device.poll(wgpu::PollType::Wait { submission_index: None, timeout: None });
    let data = read.slice(..).get_mapped_range().expect("readback");
    let got: Vec<f32> = data.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();

    let mut bad = 0;
    for (i, (under, adjusted)) in px.iter().enumerate() {
        let want = expected(Some(*adjusted), *under, *adjusted, &f);
        let g = &got[i * 4..i * 4 + 4];
        let ok = g.iter().zip(want).all(|(g, w)| (g - w).abs() <= 1e-4);
        bad += usize::from(!ok);
        let fmt = |v: &[f32]| v.iter().map(|x| format!("{:7.2}", x * 255.0)).collect::<Vec<_>>().join(" ");
        println!("px {i} {} gpu [{}] cpu [{}]", if ok { "ok  " } else { "DIFF" }, fmt(g), fmt(&want));
    }
    println!("{} ({entry}, adjustment {adj})", if bad == 0 { "PASS" } else { "FAIL" });
    i32::from(bad != 0)
}
