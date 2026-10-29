/* armdbg.c — user debugging on arm64 through the debug nub API (install_team_debugger(), the nub port's
 * messages), the way Haiku's Debugger uses it. `armdbg` starts itself as a child team with the
 * debugger installed and drives it through numbered phases (a breakpoint on phase()):
 *   hwbreak   a (hardware) breakpoint on a function called 3 times: 3 hits at its address, each continued
 *   step      a breakpoint, then 4 single steps through 4 `add w0, w0, #1`: the PC +4 and w0 +1 each time
 *   wwatch    a write watchpoint: hit before the store (memory still old), continued once, value stored
 *   rwatch    a read watchpoint: hit, continued once
 *   swbreak   more breakpoints than the CPU has hardware ones, so the last is a `brk #0` in the code: two
 *             hits, continued, the code reads back unchanged through the nub
 *   brk       a `brk #0` in the program's own code: a breakpoint hit at it, continued after it
 *   trap      `brk #0x3e8` (__builtin_trap) with a SIGILL handler: the handler runs (no debugger event)
 *   patch     code written through the nub (`mov w0, #2` over `mov w0, #1`): the new code runs
 * `armdbg nodebug` (no debugger): `brk #0` and `brk #0x3e8` each raise SIGILL at the instruction (with a
 * handler; without one the default debugger takes over, as for any crash).
 * Prints "PASS <case>" / "FAIL <case>: why" per case and "armdbg: N passed, M failed".
 */
#include <OS.h>
#include <debugger.h>
#include <image.h>
#include <stdarg.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- the debugged program ---- */

struct addresses {
	uint64_t phase, target, straight, target2, brk_site, patchme, watched, result, trap_result;
	uint64_t dummy[8];
};

volatile int gWatched;
volatile int gResult;
volatile int gTrapResult;
volatile int gSink;

__attribute__((noinline)) void phase(int n) { gSink = n; }
__attribute__((noinline)) void target(void) { gSink++; }
__attribute__((noinline)) void target2(void) { gSink += 2; }
#define DUMMY(n) __attribute__((noinline)) void dummy##n(void) { gSink = n; }
DUMMY(0) DUMMY(1) DUMMY(2) DUMMY(3) DUMMY(4) DUMMY(5) DUMMY(6) DUMMY(7)

int straight(int);
int patchme(void);
void brk_func(void);
extern char brk_site[];
void trap_func(void);
extern char trap_site[];
__asm__(
	".text\n"
	".global straight\n.type straight, %function\n.p2align 4\nstraight:\n"
	"	add w0, w0, #1\n	add w0, w0, #1\n	add w0, w0, #1\n	add w0, w0, #1\n	ret\n"
	".size straight, .-straight\n"
	".global patchme\n.type patchme, %function\n.p2align 4\npatchme:\n"
	"	mov w0, #1\n	ret\n"
	".size patchme, .-patchme\n"
	".global brk_func\n.type brk_func, %function\n.p2align 4\nbrk_func:\n"
	"	nop\n.global brk_site\nbrk_site:\n	brk #0\n	ret\n"
	".size brk_func, .-brk_func\n"
	".global trap_func\n.type trap_func, %function\n.p2align 4\ntrap_func:\n"
	"	nop\n.global trap_site\ntrap_site:\n	brk #0x3e8\n	ret\n"
	".size trap_func, .-trap_func\n");

static volatile uint64_t sSignalAddress;
static volatile int sSignal;

static void
sigill_handler(int sig, siginfo_t* info, void* context)
{
	ucontext_t* uc = context;
	sSignal = sig;
	sSignalAddress = (uint64_t)info->si_addr;
	uc->uc_mcontext.elr += 4;	/* continue after the brk */
}

static void
catch_sigill(void)
{
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_sigaction = sigill_handler;
	action.sa_flags = SA_SIGINFO;
	sigaction(SIGILL, &action, NULL);
}

