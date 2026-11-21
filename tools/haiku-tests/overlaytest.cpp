/*
 * overlaytest.cpp — hardware overlays through the overlay API, as MediaPlayer uses it
 * (B_BITMAP_WILL_OVERLAY bitmaps, BView::SetViewOverlay(), B_OVERLAY_TRANSFER_CHANNEL flips), for
 * GPU stage 6 (docs/design/gpu-stage6.md §4). Per color space: two 320x240 overlay bitmaps with
 * color bars and a square, shown scaled to 640x480 in a window, flipped every vertical blank (the
 * square moves), then a small window over the overlay (it must stay visible: keying), the window
 * moved partly off the screen (the overlay is clipped), and the last frame held for a snapshot.
 * Prints "OVL " lines; grade the HDMI capture: bars in the right colors and order (white, yellow,
 * cyan, green, magenta, red, blue, black), the yellow window over them.
 * The front buffer's alpha (app_server keys overlays by it on the Raspberry Pi, only while one is
 * shown) is read back (BScreen::ReadBitmap()) next to a probe window that draws pixels with alpha 0:
 * before the first overlay (not keyed: the probe's pixels as drawn), while it is shown (keyed: no
 * pixel outside the overlay may be other than opaque) and after it was hidden (not keyed again).
 * Inside the overlay the read-back has the key's transparent pixels, or, with an app_server that reads
 * overlays back (gpu-stage6.md §11), the bars ("N bar-coloured").
 * -p SECONDS: how long the cover window and the move partly off the screen last (default 2), to take
 * screenshots and HDMI snapshots of them (tools/pi-tests/s1-readback.sh).
 *
 *   overlaytest [-s rgb32|ycbcr422|yuv420|sand|sand10] [-f FLIPS] [-h SECONDS] [-p SECONDS]
 *       [-x WIDTHxHEIGHT]
 *       (default: rgb32 and yuv420, 320x240; from 720 lines on the accelerant takes YCbCr as BT.709)
 *
 * sand / sand10 (only on request): B_YUV420_SAND128(_10) (0x4028, 0x4029: GraphicsDefs.h of the v6-video branch), the HEVC decoder's layout (luma and chroma in
 * 128-byte columns, bytes_per_row = the column height; 10 bit: three samples per 32-bit word),
 * hw-video-decode.md §9.
 * B_YUV420 is planar I420 as the accelerant defines it (docs/design/video-overlay.md): bytes_per_row
 * is the whole picture's (3 bytes per 2 pixels), the luma rows are 2/3 of it, Cb and Cr follow the
 * luma with rows of 1/3 of it. B_YCbCr422 (packed) is not offered any more: its bitmaps must fail.
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

static int kWidth = 320;
static int kHeight = 240;
static int sFlips = 240;
static double sHold = 5;
static double sPhase = 2;
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


// B_YUV420_SAND128 and _10 (the headers of the sysroot may not have them yet)
static constexpr color_space kSand = (color_space)0x4028;
static constexpr color_space kSand10 = (color_space)0x4029;


// limited range; BT.601 below 720 lines, BT.709 from 720 on (as the accelerant encodes)
static void
to_ycbcr(uint8 r, uint8 g, uint8 b, uint8& y, uint8& cb, uint8& cr)
{
	if (kHeight < 720) {
		y = (uint8)(16 + (65.738 * r + 129.057 * g + 25.064 * b) / 256);
		cb = (uint8)(128 + (-37.945 * r - 74.494 * g + 112.439 * b) / 256);
		cr = (uint8)(128 + (112.439 * r - 94.154 * g - 18.285 * b) / 256);
	} else {
		y = (uint8)(16 + (46.742 * r + 157.243 * g + 15.874 * b) / 256);
		cb = (uint8)(128 + (-25.765 * r - 86.674 * g + 112.439 * b) / 256);
		cr = (uint8)(128 + (112.439 * r - 102.129 * g - 10.310 * b) / 256);
	}
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
	switch ((uint32)bitmap->ColorSpace()) {
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
			// planar: Y, then Cb and Cr of half the width and height; the luma rows are 2/3
			// of bytes_per_row (the whole picture's: 3 bytes per 2 pixels)
			const int32 luma = bpr / 3 * 2;
			const int32 chroma = luma / 2;
			const int32 height = (kHeight + 1) & ~1;
			uint8* cbPlane = bits + luma * height;
			uint8* crPlane = cbPlane + chroma * (height / 2);
			for (int y = 0; y < kHeight; y++) {
				for (int x = 0; x < kWidth; x++) {
					uint8 r, g, b, lumaValue, cb, cr;
					rgb_at(x, y, frame, r, g, b);
					to_ycbcr(r, g, b, lumaValue, cb, cr);
					bits[y * luma + x] = lumaValue;
					if ((x & 1) == 0 && (y & 1) == 0) {
						cbPlane[y / 2 * chroma + x / 2] = cb;
						crPlane[y / 2 * chroma + x / 2] = cr;
					}
				}
			}
			break;
		}
		case kSand:
		case kSand10:
		{
			// columns 128 bytes wide, bpr rows each: the luma rows, then (from the height
			// rounded to 16) the CbCr rows
			const bool ten = bitmap->ColorSpace() == kSand10;
			const size_t column = (size_t)bpr * 128;
			const int32 chromaRow = ((kHeight + 15) & ~15);
			for (int y = 0; y < kHeight; y++) {
				for (int x = 0; x < kWidth; x++) {
					uint8 r, g, b, lumaValue, cb, cr;
					rgb_at(x, y, frame, r, g, b);
					to_ycbcr(r, g, b, lumaValue, cb, cr);
					if (!ten) {
						bits[x / 128 * column + y * 128 + x % 128] = lumaValue;
						if ((x & 1) == 0 && (y & 1) == 0) {
							uint8* pair = bits + x / 128 * column + (chromaRow + y / 2) * 128
								+ x % 128;
							pair[0] = cb;
							pair[1] = cr;
						}
						continue;
					}
					// 96 samples per column, sample k in word k / 3 at bit (k % 3) * 10
					uint32* words = (uint32*)(bits + x / 96 * column + y * 128);
					const int k = x % 96;
					words[k / 3] = (words[k / 3] & ~(0x3ffu << (k % 3 * 10)))
						| (uint32)(lumaValue << 2) << (k % 3 * 10);
					if ((x & 1) == 0 && (y & 1) == 0) {
						// chroma sample x is Cb, x + 1 Cr
						for (int c = 0; c < 2; c++) {
							const int s = x + c;
							uint32* chroma = (uint32*)(bits + s / 96 * column
								+ (chromaRow + y / 2) * 128);
							const int j = s % 96;
							chroma[j / 3] = (chroma[j / 3] & ~(0x3ffu << (j % 3 * 10)))
								| (uint32)((c == 0 ? cb : cr) << 2) << (j % 3 * 10);
						}
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


/*!	A window whose B_RGB32 bitmap has alpha 0: app_server copies its pixels as they are */
class ProbeView : public BView {
public:
	ProbeView(BRect frame)
		:
		BView(frame, "probe", B_FOLLOW_ALL, B_WILL_DRAW),
		fBitmap(BRect(0, 0, 63, 63), B_RGB32)
	{
		uint8* bits = (uint8*)fBitmap.Bits();
		for (size_t i = 0; i < (size_t)fBitmap.BitsLength(); i += 4) {
			bits[i] = 200;
			bits[i + 1] = 100;
			bits[i + 2] = 50;
			bits[i + 3] = 0;
		}
		SetViewColor(B_TRANSPARENT_COLOR);
	}

