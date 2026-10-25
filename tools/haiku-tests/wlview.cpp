/*
 * wlview.cpp — the server half of Vulkan presenting on Haiku's in-process Wayland server, without a GPU:
 * an xdg_toplevel whose content is drawn into its BView by the client itself, as Mesa's Haiku WSI does for
 * a wgpu/Vulkan window (patched wgpu-hal: wl_ips_haiku_surface_view, then a wl_surface.commit per frame;
 * docs/design/photocraft.md, P3). Checks wayland_server >= 0.1.20251004-8:
 *   - wl_ips_haiku_surface_view(id) returns the toplevel's view (attached to a window), whose window can
 *     be locked by another thread from then on (it runs, still hidden);
 *   - without any buffer, a commit with a window geometry sizes the view and the window to it and shows the
 *     window; a later geometry resizes both;
 *   - the frame callbacks of buffer-less commits are called.
 * Each "frame" fills the view (window locked, as the WSI's presenter) with a colour, so a screenshot shows
 * the window: red at 640x400, then green at 800x500.
 *
 *   wlview [SECONDS]      (how long the window stays at the end, default 5)
 *
 * Output: "WLV <check>: ok|BAD ..." lines and "WLV result: N bad".
 *
 * Build (cross; the xdg-shell code from the host's wayland-scanner):
 *   s=artifacts/sysroot-arm64 g=sources/haiku/generated.arm64 x=$s/boot/system/data/wayland-protocols
 *   artifacts/wayland-host/bin/wayland-scanner client-header $x/stable/xdg-shell/xdg-shell.xml /tmp/xdg-shell.h
 *   artifacts/wayland-host/bin/wayland-scanner private-code $x/stable/xdg-shell/xdg-shell.xml /tmp/xdg-shell.c
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=$s -O2 -c -o /tmp/xdg-shell.o /tmp/xdg-shell.c
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=$s -O2 -I/tmp -o wlview \
 *     tools/haiku-tests/wlview.cpp /tmp/xdg-shell.o -lwayland-client -lbe
 */
#include <View.h>
#include <Window.h>

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <wayland-client.h>
#include "xdg-shell.h"

static int sBad;
static wl_compositor* sCompositor;
static xdg_wm_base* sWmBase;
static bool sConfigured;
static int sFramesDone;

static void
check(const char* what, bool ok, const char* detail = "")
{
	printf("WLV %s: %s %s\n", what, ok ? "ok" : "BAD", detail);
	fflush(stdout);
	if (!ok)
		sBad++;
}

static void
global(void*, wl_registry* registry, uint32_t name, const char* interface, uint32_t)
{
	if (strcmp(interface, wl_compositor_interface.name) == 0)
		sCompositor = (wl_compositor*)wl_registry_bind(registry, name, &wl_compositor_interface, 4);
	else if (strcmp(interface, xdg_wm_base_interface.name) == 0)
		sWmBase = (xdg_wm_base*)wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
}

static void global_remove(void*, wl_registry*, uint32_t) {}
static const wl_registry_listener kRegistry = {global, global_remove};

static void ping(void*, xdg_wm_base* base, uint32_t serial) { xdg_wm_base_pong(base, serial); }
static const xdg_wm_base_listener kWmBase = {ping};

static void
surface_configure(void*, xdg_surface* surface, uint32_t serial)
{
	xdg_surface_ack_configure(surface, serial);
	sConfigured = true;
}
static const xdg_surface_listener kXdgSurface = {surface_configure};

static void toplevel_configure(void*, xdg_toplevel*, int32_t, int32_t, wl_array*) {}
static void toplevel_close(void*, xdg_toplevel*) {}
static const xdg_toplevel_listener kToplevel = {toplevel_configure, toplevel_close};

static void
frame_done(void*, wl_callback* callback, uint32_t)
{
	wl_callback_destroy(callback);
	sFramesDone++;
}
static const wl_callback_listener kFrame = {frame_done};

// what Mesa's presenter does with a frame: the view's window locked, the view filled
static void
present(BView* view, rgb_color color)
{
	if (view->LockLooperWithTimeout(100000) != B_OK)
		return;
	view->SetHighColor(color);
	view->FillRect(view->Bounds());
	view->Sync();
	view->UnlockLooper();
}

// the view's and its window's state, the window locked (as the WSI, with a timeout: false if the window
// stays locked)
static bool
state(BView* view, BRect& bounds, BRect& frame, bool& hidden)
{
	if (view->LockLooperWithTimeout(1000000) != B_OK)
		return false;
	bounds = view->Bounds();
	frame = view->Window()->Bounds();
	hidden = view->Window()->IsHidden();
	view->UnlockLooper();
	return true;
}

