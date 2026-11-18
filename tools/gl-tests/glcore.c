/*
 * glcore — renders and reads back what OpenGL 3.2 and 3.3 core add over 3.1 (docs/design/desktop-gl.md),
 * in a surfaceless EGL core-profile context: depth clamping (on V3D 4.2 emulated in the shaders, so the
 * cases where an emulation can go wrong get their own checks), geometry shaders, seamless cube maps,
 * multisample textures, base vertex, provoking vertex, fences, BGRA and 2_10_10_10 vertex formats,
 * dual-source blending, RGB10_A2UI render targets, timer queries.
 *
 *   glcore [-v]       -v: print the values of passing checks too
 *
 * Lines start with "GLC "; "GLC check NAME: ok|BAD ..." per check, "GLC note ..." for behaviour that is
 * reported but not graded, the last line "GLC PASS" or "GLC FAIL" (exit status 0 / 1).
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>
#define GL_GLEXT_PROTOTYPES
#include <GL/glcorearb.h>

#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAY(...) do { printf("GLC " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
#define SIZE 64

static int sFailures = 0;
static bool sVerbose = false;

static void
check(bool ok, const char *name, const char *format, ...)
{
	char detail[256] = "";
	va_list args;
	va_start(args, format);
	vsnprintf(detail, sizeof(detail), format, args);
	va_end(args);
	if (!ok)
		sFailures++;
	if (!ok || sVerbose)
		SAY("check %s: %s %s", name, ok ? "ok" : "BAD", detail);
	else
		SAY("check %s: ok", name);
}

/* a GL error left by a section: named, so that the failing call can be found */
static void
errors(const char *where)
{
	GLenum error;
	while ((error = glGetError()) != GL_NO_ERROR) {
		SAY("note GL error 0x%x after %s", error, where);
		sFailures++;
	}
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
		char log[1024] = "";
		glGetShaderInfoLog(shader, sizeof(log), NULL, log);
		SAY("shader compile failed: %s", log);
		sFailures++;
	}
	return shader;
}

/* vs, gs (or NULL), fs; varyings (or NULL): transform feedback of those */
static GLuint
program(const char *vs, const char *gs, const char *fs, const char *varying)
{
	GLuint p = glCreateProgram();
	glAttachShader(p, compile(GL_VERTEX_SHADER, vs));
	if (gs != NULL)
		glAttachShader(p, compile(GL_GEOMETRY_SHADER, gs));
	if (fs != NULL)
		glAttachShader(p, compile(GL_FRAGMENT_SHADER, fs));
	if (varying != NULL)
		glTransformFeedbackVaryings(p, 1, &varying, GL_INTERLEAVED_ATTRIBS);
	glLinkProgram(p);
	GLint ok = 0;
	glGetProgramiv(p, GL_LINK_STATUS, &ok);
	if (!ok) {
		char log[1024] = "";
		glGetProgramInfoLog(p, sizeof(log), NULL, log);
		SAY("program link failed: %s", log);
		sFailures++;
	}
	return p;
}

static const char *kVsPos =
	"#version 150\n"
	"in vec4 pos;\n"
	"void main() { gl_Position = pos; }\n";
static const char *kFsRed =
	"#version 150\n"
	"out vec4 color;\n"
	"void main() { color = vec4(1.0, 0.0, 0.0, 1.0); }\n";
static const char *kFsGreen =
	"#version 150\n"
	"out vec4 color;\n"
	"void main() { color = vec4(0.0, 1.0, 0.0, 1.0); }\n";
static const char *kFsDepth2 =
	"#version 150\n"
	"out vec4 color;\n"
	"void main() { color = vec4(1.0, 0.0, 0.0, 1.0); gl_FragDepth = 2.0; }\n";
static const char *kFsFragZ =
	"#version 150\n"
	"out vec4 color;\n"
	"void main() { color = vec4(gl_FragCoord.z, 0.0, 0.0, 1.0); }\n";
static const char *kGsPass =
	"#version 150\n"
	"layout(triangles) in;\n"
	"layout(triangle_strip, max_vertices = 3) out;\n"
	"void main() {\n"
	"	for (int i = 0; i < 3; i++) { gl_Position = gl_in[i].gl_Position; EmitVertex(); }\n"
	"	EndPrimitive();\n"
	"}\n";

static GLuint sVao, sVbo;

/* a framebuffer: RGBA8 (or RGBA32F) color + 24-bit depth, SIZE x SIZE (samples > 0: multisampled
 * renderbuffers) */
