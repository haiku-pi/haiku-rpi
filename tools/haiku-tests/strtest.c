/*
 * strtest.c — libroot's memory and string routines against simple reference versions, for every length
 * 0..300 and every source and destination offset 0..15 (and each routine's corner cases: overlap for
 * memmove, the matching byte or the terminator at each position, bytes >= 0x80 for comparisons, buffers
 * ending at a page boundary followed by an inaccessible page for the routines that may read ahead).
 *
 *   strtest          prints "strtest: PASS (N checks)" or the first failures, exit status 1
 *
 * Build (cross):
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O1 -fno-builtin -o strtest tools/haiku-tests/strtest.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define MAX_LEN 300
#define MAX_OFFSET 16
#define BUFFER (MAX_LEN + 2 * MAX_OFFSET + 64)

static long sChecks, sFailures;

#define CHECK(cond, ...) do { \
	sChecks++; \
	if (!(cond) && sFailures++ < 20) { \
		printf("strtest: FAIL %s:%d: ", __func__, __LINE__); \
		printf(__VA_ARGS__); \
		printf("\n"); \
	} \
} while (0)

static int sign(int v) { return (v > 0) - (v < 0); }

static unsigned char sA[BUFFER], sB[BUFFER], sRef[BUFFER];


static void
fill(unsigned char* p, size_t n, unsigned seed)
{
	for (size_t i = 0; i < n; i++) {
		seed = seed * 1103515245 + 12345;
		p[i] = 1 + (seed >> 16) % 255;	/* never 0 */
	}
}


static void
test_memcpy_memmove_memset(void)
{
	for (size_t len = 0; len <= MAX_LEN; len++) {
		for (int so = 0; so < MAX_OFFSET; so++) {
			for (int doff = 0; doff < MAX_OFFSET; doff++) {
				fill(sA, BUFFER, len * 31 + so);
				fill(sB, BUFFER, len * 7 + doff);
				memcpy(sRef, sB, BUFFER);
				for (size_t i = 0; i < len; i++)
					sRef[doff + 8 + i] = sA[so + 8 + i];
				void* r = memcpy(sB + doff + 8, sA + so + 8, len);
				CHECK(r == sB + doff + 8, "memcpy return");
				/* compared byte by byte: memcmp is under test too */
				size_t bad = BUFFER;
				for (size_t i = 0; i < BUFFER && bad == BUFFER; i++)
					if (sB[i] != sRef[i])
						bad = i;
				CHECK(bad == BUFFER, "memcpy len %zu so %d do %d: byte %zu", len, so, doff, bad);

				/* memmove within one buffer, both directions */
				fill(sA, BUFFER, len + so * 3 + doff);
				memcpy(sRef, sA, BUFFER);
				unsigned char tmp[BUFFER];
				for (size_t i = 0; i < len; i++)
					tmp[i] = sRef[so + 8 + i];
				for (size_t i = 0; i < len; i++)
					sRef[doff + 8 + i] = tmp[i];
				r = memmove(sA + doff + 8, sA + so + 8, len);
				CHECK(r == sA + doff + 8, "memmove return");
				int same = 1;
				for (size_t i = 0; i < BUFFER; i++)
					same &= sA[i] == sRef[i];
				CHECK(same, "memmove len %zu from %d to %d", len, so, doff);
			}
			/* memset */
			fill(sA, BUFFER, len + so);
			memcpy(sRef, sA, BUFFER);
			int value = (int)(len * 13 + so) & 0xff;
			for (size_t i = 0; i < len; i++)
				sRef[so + 8 + i] = value;
			void* r = memset(sA + so + 8, value | 0x1200, len);
			CHECK(r == sA + so + 8, "memset return");
			int same = 1;
			for (size_t i = 0; i < BUFFER; i++)
				same &= sA[i] == sRef[i];
			CHECK(same, "memset len %zu offset %d", len, so);
		}
	}
	/* large and zero-fill sizes (DC ZVA in memset) */
	size_t big = 1 << 20;
	unsigned char* x = malloc(big + 256);
	unsigned char* y = malloc(big + 256);
	for (int off = 0; off < 64; off += 7) {
		fill(x, big + 256, off);
		memset(x + off, 0, big - off);
		int ok = 1;
		for (size_t i = off; i < big; i++)
			ok &= x[i] == 0;
		CHECK(ok && x[big] != 0, "memset 0 of %zu at %d", big - off, off);
		fill(x, big + 256, off + 1);
		memcpy(y + 3, x + off, big - off);
		CHECK(memcmp(y + 3, x + off, big - off) == 0, "memcpy big at %d", off);
		memmove(x + 1, x, big);
		CHECK(memcmp(x + 1, y + 3, big - off) == 0 || off != 0, "memmove big");
	}
	free(x);
	free(y);
}


