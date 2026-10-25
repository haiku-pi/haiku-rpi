//! photocraft-desktop-test — rfd's file dialogs and message dialogs and arboard's clipboard on Haiku,
//! as Photocraft uses them (docs/design/photocraft.md, P4).
//!
//!   photocraft-desktop-test [--no-wayland] COMMAND [ARGS...]
//!
//! First it connects to Haiku's in-process Wayland server, as the app does (dlopen of
//! libwayland-client.so.0, wl_display_connect(NULL)): the server makes the program's BApplication,
//! which the dialogs need. --no-wayland skips that (the dialogs must then answer "cancelled" at once).
//!
//!   clip-text-set TEXT | clip-text-get
//!   clip-html-set HTML ALT | clip-html-get
//!   clip-image-set W H | clip-image-get     (a test pattern; prints size and an FNV-1a hash of the RGBA)
//!   clip-files-set PATH... | clip-files-get
//!   clip-clear
//!   open DIR [--multiple] [EXT...]          (rfd::AsyncFileDialog, awaited on a helper thread, as the app)
//!   save DIR NAME [EXT...]
//!   folder DIR
//!   sync-open DIR [EXT...]                  (rfd::FileDialog, blocking)
//!   alert TITLE TEXT ok|okcancel|yesno|yesnocancel
//!   fonts                                   (fontdb's load_system_fonts: faces, families, a few names)
//!   jpeg-size FILE                          (a JPEG's width x height, from its SOF header)
//!   lock-hold FILE SECS | lock-try FILE     (std's File::try_lock, as Photocraft's single-instance lock:
//!                                           hold it, or try it: "locked", "would block", or the error)
//!   exit-during open|alert MS               (shows the dialog, exits with it open after MS ms: rfd's exit
//!                                           handler must hold the dialog's loopers)
//!
//! Output: "PDT <command>: <result>" lines on standard output; exit 0 unless the call failed.

use std::future::Future;
use std::path::PathBuf;
use std::sync::Arc;

fn say(command: &str, text: impl std::fmt::Display) {
    println!("PDT {command}: {text}");
}

/// Connects to the in-process Wayland server; the display stays open until the program exits.
fn connect_wayland() -> Result<(), String> {
    // SAFETY: dlopen/dlsym with valid C strings; wl_display_connect(NULL) has no other preconditions.
    unsafe {
        let lib = libc::dlopen(c"libwayland-client.so.0".as_ptr(), libc::RTLD_NOW | libc::RTLD_GLOBAL);
        if lib.is_null() {
            return Err("no libwayland-client.so.0".into());
        }
        let connect = libc::dlsym(lib, c"wl_display_connect".as_ptr());
        if connect.is_null() {
            return Err("no wl_display_connect".into());
        }
        let connect: extern "C" fn(*const libc::c_char) -> *mut libc::c_void = std::mem::transmute(connect);
        if connect(std::ptr::null()).is_null() {
            return Err("wl_display_connect(NULL) failed".into());
        }
    }
    Ok(())
}

/// Runs `future` to completion on this thread (Photocraft's `services::block_on`).
fn block_on<T>(future: impl Future<Output = T>) -> T {
    struct Unpark(std::thread::Thread);
    impl std::task::Wake for Unpark {
        fn wake(self: Arc<Self>) {
            self.0.unpark();
        }
    }
    let waker = std::task::Waker::from(Arc::new(Unpark(std::thread::current())));
    let mut cx = std::task::Context::from_waker(&waker);
    let mut future = std::pin::pin!(future);
    loop {
        if let std::task::Poll::Ready(value) = future.as_mut().poll(&mut cx) {
            return value;
        }
        std::thread::park();
    }
}

/// A test pattern: red rises along x, green along y, blue fixed, alpha in steps.
fn pattern(width: usize, height: usize) -> Vec<u8> {
    let mut rgba = Vec::with_capacity(width * height * 4);
    for y in 0..height {
        for x in 0..width {
            rgba.extend_from_slice(&[(x * 255 / width.max(1)) as u8, (y * 255 / height.max(1)) as u8, 0x5a, [255, 128, 0][(x + y) % 3]]);
        }
    }
    rgba
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325u64, |h, &b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

/// Shows an async dialog the way Photocraft does: made on this thread, awaited on another.
fn await_on_thread<T: Send + 'static>(future: impl Future<Output = T> + Send + 'static) -> T {
    std::thread::Builder::new()
        .name("file dialog".into())
        .spawn(move || block_on(future))
        .expect("thread")
        .join()
        .expect("join")
}

