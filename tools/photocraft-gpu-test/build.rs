//! Copies photocraft-gpu's integration tests (sources/photocraft-<version>/crates/gpu/tests/it) into OUT_DIR
//! with one change: every device is requested the way the app requests its own
//! (`crate::device_descriptor`, from crates/ui-egui's `gpu_canvas::device_descriptor`) instead of
//! with `wgpu::DeviceDescriptor::default()`. wgpu's default limits ask for 8192 px textures and 8
//! color attachments; V3D (the Pi 4) has 4096 and 4, so with the defaults every test would skip
//! ("no device") and none would run. The app asks for the defaults lowered to what the adapter
//! has; the tests here do the same. Any other change upstream fails the build (counted rewrites).

use std::{env, fs, path::Path};

/// (file, upstream text, replacement, occurrences in that file)
const REWRITES: &[(&str, &str, &str, usize)] = &[
    ("camera_raw.rs", "wgpu::DeviceDescriptor::default()", "crate::device_descriptor(&adapter)", 1),
    ("device_loss.rs", "wgpu::DeviceDescriptor::default()", "crate::device_descriptor(&adapter)", 1),
    ("parity.rs", "wgpu::DeviceDescriptor::default()", "crate::device_descriptor(&adapter)", 2),
    ("pipeline_errors.rs", "wgpu::DeviceDescriptor::default()", "crate::device_descriptor(&adapter)", 1),
    ("vector_mask.rs", "wgpu::DeviceDescriptor::default()", "crate::device_descriptor(&adapter)", 1),
    (
        "timing.rs",
        "wgpu::DeviceDescriptor { required_features: timing::FEATURES, ..Default::default() }",
        "wgpu::DeviceDescriptor { required_features: timing::FEATURES, ..crate::device_descriptor(&adapter) }",
        1,
    ),
    (
        "uniform_limits.rs",
        "max_uniform_buffer_binding_size: 65_536, ..Default::default() }",
        "max_uniform_buffer_binding_size: 65_536, ..crate::device_limits(&adapter) }",
        1,
    ),
];

fn main() {
    let manifest = env::var("CARGO_MANIFEST_DIR").unwrap();
    let src = Path::new(&manifest).join("../../sources/photocraft-0.17.0/crates/gpu/tests/it");
    let out = Path::new(&env::var("OUT_DIR").unwrap()).join("it");
    fs::create_dir_all(&out).unwrap();
    println!("cargo:rerun-if-changed={}", src.display());

    // the modules main.rs declares; anything else in it besides GPU_LOCK is new upstream
    let main = fs::read_to_string(src.join("main.rs")).unwrap();
    let mut mods = String::new();
    for line in main.lines() {
        let line = line.trim();
        if let Some(name) = line.strip_prefix("mod ").and_then(|l| l.strip_suffix(';')) {
            let file = format!("{name}.rs");
            let mut text = fs::read_to_string(src.join(&file)).unwrap();
            println!("cargo:rerun-if-changed={}", src.join(&file).display());
            for (f, from, to, n) in REWRITES.iter().filter(|r| r.0 == file) {
                let found = text.matches(from).count();
                assert_eq!(found, *n, "{f}: {found} of \"{from}\", expected {n} (upstream changed)");
                text = text.replace(from, to);
            }
            assert!(!text.contains("DeviceDescriptor::default()"), "{file}: an unrewritten default device request");
            fs::write(out.join(&file), text).unwrap();
            mods.push_str(&format!("#[path = {:?}]\nmod {name};\n", out.join(&file).display().to_string()));
        } else {
            assert!(
                line.is_empty()
                    || line.starts_with("//")
                    || line == "static GPU_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());",
                "tests/it/main.rs has something new: {line}"
            );
        }
    }
    for (f, ..) in REWRITES {
        assert!(main.contains(&format!("mod {};", f.trim_end_matches(".rs"))), "tests/it/main.rs no longer has {f}");
    }
    fs::write(out.join("mods.rs"), mods).unwrap();
}
