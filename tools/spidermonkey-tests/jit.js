// jit.js — which tiers actually ran: a hot loop asks the shell whether it runs in JIT code
// (inJit: Baseline or Ion) and in Ion (inIon). Prints "jit baseline=<bool> ion=<bool>".
// The bootscript checks: default mode ion=true; --no-ion baseline=true ion=false;
// --no-jit-backend baseline=false ion=false.
function hot(i) {
  return [inJit() === true, inIon() === true, i * 2];
}

let baseline = false;
let ion = false;
let s = 0;
for (let i = 0; i < 200000; i++) {
  const [j, o, v] = hot(i);
  baseline ||= j;
  ion ||= o;
  s += v;
}
if (s !== 199999 * 200000) {
  throw new Error(`jit: wrong sum ${s}`);
}
print(`jit baseline=${baseline} ion=${ion}`);
