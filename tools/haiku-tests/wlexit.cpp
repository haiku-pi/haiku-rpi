/*
 * wlexit.cpp — a Wayland client of Haiku's in-process server that exits while another of its threads still
 * sends requests, as Photocraft does (its renderer commits frames while the main thread returns from main):
 * the server's loopers are held at exit (wayland_server's HoldLoopersAtExit), and a request arriving after
 * that wakes the Wayland looper, whose thread then looked itself up in libbe's looper list after exit() had
 * freed it — "Segment violation" in BLooperList::FindLooperPred (Photocraft on the Pi, 10-25), the team left
 * in the debugger. A toplevel as Photocraft's (presented externally: wl_ips_haiku_surface_view, a geometry,
 * buffer-less commits), a thread committing it every millisecond, exit() after MS milliseconds; and a
 * request sent from an exit handler registered before the connection, so it runs after the server's hold
 * and just before libbe's static destructors (as a library's destructor or another thread may send one).
 *
 *   wlexit [MS]     (default 300)
 *
 * Output: "WLX exiting after N commits"; the exit status is 0. A crash shows as the team staying in the
 * debugger ("Thread N entered the debugger" from debug_server) instead of ending.
 *
 * Build (cross): as wlview.cpp (scripts/build-photocraft.sh --only gui builds it into the GUI stage)
 */
#include <View.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <wayland-client.h>
#include "xdg-shell.h"


static wl_compositor* sCompositor;
static xdg_wm_base* sWmBase;
static bool sConfigured;
static wl_display* sDisplay;
static wl_surface* sSurface;
static volatile int sCommits;

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

// registered before the connection: runs after the server's exit handler, before libbe's destructors
static void
late_request()
{
	if (sSurface != NULL) {
		wl_surface_commit(sSurface);
		wl_display_flush(sDisplay);
	}
}

// the renderer: a commit per "frame", until the team ends
static void*
committer(void*)
{
	while (true) {
		wl_surface_commit(sSurface);
		wl_display_flush(sDisplay);
		sCommits++;
		usleep(1000);
	}
	return NULL;
}

int
main(int argc, char** argv)
{
	int ms = argc > 1 ? atoi(argv[1]) : 300;
	atexit(late_request);
	sDisplay = wl_display_connect(NULL);
	if (sDisplay == NULL) {
		printf("WLX error: no display\n");
		return 1;
	}
	wl_registry* registry = wl_display_get_registry(sDisplay);
	wl_registry_add_listener(registry, &kRegistry, NULL);
	wl_display_roundtrip(sDisplay);
	if (sCompositor == NULL || sWmBase == NULL) {
		printf("WLX error: globals missing\n");
		return 1;
	}
	xdg_wm_base_add_listener(sWmBase, &kWmBase, NULL);
	sSurface = wl_compositor_create_surface(sCompositor);
	xdg_surface* xdgSurface = xdg_wm_base_get_xdg_surface(sWmBase, sSurface);
	xdg_surface_add_listener(xdgSurface, &kXdgSurface, NULL);
	xdg_toplevel* toplevel = xdg_surface_get_toplevel(xdgSurface);
	xdg_toplevel_add_listener(toplevel, &kToplevel, NULL);
	xdg_toplevel_set_title(toplevel, "wlexit");
	wl_surface_commit(sSurface);
	while (!sConfigured && wl_display_dispatch(sDisplay) != -1)
		;
	xdg_surface_set_window_geometry(xdgSurface, 0, 0, 320, 200);
	void* server = dlopen("wayland-server-inproc.so", RTLD_NOW);
	typedef void* (*surface_view_t)(uint32_t);
	surface_view_t surfaceView = server == NULL ? NULL
		: (surface_view_t)dlsym(server, "wl_ips_haiku_surface_view");
	if (surfaceView == NULL || surfaceView(wl_proxy_get_id((wl_proxy*)sSurface)) == NULL) {
		printf("WLX error: no view\n");
		return 1;
	}
	wl_surface_commit(sSurface);
	wl_display_roundtrip(sDisplay);

	pthread_t thread;
	pthread_create(&thread, NULL, committer, NULL);
	usleep(ms * 1000);
	printf("WLX exiting after %d commits\n", sCommits);
	fflush(stdout);
	exit(0);
}
