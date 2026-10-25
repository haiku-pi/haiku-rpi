//! Photocraft's GPU compositor on this machine's wgpu adapter, headless:
//!
//!   photocraft-gpu-probe [--thread] [OUT_DIR]
//!
//! Prints the adapters, the chosen one's limits that fall below wgpu's defaults and its float
//! render formats, requests the device the way the app does, then composites a few documents
//! (blend modes, adjustments, layer effects, a large 32-bit one) on the GPU and on the CPU
//! (photocraft_compose, the reference) and prints the largest premultiplied difference against the
//! tolerance of crates/gpu's parity tests. With OUT_DIR, each result is written there as raw
//! little-endian f32 RGBA (`<case>.gpu`, `<case>.cpu`) for an MD5. Exit status 0 when every case
//! is within the tolerance. WGPU_BACKEND, WGPU_ADAPTER_NAME etc. choose the adapter as in wgpu;
//! PCG_LOG=warn|info|debug|trace logs wgpu to stderr (default warn). --thread: all of it on a
//! second thread, as Rust's test harness runs each test (the Vulkan loader and driver are then
//! loaded from that thread).

use std::{io::Write, path::PathBuf, time::Instant};

use photocraft_color::{BlendMode, Color, ColorMode, PixelFormat, SampleType};
use photocraft_doc::adjust::{CurvePoint, LevelsChannel};
use photocraft_doc::{Adjustment, Contour, Document, Effect, FxCommon, Layer, LayerContent, Shadow};
use photocraft_geom::{Rect, Size};
use photocraft_gpu::Compositor;

/// crates/gpu/tests/it/parity.rs: one 8-bit step plus a few f32 ulps, premultiplied.
const TOL: f32 = 1.0 / 255.0 + 4.0 * f32::EPSILON;

struct StderrLog;

impl log::Log for StderrLog {
    fn enabled(&self, m: &log::Metadata) -> bool {
        m.level() <= log::max_level()
    }
    fn log(&self, r: &log::Record) {
        if self.enabled(r.metadata()) {
            eprintln!("log {} {}: {}", r.level(), r.target(), r.args());
        }
    }
    fn flush(&self) {}
}

/// Deterministic pseudo-random values in 0..1 (parity.rs's `rnd`).
fn rnd(seed: u32, i: u32) -> f32 {
    let mut h = seed.wrapping_mul(0x9e37_79b9) ^ i.wrapping_mul(0x85eb_ca6b);
    h ^= h >> 13;
    h = h.wrapping_mul(0xc2b2_ae35);
    h ^= h >> 16;
    (h & 0xffff) as f32 / 65535.0
}

/// A raster layer over `rect`: smooth gradients with some noise, alpha at least `min_alpha`.
fn image_layer(name: &str, fmt: PixelFormat, rect: Rect, seed: u32, min_alpha: f32) -> Layer {
    let mut l = Layer::raster(name, fmt);
    let (w, h) = (rect.width(), rect.height());
    let mut data = Vec::with_capacity(w as usize * h as usize * fmt.channels());
    for y in 0..h {
        for x in 0..w {
            let i = y * w + x;
            let (u, v) = (x as f32 / w as f32, y as f32 / h as f32);
            let n = rnd(seed, i) * 0.25;
            let rgba = [
                (0.6 * u + n).min(1.0),
                (0.5 * v + 0.3 * (u * 7.0 + seed as f32).sin().abs() + n * 0.5).min(1.0),
                (1.0 - 0.7 * u * v + n * 0.3).min(1.0),
                min_alpha + (1.0 - min_alpha) * rnd(seed + 7919, i),
            ];
            data.extend_from_slice(&photocraft_raster::from_rgba(&fmt, rgba));
        }
    }
    l.surface_mut().unwrap().write_region(rect, &data);
    l
}

