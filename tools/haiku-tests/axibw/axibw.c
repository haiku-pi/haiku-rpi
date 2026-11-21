/*
 * axibw.c — reads the BCM2711 system AXI bandwidth monitor: how many read/write transactions each bus master
 * (HVS scan-out, the CPUs, the network DMA, ...) put on the memory fabric in a time window. Root only: the
 * registers are reached through /dev/misc/mem (Haiku's "mem" driver maps the physical page uncached, as
 * Device memory, for every call; one 4-byte read or write per register).
 *
 *   axibw [-i MS] [-d SECS] [-q] SEL [SEL [SEL]]   up to three watchers, one line per window of MS ms
 *                                                  (default 1000) for SECS seconds (default 10), then totals
 *   axibw scan [-i MS] [-f FILTER] [FROM [TO]]     every selector FROM..TO (default 0..63), three at a time,
 *                                                  one window each
 *   axibw selftest                                 an idle window and a memcpy window on ARM_UC/ARM_L2/HVS:
 *                                                  transactions per copied MiB (calibrates bytes/transaction)
 *
 * SEL is a bus selector (0-63, or a name: hvs, argon, peripheral, arm_uc, ...), optionally with an AXI ID
 * filter after a slash: "5/v3d0", "11/30". Lines:
 *   "AXB <t> <dt_ms> <sel> R <reads> W <writes> A <addr>"   per watcher and window: raw transaction counts,
 *                                                         t = CLOCK_MONOTONIC seconds at the window's end
 *   "AXB total <sel> <secs> s: R <n>/s W <n>/s A <n>/s"   at the end (rates over all windows)
 * With -q only the totals. Counts are transactions, not bytes: bytes per transaction depends on the master's
 * burst size (calibrate it, see README.md).
 *
 * Hardware (BCM2711 system monitor at physical 0xfe009800, bus address 0x7e009800): a general control
 * register at +0 (bit 0 enable, bit 1 reset, bit 2 watch: without it nothing counts) and three bus watchers
 * at +0x40/+0x80/+0xc0, each a control register (bit 31 reset, bit 30 enable, bit 29 ID filter on,
 * bits 12:8 the ID, bits 5:0 the bus) followed by address/write/read transaction counters (31 bits) with
 * their wait and max counters. Each window is: reset the watcher, configure it, enable the monitor with the
 * watch bit, sleep, read.
 *
 * Build (cross, on the host):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -Wall -Wextra -o axibw tools/haiku-tests/axibw/axibw.c
 * Host check of the parsing and arithmetic against a simulated register file (no hardware):
 *   cc -O2 -Wall -Wextra -DAXIBW_SIMULATE -o axibw-sim tools/haiku-tests/axibw/axibw.c && ./axibw-sim selftest
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

#define MONITOR_BASE		0xfe009800u

#define GEN_CTRL			0x00
#define GEN_ENABLE			(1u << 0)
#define GEN_RESET			(1u << 1)
#define GEN_WATCH			(1u << 2)

#define WATCHER(n)			(0x40u * ((n) + 1))
#define WATCHERS			3
#define W_CTRL				0x00
#define W_ADDR_TRANS		0x04
#define W_WRITE_TRANS		0x10
#define W_READ_TRANS		0x1c
#define W_CTRL_RESET		(1u << 31)
#define W_CTRL_ENABLE		(1u << 30)
#define W_CTRL_ID_FILTER	(1u << 29)
#define W_CTRL_ID_SHIFT		8
#define W_CTRL_ID_MASK		0x1fu
#define W_CTRL_BUS_MASK		0x3fu
#define COUNTER_MASK		0x7fffffffu

/* bus selector values on BCM2711 (the vendor's system bus list) */
static const char* const kBusNames[] = {
	"dma_l2", "trans", "jpeg", "vpu_uc", "dma_uc", "system_l2", "hvs", "argon", "h264", "peripheral",
	"arm_uc", "arm_l2"
};
#define BUS_NAMES (int)(sizeof(kBusNames) / sizeof(kBusNames[0]))

/* AXI ID filter values on BCM2711 (the vendor's filter list) */
static const char* const kIdNames[32] = {
	"aio", "core0_v", "icache0", "dcache0", "core1_v", "icache1", "dcache1", "l2_main", "argon", "pcie",
	"hvs", "isp", "video_dct", "video_sd2axi", "cam0", "cam1", "dma0", "dma1", "dma2", "jpeg", "video_cme",
	"transposer", "video_fme", "gige", "usb", "v3d0", "v3d1", "v3d2", "gisb_axi", "debug", "arm", "emmcstb"
};

