/*
 * glinfo — which OpenGL versions and profiles the driver gives, and why not more (docs/design/desktop-gl.md).
 * Creates a surfaceless EGL context of each kind — desktop GL with no attributes (what a BGLView got
 * before BGL_CONTEXT_CORE), compatibility 3.0/3.1, core 3.1/3.2/3.3/4.0, OpenGL ES 2.0/3.0/3.1/3.2 — and
 * prints the version, GLSL version and profile each one really has. For desktop contexts it lists the
 * extensions of Mesa's version gates (src/mesa/main/version.c, compute_version()) for 3.0–3.3 that the
 * context does not advertise and the limits those versions require. Lines start with "GLI ".
 *
 *   glinfo [-x] [-k KIND]     -x: also print each context's whole extension list
 *                             -k: only that kind (compat, compat30, compat31, core31, core32, core33,
 *                                 core40, es20, es30, es31, es32)
 *
 * Mesa core contexts never list some pre-3.0 extensions that every 3.x version includes (they are part
 * of the core API there); a "missing" line names what the context string lacks, which is the gate only
 * for compatibility contexts and for the 3.2/3.3 lists. Exit status 0 when every context kind was
 * created or refused cleanly.
 */

#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAY(...) do { printf("GLI " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

typedef unsigned int GLenum;
typedef int GLint;
typedef unsigned int GLuint;
typedef unsigned char GLubyte;

#define GL_NO_ERROR 0
#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02
#define GL_EXTENSIONS 0x1F03
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define GL_NUM_EXTENSIONS 0x821D
#define GL_CONTEXT_PROFILE_MASK 0x9126
#define GL_CONTEXT_FLAGS 0x821E
#define GL_CONTEXT_CORE_PROFILE_BIT 0x1
#define GL_CONTEXT_COMPATIBILITY_PROFILE_BIT 0x2
#define GL_MAJOR_VERSION 0x821B
#define GL_MINOR_VERSION 0x821C

typedef const GLubyte *(*PFN_glGetString)(GLenum);
typedef const GLubyte *(*PFN_glGetStringi)(GLenum, GLuint);
typedef void (*PFN_glGetIntegerv)(GLenum, GLint *);
typedef GLenum (*PFN_glGetError)(void);

static PFN_glGetString p_glGetString;
static PFN_glGetStringi p_glGetStringi;
static PFN_glGetIntegerv p_glGetIntegerv;
static PFN_glGetError p_glGetError;

static bool sListAll = false;
static int sFailures = 0;

struct kind {
	const char *name;
	EGLenum api;
	int major, minor;   /* 0, 0: no version attributes */
	int profile;        /* EGL_CONTEXT_OPENGL_*_PROFILE_BIT_KHR or 0 */
};

static const struct kind kKinds[] = {
	{ "compat", EGL_OPENGL_API, 0, 0, 0 },
	{ "compat30", EGL_OPENGL_API, 3, 0, EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT_KHR },
	{ "compat31", EGL_OPENGL_API, 3, 1, EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT_KHR },
	{ "core31", EGL_OPENGL_API, 3, 1, 0 },
	{ "core32", EGL_OPENGL_API, 3, 2, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR },
	{ "core33", EGL_OPENGL_API, 3, 3, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR },
	{ "core40", EGL_OPENGL_API, 4, 0, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT_KHR },
	{ "es20", EGL_OPENGL_ES_API, 2, 0, 0 },
	{ "es30", EGL_OPENGL_ES_API, 3, 0, 0 },
	{ "es31", EGL_OPENGL_ES_API, 3, 1, 0 },
	{ "es32", EGL_OPENGL_ES_API, 3, 2, 0 },
};

