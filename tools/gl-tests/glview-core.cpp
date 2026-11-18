/*
 * glview-core — a core-profile desktop OpenGL context through Haiku's GL kit (BGLView with
 * BGL_CONTEXT_CORE, from libglvnd's libGL.so; docs/design/desktop-gl.md): opens a window, reports the
 * context's version and profile, draws a triangle with a GLSL 1.40 shader (the oldest a core context
 * has) for a few seconds and checks the rendered back buffer with glReadPixels (corner = clear colour,
 * centre = triangle colour). Prints "GLK " lines; exit status 0 = PASS.
 *
 *   glview-core [-s SECONDS]
 */

#define GL_GLEXT_PROTOTYPES
#include <Application.h>
#include <GLView.h>
#include <OS.h>
#include <Window.h>

#include <GL/glext.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>


#define SAY(...) do { printf("GLK " __VA_ARGS__); printf("\n"); fflush(stdout); } while (false)

static const int kSize = 256;


static GLuint
compile(GLenum type, const char* source)
{
	GLuint shader = glCreateShader(type);
	glShaderSource(shader, 1, &source, NULL);
	glCompileShader(shader);
	GLint ok = 0;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[512] = "";
		glGetShaderInfoLog(shader, sizeof(log), NULL, log);
		SAY("shader FAIL: %s", log);
		return 0;
	}
	return shader;
}


int
main(int argc, char** argv)
{
	double seconds = 3;
	int opt;
	while ((opt = getopt(argc, argv, "s:")) != -1) {
		if (opt == 's')
			seconds = atof(optarg);
		else {
			fprintf(stderr, "usage: %s [-s seconds]\n", argv[0]);
			return 2;
		}
	}

	BApplication app("application/x-vnd.haiku-rpi-glview-core");
	BWindow* window = new BWindow(BRect(100, 100, 100 + kSize - 1, 100 + kSize - 1),
		"glview-core", B_TITLED_WINDOW, B_NOT_RESIZABLE | B_QUIT_ON_WINDOW_CLOSE);
	BGLView* view = new BGLView(window->Bounds(), "gl", B_FOLLOW_ALL_SIDES, 0,
		BGL_RGB | BGL_DOUBLE | BGL_DEPTH | BGL_CONTEXT_CORE);
	window->AddChild(view);
	window->Show();

	view->LockGL();
	const char* version = (const char*)glGetString(GL_VERSION);
	SAY("version: %s", version != NULL ? version : "(none)");
	SAY("renderer: %s", (const char*)glGetString(GL_RENDERER));
	SAY("shading language: %s", (const char*)glGetString(GL_SHADING_LANGUAGE_VERSION));
	GLint profile = 0;
	glGetIntegerv(GL_CONTEXT_PROFILE_MASK, &profile);
	glGetError();
	int major = 0, minor = 0;
	if (version != NULL)
		sscanf(version, "%d.%d", &major, &minor);
	// 3.1 has no profiles (and no compatibility features without GL_ARB_compatibility); 3.2 and later
	// report the core bit
	SAY("profile mask: 0x%x", profile);
	bool ok = (major == 3 && minor == 1) || (major * 10 + minor >= 32
		&& (profile & GL_CONTEXT_CORE_PROFILE_BIT) != 0);

	GLuint vs = compile(GL_VERTEX_SHADER,
		"#version 140\n"
		"in vec2 position;\n"
		"void main() { gl_Position = vec4(position, 0.0, 1.0); }\n");
	GLuint fs = compile(GL_FRAGMENT_SHADER,
		"#version 140\n"
		"out vec4 color;\n"
		"void main() { color = vec4(1.0, 0.5, 0.0, 1.0); }\n");
	ok = ok && vs != 0 && fs != 0;
	GLuint program = glCreateProgram();
	glAttachShader(program, vs);
	glAttachShader(program, fs);
	glBindAttribLocation(program, 0, "position");
	glLinkProgram(program);
	GLint linked = 0;
	glGetProgramiv(program, GL_LINK_STATUS, &linked);
	ok = ok && linked;

	static const GLfloat kTriangle[] = { 0.0f, 0.8f, -0.7f, -0.6f, 0.7f, -0.6f };
	GLuint vao, vbo;
	glGenVertexArrays(1, &vao);
	glBindVertexArray(vao);
	glGenBuffers(1, &vbo);
	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(kTriangle), kTriangle, GL_STATIC_DRAW);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
	glEnableVertexAttribArray(0);

	int frames = 0, bad = 0;
	bigtime_t end = system_time() + (bigtime_t)(seconds * 1000000);
	while (system_time() < end) {
		glViewport(0, 0, kSize, kSize);
		glClearColor(0.0f, 0.2f, 0.6f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		glUseProgram(program);
		glDrawArrays(GL_TRIANGLES, 0, 3);
		if (frames % 30 == 0) {
			GLubyte corner[4], centre[4];
			glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, corner);
			glReadPixels(kSize / 2, kSize / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, centre);
			if (corner[0] > 8 || corner[2] < 140 || centre[0] < 240 || centre[1] < 110
					|| centre[1] > 145 || centre[2] > 8) {
				if (bad++ < 3) {
					SAY("frame %d: corner %d,%d,%d centre %d,%d,%d", frames, corner[0],
						corner[1], corner[2], centre[0], centre[1], centre[2]);
				}
			}
		}
		view->SwapBuffers();
		frames++;
	}
	view->UnlockGL();
	SAY("%d frames in %.1f s, %d bad checks", frames, seconds, bad);
	ok = ok && bad == 0 && frames > 0;
	SAY("%s", ok ? "PASS" : "FAIL");

	window->Lock();
	window->Quit();
	return ok ? 0 : 1;
}
