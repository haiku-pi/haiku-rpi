/* present-bench-keying.cpp: app_server's opaque front buffer row writers (old and new) */
#ifndef PRESENT_BENCH_KEYING_H
#define PRESENT_BENCH_KEYING_H

#include <stdint.h>

void copy_row_opaque_16(uint32_t* destination, const uint32_t* source, int32_t count);
void copy_row_opaque_64(uint32_t* destination, const uint32_t* source, int32_t count);

#endif