struct fbo {
	GLuint fb, color, depth;
};

static struct fbo
make_fbo(GLenum colorFormat, int samples)
{
	struct fbo f;
	glGenFramebuffers(1, &f.fb);
	glBindFramebuffer(GL_FRAMEBUFFER, f.fb);
	glGenRenderbuffers(1, &f.color);
	glBindRenderbuffer(GL_RENDERBUFFER, f.color);
	glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, colorFormat, SIZE, SIZE);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, f.color);
	glGenRenderbuffers(1, &f.depth);
	glBindRenderbuffer(GL_RENDERBUFFER, f.depth);
	glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_DEPTH24_STENCIL8, SIZE, SIZE);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, f.depth);
	GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	if (status != GL_FRAMEBUFFER_COMPLETE) {
		SAY("framebuffer incomplete 0x%x", status);
		sFailures++;
	}
	glViewport(0, 0, SIZE, SIZE);
	return f;
}

static void
free_fbo(struct fbo *f)
{
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glDeleteFramebuffers(1, &f->fb);
	glDeleteRenderbuffers(1, &f->color);
	glDeleteRenderbuffers(1, &f->depth);
}

static void
clear(void)
{
	glClearColor(0, 0, 0, 0);
	glClearDepth(1.0);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
}

static void
draw(GLuint prog, const float *vertices, int count)
{
	glUseProgram(prog);
	glBindVertexArray(sVao);
	glBindBuffer(GL_ARRAY_BUFFER, sVbo);
	glBufferData(GL_ARRAY_BUFFER, count * 4 * sizeof(float), vertices, GL_STREAM_DRAW);
	GLint loc = glGetAttribLocation(prog, "pos");
	glEnableVertexAttribArray(loc);
	glVertexAttribPointer(loc, 4, GL_FLOAT, GL_FALSE, 0, 0);
	glDrawArrays(GL_TRIANGLES, 0, count);
}

static float sDepth[SIZE * SIZE];
static uint8_t sColor[SIZE * SIZE * 4];
static float sColorF[SIZE * SIZE * 4];

static void
read_back(bool floatColor)
{
	glFinish();
	glPixelStorei(GL_PACK_ALIGNMENT, 1);
	glReadPixels(0, 0, SIZE, SIZE, GL_DEPTH_COMPONENT, GL_FLOAT, sDepth);
	if (floatColor)
		glReadPixels(0, 0, SIZE, SIZE, GL_RGBA, GL_FLOAT, sColorF);
	else
		glReadPixels(0, 0, SIZE, SIZE, GL_RGBA, GL_UNSIGNED_BYTE, sColor);
}

static int
covered(void)
{
	int n = 0;
	for (int i = 0; i < SIZE * SIZE; i++)
		n += sColor[i * 4] > 128 || sColor[i * 4 + 1] > 128;
	return n;
}

static bool
is_red(int x, int y)
{
	const uint8_t *p = &sColor[(y * SIZE + x) * 4];
	return p[0] > 250 && p[1] < 5 && p[2] < 5;
}

static float
depth_at(int x, int y)
{
	return sDepth[y * SIZE + x];
}

/* a triangle around the centre, all at clip-space z, w */
static void
flat_triangle(float *v, float z, float w)
{
	const float xy[3][2] = { { -0.8f, -0.8f }, { 0.8f, -0.8f }, { 0.0f, 0.8f } };
	for (int i = 0; i < 3; i++) {
		v[i * 4 + 0] = xy[i][0] * w;
		v[i * 4 + 1] = xy[i][1] * w;
		v[i * 4 + 2] = z * w;
		v[i * 4 + 3] = w;
	}
}

