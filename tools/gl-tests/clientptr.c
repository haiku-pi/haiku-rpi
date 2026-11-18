/*
 * clientptr — GL_MESA_map_buffer_client_pointer on the V3D (docs/design/gl-client-pointer.md): the
 * protocol Wine's WoW64 OpenGL thunks follow (dlls/opengl32/unix_wgl.c map_buffer_client_pointer), run
 * natively. Address space below 4 GiB is reserved as Wine does (mmap PROT_NONE, MAP_NORESERVE) and
 * committed range by range (mmap MAP_FIXED) when the driver asks for one; every range the driver gives
 * back is decommitted again (MAP_FIXED PROT_NONE). Checks: the pointer lies in the range given, data
 * written through it reaches the GPU (drawn and read back) and glGetBufferSubData, a second map needs no
 * new range and returns the same pointer, initial data is visible, the wined3d map pattern (whole buffer,
 * WRITE | FLUSH_EXPLICIT | UNSYNCHRONIZED), re-specification, invalidation and deletion give their ranges
 * back, release-all takes ranges of unmapped buffers only and a re-placed buffer keeps its contents, and
 * no BO mapping is left in the reserved range at the end. Then a timing loop: map + write + unmap of a 64 KiB
 * buffer with and without client pointers.
 *
 *   clientptr [-n LOOPS]
 *
 * Lines start with "GCP "; the last is "GCP PASS" or "GCP FAIL" (exit status 0 / 1).
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>

#include <OS.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifndef GL_MESA_map_buffer_client_pointer
#define GL_MAP_CLIENT_POINTER_BIT_MESA		0x4000
#define GL_BUFFER_CLIENT_POINTER_SIZE_MESA	0x9790
#define GL_CLIENT_POINTER_RELEASE_ALL_MESA	0x00000001
#define GL_CLIENT_POINTER_STREAM_DRAW_MESA	0x9791
#define GL_CLIENT_POINTER_STATIC_DRAW_MESA	0x9794
#define GL_CLIENT_POINTER_DYNAMIC_DRAW_MESA	0x9797
typedef void (APIENTRYP PFNGLADDCLIENTPOINTERRANGEMESAPROC)(void *addr, GLsizeiptr size);
typedef void *(APIENTRYP PFNGLRELEASECLIENTPOINTERRANGEMESAPROC)(GLbitfield flags, GLsizeiptr *size);
#endif

#define SAY(...) do { printf("GCP " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
#define CHECK(cond, ...) do { \
		if (cond) \
			SAY("check ok: " __VA_ARGS__); \
		else { \
			SAY("check BAD: " __VA_ARGS__); \
			sFailures++; \
		} \
	} while (0)

static int sFailures = 0;

#define GL_FUNCTIONS(F) \
	F(PFNGLGENBUFFERSPROC, glGenBuffers) \
	F(PFNGLDELETEBUFFERSPROC, glDeleteBuffers) \
	F(PFNGLBINDBUFFERPROC, glBindBuffer) \
	F(PFNGLBUFFERDATAPROC, glBufferData) \
	F(PFNGLMAPBUFFERRANGEPROC, glMapBufferRange) \
	F(PFNGLFLUSHMAPPEDBUFFERRANGEPROC, glFlushMappedBufferRange) \
	F(PFNGLUNMAPBUFFERPROC, glUnmapBuffer) \
	F(PFNGLGETBUFFERPARAMETERIVPROC, glGetBufferParameteriv) \
	F(PFNGLGETBUFFERSUBDATAPROC, glGetBufferSubData) \
	F(PFNGLADDCLIENTPOINTERRANGEMESAPROC, glAddClientPointerRangeMESA) \
	F(PFNGLRELEASECLIENTPOINTERRANGEMESAPROC, glReleaseClientPointerRangeMESA) \
	F(PFNGLCREATESHADERPROC, glCreateShader) \
	F(PFNGLSHADERSOURCEPROC, glShaderSource) \
	F(PFNGLCOMPILESHADERPROC, glCompileShader) \
	F(PFNGLCREATEPROGRAMPROC, glCreateProgram) \
	F(PFNGLATTACHSHADERPROC, glAttachShader) \
	F(PFNGLBINDATTRIBLOCATIONPROC, glBindAttribLocation) \
	F(PFNGLLINKPROGRAMPROC, glLinkProgram) \
	F(PFNGLGETPROGRAMIVPROC, glGetProgramiv) \
	F(PFNGLUSEPROGRAMPROC, glUseProgram) \
	F(PFNGLVERTEXATTRIBPOINTERPROC, glVertexAttribPointer) \
	F(PFNGLENABLEVERTEXATTRIBARRAYPROC, glEnableVertexAttribArray) \
	F(PFNGLGENFRAMEBUFFERSPROC, glGenFramebuffers) \
	F(PFNGLBINDFRAMEBUFFERPROC, glBindFramebuffer) \
	F(PFNGLGENRENDERBUFFERSPROC, glGenRenderbuffers) \
	F(PFNGLBINDRENDERBUFFERPROC, glBindRenderbuffer) \
	F(PFNGLRENDERBUFFERSTORAGEPROC, glRenderbufferStorage) \
	F(PFNGLFRAMEBUFFERRENDERBUFFERPROC, glFramebufferRenderbuffer) \
	F(PFNGLCHECKFRAMEBUFFERSTATUSPROC, glCheckFramebufferStatus)

#define DECLARE(type, name) static type p_##name;
GL_FUNCTIONS(DECLARE)

static double
now_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

/* --- the client's address space: Wine's reservation below 4 GiB --- */

