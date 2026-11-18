/*
 * blender-glprobe — what Blender 3.6's OpenGL backend will find here (docs/design/blender.md, step 0).
 * The contexts are made the way Blender's GHOST_SDL makes them (SDL2 windows, SDL_GL_SHARE_WITH_CURRENT_CONTEXT),
 * then each check answers one question of the feasibility analysis:
 *
 *   ctx     a 3.3 request with profile mask 0 (what stock GHOST_SDL asks) and with the core profile (what a
 *           patched GHOST_SDL would ask): version, GLSL, profile; epoxy_gl_version() as Blender computes it
 *   caps    every limit and extension GLBackend::capabilities_init() reads (source/blender/gpu/opengl/
 *           gl_backend.cc), and the flags Blender derives from them
 *   mrt     fragment shaders with 4 and with 6 outputs (EEVEE Legacy's opaque surface shader writes locations
 *           0..5), framebuffers with 4 and 6 colour attachments
 *   float   blended draws into RGBA16F, RGBA32F and R11F_G11F_B10F render targets, read back
 *   tbo     texelFetch from buffer textures R32F, RG32F, RGBA32F, RGBA8, R32UI (hair/curves data)
 *   xfb     transform feedback capture (curves are evaluated with it when there are no compute shaders)
 *   gather  textureGather
 *   egl     (-e) two shared surfaceless EGL contexts, one current on a second thread while the main thread's
 *           is current: a texture made there is read here (the driver side of Blender's job-thread contexts)
 *   thread  (-t) the same through SDL: a hidden-window context (GHOST's offscreen context) held current on a
 *           second thread while the main thread re-activates, draws and swaps its window, then released.
 *           Stock SDL2's Haiku backend keeps one process-wide current context, so each thread unlocks the
 *           other's BGLView; our HGL only prints "wrong thread" for that and goes on (HaikuPorts' x86-64
 *           stack stopped in the debugger). Grade by those lines too (tools/pi-tests/blender-probe.sh).
 *
 *   blender-glprobe [-e] [-t] [-x]      -x: print the whole extension list
 *
 * Lines start with "BGP ". Exit status: the number of failed required checks (mrt6 and the derived flags are
 * information, not failures).
 */

#include <SDL2/SDL.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SAY(...) do { printf("BGP " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef unsigned char GLubyte;
typedef unsigned char GLboolean;
typedef char GLchar;
typedef float GLfloat;
typedef unsigned int GLbitfield;
typedef intptr_t GLintptr;
typedef intptr_t GLsizeiptr;

#define GL_VERSION 0x1F02
#define GL_RENDERER 0x1F01
#define GL_VENDOR 0x1F00
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define GL_NUM_EXTENSIONS 0x821D
#define GL_EXTENSIONS 0x1F03
#define GL_CONTEXT_PROFILE_MASK 0x9126
#define GL_TEXTURE_2D 0x0DE1
#define GL_TEXTURE_BUFFER 0x8C2A
#define GL_TEXTURE0 0x84C0
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_NEAREST 0x2600
#define GL_RGBA 0x1908
#define GL_RED 0x1903
#define GL_RGB 0x1907
#define GL_RGBA8 0x8058
#define GL_RGBA16F 0x881A
#define GL_RGBA32F 0x8814
#define GL_R32F 0x822E
#define GL_RG32F 0x8230
#define GL_R32UI 0x8236
#define GL_R11F_G11F_B10F 0x8C3A
#define GL_FLOAT 0x1406
#define GL_UNSIGNED_BYTE 0x1401
#define GL_FRAMEBUFFER 0x8D40
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_ARRAY_BUFFER 0x8892
#define GL_TRANSFORM_FEEDBACK_BUFFER 0x8C8E
#define GL_STATIC_DRAW 0x88E4
#define GL_INTERLEAVED_ATTRIBS 0x8C8C
#define GL_RASTERIZER_DISCARD 0x8C89
#define GL_POINTS 0x0000
#define GL_TRIANGLES 0x0004
#define GL_BLEND 0x0BE2
#define GL_ONE 1
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_NO_ERROR 0

