/* winlist.c — the windows of the running Windows programs (one Wine prefix), for debugging what is on screen:
 * every top-level window in z-order (topmost first) with its children, as
 *   winlist: HWND pid/tid class "title" (x,y)-(x,y) visible|hidden [minimized] [style ...]
 *   winlist.exe [-a]      (-a: hidden windows too)
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static int all;

static void print_window(HWND hwnd, int depth)
{
	char cls[128] = "", title[128] = "";
	DWORD pid = 0, tid = GetWindowThreadProcessId(hwnd, &pid);
	LONG style = GetWindowLongA(hwnd, GWL_STYLE), exstyle = GetWindowLongA(hwnd, GWL_EXSTYLE);
	RECT r;

	if (!all && !IsWindowVisible(hwnd))
		return;
	GetClassNameA(hwnd, cls, sizeof(cls));
	GetWindowTextA(hwnd, title, sizeof(title));
	GetWindowRect(hwnd, &r);
	printf("winlist: %*s%p %04lx/%04lx %s \"%s\" (%ld,%ld)-(%ld,%ld) %s%s style %#lx exstyle %#lx\n", depth * 2, "",
		(void *)hwnd, pid, tid, cls, title, r.left, r.top, r.right, r.bottom,
		IsWindowVisible(hwnd) ? "visible" : "hidden", IsIconic(hwnd) ? " minimized" : "", style, exstyle);
}

static BOOL CALLBACK child(HWND hwnd, LPARAM depth)
{
	if (GetParent(hwnd) == GetAncestor(hwnd, GA_PARENT))
		print_window(hwnd, (int)depth);
	return TRUE;
}

int main(int argc, char **argv)
{
	all = argc > 1 && !strcmp(argv[1], "-a");
	for (HWND hwnd = GetTopWindow(NULL); hwnd; hwnd = GetWindow(hwnd, GW_HWNDNEXT)) {
		print_window(hwnd, 0);
		if (all || IsWindowVisible(hwnd))
			EnumChildWindows(hwnd, child, 1);
	}
	printf("winlist: foreground %p\n", (void *)GetForegroundWindow());
	return 0;
}
