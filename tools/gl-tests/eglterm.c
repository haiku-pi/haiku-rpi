/*
 * eglterm — eglTerminate() while a context is current, then eglReleaseThread(): the order many
 * programs use at exit (glmark2 did). Mesa's Haiku EGL driver freed the display in eglTerminate() and
 * then used it to release the still-current context: a crash. Prints "EGLTERM ok" when both return.
 *
 *   eglterm
 *
 * Build (cross; EGL/GLES headers from the sysroot, libEGL from libglvnd):
 *   g="sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64"
 *   $g -O2 -I artifacts/sysroot-arm64/boot/system/develop/headers/os/opengl -o eglterm tools/gl-tests/eglterm.c -lEGL
 */
#include <stdio.h>

#include <EGL/egl.h>


int
main(void)
{
	EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL)) {
		printf("EGLTERM no display: 0x%x\n", eglGetError());
		return 1;
	}

	static const EGLint kConfigAttributes[] = {
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE
	};
	EGLConfig config;
	EGLint count = 0;
	if (!eglChooseConfig(display, kConfigAttributes, &config, 1, &count) || count == 0) {
		printf("EGLTERM no config: 0x%x\n", eglGetError());
		return 1;
	}

	static const EGLint kSurfaceAttributes[] = { EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE };
	EGLSurface surface = eglCreatePbufferSurface(display, config, kSurfaceAttributes);
	eglBindAPI(EGL_OPENGL_ES_API);
	static const EGLint kContextAttributes[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, kContextAttributes);
	if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT
		|| !eglMakeCurrent(display, surface, surface, context)) {
		printf("EGLTERM setup failed: 0x%x\n", eglGetError());
		return 1;
	}

	// the order under test: terminate first, with the context current
	eglTerminate(display);
	printf("EGLTERM terminated\n");
	fflush(stdout);
	eglReleaseThread();
	printf("EGLTERM ok\n");
	return 0;
}
