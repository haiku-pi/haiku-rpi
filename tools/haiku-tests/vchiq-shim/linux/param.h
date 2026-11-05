/* Haiku: VCOS's pthreads backend takes HZ from <linux/param.h> */
#include <sys/param.h>
#ifndef HZ
#	define HZ 100
#endif