/* compute_version()'s extension lists, as GL extension strings */
static const char *const kGate30[] = {
	"GL_ARB_color_buffer_float", "GL_ARB_depth_buffer_float", "GL_ARB_half_float_vertex",
	"GL_ARB_map_buffer_range", "GL_ARB_shader_texture_lod", "GL_ARB_texture_float", "GL_ARB_texture_rg",
	"GL_ARB_texture_compression_rgtc", "GL_EXT_draw_buffers2", "GL_ARB_framebuffer_object",
	"GL_EXT_framebuffer_sRGB", "GL_EXT_packed_float", "GL_EXT_texture_array", "GL_EXT_texture_integer",
	"GL_EXT_texture_shared_exponent", "GL_EXT_transform_feedback", "GL_NV_conditional_render", NULL
};
static const char *const kGate31[] = {
	"GL_ARB_draw_instanced", "GL_ARB_uniform_buffer_object", "GL_EXT_texture_snorm",
	"GL_NV_primitive_restart", "GL_NV_texture_rectangle", NULL
};
static const char *const kGate32[] = {
	"GL_ARB_depth_clamp", "GL_ARB_draw_elements_base_vertex", "GL_ARB_fragment_coord_conventions",
	"GL_EXT_provoking_vertex", "GL_ARB_seamless_cube_map", "GL_ARB_sync", "GL_ARB_texture_multisample",
	"GL_EXT_vertex_array_bgra", NULL
};
static const char *const kGate33[] = {
	"GL_ARB_blend_func_extended", "GL_ARB_explicit_attrib_location", "GL_ARB_instanced_arrays",
	"GL_ARB_shader_bit_encoding", "GL_ARB_texture_rgb10_a2ui", "GL_ARB_timer_query",
	"GL_ARB_vertex_type_2_10_10_10_rev", "GL_EXT_texture_swizzle", NULL
};

/* limits: name, enum, the minimum GL 3.3 core requires */
struct limit {
	const char *name;
	GLenum pname;
	int minimum;
};
static const struct limit kLimits[] = {
	{ "MAX_SAMPLES", 0x8D57, 4 },
	{ "MAX_COLOR_ATTACHMENTS", 0x8CDF, 8 },
	{ "MAX_DRAW_BUFFERS", 0x8824, 8 },
	{ "MAX_DUAL_SOURCE_DRAW_BUFFERS", 0x88FC, 1 },
	{ "MAX_TEXTURE_SIZE", 0x0D33, 1024 },
	{ "MAX_3D_TEXTURE_SIZE", 0x8073, 256 },
	{ "MAX_ARRAY_TEXTURE_LAYERS", 0x88FF, 256 },
	{ "MAX_VERTEX_ATTRIBS", 0x8869, 16 },
	{ "MAX_VERTEX_TEXTURE_IMAGE_UNITS", 0x8B4C, 16 },
	{ "MAX_TEXTURE_IMAGE_UNITS", 0x8872, 16 },
	{ "MAX_COMBINED_TEXTURE_IMAGE_UNITS", 0x8B4D, 48 },
	{ "MAX_VERTEX_OUTPUT_COMPONENTS", 0x9122, 64 },
	{ "MAX_FRAGMENT_INPUT_COMPONENTS", 0x9125, 128 },
	{ "MAX_VARYING_COMPONENTS", 0x8B4B, 60 },
	{ "MAX_GEOMETRY_INPUT_COMPONENTS", 0x9123, 64 },
	{ "MAX_GEOMETRY_OUTPUT_COMPONENTS", 0x9124, 128 },
	{ "MAX_GEOMETRY_OUTPUT_VERTICES", 0x8DE0, 256 },
	{ "MAX_GEOMETRY_TOTAL_OUTPUT_COMPONENTS", 0x8DE1, 1024 },
	{ "MAX_GEOMETRY_TEXTURE_IMAGE_UNITS", 0x8C29, 16 },
	{ "MAX_GEOMETRY_UNIFORM_COMPONENTS", 0x8DDF, 1024 },
	{ "MAX_UNIFORM_BUFFER_BINDINGS", 0x8A2F, 36 },
	{ "MAX_CLIP_DISTANCES", 0x0D32, 8 },
	{ "MAX_COLOR_TEXTURE_SAMPLES", 0x910E, 1 },
	{ "MAX_DEPTH_TEXTURE_SAMPLES", 0x910F, 1 },
	{ "MAX_INTEGER_SAMPLES", 0x9110, 1 },
	{ "MAX_SERVER_WAIT_TIMEOUT(lo)", 0x9111, 0 },
};

