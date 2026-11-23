/*
 * sdl-winpos — where an SDL2 window ends up, for checks of the Haiku backend's window placement
 * (docs/design/blender.md §7.20): create one window at a given position and size, then run commands on it,
 * printing after each what SDL reports (position, size, maximized/fullscreen). The window is filled with
 * one colour through its surface, so that HDMI frames show its content area.
 *
 *   sdl-winpos X Y W H [r][b][f] [COMMAND...]
 *     X, Y          a position, or c (SDL_WINDOWPOS_CENTERED) or u (SDL_WINDOWPOS_UNDEFINED)
 *     r b f         flags: resizable, borderless, fullscreen (SDL_WINDOW_FULLSCREEN_DESKTOP); "-" for none
 *     move X Y      SDL_SetWindowPosition (X, Y as above)
 *     max | min     SDL_MaximizeWindow / SDL_MinimizeWindow
 *     restore       SDL_RestoreWindow
 *     full | unfull SDL_SetWindowFullscreen(SDL_WINDOW_FULLSCREEN) / (0)
 *     wait MS       pump events for MS milliseconds (every command is followed by 300 ms of that)
 *
 * Lines start with "SWP ". Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -o sdl-winpos tools/gl-tests/sdl-winpos.c -lSDL2
 */

#include <SDL2/SDL.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int
coordinate(const char *arg)
{
	if (strcmp(arg, "c") == 0)
		return SDL_WINDOWPOS_CENTERED;
	if (strcmp(arg, "u") == 0)
		return SDL_WINDOWPOS_UNDEFINED;
	return atoi(arg);
}

static void
pump(SDL_Window *window, int ms)
{
	Uint32 end = SDL_GetTicks() + ms;
	do {
		SDL_Event event;
		while (SDL_PollEvent(&event)) {
			if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_MAXIMIZED)
				printf("SWP event maximized\n");
			else if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_RESTORED)
				printf("SWP event restored\n");
			else if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_MINIMIZED)
				printf("SWP event minimized\n");
			else if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_RESIZED)
				printf("SWP event resized %dx%d\n", event.window.data1, event.window.data2);
		}
		SDL_Surface *surface = SDL_GetWindowSurface(window);
		if (surface != NULL) {
			SDL_FillRect(surface, NULL, SDL_MapRGB(surface->format, 0x20, 0x80, 0xc0));
			SDL_UpdateWindowSurface(window);
		}
		SDL_Delay(20);
	} while (!SDL_TICKS_PASSED(SDL_GetTicks(), end));
}

static void
report(SDL_Window *window, const char *what)
{
	int x, y, w, h;
	SDL_GetWindowPosition(window, &x, &y);
	SDL_GetWindowSize(window, &w, &h);
	Uint32 flags = SDL_GetWindowFlags(window);
	printf("SWP %s pos=%d,%d size=%dx%d%s%s%s\n", what, x, y, w, h,
		(flags & SDL_WINDOW_MAXIMIZED) ? " maximized" : "",
		(flags & SDL_WINDOW_MINIMIZED) ? " minimized" : "",
		(flags & SDL_WINDOW_FULLSCREEN) ? " fullscreen" : "");
	fflush(stdout);
}

int
main(int argc, char **argv)
{
	if (argc < 6) {
		fprintf(stderr, "usage: sdl-winpos X Y W H [r][b][f] [move X Y|max|min|restore|full|unfull|wait MS]...\n");
		return 2;
	}
	Uint32 flags = SDL_WINDOW_SHOWN;
	if (strchr(argv[5], 'r') != NULL)
		flags |= SDL_WINDOW_RESIZABLE;
	if (strchr(argv[5], 'b') != NULL)
		flags |= SDL_WINDOW_BORDERLESS;
	if (strchr(argv[5], 'f') != NULL)
		flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;

	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		printf("SWP SDL_Init: %s\n", SDL_GetError());
		return 1;
	}
	SDL_Window *window = SDL_CreateWindow("sdl-winpos", coordinate(argv[1]), coordinate(argv[2]),
		atoi(argv[3]), atoi(argv[4]), flags);
	if (window == NULL) {
		printf("SWP SDL_CreateWindow: %s\n", SDL_GetError());
		return 1;
	}
	report(window, "created");
	pump(window, 300);
	report(window, "shown");

	for (int i = 6; i < argc; i++) {
		const char *command = argv[i];
		if (strcmp(command, "move") == 0 && i + 2 < argc) {
			SDL_SetWindowPosition(window, coordinate(argv[i + 1]), coordinate(argv[i + 2]));
			i += 2;
		} else if (strcmp(command, "max") == 0) {
			SDL_MaximizeWindow(window);
		} else if (strcmp(command, "min") == 0) {
			SDL_MinimizeWindow(window);
		} else if (strcmp(command, "restore") == 0) {
			SDL_RestoreWindow(window);
		} else if (strcmp(command, "full") == 0) {
			SDL_SetWindowFullscreen(window, SDL_WINDOW_FULLSCREEN);
		} else if (strcmp(command, "unfull") == 0) {
			SDL_SetWindowFullscreen(window, 0);
		} else if (strcmp(command, "wait") == 0 && i + 1 < argc) {
			pump(window, atoi(argv[++i]));
			continue;
		} else {
			printf("SWP unknown command %s\n", command);
			return 2;
		}
		pump(window, 300);
		report(window, command);
	}

	SDL_DestroyWindow(window);
	SDL_Quit();
	return 0;
}
