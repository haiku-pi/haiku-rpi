/*
 * glview — windowed OpenGL test through Haiku's GL kit (BGLView from libglvnd's libGL.so, EGL
 * window surface, Mesa's egl_haiku): opens a window, animates a triangle with desktop GL for a few
 * seconds, checks the rendered back buffer with glReadPixels before each check-frame's swap, and
 * prints "GLW " lines (send them to /dev/dprintf from a boot script). On a hardware screen the
 * frames reach the window through egl_haiku's copy present; HDMI shows whether they do.
 *
 *   glview [-s SECONDS]          exit status 0 = PASS
 */

#include <Application.h>
#include <GLView.h>
#include <OS.h>
#include <Window.h>

#include <GL/gl.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAY(...) do { printf("GLW " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static const int kSize = 256;
static int sFailures = 0;
static double sSeconds = 5;


static bool
near(const uint8_t* pixel, uint8_t r, uint8_t g, uint8_t b)
{
	return abs(pixel[0] - r) <= 2 && abs(pixel[1] - g) <= 2 && abs(pixel[2] - b) <= 2;
}


static void
check(const char* name, const uint8_t* pixel, uint8_t r, uint8_t g, uint8_t b)
{
	bool ok = near(pixel, r, g, b);
	SAY("check %s = %d,%d,%d expect %d,%d,%d %s", name, pixel[0], pixel[1], pixel[2], r, g, b,
		ok ? "ok" : "BAD");
	if (!ok)
		sFailures++;
}


static status_t
render_thread(void* data)
{
	BGLView* view = (BGLView*)data;
	snooze(500000);
		// let the window come up

	view->LockGL();
	SAY("renderer: %s", (const char*)glGetString(GL_RENDERER));
	SAY("version: %s", (const char*)glGetString(GL_VERSION));
	view->UnlockGL();

	const bigtime_t start = system_time();
	int frames = 0;
	while (system_time() - start < (bigtime_t)(sSeconds * 1000000)) {
		view->LockGL();
		glViewport(0, 0, kSize, kSize);
		glClearColor(0.0f, 0.0f, 0.25f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		glMatrixMode(GL_MODELVIEW);
		glLoadIdentity();
		glRotatef(frames * 2.0f, 0.0f, 0.0f, 1.0f);
		glBegin(GL_TRIANGLES);
		glColor3f(1.0f, 0.0f, 0.0f);
		glVertex2f(0.0f, 0.8f);
		glColor3f(0.0f, 1.0f, 0.0f);
		glVertex2f(-0.7f, -0.6f);
		glColor3f(0.0f, 0.0f, 1.0f);
		glVertex2f(0.7f, -0.6f);
		glEnd();

		if (frames == 0) {
			// frame 0 is unrotated: the corner is clear colour, the centre inside
			uint8_t pixel[4];
			glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
			check("corner", pixel, 0, 0, 64);
			glReadPixels(kSize / 2, kSize / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
			bool inside = !near(pixel, 0, 0, 64) && pixel[3] > 0;
			SAY("check centre = %d,%d,%d inside the triangle %s", pixel[0], pixel[1], pixel[2],
				inside ? "ok" : "BAD");
			if (!inside)
				sFailures++;
			GLenum error = glGetError();
			SAY("glGetError 0x%x %s", error, error == GL_NO_ERROR ? "ok" : "BAD");
			if (error != GL_NO_ERROR)
				sFailures++;
		}
		view->SwapBuffers();
		view->UnlockGL();
		frames++;
	}
	const double elapsed = (system_time() - start) / 1000000.0;
	SAY("frames %d in %.2f s = %.1f fps", frames, elapsed, frames / elapsed);
	SAY("%s (%d failure%s)", sFailures == 0 ? "PASS" : "FAIL", sFailures,
		sFailures == 1 ? "" : "s");

	be_app->PostMessage(B_QUIT_REQUESTED);
	return B_OK;
}


int
main(int argc, char** argv)
{
	int opt;
	while ((opt = getopt(argc, argv, "s:")) != -1) {
		if (opt == 's')
			sSeconds = atof(optarg);
		else {
			fprintf(stderr, "usage: %s [-s seconds]\n", argv[0]);
			return 2;
		}
	}

	BApplication app("application/x-vnd.haiku-rpi-glview");
	SAY("begin%s", getenv("LIBGL_ALWAYS_SOFTWARE") != NULL ? " (LIBGL_ALWAYS_SOFTWARE)" : "");
	BWindow* window = new BWindow(BRect(100, 100, 100 + kSize - 1, 100 + kSize - 1),
		"glview", B_TITLED_WINDOW, B_NOT_RESIZABLE | B_NOT_ZOOMABLE | B_QUIT_ON_WINDOW_CLOSE);
	BGLView* view = new BGLView(window->Bounds(), (const char*)"gl", B_FOLLOW_ALL_SIDES, 0,
		BGL_RGB | BGL_DOUBLE | BGL_DEPTH);
	window->AddChild(view);
	window->Show();

	thread_id thread = spawn_thread(render_thread, "glview render", B_NORMAL_PRIORITY, view);
	resume_thread(thread);
	app.Run();

	status_t result;
	wait_for_thread(thread, &result);
	return sFailures == 0 ? 0 : 1;
}