	void Draw(BRect) override
	{
		SetDrawingMode(B_OP_COPY);
		DrawBitmap(&fBitmap, BPoint(0, 0));
	}

private:
	BBitmap fBitmap;
};


static const BRect kProbeFrame(800, 100, 863, 163);
static const int kProbePixels = 64 * 64;


/*!	The front buffer's pixels: those not opaque outside \a overlay (screen coordinates), and the
	transparent ones (0x00000000: keyed) in it; \a probe: those not opaque in the probe window.
	-1 if the screen cannot be read.
*/
static bool
bar_coloured(uint32 pixel)
{
	const int r = (pixel >> 16) & 0xff, g = (pixel >> 8) & 0xff, b = pixel & 0xff;
	for (int i = 0; i < 8; i++) {
		if (abs(r - kBars[i][0]) <= 16 && abs(g - kBars[i][1]) <= 16 && abs(b - kBars[i][2]) <= 16)
			return true;
	}
	return r >= 239 && g >= 239 && b >= 239;
		// the square
}


static void
alpha_census(const char* name, const char* when, BRect overlay, int& outside, int& keyed,
	int& probe, int* barPixels = NULL)
{
	BScreen screen;
	BBitmap shot(screen.Frame(), B_RGB32);
	outside = keyed = probe = -1;
	if (shot.InitCheck() != B_OK || screen.ReadBitmap(&shot) != B_OK) {
		SAY("%s alpha %s: cannot read the screen", name, when);
		return;
	}
	outside = keyed = probe = 0;
	int bars = 0;
	const uint8* bits = (const uint8*)shot.Bits();
	const int32 bpr = shot.BytesPerRow();
	const int32 width = shot.Bounds().IntegerWidth() + 1;
	const int32 height = shot.Bounds().IntegerHeight() + 1;
	for (int32 y = 0; y < height; y++) {
		const uint32* row = (const uint32*)(bits + y * bpr);
		for (int32 x = 0; x < width; x++) {
			if (overlay.Contains(BPoint(x, y))) {
				if (row[x] == 0)
					keyed++;
				else if ((row[x] >> 24) == 0xff && bar_coloured(row[x]))
					bars++;
			} else if ((row[x] >> 24) != 0xff) {
				outside++;
				if (kProbeFrame.Contains(BPoint(x, y)))
					probe++;
			}
		}
	}
	SAY("%s alpha %s: %d pixels not opaque outside the overlay (%d of the probe's %d), %d "
		"transparent in it, %d bar-coloured", name, when, outside, probe, kProbePixels, keyed, bars);
	if (barPixels != NULL)
		*barPixels = bars;
}


