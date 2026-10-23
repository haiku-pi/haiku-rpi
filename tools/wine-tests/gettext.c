/* gettext.c — the text of the edit controls (Edit, Scintilla, RichEdit) of a top-level window whose title contains
 * TITLE-PART, by WM_GETTEXT, for unattended input tests (what a program received, as text):
 *   gettext.exe TITLE-PART
 * prints "gettext: CLASS \"TEXT\"" per control; exit 1 when no such window. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static const char *want;
static HWND found;

static BOOL CALLBACK find_top(HWND hwnd, LPARAM lp)
{
	char title[256];
	(void)lp;
	GetWindowTextA(hwnd, title, sizeof(title));
	if (IsWindowVisible(hwnd) && strstr(title, want)) {
		found = hwnd;
		return FALSE;
	}
	return TRUE;
}

static BOOL CALLBACK print_edit(HWND hwnd, LPARAM lp)
{
	static char text[65536];
	char cls[64];
	DWORD_PTR len = 0;
	(void)lp;
	GetClassNameA(hwnd, cls, sizeof(cls));
	if (_strnicmp(cls, "Edit", 4) && _strnicmp(cls, "Scintilla", 9) && _strnicmp(cls, "RichEdit", 8))
		return TRUE;
	text[0] = 0;
	SendMessageTimeoutA(hwnd, WM_GETTEXT, sizeof(text), (LPARAM)text, SMTO_ABORTIFHUNG, 5000, &len);
	printf("gettext: %s \"%s\"\n", cls, text);
	return TRUE;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: gettext.exe TITLE-PART\n");
		return 2;
	}
	want = argv[1];
	EnumWindows(find_top, 0);
	if (!found) {
		printf("gettext: no window \"%s\"\n", want);
		return 1;
	}
	EnumChildWindows(found, print_edit, 0);
	return 0;
}