/* the limits capabilities_init() reads, and the ones the analysis adds (draw buffers, buffer texture size) */
static const struct { const char *name; GLenum e; } kLimits[] = {
	{ "MAX_TEXTURE_SIZE", 0x0D33 },
	{ "MAX_ARRAY_TEXTURE_LAYERS", 0x88FF },
	{ "MAX_TEXTURE_IMAGE_UNITS", 0x8872 },
	{ "MAX_VERTEX_TEXTURE_IMAGE_UNITS", 0x8B4C },
	{ "MAX_GEOMETRY_TEXTURE_IMAGE_UNITS", 0x8C29 },
	{ "MAX_COMBINED_TEXTURE_IMAGE_UNITS", 0x8B4D },
	{ "MAX_VERTEX_UNIFORM_COMPONENTS", 0x8B4A },
	{ "MAX_FRAGMENT_UNIFORM_COMPONENTS", 0x8B49 },
	{ "MAX_ELEMENTS_INDICES", 0x80E9 },
	{ "MAX_ELEMENTS_VERTICES", 0x80E8 },
	{ "MAX_VERTEX_ATTRIBS", 0x8869 },
	{ "MAX_VARYING_FLOATS", 0x8B4B },
	{ "MAX_FRAGMENT_INPUT_COMPONENTS", 0x9125 },
	{ "MAX_3D_TEXTURE_SIZE", 0x8073 },
	{ "MAX_CUBE_MAP_TEXTURE_SIZE", 0x851C },
	{ "MAX_FRAGMENT_UNIFORM_BLOCKS", 0x8A2D },
	{ "MAX_VERTEX_UNIFORM_BLOCKS", 0x8A2B },
	{ "MAX_UNIFORM_BLOCK_SIZE", 0x8A30 },
	{ "MAX_DRAW_BUFFERS", 0x8824 },
	{ "MAX_COLOR_ATTACHMENTS", 0x8CDF },
	{ "MAX_DUAL_SOURCE_DRAW_BUFFERS", 0x88FC },
	{ "MAX_TEXTURE_BUFFER_SIZE", 0x8C2B },
	{ "MAX_GEOMETRY_OUTPUT_VERTICES", 0x8DE0 },
	{ "MAX_GEOMETRY_TOTAL_OUTPUT_COMPONENTS", 0x8DE1 },
	{ "MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS", 0x8C8B },
	{ "MAX_SAMPLES", 0x8D57 },
	{ "MAX_VERTEX_SHADER_STORAGE_BLOCKS", 0x90D6 },
	{ "MAX_FRAGMENT_SHADER_STORAGE_BLOCKS", 0x90DA },
	{ "MAX_COMPUTE_SHADER_STORAGE_BLOCKS", 0x90DB },
};

/* the extensions gl_backend.cc / gl_shader.cc test (3.6), plus 4.x/5.x hard requirements for comparison */
static const char *const kExtensions[] = {
	"GL_ARB_texture_gather", "GL_ARB_shader_draw_parameters", "GL_ARB_base_instance",
	"GL_ARB_clear_texture", "GL_ARB_copy_image", "GL_KHR_debug", "GL_ARB_debug_output",
	"GL_ARB_direct_state_access", "GL_ARB_gpu_shader5", "GL_ARB_ES3_compatibility",
	"GL_AMD_vertex_shader_layer", "GL_AMD_shader_explicit_vertex_parameter", "GL_ARB_multi_bind",
	"GL_ARB_multi_draw_indirect", "GL_ARB_texture_cube_map_array", "GL_EXT_texture_filter_anisotropic",
	"GL_ARB_vertex_attrib_binding", "GL_ARB_conservative_depth", "GL_ARB_shader_image_load_store",
	"GL_ARB_shading_language_420pack", "GL_ARB_compute_shader", "GL_ARB_shader_storage_buffer_object",
	"GL_NVX_gpu_memory_info", "GL_ATI_meminfo",
	/* Blender 4.x/5.x */
	"GL_ARB_clip_control", "GL_ARB_get_texture_sub_image", "GL_ARB_texture_view",
	"GL_ARB_shader_viewport_layer_array", "GL_ARB_shader_stencil_export", "GL_ARB_texture_barrier",
};

#define GL_FUNCS(X) \
	X(const GLubyte *, glGetString, (GLenum)) \
	X(const GLubyte *, glGetStringi, (GLenum, GLuint)) \
	X(void, glGetIntegerv, (GLenum, GLint *)) \
	X(GLenum, glGetError, (void)) \
	X(GLuint, glCreateShader, (GLenum)) \
	X(void, glShaderSource, (GLuint, GLsizei, const GLchar *const *, const GLint *)) \
	X(void, glCompileShader, (GLuint)) \
	X(void, glGetShaderiv, (GLuint, GLenum, GLint *)) \
	X(void, glGetShaderInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *)) \
	X(GLuint, glCreateProgram, (void)) \
	X(void, glAttachShader, (GLuint, GLuint)) \
	X(void, glLinkProgram, (GLuint)) \
	X(void, glGetProgramiv, (GLuint, GLenum, GLint *)) \
	X(void, glGetProgramInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *)) \
	X(void, glUseProgram, (GLuint)) \
	X(void, glDeleteProgram, (GLuint)) \
	X(void, glDeleteShader, (GLuint)) \
	X(GLint, glGetUniformLocation, (GLuint, const GLchar *)) \
	X(void, glUniform1i, (GLint, GLint)) \
	X(void, glTransformFeedbackVaryings, (GLuint, GLsizei, const GLchar *const *, GLenum)) \
	X(void, glGenVertexArrays, (GLsizei, GLuint *)) \
	X(void, glBindVertexArray, (GLuint)) \
	X(void, glGenBuffers, (GLsizei, GLuint *)) \
	X(void, glBindBuffer, (GLenum, GLuint)) \
	X(void, glBindBufferBase, (GLenum, GLuint, GLuint)) \
	X(void, glBufferData, (GLenum, GLsizeiptr, const void *, GLenum)) \
	X(void, glGetBufferSubData, (GLenum, GLintptr, GLsizeiptr, void *)) \
	X(void, glGenTextures, (GLsizei, GLuint *)) \
	X(void, glBindTexture, (GLenum, GLuint)) \
	X(void, glActiveTexture, (GLenum)) \
	X(void, glTexImage2D, (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *)) \
	X(void, glTexParameteri, (GLenum, GLenum, GLint)) \
	X(void, glTexBuffer, (GLenum, GLenum, GLuint)) \
	X(void, glGenFramebuffers, (GLsizei, GLuint *)) \
	X(void, glBindFramebuffer, (GLenum, GLuint)) \
	X(void, glFramebufferTexture2D, (GLenum, GLenum, GLenum, GLuint, GLint)) \
	X(GLenum, glCheckFramebufferStatus, (GLenum)) \
	X(void, glDrawBuffers, (GLsizei, const GLenum *)) \
	X(void, glReadBuffer, (GLenum)) \
	X(void, glReadPixels, (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *)) \
	X(void, glViewport, (GLint, GLint, GLsizei, GLsizei)) \
	X(void, glClearColor, (GLfloat, GLfloat, GLfloat, GLfloat)) \
	X(void, glClear, (GLbitfield)) \
	X(void, glEnable, (GLenum)) \
	X(void, glDisable, (GLenum)) \
	X(void, glBlendFunc, (GLenum, GLenum)) \
	X(void, glDrawArrays, (GLenum, GLint, GLsizei)) \
	X(void, glBeginTransformFeedback, (GLenum)) \
	X(void, glEndTransformFeedback, (void)) \
	X(void, glFinish, (void)) \
	X(void, glDeleteTextures, (GLsizei, const GLuint *)) \
	X(void, glDeleteFramebuffers, (GLsizei, const GLuint *))

