/*
 * uiinject.cpp — drive a window of a running Haiku application the way app_server and input_server do: activate
 * it (scripting "Active", so app_server sends the real B_WINDOW_ACTIVATED), then mouse moves, button presses,
 * drags and named keys as messages to the window. For unattended tests of programs that take input only in their
 * active window (SDL: keyboard events go to the window with keyboard focus; without it SDL sends them with window
 * id 0, and e.g. Blender's GHOST_SDL drops them: "<!> event has no window").
 *
 *   uiinject TEAM TITLE-PART COMMAND...
 *     activate                  make the window the active one (and wait 300 ms)
 *     move X Y                  B_MOUSE_MOVED to X,Y (window coordinates)
 *     down B | up B             press / release mouse button B (1 left, 2 right, 3 middle)
 *     click B X Y               move, down, up
 *     drag B X1 Y1 X2 Y2 N MS   move to X1,Y1, press B, N moves to X2,Y2 (MS between moves), release
 *     key NAME                  press and release a key: a-z 0-9 space tab esc return f1-f12
 *                               kp0-kp9 (numeric keypad), up down left right
 *     wait MS
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -I sources/haiku/headers/private/app -o uiinject tools/haiku-tests/uiinject.cpp -lbe
 */

#include <Application.h>
#include <InterfaceDefs.h>
#include <Messenger.h>
#include <MessengerPrivate.h>
#include <TokenSpace.h>
#include <View.h>
#include <OS.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


static BMessenger sWindow;
static BPoint sWhere(0, 0);
static int32 sButtons = 0;


// Haiku's key codes (the US keymap) and the byte a key types (0: none)
static bool
key_code(const char* name, int32& key, char& byte)
{
	static const char* rows[] = { "1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm" };
	static const int32 starts[] = { 0x12, 0x27, 0x3c, 0x4c };
	byte = 0;
	if (strlen(name) == 1) {
		char c = tolower(name[0]);
		for (int i = 0; i < 4; i++) {
			const char* p = strchr(rows[i], c);
			if (p != NULL) {
				key = starts[i] + (p - rows[i]);
				byte = c;
				return true;
			}
		}
	}
	static const struct { const char* name; int32 key; char byte; } named[] = {
		{ "space", 0x5e, ' ' }, { "tab", 0x26, B_TAB }, { "esc", 0x01, B_ESCAPE },
		{ "return", 0x47, B_ENTER }, { "up", 0x57, B_UP_ARROW }, { "down", 0x62, B_DOWN_ARROW },
		{ "left", 0x61, B_LEFT_ARROW }, { "right", 0x63, B_RIGHT_ARROW },
		{ "kp0", 0x64, '0' }, { "kp1", 0x58, '1' }, { "kp2", 0x59, '2' }, { "kp3", 0x5a, '3' },
		{ "kp4", 0x48, '4' }, { "kp5", 0x49, '5' }, { "kp6", 0x4a, '6' }, { "kp7", 0x37, '7' },
		{ "kp8", 0x38, '8' }, { "kp9", 0x39, '9' },
	};
	for (size_t i = 0; i < sizeof(named) / sizeof(named[0]); i++) {
		if (strcmp(name, named[i].name) == 0) {
			key = named[i].key;
			byte = named[i].byte;
			return true;
		}
	}
	if (name[0] == 'f' && isdigit(name[1])) {
		int n = atoi(name + 1);
		if (n >= 1 && n <= 12) {
			key = 0x01 + n;	// F1 = 0x02 ... F12 = 0x0d
			byte = B_FUNCTION_KEY;
			return true;
		}
	}
	return false;
}


static void
post_key(uint32 what, int32 key, char byte)
{
	BMessage message(what);
	message.AddInt64("when", system_time());
	message.AddInt32("key", key);
	message.AddInt32("modifiers", 0);
	if (byte != 0) {
		char bytes[2] = { byte, 0 };
		message.AddInt8("byte", byte);
		message.AddString("bytes", bytes);
		message.AddInt32("raw_char", tolower(byte));
	}
	sWindow.SendMessage(&message);
}


static void
post_mouse(uint32 what)
{
	BMessage message(what);
	message.AddInt64("when", system_time());
	message.AddPoint("where", sWhere);
	message.AddPoint("be:view_where", sWhere);
	message.AddInt32("buttons", sButtons);
	message.AddInt32("modifiers", 0);
	if (what == B_MOUSE_MOVED)
		message.AddInt32("be:transit", B_INSIDE_VIEW);
	if (what == B_MOUSE_DOWN)
		message.AddInt32("clicks", 1);
	sWindow.SendMessage(&message);
}


