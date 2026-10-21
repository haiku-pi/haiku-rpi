/* gltest.c — OpenGL through Wine (opengl32 → win32u's EGL driver → Mesa on the V3D): a window with a GL context,
 * a colour cleared and read back, then a spinning triangle for SECONDS (default 20) with the frame rate printed.
 *   gltest.exe [SECONDS]
 * Prints "GLTEST" lines: the GL_VENDOR/RENDERER/VERSION strings, the read-back check, frames per second, OK/FAIL. */
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
	return DefWindowProcA(hwnd, msg, wp, lp);
}

int main(int argc, char **argv)
{
	int secs = argc > 1 ? atoi(argv[1]) : 20;
	PIXELFORMATDESCRIPTOR pfd = { sizeof(pfd), 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
		PFD_TYPE_RGBA, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 24, 8, 0, PFD_MAIN_PLANE, 0, 0, 0, 0 };
	WNDCLASSA wc = { 0 };
	unsigned char px[4] = { 0 };
	HGLRC ctx;
	HWND hwnd;
	HDC dc;
	int fmt, frames = 0, ok;
	DWORD start;

	wc.lpfnWndProc = wndproc;
	wc.hInstance = GetModuleHandleA(NULL);
	wc.lpszClassName = "gltest";
	RegisterClassA(&wc);
	hwnd = CreateWindowExA(0, "gltest", "gltest", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 480,
		NULL, NULL, wc.hInstance, NULL);
	dc = GetDC(hwnd);
	if (!(fmt = ChoosePixelFormat(dc, &pfd)) || !SetPixelFormat(dc, fmt, &pfd)) {
		printf("GLTEST FAIL pixel format %d (error %lu)\n", fmt, GetLastError());
		return 1;
	}
	if (!(ctx = wglCreateContext(dc)) || !wglMakeCurrent(dc, ctx)) {
		printf("GLTEST FAIL context (error %lu)\n", GetLastError());
		return 1;
	}
	printf("GLTEST vendor \"%s\"\nGLTEST renderer \"%s\"\nGLTEST version \"%s\"\n", glGetString(GL_VENDOR),
		glGetString(GL_RENDERER), glGetString(GL_VERSION));
	fflush(stdout);

	glViewport(0, 0, 640, 480);
	glClearColor(0.0f, 0.5f, 1.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glFinish();
	glReadPixels(320, 240, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	ok = px[0] < 8 && px[1] > 120 && px[1] < 136 && px[2] > 247;
	printf("GLTEST readback %u %u %u %s\n", px[0], px[1], px[2], ok ? "ok" : "WRONG");
	fflush(stdout);

	start = GetTickCount();
	while (GetTickCount() - start < (DWORD)secs * 1000) {
		MSG msg;
		while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE))
			DispatchMessageA(&msg);
		glClearColor(0.1f, 0.1f, 0.2f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		glLoadIdentity();
		glRotatef(frames * 2.0f, 0.0f, 0.0f, 1.0f);
		glBegin(GL_TRIANGLES);
		glColor3f(1.0f, 0.0f, 0.0f); glVertex2f(0.0f, 0.8f);
		glColor3f(0.0f, 1.0f, 0.0f); glVertex2f(-0.7f, -0.6f);
		glColor3f(0.0f, 0.0f, 1.0f); glVertex2f(0.7f, -0.6f);
		glEnd();
		SwapBuffers(dc);
		frames++;
	}
	printf("GLTEST %d frames in %d s: %.1f fps\nGLTEST %s\n", frames, secs, frames / (double)secs, ok ? "OK" : "FAIL");
	wglMakeCurrent(NULL, NULL);
	wglDeleteContext(ctx);
	return ok ? 0 : 1;
}
