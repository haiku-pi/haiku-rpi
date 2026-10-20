//! rust-smoke: the parts of Rust's std a port depends on, on Haiku arm64. One line per check,
//! "rust-smoke: <check> PASS|FAIL <detail>", then "rust-smoke: ALL PASS" (exit 0) or
//! "rust-smoke: N FAILED" (exit 1). Run as `rust-smoke alpha beta` (the args check expects them).
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{env, fs, panic, process, thread};

type Check = Result<String, String>;

fn args() -> Check {
    let a: Vec<String> = env::args().collect();
    if a.len() == 3 && a[1] == "alpha" && a[2] == "beta" {
        Ok(format!("{a:?}"))
    } else {
        Err(format!("{a:?}"))
    }
}

fn env_vars() -> Check {
    // SAFETY: single-threaded at this point (the checks run one after another)
    unsafe { env::set_var("RUST_SMOKE_VAR", "42") };
    let v = env::var("RUST_SMOKE_VAR").map_err(|e| e.to_string())?;
    let home = env::var("HOME").unwrap_or_default();
    if v == "42" { Ok(format!("HOME={home}")) } else { Err(v) }
}

fn threads() -> Check {
    let counter = Arc::new(AtomicU64::new(0));
    let list = Arc::new(Mutex::new(Vec::new()));
    let (tx, rx) = mpsc::channel();
    let handles: Vec<_> = (0..8u64)
        .map(|i| {
            let (counter, list, tx) = (counter.clone(), list.clone(), tx.clone());
            thread::Builder::new()
                .name(format!("worker-{i}"))
                .spawn(move || {
                    for _ in 0..100_000 {
                        counter.fetch_add(1, Ordering::Relaxed);
                    }
                    list.lock().unwrap().push(i);
                    tx.send(thread::current().name().unwrap().to_string()).unwrap();
                    i * i
                })
                .unwrap()
        })
        .collect();
    drop(tx);
    let squares: u64 = handles.into_iter().map(|h| h.join().unwrap()).sum();
    let names = rx.iter().count();
    let n = counter.load(Ordering::SeqCst);
    let len = list.lock().unwrap().len();
    // scoped threads borrowing from this stack frame
    let mut data = [1u32; 64];
    thread::scope(|s| {
        for chunk in data.chunks_mut(16) {
            s.spawn(move || chunk.iter_mut().for_each(|x| *x *= 3));
        }
    });
    let scoped: u32 = data.iter().sum();
    if n == 800_000 && len == 8 && names == 8 && squares == 140 && scoped == 192 {
        Ok(format!("8 threads, counter {n}, scoped sum {scoped}"))
    } else {
        Err(format!("counter {n} list {len} names {names} squares {squares} scoped {scoped}"))
    }
}

fn filesystem() -> Check {
    let dir = env::temp_dir().join(format!("rust-smoke-{}", process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("sub")).map_err(|e| format!("create_dir_all: {e}"))?;
    let file = dir.join("sub/data.txt");
    let text = "Haiku arm64 says hello from Rust\n".repeat(1000);
    fs::write(&file, &text).map_err(|e| format!("write: {e}"))?;
    let mut f = fs::OpenOptions::new().append(true).open(&file).map_err(|e| format!("open: {e}"))?;
    f.write_all(b"tail\n").map_err(|e| format!("append: {e}"))?;
    drop(f);
    let back = fs::read_to_string(&file).map_err(|e| format!("read: {e}"))?;
    let meta = fs::metadata(&file).map_err(|e| format!("metadata: {e}"))?;
    fs::rename(&file, dir.join("moved.txt")).map_err(|e| format!("rename: {e}"))?;
    let entries = fs::read_dir(&dir).map_err(|e| format!("read_dir: {e}"))?.count();
    let canon = fs::canonicalize(&dir).map_err(|e| format!("canonicalize: {e}"))?;
    fs::remove_dir_all(&dir).map_err(|e| format!("remove_dir_all: {e}"))?;
    let ok = back.len() == text.len() + 5
        && back.ends_with("tail\n")
        && meta.len() == back.len() as u64
        && meta.modified().is_ok()
        && entries == 2
        && !dir.exists();
    if ok {
        Ok(format!("{} bytes in {}", meta.len(), canon.display()))
    } else {
        Err(format!("read {} meta {} entries {entries}", back.len(), meta.len()))
    }
}

fn tcp_loopback() -> Check {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| format!("bind: {e}"))?;
    let addr = listener.local_addr().map_err(|e| e.to_string())?;
    let server = thread::spawn(move || -> std::io::Result<()> {
        let (mut s, _) = listener.accept()?;
        let mut buf = [0u8; 64];
        let n = s.read(&mut buf)?;
        s.write_all(&buf[..n].to_ascii_uppercase())
    });
    let mut c = TcpStream::connect(addr).map_err(|e| format!("connect: {e}"))?;
    c.set_read_timeout(Some(Duration::from_secs(5))).map_err(|e| e.to_string())?;
    c.write_all(b"ping over loopback").map_err(|e| format!("write: {e}"))?;
    let mut reply = String::new();
    c.read_to_string(&mut reply).map_err(|e| format!("read: {e}"))?;
    server.join().unwrap().map_err(|e| format!("server: {e}"))?;
    if reply == "PING OVER LOOPBACK" { Ok(format!("echo via {addr}")) } else { Err(reply) }
}