#define RESERVATION_SIZE (256 * 1024 * 1024)

static uint8_t *sReserved;
static size_t sReservedUsed;
static int sCommitted;		/* ranges given to the driver and not yet given back */
static int sCommits;		/* ranges committed in all */
static uint8_t *sLastRange;
static size_t sLastRangeSize;

static void *
commit_range(size_t size)
{
	size = (size + B_PAGE_SIZE - 1) & ~(size_t)(B_PAGE_SIZE - 1);
	if (sReservedUsed + size > RESERVATION_SIZE)
		return NULL;
	uint8_t *range = sReserved + sReservedUsed;
	if (mmap(range, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0)
			!= range) {
		return NULL;
	}
	/* a pattern the driver's mapping replaces: proves the BO, not this memory, is seen */
	memset(range, 0xa5, size);
	sReservedUsed += size + B_PAGE_SIZE;
		/* a guard page between ranges */
	sCommitted++;
	sCommits++;
	sLastRange = range;
	sLastRangeSize = size;
	return range;
}

static int sBadReleases;

static void
release_ranges(GLbitfield flags)
{
	GLsizeiptr size = 0;
	void *range;
	while ((range = p_glReleaseClientPointerRangeMESA(flags, &size)) != NULL) {
		/* what comes back must be plain zeroed memory again, not the BO */
		const uint8_t *bytes = range;
		for (GLsizeiptr i = 0; i < size; i += 512) {
			if (bytes[i] != 0) {
				sBadReleases++;
				break;
			}
		}
		mmap(range, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED | MAP_NORESERVE, -1, 0);
		sCommitted--;
	}
}

/* Wine's map_buffer_client_pointer(), for the buffer bound to GL_ARRAY_BUFFER. */
static void *
map_client_pointer(GLintptr offset, GLsizeiptr length, GLbitfield access, bool *newRange)
{
	*newRange = false;
	glGetError();
	void *pointer = p_glMapBufferRange(GL_ARRAY_BUFFER, offset, length,
		access | GL_MAP_CLIENT_POINTER_BIT_MESA);
	GLenum error = glGetError();
	if (error != GL_OUT_OF_MEMORY) {
		if (error != GL_NO_ERROR)
			SAY("map: error 0x%x", error);
		return pointer;
	}

	GLint size = 0;
	p_glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_CLIENT_POINTER_SIZE_MESA, &size);
	if (size == 0) {
		SAY("map: out of memory without a size");
		return NULL;
	}
	void *range = commit_range(size);
	if (range == NULL) {
		SAY("map: cannot commit %d bytes", size);
		return NULL;
	}
	*newRange = true;
	p_glAddClientPointerRangeMESA(range, size);
	pointer = p_glMapBufferRange(GL_ARRAY_BUFFER, offset, length, access | GL_MAP_CLIENT_POINTER_BIT_MESA);
	error = glGetError();
	if (error != GL_NO_ERROR)
		SAY("map with a new range of %d bytes: error 0x%x", size, error);
	release_ranges(0);
	return pointer;
}

