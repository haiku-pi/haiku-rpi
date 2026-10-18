/*
 * gltri — headless OpenGL smoke test for the Haiku GPU bring-up: gets an EGL context without a
 * window (surfaceless, else a pbuffer), prints what renders (GL_RENDERER/GL_VERSION), draws a
 * triangle into a framebuffer object, reads the pixels back and checks them. Every line starts with
 * "GLT " so a boot script can send it to the serial console (> /dev/dprintf) and a grader can pick
 * it out. Exit status 0 = PASS.
 *
 *   gltri [-n FRAMES] [-s SIZE]
 *
 * Lines: GLT egl ... / GLT es-context ... / GLT renderer: ... / GLT version: ... /
 *        GLT check <name> <what> ... ok|BAD / GLT frames ... / GLT gl-context ... / GLT PASS|FAIL
 * LIBGL_ALWAYS_SOFTWARE=1 forces Mesa's software renderer (softpipe), for comparison.
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SAY(...) do { printf("GLT " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static int sFailures = 0;

static double
now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static bool
has_extension(const char *list, const char *name)
{
	size_t length = strlen(name);
	for (const char *p = list; p != NULL && (p = strstr(p, name)) != NULL; p += length) {
		if ((p == list || p[-1] == ' ') && (p[length] == ' ' || p[length] == '\0'))
			return true;
	}
	return false;
}

static GLuint
compile(GLenum type, const char *source)
{
	GLuint shader = glCreateShader(type);
	glShaderSource(shader, 1, &source, NULL);
	glCompileShader(shader);
	GLint ok = 0;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[512] = "";
		glGetShaderInfoLog(shader, sizeof(log), NULL, log);
		SAY("shader compile failed: %s", log);
		sFailures++;
	}
	return shader;
}

static const char *kVertexShader =
	"attribute vec2 position;\n"
	"attribute vec3 color;\n"
	"varying vec3 vColor;\n"
	"void main() {\n"
	"	vColor = color;\n"
	"	gl_Position = vec4(position, 0.0, 1.0);\n"
	"}\n";

static const char *kFragmentShader =
	"precision mediump float;\n"
	"varying vec3 vColor;\n"
	"void main() {\n"
	"	gl_FragColor = vec4(vColor, 1.0);\n"
	"}\n";

/* The lower-left half of the target: x + y < 0 in NDC; one solid colour (yellow), so every
 * covered pixel has an exact expected value. */
static const GLfloat kTriangle[] = {
	/* x, y, r, g, b */
	-1.0f, -1.0f, 1.0f, 1.0f, 0.0f,
	 1.0f, -1.0f, 1.0f, 1.0f, 0.0f,
	-1.0f,  1.0f, 1.0f, 1.0f, 0.0f,
};

static const uint8_t kClear[4] = { 0, 0, 64, 255 };		/* dark blue */
static const uint8_t kYellow[4] = { 255, 255, 0, 255 };

static bool
same_colour(const uint8_t *a, const uint8_t *b)
{
	for (int i = 0; i < 4; i++) {
		if (abs((int)a[i] - (int)b[i]) > 2)
			return false;
	}
	return true;
}

static void
check_pixel(const uint8_t *pixels, int size, const char *name, int x, int y,
	const uint8_t *expected)
{
	const uint8_t *p = pixels + (y * size + x) * 4;
	bool ok = same_colour(p, expected);
	SAY("check %s pixel(%d,%d) = %d,%d,%d,%d expect %d,%d,%d,%d %s", name, x, y,
		p[0], p[1], p[2], p[3], expected[0], expected[1], expected[2], expected[3],
		ok ? "ok" : "BAD");
	if (!ok)
		sFailures++;
}

static void
print_gl_strings(void)
{
	SAY("vendor: %s", (const char *)glGetString(GL_VENDOR));
	SAY("renderer: %s", (const char *)glGetString(GL_RENDERER));
	SAY("version: %s", (const char *)glGetString(GL_VERSION));
	SAY("glsl: %s", (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION));
}