#define DECLARE(ret, name, args) static ret (*p_##name) args;
GL_FUNCS(DECLARE)

static int sFailures = 0;
static bool sAllExtensions = false;

static void
check(bool ok, const char *what, const char *detail)
{
	SAY("%s %s%s%s", ok ? "PASS" : "FAIL", what, detail ? ": " : "", detail ? detail : "");
	if (!ok)
		sFailures++;
}

static bool
load_gl(void *(*getProc)(const char *))
{
	bool ok = true;
#define LOAD(ret, name, args) \
	p_##name = (ret (*) args)getProc(#name); \
	if (p_##name == NULL) { SAY("missing function %s", #name); ok = false; }
	GL_FUNCS(LOAD)
	return ok;
}

static void *
sdl_proc(const char *name)
{
	return SDL_GL_GetProcAddress(name);
}

static void *
egl_proc(const char *name)
{
	return (void *)eglGetProcAddress(name);
}

static bool
has_extension(const char *name)
{
	GLint count = 0;
	p_glGetIntegerv(GL_NUM_EXTENSIONS, &count);
	for (GLint i = 0; i < count; i++) {
		if (strcmp((const char *)p_glGetStringi(GL_EXTENSIONS, i), name) == 0)
			return true;
	}
	return false;
}

/* epoxy_gl_version(): GL_VERSION's major * 10 + minor */
static int
gl_version(void)
{
	const char *version = (const char *)p_glGetString(GL_VERSION);
	int major = 0, minor = 0;
	if (version == NULL || sscanf(version, "%d.%d", &major, &minor) != 2)
		return 0;
	return major * 10 + minor;
}

static GLuint
program(const char *vs, const char *fs, const char *const *xfbVaryings, int xfbCount, char *log,
	int logSize)
{
	const char *sources[2] = { vs, fs };
	const GLenum types[2] = { GL_VERTEX_SHADER, GL_FRAGMENT_SHADER };
	GLuint prog = p_glCreateProgram();
	log[0] = '\0';
	for (int i = 0; i < 2; i++) {
		if (sources[i] == NULL)
			continue;
		GLuint shader = p_glCreateShader(types[i]);
		GLint ok = 0;
		p_glShaderSource(shader, 1, &sources[i], NULL);
		p_glCompileShader(shader);
		p_glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
		if (!ok) {
			p_glGetShaderInfoLog(shader, logSize, NULL, log);
			p_glDeleteShader(shader);
			p_glDeleteProgram(prog);
			return 0;
		}
		p_glAttachShader(prog, shader);
		p_glDeleteShader(shader);
	}
	if (xfbCount > 0)
		p_glTransformFeedbackVaryings(prog, xfbCount, xfbVaryings, GL_INTERLEAVED_ATTRIBS);
	p_glLinkProgram(prog);
	GLint linked = 0;
	p_glGetProgramiv(prog, GL_LINK_STATUS, &linked);
	if (!linked) {
		p_glGetProgramInfoLog(prog, logSize, NULL, log);
		p_glDeleteProgram(prog);
		return 0;
	}
	return prog;
}

static const char *kFullscreenVS =
	"#version 330\n"
	"void main() {\n"
	"  vec2 p = vec2((gl_VertexID & 1) * 4 - 1, (gl_VertexID & 2) * 2 - 1);\n"
	"  gl_Position = vec4(p, 0.0, 1.0);\n"
	"}\n";

static GLuint
texture(GLenum internal, GLenum format, GLenum type, int w, int h, const void *data)
{
	GLuint tex;
	p_glGenTextures(1, &tex);
	p_glBindTexture(GL_TEXTURE_2D, tex);
	p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	p_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	p_glTexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, format, type, data);
	return tex;
}

static void
print_context(const char *label)
{
	GLint mask = 0;
	p_glGetIntegerv(GL_CONTEXT_PROFILE_MASK, &mask);
	SAY("%s: version \"%s\", GLSL \"%s\", profile mask %d, epoxy_gl_version %d", label,
		(const char *)p_glGetString(GL_VERSION), (const char *)p_glGetString(GL_SHADING_LANGUAGE_VERSION),
		mask, gl_version());
}

