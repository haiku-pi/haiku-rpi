/*
 * overlaytest.cpp — hardware overlays through the overlay API, as MediaPlayer uses it
 * (B_BITMAP_WILL_OVERLAY bitmaps, BView::SetViewOverlay(), B_OVERLAY_TRANSFER_CHANNEL flips), for
 * GPU stage 6 (docs/design/gpu-stage6.md §4). Per color space: two 320x240 overlay bitmaps with
 * color bars and a square, shown scaled to 640x480 in a window, flipped every vertical blank (the
 * square moves), then a small window over the overlay (it must stay visible: keying), the window
 * moved partly off the screen (the overlay is clipped), and the last frame held for a snapshot.
 * Prints "OVL " lines; grade the HDMI capture: bars in the right colors and order (white, yellow,
 * cyan, green, magenta, red, blue, black), the yellow window over them.
 *
 *   overlaytest [-s rgb32|ycbcr422|yuv420] [-f FLIPS] [-h SECONDS]   (default: all three spaces)
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -o overlaytest tools/haiku-tests/overlaytest.cpp -lbe
 */
#include <Application.h>
#include <Bitmap.h>
#include <Screen.h>
#include <StringView.h>
#include <View.h>
#include <Window.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAY(...) do { printf("OVL " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static const int kWidth = 320;
static const int kHeight = 240;
static int sFlips = 240;
static double sHold = 5;
static int sFailures = 0;

// the bars: white, yellow, cyan, green, magenta, red, blue, black (75 %)
static const uint8 kBars[8][3] = {
	{ 191, 191, 191 }, { 191, 191, 0 }, { 0, 191, 191 }, { 0, 191, 0 },
	{ 191, 0, 191 }, { 191, 0, 0 }, { 0, 0, 191 }, { 0, 0, 0 }
};


static void
rgb_at(int x, int y, int frame, uint8& r, uint8& g, uint8& b)
{
	const int squareX = (frame * 4) % (kWidth - 40);
	if (x >= squareX && x < squareX + 40 && y >= 100 && y < 140) {
		r = g = b = 255;
		return;
	}
	const uint8* bar = kBars[x * 8 / kWidth];
	r = bar[0];
	g = bar[1];
	b = bar[2];
}


// BT.601, limited range (the accelerant's encoding below 720 lines)
static void
to_ycbcr(uint8 r, uint8 g, uint8 b, uint8& y, uint8& cb, uint8& cr)
{
	y = (uint8)(16 + (65.738 * r + 129.057 * g + 25.064 * b) / 256);
	cb = (uint8)(128 + (-37.945 * r - 74.494 * g + 112.439 * b) / 256);
	cr = (uint8)(128 + (112.439 * r - 94.154 * g - 18.285 * b) / 256);
}


