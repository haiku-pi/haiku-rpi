/*
 * wlkeys.cpp — what a Wayland client of Haiku's in-process server sees of the keyboard: a toplevel made the
 * way Photocraft's is (presented externally: wl_ips_haiku_surface_view, a window geometry, buffer-less
 * commits; no GPU needed), a wl_keyboard whose keymap goes through libxkbcommon as winit does, and every
 * keyboard event printed with the modifiers as a toolkit reads them (xkb_state_update_mask from
 * wl_keyboard.modifiers, then the effective Control/Alt/Shift/Logo state). For finding where a shortcut
 * (Ctrl+O) gets lost: keyinject, QEMU's sendkey (input_server, the real path) or a person at the keyboard.
 *
 *   wlkeys [SECONDS]      (how long the window stays, default 20)
 *
 * Output: "WLK ready wl_surface@N" once the window is shown, then "WLK enter", "WLK leave",
 * "WLK modifiers depressed 0x... latched 0x... locked 0x...: <names> -> ctrl 0|1 alt 0|1 shift 0|1 logo 0|1",
 * "WLK key <evdev code> down|up: <keysym> \"<utf8>\" ctrl 0|1 alt 0|1 shift 0|1 logo 0|1", "WLK end: N keys".
 *
 * Build (cross; built into the GUI stage by scripts/build-photocraft.sh --only gui):
 *   as wlview.cpp, plus -lxkbcommon
 */
#include <View.h>
#include <Window.h>

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "xdg-shell.h"


static wl_compositor* sCompositor;
static xdg_wm_base* sWmBase;
static wl_seat* sSeat;
static bool sConfigured;
static xkb_context* sContext;
static xkb_keymap* sKeymap;
static xkb_state* sState;
static int sKeys;

static void
global(void*, wl_registry* registry, uint32_t name, const char* interface, uint32_t)
{
	if (strcmp(interface, wl_compositor_interface.name) == 0)
		sCompositor = (wl_compositor*)wl_registry_bind(registry, name, &wl_compositor_interface, 4);
	else if (strcmp(interface, xdg_wm_base_interface.name) == 0)
		sWmBase = (xdg_wm_base*)wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
	else if (strcmp(interface, wl_seat_interface.name) == 0)
		sSeat = (wl_seat*)wl_registry_bind(registry, name, &wl_seat_interface, 5);
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

// the effective modifiers as winit reads them
static void
print_mods(char* out, size_t size)
{
	if (sState == NULL) {
		snprintf(out, size, "(no keymap)");
		return;
	}
	snprintf(out, size, "ctrl %d alt %d shift %d logo %d",
		xkb_state_mod_name_is_active(sState, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE) > 0,
		xkb_state_mod_name_is_active(sState, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE) > 0,
		xkb_state_mod_name_is_active(sState, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) > 0,
		xkb_state_mod_name_is_active(sState, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE) > 0);
}

static void
keymap(void*, wl_keyboard*, uint32_t format, int32_t fd, uint32_t size)
{
	char* text = (char*)mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 || text == MAP_FAILED) {
		printf("WLK keymap: format %u, not mapped\n", format);
		return;
	}
	if (sState != NULL)
		xkb_state_unref(sState);
	if (sKeymap != NULL)
		xkb_keymap_unref(sKeymap);
	sKeymap = xkb_keymap_new_from_string(sContext, text, XKB_KEYMAP_FORMAT_TEXT_V1,
		XKB_KEYMAP_COMPILE_NO_FLAGS);
	munmap(text, size);
	sState = sKeymap != NULL ? xkb_state_new(sKeymap) : NULL;
	printf("WLK keymap: %u bytes, %s, %u modifiers:", size, sKeymap != NULL ? "compiled" : "NOT compiled",
		sKeymap != NULL ? xkb_keymap_num_mods(sKeymap) : 0);
	for (xkb_mod_index_t i = 0; sKeymap != NULL && i < xkb_keymap_num_mods(sKeymap); i++)
		printf(" %u=%s", i, xkb_keymap_mod_get_name(sKeymap, i));
	printf("\n");
	fflush(stdout);
}

static void
enter(void*, wl_keyboard*, uint32_t, wl_surface* surface, wl_array*)
{
	printf("WLK enter wl_surface@%u\n", wl_proxy_get_id((wl_proxy*)surface));
	fflush(stdout);
}

static void
leave(void*, wl_keyboard*, uint32_t, wl_surface* surface)
{
	printf("WLK leave wl_surface@%u\n", surface != NULL ? wl_proxy_get_id((wl_proxy*)surface) : 0);
	fflush(stdout);
}

