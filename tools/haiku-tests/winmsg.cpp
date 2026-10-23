/*
 * winmsg.cpp — post a message with a given code to a window of a running Haiku application, as if one of its
 * controls had been pressed (a button's message), for unattended tests of dialogs:
 *
 *   winmsg TEAM TITLE-PART CODE        (CODE: a four-character code, e.g. acCp)
 *
 * Build: as tools/haiku-tests/keyinject.cpp.
 */
#include <Application.h>
#include <Messenger.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int
main(int argc, char** argv)
{
	if (argc != 4 || strlen(argv[3]) != 4) {
		fprintf(stderr, "usage: winmsg TEAM TITLE-PART CODE\n");
		return 2;
	}
	BApplication app("application/x-vnd.haiku-pi-winmsg");
	BMessenger target(NULL, (team_id)atoi(argv[1]));
	for (int32 i = 0; i < 64; i++) {
		BMessage get(B_GET_PROPERTY), reply;
		get.AddSpecifier("Title");
		get.AddSpecifier("Window", i);
		const char* title;
		if (target.SendMessage(&get, &reply, 1000000, 1000000) != B_OK
			|| reply.FindString("result", &title) != B_OK)
			break;
		if (strstr(title, argv[2]) == NULL)
			continue;
		BMessage getMessenger(B_GET_PROPERTY), messengerReply;
		getMessenger.AddSpecifier("Messenger");
		getMessenger.AddSpecifier("Window", i);
		BMessenger window;
		if (target.SendMessage(&getMessenger, &messengerReply, 1000000, 1000000) != B_OK
			|| messengerReply.FindMessenger("result", &window) != B_OK)
			break;
		const char* c = argv[3];
		uint32 what = ((uint32)c[0] << 24) | ((uint32)c[1] << 16) | ((uint32)c[2] << 8) | (uint32)c[3];
		status_t status = window.SendMessage(what);
		printf("winmsg: '%s' to window %" B_PRId32 " \"%s\": %s\n", argv[3], i, title, strerror(status));
		return status == B_OK ? 0 : 1;
	}
	fprintf(stderr, "winmsg: no window \"%s\" in team %s\n", argv[2], argv[1]);
	return 1;
}
