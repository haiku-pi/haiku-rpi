/*
 * glflip — full-screen OpenGL through BGLView, for GPU stage 6 (docs/design/gpu-stage6.md): a
 * borderless window covering the screen, so that Mesa presents its frames on an overlay plane (page
 * flips, no copy); a rotating triangle and a bar that moves one step per frame (a dropped or doubled
 * frame shows as a jump in an HDMI capture). Prints "GLF " lines:
 *   GLF frames N in T s = F fps; swap intervals: median M ms, K over 1.5x the median (stalls)
 * Mesa's HAIKU_EGL_FPS=1 adds its overlay line (flips, missed, starved, late, dropped), the display
 * driver logs its own per-plane counts on the serial console when the plane goes.
 *
 *   glflip [-n FRAMES] [-i INTERVAL] [-W WIDTH -H HEIGHT] [-o] [-w]   exit status 0 = PASS
 *
 *   -n  frames to draw (default 1200)
 *   -i  swap interval: 1 (default) waits for the vertical blank (BGLView::SwapBuffers(true)), 0 not
 *   -W, -H  a window of that size instead of the screen's (HAIKU_EGL_OVERLAY=1 puts it on a plane)
 *   -o  from a third to two thirds of the frames, a small window lies over the GL window (the overlay
 *       must be keyed: the small window stays visible over the plane)
 *   -w  warm up: 60 frames before the counted ones (the first frames allocate the overlay buffers)
 */

#include <Application.h>
#include <GLView.h>
#include <OS.h>
#include <Screen.h>
#include <StringView.h>
#include <Window.h>

#include <GL/gl.h>

#include <algorithm>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <vector>

#define SAY(...) do { printf("GLF " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static int sFrames = 1200;
static int sInterval = 1;
static int sWidth = 0, sHeight = 0;
static bool sCover = false;
static bool sWarmUp = false;
static int sFailures = 0;