fn blend_doc(w: u32, h: u32, depth: SampleType) -> Document {
    let mut d = Document::new("blend", Size::new(w, h), ColorMode::Rgb, depth);
    let fmt = d.pixel_format();
    d.layers.push(image_layer("bg", fmt, Rect::from_xywh(0, 0, w, h), 1, 1.0));
    // At 32 bits Color Dodge leaves values above 1, where the non-separable modes' ClipColor is
    // ill-conditioned and CPU and GPU legitimately round apart (parity.rs, non_separable_modes_on_hdr_values):
    // separable modes only there.
    let last = if depth == SampleType::F32 { [BlendMode::LinearBurn, BlendMode::Exclusion] } else { [BlendMode::Hue, BlendMode::Luminosity] };
    let modes = [BlendMode::Multiply, BlendMode::Screen, BlendMode::Overlay, BlendMode::SoftLight, BlendMode::ColorDodge, BlendMode::Difference, last[0], last[1]];
    for (i, mode) in modes.into_iter().enumerate() {
        let i = i as u32;
        // overlapping bands, partly off the canvas
        let rect = Rect::from_xywh((i * w / 10) as i32 - 16, (i * h / 12) as i32, w / 3, h / 2);
        let mut l = image_layer(&format!("{mode:?}"), fmt, rect, 10 + i, 0.2);
        l.blend = mode;
        l.opacity = 0.75;
        d.layers.push(l);
    }
    d
}

fn adjust_doc(w: u32, h: u32) -> Document {
    let mut d = Document::new("adjust", Size::new(w, h), ColorMode::Rgb, SampleType::U16);
    let fmt = d.pixel_format();
    d.layers.push(image_layer("bg", fmt, Rect::from_xywh(0, 0, w, h), 2, 1.0));
    let channel = LevelsChannel { in_black: 0.1, in_white: 0.9, gamma: 1.4, out_black: 0.05, out_white: 0.95 };
    let curve = vec![
        CurvePoint { input: 0.0, output: 0.0 },
        CurvePoint { input: 0.3, output: 0.2 },
        CurvePoint { input: 0.7, output: 0.85 },
        CurvePoint { input: 1.0, output: 1.0 },
    ];
    for adj in [
        Adjustment::Exposure { exposure: 0.4, offset: 0.01, gamma: 1.1 },
        Adjustment::Levels { master: channel.clone(), per_channel: Default::default(), space: Default::default(), black: Default::default() },
        Adjustment::Curves { master: curve, per_channel: Default::default(), space: Default::default(), black: Vec::new(), pencil: false },
        Adjustment::BrightnessContrast { brightness: 10.0, contrast: 20.0, legacy: false },
        Adjustment::ChannelMixer { matrix: [[0.8, 0.3, -0.1, 0.0], [0.1, 0.9, 0.0, 0.05], [0.0, 0.2, 0.7, 0.0]], monochrome: false },
        Adjustment::PhotoFilter { color: [0.97, 0.76, 0.0], density: 0.3, preserve_luminosity: true },
    ] {
        d.layers.push(Layer::new("adjustment", LayerContent::Adjustment(adj)));
    }
    d
}

fn effects_doc(w: u32, h: u32) -> Document {
    let mut d = Document::new("effects", Size::new(w, h), ColorMode::Rgb, SampleType::U8);
    let fmt = d.pixel_format();
    d.layers.push(image_layer("bg", fmt, Rect::from_xywh(0, 0, w, h), 3, 1.0));
    let mut l = image_layer("card", fmt, Rect::from_xywh(w as i32 / 4, h as i32 / 4, w / 2, h / 2), 4, 1.0);
    l.effects.items = vec![Effect::DropShadow(Shadow {
        common: FxCommon::new(BlendMode::Multiply, 0.75),
        color: Color::rgb(0.1, 0.05, 0.3),
        angle: 120.0,
        use_global_light: false,
        distance: 12.0,
        spread: 0.0,
        size: 16.0,
        contour: Contour::Linear,
        anti_alias: false,
        noise: 0.0,
        knocks_out: true,
    })];
    d.layers.push(l);
    d
}

