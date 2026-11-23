/*
 * mouseto X Y — moves the real mouse pointer to X,Y (screen coordinates), as a mouse would: libgame's
 * set_mouse_position(), the input_server's set-position command. app_server then picks the cursor of the window
 * under the pointer, and the window gets B_MOUSE_MOVED with its transit (entered/exited) — unlike
 * tools/haiku-tests/uiinject.cpp, which posts messages to one window and leaves the pointer where it is.
 * Used for KNOWN-ISSUES W14 (cursor over Wine games, HDMI frames).
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -o mouseto tools/haiku-tests/mouseto.cpp -lgame -lbe
 */

#include <WindowScreen.h>

#include <stdio.h>
#include <stdlib.h>


int
main(int argc, char** argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: mouseto X Y\n");
		return 2;
	}
	set_mouse_position(atoi(argv[1]), atoi(argv[2]));
	return 0;
}
