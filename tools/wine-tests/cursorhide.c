/* cursorhide.c — a window that hides the cursor the Windows way, for KNOWN-ISSUES W14 (the system cursor stayed
   over games that draw their own): ShowCursor(FALSE) at the start and SetCursor(NULL) on WM_SETCURSOR, as games do.
     cursorhide MODE SECS
     MODE: show   a 640x480 window at 100,100 with the normal arrow (the control)
           hide   the same window, cursor hidden over its client area
           full   a WS_POPUP of the screen's size (a full-screen game), cursor hidden
   Prints "CH t=N visible=V" (GetCursorInfo) once a second. The window is a flat colour, so an HDMI frame shows
   whether a cursor is drawn over it. Built with llvm-mingw: aarch64-w64-mingw32-gcc -O2 -o cursorhide.exe
   cursorhide.c -luser32 -lgdi32 (i686-w64-mingw32-gcc for 32-bit x86) */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int hide;

static LRESULT CALLBACK proc(HWND w, UINT m, WPARAM wp, LPARAM lp)
{
	if (m == WM_SETCURSOR && LOWORD(lp) == HTCLIENT && hide) { SetCursor(NULL); return TRUE; }
	if (m == WM_PAINT) {
		PAINTSTRUCT ps; HDC dc = BeginPaint(w, &ps); RECT r; GetClientRect(w, &r);
		HBRUSH b = CreateSolidBrush(hide ? RGB(0, 96, 160) : RGB(160, 96, 0));
		FillRect(dc, &r, b); DeleteObject(b); EndPaint(w, &ps); return 0;
	}
	if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
	return DefWindowProcA(w, m, wp, lp);
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "hide";
	int secs = argc > 2 ? atoi(argv[2]) : 30, full = !strcmp(mode, "full");
	hide = strcmp(mode, "show") != 0;
	WNDCLASSA c = {0};
	c.lpfnWndProc = proc; c.hInstance = GetModuleHandleA(NULL); c.lpszClassName = "cursorhide";
	c.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
	RegisterClassA(&c);
	int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
	HWND w = full ? CreateWindowExA(WS_EX_TOPMOST, "cursorhide", "cursorhide", WS_POPUP | WS_VISIBLE, 0, 0, sw, sh, 0, 0, c.hInstance, 0)
		: CreateWindowA("cursorhide", "cursorhide", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 480, 0, 0, c.hInstance, 0);
	if (hide) printf("CH ShowCursor(FALSE) -> %d\n", ShowCursor(FALSE));
	printf("CH mode=%s screen=%dx%d hwnd=%p\n", mode, sw, sh, (void *)w); fflush(stdout);
	SetTimer(w, 1, 1000, NULL);
	MSG msg; int t = 0;
	while (GetMessageA(&msg, 0, 0, 0) > 0) {
		if (msg.message == WM_TIMER) {
			CURSORINFO ci = {sizeof(ci)}; GetCursorInfo(&ci);
			printf("CH t=%d visible=%d cursor=%p\n", ++t, !!(ci.flags & CURSOR_SHOWING), (void *)ci.hCursor); fflush(stdout);
			if (t >= secs) DestroyWindow(w);
		}
		TranslateMessage(&msg); DispatchMessageA(&msg);
	}
	printf("CH end\n");
	return 0;
}