static int
child_main(void)
{
	static struct addresses a;
	a.phase = (uint64_t)phase;
	a.target = (uint64_t)target;
	a.straight = (uint64_t)straight;
	a.target2 = (uint64_t)target2;
	a.brk_site = (uint64_t)brk_site;
	a.patchme = (uint64_t)patchme;
	a.watched = (uint64_t)&gWatched;
	a.result = (uint64_t)&gResult;
	a.trap_result = (uint64_t)&gTrapResult;
	void (*dummies[8])(void) = { dummy0, dummy1, dummy2, dummy3, dummy4, dummy5, dummy6, dummy7 };
	for (int i = 0; i < 8; i++)
		a.dummy[i] = (uint64_t)dummies[i];
	debugger((const char*)&a);
		/* the debugger reads the addresses (this team's images are relocated) */

	phase(1);
	for (int i = 0; i < 3; i++)
		target();
	phase(2);
	gResult = straight(10);
	phase(3);
	gWatched = 5;
	phase(4);
	gResult = gWatched;
	phase(5);
	target2();
	target2();
	phase(6);
	brk_func();
	phase(7);
	catch_sigill();
	trap_func();
	gTrapResult = sSignal == SIGILL && sSignalAddress == (uint64_t)trap_site ? 1 : -1;
	phase(8);
	gResult = patchme();
	phase(9);
	return 0;
}

static int
nodebug_main(void)
{
	int failed = 0;
	catch_sigill();
	sSignal = 0;
	brk_func();
	if (sSignal == SIGILL && sSignalAddress == (uint64_t)brk_site)
		printf("PASS nodebug-brk0: SIGILL at the brk\n");
	else {
		printf("FAIL nodebug-brk0: signal %d at %#llx (brk at %p)\n", sSignal,
			(unsigned long long)sSignalAddress, brk_site);
		failed++;
	}
	sSignal = 0;
	trap_func();
	if (sSignal == SIGILL && sSignalAddress == (uint64_t)trap_site)
		printf("PASS nodebug-trap: SIGILL at the brk #0x3e8\n");
	else {
		printf("FAIL nodebug-trap: signal %d at %#llx (brk at %p)\n", sSignal,
			(unsigned long long)sSignalAddress, trap_site);
		failed++;
	}
	return failed;
}

/* ---- the debugger ---- */

static port_id sDebuggerPort, sNubPort, sReplyPort;
static thread_id sThread;
static int sPassed, sFailed;
static struct addresses sA;

static void
result(int ok, const char* name, const char* format, ...)
{
	char why[256] = "";
	va_list args;
	va_start(args, format);
	vsnprintf(why, sizeof(why), format, args);
	va_end(args);
	if (ok) {
		sPassed++;
		printf("PASS %s%s%s\n", name, why[0] ? ": " : "", why);
	} else {
		sFailed++;
		printf("FAIL %s: %s\n", name, why);
	}
	fflush(stdout);
}

static int32
next_event(debug_debugger_message_data* m)
{
	int32 code;
	ssize_t size = read_port_etc(sDebuggerPort, &code, m, sizeof(*m), B_RELATIVE_TIMEOUT,
		10000000);
	if (size < 0)
		return -1;
	if (code != B_DEBUGGER_MESSAGE_TEAM_DELETED)
		sThread = m->origin.thread;
	return code;
}

static void
send(int32 code, const void* message, size_t size)
{
	write_port(sNubPort, code, message, size);
}

static void
cont(bool singleStep)
{
	debug_nub_continue_thread m = { sThread, B_THREAD_DEBUG_HANDLE_EVENT, singleStep };
	send(B_DEBUG_MESSAGE_CONTINUE_THREAD, &m, sizeof(m));
}

static status_t
reply_status(void)
{
	int32 code;
	status_t error;
	if (read_port_etc(sReplyPort, &code, &error, sizeof(error), B_RELATIVE_TIMEOUT, 5000000) < 0)
		return B_TIMED_OUT;
	return error;
}

static status_t
set_breakpoint(uint64_t address)
{
	debug_nub_set_breakpoint m = { sReplyPort, (void*)address };
	send(B_DEBUG_MESSAGE_SET_BREAKPOINT, &m, sizeof(m));
	return reply_status();
}

static void
clear_breakpoint(uint64_t address)
{
	debug_nub_clear_breakpoint m = { (void*)address };
	send(B_DEBUG_MESSAGE_CLEAR_BREAKPOINT, &m, sizeof(m));
}

