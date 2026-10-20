// misc.js — the platform pieces of the shell: build configuration, Intl (bundled ICU data) and the
// time zone (Haiku's DateTime.cpp asks BLocaleRoster), deep recursion stopping with an exception
// (the native stack base from get_thread_info), promises, GC, helper-thread compilation.
// Prints "misc ..." lines and "misc OK".
const conf = getBuildConfiguration();
print(`misc arm64=${conf["arm64"]} debug=${conf["debug"]} release=${conf["release_or_beta"]}`);

const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
print(`misc timezone=${tz} date=${new Date(0).toISOString()}`);
const de = new Intl.NumberFormat("de-DE").format(1234567.891);
if (de !== "1.234.567,891") {
  throw new Error(`misc: Intl de-DE ${de}`);
}
print(`misc intl de-DE=${de} ${new Intl.DateTimeFormat("en-US", { timeZone: "UTC" }).format(0)}`);

let depth = 0;
function recurse() {
  depth++;
  recurse();
}
try {
  recurse();
  throw new Error("misc: unbounded recursion did not stop");
} catch (e) {
  if (!(e instanceof InternalError)) {
    throw e;
  }
  print(`misc recursion stopped at depth ${depth}: ${e.message}`);
}

let resolved = 0;
(async () => {
  for (let i = 0; i < 1000; i++) {
    resolved += await Promise.resolve(1);
  }
})();
drainJobQueue();
if (resolved !== 1000) {
  throw new Error(`misc: promises ${resolved}`);
}

let live = [];
for (let i = 0; i < 300000; i++) {
  live.push({ i, s: "x" + i });
  if (live.length > 10000) {
    live = [];
  }
}
gc();
print(`misc promises=${resolved} gc ok`);

// compile on a helper thread, run on the main thread
const job = offThreadCompileToStencil("globalThis.mulAdd = function (a, b) { return a * b + 1; };");
evalStencil(finishOffThreadStencil(job));
if (globalThis.mulAdd(6, 7) !== 43) {
  throw new Error("misc: off-thread compile");
}
print("misc off-thread compile ok");
print("misc OK");