static void
caps(void)
{
	SAY("renderer \"%s\", vendor \"%s\"", (const char *)p_glGetString(GL_RENDERER),
		(const char *)p_glGetString(GL_VENDOR));
	for (size_t i = 0; i < sizeof(kLimits) / sizeof(kLimits[0]); i++) {
		GLint value = -1;
		p_glGetIntegerv(kLimits[i].e, &value);
		SAY("limit %s %d%s", kLimits[i].name, value, p_glGetError() != GL_NO_ERROR ? " (error)" : "");
	}
	for (size_t i = 0; i < sizeof(kExtensions) / sizeof(kExtensions[0]); i++)
		SAY("ext %s %s", kExtensions[i], has_extension(kExtensions[i]) ? "yes" : "no");
	/* what Blender 3.6 derives (gl_backend.cc capabilities_init) */
	int version = gl_version();
	SAY("blender compute_shader_support %d", has_extension("GL_ARB_compute_shader") && version >= 43);
	/* the extension, and at least 8 blocks in the vertex, fragment and compute stages */
	GLint ssboVS = 0, ssboFS = 0, ssboCS = 0;
	p_glGetIntegerv(0x90D6, &ssboVS);
	p_glGetIntegerv(0x90DA, &ssboFS);
	p_glGetIntegerv(0x90DB, &ssboCS);
	while (p_glGetError() != GL_NO_ERROR)
		;
	GLint ssboMin = ssboVS < ssboFS ? ssboVS : ssboFS;
	ssboMin = ssboCS < ssboMin ? ssboCS : ssboMin;
	SAY("blender shader_storage_buffer_objects_support %d (extension %d, min blocks VS/FS/CS %d >= 8)",
		has_extension("GL_ARB_shader_storage_buffer_object") && ssboMin >= 8,
		has_extension("GL_ARB_shader_storage_buffer_object"), ssboMin);
	SAY("blender shader_image_load_store_support %d", has_extension("GL_ARB_shader_image_load_store"));
	SAY("blender explicit_location/texture_storage/stencil_texturing %d", version >= 43);
	SAY("blender base_instance_support %d", has_extension("GL_ARB_base_instance") && version >= 40);
	SAY("blender support level %s (3.6: version >= 33; 4.x/5.x: >= 43)",
		version >= 33 ? "SUPPORTED for 3.6" : "UNSUPPORTED");
	if (sAllExtensions) {
		GLint count = 0;
		p_glGetIntegerv(GL_NUM_EXTENSIONS, &count);
		for (GLint i = 0; i < count; i++)
			SAY("extension %s", (const char *)p_glGetStringi(GL_EXTENSIONS, i));
	}
}

/* N fragment outputs at explicit locations 0..N-1, as Blender's generated GLSL declares them */
static void
mrt(int outputs, bool required)
{
	char fs[1024], log[1024], what[64];
	int n = snprintf(fs, sizeof(fs), "#version 330\n");
	for (int i = 0; i < outputs; i++)
		n += snprintf(fs + n, sizeof(fs) - n, "layout(location = %d) out vec4 o%d;\n", i, i);
	n += snprintf(fs + n, sizeof(fs) - n, "void main() {\n");
	for (int i = 0; i < outputs; i++)
		n += snprintf(fs + n, sizeof(fs) - n, "  o%d = vec4(%d.0 / 8.0, 0.5, 0.25, 1.0);\n", i, i + 1);
	snprintf(fs + n, sizeof(fs) - n, "}\n");
	GLuint prog = program(kFullscreenVS, fs, NULL, 0, log, sizeof(log));
	snprintf(what, sizeof(what), "mrt%d link", outputs);
	if (!required) {
		SAY("INFO %s: %s%s%s", what, prog ? "ok" : "fails", prog ? "" : " — ", prog ? "" : log);
		if (!prog)
			SAY("INFO EEVEE Legacy opaque surface shader (6 outputs) cannot link here: needs a Blender patch");
	} else
		check(prog != 0, what, prog ? NULL : log);

	/* the framebuffer side */
	GLuint fbo, tex[8];
	GLenum bufs[8];
	p_glGenFramebuffers(1, &fbo);
	p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	for (int i = 0; i < outputs; i++) {
		tex[i] = texture(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 8, 8, NULL);
		p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i, GL_TEXTURE_2D, tex[i], 0);
		bufs[i] = GL_COLOR_ATTACHMENT0 + i;
	}
	GLenum attachError = p_glGetError();
	bool complete = p_glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
	snprintf(what, sizeof(what), "mrt%d framebuffer", outputs);
	if (required && prog) {
		p_glDrawBuffers(outputs, bufs);
		p_glViewport(0, 0, 8, 8);
		p_glUseProgram(prog);
		p_glDrawArrays(GL_TRIANGLES, 0, 3);
		bool values = true;
		for (int i = 0; i < outputs; i++) {
			GLubyte px[4];
			p_glReadBuffer(GL_COLOR_ATTACHMENT0 + i);
			p_glReadPixels(4, 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
			int expect = (i + 1) * 255 / 8;
			if (abs(px[0] - expect) > 2 || abs(px[1] - 128) > 2)
				values = false;
		}
		check(complete && attachError == GL_NO_ERROR && values, what,
			complete ? (values ? NULL : "wrong values") : "incomplete");
	} else
		SAY("INFO %s: attach error 0x%x, %s", what, attachError, complete ? "complete" : "incomplete");
	if (prog)
		p_glDeleteProgram(prog);
	p_glBindFramebuffer(GL_FRAMEBUFFER, 0);
	p_glDeleteFramebuffers(1, &fbo);
	p_glDeleteTextures(outputs, tex);
	while (p_glGetError() != GL_NO_ERROR)
		;
}

