// bench.js — a small CPU workload for the SpiderMonkey shell: the same results in every JIT mode,
// different times. Prints "bench <name> <ms> ms sum=<n>" per workload and "bench checksum <n>".
//   js bench.js                      (Baseline + Ion)
//   js --no-ion bench.js             (interpreter + Baseline)
//   js --no-jit-backend bench.js     (interpreters only)
const now = () => Date.now();
const results = [];

function run(name, fn) {
  const t0 = now();
  const sum = fn() >>> 0;
  results.push(sum);
  print(`bench ${name} ${now() - t0} ms sum=${sum}`);
}

// recursive calls
function fib(n) {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
}
run("fib", () => fib(25));

// typed arrays, integer arithmetic, sort
run("array", () => {
  const a = new Int32Array(200000);
  let x = 12345;
  for (let i = 0; i < a.length; i++) {
    x = (Math.imul(x, 1103515245) + 12345) | 0;
    a[i] = x >> 8;
  }
  a.sort();
  let s = 0;
  for (let i = 0; i < a.length; i += 7) {
    s = (s + a[i] * (i & 15)) | 0;
  }
  return s;
});

// objects, property access, floating point
run("objects", () => {
  const pts = [];
  for (let i = 0; i < 30000; i++) {
    pts.push({ x: Math.sin(i) * 100, y: Math.cos(i) * 100 });
  }
  let s = 0;
  for (let k = 0; k < 10; k++) {
    for (const p of pts) {
      s += Math.sqrt(p.x * p.x + p.y * p.y);
    }
  }
  return Math.round(s);
});

// strings, regexps, JSON
run("string", () => {
  let text = "";
  for (let i = 0; i < 4000; i++) {
    text += `item-${i}:${(i * 7) % 13};`;
  }
  let s = 0;
  for (let k = 0; k < 4; k++) {
    for (const m of text.matchAll(/item-(\d+):(\d+);/g)) {
      s = (s + Number(m[1]) * Number(m[2])) | 0;
    }
    const parsed = JSON.parse(JSON.stringify(text.split(";").slice(0, 500)));
    s = (s + parsed.join("").length) | 0;
  }
  return s;
});

let checksum = 0;
for (const r of results) {
  checksum = (Math.imul(checksum, 31) + r) >>> 0;
}
print(`bench checksum ${checksum}`);
