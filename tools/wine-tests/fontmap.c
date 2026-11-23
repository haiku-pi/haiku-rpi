/* fontmap.c — which installed face Wine gives a program for common Windows font names (KNOWN-ISSUES W16: with
   Haiku's fonts loaded, a face that is not installed must still resolve by class, not to the first family in name
   order). One line per request: "FM <name> pitch=<lfPitchAndFamily> -> <face GetTextFace returned>".
   Built with llvm-mingw: aarch64-w64-mingw32-gcc -O2 -o fontmap.exe fontmap.c -lgdi32 */
#include <stdio.h>
#include <windows.h>

int main(void)
{
	static const struct { const char *name; BYTE pitch; } req[] = {
		{"Arial", 0}, {"Arial", VARIABLE_PITCH | FF_SWISS}, {"Segoe UI", 0}, {"Verdana", VARIABLE_PITCH | FF_SWISS},
		{"Times New Roman", 0}, {"Times New Roman", VARIABLE_PITCH | FF_ROMAN},
		{"Courier New", 0}, {"Courier New", FIXED_PITCH | FF_MODERN}, {"Consolas", FIXED_PITCH | FF_MODERN},
		{"MS Shell Dlg", 0}, {"Tahoma", 0}, {"", 0},
	};
	HDC dc = CreateCompatibleDC(NULL);
	for (unsigned i = 0; i < sizeof(req) / sizeof(req[0]); i++) {
		LOGFONTA lf = {0};
		char face[LF_FACESIZE] = "";
		lf.lfHeight = -16;
		lf.lfCharSet = DEFAULT_CHARSET;
		lf.lfPitchAndFamily = req[i].pitch;
		lstrcpynA(lf.lfFaceName, req[i].name, LF_FACESIZE);
		HFONT f = CreateFontIndirectA(&lf), old = SelectObject(dc, f);
		GetTextFaceA(dc, sizeof(face), face);
		printf("FM %s pitch=0x%02x -> %s\n", req[i].name[0] ? req[i].name : "(none)", req[i].pitch, face);
		SelectObject(dc, old);
		DeleteObject(f);
	}
	DeleteDC(dc);
	return 0;
}
