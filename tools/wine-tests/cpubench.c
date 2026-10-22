/* cpubench.c — a small CPU benchmark to compare the x86 emulators with native code: the same C built for
 * arm64, x86 and x86-64, run under Wine (natively, Box64, FEX). Prints the milliseconds of each part and a
 * checksum, which must match between builds.
 *
 *   cpubench.exe [SCALE]     (default 1) */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned int checksum;

static double ms(LARGE_INTEGER a, LARGE_INTEGER b, LARGE_INTEGER f)
{
	return (b.QuadPart - a.QuadPart) * 1000.0 / f.QuadPart;
}

/* integer: an xorshift generator and a modular mix */
static void bench_int(int n)
{
	unsigned int x = 2463534242u, acc = 0;
	int i;
	for (i = 0; i < n * 20000000; i++) {
		x ^= x << 13; x ^= x >> 17; x ^= x << 5;
		acc += x % 1000003u;
	}
	checksum ^= acc;
}

/* floating point: a small n-body step */
static void bench_float(int n)
{
	double px[16], py[16], vx[16] = {0}, vy[16] = {0};
	int i, j, s;
	for (i = 0; i < 16; i++) { px[i] = i * 1.25; py[i] = (i * 7 % 16) * 0.75; }
	for (s = 0; s < n * 40000; s++)
		for (i = 0; i < 16; i++)
			for (j = 0; j < 16; j++) {
				double dx = px[j] - px[i], dy = py[j] - py[i], d = dx * dx + dy * dy + 0.01;
				vx[i] += dx / d * 1e-4; vy[i] += dy / d * 1e-4;
			}
	for (i = 0; i < 16; i++) checksum ^= (unsigned int)(vx[i] * 1e6) ^ (unsigned int)(vy[i] * 1e6);
}

/* memory: copies of an 8 MiB buffer */
static void bench_memory(int n)
{
	size_t size = 8 << 20;
	char *a = malloc(size), *b = malloc(size);
	int i;
	memset(a, 1, size);
	for (i = 0; i < n * 100; i++) { memcpy(b, a, size); a[i % size]++; }
	checksum ^= (unsigned char)b[0] + (unsigned char)b[size - 1];
	free(a); free(b);
}

/* branches and calls: qsort of integers */
static int compare(const void *a, const void *b)
{
	return *(const int *)a - *(const int *)b;
}

static void bench_sort(int n)
{
	int count = 1 << 20, i, r;
	int *v = malloc(count * sizeof(*v));
	for (r = 0; r < n * 3; r++) {
		unsigned int x = 12345 + r;
		for (i = 0; i < count; i++) { x = x * 1103515245u + 12345u; v[i] = (int)(x >> 8); }
		qsort(v, count, sizeof(*v), compare);
		checksum ^= v[count / 2];
	}
	free(v);
}

int main(int argc, char **argv)
{
	int n = argc > 1 ? atoi(argv[1]) : 1;
	LARGE_INTEGER f, t0, t1, t2, t3, t4;
	QueryPerformanceFrequency(&f);
	QueryPerformanceCounter(&t0);
	bench_int(n);
	QueryPerformanceCounter(&t1);
	bench_float(n);
	QueryPerformanceCounter(&t2);
	bench_memory(n);
	QueryPerformanceCounter(&t3);
	bench_sort(n);
	QueryPerformanceCounter(&t4);
	printf("CPUBENCH int %.0f ms, float %.0f ms, memory %.0f ms, sort %.0f ms, total %.0f ms, checksum %08x\n",
		ms(t0, t1, f), ms(t1, t2, f), ms(t2, t3, f), ms(t3, t4, f), ms(t0, t4, f), checksum);
	return 0;
}