/* Renders into an FBO, reads it back and grades it. */
static void
render_test(int size, int frames)
{
	GLuint texture, fbo;
	glGenTextures(1, &texture);
	glBindTexture(GL_TEXTURE_2D, texture);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, size, size, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
	GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	SAY("fbo %dx%d status 0x%x %s", size, size, status,
		status == GL_FRAMEBUFFER_COMPLETE ? "ok" : "BAD");
	if (status != GL_FRAMEBUFFER_COMPLETE) {
		sFailures++;
		return;
	}

	GLuint program = glCreateProgram();
	glAttachShader(program, compile(GL_VERTEX_SHADER, kVertexShader));
	glAttachShader(program, compile(GL_FRAGMENT_SHADER, kFragmentShader));
	glBindAttribLocation(program, 0, "position");
	glBindAttribLocation(program, 1, "color");
	glLinkProgram(program);
	GLint linked = 0;
	glGetProgramiv(program, GL_LINK_STATUS, &linked);
	if (!linked) {
		char log[512] = "";
		glGetProgramInfoLog(program, sizeof(log), NULL, log);
		SAY("program link failed: %s", log);
		sFailures++;
		return;
	}

	GLuint buffer;
	glGenBuffers(1, &buffer);
	glBindBuffer(GL_ARRAY_BUFFER, buffer);
	glBufferData(GL_ARRAY_BUFFER, sizeof(kTriangle), kTriangle, GL_STATIC_DRAW);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(GLfloat), (void *)0);
	glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(GLfloat),
		(void *)(2 * sizeof(GLfloat)));
	glEnableVertexAttribArray(0);
	glEnableVertexAttribArray(1);
	glUseProgram(program);
	glViewport(0, 0, size, size);

	double start = now_ms();
	for (int frame = 0; frame < frames; frame++) {
		glClearColor(kClear[0] / 255.0f, kClear[1] / 255.0f, kClear[2] / 255.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		glDrawArrays(GL_TRIANGLES, 0, 3);
	}
	glFinish();
	double elapsed = now_ms() - start;
	GLenum error = glGetError();
	SAY("frames %d in %.1f ms (%.2f ms/frame), glGetError 0x%x %s", frames, elapsed,
		elapsed / frames, error, error == GL_NO_ERROR ? "ok" : "BAD");
	if (error != GL_NO_ERROR)
		sFailures++;

	uint8_t *pixels = calloc((size_t)size * size, 4);
	start = now_ms();
	glReadPixels(0, 0, size, size, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
	SAY("readpixels %.1f ms", now_ms() - start);

	/* Row 0 is the bottom: the triangle covers the corner (0,0), not (size-1,size-1). */
	check_pixel(pixels, size, "inside", size / 8, size / 8, kYellow);
	check_pixel(pixels, size, "inside-edge", size - 3, 1, kYellow);
	check_pixel(pixels, size, "outside", size - 1 - size / 8, size - 1 - size / 8, kClear);
	check_pixel(pixels, size, "outside-edge", size - 1, size - 1, kClear);

	/* Every pixel is one of the two colours; the triangle covers about half. */
	int yellow = 0, clear = 0, other = 0;
	for (int i = 0; i < size * size; i++) {
		if (same_colour(pixels + i * 4, kYellow))
			yellow++;
		else if (same_colour(pixels + i * 4, kClear))
			clear++;
		else
			other++;
	}
	int expectedMin = size * (size - 1) / 2 - size;
	int expectedMax = size * (size + 1) / 2 + size;
	bool ok = other == 0 && yellow >= expectedMin && yellow <= expectedMax;
	SAY("check coverage yellow %d clear %d other %d of %d (expect yellow %d..%d) %s", yellow,
		clear, other, size * size, expectedMin, expectedMax, ok ? "ok" : "BAD");
	if (!ok)
		sFailures++;
	free(pixels);

	glDeleteBuffers(1, &buffer);
	glDeleteProgram(program);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glDeleteFramebuffers(1, &fbo);
	glDeleteTextures(1, &texture);
}

/* Makes the context current without a window: surfaceless if offered, else on a pbuffer. */
static bool
make_current(EGLDisplay display, EGLConfig config, EGLContext context, bool surfaceless,
	EGLSurface *surface)
{
	*surface = EGL_NO_SURFACE;
	if (!surfaceless) {
		static const EGLint attributes[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
		*surface = eglCreatePbufferSurface(display, config, attributes);
		if (*surface == EGL_NO_SURFACE) {
			SAY("eglCreatePbufferSurface failed 0x%x", eglGetError());
			return false;
		}
	}
	if (!eglMakeCurrent(display, *surface, *surface, context)) {
		SAY("eglMakeCurrent failed 0x%x", eglGetError());
		return false;
	}
	return true;
}

int
main(int argc, char **argv)
{
	int frames = 100;
	int size = 64;
	int opt;
	while ((opt = getopt(argc, argv, "n:s:")) != -1) {
		switch (opt) {
			case 'n': frames = atoi(optarg); break;
			case 's': size = atoi(optarg); break;
			default:
				fprintf(stderr, "usage: %s [-n frames] [-s size]\n", argv[0]);
				return 2;
		}
	}
	if (frames < 1)
		frames = 1;
	if (size < 16)
		size = 16;

	SAY("begin size %d frames %d%s", size, frames,
		getenv("LIBGL_ALWAYS_SOFTWARE") != NULL ? " (LIBGL_ALWAYS_SOFTWARE)" : "");

	double start = now_ms();
	EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	EGLint major = 0, minor = 0;
	if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor)) {
		SAY("eglInitialize failed 0x%x", eglGetError());
		SAY("FAIL");
		return 1;
	}
	const char *extensions = eglQueryString(display, EGL_EXTENSIONS);
	bool surfaceless = has_extension(extensions, "EGL_KHR_surfaceless_context");
	SAY("egl %d.%d vendor \"%s\" apis \"%s\" surfaceless %s (%.1f ms)", major, minor,
		eglQueryString(display, EGL_VENDOR), eglQueryString(display, EGL_CLIENT_APIS),
		surfaceless ? "yes" : "no", now_ms() - start);

	/* OpenGL ES: the API the exit criterion names. */
	eglBindAPI(EGL_OPENGL_ES_API);
	static const EGLint configAttributes[] = {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_NONE
	};
	EGLConfig config = NULL;
	EGLint count = 0;
	if (!eglChooseConfig(display, configAttributes, &config, 1, &count) || count < 1) {
		SAY("no ES2 pbuffer config (0x%x), using no config", eglGetError());
		config = NULL;
		if (!surfaceless) {
			SAY("FAIL");
			return 1;
		}
	}

	EGLContext context = EGL_NO_CONTEXT;
	EGLint version = 3;
	for (; version >= 2 && context == EGL_NO_CONTEXT; version--) {
		const EGLint contextAttributes[] = { EGL_CONTEXT_CLIENT_VERSION, version, EGL_NONE };
		context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
		if (context == EGL_NO_CONTEXT)
			SAY("eglCreateContext ES %d failed 0x%x", version, eglGetError());
	}
	if (context == EGL_NO_CONTEXT) {
		SAY("FAIL");
		return 1;
	}
	SAY("es-context requested %d", version + 1);

	EGLSurface surface;
	if (!make_current(display, config, context, surfaceless, &surface)) {
		SAY("FAIL");
		return 1;
	}
	print_gl_strings();
	render_test(size, frames);

	eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	if (surface != EGL_NO_SURFACE)
		eglDestroySurface(display, surface);
	eglDestroyContext(display, context);

	/* Desktop OpenGL (what BGLView asks for): report its version. */
	if (eglBindAPI(EGL_OPENGL_API)) {
		EGLContext glContext = eglCreateContext(display, config, EGL_NO_CONTEXT, NULL);
		if (glContext != EGL_NO_CONTEXT
			&& make_current(display, config, glContext, surfaceless, &surface)) {
			SAY("gl-context renderer: %s", (const char *)glGetString(GL_RENDERER));
			SAY("gl-context version: %s", (const char *)glGetString(GL_VERSION));
			eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
			if (surface != EGL_NO_SURFACE)
				eglDestroySurface(display, surface);
		} else
			SAY("gl-context failed 0x%x", eglGetError());
		if (glContext != EGL_NO_CONTEXT)
			eglDestroyContext(display, glContext);
	}

	eglTerminate(display);
	SAY("%s (%d failure%s)", sFailures == 0 ? "PASS" : "FAIL", sFailures,
		sFailures == 1 ? "" : "s");
	return sFailures == 0 ? 0 : 1;
}
