/* d3dtest.c — a Direct3D 9 smoke test for wined3d's OpenGL renderer: a 640x480 window (or full screen) cleared
 * to blue with a rotating triangle (red, green and blue corners, Gouraud-shaded) drawn from a vertex buffer, for
 * SECONDS seconds; prints the adapter, the frames per second, and then reads the back buffer back: the centre
 * pixel must be the triangle's (not the clear colour) and a corner the clear colour.
 *
 *   d3dtest.exe [SECONDS [fullscreen]]      (default 15 s, windowed)
 *
 * Prints "D3DTEST: right" or "D3DTEST: WRONG ..." last. */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct vertex { float x, y, z, rhw; DWORD color; };
#define FVF (D3DFVF_XYZRHW | D3DFVF_DIFFUSE)
#define WIDTH 640
#define HEIGHT 480
#define CLEAR 0xff2040c0

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
	if (msg == WM_DESTROY) PostQuitMessage(0);
	return DefWindowProcA(hwnd, msg, wp, lp);
}

static void triangle(struct vertex *v, float angle)
{
	static const DWORD colors[3] = { 0xffff0000, 0xff00ff00, 0xff0000ff };
	int i;
	for (i = 0; i < 3; i++) {
		float a = angle + i * 2.0943951f;
		v[i].x = WIDTH / 2 + 200 * sinf(a);
		v[i].y = HEIGHT / 2 - 200 * cosf(a);
		v[i].z = 0.5f;
		v[i].rhw = 1.0f;
		v[i].color = colors[i];
	}
}

/* the pixel at x,y of the back buffer, as 0xRRGGBB */
static DWORD read_pixel(IDirect3DDevice9 *device, IDirect3DSurface9 *copy, int x, int y)
{
	IDirect3DSurface9 *back;
	D3DLOCKED_RECT locked;
	DWORD pixel = 0xdeadbeef;

	if (FAILED(IDirect3DDevice9_GetBackBuffer(device, 0, 0, D3DBACKBUFFER_TYPE_MONO, &back))) return pixel;
	if (SUCCEEDED(IDirect3DDevice9_GetRenderTargetData(device, back, copy))
		&& SUCCEEDED(IDirect3DSurface9_LockRect(copy, &locked, NULL, D3DLOCK_READONLY))) {
		pixel = ((DWORD *)((BYTE *)locked.pBits + y * locked.Pitch))[x] & 0xffffff;
		IDirect3DSurface9_UnlockRect(copy);
	}
	IDirect3DSurface9_Release(back);
	return pixel;
}

