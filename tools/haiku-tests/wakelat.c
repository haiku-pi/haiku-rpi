/*
 * wakelat.c — how late a periodic thread wakes up while other threads keep the CPUs busy: the pattern of a
 * video player (a frame every PERIOD ms, a few ms of work each) next to other work. A measuring thread at
 * PRIO sleeps until the next period (snooze_until), records how late it woke (system_time() - target),
 * then spins WORK_US microseconds; meanwhile BUSY threads at priority 10 spin without sleeping. With THREADS > 1,
 * that many measuring threads, their periods staggered evenly; a period whose work ends after the next period's
 * start is a deadline miss (a video frame that would be late).
 *
 *   wakelat [PERIOD_MS [N [PRIO [BUSY [WORK_US [THREADS]]]]]]   (default 33 ms, 300 periods, priority 10, 0 busy,
 *                                                              2000 us, 1 thread)
 *
 * Prints "WAKELAT period P ms prio R busy B work W us threads T scheduler mode S (0 low latency, 1 power saving): n N late us: median M p90 X p99 Y
 * max Z; over 5/10/33 ms: a/b/c; deadline misses D".
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o wakelat tools/haiku-tests/wakelat.c
 */
#include <OS.h>
#include <scheduler.h>
#include <stdio.h>
#include <stdlib.h>

static volatile int sStop;


static status_t
busy(void* arg)
{
	(void)arg;
	while (!sStop)
		;
	return 0;
}


static void
spin(bigtime_t us)
{
	bigtime_t end = system_time() + us;
	while (system_time() < end)
		;
}


static int
compare(const void* a, const void* b)
{
	bigtime_t x = *(const bigtime_t*)a, y = *(const bigtime_t*)b;
	return x < y ? -1 : x > y;
}


typedef struct {
	bigtime_t period, work, start;
	int n, misses;
	bigtime_t* late;
} params;


static status_t
measure(void* arg)
{
	params* p = arg;
	bigtime_t next = p->start;
	for (int i = 0; i < p->n; i++) {
		snooze_until(next, B_SYSTEM_TIMEBASE);
		p->late[i] = system_time() - next;
		spin(p->work);
		next += p->period;
		if (system_time() > next)
			p->misses++;
	}
	return 0;
}


int
main(int argc, char** argv)
{
	bigtime_t period = (argc > 1 ? atoi(argv[1]) : 33) * 1000LL;
	int n = argc > 2 ? atoi(argv[2]) : 300;
	int prio = argc > 3 ? atoi(argv[3]) : 10;
	int nbusy = argc > 4 ? atoi(argv[4]) : 0;
	bigtime_t work = argc > 5 ? atoi(argv[5]) : 2000;
	int nthreads = argc > 6 ? atoi(argv[6]) : 1;
	if (n < 1 || nbusy < 0 || nbusy > 64 || nthreads < 1 || nthreads > 16)
		return 2;
	thread_id busyThreads[64];
	for (int i = 0; i < nbusy; i++) {
		busyThreads[i] = spawn_thread(busy, "wakelat busy", B_NORMAL_PRIORITY, NULL);
		resume_thread(busyThreads[i]);
	}
	snooze(200000);
	params p[16];
	thread_id t[16];
	bigtime_t start = system_time() + period;
	for (int k = 0; k < nthreads; k++) {
		p[k].period = period;
		p[k].work = work;
		p[k].n = n;
		p[k].misses = 0;
		p[k].start = start + period * k / nthreads;
		p[k].late = malloc(sizeof(bigtime_t) * n);
		t[k] = spawn_thread(measure, "wakelat measure", prio, &p[k]);
		resume_thread(t[k]);
	}
	status_t ret;
	for (int k = 0; k < nthreads; k++)
		wait_for_thread(t[k], &ret);
	sStop = 1;
	for (int i = 0; i < nbusy; i++)
		wait_for_thread(busyThreads[i], &ret);
	int total = n * nthreads, misses = 0;
	bigtime_t* late = malloc(sizeof(bigtime_t) * total);
	for (int k = 0; k < nthreads; k++) {
		for (int i = 0; i < n; i++)
			late[k * n + i] = p[k].late[i];
		misses += p[k].misses;
	}
	qsort(late, total, sizeof(bigtime_t), compare);
	int over5 = 0, over10 = 0, over33 = 0;
	for (int i = 0; i < total; i++) {
		over5 += late[i] > 5000;
		over10 += late[i] > 10000;
		over33 += late[i] > 33000;
	}
	printf("WAKELAT period %lld ms prio %d busy %d work %lld us threads %d scheduler mode %d: n %d late us: median %lld"
		" p90 %lld p99 %lld max %lld; over 5/10/33 ms: %d/%d/%d; deadline misses %d\n", (long long)(period / 1000), prio,
		nbusy, (long long)work, nthreads, (int)get_scheduler_mode(), total, (long long)late[total / 2],
		(long long)late[total * 9 / 10], (long long)late[total * 99 / 100], (long long)late[total - 1], over5, over10,
		over33, misses);
	return 0;
}