static bool
fill(BBitmap* bitmap, int frame)
{
	if (bitmap->LockBits() != B_OK) {
		SAY("LockBits failed BAD");
		return false;
	}
	uint8* bits = (uint8*)bitmap->Bits();
	const int32 bpr = bitmap->BytesPerRow();
	switch (bitmap->ColorSpace()) {
		case B_RGB32:
			for (int y = 0; y < kHeight; y++) {
				uint8* row = bits + y * bpr;
				for (int x = 0; x < kWidth; x++) {
					uint8 r, g, b;
					rgb_at(x, y, frame, r, g, b);
					row[x * 4] = b;
					row[x * 4 + 1] = g;
					row[x * 4 + 2] = r;
					row[x * 4 + 3] = 255;
				}
			}
			break;
		case B_YCbCr422:
			// Y0 Cb Y1 Cr
			for (int y = 0; y < kHeight; y++) {
				uint8* row = bits + y * bpr;
				for (int x = 0; x < kWidth; x += 2) {
					uint8 r, g, b, y0, y1, cb, cr, cb1, cr1;
					rgb_at(x, y, frame, r, g, b);
					to_ycbcr(r, g, b, y0, cb, cr);
					rgb_at(x + 1, y, frame, r, g, b);
					to_ycbcr(r, g, b, y1, cb1, cr1);
					row[x * 2] = y0;
					row[x * 2 + 1] = cb;
					row[x * 2 + 2] = y1;
					row[x * 2 + 3] = cr;
				}
			}
			break;
		case B_YUV420:
		{
			// planar: Y, then Cb and Cr of half the pitch and height
			uint8* cbPlane = bits + bpr * kHeight;
			uint8* crPlane = cbPlane + bpr / 2 * kHeight / 2;
			for (int y = 0; y < kHeight; y++) {
				for (int x = 0; x < kWidth; x++) {
					uint8 r, g, b, luma, cb, cr;
					rgb_at(x, y, frame, r, g, b);
					to_ycbcr(r, g, b, luma, cb, cr);
					bits[y * bpr + x] = luma;
					if ((x & 1) == 0 && (y & 1) == 0) {
						cbPlane[y / 2 * (bpr / 2) + x / 2] = cb;
						crPlane[y / 2 * (bpr / 2) + x / 2] = cr;
					}
				}
			}
			break;
		}
		default:
			break;
	}
	bitmap->UnlockBits();
	return true;
}


static const char*
space_name(color_space space)
{
	switch (space) {
		case B_RGB32:
			return "rgb32";
		case B_YCbCr422:
			return "ycbcr422";
		case B_YUV420:
			return "yuv420";
		default:
			return "?";
	}
}


static void
test_space(color_space space)
{
	const char* name = space_name(space);
	BBitmap* bitmaps[2];
	const BRect bounds(0, 0, kWidth - 1, kHeight - 1);
	for (int i = 0; i < 2; i++) {
		bitmaps[i] = new BBitmap(bounds, B_BITMAP_WILL_OVERLAY
			| (i == 0 ? B_BITMAP_RESERVE_OVERLAY_CHANNEL : 0), space);
		const status_t status = bitmaps[i]->InitCheck();
		// (Bits() of an overlay bitmap that failed would crash: no client data)
		SAY("%s bitmap %d: %s, bits %p, %" B_PRId32 " bytes per row %s", name, i,
			strerror(status), status == B_OK ? bitmaps[i]->Bits() : NULL,
			status == B_OK ? bitmaps[i]->BytesPerRow() : 0, status == B_OK ? "ok" : "BAD");
		if (status != B_OK) {
			sFailures++;
			delete bitmaps[0];
			if (i == 1)
				delete bitmaps[1];
			return;
		}
	}
	// the writes go straight to the display's buffer (a kernel area every team may write)
	if (!fill(bitmaps[0], 0) || !fill(bitmaps[1], 1)) {
		sFailures++;
		return;
	}
	SAY("%s filled ok", name);

	BWindow* window = new BWindow(BRect(100, 100, 100 + 2 * kWidth - 1, 100 + 2 * kHeight - 1),
		name, B_TITLED_WINDOW, B_NOT_RESIZABLE | B_NOT_ZOOMABLE);
	BView* view = new BView(window->Bounds(), "overlay", B_FOLLOW_ALL, B_WILL_DRAW);
	window->AddChild(view);
	window->Show();
	snooze(300000);

	window->Lock();
	rgb_color key;
	status_t status = view->SetViewOverlay(bitmaps[0], bounds, view->Bounds(), &key,
		B_FOLLOW_ALL, B_OVERLAY_FILTER_HORIZONTAL | B_OVERLAY_FILTER_VERTICAL);
	if (status == B_OK) {
		view->SetViewColor(key);
		view->Invalidate();
	}
	window->Unlock();
	SAY("%s SetViewOverlay: %s, key %d,%d,%d,%d %s", name, strerror(status), key.red, key.green,
		key.blue, key.alpha, status == B_OK ? "ok" : "BAD");
	if (status != B_OK) {
		sFailures++;
		window->Lock();
		window->Quit();
		return;
	}

	// a flip per vertical blank; the square moves
	BScreen screen(window);
	const bigtime_t start = system_time();
	int failed = 0;
	for (int flip = 1; flip <= sFlips; flip++) {
		BBitmap* next = bitmaps[flip & 1];
		fill(next, flip);
		screen.WaitForRetrace(100000);
		window->Lock();
		if (view->SetViewOverlay(next, bounds, view->Bounds(), &key, B_FOLLOW_ALL,
				B_OVERLAY_FILTER_HORIZONTAL | B_OVERLAY_FILTER_VERTICAL
					| B_OVERLAY_TRANSFER_CHANNEL) != B_OK) {
			failed++;
		}
		window->Unlock();
	}
	const double elapsed = (system_time() - start) / 1e6;
	SAY("%s %d flips in %.2f s = %.1f/s, %d failed %s", name, sFlips, elapsed, sFlips / elapsed,
		failed, failed == 0 ? "ok" : "BAD");
	if (failed > 0)
		sFailures++;

	// a window over the overlay: keyed, it stays visible
	BWindow* cover = new BWindow(BRect(300, 250, 500, 350), "over the overlay",
		B_FLOATING_WINDOW_LOOK, B_FLOATING_ALL_WINDOW_FEEL, B_NOT_RESIZABLE | B_AVOID_FOCUS);
	BStringView* label = new BStringView(cover->Bounds(), "label", "over the overlay");
	label->SetViewColor(255, 220, 0);
	cover->AddChild(label);
	cover->Show();
	SAY("%s cover window shown (HDMI: the yellow window over the bars)", name);
	snooze(2000000);
	cover->Lock();
	cover->Quit();

	// partly off the screen: the driver clips the plane
	window->Lock();
	window->MoveTo(-200, 100);
	window->Unlock();
	SAY("%s window moved to -200,100 (HDMI: the bars cut at the left edge)", name);
	snooze(2000000);
	window->Lock();
	window->MoveTo(100, 100);
	window->Unlock();

	SAY("%s holding %.0f s", name, sHold);
	snooze((bigtime_t)(sHold * 1e6));

	window->Lock();
	view->ClearViewOverlay();
	window->Quit();
	delete bitmaps[0];
	delete bitmaps[1];
	SAY("%s done", name);
}