static const char*
space_name(color_space space)
{
	switch ((uint32)space) {
		case B_RGB32:
			return "rgb32";
		case B_YCbCr422:
			return "ycbcr422";
		case B_YUV420:
			return "yuv420";
		case kSand:
			return "sand";
		case kSand10:
			return "sand10";
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

	// shown at twice the size, or the buffer's size from 720 lines on (as video)
	const int scale = kHeight < 720 ? 2 : 1;
	BWindow* window = new BWindow(BRect(100, 100, 100 + scale * kWidth - 1,
		100 + scale * kHeight - 1),
		name, B_TITLED_WINDOW, B_NOT_RESIZABLE | B_NOT_ZOOMABLE);
	BView* view = new BView(window->Bounds(), "overlay", B_FOLLOW_ALL, B_WILL_DRAW);
	window->AddChild(view);
	window->Show();
	BWindow* probe = new BWindow(kProbeFrame, "alpha probe", B_NO_BORDER_WINDOW_LOOK,
		B_FLOATING_ALL_WINDOW_FEEL, B_NOT_MOVABLE | B_AVOID_FOCUS);
	ProbeView* probeView = new ProbeView(probe->Bounds());
	probe->AddChild(probeView);
	probe->Show();
	snooze(300000);
	window->Lock();
	const BRect overlayRect = view->ConvertToScreen(view->Bounds());
	window->Unlock();
	int outside, keyed, before;
	alpha_census(name, "before", overlayRect, outside, keyed, before);

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
		probe->Lock();
		probe->Quit();
		return;
	}

	// keyed: the front buffer was made opaque before the overlay showed, the key is transparent
	snooze(300000);
	int probed, bars;
	alpha_census(name, "shown", overlayRect, outside, keyed, probed, &bars);
	// the key's transparent pixels, or, read back, the overlay's picture
	const int overlayPixels = overlayRect.IntegerWidth() * overlayRect.IntegerHeight();
	const bool keyedOk = outside == 0 && (keyed > 0 || bars > overlayPixels * 3 / 4);
	SAY("%s keyed front buffer %s", name, keyedOk ? "ok" : "BAD");
	if (!keyedOk)
		sFailures++;

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
	snooze((bigtime_t)(sPhase * 1e6));
	cover->Lock();
	cover->Quit();

	// partly off the screen: the driver clips the plane
	window->Lock();
	window->MoveTo(-200, 100);
	window->Unlock();
	SAY("%s window moved to -200,100 (HDMI: the bars cut at the left edge)", name);
	snooze((bigtime_t)(sPhase * 1e6));
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

	// not keyed again (app_server stops keying 100 ms after the last overlay went): the probe drawn
	// again comes out as before
	snooze(500000);
	probe->Lock();
	probeView->Invalidate();
	probe->Unlock();
	snooze(300000);
	alpha_census(name, "after", overlayRect, outside, keyed, probed);
	SAY("%s after the overlay: %s", name, before < kProbePixels
		? "(the probe's alpha was not drawn as it is: no check)"
		: probed == kProbePixels ? "not keyed ok" : "still keyed (opaque writes)");
	probe->Lock();
	probe->Quit();
	SAY("%s done", name);
}