struct selector {
	int bus;		/* 0-63 */
	int id;			/* -1: no ID filter */
	char label[32];
};

struct counts {
	uint64_t reads, writes, addrs;
};


/* ---- register access ---------------------------------------------------------------------------- */

#ifndef AXIBW_SIMULATE

static int sMem = -1;

static void
reg_open(void)
{
	sMem = open("/dev/misc/mem", O_RDWR);
	if (sMem < 0) {
		fprintf(stderr, "axibw: /dev/misc/mem: %s (root only)\n", strerror(errno));
		exit(1);
	}
}

static uint32_t
reg_read(uint32_t offset)
{
	uint32_t value;
	if (pread(sMem, &value, 4, (off_t)(MONITOR_BASE + offset)) != 4) {
		fprintf(stderr, "axibw: read of 0x%08x: %s\n", MONITOR_BASE + offset, strerror(errno));
		exit(1);
	}
	return value;
}

static void
reg_write(uint32_t offset, uint32_t value)
{
	if (pwrite(sMem, &value, 4, (off_t)(MONITOR_BASE + offset)) != 4) {
		fprintf(stderr, "axibw: write of 0x%08x: %s\n", MONITOR_BASE + offset, strerror(errno));
		exit(1);
	}
}

#else	/* a register file that counts like the hardware, for checking this program on the host */

static uint32_t sRegs[0x100 / 4];
static double sEnabledAt[WATCHERS];

static double now(void);

static void
reg_open(void)
{
}

static uint32_t
reg_read(uint32_t offset)
{
	int w = offset / 0x40 - 1;
	uint32_t r = offset % 0x40;
	if (w >= 0 && w < WATCHERS && r != W_CTRL && (sRegs[GEN_CTRL / 4] & GEN_WATCH) != 0
		&& (sRegs[offset / 4 - r / 4] & W_CTRL_ENABLE) != 0) {
		/* bus b: (b + 1) million reads/s, half as many writes, an address per 4 data */
		double secs = now() - sEnabledAt[w];
		int bus = sRegs[offset / 4 - r / 4] & W_CTRL_BUS_MASK;
		double reads = (bus + 1) * 1e6 * secs;
		if (r == W_READ_TRANS)
			return (uint32_t)reads & COUNTER_MASK;
		if (r == W_WRITE_TRANS)
			return (uint32_t)(reads / 2) & COUNTER_MASK;
		if (r == W_ADDR_TRANS)
			return (uint32_t)(reads * 1.5 / 4) & COUNTER_MASK;
	}
	return sRegs[offset / 4];
}

static void
reg_write(uint32_t offset, uint32_t value)
{
	int w = offset / 0x40 - 1;
	sRegs[offset / 4] = value;
	if (offset == GEN_CTRL && (value & GEN_WATCH) != 0) {
		for (int i = 0; i < WATCHERS; i++)
			sEnabledAt[i] = now();
	}
	if (w >= 0 && w < WATCHERS && offset % 0x40 == W_CTRL && (value & W_CTRL_RESET) != 0)
		memset(&sRegs[offset / 4 + 1], 0, 0x3c);
}

#endif


/* ---- helpers ------------------------------------------------------------------------------------ */

static double
now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void
sleep_ms(int ms)
{
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
	while (nanosleep(&ts, &ts) != 0 && errno == EINTR)
		;
}

static int
lookup(const char* name, const char* const* names, int count)
{
	char* end;
	long value = strtol(name, &end, 0);
	if (*name != '\0' && *end == '\0')
		return (int)value;
	for (int i = 0; i < count; i++) {
		if (strcasecmp(name, names[i]) == 0)
			return i;
	}
	return -1;
}

static void
make_label(struct selector* sel)
{
	char bus[16];
	if (sel->bus < BUS_NAMES)
		snprintf(bus, sizeof(bus), "%s", kBusNames[sel->bus]);
	else
		snprintf(bus, sizeof(bus), "bus%d", sel->bus);
	if (sel->id >= 0)
		snprintf(sel->label, sizeof(sel->label), "%s/%s", bus, kIdNames[sel->id]);
	else
		snprintf(sel->label, sizeof(sel->label), "%s", bus);
}

