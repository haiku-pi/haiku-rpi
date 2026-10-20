/* The arm64 Haiku mcontext_t / ucontext_t layout that layout.rs expects of the libc crate,
 * checked against the Haiku headers. scripts/build-rust.sh tests. */
#include <signal.h>
#include <stddef.h>
_Static_assert(sizeof(mcontext_t) == 800, "mc");
_Static_assert(offsetof(mcontext_t, lr) == 240, "lr");
_Static_assert(offsetof(mcontext_t, sp) == 248, "sp");
_Static_assert(offsetof(mcontext_t, elr) == 256, "elr");
_Static_assert(offsetof(mcontext_t, spsr) == 264, "spsr");
_Static_assert(offsetof(mcontext_t, fp_q) == 272, "fpq");
_Static_assert(offsetof(mcontext_t, fpsr) == 784, "fpsr");
_Static_assert(offsetof(mcontext_t, fpcr) == 788, "fpcr");
_Static_assert(_Alignof(mcontext_t) == 16, "al");
_Static_assert(sizeof(ucontext_t) == 848, "uc");
_Static_assert(offsetof(ucontext_t, uc_sigmask) == 8, "ucs");
_Static_assert(offsetof(ucontext_t, uc_stack) == 16, "ucst");
_Static_assert(offsetof(ucontext_t, uc_mcontext) == 48, "ucm");
_Static_assert(sizeof(sigset_t) == 8, "ss");
_Static_assert(sizeof(stack_t) == 24, "st");
int layout_ok;
