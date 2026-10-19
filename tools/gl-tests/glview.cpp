/*
 * glview — windowed OpenGL test through Haiku's GL kit (BGLView from libglvnd's libGL.so, EGL
 * window surface, Mesa's egl_haiku): opens a window, animates a triangle with desktop GL for a few
 * seconds, checks the rendered back buffer with glReadPixels before each check-frame's swap, and
 * prints "GLW " lines (send them to /dev/dprintf from a boot script). On a hardware screen the
 * frames reach the window through egl_haiku's copy present; HDMI shows whether they do.
 *
 *   glview [-s SECONDS] [-f] [-y] [-b] [-n] [-a] [-S] [-c]     exit status 0 = PASS
 *
 *   -f  draw into a framebuffer object instead of the window (and check that)
 *   -y  with -f: y-flipped, as Mesa renders into window framebuffers
 *   -b  with -f: the texture in B, G, R, A order
 *   -n  no depth buffer          -a  an alpha channel
 *   -S  clear the stencil buffer too (the whole depth/stencil buffer)
 *   -d  with -f: a depth/stencil renderbuffer (GL_DEPTH24_STENCIL8), like the window's
 *   -W  SIZE: a SIZE x SIZE window (default 256)
 *   -c  no glClear at all (the corner check then fails: only the triangle is drawn)
 */

#include <Application.h>
#include <GLView.h>
#include <OS.h>
#include <Window.h>

