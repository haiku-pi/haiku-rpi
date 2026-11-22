/*
 * winframes.cpp — the windows of a running Haiku application with their frames (the content area, in screen
 * coordinates; the tab and border lie outside it), visibility and look, by scripting, for unattended checks of
 * window placement. `hey` cannot reach an application launched with B_ARGV_ONLY (Blender's): the roster
 * has no app info for it; a messenger to the team works.
 *
 *   winframes TEAM
 *
 * One line per window: "WF <index> "<title>" frame=L,T,R,B hidden=0|1 look=N".
 * Build: as tools/haiku-tests/keyinject.cpp.
 */
#include <Application.h>
#include <Messenger.h>

#include <stdio.h>
#include <stdlib.h>

static bool
get(BMessenger& target, const char* property, int32 index, BMessage& reply)
{
	BMessage request(B_GET_PROPERTY);
	request.AddSpecifier(property);
	request.AddSpecifier("Window", index);
	return target.SendMessage(&request, &reply, 1000000, 1000000) == B_OK
		&& reply.what != B_MESSAGE_NOT_UNDERSTOOD && reply.FindInt32("error") != B_BAD_INDEX;
}

int
main(int argc, char** argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: winframes TEAM\n");
		return 2;
	}
	BApplication app("application/x-vnd.haiku-pi-winframes");
	BMessenger target(NULL, (team_id)atoi(argv[1]));
	if (!target.IsValid()) {
		fprintf(stderr, "winframes: no team %s\n", argv[1]);
		return 1;
	}
	int32 i = 0;
	for (; i < 64; i++) {
		BMessage titleReply, frameReply, hiddenReply, lookReply;
		const char* title;
		BRect frame;
		if (!get(target, "Title", i, titleReply) || titleReply.FindString("result", &title) != B_OK)
			break;
		get(target, "Frame", i, frameReply);
		frameReply.FindRect("result", &frame);
		bool hidden = false;
		if (get(target, "Hidden", i, hiddenReply))
			hiddenReply.FindBool("result", &hidden);
		int32 look = -1;
		if (get(target, "Look", i, lookReply))
			lookReply.FindInt32("result", &look);
		printf("WF %" B_PRId32 " \"%s\" frame=%.0f,%.0f,%.0f,%.0f hidden=%d look=%" B_PRId32 "\n", i, title,
			frame.left, frame.top, frame.right, frame.bottom, hidden ? 1 : 0, look);
	}
	return i > 0 ? 0 : 1;
}