static char *sExtensions = NULL;    /* " ext1 ext2 ... " */

static void
collect_extensions(bool es, int major)
{
	free(sExtensions);
	sExtensions = NULL;
	size_t length = 2, used = 1;
	if (!es && major >= 3 && p_glGetStringi != NULL) {
		GLint count = 0;
		p_glGetIntegerv(GL_NUM_EXTENSIONS, &count);
		for (GLint i = 0; i < count; i++)
			length += strlen((const char *)p_glGetStringi(GL_EXTENSIONS, i)) + 1;
		sExtensions = malloc(length);
		strcpy(sExtensions, " ");
		for (GLint i = 0; i < count; i++) {
			const char *name = (const char *)p_glGetStringi(GL_EXTENSIONS, i);
			strcpy(sExtensions + used, name);
			used += strlen(name);
			strcpy(sExtensions + used, " ");
			used++;
		}
	} else {
		const char *list = (const char *)p_glGetString(GL_EXTENSIONS);
		if (list == NULL)
			list = "";
		sExtensions = malloc(strlen(list) + 3);
		sprintf(sExtensions, " %s ", list);
	}
}

static bool
has_extension(const char *name)
{
	char pattern[128];
	snprintf(pattern, sizeof(pattern), " %s ", name);
	return sExtensions != NULL && strstr(sExtensions, pattern) != NULL;
}

static void
report_gate(const char *version, const char *const *list)
{
	char missing[1024] = "";
	int count = 0;
	for (int i = 0; list[i] != NULL; i++) {
		if (has_extension(list[i]))
			continue;
		if (count++ > 0)
			strncat(missing, " ", sizeof(missing) - strlen(missing) - 1);
		strncat(missing, list[i], sizeof(missing) - strlen(missing) - 1);
	}
	if (count == 0)
		SAY("  gate %s: every extension advertised", version);
	else
		SAY("  gate %s: not advertised (%d): %s", version, count, missing);
}

static void
report_context(void)
{
	SAY("  renderer: %s | %s", (const char *)p_glGetString(GL_VENDOR),
		(const char *)p_glGetString(GL_RENDERER));
	SAY("  version: %s", (const char *)p_glGetString(GL_VERSION));
	const char *glsl = (const char *)p_glGetString(GL_SHADING_LANGUAGE_VERSION);
	SAY("  glsl: %s", glsl != NULL ? glsl : "(none)");
	p_glGetError();
}

static void
report_desktop(int major)
{
	GLint profile = 0, flags = 0;
	if (major >= 3) {
		p_glGetIntegerv(GL_CONTEXT_PROFILE_MASK, &profile);
		p_glGetIntegerv(GL_CONTEXT_FLAGS, &flags);
	}
	p_glGetError();
	SAY("  profile: %s, flags 0x%x",
		(profile & GL_CONTEXT_CORE_PROFILE_BIT) ? "core"
			: (profile & GL_CONTEXT_COMPATIBILITY_PROFILE_BIT) ? "compatibility"
			: major >= 3 ? "none (3.0/3.1)" : "legacy (< 3.0)", flags);
	report_gate("3.0", kGate30);
	report_gate("3.1", kGate31);
	report_gate("3.2", kGate32);
	report_gate("3.3", kGate33);
	char line[2048] = "";
	for (size_t i = 0; i < sizeof(kLimits) / sizeof(kLimits[0]); i++) {
		GLint value = -1;
		p_glGetIntegerv(kLimits[i].pname, &value);
		GLenum error = p_glGetError();
		char item[96];
		if (error != GL_NO_ERROR)
			snprintf(item, sizeof(item), " %s=n/a", kLimits[i].name);
		else
			snprintf(item, sizeof(item), " %s=%d%s", kLimits[i].name, value,
				value < kLimits[i].minimum ? "(<3.3 minimum)" : "");
		strncat(line, item, sizeof(line) - strlen(line) - 1);
	}
	SAY("  limits:%s", line);
}