static int32
button_mask(int b)
{
	return b == 1 ? B_PRIMARY_MOUSE_BUTTON : b == 2 ? B_SECONDARY_MOUSE_BUTTON : B_TERTIARY_MOUSE_BUTTON;
}


int
main(int argc, char** argv)
{
	if (argc < 4) {
		fprintf(stderr, "usage: uiinject TEAM TITLE-PART COMMAND...\n");
		return 2;
	}
	BApplication app("application/x-vnd.haiku-pi-uiinject");
	BMessenger target(NULL, (team_id)atoi(argv[1]));
	int32 index = -1;
	for (int32 i = 0; i < 64 && !sWindow.IsValid(); i++) {
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
		if (target.SendMessage(&getMessenger, &messengerReply, 1000000, 1000000) == B_OK)
			messengerReply.FindMessenger("result", &sWindow);
		index = i;
		printf("uiinject: window %" B_PRId32 " \"%s\"\n", i, title);
	}
	if (!sWindow.IsValid()) {
		fprintf(stderr, "uiinject: no window \"%s\" in team %s\n", argv[2], argv[1]);
		return 1;
	}
	// to the window's preferred handler, as input_server sends (BWindow hands it to the focus view)
	BMessenger window = sWindow;
	BMessenger::Private(sWindow).SetTo(BMessenger::Private(sWindow).Team(),
		BMessenger::Private(sWindow).Port(), B_PREFERRED_TOKEN);

	for (int a = 3; a < argc; a++) {
		const char* c = argv[a];
		if (strcmp(c, "activate") == 0) {
			BMessage set(B_SET_PROPERTY), reply;
			set.AddBool("data", true);
			set.AddSpecifier("Active");
			set.AddSpecifier("Window", index);
			status_t status = target.SendMessage(&set, &reply, 1000000, 1000000);
			printf("uiinject: activate: %s\n", strerror(status));
			snooze(300000);
		} else if (strcmp(c, "move") == 0 && a + 2 < argc) {
			sWhere = BPoint(atof(argv[a + 1]), atof(argv[a + 2]));
			a += 2;
			post_mouse(B_MOUSE_MOVED);
		} else if ((strcmp(c, "down") == 0 || strcmp(c, "up") == 0) && a + 1 < argc) {
			int32 mask = button_mask(atoi(argv[++a]));
			bool down = c[0] == 'd';
			sButtons = down ? (sButtons | mask) : (sButtons & ~mask);
			post_mouse(down ? B_MOUSE_DOWN : B_MOUSE_UP);
		} else if (strcmp(c, "click") == 0 && a + 3 < argc) {
			int32 mask = button_mask(atoi(argv[a + 1]));
			sWhere = BPoint(atof(argv[a + 2]), atof(argv[a + 3]));
			a += 3;
			post_mouse(B_MOUSE_MOVED);
			snooze(50000);
			sButtons |= mask;
			post_mouse(B_MOUSE_DOWN);
			snooze(80000);
			sButtons &= ~mask;
			post_mouse(B_MOUSE_UP);
		} else if (strcmp(c, "drag") == 0 && a + 7 < argc) {
			int32 mask = button_mask(atoi(argv[a + 1]));
			BPoint from(atof(argv[a + 2]), atof(argv[a + 3])), to(atof(argv[a + 4]), atof(argv[a + 5]));
			int n = atoi(argv[a + 6]);
			bigtime_t pause = atoi(argv[a + 7]) * 1000LL;
			a += 7;
			sWhere = from;
			post_mouse(B_MOUSE_MOVED);
			snooze(50000);
			sButtons |= mask;
			post_mouse(B_MOUSE_DOWN);
			for (int i = 1; i <= n; i++) {
				snooze(pause);
				sWhere = from + BPoint((to.x - from.x) * i / n, (to.y - from.y) * i / n);
				post_mouse(B_MOUSE_MOVED);
			}
			snooze(50000);
			sButtons &= ~mask;
			post_mouse(B_MOUSE_UP);
		} else if (strcmp(c, "key") == 0 && a + 1 < argc) {
			int32 key;
			char byte;
			if (!key_code(argv[++a], key, byte)) {
				fprintf(stderr, "uiinject: no key \"%s\"\n", argv[a]);
				continue;
			}
			post_key(B_KEY_DOWN, key, byte);
			snooze(60000);
			post_key(B_KEY_UP, key, byte);
		} else if (strcmp(c, "wait") == 0 && a + 1 < argc) {
			snooze(atoi(argv[++a]) * 1000LL);
		} else {
			fprintf(stderr, "uiinject: bad command \"%s\"\n", c);
			return 2;
		}
		snooze(30000);
	}
	printf("uiinject: done\n");
	return 0;
}
