/* rust-clib: C calling a Rust library (src/lib.rs); linked once with the static library
 * (rust-c-static) and once with the shared one (rust-c-shared). One line per check,
 * "rust-clib: <check> PASS|FAIL", then "rust-clib: ALL PASS" (exit 0) or "rust-clib: N FAILED". */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

const char* rust_clib_version(void);
uint64_t rust_sum_parallel(const uint32_t* data, size_t len, uint32_t threads);
int32_t rust_checked_double(int32_t n);
size_t rust_distinct_words(const char* text);
int64_t rust_file_roundtrip(const char* path, double x);

static int failed;

static void
check(const char* name, int ok, const char* detail)
{
	printf("rust-clib: %s %s %s\n", name, ok ? "PASS" : "FAIL", detail);
	if (!ok)
		failed++;
}

int
main(void)
{
	char detail[128];
	enum { N = 100000 };
	uint32_t* data = malloc(N * sizeof(uint32_t));
	uint64_t sum;
	int64_t length;
	int32_t doubled, refused;
	size_t words;
	char path[64];

	check("version", strcmp(rust_clib_version(), "rust-clib 0.1.0") == 0, rust_clib_version());

	for (int i = 0; i < N; i++)
		data[i] = i;
	sum = rust_sum_parallel(data, N, 4);
	snprintf(detail, sizeof(detail), "%llu", (unsigned long long)sum);
	check("threads", sum == (uint64_t)N * (N - 1) / 2, detail);
	free(data);

	/* the panic inside prints its message to stderr: expected */
	doubled = rust_checked_double(21);
	refused = rust_checked_double(-5);
	snprintf(detail, sizeof(detail), "%d %d", doubled, refused);
	check("unwind", doubled == 42 && refused == -1, detail);

	words = rust_distinct_words("the quick brown fox jumps over the lazy dog the end");
	snprintf(detail, sizeof(detail), "%zu", words);
	check("hashset", words == 9, detail);

	snprintf(path, sizeof(path), "/tmp/rust-clib-%d.txt", (int)getpid());
	length = rust_file_roundtrip(path, 3.14159265);
	unlink(path);
	snprintf(detail, sizeof(detail), "%lld bytes", (long long)length);
	check("fs", length == (int64_t)strlen("pi is about 3.14159\n"), detail);

	if (failed == 0) {
		printf("rust-clib: ALL PASS\n");
		return 0;
	}
	printf("rust-clib: %d FAILED\n", failed);
	return 1;
}