static void
unmap(void)
{
	p_glUnmapBuffer(GL_ARRAY_BUFFER);
	release_ranges(0);
}

static bool
in_last_range(const void *pointer, size_t length)
{
	const uint8_t *p = pointer;
	return p >= sLastRange && p + length <= sLastRange + sLastRangeSize;
}

/* BO mappings (the kernel names them "v3d bo map") left in the reservation */
static int32
count_placed_areas(void)
{
	int32 count = 0;
	ssize_t cookie = 0;
	area_info info;
	while (get_next_area_info(B_CURRENT_TEAM, &cookie, &info) == B_OK) {
		const uint8_t *address = info.address;
		if (strstr(info.name, "v3d bo map") != NULL && address >= sReserved
				&& address < sReserved + RESERVATION_SIZE) {
			count++;
		}
	}
	return count;
}

/* --- drawing from the buffer --- */

struct vertex {
	float x, y, r, g, b;
};

static GLuint sProgram;

static GLuint
compile(GLenum type, const char *source)
{
	GLuint shader = p_glCreateShader(type);
	p_glShaderSource(shader, 1, &source, NULL);
	p_glCompileShader(shader);
	return shader;
}

static bool
setup_drawing(void)
{
	GLuint framebuffer, renderbuffer;
	p_glGenRenderbuffers(1, &renderbuffer);
	p_glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
	p_glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 16, 16);
	p_glGenFramebuffers(1, &framebuffer);
	p_glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
	p_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, renderbuffer);
	if (p_glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		SAY("framebuffer incomplete");
		return false;
	}
	glViewport(0, 0, 16, 16);

	sProgram = p_glCreateProgram();
	p_glAttachShader(sProgram, compile(GL_VERTEX_SHADER,
		"attribute vec2 position;\n"
		"attribute vec3 color;\n"
		"varying vec3 vColor;\n"
		"void main() { vColor = color; gl_Position = vec4(position, 0.0, 1.0); }\n"));
	p_glAttachShader(sProgram, compile(GL_FRAGMENT_SHADER,
		"varying vec3 vColor;\n"
		"void main() { gl_FragColor = vec4(vColor, 1.0); }\n"));
	p_glBindAttribLocation(sProgram, 0, "position");
	p_glBindAttribLocation(sProgram, 1, "color");
	p_glLinkProgram(sProgram);
	GLint linked = 0;
	p_glGetProgramiv(sProgram, GL_LINK_STATUS, &linked);
	if (!linked) {
		SAY("program link failed");
		return false;
	}
	p_glUseProgram(sProgram);
	return true;
}

/* a triangle covering the viewport in one colour */
static void
fill_triangle(struct vertex *v, float r, float g, float b)
{
	static const float kPositions[3][2] = { { -1, -1 }, { 3, -1 }, { -1, 3 } };
	for (int i = 0; i < 3; i++)
		v[i] = (struct vertex){ kPositions[i][0], kPositions[i][1], r, g, b };
}

/* draws from the bound GL_ARRAY_BUFFER at byte offset "offset"; returns the centre pixel as 0xRRGGBB */
static uint32_t
draw(GLintptr offset)
{
	p_glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(struct vertex),
		(const void *)(offset + offsetof(struct vertex, x)));
	p_glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, sizeof(struct vertex),
		(const void *)(offset + offsetof(struct vertex, r)));
	p_glEnableVertexAttribArray(0);
	p_glEnableVertexAttribArray(1);
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	uint8_t pixel[4] = { 0 };
	glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
	return (uint32_t)pixel[0] << 16 | (uint32_t)pixel[1] << 8 | pixel[2];
}

/* --- the tests --- */