/// Largest premultiplied difference and its pixel index (parity.rs's `worst_diff`).
fn worst_diff(cpu: &[[f32; 4]], gpu: &[[f32; 4]]) -> (f32, usize) {
    let mut worst = (0.0f32, 0usize);
    for (i, (c, o)) in cpu.iter().zip(gpu).enumerate() {
        let pc = [c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3]];
        let po = [o[0] * o[3], o[1] * o[3], o[2] * o[3], o[3]];
        for k in 0..4 {
            let d = (pc[k] - po[k]).abs();
            if d.is_nan() || d > worst.0 {
                worst = (if d.is_nan() { 9.0 } else { d }, i);
            }
        }
    }
    worst
}

fn write_raw(dir: &Option<PathBuf>, name: &str, px: &[[f32; 4]]) {
    let Some(dir) = dir else { return };
    let mut bytes = Vec::with_capacity(px.len() * 16);
    for p in px {
        for c in p {
            bytes.extend_from_slice(&c.to_le_bytes());
        }
    }
    std::fs::write(dir.join(name), bytes).unwrap_or_else(|e| panic!("writing {name}: {e}"));
}

fn main() {
    let level = match std::env::var("PCG_LOG").as_deref() {
        Ok("trace") => log::LevelFilter::Trace,
        Ok("debug") => log::LevelFilter::Debug,
        Ok("info") => log::LevelFilter::Info,
        Ok("error") => log::LevelFilter::Error,
        _ => log::LevelFilter::Warn,
    };
    static LOG: StderrLog = StderrLog;
    log::set_logger(&LOG).unwrap();
    log::set_max_level(level);
    let args: Vec<String> = std::env::args().skip(1).collect();
    let out = args.iter().find(|a| !a.starts_with("--")).map(PathBuf::from);
    let status = if args.iter().any(|a| a == "--thread") {
        println!("on a second thread");
        std::thread::spawn(move || probe(out)).join().unwrap_or(2)
    } else {
        probe(out)
    };
    std::io::stdout().flush().ok();
    std::process::exit(status);
}