static int
ref_memcmp(const unsigned char* a, const unsigned char* b, size_t n)
{
	for (size_t i = 0; i < n; i++)
		if (a[i] != b[i])
			return a[i] - b[i];
	return 0;
}


static void
test_compare(void)
{
	for (size_t len = 0; len <= MAX_LEN; len++) {
		for (int ao = 0; ao < MAX_OFFSET; ao++) {
			int bo = (ao * 5 + len) % MAX_OFFSET;
			fill(sA + ao, len + 1, len);
			memcpy(sB + bo, sA + ao, len + 1);
			sA[ao + len] = 0;
			sB[bo + len] = 0;
			CHECK(memcmp(sA + ao, sB + bo, len) == 0, "memcmp equal %zu", len);
			CHECK(strcmp((char*)sA + ao, (char*)sB + bo) == 0, "strcmp equal %zu", len);
			CHECK(strncmp((char*)sA + ao, (char*)sB + bo, len + 5) == 0, "strncmp equal %zu", len);
			for (size_t pos = 0; pos < len; pos += 1 + len / 40) {
				unsigned char saved = sB[bo + pos];
				for (int delta = -1; delta <= 1; delta += 2) {
					sB[bo + pos] = (unsigned char)(saved + delta * 0x81);
					if (sB[bo + pos] == 0)
						sB[bo + pos] = 0xff;
					int expected = sign(ref_memcmp(sA + ao, sB + bo, len));
					CHECK(sign(memcmp(sA + ao, sB + bo, len)) == expected,
						"memcmp len %zu pos %zu", len, pos);
					CHECK(sign(strcmp((char*)sA + ao, (char*)sB + bo)) == expected,
						"strcmp len %zu pos %zu", len, pos);
					CHECK(sign(strncmp((char*)sA + ao, (char*)sB + bo, pos + 1)) == expected,
						"strncmp n %zu len %zu", pos + 1, len);
					CHECK(strncmp((char*)sA + ao, (char*)sB + bo, pos) == 0,
						"strncmp before the difference, n %zu", pos);
				}
				sB[bo + pos] = saved;
			}
			/* one string a prefix of the other */
			if (len > 0) {
				sB[bo + len - 1] = 0;
				CHECK(strcmp((char*)sA + ao, (char*)sB + bo) > 0, "strcmp prefix %zu", len);
				CHECK(strcmp((char*)sB + bo, (char*)sA + ao) < 0, "strcmp prefix %zu", len);
			}
		}
	}
}


static void
test_search(void)
{
	for (size_t len = 0; len <= MAX_LEN; len++) {
		for (int o = 0; o < MAX_OFFSET; o++) {
			unsigned char* s = sA + o + 8;
			fill(s, len, len + o);
			for (size_t i = 0; i < len; i++)
				if (s[i] == 'q')
					s[i] = 'r';
			s[len] = 0;
			CHECK(strlen((char*)s) == len, "strlen %zu off %d", len, o);
			CHECK(strnlen((char*)s, len + 3) == len, "strnlen %zu", len);
			CHECK(strnlen((char*)s, len / 2) == len / 2, "strnlen limit %zu", len);
			CHECK(memchr(s, 'q', len) == NULL, "memchr none %zu", len);
			CHECK(strchr((char*)s, 'q') == NULL, "strchr none %zu", len);
			CHECK(strrchr((char*)s, 'q') == NULL, "strrchr none %zu", len);
			CHECK(memrchr(s, 'q', len) == NULL, "memrchr none %zu", len);
			CHECK(strchrnul((char*)s, 'q') == (char*)s + len, "strchrnul none %zu", len);
			CHECK(strchr((char*)s, 0) == (char*)s + len, "strchr NUL %zu", len);
			CHECK(memchr(s, 0, len + 1) == s + len, "memchr NUL %zu", len);
			for (size_t pos = 0; pos < len; pos += 1 + len / 50) {
				s[pos] = 'q';
				CHECK(memchr(s, 'q', len) == s + pos, "memchr len %zu pos %zu", len, pos);
				CHECK(memchr(s, 'q' | 0x300, len) == s + pos, "memchr int arg");
				CHECK(memchr(s, 'q', pos) == NULL, "memchr short n");
				CHECK(strchr((char*)s, 'q') == (char*)s + pos, "strchr %zu %zu", len, pos);
				CHECK(strchrnul((char*)s, 'q') == (char*)s + pos, "strchrnul %zu %zu", len, pos);
				CHECK(strrchr((char*)s, 'q') == (char*)s + pos, "strrchr %zu %zu", len, pos);
				CHECK(memrchr(s, 'q', len) == s + pos, "memrchr %zu %zu", len, pos);
				if (pos + 2 < len) {
					s[len - 1] = 'q';
					CHECK(strrchr((char*)s, 'q') == (char*)s + len - 1, "strrchr last");
					CHECK(memrchr(s, 'q', len) == s + len - 1, "memrchr last");
					CHECK(memchr(s, 'q', len) == s + pos, "memchr first of two");
					s[len - 1] = 'r';
				}
				s[pos] = 0;
				CHECK(strlen((char*)s) == pos, "strlen early NUL %zu", pos);
				s[pos] = 'r';
			}
			/* bytes >= 0x80 */
			if (len > 0) {
				for (size_t i = 0; i < len; i++)
					if (s[i] == 0xe9)
						s[i] = 0xea;
				s[len / 2] = 0xe9;
				CHECK(strchr((char*)s, 0xe9) == (char*)s + len / 2, "strchr high byte");
				CHECK(memchr(s, 0xe9, len) == s + len / 2, "memchr high byte");
			}
		}
	}
}