// a frame as wgpu-hal sends it: a frame callback, the geometry (winit, on a resize), the present, a commit
static void
frame(wl_display* display, wl_surface* surface, xdg_surface* xdgSurface, BView* view, int width,
	int height, rgb_color color)
{
	wl_callback_add_listener(wl_surface_frame(surface), &kFrame, NULL);
	xdg_surface_set_window_geometry(xdgSurface, 0, 0, width, height);
	present(view, color);
	wl_surface_commit(surface);
	wl_display_roundtrip(display);
}

static bool
size_is(BView* view, int width, int height, const char* what)
{
	BRect bounds, frame;
	bool hidden;
	if (!state(view, bounds, frame, hidden)) {
		check(what, false, "the window stays locked");
		return false;
	}
	char detail[160];
	snprintf(detail, sizeof(detail), "view %dx%d, window %dx%d, %s", bounds.IntegerWidth() + 1,
		bounds.IntegerHeight() + 1, frame.IntegerWidth() + 1, frame.IntegerHeight() + 1,
		hidden ? "hidden" : "shown");
	bool ok = bounds.IntegerWidth() + 1 == width && bounds.IntegerHeight() + 1 == height
		&& frame.IntegerWidth() + 1 == width && frame.IntegerHeight() + 1 == height && !hidden;
	check(what, ok, detail);
	return ok;
}

int
main(int argc, char** argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 5;
	wl_display* display = wl_display_connect(NULL);
	check("connect", display != NULL);
	if (display == NULL)
		return 1;
	wl_registry* registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &kRegistry, NULL);
	wl_display_roundtrip(display);
	check("globals", sCompositor != NULL && sWmBase != NULL);
	if (sCompositor == NULL || sWmBase == NULL)
		return 1;
	xdg_wm_base_add_listener(sWmBase, &kWmBase, NULL);

	wl_surface* surface = wl_compositor_create_surface(sCompositor);
	xdg_surface* xdgSurface = xdg_wm_base_get_xdg_surface(sWmBase, surface);
	xdg_surface_add_listener(xdgSurface, &kXdgSurface, NULL);
	xdg_toplevel* toplevel = xdg_surface_get_toplevel(xdgSurface);
	xdg_toplevel_add_listener(toplevel, &kToplevel, NULL);
	xdg_toplevel_set_title(toplevel, "wlview");
	wl_surface_commit(surface);
	while (!sConfigured && wl_display_dispatch(display) != -1)
		;
	check("configure", sConfigured);

	void* server = dlopen("wayland-server-inproc.so", RTLD_NOW);
	typedef void* (*surface_view_t)(uint32_t);
	surface_view_t surfaceView = server == NULL ? NULL
		: (surface_view_t)dlsym(server, "wl_ips_haiku_surface_view");
	check("export", surfaceView != NULL, "wl_ips_haiku_surface_view");
	if (surfaceView == NULL)
		return 1;
	uint32_t id = wl_proxy_get_id((wl_proxy*)surface);
	BView* view = (BView*)surfaceView(id);
	char detail[80];
	snprintf(detail, sizeof(detail), "wl_surface@%u view %p", id, view);
	check("view", view != NULL && view->Looper() != NULL, detail);
	if (view == NULL)
		return 1;
	check("no view for a non-surface", surfaceView(0xfffff) == NULL);

	// before the first frame: no geometry committed yet; the window hidden, but it can be locked (the WSI
	// reads the view's size when the surface and the swapchain are made)
	BRect bounds, frameRect;
	bool hidden = false;
	bool lockable = state(view, bounds, frameRect, hidden);
	check("lockable before the first commit", lockable);
	check("hidden before the first commit", lockable && hidden);

	frame(display, surface, xdgSurface, view, 640, 400, make_color(200, 30, 30));
	snooze(300000);
	present(view, make_color(200, 30, 30));
	size_is(view, 640, 400, "first commit: shown at the geometry");

	frame(display, surface, xdgSurface, view, 800, 500, make_color(30, 160, 60));
	snooze(300000);
	present(view, make_color(30, 160, 60));
	size_is(view, 800, 500, "resize by geometry");

	// a few more frames: their frame callbacks must come (the window's pulse, ~2-60 Hz)
	for (int i = 0; i < 5; i++) {
		frame(display, surface, xdgSurface, view, 800, 500, make_color(30, 160, 60));
		snooze(100000);
	}
	bigtime_t until = system_time() + 3000000;
	while (sFramesDone < 7 && system_time() < until) {
		wl_display_roundtrip(display);
		snooze(50000);
	}
	snprintf(detail, sizeof(detail), "%d of 7", sFramesDone);
	check("frame callbacks", sFramesDone >= 6, detail);

	sleep(seconds);
	printf("WLV result: %d bad\n", sBad);
	xdg_toplevel_destroy(toplevel);
	xdg_surface_destroy(xdgSurface);
	wl_surface_destroy(surface);
	wl_display_roundtrip(display);
	wl_display_disconnect(display);
	return sBad == 0 ? 0 : 1;
}