static void
test_depth_clamp(void)
{
	GLuint red = program(kVsPos, NULL, kFsRed, NULL);
	GLuint redGs = program(kVsPos, kGsPass, kFsRed, NULL);
	GLuint depth2 = program(kVsPos, NULL, kFsDepth2, NULL);
	struct fbo f = make_fbo(GL_RGBA8, 0);
	glEnable(GL_DEPTH_TEST);
	glDepthFunc(GL_ALWAYS);
	float v[12];
	const int cx = SIZE / 2, cy = SIZE / 2;

	/* beyond the far plane */
	flat_triangle(v, 1.5f, 1.0f);
	glDisable(GL_DEPTH_CLAMP);
	clear();
	draw(red, v, 3);
	read_back(false);
	check(covered() == 0, "clamp-off-far-clipped", "%d pixels drawn", covered());
	glEnable(GL_DEPTH_CLAMP);
	check(glIsEnabled(GL_DEPTH_CLAMP) && glGetError() == GL_NO_ERROR, "clamp-enable", "");
	clear();
	draw(red, v, 3);
	read_back(false);
	check(is_red(cx, cy) && fabsf(depth_at(cx, cy) - 1.0f) < 1e-6f, "clamp-far",
		"red %d depth %.7f (1)", is_red(cx, cy), depth_at(cx, cy));
	int fullCoverage = covered();

	/* in front of the near plane, perspective w */
	flat_triangle(v, -1.5f, 2.5f);
	clear();
	draw(red, v, 3);
	read_back(false);
	check(is_red(cx, cy) && fabsf(depth_at(cx, cy)) < 1e-6f, "clamp-near",
		"red %d depth %.7f (0)", is_red(cx, cy), depth_at(cx, cy));

	/* a depth range */
	glDepthRange(0.25, 0.75);
	flat_triangle(v, 1.5f, 1.0f);
	clear();
	draw(red, v, 3);
	read_back(false);
	check(fabsf(depth_at(cx, cy) - 0.75f) < 1e-6f, "clamp-far-range", "depth %.7f (0.75)",
		depth_at(cx, cy));
	flat_triangle(v, -1.5f, 1.0f);
	clear();
	draw(red, v, 3);
	read_back(false);
	check(fabsf(depth_at(cx, cy) - 0.25f) < 1e-6f, "clamp-near-range", "depth %.7f (0.25)",
		depth_at(cx, cy));

	/* gl_FragDepth = 2.0: clamped to the range with clamping, to 0..1 without */
	flat_triangle(v, 0.0f, 1.0f);
	clear();
	draw(depth2, v, 3);
	read_back(false);
	check(fabsf(depth_at(cx, cy) - 0.75f) < 1e-6f, "clamp-fragdepth", "depth %.7f (0.75)",
		depth_at(cx, cy));
	glDisable(GL_DEPTH_CLAMP);
	clear();
	draw(depth2, v, 3);
	read_back(false);
	check(fabsf(depth_at(cx, cy) - 1.0f) < 1e-6f, "noclamp-fragdepth", "depth %.7f (1)",
		depth_at(cx, cy));
	glDepthRange(0.0, 1.0);

	/* a geometry shader as the last stage */
	glEnable(GL_DEPTH_CLAMP);
	flat_triangle(v, 1.5f, 1.0f);
	clear();
	draw(redGs, v, 3);
	read_back(false);
	check(is_red(cx, cy) && fabsf(depth_at(cx, cy) - 1.0f) < 1e-6f, "clamp-far-gs",
		"red %d depth %.7f (1)", is_red(cx, cy), depth_at(cx, cy));

	/* inside the planes, perspective: the same depth with and without clamping */
	const float persp[12] = {
		-0.8f, -0.8f, -0.3f, 1.0f,
		0.8f * 3, -0.8f * 3, 0.6f * 3, 3.0f,
		0.0f, 0.8f * 2, 0.2f * 2, 2.0f,
	};
	static float reference[SIZE * SIZE];
	glDisable(GL_DEPTH_CLAMP);
	clear();
	draw(red, persp, 3);
	read_back(false);
	memcpy(reference, sDepth, sizeof(reference));
	int refCovered = covered();
	glEnable(GL_DEPTH_CLAMP);
	clear();
	draw(red, persp, 3);
	read_back(false);
	float worst = 0;
	for (int i = 0; i < SIZE * SIZE; i++) {
		if (sColor[i * 4] > 128)
			worst = fmaxf(worst, fabsf(sDepth[i] - reference[i]));
	}
	check(covered() == refCovered && worst < 1e-5f, "clamp-same-depth-inside",
		"%d/%d pixels, largest difference %.2e", covered(), refCovered, worst);

	/* gl_FragCoord.z sees the depth (a float color target) */
	struct fbo ff = make_fbo(GL_RGBA32F, 0);
	GLuint fragZ = program(kVsPos, NULL, kFsFragZ, NULL);
	clear();
	draw(fragZ, persp, 3);
	read_back(true);
	worst = 0;
	int n = 0;
	for (int i = 0; i < SIZE * SIZE; i++) {
		if (sColorF[i * 4 + 3] > 0.5f) {
			worst = fmaxf(worst, fabsf(sColorF[i * 4] - reference[i]));
			n++;
		}
	}
	check(n == refCovered && worst < 1e-5f, "clamp-fragcoord-z", "%d pixels, largest difference %.2e",
		n, worst);
	free_fbo(&ff);
	glBindFramebuffer(GL_FRAMEBUFFER, f.fb);
	errors("depth clamp, depth range, FragDepth, GS, FragCoord.z");

	/* crossing the near plane: not clipped with clamping, clamped to 0 where in front */
	const float cross[12] = {
		-0.8f, -0.8f, -3.0f, 1.0f,
		0.8f, -0.8f, 0.5f, 1.0f,
		0.0f, 0.8f, 0.5f, 1.0f,
	};
	glDisable(GL_DEPTH_CLAMP);
	clear();
	draw(red, cross, 3);
	read_back(false);
	int clipped = covered();
	glEnable(GL_DEPTH_CLAMP);
	clear();
	draw(red, cross, 3);
	read_back(false);
	check(covered() == fullCoverage && clipped < fullCoverage && fabsf(depth_at(SIZE / 8 + 2, SIZE / 8 + 2)) < 1e-6f,
		"clamp-cross-near", "%d pixels (unclamped %d, whole %d), corner depth %.7f", covered(), clipped,
		fullCoverage, depth_at(SIZE / 8 + 2, SIZE / 8 + 2));

	/* crossing w = 0 (a vertex behind the eye): only what is in front is drawn */
	const float behind[12] = {
		-0.5f, -0.5f, 0.5f, -1.0f,
		0.8f, -0.8f, 0.5f, 1.0f,
		0.0f, 0.8f, 0.5f, 1.0f,
	};
	glDisable(GL_DEPTH_CLAMP);
	clear();
	draw(red, behind, 3);
	read_back(false);
	int behindOff = covered();
	glEnable(GL_DEPTH_CLAMP);
	clear();
	draw(red, behind, 3);
	read_back(false);
	bool finite = true;
	for (int i = 0; i < SIZE * SIZE; i++) {
		if (sColor[i * 4] > 128 && !(sDepth[i] >= 0.0f && sDepth[i] <= 1.0f))
			finite = false;
	}
	check(finite && covered() >= behindOff, "clamp-behind-eye", "%d pixels (unclamped %d), depths in 0..1: %d",
		covered(), behindOff, finite);
	errors("near plane, behind the eye");

	/* polygon offset while clamping: the same depths as the hardware's offset without clamping (units, and
	 * factor on a sloped triangle), and the offset triangle wins the LESS test over its unoffset twin */
	glDepthFunc(GL_LESS);
	GLuint green = program(kVsPos, NULL, kFsGreen, NULL);
	const float sloped[12] = {
		-0.8f, -0.8f, -0.6f, 1.0f,
		0.8f, -0.8f, 0.2f, 1.0f,
		0.0f, 0.8f, 0.7f, 1.0f,
	};
	static const struct { const char *name; float factor, units; } kOffsets[] = {
		{ "units", 0.0f, -100.0f }, { "factor", -4.0f, 0.0f }, { "both", 2.0f, 50.0f },
	};
	for (size_t k = 0; k < sizeof(kOffsets) / sizeof(kOffsets[0]); k++) {
		static float off[SIZE * SIZE];
		bool redWins[2] = { false, false };
		int pixels = 0;
		for (int pass = 0; pass < 2; pass++) {
			if (pass == 0)
				glDisable(GL_DEPTH_CLAMP);
			else
				glEnable(GL_DEPTH_CLAMP);
			clear();
			glDisable(GL_POLYGON_OFFSET_FILL);
			if (kOffsets[k].units < 0 || kOffsets[k].factor < 0)
				draw(green, sloped, 3);
			glEnable(GL_POLYGON_OFFSET_FILL);
			glPolygonOffset(kOffsets[k].factor, kOffsets[k].units);
			draw(red, sloped, 3);
			glDisable(GL_POLYGON_OFFSET_FILL);
			read_back(false);
			redWins[pass] = is_red(cx, cy);
			if (pass == 0) {
				memcpy(off, sDepth, sizeof(off));
				continue;
			}
			worst = 0;
			for (int i = 0; i < SIZE * SIZE; i++) {
				if (sColor[i * 4] > 128) {
					worst = fmaxf(worst, fabsf(sDepth[i] - off[i]));
					pixels++;
				}
			}
		}
		char name[64];
		snprintf(name, sizeof(name), "clamp-polygon-offset-%s", kOffsets[k].name);
		/* the slope term is the implementation's estimate (GL: "may be approximated"): the shader's
		 * derivatives and the hardware's agree within 2e-5 of depth here (the factor terms are ~1e-2) */
		check(redWins[0] == redWins[1] && pixels > 100 && worst < (kOffsets[k].factor != 0 ? 2e-5f : 2e-6f),
			name, "red wins %d/%d, %d pixels, largest difference %.2e (depth centre %.7f)", redWins[0],
			redWins[1], pixels, worst, depth_at(cx, cy));
	}
	glDepthFunc(GL_ALWAYS);
	errors("polygon offset");

	/* transform feedback sees the program's gl_Position, not the hardware's */
	GLuint tf = program(kVsPos, NULL, kFsRed, "gl_Position");
	GLuint tfBuffer;
	glGenBuffers(1, &tfBuffer);
	glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, tfBuffer);
	glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER, 12 * sizeof(float), NULL, GL_STREAM_READ);
	flat_triangle(v, 1.5f, 1.0f);
	/* set up first: the program may not change while transform feedback is active */
	glUseProgram(tf);
	glBindBuffer(GL_ARRAY_BUFFER, sVbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(v), v, GL_STREAM_DRAW);
	glVertexAttribPointer(glGetAttribLocation(tf, "pos"), 4, GL_FLOAT, GL_FALSE, 0, 0);
	glEnableVertexAttribArray(glGetAttribLocation(tf, "pos"));
	glBeginTransformFeedback(GL_TRIANGLES);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glEndTransformFeedback();
	float captured[12] = { 0 };
	glGetBufferSubData(GL_TRANSFORM_FEEDBACK_BUFFER, 0, sizeof(captured), captured);
	check(captured[2] == 1.5f && captured[6] == 1.5f, "clamp-xfb-position", "z %.3f %.3f %.3f (1.5)",
		captured[2], captured[6], captured[10]);
	glDeleteBuffers(1, &tfBuffer);
	errors("transform feedback");

	free_fbo(&f);

	/* multisampled */
	struct fbo ms = make_fbo(GL_RGBA8, 4);
	struct fbo resolved = make_fbo(GL_RGBA8, 0);
	int msCovered[2];
	for (int pass = 0; pass < 2; pass++) {
		/* the reference: inside the planes, unclamped; then beyond the far plane, clamped */
		if (pass == 0)
			glDisable(GL_DEPTH_CLAMP);
		else
			glEnable(GL_DEPTH_CLAMP);
		glBindFramebuffer(GL_FRAMEBUFFER, ms.fb);
		flat_triangle(v, pass == 0 ? 0.5f : 1.5f, 1.0f);
		clear();
		draw(red, v, 3);
		glBindFramebuffer(GL_READ_FRAMEBUFFER, ms.fb);
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, resolved.fb);
		glBlitFramebuffer(0, 0, SIZE, SIZE, 0, 0, SIZE, SIZE, GL_COLOR_BUFFER_BIT, GL_NEAREST);
		glBindFramebuffer(GL_FRAMEBUFFER, resolved.fb);
		glFinish();
		glPixelStorei(GL_PACK_ALIGNMENT, 1);
		glReadPixels(0, 0, SIZE, SIZE, GL_RGBA, GL_UNSIGNED_BYTE, sColor);
		msCovered[pass] = covered();
	}
	check(is_red(cx, cy) && msCovered[1] == msCovered[0], "clamp-msaa", "red %d, %d pixels (unclamped inside: %d)",
		is_red(cx, cy), msCovered[1], msCovered[0]);
	errors("msaa");
	free_fbo(&ms);
	free_fbo(&resolved);
	glDisable(GL_DEPTH_CLAMP);
	glDisable(GL_DEPTH_TEST);
	check(glGetError() == GL_NO_ERROR, "clamp-no-gl-error", "");
}