static void
key(void*, wl_keyboard*, uint32_t, uint32_t, uint32_t code, uint32_t state)
{
	char name[64] = "?", utf8[16] = "", mods[96];
	if (sState != NULL) {
		xkb_keysym_t sym = xkb_state_key_get_one_sym(sState, code + 8);
		xkb_keysym_get_name(sym, name, sizeof(name));
		xkb_state_key_get_utf8(sState, code + 8, utf8, sizeof(utf8));
		for (char* c = utf8; *c != '\0'; c++) {
			if ((unsigned char)*c < 0x20)
				*c = '^';
		}
	}
	print_mods(mods, sizeof(mods));
	printf("WLK key %u %s: %s \"%s\" %s\n", code, state == WL_KEYBOARD_KEY_STATE_PRESSED ? "down" : "up",
		name, utf8, mods);
	fflush(stdout);
	if (state == WL_KEYBOARD_KEY_STATE_PRESSED)
		sKeys++;
}

static void
modifiers(void*, wl_keyboard*, uint32_t, uint32_t depressed, uint32_t latched, uint32_t locked,
	uint32_t group)
{
	char names[256] = "", mods[96];
	if (sState != NULL) {
		xkb_state_update_mask(sState, depressed, latched, locked, 0, 0, group);
		uint32_t all = depressed | latched | locked;
		for (xkb_mod_index_t i = 0; i < 32; i++) {
			if ((all & (1u << i)) == 0)
				continue;
			const char* name = i < xkb_keymap_num_mods(sKeymap) ? xkb_keymap_mod_get_name(sKeymap, i) : NULL;
			size_t length = strlen(names);
			snprintf(names + length, sizeof(names) - length, " %u=%s", i, name != NULL ? name : "(none)");
		}
	}
	print_mods(mods, sizeof(mods));
	printf("WLK modifiers depressed 0x%x latched 0x%x locked 0x%x:%s -> %s\n", depressed, latched, locked,
		names, mods);
	fflush(stdout);
}

static void repeat_info(void*, wl_keyboard*, int32_t, int32_t) {}
static const wl_keyboard_listener kKeyboard = {keymap, enter, leave, key, modifiers, repeat_info};

int
main(int argc, char** argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 20;
	sContext = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	wl_display* display = wl_display_connect(NULL);
	if (display == NULL) {
		printf("WLK error: no display\n");
		return 1;
	}
	wl_registry* registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &kRegistry, NULL);
	wl_display_roundtrip(display);
	if (sCompositor == NULL || sWmBase == NULL || sSeat == NULL) {
		printf("WLK error: globals missing\n");
		return 1;
	}
	xdg_wm_base_add_listener(sWmBase, &kWmBase, NULL);
	wl_keyboard* keyboard = wl_seat_get_keyboard(sSeat);
	wl_keyboard_add_listener(keyboard, &kKeyboard, NULL);

	wl_surface* surface = wl_compositor_create_surface(sCompositor);
	xdg_surface* xdgSurface = xdg_wm_base_get_xdg_surface(sWmBase, surface);
	xdg_surface_add_listener(xdgSurface, &kXdgSurface, NULL);
	xdg_toplevel* toplevel = xdg_surface_get_toplevel(xdgSurface);
	xdg_toplevel_add_listener(toplevel, &kToplevel, NULL);
	xdg_toplevel_set_title(toplevel, "wlkeys");
	wl_surface_commit(surface);
	while (!sConfigured && wl_display_dispatch(display) != -1)
		;
	// as winit + wgpu-hal: the geometry, the view for the Vulkan surface (shown at once), a commit per frame
	xdg_surface_set_window_geometry(xdgSurface, 0, 0, 480, 240);
	void* server = dlopen("wayland-server-inproc.so", RTLD_NOW);
	typedef void* (*surface_view_t)(uint32_t);
	surface_view_t surfaceView = server == NULL ? NULL
		: (surface_view_t)dlsym(server, "wl_ips_haiku_surface_view");
	BView* view = surfaceView != NULL ? (BView*)surfaceView(wl_proxy_get_id((wl_proxy*)surface)) : NULL;
	if (view == NULL) {
		printf("WLK error: no view\n");
		return 1;
	}
	if (view->LockLooperWithTimeout(1000000) == B_OK) {
		view->SetHighColor(make_color(60, 90, 160));
		view->FillRect(view->Bounds());
		view->Sync();
		view->UnlockLooper();
	}
	wl_surface_commit(surface);
	wl_display_roundtrip(display);
	printf("WLK ready wl_surface@%u\n", wl_proxy_get_id((wl_proxy*)surface));
	fflush(stdout);

	bigtime_t until = system_time() + seconds * 1000000LL;
	while (system_time() < until) {
		wl_display_roundtrip(display);
		snooze(20000);
	}
	printf("WLK end: %d keys\n", sKeys);
	fflush(stdout);
	xdg_toplevel_destroy(toplevel);
	xdg_surface_destroy(xdgSurface);
	wl_surface_destroy(surface);
	wl_display_roundtrip(display);
	wl_display_disconnect(display);
	return 0;
}
