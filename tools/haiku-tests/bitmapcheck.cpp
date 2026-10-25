/*
 * bitmapcheck.cpp — app_server's bitmap drawing, checked through the screen: draws large B_RGB32/B_RGBA32
 * bitmaps the ways a GL/Vulkan presenter and ordinary programs do — outside an update session (copy to
 * the front buffer at once), inside one (Invalidate() + Draw(), copied at its end), with drawing over
 * the bitmap, two bitmaps over each other, a source rectangle at an offset, DrawBitmapAsync() (whose
 * copy app_server may defer to the end of the update), a window partly covering
 * the target — and reads the screen back after each (BScreen::GetBitmap(): the front buffer). Moving
 * the window makes app_server copy its pixels from the back buffer, unredrawn: the "moved" hashes
 * check what went there.
 * Prints "BMC <test> <hash>" per test: two app_servers that draw the same must print the same hashes
 * (docs/design/gpu-present.md, C1). The last test leaves its picture on screen for a front-buffer
 * snapshot (QEMU screendump, HDMI capture).
 *
 *   bitmapcheck [SECONDS-TO-HOLD]
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -o bitmapcheck tools/haiku-tests/bitmapcheck.cpp -lbe
 */
#include <Application.h>
#include <Bitmap.h>
#include <Screen.h>
#include <View.h>
#include <Window.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>


static const int32 kWidth = 640;
static const int32 kHeight = 480;
static const BPoint kWindowOrigin(40, 40);


enum {
	TEST_NONE,
	TEST_SESSION_PLAIN,
	TEST_SESSION_TEXT_OVER,
	TEST_SESSION_TWO_BITMAPS,
	TEST_SESSION_SOURCE_RECT,
	TEST_SESSION_RGBA,
	TEST_SESSION_ASYNC,
	TEST_SESSION_ASYNC_TEXT_OVER,
};


static BBitmap*
make_bitmap(color_space space, uint32 seed)
{
	BBitmap* bitmap = new BBitmap(BRect(0, 0, kWidth - 1, kHeight - 1), space);
	uint32* bits = (uint32*)bitmap->Bits();
	const int32 stride = bitmap->BytesPerRow() / 4;
	for (int32 y = 0; y < kHeight; y++) {
		for (int32 x = 0; x < kWidth; x++) {
			uint32 r = (x * 255 / kWidth) ^ seed;
			uint32 g = (y * 255 / kHeight) + seed * 7;
			uint32 b = ((x / 16 + y / 16) & 1) ? 0xc0 : 0x30;
			uint32 a = space == B_RGBA32 ? ((x + y) & 0xff) : 0xff;
			bits[y * stride + x] = a << 24 | (r & 0xff) << 16 | (g & 0xff) << 8 | b;
		}
	}
	return bitmap;
}


class CheckView : public BView {
public:
	CheckView(BRect frame, BBitmap* a, BBitmap* b, BBitmap* rgba)
		:
		BView(frame, "check", B_FOLLOW_ALL, B_WILL_DRAW),
		fTest(TEST_NONE),
		fA(a),
		fB(b),
		fRGBA(rgba),
		fDrawn(create_sem(0, "drawn"))
	{
		// the default view color: the background is filled before Draw()
	}

	void SetTest(int test) { fTest = test; }
	sem_id Drawn() const { return fDrawn; }

	virtual void Draw(BRect)
	{
		SetDrawingMode(B_OP_COPY);
		switch (fTest) {
			case TEST_SESSION_PLAIN:
				DrawBitmap(fA, B_ORIGIN);
				break;
			case TEST_SESSION_TEXT_OVER:
				DrawBitmap(fB, B_ORIGIN);
				SetHighColor(255, 255, 0);
				FillRect(BRect(200, 150, 439, 329));
				SetHighColor(0, 0, 0);
				SetLowColor(255, 255, 0);
				DrawString("drawn over the bitmap", BPoint(220, 240));
				break;
			case TEST_SESSION_TWO_BITMAPS:
				DrawBitmap(fA, B_ORIGIN);
				DrawBitmap(fB, BRect(0, 0, kWidth / 2 - 1, kHeight - 1),
					BRect(0, 0, kWidth / 2 - 1, kHeight - 1));
				break;
			case TEST_SESSION_SOURCE_RECT:
				FillRect(Bounds(), B_SOLID_LOW);
				DrawBitmap(fA, BRect(100, 60, 499, 359), BRect(37, 21, 436, 320));
				DrawBitmap(fB, BRect(0, 0, 199, 199), BRect(300, 250, 499, 449));
				break;
			case TEST_SESSION_RGBA:
				DrawBitmap(fRGBA, B_ORIGIN);
				break;
			case TEST_SESSION_ASYNC:
				// as BGLView: the copy may wait for the end of the update
				DrawBitmapAsync(fB, B_ORIGIN);
				break;
			case TEST_SESSION_ASYNC_TEXT_OVER:
				DrawBitmapAsync(fA, B_ORIGIN);
				SetHighColor(0, 0, 0);
				SetLowColor(255, 255, 255);
				DrawString("drawn over a deferred bitmap", BPoint(150, 100));
				DrawBitmapAsync(fRGBA, BRect(0, 0, 99, 99), BRect(500, 350, 599, 449));
				break;
		}
		release_sem(fDrawn);
	}

private:
	int fTest;
	BBitmap* fA;
	BBitmap* fB;
	BBitmap* fRGBA;
	sem_id fDrawn;
};