static int
parse_selector(const char* text, struct selector* sel)
{
	char bus[32];
	const char* slash = strchr(text, '/');
	size_t length = slash != NULL ? (size_t)(slash - text) : strlen(text);
	if (length == 0 || length >= sizeof(bus))
		return -1;
	memcpy(bus, text, length);
	bus[length] = '\0';
	sel->bus = lookup(bus, kBusNames, BUS_NAMES);
	sel->id = slash != NULL ? lookup(slash + 1, kIdNames, 32) : -1;
	if (sel->bus < 0 || sel->bus > (int)W_CTRL_BUS_MASK || (slash != NULL && (sel->id < 0 || sel->id > 31)))
		return -1;
	make_label(sel);
	return 0;
}


/* ---- the monitor -------------------------------------------------------------------------------- */

/* One window: the watchers reset and configured, counting for ms milliseconds; returns its length (s). */
static double
window(const struct selector* sels, int count, int ms, struct counts* out)
{
	for (int i = 0; i < count; i++) {
		uint32_t ctrl = W_CTRL_ENABLE | (uint32_t)sels[i].bus;
		if (sels[i].id >= 0)
			ctrl |= W_CTRL_ID_FILTER | ((uint32_t)sels[i].id & W_CTRL_ID_MASK) << W_CTRL_ID_SHIFT;
		reg_write(WATCHER(i) + W_CTRL, W_CTRL_RESET);
		reg_write(WATCHER(i) + W_CTRL, ctrl);
	}
	reg_write(GEN_CTRL, GEN_ENABLE | GEN_WATCH);
	double start = now();
	sleep_ms(ms);
	for (int i = 0; i < count; i++) {
		/* (one register per call: the reads of a window are microseconds apart) */
		out[i].reads = reg_read(WATCHER(i) + W_READ_TRANS) & COUNTER_MASK;
		out[i].writes = reg_read(WATCHER(i) + W_WRITE_TRANS) & COUNTER_MASK;
		out[i].addrs = reg_read(WATCHER(i) + W_ADDR_TRANS) & COUNTER_MASK;
	}
	return now() - start;
}

static void
monitor_reset(void)
{
	reg_write(GEN_CTRL, GEN_RESET);
	reg_write(GEN_CTRL, 0);
}

static int
run_watch(struct selector* sels, int count, int ms, double secs, int quiet)
{
	struct counts total[WATCHERS] = { { 0, 0, 0 } };
	double elapsed = 0;
	monitor_reset();
	double end = now() + secs;
	while (now() < end) {
		struct counts c[WATCHERS];
		double dt = window(sels, count, ms, c);
		double t = now();
		elapsed += dt;
		for (int i = 0; i < count; i++) {
			total[i].reads += c[i].reads;
			total[i].writes += c[i].writes;
			total[i].addrs += c[i].addrs;
			if (!quiet) {
				printf("AXB %.3f %.1f %s R %llu W %llu A %llu\n", t, dt * 1000, sels[i].label,
					(unsigned long long)c[i].reads, (unsigned long long)c[i].writes,
					(unsigned long long)c[i].addrs);
			}
		}
		fflush(stdout);
	}
	monitor_reset();
	for (int i = 0; i < count; i++) {
		printf("AXB total %s %.2f s: R %.0f/s W %.0f/s A %.0f/s\n", sels[i].label, elapsed,
			total[i].reads / elapsed, total[i].writes / elapsed, total[i].addrs / elapsed);
	}
	return 0;
}


static int
run_scan(int from, int to, int id, int ms)
{
	monitor_reset();
	for (int bus = from; bus <= to; bus += WATCHERS) {
		struct selector sels[WATCHERS];
		struct counts c[WATCHERS];
		int count = 0;
		for (; count < WATCHERS && bus + count <= to; count++) {
			sels[count].bus = bus + count;
			sels[count].id = id;
			make_label(&sels[count]);
		}
		double dt = window(sels, count, ms, c);
		for (int i = 0; i < count; i++) {
			printf("AXB scan %d %s %.2f s: R %.0f/s W %.0f/s A %.0f/s\n", sels[i].bus, sels[i].label, dt,
				c[i].reads / dt, c[i].writes / dt, c[i].addrs / dt);
		}
		fflush(stdout);
	}
	monitor_reset();
	return 0;
}


