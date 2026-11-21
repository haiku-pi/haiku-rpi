/*
 * glmipnpot — glGenerateMipmap on power-of-two and non-power-of-two textures, each level read back
 * two ways: through the sampler (texelFetch of level L into a framebuffer of the level's size) and
 * through a framebuffer with level L attached (glReadPixels). Level 0 is a smooth gradient (red
 * along x, green along y), so every correct mipmap is close to the same gradient whatever the
 * filter; a level laid out differently from how it is read comes back far off it.
 * V3D: the Phoenix-RTOS port saw the TFU's multi-level mode lay out the small levels of
 * non-power-of-two textures wrongly; this checks it here (docs/design/gpu-v3d.md §6). Headless
 * (EGL surfaceless or a pbuffer, OpenGL ES 3); RGBA8 and RGB8 (Quake II's solid textures).
 *
 *   glmipnpot
 *
 * Lines "GLM rgba8|rgb8 <w>x<h> level <L> <lw>x<lh> sample max <e> mean <m> read max <e> mean <m> ok|BAD",
 * then "GLM PASS|FAIL (N bad levels)". Exit status 0 = PASS.
 */

#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SAY(...) do { printf("GLM " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

/* A correct level is within a few steps of the gradient; the limit allows for the filter's
 * footprint at the smallest levels (a texel there averages up to 2^L source texels). */
static int
limit(int w, int h, int level)
{
	int span = 1 << level;
	int a = 255 * span / w, b = 255 * span / h;
	return 12 + (a > b ? a : b);
}

static GLuint
program(void)
{
	static const char *vs =
		"#version 300 es\n"
		"in vec2 position;\n"
		"void main() { gl_Position = vec4(position, 0.0, 1.0); }\n";
	static const char *fs =
		"#version 300 es\n"
		"precision highp float;\n"
		"uniform highp sampler2D tex;\n"
		"uniform int level;\n"
		"out vec4 colour;\n"
		"void main() { colour = texelFetch(tex, ivec2(gl_FragCoord.xy), level); }\n";
	GLuint p = glCreateProgram();
	const char *src[2] = { vs, fs };
	GLenum type[2] = { GL_VERTEX_SHADER, GL_FRAGMENT_SHADER };
	for (int i = 0; i < 2; i++) {
		GLuint s = glCreateShader(type[i]);
		glShaderSource(s, 1, &src[i], NULL);
		glCompileShader(s);
		GLint ok = 0;
		glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
		if (!ok) {
			char log[512] = "";
			glGetShaderInfoLog(s, sizeof(log), NULL, log);
			SAY("shader: %s", log);
			exit(1);
		}
		glAttachShader(p, s);
	}
	glBindAttribLocation(p, 0, "position");
	glLinkProgram(p);
	return p;
}

/* the largest and the mean distance of the level's red/green from the gradient */
static void
measure(const unsigned char *pixels, int lw, int lh, int *max, double *mean)
{
	long sum = 0;
	*max = 0;
	for (int y = 0; y < lh; y++) {
		for (int x = 0; x < lw; x++) {
			const unsigned char *p = pixels + (y * lw + x) * 4;
			int er = abs(p[0] - (int)((x + 0.5) * 255 / lw));
			int eg = abs(p[1] - (int)((y + 0.5) * 255 / lh));
			int e = er > eg ? er : eg;
			if (e > *max)
				*max = e;
			sum += e;
		}
	}
	*mean = (double)sum / (lw * lh);
}

