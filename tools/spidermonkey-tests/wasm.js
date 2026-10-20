// wasm.js — WebAssembly: compile, run a loop, and trap on out-of-bounds loads. With huge memory
// (64-bit) the bounds checks are left out and an out-of-bounds load faults; the wasm signal handler
// must turn that fault into a WebAssembly.RuntimeError (else the shell dies with SIGSEGV).
// Prints "wasm ..." lines and "wasm OK".
//   js wasm.js; js --wasm-compiler=baseline wasm.js; js --wasm-compiler=optimizing wasm.js
if (!wasmIsSupported()) {
  throw new Error("wasm: not supported in this mode");
}
print(`wasm compiler=${wasmCompileMode()} hugeMemory=${wasmHugeMemoryEnabled()}`);

const bytes = wasmTextToBinary(`(module
  (memory (export "mem") 1)
  (func (export "load") (param i32) (result i32) (i32.load (local.get 0)))
  (func (export "sum") (param $n i32) (result i32) (local $i i32) (local $s i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $s (i32.add (local.get $s) (i32.mul (local.get $i) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $s)))`);
const { exports } = new WebAssembly.Instance(new WebAssembly.Module(bytes));

const n = 5000000;
let expected = 0;
for (let i = 0; i < n; i++) {
  expected = (expected + Math.imul(i, i)) | 0;
}
const t0 = Date.now();
const got = exports.sum(n);
print(`wasm sum ${Date.now() - t0} ms sum=${got >>> 0}`);
if (got !== expected) {
  throw new Error(`wasm: sum ${got}, expected ${expected}`);
}

new Int32Array(exports.mem.buffer)[1] = 0x12345678;
if (exports.load(4) !== 0x12345678) {
  throw new Error("wasm: load(4) wrong");
}

// out of bounds: just past the end of the 64 KiB memory, and far into the guard region
let traps = 0;
for (const address of [65536, 65534, 0x7fff0000, -16]) {
  try {
    exports.load(address);
    throw new Error(`wasm: load(${address}) did not trap`);
  } catch (e) {
    if (!(e instanceof WebAssembly.RuntimeError) || !/out of bounds/.test(e.message)) {
      throw e;
    }
    traps++;
  }
}
print(`wasm traps=${traps} (RuntimeError: index out of bounds)`);

// the instance still works after the traps
if (exports.load(4) !== 0x12345678) {
  throw new Error("wasm: broken after the traps");
}
print("wasm OK");
