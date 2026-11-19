/*
 * sdl-coreseq — SuperTuxKart's (Irrlicht's CIrrDeviceSDL) way to an OpenGL context through SDL2, step by step:
 * SDL's video subsystem started and stopped once (STK's null device), started again, then core-profile
 * requests for 4.3, 3.3 and 3.1 (8-bit RGB, 24-bit depth, double-buffered), each in a new window that is
 * destroyed with its context before the next attempt, and last a profile-0 2.1 request (STK's legacy device).
 * The first attempt whose context reports at least the requested version wins, as in STK's versionCorrect().
 * Each attempt prints SDL's error or the context's GL_VERSION, so a program that ends on an older context
 * than expected shows where it lost the newer one (docs/design/desktop-gl.md §7).
 *
 *   sdl-coreseq [-1] [-f] [-o]   -1: one SDL_InitSubSystem only (no null device first)
 *                                -f: fullscreen windows; -o: stop at the first context SDL hands out
 *
 * Lines start with "SCS ". Exit status 0 when the 3.3 core request gave a 3.3 core context.
 */

#include <SDL2/SDL.h>

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#define SAY(...) do { printf("SCS " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

#define GL_VERSION 0x1F02
#define GL_MAJOR_VERSION 0x821B
#define GL_MINOR_VERSION 0x821C
#define GL_CONTEXT_PROFILE_MASK 0x9126

typedef const unsigned char *(*GetStringFunc)(unsigned int);
typedef void (*GetIntegervFunc)(unsigned int, int *);

int
main(int argc, char **argv)
{
	bool nullDevice = true, fullscreen = false, first = false;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-1") == 0)
			nullDevice = false;
		else if (strcmp(argv[i], "-f") == 0)
			fullscreen = true;
		else if (strcmp(argv[i], "-o") == 0)
			first = true;
		else {
			fprintf(stderr, "usage: %s [-1] [-f] [-o]\n", argv[0]);
			return 2;
		}
	}
	SDL_version linked;
	SDL_GetVersion(&linked);
	SAY("SDL %d.%d.%d", linked.major, linked.minor, linked.patch);
	if (nullDevice) {
		if (SDL_InitSubSystem(SDL_INIT_TIMER | SDL_INIT_VIDEO) < 0) {
			SAY("FAIL first SDL_InitSubSystem: %s", SDL_GetError());
			return 1;
		}
		SDL_QuitSubSystem(SDL_INIT_TIMER | SDL_INIT_VIDEO);
	}
	if (SDL_InitSubSystem(SDL_INIT_TIMER | SDL_INIT_VIDEO) < 0) {
		SAY("FAIL SDL_InitSubSystem: %s", SDL_GetError());
		return 1;
	}
	SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	Uint32 flags = SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_OPENGL;
	if (fullscreen)
		flags |= SDL_WINDOW_FULLSCREEN;

	static const struct { int major, minor, profile; } attempts[] = {
		{ 4, 3, SDL_GL_CONTEXT_PROFILE_CORE },
		{ 3, 3, SDL_GL_CONTEXT_PROFILE_CORE },
		{ 3, 1, SDL_GL_CONTEXT_PROFILE_CORE },
		{ 2, 1, 0 },
	};
	int status = 1;
	SDL_Window *window = NULL;
	SDL_GLContext context = NULL;
	for (size_t i = 0; i < sizeof(attempts) / sizeof(attempts[0]); i++) {
		if (context != NULL)
			SDL_GL_DeleteContext(context);
		if (window != NULL)
			SDL_DestroyWindow(window);
		context = NULL;
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, attempts[i].profile);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, attempts[i].major);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, attempts[i].minor);
		const char *profile = attempts[i].profile == SDL_GL_CONTEXT_PROFILE_CORE ? "core" : "profile 0";
		window = SDL_CreateWindow("sdl-coreseq", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, 1280, 720,
			flags);
		if (window == NULL) {
			SAY("%s %d.%d: no window: %s", profile, attempts[i].major, attempts[i].minor, SDL_GetError());
			continue;
		}
		context = SDL_GL_CreateContext(window);
		if (context == NULL) {
			SAY("%s %d.%d: no context: %s", profile, attempts[i].major, attempts[i].minor, SDL_GetError());
			continue;
		}
		GetStringFunc getString = (GetStringFunc)SDL_GL_GetProcAddress("glGetString");
		GetIntegervFunc getIntegerv = (GetIntegervFunc)SDL_GL_GetProcAddress("glGetIntegerv");
		if (getString == NULL || getIntegerv == NULL) {
			SAY("%s %d.%d: context, but no glGetString/glGetIntegerv: %s", profile, attempts[i].major,
				attempts[i].minor, SDL_GetError());
			continue;
		}
		int major = 0, minor = 0, mask = 0;
		getIntegerv(GL_MAJOR_VERSION, &major);
		getIntegerv(GL_MINOR_VERSION, &minor);
		getIntegerv(GL_CONTEXT_PROFILE_MASK, &mask);
		const char *version = (const char *)getString(GL_VERSION);
		bool enough = major > attempts[i].major || (major == attempts[i].major && minor >= attempts[i].minor);
		SAY("%s %d.%d: context \"%s\" (%d.%d, profile mask %d): %s", profile, attempts[i].major,
			attempts[i].minor, version ? version : "(null)", major, minor, mask,
			enough ? "taken" : "older than asked, next");
		if (enough || first) {
			status = (attempts[i].major == 3 && attempts[i].minor == 3 && major == 3 && minor >= 3
				&& (mask & 1)) ? 0 : 1;
			break;
		}
	}
	SAY("%s 3.3 core %s", status == 0 ? "PASS" : "FAIL",
		status == 0 ? "was the context taken" : "was not the context taken");
	if (context != NULL)
		SDL_GL_DeleteContext(context);
	if (window != NULL)
		SDL_DestroyWindow(window);
	SDL_Quit();
	return status;
}