static void
test_basic(void)
{
	SAY("-- basic: map, write, draw; map again");
	GLuint buffer;
	p_glGenBuffers(1, &buffer);
	p_glBindBuffer(GL_ARRAY_BUFFER, buffer);
	p_glBufferData(GL_ARRAY_BUFFER, 3 * sizeof(struct vertex), NULL, GL_CLIENT_POINTER_STATIC_DRAW_MESA);
	CHECK(glGetError() == GL_NO_ERROR, "glBufferData with a client-pointer usage");

	bool newRange;
	struct vertex *v = map_client_pointer(0, 3 * sizeof(struct vertex), GL_MAP_WRITE_BIT, &newRange);
	CHECK(v != NULL && newRange, "first map asks for a range (%p)", (void *)v);
	if (v == NULL)
		return;
	CHECK(in_last_range(v, 3 * sizeof(*v)), "pointer %p in the range %p+%zu", (void *)v,
		(void *)sLastRange, sLastRangeSize);
	CHECK((uintptr_t)v < 0x100000000ull, "pointer below 4 GiB");
	CHECK(((uint8_t *)v)[0] != 0xa5, "the range shows the BO, not the client's memory");
	fill_triangle(v, 1, 0, 0);
	unmap();
	uint32_t pixel = draw(0);
	CHECK(pixel == 0xff0000, "GPU draws the data written through the pointer (0x%06x)", pixel);
	struct vertex back[3];
	p_glGetBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(back), back);
	CHECK(back[2].y == 3 && back[0].r == 1, "glGetBufferSubData reads it");

	void *first = v;
	v = map_client_pointer(0, 3 * sizeof(struct vertex), GL_MAP_WRITE_BIT, &newRange);
	CHECK(v == first && !newRange, "second map: same pointer, no new range (%p)", (void *)v);
	if (v != NULL) {
		fill_triangle(v, 0, 1, 0);
		unmap();
	}
	pixel = draw(0);
	CHECK(pixel == 0x00ff00, "GPU sees the second write (0x%06x)", pixel);

	p_glDeleteBuffers(1, &buffer);
	release_ranges(0);
	CHECK(sCommitted == 0, "deleting the buffer gives its range back (%d out)", sCommitted);
}

static void
test_initial_data(void)
{
	SAY("-- initial data, partial map, wined3d's pattern");
	struct vertex data[6];
	fill_triangle(data, 0, 0, 1);
	fill_triangle(data + 3, 1, 1, 0);
	GLuint buffer;
	p_glGenBuffers(1, &buffer);
	p_glBindBuffer(GL_ARRAY_BUFFER, buffer);
	p_glBufferData(GL_ARRAY_BUFFER, sizeof(data), data, GL_CLIENT_POINTER_DYNAMIC_DRAW_MESA);

	bool newRange;
	struct vertex *v = map_client_pointer(0, sizeof(data), GL_MAP_READ_BIT | GL_MAP_WRITE_BIT,
		&newRange);
	CHECK(v != NULL && memcmp(v, data, sizeof(data)) == 0, "glBufferData's data visible through the pointer");
	if (v != NULL)
		unmap();

	/* a range of the buffer, not at its start */
	struct vertex *w = map_client_pointer(3 * sizeof(struct vertex), 3 * sizeof(struct vertex),
		GL_MAP_WRITE_BIT, &newRange);
	CHECK(w != NULL && v != NULL && w == v + 3 && !newRange, "offset map: pointer + offset, no new range");
	if (w != NULL) {
		fill_triangle(w, 1, 0, 1);
		unmap();
	}
	CHECK(draw(3 * sizeof(struct vertex)) == 0xff00ff, "GPU draws the offset write");
	CHECK(draw(0) == 0x0000ff, "the rest unchanged");

	/* wined3d (no ARB_buffer_storage): the whole buffer, write-only, explicit flush, unsynchronized */
	v = map_client_pointer(0, sizeof(data), GL_MAP_WRITE_BIT | GL_MAP_FLUSH_EXPLICIT_BIT
		| GL_MAP_UNSYNCHRONIZED_BIT, &newRange);
	CHECK(v != NULL && !newRange, "wined3d-style map, no new range");
	if (v != NULL) {
		fill_triangle(v + 3, 0, 1, 1);
		p_glFlushMappedBufferRange(GL_ARRAY_BUFFER, 3 * sizeof(struct vertex), 3 * sizeof(struct vertex));
		unmap();
	}
	CHECK(draw(3 * sizeof(struct vertex)) == 0x00ffff, "GPU draws the flushed range");

	p_glDeleteBuffers(1, &buffer);
	release_ranges(0);
	CHECK(sCommitted == 0, "ranges back after delete (%d out)", sCommitted);
}

