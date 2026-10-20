// Compile-time check of patches/rust-libc against the C side (layout.c): the arm64 Haiku
// mcontext_t / ucontext_t of the libc crate std was built with. scripts/build-rust.sh tests.
#![feature(rustc_private)]
#![no_main]
extern crate libc;
use std::mem::{align_of, offset_of, size_of};
const _: () = assert!(size_of::<libc::mcontext_t>() == 800);
const _: () = assert!(align_of::<libc::mcontext_t>() == 16);
const _: () = assert!(offset_of!(libc::mcontext_t, lr) == 240);
const _: () = assert!(offset_of!(libc::mcontext_t, elr) == 256);
const _: () = assert!(offset_of!(libc::mcontext_t, fp_q) == 272);
const _: () = assert!(offset_of!(libc::mcontext_t, fpsr) == 784);
const _: () = assert!(offset_of!(libc::mcontext_t, fpcr) == 788);
const _: () = assert!(size_of::<libc::ucontext_t>() == 848);
const _: () = assert!(offset_of!(libc::ucontext_t, uc_stack) == 16);
const _: () = assert!(offset_of!(libc::ucontext_t, uc_mcontext) == 48);
