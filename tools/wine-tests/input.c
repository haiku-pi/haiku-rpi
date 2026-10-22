/* input.c — play mouse and keyboard input into a Windows program under Wine, for unattended tests:
 *   input.exe STEP...
 * steps, in order:
 *   wait:MS          sleep MS milliseconds
 *   window:TITLE     use the top-level window whose title starts with TITLE (waits up to 120 s for it); the
 *                    default is the foreground window
 *   focus:TITLE      the same, and make it the foreground window (keyboard input goes there)
 *   click:X,Y        left click at X,Y of the window's client area
 *   move:X,Y         move the mouse there
 *   key:VK           press and release a virtual key (decimal or 0x hex: 0x0d Return, 0x1b Escape, 0x20 Space)
 *   hold:VK,MS       press a virtual key, keep it down MS milliseconds, release it (walking in a game: 0x26 Up)
 *   text:STRING      type STRING
 * The input goes in by SendInput, as from the hardware: DirectInput sees it too. Each step is printed, with the
 * foreground window's title. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HWND target;
static const char *want_title;

static BOOL CALLBACK find_window(HWND hwnd, LPARAM lp)
{
	char text[256];
	(void)lp;
	GetWindowTextA(hwnd, text, sizeof(text));
	if (IsWindowVisible(hwnd) && _strnicmp(text, want_title, strlen(want_title)) == 0) {
		target = hwnd;
		return FALSE;
	}
	return TRUE;
}

static void send_mouse(DWORD flags, int x, int y)
{
	INPUT in = { 0 };
	in.type = INPUT_MOUSE;
	/* absolute coordinates are 0..65535 over the primary screen */
	in.mi.dx = MulDiv(x, 65535, GetSystemMetrics(SM_CXSCREEN) - 1);
	in.mi.dy = MulDiv(y, 65535, GetSystemMetrics(SM_CYSCREEN) - 1);
	in.mi.dwFlags = flags | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE;
	SendInput(1, &in, sizeof(in));
}

static void send_key(WORD vk, BOOL up)
{
	INPUT in = { 0 };
	in.type = INPUT_KEYBOARD;
	in.ki.wVk = vk;
	in.ki.wScan = (WORD)MapVirtualKeyA(vk, MAPVK_VK_TO_VSC);
	in.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
	SendInput(1, &in, sizeof(in));
}

static POINT to_screen(int x, int y)
{
	POINT p = { x, y };
	HWND hwnd = target ? target : GetForegroundWindow();
	if (hwnd)
		ClientToScreen(hwnd, &p);
	return p;
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i], *v = strchr(a, ':');
		int x, y;
		if (!v) {
			printf("input: bad step \"%s\"\n", a);
			return 2;
		}
		v++;
		if (strncmp(a, "wait:", 5) == 0) {
			Sleep(atoi(v));
		} else if (strncmp(a, "window:", 7) == 0 || strncmp(a, "focus:", 6) == 0) {
			want_title = v;
			target = NULL;
			for (int t = 0; t < 480 && !target; t++) {
				EnumWindows(find_window, 0);
				if (!target)
					Sleep(250);
			}
			if (!target) {
				printf("input: no window \"%s\"\n", v);
				return 1;
			}
			if (a[0] == 'f')
				SetForegroundWindow(target);
		} else if (strncmp(a, "click:", 6) == 0 && sscanf(v, "%d,%d", &x, &y) == 2) {
			POINT p = to_screen(x, y);
			send_mouse(0, p.x, p.y);
			Sleep(50);
			send_mouse(MOUSEEVENTF_LEFTDOWN, p.x, p.y);
			Sleep(80);
			send_mouse(MOUSEEVENTF_LEFTUP, p.x, p.y);
		} else if (strncmp(a, "move:", 5) == 0 && sscanf(v, "%d,%d", &x, &y) == 2) {
			POINT p = to_screen(x, y);
			send_mouse(0, p.x, p.y);
		} else if (strncmp(a, "key:", 4) == 0) {
			WORD vk = (WORD)strtol(v, NULL, 0);
			send_key(vk, FALSE);
			Sleep(60);
			send_key(vk, TRUE);
		} else if (strncmp(a, "hold:", 5) == 0) {
			char *ms;
			WORD vk = (WORD)strtol(v, &ms, 0);
			send_key(vk, FALSE);
			Sleep(*ms == ',' ? atoi(ms + 1) : 500);
			send_key(vk, TRUE);
		} else if (strncmp(a, "text:", 5) == 0) {
			for (const char *c = v; *c; c++) {
				SHORT s = VkKeyScanA(*c);
				if (s & 0x100)
					send_key(VK_SHIFT, FALSE);
				send_key(LOBYTE(s), FALSE);
				send_key(LOBYTE(s), TRUE);
				if (s & 0x100)
					send_key(VK_SHIFT, TRUE);
				Sleep(40);
			}
		} else {
			printf("input: bad step \"%s\"\n", a);
			return 2;
		}
		{
			char fg[128] = "";
			GetWindowTextA(GetForegroundWindow(), fg, sizeof(fg));
			printf("input: %s (foreground \"%s\")\n", a, fg);
		}
		fflush(stdout);
	}
	return 0;
}