int
main(int argc, char** argv)
{
	color_space only = B_NO_COLOR_SPACE;
	int opt;
	while ((opt = getopt(argc, argv, "s:f:h:")) != -1) {
		if (opt == 's') {
			if (strcmp(optarg, "rgb32") == 0)
				only = B_RGB32;
			else if (strcmp(optarg, "ycbcr422") == 0)
				only = B_YCbCr422;
			else if (strcmp(optarg, "yuv420") == 0)
				only = B_YUV420;
		} else if (opt == 'f')
			sFlips = atoi(optarg);
		else if (opt == 'h')
			sHold = atof(optarg);
		else {
			fprintf(stderr, "usage: %s [-s rgb32|ycbcr422|yuv420] [-f flips] [-h seconds]\n",
				argv[0]);
			return 2;
		}
	}

	BApplication app("application/x-vnd.haiku-rpi-overlaytest");
	uint32 support = 0;
	const color_space spaces[] = { B_RGB32, B_YCbCr422, B_YUV420 };
	for (color_space space : spaces) {
		bitmaps_support_space(space, &support);
		SAY("%s: %s", space_name(space),
			(support & B_BITMAPS_SUPPORT_OVERLAY) != 0 ? "overlays" : "no overlays");
	}
	for (color_space space : spaces) {
		if (only == B_NO_COLOR_SPACE || only == space)
			test_space(space);
	}
	SAY("end: %s (%d failure%s)", sFailures == 0 ? "PASS" : "FAIL", sFailures,
		sFailures == 1 ? "" : "s");
	return sFailures == 0 ? 0 : 1;
}