int main(int argc, char **argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 15;
	BOOL fullscreen = argc > 2 && !strcmp(argv[2], "fullscreen");
	WNDCLASSA wc = { 0 };
	D3DPRESENT_PARAMETERS pp = { 0 };
	D3DADAPTER_IDENTIFIER9 id;
	IDirect3D9 *d3d;
	IDirect3DDevice9 *device;
	IDirect3DVertexBuffer9 *vb;
	IDirect3DSurface9 *copy;
	DWORD start, last, now, centre, corner;
	int frames = 0, total = 0;
	HRESULT hr;
	HWND hwnd;
	MSG msg;

	wc.lpfnWndProc = window_proc;
	wc.hInstance = GetModuleHandleA(NULL);
	wc.lpszClassName = "d3dtest";
	RegisterClassA(&wc);
	hwnd = CreateWindowA("d3dtest", "d3dtest", fullscreen ? WS_POPUP : WS_OVERLAPPEDWINDOW, 0, 0,
		WIDTH, HEIGHT, NULL, NULL, wc.hInstance, NULL);
	if (!fullscreen) {
		RECT r = { 0, 0, WIDTH, HEIGHT };
		AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
		SetWindowPos(hwnd, NULL, 100, 100, r.right - r.left, r.bottom - r.top, SWP_NOZORDER);
	}
	ShowWindow(hwnd, SW_SHOW);

	if (!(d3d = Direct3DCreate9(D3D_SDK_VERSION))) {
		printf("D3DTEST: WRONG (no Direct3D 9)\n");
		return 1;
	}
	if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id)))
		printf("d3dtest: adapter \"%s\", driver %s\n", id.Description, id.Driver);
	pp.Windowed = !fullscreen;
	pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
	pp.BackBufferWidth = WIDTH;
	pp.BackBufferHeight = HEIGHT;
	pp.BackBufferFormat = D3DFMT_X8R8G8B8;
	pp.BackBufferCount = 1;
	pp.hDeviceWindow = hwnd;
	pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
	hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
		D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &device);
	if (FAILED(hr)) {
		printf("D3DTEST: WRONG (CreateDevice %#lx)\n", hr);
		return 1;
	}
	IDirect3DDevice9_CreateVertexBuffer(device, 3 * sizeof(struct vertex), D3DUSAGE_WRITEONLY | D3DUSAGE_DYNAMIC,
		FVF, D3DPOOL_DEFAULT, &vb, NULL);
	IDirect3DDevice9_CreateOffscreenPlainSurface(device, WIDTH, HEIGHT, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &copy,
		NULL);
	IDirect3DDevice9_SetRenderState(device, D3DRS_LIGHTING, FALSE);
	IDirect3DDevice9_SetRenderState(device, D3DRS_CULLMODE, D3DCULL_NONE);

	start = last = GetTickCount();
	for (;;) {
		struct vertex *v;
		while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
			TranslateMessage(&msg);
			DispatchMessageA(&msg);
		}
		now = GetTickCount();
		if (now - start >= (DWORD)seconds * 1000) break;
		if (SUCCEEDED(IDirect3DVertexBuffer9_Lock(vb, 0, 0, (void **)&v, D3DLOCK_DISCARD))) {
			triangle(v, (now - start) / 1000.0f);
			IDirect3DVertexBuffer9_Unlock(vb);
		}
		IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, CLEAR, 1.0f, 0);
		IDirect3DDevice9_BeginScene(device);
		IDirect3DDevice9_SetStreamSource(device, 0, vb, 0, sizeof(struct vertex));
		IDirect3DDevice9_SetFVF(device, FVF);
		IDirect3DDevice9_DrawPrimitive(device, D3DPT_TRIANGLELIST, 0, 1);
		IDirect3DDevice9_EndScene(device);
		IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
		frames++;
		total++;
		if (now - last >= 1000) {
			printf("d3dtest: %d fps\n", frames * 1000 / (int)(now - last));
			fflush(stdout);
			frames = 0;
			last = now;
		}
	}
	printf("d3dtest: %d frames in %d s, %.1f fps\n", total, seconds, total * 1000.0 / (now - start));

	/* one more frame, read back before it is presented */
	IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, CLEAR, 1.0f, 0);
	IDirect3DDevice9_BeginScene(device);
	IDirect3DDevice9_SetStreamSource(device, 0, vb, 0, sizeof(struct vertex));
	IDirect3DDevice9_SetFVF(device, FVF);
	IDirect3DDevice9_DrawPrimitive(device, D3DPT_TRIANGLELIST, 0, 1);
	IDirect3DDevice9_EndScene(device);
	centre = read_pixel(device, copy, WIDTH / 2, HEIGHT / 2);
	corner = read_pixel(device, copy, 4, 4);
	printf("d3dtest: centre %06lx, corner %06lx\n", centre, corner);
	if (corner == (CLEAR & 0xffffff) && centre != (CLEAR & 0xffffff) && centre != 0xdeadbeef)
		printf("D3DTEST: right\n");
	else
		printf("D3DTEST: WRONG (centre %06lx, corner %06lx, clear %06x)\n", centre, corner, CLEAR & 0xffffff);

	IDirect3DSurface9_Release(copy);
	IDirect3DVertexBuffer9_Release(vb);
	IDirect3DDevice9_Release(device);
	IDirect3D9_Release(d3d);
	DestroyWindow(hwnd);
	return 0;
}