/* memcpy for about a second while the CPU buses are watched, against an idle second */
static int
run_selftest(void)
{
	enum { MIB = 1024 * 1024, BUFFER = 32 * MIB };
	struct selector sels[WATCHERS];
	parse_selector("arm_uc", &sels[0]);
	parse_selector("arm_l2", &sels[1]);
	parse_selector("hvs", &sels[2]);
	char* a = malloc(BUFFER);
	char* b = malloc(BUFFER);
	if (a == NULL || b == NULL) {
		fprintf(stderr, "axibw: no memory\n");
		return 1;
	}
	memset(a, 1, BUFFER);
	memset(b, 2, BUFFER);

	monitor_reset();
	struct counts idle[WATCHERS], busy[WATCHERS];
	double idleSecs = window(sels, WATCHERS, 1000, idle);

	/* the busy window by hand: copy until a second has passed */
	for (int i = 0; i < WATCHERS; i++) {
		reg_write(WATCHER(i) + W_CTRL, W_CTRL_RESET);
		reg_write(WATCHER(i) + W_CTRL, W_CTRL_ENABLE | (uint32_t)sels[i].bus);
	}
	reg_write(GEN_CTRL, GEN_ENABLE | GEN_WATCH);
	double start = now();
	long copies = 0;
	while (now() - start < 1.0) {
		memcpy(copies % 2 ? a : b, copies % 2 ? b : a, BUFFER);
		copies++;
	}
	for (int i = 0; i < WATCHERS; i++) {
		busy[i].reads = reg_read(WATCHER(i) + W_READ_TRANS) & COUNTER_MASK;
		busy[i].writes = reg_read(WATCHER(i) + W_WRITE_TRANS) & COUNTER_MASK;
		busy[i].addrs = reg_read(WATCHER(i) + W_ADDR_TRANS) & COUNTER_MASK;
	}
	double busySecs = now() - start;
	monitor_reset();

	double mib = (double)copies * BUFFER / MIB;
	printf("AXB selftest: %ld copies of 32 MiB in %.2f s (%.0f MiB/s each way)\n", copies, busySecs,
		mib / busySecs);
	for (int i = 0; i < WATCHERS; i++) {
		/* rate-normalised: the busy window's count minus the idle rate over the busy window's length */
		double dr = busy[i].reads - idle[i].reads / idleSecs * busySecs;
		double dw = busy[i].writes - idle[i].writes / idleSecs * busySecs;
		printf("AXB selftest %s: idle R %.0f/s W %.0f/s; memcpy R %.0f/s W %.0f/s; extra per copied MiB "
			"R %.0f W %.0f (%.1f / %.1f bytes per transaction)\n", sels[i].label,
			idle[i].reads / idleSecs, idle[i].writes / idleSecs, busy[i].reads / busySecs,
			busy[i].writes / busySecs, dr / mib, dw / mib, dr > 1000 ? mib * MIB / dr : 0,
			dw > 1000 ? mib * MIB / dw : 0);
	}
	free(a);
	free(b);
	return 0;
}


static void
usage(void)
{
	fprintf(stderr,
		"usage: axibw [-i MS] [-d SECS] [-q] SEL [SEL [SEL]]\n"
		"       axibw scan [-i MS] [-f ID] [FROM [TO]]\n"
		"       axibw selftest\n"
		"SEL: bus (0-63 or name) [/ID filter (0-31 or name)]; buses:");
	for (int i = 0; i < BUS_NAMES; i++)
		fprintf(stderr, " %d=%s", i, kBusNames[i]);
	fprintf(stderr, "\n");
	exit(2);
}


int
main(int argc, char** argv)
{
	int ms = 1000, quiet = 0, id = -1;
	double secs = 10;
	int scan = argc > 1 && strcmp(argv[1], "scan") == 0;
	if (argc > 1 && strcmp(argv[1], "selftest") == 0) {
		reg_open();
		return run_selftest();
	}
	int opt;
	optind = scan ? 2 : 1;
	while ((opt = getopt(argc, argv, "i:d:qf:")) != -1) {
		switch (opt) {
			case 'i': ms = atoi(optarg); break;
			case 'd': secs = atof(optarg); break;
			case 'q': quiet = 1; break;
			case 'f':
				id = lookup(optarg, kIdNames, 32);
				if (id < 0 || id > 31)
					usage();
				break;
			default: usage();
		}
	}
	if (ms < 10 || ms > 10000 || secs <= 0)
		usage();
	if (scan) {
		int from = optind < argc ? atoi(argv[optind]) : 0;
		int to = optind + 1 < argc ? atoi(argv[optind + 1]) : 63;
		if (from < 0 || to > 63 || from > to)
			usage();
		reg_open();
		return run_scan(from, to, id, ms);
	}
	int count = argc - optind;
	if (count < 1 || count > WATCHERS)
		usage();
	struct selector sels[WATCHERS];
	for (int i = 0; i < count; i++) {
		if (parse_selector(argv[optind + i], &sels[i]) != 0)
			usage();
	}
	reg_open();
	return run_watch(sels, count, ms, secs, quiet);
}
