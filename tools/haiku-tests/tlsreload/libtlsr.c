/* libtlsr.c — the library for tlsreload.c: a thread-local variable written by one call and read by
 * another (general-dynamic TLS, as any -fPIC library's thread_local). */
static __thread long sValue;

void
tlsr_set(long value)
{
	sValue = value;
}

long
tlsr_get(void)
{
	return sValue;
}