static status_t
set_watchpoint(uint64_t address, uint32 type, int32 length)
{
	debug_nub_set_watchpoint m = { sReplyPort, (void*)address, type, length };
	send(B_DEBUG_MESSAGE_SET_WATCHPOINT, &m, sizeof(m));
	return reply_status();
}

static void
clear_watchpoint(uint64_t address)
{
	debug_nub_clear_watchpoint m = { (void*)address };
	send(B_DEBUG_MESSAGE_CLEAR_WATCHPOINT, &m, sizeof(m));
}

static ssize_t
read_memory(uint64_t address, void* buffer, int32 size)
{
	debug_nub_read_memory m = { sReplyPort, (void*)address, size };
	send(B_DEBUG_MESSAGE_READ_MEMORY, &m, sizeof(m));
	static debug_nub_read_memory_reply reply;
	int32 code;
	if (read_port_etc(sReplyPort, &code, &reply, sizeof(reply), B_RELATIVE_TIMEOUT, 5000000) < 0)
		return B_TIMED_OUT;
	if (reply.error != B_OK)
		return reply.error;
	memcpy(buffer, reply.data, reply.size);
	return reply.size;
}

static status_t
write_memory(uint64_t address, const void* data, int32 size)
{
	static debug_nub_write_memory m;
	m.reply_port = sReplyPort;
	m.address = (void*)address;
	m.size = size;
	memcpy(m.data, data, size);
	send(B_DEBUG_MESSAGE_WRITE_MEMORY, &m, sizeof(m));
	debug_nub_write_memory_reply reply;
	int32 code;
	if (read_port_etc(sReplyPort, &code, &reply, sizeof(reply), B_RELATIVE_TIMEOUT, 5000000) < 0)
		return B_TIMED_OUT;
	return reply.error != B_OK ? reply.error : reply.size == size ? B_OK : B_ERROR;
}

static int
read_int(uint64_t address)
{
	int value = -12345;
	read_memory(address, &value, sizeof(value));
	return value;
}

/* Waits for the breakpoint at phase(); returns the phase number, -1 on anything else */
static int
wait_phase(debug_debugger_message_data* m, const char* context)
{
	int32 code = next_event(m);
	if (code == B_DEBUGGER_MESSAGE_BREAKPOINT_HIT
		&& m->breakpoint_hit.cpu_state.elr == sA.phase)
		return (int)m->breakpoint_hit.cpu_state.x[0];
	if (code == B_DEBUGGER_MESSAGE_TEAM_DELETED) {
		printf("armdbg: %s: the team ended (status %#x, signal %d) instead of phase()\n", context,
			(unsigned)m->team_deleted.status, m->team_deleted.signal);
	} else {
		printf("armdbg: %s: event %d (pc %#llx) instead of phase()\n", context, (int)code,
			code >= 0 ? (unsigned long long)m->breakpoint_hit.cpu_state.elr : 0ULL);
	}
	return -1;
}