/* blended draw into float targets: clear 0.25, add 0.5 with ONE/ONE, expect 0.75 */
static void
float_targets(void)
{
	static const struct { const char *name; GLenum internal, format; } kFormats[] = {
		{ "RGBA16F", GL_RGBA16F, GL_RGBA }, { "RGBA32F", GL_RGBA32F, GL_RGBA },
		{ "R11F_G11F_B10F", GL_R11F_G11F_B10F, GL_RGB },
	};
	char log[1024];
	GLuint prog = program(kFullscreenVS,
		"#version 330\nout vec4 c;\nvoid main() { c = vec4(0.5); }\n", NULL, 0, log, sizeof(log));
	for (size_t i = 0; i < sizeof(kFormats) / sizeof(kFormats[0]); i++) {
		char what[64], detail[96] = "";
		GLuint fbo, tex = texture(kFormats[i].internal, kFormats[i].format, GL_FLOAT, 8, 8, NULL);
		p_glGenFramebuffers(1, &fbo);
		p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
		p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
		bool ok = p_glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
		if (ok && prog) {
			float px[4] = { 0 };
			p_glViewport(0, 0, 8, 8);
			p_glClearColor(0.25f, 0.25f, 0.25f, 0.25f);
			p_glClear(GL_COLOR_BUFFER_BIT);
			p_glEnable(GL_BLEND);
			p_glBlendFunc(GL_ONE, GL_ONE);
			p_glUseProgram(prog);
			p_glDrawArrays(GL_TRIANGLES, 0, 3);
			p_glDisable(GL_BLEND);
			p_glReadPixels(4, 4, 1, 1, GL_RGBA, GL_FLOAT, px);
			ok = px[0] > 0.74f && px[0] < 0.76f && px[1] > 0.74f && px[1] < 0.76f;
			snprintf(detail, sizeof(detail), "%.3f %.3f %.3f %.3f", px[0], px[1], px[2], px[3]);
		} else
			snprintf(detail, sizeof(detail), "%.80s", prog ? "framebuffer incomplete" : log);
		snprintf(what, sizeof(what), "float %s blend", kFormats[i].name);
		check(ok, what, detail);
		p_glBindFramebuffer(GL_FRAMEBUFFER, 0);
		p_glDeleteFramebuffers(1, &fbo);
		p_glDeleteTextures(1, &tex);
	}
	if (prog)
		p_glDeleteProgram(prog);
}

/* texelFetch from a buffer texture into an RGBA32F row of 4 pixels */
static void
buffer_textures(void)
{
	static const struct {
		const char *name; GLenum internal; const char *sampler; int bytes; float expect[4][4];
	} kCases[] = {
		{ "R32F", GL_R32F, "samplerBuffer", 4,
			{ { 1, 0, 0, 1 }, { 2, 0, 0, 1 }, { 3, 0, 0, 1 }, { 4, 0, 0, 1 } } },
		{ "RG32F", GL_RG32F, "samplerBuffer", 8,
			{ { 1, 2, 0, 1 }, { 3, 4, 0, 1 }, { 5, 6, 0, 1 }, { 7, 8, 0, 1 } } },
		{ "RGBA32F", GL_RGBA32F, "samplerBuffer", 16,
			{ { 1, 2, 3, 4 }, { 5, 6, 7, 8 }, { 9, 10, 11, 12 }, { 13, 14, 15, 16 } } },
		{ "RGBA8", GL_RGBA8, "samplerBuffer", 4, { { 0 } } },
		{ "R32UI", GL_R32UI, "usamplerBuffer", 4,
			{ { 1, 0, 0, 1 }, { 2, 0, 0, 1 }, { 3, 0, 0, 1 }, { 4, 0, 0, 1 } } },
	};
	for (size_t c = 0; c < sizeof(kCases) / sizeof(kCases[0]); c++) {
		char fs[512], log[1024], what[64], detail[160] = "";
		uint8_t data[64];
		if (kCases[c].internal == GL_RGBA8) {
			for (int i = 0; i < 16; i++)
				data[i] = (uint8_t)(i * 17);
		} else if (kCases[c].internal == GL_R32UI) {
			for (uint32_t i = 0; i < 4; i++) {
				uint32_t v = i + 1;
				memcpy(data + i * 4, &v, 4);
			}
		} else {
			for (int i = 0; i < 16; i++) {
				float v = (float)(i + 1);
				memcpy(data + i * 4, &v, 4);
			}
		}
		snprintf(fs, sizeof(fs),
			"#version 330\nuniform %s tb;\nout vec4 c;\n"
			"void main() { c = vec4(texelFetch(tb, int(gl_FragCoord.x))); }\n", kCases[c].sampler);
		GLuint prog = program(kFullscreenVS, fs, NULL, 0, log, sizeof(log));
		GLuint buf, tbo, fbo, target = texture(GL_RGBA32F, GL_RGBA, GL_FLOAT, 4, 1, NULL);
		p_glGenBuffers(1, &buf);
		p_glBindBuffer(GL_TEXTURE_BUFFER, buf);
		p_glBufferData(GL_TEXTURE_BUFFER, kCases[c].bytes * 4, data, GL_STATIC_DRAW);
		p_glGenTextures(1, &tbo);
		p_glActiveTexture(GL_TEXTURE0);
		p_glBindTexture(GL_TEXTURE_BUFFER, tbo);
		p_glTexBuffer(GL_TEXTURE_BUFFER, kCases[c].internal, buf);
		p_glGenFramebuffers(1, &fbo);
		p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
		p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
		bool ok = prog != 0 && p_glGetError() == GL_NO_ERROR;
		if (ok) {
			float px[16];
			p_glViewport(0, 0, 4, 1);
			p_glUseProgram(prog);
			p_glUniform1i(p_glGetUniformLocation(prog, "tb"), 0);
			p_glDrawArrays(GL_TRIANGLES, 0, 3);
			p_glReadPixels(0, 0, 4, 1, GL_RGBA, GL_FLOAT, px);
			for (int i = 0; i < 4; i++) {
				for (int k = 0; k < 4; k++) {
					float expect = kCases[c].internal == GL_RGBA8 ? (float)((i * 4 + k) * 17) / 255.0f
						: kCases[c].expect[i][k];
					if (px[i * 4 + k] < expect - 0.01f || px[i * 4 + k] > expect + 0.01f)
						ok = false;
				}
			}
			snprintf(detail, sizeof(detail), "texel 1 = %.3f %.3f %.3f %.3f", px[4], px[5], px[6], px[7]);
		} else
			snprintf(detail, sizeof(detail), "%.80s", prog ? "GL error" : log);
		snprintf(what, sizeof(what), "tbo %s", kCases[c].name);
		check(ok, what, detail);
		if (prog)
			p_glDeleteProgram(prog);
		p_glBindFramebuffer(GL_FRAMEBUFFER, 0);
		p_glDeleteFramebuffers(1, &fbo);
		p_glDeleteTextures(1, &tbo);
		p_glDeleteTextures(1, &target);
	}
}

