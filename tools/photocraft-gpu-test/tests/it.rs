//! photocraft-gpu's integration tests (sources/photocraft/crates/gpu/tests/it, copied by build.rs)
//! with the device the app requests.

/// As in the upstream main.rs: concurrent wgpu instances in one process crash some drivers, so a
/// test that creates a device holds this lock until the device is dropped.
static GPU_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// The app's device limits (crates/ui-egui `gpu_canvas::device_limits`): wgpu's defaults (WebGL2's
/// on GL) lowered to what the adapter supports, and the adapter's own texture and buffer sizes.
pub fn device_limits(adapter: &wgpu::Adapter) -> wgpu::Limits {
    let supported = adapter.limits();
    let base = if adapter.get_info().backend == wgpu::Backend::Gl { wgpu::Limits::downlevel_webgl2_defaults() } else { wgpu::Limits::default() };
    let base = base.or_worse_values_from(&supported);
    wgpu::Limits { max_texture_dimension_2d: supported.max_texture_dimension_2d, max_buffer_size: supported.max_buffer_size, ..base }
}

/// The app's device request without its optional timestamp feature (the timing tests ask for it).
pub fn device_descriptor(adapter: &wgpu::Adapter) -> wgpu::DeviceDescriptor<'static> {
    wgpu::DeviceDescriptor { label: Some("photocraft-gpu-it"), required_limits: device_limits(adapter), ..Default::default() }
}

include!(concat!(env!("OUT_DIR"), "/it/mods.rs"));