static void
test_features(void)
{
	struct fbo f = make_fbo(GL_RGBA8, 0);
	const int cx = SIZE / 2, cy = SIZE / 2;
	float v[12];

	/* geometry shader: a point becomes a triangle */
	GLuint gs = program(kVsPos,
		"#version 150\n"
		"layout(points) in;\n"
		"layout(triangle_strip, max_vertices = 3) out;\n"
		"void main() {\n"
		"	vec4 c = gl_in[0].gl_Position;\n"
		"	gl_Position = c + vec4(-0.5, -0.5, 0, 0); EmitVertex();\n"
		"	gl_Position = c + vec4(0.5, -0.5, 0, 0); EmitVertex();\n"
		"	gl_Position = c + vec4(0.0, 0.5, 0, 0); EmitVertex();\n"
		"	EndPrimitive();\n"
		"}\n", kFsRed, NULL);
	const float point[4] = { 0, 0, 0, 1 };
	clear();
	glUseProgram(gs);
	glBindBuffer(GL_ARRAY_BUFFER, sVbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(point), point, GL_STREAM_DRAW);
	glVertexAttribPointer(glGetAttribLocation(gs, "pos"), 4, GL_FLOAT, GL_FALSE, 0, 0);
	glDrawArrays(GL_POINTS, 0, 1);
	read_back(false);
	check(is_red(cx, cy) && covered() > 100, "geometry-shader", "%d pixels", covered());

	/* base vertex */
	flat_triangle(v, 0.0f, 1.0f);
	float twice[24];
	memset(twice, 0, sizeof(twice));
	memcpy(twice + 12, v, sizeof(v));
	GLuint red = program(kVsPos, NULL, kFsRed, NULL);
	glUseProgram(red);
	glBufferData(GL_ARRAY_BUFFER, sizeof(twice), twice, GL_STREAM_DRAW);
	glVertexAttribPointer(glGetAttribLocation(red, "pos"), 4, GL_FLOAT, GL_FALSE, 0, 0);
	GLuint ibo;
	glGenBuffers(1, &ibo);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
	const GLushort indices[3] = { 0, 1, 2 };
	glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);
	clear();
	glDrawElementsBaseVertex(GL_TRIANGLES, 3, GL_UNSIGNED_SHORT, 0, 3);
	read_back(false);
	check(is_red(cx, cy), "base-vertex", "");

	/* provoking vertex: the first vertex's flat color */
	GLuint flat = program(
		"#version 150\n"
		"in vec4 pos;\n"
		"flat out vec4 c;\n"
		"void main() { gl_Position = pos; c = vec4(gl_VertexID == 0, gl_VertexID == 2, 0, 1); }\n",
		NULL,
		"#version 150\n"
		"flat in vec4 c;\n"
		"out vec4 color;\n"
		"void main() { color = c; }\n", NULL);
	glProvokingVertex(GL_FIRST_VERTEX_CONVENTION);
	clear();
	draw(flat, v, 3);
	read_back(false);
	bool first = is_red(cx, cy);
	glProvokingVertex(GL_LAST_VERTEX_CONVENTION);
	clear();
	draw(flat, v, 3);
	read_back(false);
	const uint8_t *p = &sColor[(cy * SIZE + cx) * 4];
	check(first && p[1] > 250 && p[0] < 5, "provoking-vertex", "first %d, last %d/%d/%d", first, p[0], p[1], p[2]);

	/* BGRA vertex colors and 2_10_10_10_REV */
	GLuint attr = program(
		"#version 150\n"
		"in vec4 pos;\n"
		"in vec4 col;\n"
		"out vec4 c;\n"
		"void main() { gl_Position = pos; c = col; }\n",
		NULL,
		"#version 150\n"
		"in vec4 c;\n"
		"out vec4 color;\n"
		"void main() { color = c; }\n", NULL);
	glUseProgram(attr);
	GLint posLoc = glGetAttribLocation(attr, "pos"), colLoc = glGetAttribLocation(attr, "col");
	GLuint colors;
	glGenBuffers(1, &colors);
	glBindBuffer(GL_ARRAY_BUFFER, sVbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(v), v, GL_STREAM_DRAW);
	glVertexAttribPointer(posLoc, 4, GL_FLOAT, GL_FALSE, 0, 0);
	glEnableVertexAttribArray(colLoc);
	glBindBuffer(GL_ARRAY_BUFFER, colors);
	const uint8_t bgra[12] = { 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255 };   /* blue */
	glBufferData(GL_ARRAY_BUFFER, sizeof(bgra), bgra, GL_STREAM_DRAW);
	glVertexAttribPointer(colLoc, GL_BGRA, GL_UNSIGNED_BYTE, GL_TRUE, 0, 0);
	clear();
	glDrawArrays(GL_TRIANGLES, 0, 3);
	read_back(false);
	check(p[2] > 250 && p[0] < 5, "vertex-bgra", "%d/%d/%d (0/0/255)", p[0], p[1], p[2]);
	const uint32_t packed = (3u << 30) | (0u << 20) | (1023u << 10) | 0u;   /* r 0, g 1, b 0, a 1 */
	const uint32_t rev[3] = { packed, packed, packed };
	glBufferData(GL_ARRAY_BUFFER, sizeof(rev), rev, GL_STREAM_DRAW);
	glVertexAttribPointer(colLoc, 4, GL_UNSIGNED_INT_2_10_10_10_REV, GL_TRUE, 0, 0);
	clear();
	glDrawArrays(GL_TRIANGLES, 0, 3);
	read_back(false);
	check(p[1] > 250 && p[0] < 5 && p[2] < 5, "vertex-2-10-10-10", "%d/%d/%d (0/255/0)", p[0], p[1], p[2]);
	glDisableVertexAttribArray(colLoc);
	glDeleteBuffers(1, &colors);

	/* dual-source blending */
	GLuint dual = program(kVsPos, NULL,
		"#version 330\n"
		"layout(location = 0, index = 0) out vec4 color;\n"
		"layout(location = 0, index = 1) out vec4 factor;\n"
		"void main() { color = vec4(1.0); factor = vec4(0.5, 0.25, 1.0, 1.0); }\n", NULL);
	glEnable(GL_BLEND);
	glBlendFunc(GL_SRC1_COLOR, GL_ZERO);
	clear();
	draw(dual, v, 3);
	glDisable(GL_BLEND);
	read_back(false);
	check(abs(p[0] - 128) <= 2 && abs(p[1] - 64) <= 2 && p[2] > 250, "dual-source-blend",
		"%d/%d/%d (128/64/255)", p[0], p[1], p[2]);

	/* fence */
	GLsync sync = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
	GLenum waited = glClientWaitSync(sync, GL_SYNC_FLUSH_COMMANDS_BIT, 1000000000ull);
	check(waited == GL_ALREADY_SIGNALED || waited == GL_CONDITION_SATISFIED, "fence", "0x%x", waited);
	glDeleteSync(sync);

	/* timer queries */
	GLuint queries[2];
	glGenQueries(2, queries);
	glQueryCounter(queries[0], GL_TIMESTAMP);
	glBeginQuery(GL_TIME_ELAPSED, queries[1]);
	clear();
	for (int i = 0; i < 20; i++)
		draw(red, v, 3);
	glEndQuery(GL_TIME_ELAPSED);
	GLuint64 stamp = 0, elapsed = 0;
	glGetQueryObjectui64v(queries[0], GL_QUERY_RESULT, &stamp);
	glGetQueryObjectui64v(queries[1], GL_QUERY_RESULT, &elapsed);
	check(stamp > 0 && elapsed > 0 && elapsed < 1000000000ull, "timer-query", "timestamp %llu ns, elapsed %llu ns",
		(unsigned long long)stamp, (unsigned long long)elapsed);
	glDeleteQueries(2, queries);

	free_fbo(&f);

	/* RGB10_A2UI render target */
	GLuint fb, rb;
	glGenFramebuffers(1, &fb);
	glBindFramebuffer(GL_FRAMEBUFFER, fb);
	glGenRenderbuffers(1, &rb);
	glBindRenderbuffer(GL_RENDERBUFFER, rb);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_RGB10_A2UI, SIZE, SIZE);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
	GLuint uiProg = program(kVsPos, NULL,
		"#version 330\n"
		"out uvec4 color;\n"
		"void main() { color = uvec4(1023u, 512u, 3u, 1u); }\n", NULL);
	const GLuint zero[4] = { 0, 0, 0, 0 };
	glClearBufferuiv(GL_COLOR, 0, zero);
	draw(uiProg, v, 3);
	glFinish();
	GLuint texel = 0;
	glReadPixels(cx, cy, 1, 1, GL_RGBA_INTEGER, GL_UNSIGNED_INT_2_10_10_10_REV, &texel);
	check(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
		&& texel == ((1u << 30) | (3u << 20) | (512u << 10) | 1023u), "rgb10-a2ui", "0x%08x", texel);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glDeleteFramebuffers(1, &fb);
	glDeleteRenderbuffers(1, &rb);

	/* a multisample texture, sampled with texelFetch */
	GLuint msTex, msFb;
	glGenTextures(1, &msTex);
	glBindTexture(GL_TEXTURE_2D_MULTISAMPLE, msTex);
	glTexImage2DMultisample(GL_TEXTURE_2D_MULTISAMPLE, 4, GL_RGBA8, SIZE, SIZE, GL_TRUE);
	glGenFramebuffers(1, &msFb);
	glBindFramebuffer(GL_FRAMEBUFFER, msFb);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D_MULTISAMPLE, msTex, 0);
	glClearColor(0, 0, 0, 0);
	glClear(GL_COLOR_BUFFER_BIT);
	draw(red, v, 3);
	struct fbo out = make_fbo(GL_RGBA8, 0);
	GLuint fetch = program(kVsPos, NULL,
		"#version 150\n"
		"uniform sampler2DMS tex;\n"
		"out vec4 color;\n"
		"void main() { color = texelFetch(tex, ivec2(gl_FragCoord.xy), 3); }\n", NULL);
	glUseProgram(fetch);
	glUniform1i(glGetUniformLocation(fetch, "tex"), 0);
	const float quad[24] = { -1, -1, 0, 1, 1, -1, 0, 1, 1, 1, 0, 1, -1, -1, 0, 1, 1, 1, 0, 1, -1, 1, 0, 1 };
	clear();
	draw(fetch, quad, 6);
	read_back(false);
	check(is_red(cx, cy) && !is_red(1, SIZE - 2), "texture-multisample", "centre %d corner %d", is_red(cx, cy),
		is_red(1, SIZE - 2));
	free_fbo(&out);
	glDeleteFramebuffers(1, &msFb);
	glDeleteTextures(1, &msTex);

	/* seamless cube maps: the enable is accepted; what linear filtering at a face edge gives is
	 * reported with it on and off (V3D's sampler always filters across the edge) */
	GLuint cube;
	glGenTextures(1, &cube);
	glBindTexture(GL_TEXTURE_CUBE_MAP, cube);
	for (int face = 0; face < 6; face++) {
		uint8_t texels[4 * 4 * 4];
		for (int i = 0; i < 16; i++) {
			texels[i * 4 + 0] = face == 0 ? 255 : 0;   /* +X red, others blue */
			texels[i * 4 + 1] = 0;
			texels[i * 4 + 2] = face == 0 ? 0 : 255;
			texels[i * 4 + 3] = 255;
		}
		glTexImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X + face, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE,
			texels);
	}
	glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	struct fbo cf = make_fbo(GL_RGBA8, 0);
	GLuint cubeProg = program(kVsPos, NULL,
		"#version 150\n"
		"uniform samplerCube tex;\n"
		"out vec4 color;\n"
		"void main() { color = texture(tex, vec3(1.0, 0.0, 1.0)); }\n", NULL);   /* the +X/+Z edge */
	glUseProgram(cubeProg);
	glUniform1i(glGetUniformLocation(cubeProg, "tex"), 0);
	for (int seamless = 0; seamless < 2; seamless++) {
		if (seamless)
			glEnable(GL_TEXTURE_CUBE_MAP_SEAMLESS);
		else
			glDisable(GL_TEXTURE_CUBE_MAP_SEAMLESS);
		clear();
		draw(cubeProg, quad, 6);
		read_back(false);
		SAY("note cube-edge seamless %s: %d/%d/%d", seamless ? "on" : "off", p[0], p[1], p[2]);
	}
	check(glIsEnabled(GL_TEXTURE_CUBE_MAP_SEAMLESS) && glGetError() == GL_NO_ERROR, "seamless-enable", "");
	glDisable(GL_TEXTURE_CUBE_MAP_SEAMLESS);
	free_fbo(&cf);
	glDeleteTextures(1, &cube);
	check(glGetError() == GL_NO_ERROR, "features-no-gl-error", "");
}