static void
transform_feedback(void)
{
	char log[1024], detail[96] = "";
	const char *varyings[] = { "xfbOut" };
	GLuint prog = program("#version 330\nout vec4 xfbOut;\n"
		"void main() { xfbOut = vec4(float(gl_VertexID), 1.0, 2.0, 3.0); gl_Position = vec4(0.0); }\n",
		NULL, varyings, 1, log, sizeof(log));
	bool ok = prog != 0;
	if (ok) {
		GLuint buf;
		float out[16] = { 0 };
		p_glGenBuffers(1, &buf);
		p_glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buf);
		p_glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER, sizeof(out), NULL, GL_STATIC_DRAW);
		p_glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buf);
		p_glUseProgram(prog);
		p_glEnable(GL_RASTERIZER_DISCARD);
		p_glBeginTransformFeedback(GL_POINTS);
		p_glDrawArrays(GL_POINTS, 0, 4);
		p_glEndTransformFeedback();
		p_glDisable(GL_RASTERIZER_DISCARD);
		p_glGetBufferSubData(GL_TRANSFORM_FEEDBACK_BUFFER, 0, sizeof(out), out);
		for (int i = 0; i < 4; i++) {
			if (out[i * 4] != (float)i || out[i * 4 + 1] != 1.0f || out[i * 4 + 3] != 3.0f)
				ok = false;
		}
		snprintf(detail, sizeof(detail), "vertex 3 = %.1f %.1f %.1f %.1f", out[12], out[13], out[14], out[15]);
		p_glDeleteProgram(prog);
	} else
		snprintf(detail, sizeof(detail), "%.80s", log);
	check(ok, "xfb", detail);
}

static void
gather(void)
{
	char log[1024], detail[96] = "";
	const float values[4] = { 1, 2, 3, 4 };
	GLuint src = texture(GL_R32F, GL_RED, GL_FLOAT, 2, 2, values);
	GLuint target = texture(GL_RGBA32F, GL_RGBA, GL_FLOAT, 1, 1, NULL);
	GLuint prog = program(kFullscreenVS, "#version 330\n#extension GL_ARB_texture_gather : enable\n"
		"uniform sampler2D t;\nout vec4 c;\nvoid main() { c = textureGather(t, vec2(0.5)); }\n",
		NULL, 0, log, sizeof(log));
	bool ok = prog != 0;
	if (ok) {
		GLuint fbo;
		float px[4];
		p_glGenFramebuffers(1, &fbo);
		p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
		p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
		p_glActiveTexture(GL_TEXTURE0);
		p_glBindTexture(GL_TEXTURE_2D, src);
		p_glViewport(0, 0, 1, 1);
		p_glUseProgram(prog);
		p_glUniform1i(p_glGetUniformLocation(prog, "t"), 0);
		p_glDrawArrays(GL_TRIANGLES, 0, 3);
		p_glReadPixels(0, 0, 1, 1, GL_RGBA, GL_FLOAT, px);
		/* (0,1) (1,1) (1,0) (0,0) of the 2x2 texture: 3 4 2 1 */
		ok = px[0] == 3.0f && px[1] == 4.0f && px[2] == 2.0f && px[3] == 1.0f;
		snprintf(detail, sizeof(detail), "%.1f %.1f %.1f %.1f (want 3 4 2 1)", px[0], px[1], px[2], px[3]);
		p_glBindFramebuffer(GL_FRAMEBUFFER, 0);
		p_glDeleteFramebuffers(1, &fbo);
		p_glDeleteProgram(prog);
	} else
		snprintf(detail, sizeof(detail), "%.80s", log);
	check(ok, "gather", detail);
	p_glDeleteTextures(1, &src);
	p_glDeleteTextures(1, &target);
}

