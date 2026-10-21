/* click.c — press a button of a Windows program's dialog, for unattended tests under Wine:
 *   click.exe TITLE BUTTON [SECONDS]
 * waits up to SECONDS (default 120) for a top-level window titled TITLE (a prefix of it), then sends BM_CLICK to
 * its child button whose text is BUTTON ('&' accelerators ignored). Exit code 0 when pressed, 1 otherwise. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *title, *button;
static HWND found_window, found_button;

static void strip_amp(const char *in, char *out, size_t size)
{
	size_t n = 0;
	for (; *in && n + 1 < size; in++)
		if (*in != '&')
			out[n++] = *in;
	out[n] = 0;
}

static BOOL CALLBACK find_button(HWND hwnd, LPARAM lp)
{
	char text[256], plain[256];
	(void)lp;
	GetWindowTextA(hwnd, text, sizeof(text));
	strip_amp(text, plain, sizeof(plain));
	if (_stricmp(plain, button) == 0) {
		found_button = hwnd;
		return FALSE;
	}
	return TRUE;
}

static BOOL CALLBACK find_window(HWND hwnd, LPARAM lp)
{
	char text[256];
	(void)lp;
	GetWindowTextA(hwnd, text, sizeof(text));
	if (IsWindowVisible(hwnd) && _strnicmp(text, title, strlen(title)) == 0) {
		found_window = hwnd;
		return FALSE;
	}
	return TRUE;
}

int main(int argc, char **argv)
{
	int secs = argc > 3 ? atoi(argv[3]) : 120;
	if (argc < 3) {
		printf("usage: click.exe TITLE BUTTON [SECONDS]\n");
		return 2;
	}
	title = argv[1];
	button = argv[2];
	for (int i = 0; i < secs * 4; i++) {
		found_window = found_button = NULL;
		EnumWindows(find_window, 0);
		if (found_window)
			EnumChildWindows(found_window, find_button, 0);
		if (found_button) {
			SendMessageA(found_button, BM_CLICK, 0, 0);
			printf("click: pressed \"%s\" in \"%s\" after %d ms\n", button, title, i * 250);
			return 0;
		}
		Sleep(250);
	}
	printf("click: no \"%s\" in a window \"%s\" within %d s\n", button, title, secs);
	return 1;
}