int
main(int argc, char **argv)
{
	int opt;
	while ((opt = getopt(argc, argv, "v")) != -1) {
		if (opt == 'v')
			sVerbose = true;
		else {
			fprintf(stderr, "usage: %s [-v]\n", argv[0]);
			return 2;
		}
	}

	EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL) || !eglBindAPI(EGL_OPENGL_API)) {
		SAY("EGL init failed 0x%x", eglGetError());
		SAY("FAIL");
		return 1;
	}
	const EGLint attribs[] = {
		EGL_CONTEXT_MAJOR_VERSION, 3,
		EGL_CONTEXT_MINOR_VERSION, 2,
		EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
		EGL_NONE
	};
	EGLContext context = eglCreateContext(display, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attribs);
	if (context == EGL_NO_CONTEXT || !eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
		SAY("no OpenGL 3.2 core context (EGL error 0x%x)", eglGetError());
		SAY("FAIL");
		return 1;
	}
	SAY("renderer: %s, %s", (const char *)glGetString(GL_RENDERER), (const char *)glGetString(GL_VERSION));

	glGenVertexArrays(1, &sVao);
	glBindVertexArray(sVao);
	glGenBuffers(1, &sVbo);

	test_depth_clamp();
	test_features();

	eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(display, context);
	eglTerminate(display);
	SAY("%s", sFailures == 0 ? "PASS" : "FAIL");
	return sFailures == 0 ? 0 : 1;
}