static void
list_extensions(void)
{
	int count = 0;
	for (const char *p = sExtensions; p != NULL && *p != '\0'; p++) {
		if (*p == ' ' && p[1] != '\0')
			count++;
	}
	SAY("  extensions (%d):%s", count, sExtensions);
}

static void
try_kind(EGLDisplay display, const struct kind *kind)
{
	EGLint attribs[16];
	int n = 0;
	if (kind->major != 0) {
		attribs[n++] = EGL_CONTEXT_MAJOR_VERSION;
		attribs[n++] = kind->major;
		attribs[n++] = EGL_CONTEXT_MINOR_VERSION;
		attribs[n++] = kind->minor;
	}
	if (kind->profile != 0) {
		attribs[n++] = EGL_CONTEXT_OPENGL_PROFILE_MASK;
		attribs[n++] = kind->profile;
	}
	attribs[n] = EGL_NONE;

	if (!eglBindAPI(kind->api)) {
		SAY("%s: eglBindAPI failed 0x%x", kind->name, eglGetError());
		sFailures++;
		return;
	}
	EGLContext context = eglCreateContext(display, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attribs);
	if (context == EGL_NO_CONTEXT) {
		SAY("%s: refused (EGL error 0x%x)", kind->name, eglGetError());
		return;
	}
	if (!eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
		SAY("%s: created, but not made current (EGL error 0x%x)", kind->name, eglGetError());
		eglDestroyContext(display, context);
		sFailures++;
		return;
	}
	/* through EGL: libglvnd dispatches to the current context's vendor */
	p_glGetString = (PFN_glGetString)eglGetProcAddress("glGetString");
	p_glGetStringi = (PFN_glGetStringi)eglGetProcAddress("glGetStringi");
	p_glGetIntegerv = (PFN_glGetIntegerv)eglGetProcAddress("glGetIntegerv");
	p_glGetError = (PFN_glGetError)eglGetProcAddress("glGetError");
	if (p_glGetString == NULL || p_glGetIntegerv == NULL || p_glGetError == NULL) {
		SAY("%s: no GL entry points", kind->name);
		sFailures++;
	} else {
		const char *version = (const char *)p_glGetString(GL_VERSION);
		int major = 0;
		if (version != NULL) {
			const char *digits = version;
			while (*digits != '\0' && (*digits < '0' || *digits > '9'))
				digits++;
			major = atoi(digits);
		}
		bool es = kind->api == EGL_OPENGL_ES_API;
		SAY("%s: created", kind->name);
		report_context();
		collect_extensions(es, major);
		if (!es)
			report_desktop(major);
		if (sListAll)
			list_extensions();
	}
	eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(display, context);
}

int
main(int argc, char **argv)
{
	const char *only = NULL;
	int opt;
	while ((opt = getopt(argc, argv, "xk:")) != -1) {
		if (opt == 'x')
			sListAll = true;
		else if (opt == 'k')
			only = optarg;
		else {
			fprintf(stderr, "usage: %s [-x] [-k KIND]\n", argv[0]);
			return 2;
		}
	}

	EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	EGLint major = 0, minor = 0;
	if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor)) {
		SAY("EGL init failed 0x%x", eglGetError());
		return 1;
	}
	SAY("egl %d.%d %s | %s", major, minor, eglQueryString(display, EGL_VENDOR),
		eglQueryString(display, EGL_VERSION));
	const char *overrides[] = { "MESA_GL_VERSION_OVERRIDE", "MESA_GLSL_VERSION_OVERRIDE",
		"MESA_EXTENSION_OVERRIDE", "LIBGL_ALWAYS_SOFTWARE", NULL };
	for (int i = 0; overrides[i] != NULL; i++) {
		if (getenv(overrides[i]) != NULL)
			SAY("environment: %s=%s", overrides[i], getenv(overrides[i]));
	}

	for (size_t i = 0; i < sizeof(kKinds) / sizeof(kKinds[0]); i++) {
		if (only == NULL || strcmp(only, kKinds[i].name) == 0)
			try_kind(display, &kKinds[i]);
	}
	eglTerminate(display);
	free(sExtensions);
	SAY("%s", sFailures == 0 ? "done" : "errors");
	return sFailures == 0 ? 0 : 1;
}