static void
test_copy(void)
{
	for (size_t len = 0; len <= MAX_LEN; len++) {
		for (int so = 0; so < MAX_OFFSET; so++) {
			int doff = (so * 7 + len) % MAX_OFFSET;
			unsigned char* src = sA + so + 8;
			fill(src, len, len * 3 + so);
			src[len] = 0;
			fill(sB, BUFFER, 99);
			memcpy(sRef, sB, BUFFER);
			memcpy(sRef + doff + 8, src, len + 1);
			char* r = strcpy((char*)sB + doff + 8, (char*)src);
			CHECK(r == (char*)sB + doff + 8, "strcpy return");
			CHECK(memcmp(sB, sRef, BUFFER) == 0, "strcpy len %zu so %d do %d", len, so, doff);
			fill(sB, BUFFER, 98);
			memcpy(sRef, sB, BUFFER);
			memcpy(sRef + doff + 8, src, len + 1);
			r = stpcpy((char*)sB + doff + 8, (char*)src);
			CHECK(r == (char*)sB + doff + 8 + len, "stpcpy return len %zu", len);
			CHECK(memcmp(sB, sRef, BUFFER) == 0, "stpcpy len %zu so %d do %d", len, so, doff);
		}
	}
}


/* strings ending right before an inaccessible page: routines that read ahead must not fault */
static void
test_page_end(void)
{
	long page = sysconf(_SC_PAGESIZE);
	unsigned char* area = mmap(NULL, 2 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS,
		-1, 0);
	if (area == MAP_FAILED) {
		CHECK(0, "mmap");
		return;
	}
	mprotect(area + page, page, PROT_NONE);
	for (size_t len = 0; len < 100; len++) {
		unsigned char* s = area + page - len - 1;
		memset(s, 'a', len);
		s[len] = 0;
		CHECK(strlen((char*)s) == len, "strlen at page end %zu", len);
		CHECK(strnlen((char*)s, 1000) == len, "strnlen at page end");
		CHECK(strchr((char*)s, 'z') == NULL, "strchr at page end");
		CHECK(strrchr((char*)s, 'a') == (len ? (char*)s + len - 1 : NULL), "strrchr at page end");
		CHECK(strcmp((char*)s, (char*)s) == 0, "strcmp at page end");
		CHECK(memchr(s, 'z', len + 1) == NULL, "memchr at page end");
		char copy[128];
		CHECK(strcpy(copy, (char*)s) == copy && strlen(copy) == len, "strcpy at page end");
		unsigned char* t = area + page - len;
		memset(t, 'b', len);
		CHECK(memcmp(t, t, len) == 0, "memcmp at page end");
		CHECK(memrchr(t, 'z', len) == NULL, "memrchr at page end");
	}
	munmap(area, 2 * page);
}


int
main(void)
{
	test_memcpy_memmove_memset();
	test_compare();
	test_search();
	test_copy();
	test_page_end();
	if (sFailures == 0)
		printf("strtest: PASS (%ld checks)\n", sChecks);
	else
		printf("strtest: %ld of %ld checks FAILED\n", sFailures, sChecks);
	return sFailures != 0;
}