static void
test_respecify(int loops)
{
	SAY("-- re-specification and invalidation, %d loops each", loops);
	GLuint buffer;
	p_glGenBuffers(1, &buffer);
	p_glBindBuffer(GL_ARRAY_BUFFER, buffer);
	int commits = sCommits;
	int bad = 0;
	for (int i = 0; i < loops; i++) {
		GLsizeiptr size = 3 * sizeof(struct vertex) + (i % 4) * 8192;
		p_glBufferData(GL_ARRAY_BUFFER, size, NULL, GL_CLIENT_POINTER_STREAM_DRAW_MESA);
		bool newRange;
		struct vertex *v = map_client_pointer(0, size, GL_MAP_WRITE_BIT, &newRange);
		if (v == NULL) {
			bad++;
			continue;
		}
		fill_triangle(v, i & 1, 0, 1);
		unmap();
		if (draw(0) != ((i & 1) ? 0xff00ffu : 0x0000ffu))
			bad++;
	}
	glFinish();
	release_ranges(0);
	CHECK(bad == 0, "glBufferData loop: every map drew right (%d bad)", bad);
	CHECK(sCommitted <= 1, "glBufferData loop: %d ranges committed, %d still out", sCommits - commits,
		sCommitted);

	commits = sCommits;
	bad = 0;
	for (int i = 0; i < loops; i++) {
		bool newRange;
		struct vertex *v = map_client_pointer(0, 3 * sizeof(struct vertex),
			GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT, &newRange);
		if (v == NULL) {
			bad++;
			continue;
		}
		fill_triangle(v, 0, i & 1, 1);
		unmap();
		if (draw(0) != ((i & 1) ? 0x00ffffu : 0x0000ffu))
			bad++;
	}
	glFinish();
	release_ranges(0);
	CHECK(bad == 0, "invalidating maps: every map drew right (%d bad)", bad);
	CHECK(sCommitted <= 1, "invalidating maps: %d ranges committed, %d still out", sCommits - commits,
		sCommitted);

	p_glDeleteBuffers(1, &buffer);
	release_ranges(0);
	CHECK(sCommitted == 0, "ranges back after delete (%d out)", sCommitted);
}

static void
test_release_all(void)
{
	SAY("-- release-all");
	GLuint buffers[2];
	p_glGenBuffers(2, buffers);
	struct vertex *v[2];
	for (int i = 0; i < 2; i++) {
		p_glBindBuffer(GL_ARRAY_BUFFER, buffers[i]);
		p_glBufferData(GL_ARRAY_BUFFER, 3 * sizeof(struct vertex), NULL, GL_CLIENT_POINTER_STATIC_DRAW_MESA);
		bool newRange;
		v[i] = map_client_pointer(0, 3 * sizeof(struct vertex), GL_MAP_WRITE_BIT, &newRange);
		if (v[i] == NULL) {
			SAY("check BAD: map for release-all");
			sFailures++;
			return;
		}
		fill_triangle(v[i], i, 1, 0);
	}
	/* buffer 0 unmapped, buffer 1 still mapped */
	p_glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
	unmap();
	release_ranges(GL_CLIENT_POINTER_RELEASE_ALL_MESA);
	CHECK(sCommitted == 1, "release-all takes the unmapped buffer's range only (%d out)", sCommitted);

	bool newRange;
	struct vertex *w = map_client_pointer(0, 3 * sizeof(struct vertex), GL_MAP_READ_BIT, &newRange);
	CHECK(w != NULL && newRange, "the unplaced buffer asks for a new range");
	CHECK(w != NULL && w[0].r == 0 && w[0].g == 1, "and keeps its contents");
	if (w != NULL)
		unmap();
	CHECK(draw(0) == 0x00ff00, "GPU still draws it");

	p_glBindBuffer(GL_ARRAY_BUFFER, buffers[1]);
	unmap();
	p_glDeleteBuffers(2, buffers);
	release_ranges(GL_CLIENT_POINTER_RELEASE_ALL_MESA);
	CHECK(sCommitted == 0, "all ranges back (%d out)", sCommitted);
}

