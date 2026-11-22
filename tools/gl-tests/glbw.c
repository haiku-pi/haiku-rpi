/*
 * glbw — GPU memory traffic of known size, for calibrating a bus monitor (tools/haiku-tests/axibw): in a
 * surfaceless EGL GLES 3 context, render passes into a W×H framebuffer object, each finished with glFinish
 * (one V3D render job per pass), for SECS seconds.
 *
 *   glbw [-m clear|load|full] [-f rgba8|rgba16f] [-r 1-4] [-s WxH] [-t SECS]
 *
 *   clear: each pass clears the colour buffers and draws nothing: the job stores W·H·bpp bytes per buffer,
 *          loads nothing
 *   load:  each pass draws one small triangle without a clear: the job loads and stores W·H·bpp per buffer
 *   full:  as load, but the triangles cover the whole buffer (every pixel shaded once, a post-process pass)
 *   -r N:  N colour buffers (render targets) of the format; V3D's tile size shrinks with their count
 *
 * Lines: "GBW start <t>", then "GBW <mode> <format> x<N> <W>x<H>: <ms> ms/pass, <passes> passes in <secs> s
 * (<passes/s>/s), <MB/s> MB/s stored, <MB/s> MB/s loaded" and "GBW end <t>" (t = CLOCK_MONOTONIC seconds, as
 * axibw prints).
 *
 * Build (cross, on the host):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -Wall -o glbw tools/gl-tests/glbw.c -lEGL -lGLESv2
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double
now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static GLuint
shader(GLenum type, const char* source)
{
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &source, NULL);
	glCompileShader(s);
	GLint ok = 0;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		fprintf(stderr, "glbw: shader does not compile\n");
		exit(1);
	}
	return s;
}

int
main(int argc, char** argv)
{
	const char* mode = "clear";
	const char* format = "rgba8";
	int width = 1024, height = 1024, targets = 1;
	double secs = 10;
	int opt;
	while ((opt = getopt(argc, argv, "m:f:r:s:t:")) != -1) {
		switch (opt) {
			case 'm': mode = optarg; break;
			case 'f': format = optarg; break;
			case 's':
				if (sscanf(optarg, "%dx%d", &width, &height) != 2)
					return 2;
				break;
			case 't': secs = atof(optarg); break;
			case 'r': targets = atoi(optarg); break;
			default:
				fprintf(stderr, "usage: glbw [-m clear|load|full] [-f rgba8|rgba16f] [-r 1-4] [-s WxH] [-t SECS]\n");
				return 2;
		}
	}
	int full = strcmp(mode, "full") == 0;
	int load = full || strcmp(mode, "load") == 0;
	if (targets < 1 || targets > 4)
		return 2;
	int half = strcmp(format, "rgba16f") == 0;

	EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (!eglInitialize(display, NULL, NULL) || !eglBindAPI(EGL_OPENGL_ES_API)) {
		fprintf(stderr, "glbw: no EGL\n");
		return 1;
	}
	EGLint configAttribs[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE };
	EGLConfig config;
	EGLint configs = 0;
	eglChooseConfig(display, configAttribs, &config, 1, &configs);
	EGLint contextAttribs[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE };
	EGLContext context = eglCreateContext(display, configs > 0 ? config : EGL_NO_CONFIG_KHR,
		EGL_NO_CONTEXT, contextAttribs);
	if (context == EGL_NO_CONTEXT
		|| !eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
		fprintf(stderr, "glbw: no surfaceless GLES 3 context\n");
		return 1;
	}

	GLuint rb[4], fb;
	static const GLenum kBuffers[4] = { GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2,
		GL_COLOR_ATTACHMENT3 };
	glGenRenderbuffers(targets, rb);
	glGenFramebuffers(1, &fb);
	glBindFramebuffer(GL_FRAMEBUFFER, fb);
	for (int i = 0; i < targets; i++) {
		glBindRenderbuffer(GL_RENDERBUFFER, rb[i]);
		glRenderbufferStorage(GL_RENDERBUFFER, half ? GL_RGBA16F : GL_RGBA8, width, height);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, kBuffers[i], GL_RENDERBUFFER, rb[i]);
	}
	glDrawBuffers(targets, kBuffers);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		fprintf(stderr, "glbw: framebuffer incomplete (%s)\n", format);
		return 1;
	}
	glViewport(0, 0, width, height);

	GLuint program = glCreateProgram();
	glAttachShader(program, shader(GL_VERTEX_SHADER,
		"#version 300 es\nin vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }\n"));
	char fragment[512] = "#version 300 es\nprecision mediump float;\n";
	for (int i = 0; i < targets; i++) {
		snprintf(fragment + strlen(fragment), sizeof(fragment) - strlen(fragment),
			"layout(location = %d) out vec4 c%d;\n", i, i);
	}
	strcat(fragment, "void main() {\n");
	for (int i = 0; i < targets; i++) {
		snprintf(fragment + strlen(fragment), sizeof(fragment) - strlen(fragment),
			"c%d = vec4(1.0, 0.5, %d.0 / 4.0, 1.0);\n", i, i);
	}
	strcat(fragment, "}\n");
	glAttachShader(program, shader(GL_FRAGMENT_SHADER, fragment));
	glBindAttribLocation(program, 0, "p");
	glLinkProgram(program);
	glUseProgram(program);
	static const GLfloat small[] = { -0.01f, -0.01f, 0.01f, -0.01f, 0.0f, 0.01f };
	static const GLfloat cover[] = { -1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1 };
	GLuint vb;
	glGenBuffers(1, &vb);
	glBindBuffer(GL_ARRAY_BUFFER, vb);
	if (full)
		glBufferData(GL_ARRAY_BUFFER, sizeof(cover), cover, GL_STATIC_DRAW);
	else
		glBufferData(GL_ARRAY_BUFFER, sizeof(small), small, GL_STATIC_DRAW);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
	glEnableVertexAttribArray(0);

	/* the first pass clears, so a "load" pass loads defined contents */
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);
	glFinish();

	double start = now();
	printf("GBW start %.3f\n", start);
	fflush(stdout);
	long passes = 0;
	while (now() - start < secs) {
		if (load) {
			glDrawArrays(GL_TRIANGLES, 0, full ? 6 : 3);
		} else {
			glClearColor((passes & 1) ? 1.0f : 0.0f, 0.0f, 0.0f, 1.0f);
			glClear(GL_COLOR_BUFFER_BIT);
		}
		glFinish();
		passes++;
	}
	double end = now();
	double elapsed = end - start;
	double mb = (double)width * height * (half ? 8 : 4) * targets * passes / 1e6;
	printf("GBW %s %s x%d %dx%d: %.2f ms/pass, %ld passes in %.2f s (%.1f/s), %.1f MB/s stored, "
		"%.1f MB/s loaded\n", mode, format, targets, width, height, 1000 * elapsed / passes, passes, elapsed,
		passes / elapsed, mb / elapsed, load ? mb / elapsed : 0.0);
	printf("GBW end %.3f\n", end);
	glGetError() == GL_NO_ERROR ? (void)0 : fprintf(stderr, "glbw: a GL error\n");
	eglTerminate(display);
	return 0;
}