fn probe(out: Option<PathBuf>) -> i32 {

    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle_from_env());
    let adapters = pollster::block_on(instance.enumerate_adapters(wgpu::Backends::all()));
    println!("adapters: {}", adapters.len());
    for a in &adapters {
        let i = a.get_info();
        println!("adapter: {:?} \"{}\" {:?} driver \"{}\" \"{}\" vendor {:#x} device {:#x}", i.backend, i.name, i.device_type, i.driver, i.driver_info, i.vendor, i.device);
    }
    let adapter = match pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default())) {
        Ok(a) => a,
        Err(e) => {
            println!("FAIL no adapter: {e}");
            return 1;
        }
    };
    let info = adapter.get_info();
    println!("chosen: {:?} \"{}\"", info.backend, info.name);
    let limits = adapter.limits();
    let mut below = Vec::new();
    wgpu::Limits::default().check_limits_with_fail_fn(&limits, false, |name, want, have| below.push(format!("{name} {have} (default {want})")));
    println!("limits below wgpu's defaults: {}", if below.is_empty() { "none".to_string() } else { below.join(", ") });
    println!(
        "limits: texture-2d {} color-attachments {} inter-stage-vars {} uniform-binding {} storage-binding {} buffer {} workgroup-storage {}",
        limits.max_texture_dimension_2d,
        limits.max_color_attachments,
        limits.max_inter_stage_shader_variables,
        limits.max_uniform_buffer_binding_size,
        limits.max_storage_buffer_binding_size,
        limits.max_buffer_size,
        limits.max_compute_workgroup_storage_size
    );
    println!("features: {:?}", adapter.features());
    for format in [wgpu::TextureFormat::Rgba32Float, wgpu::TextureFormat::Rgba16Float, wgpu::TextureFormat::Rgba8Unorm] {
        let f = adapter.get_texture_format_features(format);
        println!("format {format:?}: {:?} {:?}", f.allowed_usages, f.flags);
    }

    // the app's device (crates/ui-egui gpu_canvas::device_limits)
    let base = if info.backend == wgpu::Backend::Gl { wgpu::Limits::downlevel_webgl2_defaults() } else { wgpu::Limits::default() };
    let required = wgpu::Limits {
        max_texture_dimension_2d: limits.max_texture_dimension_2d,
        max_buffer_size: limits.max_buffer_size,
        ..base.or_worse_values_from(&limits)
    };
    let (device, queue) = match pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("photocraft-gpu-probe"),
        required_limits: required,
        ..Default::default()
    })) {
        Ok(d) => d,
        Err(e) => {
            println!("FAIL no device: {e}");
            return 1;
        }
    };
    let format = Compositor::preferred_acc_format(&adapter);
    let t = Instant::now();
    let mut comp = match Compositor::try_new_with_format(&device, format) {
        Ok(c) => c,
        Err(e) => {
            println!("FAIL compositor ({format:?}): {e}");
            return 1;
        }
    };
    println!("compositor: {format:?}, pipelines built in {} ms", t.elapsed().as_millis());

    let (w, h) = (640, 480);
    let cases = [
        ("blend-u8", blend_doc(w, h, SampleType::U8)),
        ("adjust-u16", adjust_doc(w, h)),
        ("effects-u8", effects_doc(w, h)),
        ("blend-f32-2048", blend_doc(2048, 2048, SampleType::F32)),
    ];
    let mut failed = 0;
    for (name, doc) in &cases {
        let t = Instant::now();
        let cpu = photocraft_compose::flatten(doc);
        let cpu_ms = t.elapsed().as_millis();
        let t = Instant::now();
        let first = photocraft_gpu::render_to_vec(&mut comp, &device, &queue, doc, doc.bounds());
        let cold_ms = t.elapsed().as_millis();
        let gpu = match first {
            Ok(v) => v,
            Err(e) => {
                println!("case {name}: FAIL render: {e}");
                failed += 1;
                continue;
            }
        };
        // again, on a fresh compositor (no cached composite): the same bits?
        let mut fresh = Compositor::new_with_format(&device, format);
        let t = Instant::now();
        let again = photocraft_gpu::render_to_vec(&mut fresh, &device, &queue, doc, doc.bounds()).unwrap_or_default();
        let warm_ms = t.elapsed().as_millis();
        let repeat = again.iter().flatten().map(|v| v.to_bits()).eq(gpu.iter().flatten().map(|v| v.to_bits()));
        let (worst, at) = worst_diff(&cpu.px, &gpu);
        let ok = worst <= TOL && gpu.len() == cpu.px.len();
        failed += usize::from(!ok);
        println!(
            "case {name}: {} {}x{} max-diff {:.3}/255 at ({},{}) repeat {} cpu-ms {cpu_ms} gpu-ms {cold_ms} gpu2-ms {warm_ms}",
            if ok { "ok" } else { "FAIL" },
            doc.bounds().width(),
            doc.bounds().height(),
            worst * 255.0,
            at as u32 % doc.bounds().width(),
            at as u32 / doc.bounds().width(),
            if repeat { "identical" } else { "differs" },
        );
        if !ok && at < gpu.len() {
            println!("case {name}: worst pixel cpu {:?} gpu {:?}", cpu.px[at], gpu[at]);
        }
        write_raw(&out, &format!("{name}.gpu"), &gpu);
        write_raw(&out, &format!("{name}.cpu"), &cpu.px);
    }
    println!("result: {} of {} cases within {:.3}/255", cases.len() - failed, cases.len(), TOL * 255.0);
    i32::from(failed > 0)
}
