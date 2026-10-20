//! rust-clib: a Rust library with a C ABI, built both as a static and as a shared library and
//! called from main.c (tools/rust-tests/rust-clib/), the way Gecko links its Rust code (gkrust).
use std::collections::HashSet;
use std::ffi::{CStr, c_char};
use std::{fs, panic, slice, thread};

/// A static C string.
#[unsafe(no_mangle)]
pub extern "C" fn rust_clib_version() -> *const c_char {
    c"rust-clib 0.1.0".as_ptr()
}

/// The sum of `len` numbers at `data`, split over `threads` threads.
///
/// # Safety
/// `data` points to `len` readable u32s.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rust_sum_parallel(data: *const u32, len: usize, threads: u32) -> u64 {
    let v = unsafe { slice::from_raw_parts(data, len) };
    let chunk = len.div_ceil(threads.max(1) as usize).max(1);
    thread::scope(|s| {
        let parts: Vec<_> = v
            .chunks(chunk)
            .map(|c| s.spawn(move || c.iter().map(|&x| u64::from(x)).sum::<u64>()))
            .collect();
        parts.into_iter().map(|h| h.join().unwrap()).sum()
    })
}

/// 2 * n, or -1 if n < 0: a panic inside, caught before it reaches C.
#[unsafe(no_mangle)]
pub extern "C" fn rust_checked_double(n: i32) -> i32 {
    panic::catch_unwind(|| {
        assert!(n >= 0, "negative input {n}");
        n * 2
    })
    .unwrap_or(-1)
}

/// The number of distinct words of a C string (a HashSet: needs the OS random source).
///
/// # Safety
/// `text` is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rust_distinct_words(text: *const c_char) -> usize {
    let s = unsafe { CStr::from_ptr(text) }.to_string_lossy();
    s.split_whitespace().collect::<HashSet<_>>().len()
}

/// Writes a formatted line to `path`, reads it back; returns its length, or -1.
///
/// # Safety
/// `path` is a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rust_file_roundtrip(path: *const c_char, x: f64) -> i64 {
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();
    let line = format!("pi is about {x:.5}\n");
    if fs::write(&path, &line).is_err() {
        return -1;
    }
    match fs::read_to_string(&path) {
        Ok(back) if back == line => back.len() as i64,
        _ => -1,
    }
}
