/*
 * spalign.c — arm64: check that a user fault that the kernel does not route to a
 * specific handler delivers a signal to the program instead of panicking the
 * kernel (HK-01 and the SP-alignment class, EC 0x26).
 *
 * Each case runs in a child so the parent survives it. A case passes when the
 * child dies of the expected signal (SIGBUS for a misaligned stack pointer,
 * SIGILL for an undefined instruction, a __builtin_trap() or an SVE
 * instruction). If the kernel still panics, the whole machine stops here
 * instead and nothing below prints; that is the failure this test is for.
 *
 * The SVE case reaches the kernel's catch-all for exception classes it has no
 * case for: on a CPU with SVE (QEMU -cpu neoverse-v1) whose kernel leaves
 * CPACR_EL1.ZEN clear, it traps as EC 0x19; on a Cortex-A72 it is just an
 * undefined instruction (EC 0).
 *
 * Build (cross): $tp-gcc --sysroot=SYSROOT -O2 -o spalign tools/haiku-tests/spalign.c
 * Prints one line per case and "SPALIGN end"; exit 0 iff no case failed (a
 * skipped case is counted on the end line).
 */
#include <sys/wait.h>
#include <unistd.h>

#include <OS.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

/* Run fn() in a child; return the signal that killed it, or 0 if it exited. */
static int
run_child(void (*fn)(void))
{
	pid_t pid = fork();
	if (pid < 0) {
		perror("fork");
		exit(2);
	}
	if (pid == 0) {
		// die of the signal directly instead of stopping in debug_server, so
		// the parent's waitpid() sees the terminating signal
		disable_debugger(1);
		fn();
		_exit(0);
	}
	int status = 0;
	while (waitpid(pid, &status, 0) < 0)
		;
	if (WIFSIGNALED(status))
		return WTERMSIG(status);
	return 0;
}

static void
case_sp_misalign(void)
{
	/*
	 * Move the stack pointer off a 16-byte boundary and touch memory through
	 * it. With SCTLR_EL1.SA0 set (the loader sets it) this raises an SP
	 * alignment fault (EC 0x26). The sub/add keep SP's value otherwise intact.
	 */
	__asm__ __volatile__(
		"mov x9, sp\n\t"
		"sub sp, sp, #1\n\t"
		"ldr x10, [sp]\n\t"
		"mov sp, x9\n\t"
		::: "x9", "x10", "memory");
}

static void
case_undefined(void)
{
	__asm__ __volatile__("udf #0");
}

static void
case_builtin_trap(void)
{
	__builtin_trap();
}

static void
case_sve(void)
{
	/* rdvl x0, #1 */
	__asm__ __volatile__(".inst 0x04bf5020" ::: "x0");
}

static int sSkipped = 0;

/* skipOnZero: a case that need not fault in every emulator (QEMU does not model
 * the SP alignment check) is a SKIP, not a FAIL, when no signal was raised. */
static int
check(const char* name, void (*fn)(void), int want, int skipOnZero)
{
	int got = run_child(fn);
	const char* verdict;
	int ok;
	if (got == want) {
		verdict = "PASS"; ok = 1;
	} else if (got == 0 && skipOnZero) {
		verdict = "SKIP (no fault raised here; QEMU does not model this check)";
		ok = 1;
		sSkipped++;
	} else {
		verdict = "FAIL"; ok = 0;
	}
	printf("SPALIGN %s: got signal %d, want %d -> %s\n",
		name, got, want, verdict);
	fflush(stdout);
	return ok;
}

int
main(void)
{
	int ok = 1;
	ok &= check("undefined-instruction", case_undefined, SIGILL, 0);
	ok &= check("builtin-trap", case_builtin_trap, SIGILL, 0);
	// SCTLR_EL1.SA0 makes a misaligned-SP access an SP alignment fault on real
	// hardware; QEMU does not model the check, so no signal there (SKIP).
	ok &= check("sp-misalign", case_sp_misalign, SIGBUS, 1);
	ok &= check("sve-instruction", case_sve, SIGILL, 0);
	printf("SPALIGN end: %s (%d skipped)\n", ok ? "PASS" : "FAIL", sSkipped);
	return ok ? 0 : 1;
}