#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAY(...) do { printf("GLW " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static int kSize = 256;
static int sFailures = 0;
static double sSeconds = 5;
static bool sOffscreen = false;
static bool sFlipY = false;
static bool sBgra = false;
static bool sClear = true;
static bool sOffscreenDepth = false;
static GLbitfield sClearMask = GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT;


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

	if (sOffscreen) {
		// the same drawing, into a framebuffer object instead of the window
		view->LockGL();
		PFNGLGENFRAMEBUFFERSPROC genFramebuffers
			= (PFNGLGENFRAMEBUFFERSPROC)view->GetGLProcAddress("glGenFramebuffers");
		PFNGLBINDFRAMEBUFFERPROC bindFramebuffer
			= (PFNGLBINDFRAMEBUFFERPROC)view->GetGLProcAddress("glBindFramebuffer");
		PFNGLFRAMEBUFFERTEXTURE2DPROC framebufferTexture2D
			= (PFNGLFRAMEBUFFERTEXTURE2DPROC)view->GetGLProcAddress(
				"glFramebufferTexture2D");
		PFNGLCHECKFRAMEBUFFERSTATUSPROC checkFramebufferStatus
			= (PFNGLCHECKFRAMEBUFFERSTATUSPROC)view->GetGLProcAddress(
				"glCheckFramebufferStatus");
		GLuint texture, fbo;
		glGenTextures(1, &texture);
		glBindTexture(GL_TEXTURE_2D, texture);
		// -b: B, G, R, A order, like the window buffers
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, kSize, kSize, 0,
			sBgra ? GL_BGRA : GL_RGBA, GL_UNSIGNED_BYTE, NULL);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		genFramebuffers(1, &fbo);
		bindFramebuffer(GL_FRAMEBUFFER, fbo);
		framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
			texture, 0);
		if (sOffscreenDepth) {
			PFNGLGENRENDERBUFFERSPROC genRenderbuffers
				= (PFNGLGENRENDERBUFFERSPROC)view->GetGLProcAddress("glGenRenderbuffers");
			PFNGLBINDRENDERBUFFERPROC bindRenderbuffer
				= (PFNGLBINDRENDERBUFFERPROC)view->GetGLProcAddress("glBindRenderbuffer");
			PFNGLRENDERBUFFERSTORAGEPROC renderbufferStorage
				= (PFNGLRENDERBUFFERSTORAGEPROC)view->GetGLProcAddress(
					"glRenderbufferStorage");
			PFNGLFRAMEBUFFERRENDERBUFFERPROC framebufferRenderbuffer
				= (PFNGLFRAMEBUFFERRENDERBUFFERPROC)view->GetGLProcAddress(
					"glFramebufferRenderbuffer");
			GLuint depth;
			genRenderbuffers(1, &depth);
			bindRenderbuffer(GL_RENDERBUFFER, depth);
			renderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, kSize, kSize);
			framebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
				GL_RENDERBUFFER, depth);
			SAY("offscreen fbo depth/stencil renderbuffer, error 0x%x", glGetError());
		}
		if (sFlipY) {
			// render upside down, as Mesa does into window framebuffers
			PFNGLFRAMEBUFFERPARAMETERIPROC framebufferParameteri
				= (PFNGLFRAMEBUFFERPARAMETERIPROC)view->GetGLProcAddress(
					"glFramebufferParameteri");
			if (framebufferParameteri != NULL)
				framebufferParameteri(GL_FRAMEBUFFER, GL_FRAMEBUFFER_FLIP_Y_MESA, 1);
			SAY("offscreen fbo flip y %s, error 0x%x",
				framebufferParameteri != NULL ? "set" : "unavailable", glGetError());
		}
		SAY("offscreen fbo status 0x%x", checkFramebufferStatus(GL_FRAMEBUFFER));
		view->UnlockGL();
	}

	{
		// what decides between a hardware clear and a quad drawn by Mesa
		view->LockGL();
		GLint scissor[4], viewport[4];
		GLboolean mask[4];
		glGetIntegerv(GL_SCISSOR_BOX, scissor);
		glGetIntegerv(GL_VIEWPORT, viewport);
		glGetBooleanv(GL_COLOR_WRITEMASK, mask);
		SAY("state: scissor test %d box %d,%d %dx%d, viewport %d,%d %dx%d, color mask %d%d%d%d",
			glIsEnabled(GL_SCISSOR_TEST), scissor[0], scissor[1], scissor[2], scissor[3],
			viewport[0], viewport[1], viewport[2], viewport[3], mask[0], mask[1], mask[2],
			mask[3]);
		view->UnlockGL();
	}

	const bigtime_t start = system_time();
	int frames = 0;
	while (system_time() - start < (bigtime_t)(sSeconds * 1000000)) {
		view->LockGL();
		glViewport(0, 0, kSize, kSize);
		glClearColor(0.0f, 0.0f, 0.25f, 1.0f);
		if (sClear)
			glClear(sClearMask);
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
	uint32 options = BGL_RGB | BGL_DOUBLE | BGL_DEPTH;
	while ((opt = getopt(argc, argv, "s:nafSybcdW:")) != -1) {
		if (opt == 's')
			sSeconds = atof(optarg);
		else if (opt == 'n')
			options &= ~BGL_DEPTH;
		else if (opt == 'a')
			options |= BGL_ALPHA;
		else if (opt == 'f')
			sOffscreen = true;
		else if (opt == 'S')
			sClearMask |= GL_STENCIL_BUFFER_BIT;
		else if (opt == 'y')
			sFlipY = true;
		else if (opt == 'b')
			sBgra = true;
		else if (opt == 'c')
			sClear = false;
		else if (opt == 'd')
			sOffscreenDepth = true;
		else if (opt == 'W')
			kSize = atoi(optarg);
		else {
			fprintf(stderr, "usage: %s [-s seconds] [-n (no depth buffer)] [-a (alpha)]\n",
				argv[0]);
			return 2;
		}
	}

	BApplication app("application/x-vnd.haiku-rpi-glview");
	SAY("begin%s%s%s", getenv("LIBGL_ALWAYS_SOFTWARE") != NULL ? " (LIBGL_ALWAYS_SOFTWARE)" : "",
		(options & BGL_DEPTH) == 0 ? " (no depth buffer)" : "",
		(options & BGL_ALPHA) != 0 ? " (alpha)" : "");
	BWindow* window = new BWindow(BRect(100, 100, 100 + kSize - 1, 100 + kSize - 1),
		"glview", B_TITLED_WINDOW, B_NOT_RESIZABLE | B_NOT_ZOOMABLE | B_QUIT_ON_WINDOW_CLOSE);
	BGLView* view = new BGLView(window->Bounds(), (const char*)"gl", B_FOLLOW_ALL_SIDES, 0,
		options);
	window->AddChild(view);
	window->Show();

	thread_id thread = spawn_thread(render_thread, "glview render", B_NORMAL_PRIORITY, view);
	resume_thread(thread);
	app.Run();

	status_t result;
	wait_for_thread(thread, &result);
	return sFailures == 0 ? 0 : 1;
}