/* a 4x4 RGBA8 texture of 0x11223344 made on another thread's (shared) context, read back here */
static const uint32_t kPattern = 0x44332211u;

static bool
read_shared_texture(GLuint tex, char *detail, size_t size)
{
	GLuint fbo;
	uint32_t px = 0;
	p_glGenFramebuffers(1, &fbo);
	p_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	p_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	bool complete = p_glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
	if (complete)
		p_glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &px);
	p_glBindFramebuffer(GL_FRAMEBUFFER, 0);
	p_glDeleteFramebuffers(1, &fbo);
	snprintf(detail, size, "texture %u: %s, pixel 0x%08x", tex, complete ? "complete" : "incomplete", px);
	return complete && px == kPattern;
}

static GLuint
make_pattern_texture(void)
{
	uint32_t data[16];
	for (int i = 0; i < 16; i++)
		data[i] = kPattern;
	GLuint tex = texture(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 4, 4, data);
	p_glFinish();
	return tex;
}

struct egl_worker {
	EGLDisplay display;
	EGLContext context;
	GLuint texture;
	bool made_current;
};

static void *
egl_worker_main(void *data)
{
	struct egl_worker *w = data;
	w->made_current = eglMakeCurrent(w->display, EGL_NO_SURFACE, EGL_NO_SURFACE, w->context);
	if (w->made_current) {
		w->texture = make_pattern_texture();
		eglMakeCurrent(w->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	}
	return NULL;
}

static int
egl_threads(void)
{
	static const EGLint attribs[] = {
		EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3,
		EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE
	};
	EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (!eglInitialize(display, NULL, NULL) || !eglBindAPI(EGL_OPENGL_API)) {
		check(false, "egl threads", "no EGL display / OpenGL API");
		return sFailures;
	}
	EGLContext main = eglCreateContext(display, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attribs);
	EGLContext other = main != EGL_NO_CONTEXT
		? eglCreateContext(display, EGL_NO_CONFIG_KHR, main, attribs) : EGL_NO_CONTEXT;
	if (other == EGL_NO_CONTEXT || !eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, main)) {
		check(false, "egl threads", "no shared core 3.3 contexts");
		return sFailures;
	}
	if (!load_gl(egl_proc)) {
		check(false, "egl threads", "functions missing");
		return sFailures;
	}
	print_context("egl core33");
	struct egl_worker w = { display, other, 0, false };
	pthread_t thread;
	pthread_create(&thread, NULL, egl_worker_main, &w);
	pthread_join(thread, NULL);
	char detail[128] = "worker could not make its context current";
	bool ok = w.made_current && read_shared_texture(w.texture, detail, sizeof(detail));
	check(ok, "egl threads (shared context current on a second thread)", detail);
	eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(display, other);
	eglDestroyContext(display, main);
	eglTerminate(display);
	return sFailures;
}

/* Blender's pattern: a job thread holds its offscreen context while the main thread keeps drawing (and
 * swapping) its window, then the job releases its context. */
struct sdl_worker {
	SDL_Window *window;
	SDL_GLContext context;
	SDL_sem *made;      /* worker → main: context current, texture made */
	SDL_sem *go;        /* main → worker: release now */
	GLuint texture;
	int status;
	bool still_current; /* the worker's context was still usable after the main thread's draw */
};

static int
sdl_worker_main(void *data)
{
	struct sdl_worker *w = data;
	w->status = SDL_GL_MakeCurrent(w->window, w->context);
	if (w->status == 0)
		w->texture = make_pattern_texture();
	SDL_SemPost(w->made);
	SDL_SemWait(w->go);
	if (w->status == 0) {
		w->still_current = p_glGetString(GL_VERSION) != NULL;
		SDL_GL_MakeCurrent(NULL, NULL); /* GHOST_ContextSDL::releaseDrawingContext() */
	}
	return 0;
}

/* the main thread draws its window while the worker holds its context: clear, read back, swap */
static bool
main_draws(SDL_Window *window, SDL_GLContext context, char *detail, size_t size)
{
	GLubyte px[4] = { 0 };
	int status = SDL_GL_MakeCurrent(window, context); /* Blender re-activates the window context */
	const GLubyte *version = p_glGetString(GL_VERSION);
	if (status == 0 && version != NULL) {
		p_glBindFramebuffer(GL_FRAMEBUFFER, 0);
		p_glViewport(0, 0, 16, 16);
		p_glClearColor(0.0f, 1.0f, 0.0f, 1.0f);
		p_glClear(GL_COLOR_BUFFER_BIT);
		p_glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
		SDL_GL_SwapWindow(window);
	}
	snprintf(detail, size, "make-current %d, context %s, pixel %u %u %u", status,
		version != NULL ? "usable" : "LOST", px[0], px[1], px[2]);
	return status == 0 && version != NULL && px[1] == 255 && px[0] == 0;
}

static SDL_GLContext
sdl_context(SDL_Window *window, int profile, bool share)
{
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, profile);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_SHARE_WITH_CURRENT_CONTEXT, share ? 1 : 0);
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);
	return SDL_GL_CreateContext(window);
}