fn tcp_timeout() -> Check {
    // nothing answers there: the connect must fail (timeout, or unreachable), and within bounds
    let addr: SocketAddr = "10.255.255.1:9".parse().unwrap();
    let start = Instant::now();
    let r = TcpStream::connect_timeout(&addr, Duration::from_secs(2));
    let took = start.elapsed();
    match r {
        Ok(_) => Err(format!("connected to {addr}?")),
        Err(e) if took < Duration::from_secs(10) => Ok(format!("{:?} after {} ms", e.kind(), took.as_millis())),
        Err(e) => Err(format!("{e} only after {} ms", took.as_millis())),
    }
}

fn time() -> Check {
    let start = Instant::now();
    thread::sleep(Duration::from_millis(150));
    let slept = start.elapsed();
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| e.to_string())?;
    // the Pi has no RTC: before an NTP sync the clock may be anywhere after the epoch
    if slept >= Duration::from_millis(150) && slept < Duration::from_secs(2) && now.as_secs() > 0 {
        Ok(format!("slept {} us, unix time {}", slept.as_micros(), now.as_secs()))
    } else {
        Err(format!("slept {slept:?}, unix time {now:?}"))
    }
}

fn unwinding() -> Check {
    let r = panic::catch_unwind(|| {
        let v: Vec<u32> = Vec::new();
        v[3]
    });
    match r {
        Err(e) => {
            let msg = e.downcast_ref::<String>().cloned().unwrap_or_default();
            Ok(format!("caught: {msg}"))
        }
        Ok(v) => Err(format!("no panic, got {v}")),
    }
}

fn hashmap() -> Check {
    // RandomState needs the OS random source
    let m: HashMap<String, usize> = (0..1000).map(|i| (format!("k{i}"), i)).collect();
    let sum: usize = m.values().sum();
    if sum == 499_500 && m["k777"] == 777 { Ok(format!("{} entries", m.len())) } else { Err(sum.to_string()) }
}

fn child_process() -> Check {
    let out = process::Command::new("/bin/sh")
        .args(["-c", "echo child $0; exit 3", "ok"])
        .output()
        .map_err(|e| format!("spawn: {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if out.status.code() == Some(3) && stdout == "child ok" {
        Ok(format!("status {}, stdout {stdout:?}", out.status))
    } else {
        Err(format!("status {:?}, stdout {stdout:?}", out.status))
    }
}

fn main() {
    // keep the default hook's message off the console for the expected panic
    panic::set_hook(Box::new(|_| {}));
    let checks: [(&str, fn() -> Check); 10] = [
        ("args", args),
        ("env", env_vars),
        ("threads", threads),
        ("fs", filesystem),
        ("tcp-loopback", tcp_loopback),
        ("tcp-timeout", tcp_timeout),
        ("time", time),
        ("unwind", unwinding),
        ("hashmap", hashmap),
        ("process", child_process),
    ];
    let mut failed = 0;
    for (name, check) in checks {
        match panic::catch_unwind(check) {
            Ok(Ok(detail)) => println!("rust-smoke: {name} PASS {detail}"),
            Ok(Err(detail)) => {
                failed += 1;
                println!("rust-smoke: {name} FAIL {detail}");
            }
            Err(_) => {
                failed += 1;
                println!("rust-smoke: {name} FAIL panicked");
            }
        }
    }
    if failed == 0 {
        println!("rust-smoke: ALL PASS");
    } else {
        println!("rust-smoke: {failed} FAILED");
        process::exit(1);
    }
}
