/*
 * drawbench.cpp — app_server drawing speed: opens a window and, for a few seconds each, fills it, draws a
 * bitmap of its size into it, and draws lines of text, each frame waited for with Sync(). Prints frames per
 * second and the pixel rate for each test.
 *
 *   drawbench [WIDTH HEIGHT [SECONDS]]          (default 1600 900, 3 s per test)
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -o drawbench tools/haiku-tests/drawbench.cpp -lbe
 */
#include <Application.h>
#include <Bitmap.h>
#include <View.h>
#include <Window.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>


static void
report(const char* test, int frames, bigtime_t elapsed, int width, int height)
{
	double seconds = elapsed / 1e6;
	printf("drawbench: %-12s %6.1f frames/s, %7.1f Mpixel/s\n", test, frames / seconds,
		frames * (double)width * height / seconds / 1e6);
}


int
main(int argc, char** argv)
{
	int width = argc > 2 ? atoi(argv[1]) : 1600;
	int height = argc > 2 ? atoi(argv[2]) : 900;
	bigtime_t duration = (argc > 3 ? atoi(argv[3]) : 3) * 1000000LL;

	BApplication app("application/x-vnd.haiku-pi-drawbench");
	BRect frame(0, 0, width - 1, height - 1);
	BWindow* window = new BWindow(frame.OffsetToCopy(40, 40), "drawbench", B_TITLED_WINDOW,
		B_NOT_RESIZABLE | B_NOT_ZOOMABLE | B_QUIT_ON_WINDOW_CLOSE);
	BView* view = new BView(frame, "view", B_FOLLOW_ALL, B_WILL_DRAW);
	view->SetViewColor(B_TRANSPARENT_COLOR);
	window->AddChild(view);
	window->Show();
	snooze(500000);

	// solid fills
	window->Lock();
	int frames = 0;
	bigtime_t start = system_time();
	while (system_time() - start < duration) {
		view->SetHighColor(frames & 1 ? 40 : 200, 120, frames & 1 ? 200 : 40);
		view->FillRect(frame);
		view->Sync();
		frames++;
	}
	report("fill", frames, system_time() - start, width, height);

	// bitmap blits (B_RGB32, as an application or a GL view hands its frames over)
	BBitmap bitmap(frame, B_RGB32);
	uint32* bits = (uint32*)bitmap.Bits();
	for (int32 i = 0; i < bitmap.BitsLength() / 4; i++)
		bits[i] = 0xff000000 | (i * 2654435761u >> 8);
	frames = 0;
	start = system_time();
	while (system_time() - start < duration) {
		view->DrawBitmap(&bitmap, B_ORIGIN);
		view->Sync();
		frames++;
	}
	report("bitmap", frames, system_time() - start, width, height);

	// text: a screen of lines (anti-aliased, the default font)
	font_height fontHeight;
	view->GetFontHeight(&fontHeight);
	float lineHeight = fontHeight.ascent + fontHeight.descent + fontHeight.leading;
	int lines = (int)(height / lineHeight);
	const char* text = "The quick brown fox jumps over the lazy dog. 0123456789 Haiku on the Pi 4";
	frames = 0;
	start = system_time();
	while (system_time() - start < duration) {
		view->SetHighColor(255, 255, 255);
		view->FillRect(frame);
		view->SetHighColor(0, 0, 0);
		for (int line = 0; line < lines; line++)
			view->DrawString(text, BPoint(4, (line + 1) * lineHeight));
		view->Sync();
		frames++;
	}
	report("text", frames, system_time() - start, width, height);
	printf("drawbench: text: %d lines of %zu characters per frame\n", lines, strlen(text));
	window->Unlock();

	window->Lock();
	window->Quit();
	return 0;
}