int
main(int argc, char **argv)
{
	bool doEgl = false, doThread = false;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-e") == 0)
			doEgl = true;
		else if (strcmp(argv[i], "-t") == 0)
			doThread = true;
		else if (strcmp(argv[i], "-x") == 0)
			sAllExtensions = true;
		else {
			fprintf(stderr, "usage: %s [-e] [-t] [-x]\n", argv[0]);
			return 2;
		}
	}
	if (doEgl)
		return egl_threads();

	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		SAY("FAIL SDL_Init: %s", SDL_GetError());
		return 1;
	}
	/* 1. what stock GHOST_SDL asks: profile mask 0, 3.3 */
	SDL_Window *probe = SDL_CreateWindow("blender-glprobe (profile 0)", SDL_WINDOWPOS_UNDEFINED,
		SDL_WINDOWPOS_UNDEFINED, 64, 64, SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
	SDL_GLContext stock = probe ? sdl_context(probe, 0, false) : NULL;
	if (stock != NULL && load_gl(sdl_proc)) {
		print_context("ghost-stock (profile 0, 3.3)");
		SAY("INFO stock GHOST_SDL %s", gl_version() >= 33 ? "gets 3.3: no GHOST patch needed"
			: "gets < 3.3: Blender 3.6 would say \"unsupported\" and quit; GHOST must ask for the core profile");
		SDL_GL_MakeCurrent(NULL, NULL);
		SDL_GL_DeleteContext(stock);
	} else
		SAY("INFO ghost-stock: no context (%s)", SDL_GetError());
	if (probe)
		SDL_DestroyWindow(probe);

	/* 2. the patched GHOST_SDL: core profile 3.3, a visible window as Blender's main window */
	SDL_Window *window = SDL_CreateWindow("blender-glprobe", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
		320, 200, SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE);
	SDL_GLContext context = window ? sdl_context(window, SDL_GL_CONTEXT_PROFILE_CORE, true) : NULL;
	if (context == NULL || !load_gl(sdl_proc)) {
		check(false, "ghost-core context", SDL_GetError());
		SDL_Quit();
		return sFailures;
	}
	print_context("ghost-core (core profile, 3.3)");
	check(gl_version() >= 33, "ghost-core version >= 3.3", NULL);

	GLuint vao;
	p_glGenVertexArrays(1, &vao);
	p_glBindVertexArray(vao);
	caps();
	mrt(4, true);
	mrt(6, false);
	float_targets();
	buffer_textures();
	transform_feedback();
	gather();

	if (doThread) {
		/* GHOST_SystemSDL::createOffscreenContext(): a hidden 1x1 window, sharing with the current
		 * context; then the main window's context is made current again, as Blender does */
		SDL_Window *hidden = SDL_CreateWindow("Offscreen Context Windows", SDL_WINDOWPOS_UNDEFINED,
			SDL_WINDOWPOS_UNDEFINED, 1, 1, SDL_WINDOW_OPENGL | SDL_WINDOW_BORDERLESS | SDL_WINDOW_HIDDEN);
		SDL_GLContext offscreen = hidden ? sdl_context(hidden, SDL_GL_CONTEXT_PROFILE_CORE, true) : NULL;
		SDL_GL_MakeCurrent(window, context);
		if (offscreen == NULL) {
			check(false, "sdl thread", SDL_GetError());
		} else {
			/* Stock SDL2 keeps one process-wide current BGLView: the worker unlocks the main
			 * thread's view and vice versa. On our HGL that only prints "UnlockGL is called from
			 * wrong thread" / "Unlocking BLocker ... from wrong thread" and goes on, so the checks
			 * below may pass anyway: blender-probe.sh grades any such line as a FAIL. */
			SAY("INFO sdl thread: offscreen context held on a second thread while the main thread draws");
			struct sdl_worker w = { hidden, offscreen, SDL_CreateSemaphore(0), SDL_CreateSemaphore(0), 0,
				-1, false };
			SDL_Thread *thread = SDL_CreateThread(sdl_worker_main, "blender-glprobe job", &w);
			SDL_SemWait(w.made);
			char drawDetail[96];
			bool drew = main_draws(window, context, drawDetail, sizeof(drawDetail));
			check(drew, "sdl thread: main window draws while the job holds its context", drawDetail);
			SDL_SemPost(w.go);
			SDL_WaitThread(thread, NULL);
			check(w.status == 0 && w.still_current, "sdl thread: job context still current after the main draw",
				w.status == 0 ? NULL : "worker could not make its context current");
			char detail[128] = "no texture";
			SDL_GL_MakeCurrent(window, context);
			bool ok = w.status == 0 && p_glGetString(GL_VERSION) != NULL
				&& read_shared_texture(w.texture, detail, sizeof(detail));
			check(ok, "sdl thread: job's texture seen by the main context (shared)", detail);
			SDL_DestroySemaphore(w.made);
			SDL_DestroySemaphore(w.go);
			SDL_GL_DeleteContext(offscreen);
		}
		if (hidden)
			SDL_DestroyWindow(hidden);
	}

	SDL_GL_MakeCurrent(NULL, NULL);
	SDL_GL_DeleteContext(context);
	SDL_DestroyWindow(window);
	SDL_Quit();
	SAY("done: %d failures", sFailures);
	return sFailures;
}