int
main(int argc, char** argv)
{
	color_space only = B_NO_COLOR_SPACE;
	int opt;
	while ((opt = getopt(argc, argv, "s:f:h:p:x:")) != -1) {
		if (opt == 's') {
			if (strcmp(optarg, "rgb32") == 0)
				only = B_RGB32;
			else if (strcmp(optarg, "ycbcr422") == 0)
				only = B_YCbCr422;
			else if (strcmp(optarg, "yuv420") == 0)
				only = B_YUV420;
			else if (strcmp(optarg, "sand") == 0)
				only = kSand;
			else if (strcmp(optarg, "sand10") == 0)
				only = kSand10;
		} else if (opt == 'f')
			sFlips = atoi(optarg);
		else if (opt == 'h')
			sHold = atof(optarg);
		else if (opt == 'p')
			sPhase = atof(optarg);
		else if (opt == 'x' && sscanf(optarg, "%dx%d", &kWidth, &kHeight) == 2 && kWidth >= 64
			&& kHeight >= 64) {
		} else {
			fprintf(stderr, "usage: %s [-s rgb32|ycbcr422|yuv420|sand|sand10] [-f flips] [-h seconds] "
				"[-p seconds] [-x WIDTHxHEIGHT]\n", argv[0]);
			return 2;
		}
	}

	BApplication app("application/x-vnd.haiku-rpi-overlaytest");
	uint32 support = 0;
	const color_space spaces[] = { B_RGB32, B_YCbCr422, B_YUV420, kSand,
		kSand10 };
	for (color_space space : spaces) {
		bitmaps_support_space(space, &support);
		SAY("%s: %s", space_name(space),
			(support & B_BITMAPS_SUPPORT_OVERLAY) != 0 ? "overlays" : "no overlays");
	}
	for (color_space space : spaces) {
		// (no packed 4:2:2 on the display: only when asked for, and it must fail)
		if ((only == B_NO_COLOR_SPACE && (space == B_RGB32 || space == B_YUV420))
			|| only == space)
			test_space(space);
	}
	SAY("end: %s (%d failure%s)", sFailures == 0 ? "PASS" : "FAIL", sFailures,
		sFailures == 1 ? "" : "s");
	return sFailures == 0 ? 0 : 1;
}
