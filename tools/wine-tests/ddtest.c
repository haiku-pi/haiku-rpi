/* ddtest.c — a known DirectDraw picture, to check Wine's 2D path (wined3d's GDI renderer) against a screenshot.
 * Sets a full-screen mode (default 640x480x16, or argv: width height bpp), locks the primary surface and fills it
 * with eight vertical colour bars (white, yellow, cyan, green, magenta, red, blue, black) over the top half and a
 * horizontal grey ramp under it, in the surface's own pixel format; prints the format and keeps the picture for
 * argv[4] seconds (default 30). Built for arm64 and for x86 (WoW64 under the emulator) by scripts/build-wine.sh. */
#include <windows.h>
#include <ddraw.h>
#include <stdio.h>
#include <stdlib.h>

static DWORD pack(const DDPIXELFORMAT *pf, unsigned r, unsigned g, unsigned b)
{
	DWORD masks[3] = { pf->dwRBitMask, pf->dwGBitMask, pf->dwBBitMask };
	unsigned v[3] = { r, g, b };
	DWORD out = 0;
	for (int i = 0; i < 3; i++) {
		DWORD m = masks[i];
		int shift = 0, bits = 0;
		while (m && !(m & 1)) { m >>= 1; shift++; }
		while (m & 1) { m >>= 1; bits++; }
		out |= (DWORD)(v[i] >> (8 - bits)) << shift;
	}
	return out;
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
	return DefWindowProcA(hwnd, msg, wp, lp);
}

int main(int argc, char **argv)
{
	int width = argc > 3 ? atoi(argv[1]) : 640, height = argc > 3 ? atoi(argv[2]) : 480;
	int bpp = argc > 3 ? atoi(argv[3]) : 16, secs = argc > 4 ? atoi(argv[4]) : 30;
	static const unsigned bars[8][3] = { {255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
		{255, 0, 255}, {255, 0, 0}, {0, 0, 255}, {0, 0, 0} };
	WNDCLASSA wc = { 0 };
	IDirectDraw7 *dd;
	IDirectDrawSurface7 *primary;
	DDSURFACEDESC2 sd;
	HRESULT hr;
	HWND hwnd;

	wc.lpfnWndProc = wndproc;
	wc.hInstance = GetModuleHandleA(NULL);
	wc.lpszClassName = "ddtest";
	RegisterClassA(&wc);
	hwnd = CreateWindowExA(WS_EX_TOPMOST, "ddtest", "ddtest", WS_POPUP | WS_VISIBLE, 0, 0, width, height,
		NULL, NULL, wc.hInstance, NULL);

	if (FAILED(hr = DirectDrawCreateEx(NULL, (void **)&dd, &IID_IDirectDraw7, NULL))) {
		printf("ddtest: DirectDrawCreateEx %#lx\n", hr);
		return 1;
	}
	if (FAILED(hr = IDirectDraw7_SetCooperativeLevel(dd, hwnd, DDSCL_EXCLUSIVE | DDSCL_FULLSCREEN))) {
		printf("ddtest: SetCooperativeLevel %#lx\n", hr);
		return 1;
	}
	if (FAILED(hr = IDirectDraw7_SetDisplayMode(dd, width, height, bpp, 0, 0))) {
		printf("ddtest: SetDisplayMode %dx%dx%d %#lx\n", width, height, bpp, hr);
		return 1;
	}
	memset(&sd, 0, sizeof(sd));
	sd.dwSize = sizeof(sd);
	sd.dwFlags = DDSD_CAPS;
	sd.ddsCaps.dwCaps = DDSCAPS_PRIMARYSURFACE;
	if (FAILED(hr = IDirectDraw7_CreateSurface(dd, &sd, &primary, NULL))) {
		printf("ddtest: CreateSurface %#lx\n", hr);
		return 1;
	}
	memset(&sd, 0, sizeof(sd));
	sd.dwSize = sizeof(sd);
	if (FAILED(hr = IDirectDrawSurface7_Lock(primary, NULL, &sd, DDLOCK_WAIT | DDLOCK_WRITEONLY, NULL))) {
		printf("ddtest: Lock %#lx\n", hr);
		return 1;
	}
	printf("ddtest: %lux%lu, %lu bpp, pitch %ld, masks r %#lx g %#lx b %#lx\n", sd.dwWidth, sd.dwHeight,
		sd.ddpfPixelFormat.dwRGBBitCount, sd.lPitch, sd.ddpfPixelFormat.dwRBitMask,
		sd.ddpfPixelFormat.dwGBitMask, sd.ddpfPixelFormat.dwBBitMask);
	fflush(stdout);
	for (DWORD y = 0; y < sd.dwHeight; y++) {
		BYTE *row = (BYTE *)sd.lpSurface + y * sd.lPitch;
		for (DWORD x = 0; x < sd.dwWidth; x++) {
			DWORD c;
			if (y < sd.dwHeight / 2) {
				const unsigned *bar = bars[x * 8 / sd.dwWidth];
				c = pack(&sd.ddpfPixelFormat, bar[0], bar[1], bar[2]);
			} else {
				unsigned grey = x * 255 / (sd.dwWidth - 1);
				c = pack(&sd.ddpfPixelFormat, grey, grey, grey);
			}
			switch (sd.ddpfPixelFormat.dwRGBBitCount) {
			case 16: ((WORD *)row)[x] = (WORD)c; break;
			case 32: ((DWORD *)row)[x] = c; break;
			case 24: row[x * 3] = c; row[x * 3 + 1] = c >> 8; row[x * 3 + 2] = c >> 16; break;
			}
		}
	}
	IDirectDrawSurface7_Unlock(primary, NULL);
	for (int i = 0; i < secs * 10; i++) {
		MSG msg;
		while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE))
			DispatchMessageA(&msg);
		Sleep(100);
	}
	IDirectDraw7_RestoreDisplayMode(dd);
	printf("ddtest: done\n");
	return 0;
}