static void
time_maps(int loops)
{
	enum { kSize = 64 * 1024 };
	uint8_t *source = malloc(kSize);
	memset(source, 0x3c, kSize);
	for (int clientPointer = 0; clientPointer < 2; clientPointer++) {
		GLuint buffer;
		p_glGenBuffers(1, &buffer);
		p_glBindBuffer(GL_ARRAY_BUFFER, buffer);
		p_glBufferData(GL_ARRAY_BUFFER, kSize, NULL,
			clientPointer ? GL_CLIENT_POINTER_DYNAMIC_DRAW_MESA : GL_DYNAMIC_DRAW);
		const GLbitfield access = GL_MAP_WRITE_BIT | GL_MAP_FLUSH_EXPLICIT_BIT | GL_MAP_UNSYNCHRONIZED_BIT;
		double start = now_us();
		int failed = 0;
		for (int i = 0; i < loops; i++) {
			bool newRange;
			void *p = clientPointer
				? map_client_pointer(0, kSize, access, &newRange)
				: p_glMapBufferRange(GL_ARRAY_BUFFER, 0, kSize, access);
			if (p == NULL) {
				failed++;
				continue;
			}
			memcpy(p, source, kSize);
			p_glFlushMappedBufferRange(GL_ARRAY_BUFFER, 0, kSize);
			if (clientPointer)
				unmap();
			else
				p_glUnmapBuffer(GL_ARRAY_BUFFER);
		}
		double us = (now_us() - start) / loops;
		SAY("timing %s: %d x (map + 64 KiB write + flush + unmap): %.1f us each%s",
			clientPointer ? "client pointer" : "plain map", loops, us, failed ? " (maps failed)" : "");
		if (failed)
			sFailures++;
		p_glDeleteBuffers(1, &buffer);
		release_ranges(0);
	}
	free(source);
}

int
main(int argc, char **argv)
{
	int loops = 200;
	int opt;
	while ((opt = getopt(argc, argv, "n:")) != -1) {
		if (opt == 'n')
			loops = atoi(optarg);
		else {
			fprintf(stderr, "usage: %s [-n loops]\n", argv[0]);
			return 2;
		}
	}

	EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL) || !eglBindAPI(EGL_OPENGL_API)) {
		SAY("EGL init failed 0x%x", eglGetError());
		SAY("FAIL");
		return 1;
	}
	EGLContext context = eglCreateContext(display, NULL, EGL_NO_CONTEXT, NULL);
	if (context == EGL_NO_CONTEXT || !eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
		SAY("no surfaceless desktop GL context 0x%x", eglGetError());
		SAY("FAIL");
		return 1;
	}
	SAY("renderer: %s, %s", (const char *)glGetString(GL_RENDERER), (const char *)glGetString(GL_VERSION));
	const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
	bool has = extensions != NULL && strstr(extensions, "GL_MESA_map_buffer_client_pointer") != NULL;
	SAY("GL_MESA_map_buffer_client_pointer: %s", has ? "yes" : "no");
	if (!has) {
		SAY("FAIL");
		return 1;
	}

#define LOAD(type, name) \
	if ((p_##name = (type)eglGetProcAddress(#name)) == NULL) { \
		SAY("no %s", #name); \
		SAY("FAIL"); \
		return 1; \
	}
	GL_FUNCTIONS(LOAD)

	/* Wine's reservation: low, never committed as a whole */
	sReserved = mmap((void *)0x40000000, RESERVATION_SIZE, PROT_NONE,
		MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (sReserved == MAP_FAILED) {
		SAY("cannot reserve %d MiB", RESERVATION_SIZE >> 20);
		SAY("FAIL");
		return 1;
	}
	SAY("reservation %p+%d MiB", (void *)sReserved, RESERVATION_SIZE >> 20);

	if (!setup_drawing()) {
		SAY("FAIL");
		return 1;
	}

	test_basic();
	test_initial_data();
	test_respecify(loops / 4 > 8 ? loops / 4 : 8);
	test_release_all();
	CHECK(sBadReleases == 0, "every range came back as zeroed memory (%d not)", sBadReleases);
	int32 placed = count_placed_areas();
	CHECK(placed == 0, "no BO mapping left in the reserved range (%d)", placed);
	SAY("ranges committed in all: %d", sCommits);

	time_maps(loops);

	CHECK(glGetError() == GL_NO_ERROR, "no GL error left");
	eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(display, context);
	eglTerminate(display);

	SAY("%s", sFailures == 0 ? "PASS" : "FAIL");
	return sFailures == 0 ? 0 : 1;
}