static uint32
screen_hash(BRect frame)
{
	BScreen screen;
	BBitmap* shot = NULL;
	if (screen.GetBitmap(&shot, false, &frame) != B_OK || shot == NULL)
		return 0;
	// FNV-1a over the pixels' color bytes (the alpha of a screen read back
	// is not part of the picture)
	uint32 hash = 2166136261u;
	const uint8* bits = (const uint8*)shot->Bits();
	const int32 width = shot->Bounds().IntegerWidth() + 1;
	const int32 height = shot->Bounds().IntegerHeight() + 1;
	for (int32 y = 0; y < height; y++) {
		const uint8* row = bits + y * shot->BytesPerRow();
		for (int32 x = 0; x < width * 4; x++) {
			if ((x & 3) == 3)
				continue;
			hash = (hash ^ row[x]) * 16777619u;
		}
	}
	delete shot;
	return hash;
}


/*!	Moves the window right and back: app_server copies its contents from the
	back buffer each time without asking the window to redraw. Returns the
	hash of the picture after the first move.
*/
static uint32
moved_hash(BWindow* window, BRect frame)
{
	window->Lock();
	window->MoveBy(16, 0);
	window->Sync();
	window->Unlock();
	snooze(200000);
	uint32 hash = screen_hash(frame.OffsetByCopy(16, 0));
	window->Lock();
	window->MoveBy(-16, 0);
	window->Sync();
	window->Unlock();
	snooze(200000);
	return hash;
}


static void
run_session(BWindow* window, CheckView* view, int test, const char* name,
	BRect screenFrame)
{
	window->Lock();
	view->SetTest(test);
	view->Invalidate();
	window->Unlock();
	acquire_sem_etc(view->Drawn(), 1, B_RELATIVE_TIMEOUT, 5000000);
	snooze(100000);
	window->Lock();
	view->Sync();
	window->Unlock();
	printf("BMC %s %08" B_PRIx32 "\n", name, screen_hash(screenFrame));
	fflush(stdout);
}


int
main(int argc, char** argv)
{
	const int holdSeconds = argc > 1 ? atoi(argv[1]) : 0;

	BApplication app("application/x-vnd.haiku-pi-bitmapcheck");
	BBitmap* a = make_bitmap(B_RGB32, 0);
	BBitmap* b = make_bitmap(B_RGB32, 0x5a);
	BBitmap* rgba = make_bitmap(B_RGBA32, 0x21);

	BRect frame(0, 0, kWidth - 1, kHeight - 1);
	frame.OffsetTo(kWindowOrigin);
	BWindow* window = new BWindow(frame, "bitmapcheck", B_NO_BORDER_WINDOW_LOOK,
		B_FLOATING_ALL_WINDOW_FEEL, B_NOT_MOVABLE | B_NOT_RESIZABLE | B_AVOID_FOCUS);
	CheckView* view = new CheckView(frame.OffsetToCopy(B_ORIGIN), a, b, rgba);
	window->AddChild(view);
	window->Show();
	snooze(500000);

	// outside an update session: copied to the front buffer at once
	window->Lock();
	view->SetDrawingMode(B_OP_COPY);
	view->DrawBitmap(a, B_ORIGIN);
	view->Sync();
	window->Unlock();
	printf("BMC direct %08" B_PRIx32 "\n", screen_hash(frame));
	printf("BMC moved-after-direct %08" B_PRIx32 "\n", moved_hash(window, frame));

	run_session(window, view, TEST_SESSION_PLAIN, "session", frame);
	run_session(window, view, TEST_SESSION_TEXT_OVER, "text-over", frame);
	run_session(window, view, TEST_SESSION_TWO_BITMAPS, "two-bitmaps", frame);
	run_session(window, view, TEST_SESSION_SOURCE_RECT, "source-rect", frame);
	run_session(window, view, TEST_SESSION_RGBA, "rgba", frame);
	run_session(window, view, TEST_SESSION_ASYNC, "async", frame);
	printf("BMC moved-after-async %08" B_PRIx32 "\n", moved_hash(window, frame));
	run_session(window, view, TEST_SESSION_ASYNC_TEXT_OVER, "async-text-over", frame);

	// a window over part of it: the bitmap is clipped to several rectangles
	BRect coverFrame(0, 0, 199, 149);
	coverFrame.OffsetTo(kWindowOrigin + BPoint(220, 160));
	BWindow* cover = new BWindow(coverFrame, "cover", B_NO_BORDER_WINDOW_LOOK,
		B_FLOATING_ALL_WINDOW_FEEL, B_NOT_MOVABLE | B_NOT_RESIZABLE | B_AVOID_FOCUS);
	BView* coverView = new BView(coverFrame.OffsetToCopy(B_ORIGIN), "cover",
		B_FOLLOW_ALL, B_WILL_DRAW);
	coverView->SetViewColor(40, 90, 200);
	cover->AddChild(coverView);
	cover->Show();
	snooze(300000);
	run_session(window, view, TEST_SESSION_TWO_BITMAPS, "covered", frame);

	window->Lock();
	view->DrawBitmap(b, B_ORIGIN);
	view->Sync();
	window->Unlock();
	printf("BMC covered-direct %08" B_PRIx32 "\n", screen_hash(frame));
	printf("BMC done\n");
	fflush(stdout);

	if (holdSeconds > 0)
		snooze(holdSeconds * 1000000LL);
	return 0;
}
