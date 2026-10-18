/*
 * cursor-move — moves the mouse pointer from a program (the input_server's set-position command, what
 * libgame's set_mouse_position() sends; the minimum image has no libgame): to the screen's centre, its four corners (the cursor partly off screen) and around a
 * circle, holding each corner a while so that HDMI frames catch it. "CUR " lines.
 *
 *   cursor-move [-h SECONDS_PER_CORNER] [-c SECONDS_OF_CIRCLE]
 */

#include <Application.h>
#include <Message.h>
#include <Screen.h>
#include <OS.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>


// libbe's private channel to the input_server (headers/private/interface/input_globals.h)
status_t _control_input_server_(BMessage* command, BMessage* reply);


static void
set_mouse_position(int32 x, int32 y)
{
	BMessage command('Ismp');
		// IS_SET_MOUSE_POSITION
	BMessage reply;
	command.AddPoint("where", BPoint(x, y));
	_control_input_server_(&command, &reply);
}


int
main(int argc, char** argv)
{
	double hold = 3, circle = 5;
	int opt;
	while ((opt = getopt(argc, argv, "h:c:")) != -1) {
		if (opt == 'h')
			hold = atof(optarg);
		else if (opt == 'c')
			circle = atof(optarg);
		else {
			fprintf(stderr, "usage: %s [-h seconds] [-c seconds]\n", argv[0]);
			return 2;
		}
	}

	BApplication app("application/x-vnd.haiku-rpi-cursor-move");
	BRect frame = BScreen().Frame();
	const int32 width = frame.IntegerWidth() + 1;
	const int32 height = frame.IntegerHeight() + 1;
	printf("CUR screen %" B_PRId32 "x%" B_PRId32 "\n", width, height);
	fflush(stdout);

	const struct { int32 x, y; const char* name; } kPoints[] = {
		{ width / 2, height / 2, "centre" },
		{ 0, 0, "top left" },
		{ width - 1, 0, "top right" },
		{ width - 1, height - 1, "bottom right" },
		{ 0, height - 1, "bottom left" },
	};
	for (size_t i = 0; i < sizeof(kPoints) / sizeof(kPoints[0]); i++) {
		set_mouse_position(kPoints[i].x, kPoints[i].y);
		printf("CUR %s %" B_PRId32 ",%" B_PRId32 "\n", kPoints[i].name,
			kPoints[i].x, kPoints[i].y);
		fflush(stdout);
		snooze((bigtime_t)(hold * 1000000));
	}

	const bigtime_t start = system_time();
	int moves = 0;
	while (system_time() - start < (bigtime_t)(circle * 1000000)) {
		const double angle = (system_time() - start) / 1000000.0 * 2 * M_PI / 2;
		set_mouse_position(width / 2 + (int32)(cos(angle) * height / 3),
			height / 2 + (int32)(sin(angle) * height / 3));
		moves++;
		snooze(8000);
	}
	printf("CUR circle: %d moves in %.1f s\n", moves, circle);
	return 0;
}