/// The width and height in a JPEG's first SOF segment (baseline, progressive, ...).
fn jpeg_size(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.get(..2)? != [0xff, 0xd8] {
        return None;
    }
    let mut i = 2;
    while i + 4 <= bytes.len() {
        if bytes[i] != 0xff {
            return None;
        }
        let marker = bytes[i + 1];
        let length = u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]) as usize;
        if matches!(marker, 0xc0..=0xcf) && !matches!(marker, 0xc4 | 0xc8 | 0xcc) {
            let sof = bytes.get(i + 4..i + 9)?;
            return Some((u16::from_be_bytes([sof[3], sof[4]]) as u32, u16::from_be_bytes([sof[1], sof[2]]) as u32));
        }
        i += 2 + length;
    }
    None
}

fn paths(list: Option<Vec<PathBuf>>) -> String {
    match list {
        Some(list) => list.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(" | "),
        None => "cancelled".into(),
    }
}

fn run(command: &str, args: &[String]) -> Result<(), String> {
    let arg = |i: usize| args.get(i).cloned().ok_or_else(|| format!("{command}: argument {} missing", i + 1));
    let clipboard = || arboard::Clipboard::new().map_err(|e| format!("Clipboard::new: {e}"));
    match command {
        "clip-text-set" => clipboard()?.set_text(arg(0)?).map_err(|e| e.to_string())?,
        "clip-text-get" => say(command, clipboard()?.get_text().map_err(|e| e.to_string())?),
        "clip-html-set" => clipboard()?.set_html(arg(0)?, Some(arg(1)?)).map_err(|e| e.to_string())?,
        "clip-html-get" => {
            let mut cb = clipboard()?;
            say(command, format!("html {:?}", cb.get().html().map_err(|e| e.to_string())?));
            say(command, format!("text {:?}", cb.get_text().map_err(|e| e.to_string())?));
        }
        "clip-image-set" => {
            let (w, h): (usize, usize) = (arg(0)?.parse().map_err(|_| "W")?, arg(1)?.parse().map_err(|_| "H")?);
            let rgba = pattern(w, h);
            say(command, format!("{w}x{h} fnv {:016x}", fnv1a(&rgba)));
            clipboard()?
                .set_image(arboard::ImageData { width: w, height: h, bytes: rgba.into() })
                .map_err(|e| e.to_string())?;
        }
        "clip-image-get" => {
            let image = clipboard()?.get_image().map_err(|e| e.to_string())?;
            let first: Vec<u8> = image.bytes.iter().take(4).copied().collect();
            say(command, format!("{}x{} fnv {:016x} first pixel {first:?}", image.width, image.height, fnv1a(&image.bytes)));
        }
        "clip-files-set" => clipboard()?.set().file_list(args).map_err(|e| e.to_string())?,
        "clip-files-get" => say(command, paths(Some(clipboard()?.get().file_list().map_err(|e| e.to_string())?))),
        "clip-clear" => clipboard()?.clear().map_err(|e| e.to_string())?,
        "open" | "save" | "folder" => {
            let mut dialog = rfd::AsyncFileDialog::new().set_directory(arg(0)?);
            let mut rest = &args[1..];
            let multiple = rest.first().is_some_and(|a| a == "--multiple");
            if multiple {
                rest = &rest[1..];
            }
            if command == "save" {
                dialog = dialog.set_file_name(arg(1)?);
                rest = &rest[1..];
            }
            if !rest.is_empty() {
                dialog = dialog.add_filter("Test files", rest);
            }
            let answer = match command {
                "open" if multiple => {
                    let picked = dialog.pick_files();
                    await_on_thread(async move { picked.await.map(|f| f.iter().map(|f| f.path().to_path_buf()).collect()) })
                }
                "open" => {
                    let picked = dialog.pick_file();
                    await_on_thread(async move { picked.await.map(|f| vec![f.path().to_path_buf()]) })
                }
                "save" => {
                    let picked = dialog.save_file();
                    await_on_thread(async move { picked.await.map(|f| vec![f.path().to_path_buf()]) })
                }
                _ => {
                    let picked = dialog.pick_folder();
                    await_on_thread(async move { picked.await.map(|f| vec![f.path().to_path_buf()]) })
                }
            };
            say(command, paths(answer));
        }
        "sync-open" => {
            let dialog = rfd::FileDialog::new().set_directory(arg(0)?).set_title("Sync open");
            let dialog = if args.len() > 1 { dialog.add_filter("Test files", &args[1..]) } else { dialog };
            say(command, paths(dialog.pick_file().map(|p| vec![p])));
        }
        "alert" => {
            let buttons = match arg(2)?.as_str() {
                "ok" => rfd::MessageButtons::Ok,
                "okcancel" => rfd::MessageButtons::OkCancel,
                "yesno" => rfd::MessageButtons::YesNo,
                "yesnocancel" => rfd::MessageButtons::YesNoCancel,
                other => return Err(format!("alert: no buttons {other}")),
            };
            let answer = rfd::MessageDialog::new()
                .set_title(arg(0)?)
                .set_description(arg(1)?)
                .set_level(rfd::MessageLevel::Warning)
                .set_buttons(buttons)
                .show();
            say(command, answer);
        }
        "fonts" => {
            let mut db = fontdb::Database::new();
            db.load_system_fonts();
            let mut families: Vec<String> = db.faces().filter_map(|f| f.families.first().map(|(n, _)| n.clone())).collect();
            families.sort();
            families.dedup();
            say(command, format!("{} faces, {} families", db.len(), families.len()));
            say(command, families.iter().take(12).cloned().collect::<Vec<_>>().join(", "));
        }
        "exit-during" => {
            let ms: u64 = arg(1)?.parse().map_err(|_| "MS")?;
            match arg(0)?.as_str() {
                "open" => {
                    let picked = rfd::AsyncFileDialog::new().set_directory("/boot/home").pick_file();
                    std::thread::spawn(move || block_on(picked));
                }
                "alert" => {
                    std::thread::spawn(|| rfd::MessageDialog::new().set_title("PDT exit").set_description("exiting").show());
                }
                other => return Err(format!("exit-during: no dialog {other}")),
            }
            std::thread::sleep(std::time::Duration::from_millis(ms));
            say(command, "exiting with the dialog open");
            std::process::exit(0);
        }
        "lock-hold" | "lock-try" => {
            let file = std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(arg(0)?).map_err(|e| e.to_string())?;
            match file.try_lock() {
                Ok(()) => say(command, "locked"),
                Err(std::fs::TryLockError::WouldBlock) => say(command, "would block"),
                Err(std::fs::TryLockError::Error(e)) => return Err(format!("try_lock: {e}")),
            }
            if command == "lock-hold" {
                let secs: u64 = arg(1)?.parse().map_err(|_| "SECS")?;
                std::thread::sleep(std::time::Duration::from_secs(secs));
            }
        }
        "jpeg-size" => {
            let (w, h) = jpeg_size(&std::fs::read(arg(0)?).map_err(|e| e.to_string())?).ok_or("not a JPEG")?;
            say(command, format!("{w}x{h}"));
        }
        _ => return Err(format!("no command {command}")),
    }
    Ok(())
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let wayland = args.first().is_none_or(|a| a != "--no-wayland");
    if !wayland {
        args.remove(0);
    }
    let Some(command) = args.first().cloned() else {
        eprintln!("usage: photocraft-desktop-test [--no-wayland] COMMAND [ARGS...]");
        std::process::exit(2);
    };
    if wayland {
        if let Err(e) = connect_wayland() {
            say(&command, format!("error: {e}"));
            std::process::exit(1);
        }
    }
    if let Err(e) = run(&command, &args[1..]) {
        say(&command, format!("error: {e}"));
        std::process::exit(1);
    }
    say(&command, "done");
}