static void
draw_frame(int frame, int width, int height)
{
	glViewport(0, 0, width, height);
	glClearColor(0.0f, 0.0f, 0.25f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();

	// the bar: one 32nd of the width per frame, so a frame shown twice or not at all is a jump
	const float x = -1.0f + 2.0f * ((frame % 64) / 64.0f);
	glColor3f(1.0f, 1.0f, 1.0f);
	glBegin(GL_QUADS);
	glVertex2f(x, -1.0f);
	glVertex2f(x + 2.0f / 64, -1.0f);
	glVertex2f(x + 2.0f / 64, 1.0f);
	glVertex2f(x, 1.0f);
	glEnd();

	glRotatef(frame * 2.0f, 0.0f, 0.0f, 1.0f);
	glScalef((float)height / width, 1.0f, 1.0f);
	glBegin(GL_TRIANGLES);
	glColor3f(1.0f, 0.0f, 0.0f);
	glVertex2f(0.0f, 0.8f);
	glColor3f(0.0f, 1.0f, 0.0f);
	glVertex2f(-0.7f, -0.6f);
	glColor3f(0.0f, 0.0f, 1.0f);
	glVertex2f(0.7f, -0.6f);
	glEnd();
}


static BWindow* sCoverWindow = NULL;


static void
show_cover(bool show)
{
	if (show) {
		BRect frame(BScreen().Frame());
		frame.InsetBy(frame.Width() / 3, frame.Height() / 3);
		sCoverWindow = new BWindow(frame, "glflip cover", B_FLOATING_WINDOW_LOOK,
			B_FLOATING_ALL_WINDOW_FEEL, B_NOT_RESIZABLE | B_AVOID_FOCUS);
		BStringView* label = new BStringView(sCoverWindow->Bounds(), "label",
			"over the overlay");
		label->SetViewColor(255, 220, 0);
		sCoverWindow->AddChild(label);
		sCoverWindow->Show();
		SAY("cover window shown");
	} else if (sCoverWindow != NULL) {
		sCoverWindow->Lock();
		sCoverWindow->Quit();
		sCoverWindow = NULL;
		SAY("cover window gone");
	}
}


static status_t
render_thread(void* data)
{
	BGLView* view = (BGLView*)data;
	snooze(500000);
		// let the window come up

	view->LockLooper();
	const BRect bounds = view->Bounds();
	view->UnlockLooper();
	const int width = bounds.IntegerWidth() + 1;
	const int height = bounds.IntegerHeight() + 1;

	view->LockGL();
	SAY("renderer: %s", (const char*)glGetString(GL_RENDERER));
	SAY("size %dx%d, swap interval %d", width, height, sInterval);
	view->UnlockGL();

	if (sWarmUp) {
		for (int frame = 0; frame < 60; frame++) {
			view->LockGL();
			draw_frame(frame, width, height);
			view->SwapBuffers(sInterval != 0);
			view->UnlockGL();
		}
	}

	std::vector<bigtime_t> intervals;
	intervals.reserve(sFrames);
	const bigtime_t start = system_time();
	bigtime_t last = start;
	for (int frame = 0; frame < sFrames; frame++) {
		if (sCover && frame == sFrames / 3)
			show_cover(true);
		if (sCover && frame == 2 * sFrames / 3)
			show_cover(false);

		view->LockGL();
		draw_frame(frame, width, height);
		if (frame == 0) {
			GLenum error = glGetError();
			SAY("glGetError 0x%x %s", error, error == GL_NO_ERROR ? "ok" : "BAD");
			if (error != GL_NO_ERROR)
				sFailures++;
		}
		view->SwapBuffers(sInterval != 0);
		view->UnlockGL();

		const bigtime_t now = system_time();
		intervals.push_back(now - last);
		last = now;
	}
	const double elapsed = (last - start) / 1000000.0;

	std::vector<bigtime_t> sorted(intervals);
	std::sort(sorted.begin(), sorted.end());
	const bigtime_t median = sorted.empty() ? 0 : sorted[sorted.size() / 2];
	int stalls = 0;
	bigtime_t longest = 0;
	for (size_t i = 1; i < intervals.size(); i++) {
		if (intervals[i] * 2 > median * 3)
			stalls++;
		longest = std::max(longest, intervals[i]);
	}
	SAY("frames %d in %.3f s = %.2f fps; swap intervals: median %.3f ms, longest %.3f ms, "
		"%d over 1.5x the median (stalls)", sFrames, elapsed, sFrames / elapsed, median / 1000.0,
		longest / 1000.0, stalls);
	SAY("%s (%d failure%s)", sFailures == 0 ? "PASS" : "FAIL", sFailures,
		sFailures == 1 ? "" : "s");

	be_app->PostMessage(B_QUIT_REQUESTED);
	return B_OK;
}


int
main(int argc, char** argv)
{
	int opt;
	while ((opt = getopt(argc, argv, "n:i:W:H:ow")) != -1) {
		if (opt == 'n')
			sFrames = atoi(optarg);
		else if (opt == 'i')
			sInterval = atoi(optarg);
		else if (opt == 'W')
			sWidth = atoi(optarg);
		else if (opt == 'H')
			sHeight = atoi(optarg);
		else if (opt == 'o')
			sCover = true;
		else if (opt == 'w')
			sWarmUp = true;
		else {
			fprintf(stderr, "usage: %s [-n frames] [-i interval] [-W width -H height] [-o] [-w]\n",
				argv[0]);
			return 2;
		}
	}

	BApplication app("application/x-vnd.haiku-rpi-glflip");
	BRect frame = BScreen().Frame();
	window_look look = B_NO_BORDER_WINDOW_LOOK;
	if (sWidth > 0 && sHeight > 0) {
		frame.Set(100, 100, 100 + sWidth - 1, 100 + sHeight - 1);
		look = B_TITLED_WINDOW_LOOK;
	}
	SAY("begin %s %dx%d", look == B_NO_BORDER_WINDOW_LOOK ? "full screen" : "window",
		frame.IntegerWidth() + 1, frame.IntegerHeight() + 1);
	BWindow* window = new BWindow(frame, "glflip", look, B_NORMAL_WINDOW_FEEL,
		B_NOT_RESIZABLE | B_NOT_ZOOMABLE | B_NOT_MOVABLE | B_QUIT_ON_WINDOW_CLOSE);
	BGLView* view = new BGLView(window->Bounds(), (const char*)"gl", B_FOLLOW_ALL_SIDES, 0,
		BGL_RGB | BGL_DOUBLE | BGL_DEPTH);
	window->AddChild(view);
	window->Show();

	thread_id thread = spawn_thread(render_thread, "glflip render", B_NORMAL_PRIORITY, view);
	resume_thread(thread);
	app.Run();

	status_t result;
	wait_for_thread(thread, &result);
	return sFailures == 0 ? 0 : 1;
}