static int
test(GLuint prog, int w, int h, GLenum internal)
{
	int bad = 0;
	int bpp = internal == GL_RGB8 ? 3 : 4;
	unsigned char *data = malloc((size_t)w * h * bpp);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			unsigned char *p = data + (y * w + x) * bpp;
			p[0] = (x + 0.5) * 255 / w;
			p[1] = (y + 0.5) * 255 / h;
			p[2] = 128;
			if (bpp == 4)
				p[3] = 255;
		}
	}
	GLuint tex;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glTexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, bpp == 3 ? GL_RGB : GL_RGBA,
		GL_UNSIGNED_BYTE, data);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST_MIPMAP_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glGenerateMipmap(GL_TEXTURE_2D);
	free(data);

	int levels = 1;
	for (int s = (w > h ? w : h); s > 1; s >>= 1)
		levels++;
	for (int level = 1; level < levels; level++) {
		int lw = w >> level, lh = h >> level;
		if (lw < 1) lw = 1;
		if (lh < 1) lh = 1;
		unsigned char *pixels = malloc((size_t)lw * lh * 4);
		int sMax, rMax;
		double sMean, rMean;

		/* through the sampler */
		GLuint rb, fb;
		glGenRenderbuffers(1, &rb);
		glBindRenderbuffer(GL_RENDERBUFFER, rb);
		glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, lw, lh);
		glGenFramebuffers(1, &fb);
		glBindFramebuffer(GL_FRAMEBUFFER, fb);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
		glViewport(0, 0, lw, lh);
		glUseProgram(prog);
		glUniform1i(glGetUniformLocation(prog, "tex"), 0);
		glUniform1i(glGetUniformLocation(prog, "level"), level);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glReadPixels(0, 0, lw, lh, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
		measure(pixels, lw, lh, &sMax, &sMean);
		glDeleteFramebuffers(1, &fb);
		glDeleteRenderbuffers(1, &rb);

		/* through a framebuffer with the level attached */
		glGenFramebuffers(1, &fb);
		glBindFramebuffer(GL_FRAMEBUFFER, fb);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, level);
		memset(pixels, 0, (size_t)lw * lh * 4);
		glReadPixels(0, 0, lw, lh, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
		measure(pixels, lw, lh, &rMax, &rMean);
		glBindFramebuffer(GL_FRAMEBUFFER, 0);
		glDeleteFramebuffers(1, &fb);
		free(pixels);

		int l = limit(w, h, level);
		int ok = sMax <= l && rMax <= l;
		if (!ok)
			bad++;
		SAY("%s %dx%d level %d %dx%d sample max %d mean %.1f read max %d mean %.1f (limit %d) %s",
			internal == GL_RGB8 ? "rgb8" : "rgba8", w, h, level, lw, lh, sMax, sMean, rMax, rMean, l, ok ? "ok" : "BAD");
	}
	glDeleteTextures(1, &tex);
	GLenum error = glGetError();
	if (error != GL_NO_ERROR) {
		SAY("%dx%d: GL error 0x%x", w, h, error);
		bad++;
	}
	return bad;
}

int
main(void)
{
	EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL)) {
		SAY("eglInitialize failed 0x%x", eglGetError());
		return 1;
	}
	eglBindAPI(EGL_OPENGL_ES_API);
	static const EGLint configAttributes[] = {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE
	};
	EGLConfig config = NULL;
	EGLint count = 0;
	eglChooseConfig(display, configAttributes, &config, 1, &count);
	static const EGLint contextAttributes[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
	EGLContext context = eglCreateContext(display, count > 0 ? config : NULL, EGL_NO_CONTEXT,
		contextAttributes);
	if (context == EGL_NO_CONTEXT) {
		SAY("eglCreateContext failed 0x%x", eglGetError());
		return 1;
	}
	EGLSurface surface = EGL_NO_SURFACE;
	if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
		static const EGLint pbuffer[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
		surface = eglCreatePbufferSurface(display, config, pbuffer);
		if (!eglMakeCurrent(display, surface, surface, context)) {
			SAY("eglMakeCurrent failed 0x%x", eglGetError());
			return 1;
		}
	}
	SAY("renderer: %s", (const char *)glGetString(GL_RENDERER));
	SAY("version: %s", (const char *)glGetString(GL_VERSION));

	static const GLfloat quad[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
	GLuint vbo;
	glGenBuffers(1, &vbo);
	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
	glEnableVertexAttribArray(0);
	GLuint prog = program();

	/* power-of-two controls, then Quake II's model skins and other non-power-of-two sizes */
	static const int sizes[][2] = {
		{ 256, 256 }, { 256, 64 }, { 64, 128 },
		{ 288, 195 }, { 260, 195 }, { 296, 164 }, { 308, 154 }, { 200, 100 }, { 136, 60 },
		{ 100, 100 }, { 640, 480 }, { 1000, 1 }, { 3, 300 },
	};
	int bad = 0;
	for (unsigned i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
		bad += test(prog, sizes[i][0], sizes[i][1], GL_RGBA8);
		bad += test(prog, sizes[i][0], sizes[i][1], GL_RGB8);
	}
	SAY("%s (%d bad levels)", bad == 0 ? "PASS" : "FAIL", bad);

	eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	if (surface != EGL_NO_SURFACE)
		eglDestroySurface(display, surface);
	eglDestroyContext(display, context);
	eglTerminate(display);
	return bad == 0 ? 0 : 1;
}