static int
debugger_main(const char* self)
{
	const char* args[] = { self, "child", NULL };
	extern char** environ;
	thread_id child = load_image(2, args, (const char**)environ);
	if (child < 0) {
		printf("FAIL load: %s\n", strerror(child));
		return 1;
	}
	thread_info info;
	get_thread_info(child, &info);
	team_id team = info.team;

	sDebuggerPort = create_port(10, "armdbg debugger");
	sReplyPort = create_port(10, "armdbg reply");
	sNubPort = install_team_debugger(team, sDebuggerPort);
	if (sNubPort < 0) {
		printf("FAIL install_team_debugger: %s\n", strerror(sNubPort));
		kill_team(team);
		return 1;
	}
	resume_thread(child);

	debug_debugger_message_data m;
	int32 code = next_event(&m);
	if (code != B_DEBUGGER_MESSAGE_DEBUGGER_CALL
		|| read_memory((uint64_t)m.debugger_call.message, &sA, sizeof(sA)) != sizeof(sA)) {
		printf("FAIL start: event %d instead of the debugger() call\n", (int)code);
		kill_team(team);
		return 1;
	}
	status_t error = set_breakpoint(sA.phase);
	if (error != B_OK) {
		printf("FAIL start: breakpoint on phase(): %s\n", strerror(error));
		kill_team(team);
		return 1;
	}
	cont(false);

	int n = wait_phase(&m, "start");

	/* hwbreak: a breakpoint (the first ones are the CPU's), hit 3 times */
	if (n == 1) {
		error = set_breakpoint(sA.target);
		cont(false);
		int hits = 0, bad = 0;
		for (;;) {
			code = next_event(&m);
			if (code != B_DEBUGGER_MESSAGE_BREAKPOINT_HIT)
				break;
			if (m.breakpoint_hit.cpu_state.elr == sA.phase)
				break;
			if (m.breakpoint_hit.cpu_state.elr == sA.target)
				hits++;
			else
				bad++;
			if (hits + bad > 10)
				break;
			cont(false);
		}
		n = code == B_DEBUGGER_MESSAGE_BREAKPOINT_HIT && m.breakpoint_hit.cpu_state.elr == sA.phase
			? (int)m.breakpoint_hit.cpu_state.x[0] : -1;
		result(error == B_OK && hits == 3 && bad == 0 && n == 2, "hwbreak",
			"set %s, %d hits at target(), %d elsewhere, then phase %d", strerror(error), hits, bad, n);
		clear_breakpoint(sA.target);
	}

	/* step: breakpoint on straight(), 4 single steps */
	if (n == 2) {
		error = set_breakpoint(sA.straight);
		cont(false);
		code = next_event(&m);
		int ok = error == B_OK && code == B_DEBUGGER_MESSAGE_BREAKPOINT_HIT
			&& m.breakpoint_hit.cpu_state.elr == sA.straight && m.breakpoint_hit.cpu_state.x[0] == 10;
		char trace[200] = "";
		for (int i = 1; ok && i <= 4; i++) {
			cont(true);
			code = next_event(&m);
			uint64_t pc = m.single_step.cpu_state.elr;
			uint64_t x0 = m.single_step.cpu_state.x[0];
			snprintf(trace + strlen(trace), sizeof(trace) - strlen(trace), " +%lld:w0=%lld",
				(long long)(pc - sA.straight), (long long)x0);
			ok = code == B_DEBUGGER_MESSAGE_SINGLE_STEP && pc == sA.straight + 4 * i
				&& x0 == 10 + (uint64_t)i;
		}
		clear_breakpoint(sA.straight);
		cont(false);
		n = wait_phase(&m, "step");
		result(ok && n == 3 && read_int(sA.result) == 14, "step", "4 steps:%s, result %d",
			trace, read_int(sA.result));
	}

	/* wwatch: a write watchpoint */
	if (n == 3) {
		error = set_watchpoint(sA.watched, B_DATA_WRITE_WATCHPOINT, 4);
		cont(false);
		code = next_event(&m);
		int hit = code == B_DEBUGGER_MESSAGE_WATCHPOINT_HIT;
		int before = read_int(sA.watched);
		if (code >= 0)
			cont(false);
		n = wait_phase(&m, "wwatch");
		int after = read_int(sA.watched);
		result(error == B_OK && hit && before == 0 && n == 4 && after == 5, "wwatch",
			"set %s, event %d, value at the hit %d, then phase %d, value %d", strerror(error),
			(int)code, before, n, after);
		clear_watchpoint(sA.watched);
	}

	/* rwatch: a read watchpoint */
	if (n == 4) {
		error = set_watchpoint(sA.watched, B_DATA_READ_WATCHPOINT, 4);
		cont(false);
		code = next_event(&m);
		int hit = code == B_DEBUGGER_MESSAGE_WATCHPOINT_HIT;
		if (code >= 0)
			cont(false);
		n = wait_phase(&m, "rwatch");
		result(error == B_OK && hit && n == 5 && read_int(sA.result) == 5, "rwatch",
			"set %s, event %d, then phase %d, read %d", strerror(error), (int)code, n,
			read_int(sA.result));
		clear_watchpoint(sA.watched);
	}

	/* swbreak: the hardware breakpoints used up by functions never called */
	if (n == 5) {
		uint32_t before, after;
		read_memory(sA.target2, &before, 4);
		int dummiesSet = 0;
		for (int i = 0; i < 8; i++)
			dummiesSet += set_breakpoint(sA.dummy[i]) == B_OK;
		error = set_breakpoint(sA.target2);
		read_memory(sA.target2, &after, 4);
		cont(false);
		int hits = 0, bad = 0;
		for (;;) {
			code = next_event(&m);
			if (code != B_DEBUGGER_MESSAGE_BREAKPOINT_HIT || m.breakpoint_hit.cpu_state.elr == sA.phase)
				break;
			if (m.breakpoint_hit.cpu_state.elr == sA.target2)
				hits++;
			else
				bad++;
			if (hits + bad > 10)
				break;
			cont(false);
		}
		n = code == B_DEBUGGER_MESSAGE_BREAKPOINT_HIT && m.breakpoint_hit.cpu_state.elr == sA.phase
			? (int)m.breakpoint_hit.cpu_state.x[0] : -1;
		for (int i = 0; i < 8; i++)
			clear_breakpoint(sA.dummy[i]);
		clear_breakpoint(sA.target2);
		uint32_t cleared;
		read_memory(sA.target2, &cleared, 4);
		result(error == B_OK && dummiesSet == 8 && hits == 2 && bad == 0 && n == 6
				&& before == after && cleared == before,
			"swbreak", "9 set (%d), %d hits at target2(), %d elsewhere, then phase %d; code %08x/%08x/%08x",
			dummiesSet + (error == B_OK), hits, bad, n, before, after, cleared);
	}

	/* brk: the program's own brk #0 */
	if (n == 6) {
		cont(false);
		code = next_event(&m);
		int hit = code == B_DEBUGGER_MESSAGE_BREAKPOINT_HIT
			&& m.breakpoint_hit.cpu_state.elr == sA.brk_site;
		uint64_t pc = code >= 0 ? m.breakpoint_hit.cpu_state.elr : 0;
		if (code >= 0 && pc != sA.phase)
			cont(false);
		n = pc == sA.phase ? (int)m.breakpoint_hit.cpu_state.x[0] : wait_phase(&m, "brk");
		result(hit && n == 7, "brk", "event %d at %#llx (brk at %#llx), then phase %d", (int)code,
			(unsigned long long)pc, (unsigned long long)sA.brk_site, n);
	}

	/* trap: brk #0x3e8 with a SIGILL handler: the handler runs, no event */
	if (n == 7) {
		cont(false);
		n = wait_phase(&m, "trap");
		int trapResult = read_int(sA.trap_result);
		result(n == 8 && trapResult == 1, "trap", "phase %d, the handler's result %d", n, trapResult);
	}

	/* patch: new code written through the nub */
	if (n == 8) {
		uint32_t movW0_2 = 0x52800040;
		error = write_memory(sA.patchme, &movW0_2, 4);
		cont(false);
		n = wait_phase(&m, "patch");
		int value = read_int(sA.result);
		result(error == B_OK && n == 9 && value == 2, "patch", "write %s, phase %d, patchme() %d",
			strerror(error), n, value);
	}

	if (n == 9) {
		clear_breakpoint(sA.phase);
		cont(false);
		code = next_event(&m);
		result(code == B_DEBUGGER_MESSAGE_TEAM_DELETED && m.team_deleted.status == 0, "exit",
			"event %d, status %d", (int)code,
			code == B_DEBUGGER_MESSAGE_TEAM_DELETED ? (int)m.team_deleted.status : -1);
	} else {
		printf("FAIL sequence: stopped at phase %d\n", n);
		sFailed++;
		kill_team(team);
	}

	printf("armdbg: %d passed, %d failed\n", sPassed, sFailed);
	return sFailed != 0;
}

int
main(int argc, char** argv)
{
	if (argc > 1 && strcmp(argv[1], "child") == 0)
		return child_main();
	if (argc > 1 && strcmp(argv[1], "nodebug") == 0)
		return nodebug_main();
	return debugger_main(argv[0]);
}
