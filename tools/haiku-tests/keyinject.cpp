/*
 * keyinject.cpp — type text into a window of a running Haiku application the way input_server delivers
 * keys: B_KEY_DOWN/B_KEY_UP with the US keymap's key codes, and Shift as its own (unmapped) key with
 * B_MODIFIERS_CHANGED, so a Wayland client of the in-process server (Wine) sees the keys and the modifier
 * state a real keyboard gives. For unattended tests of keyboard input; no input_server involved.
 *
 *   keyinject TEAM TITLE-PART TEXT [MS]   (letters, digits, space, ".,-!"; TEXT may use upper case; MS: the
 *                                          pause after each message, default 30)
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64
 *   $g/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ --sysroot=artifacts/sysroot-arm64 -O2 \
 *     -I sources/haiku/headers/private/app -o keyinject tools/haiku-tests/keyinject.cpp -lbe
 */
#include <Application.h>
#include <InterfaceDefs.h>
#include <Messenger.h>
#include <MessengerPrivate.h>
#include <TokenSpace.h>
#include <OS.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const int32 kLeftShift = 0x4b;

// the US keymap's key codes
static int32
key_code(char c)
{
	static const char* rows[] = { "1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm" };
	static const int32 starts[] = { 0x12, 0x27, 0x3c, 0x4c };
	c = tolower(c);
	for (int i = 0; i < 4; i++) {
		const char* p = strchr(rows[i], c);
		if (c != '\0' && p != NULL)
			return starts[i] + (p - rows[i]);
	}
	switch (c) {
		case ' ': return 0x5e;
		case '.': return 0x54;
		case ',': return 0x53;
		case '-': return 0x1c;
		case '!': return 0x12;	// Shift+1
	}
	return -1;
}

static bigtime_t sPause = 30000;

static void
post_key(BMessenger& window, uint32 what, int32 key, uint32 modifiers, char byte)
{
	BMessage message(what);
	message.AddInt64("when", system_time());
	message.AddInt32("key", key);
	message.AddInt32("modifiers", modifiers);
	if (byte != 0) {
		char bytes[2] = { byte, 0 };
		message.AddInt8("byte", byte);
		message.AddString("bytes", bytes);
		message.AddInt32("raw_char", tolower(byte));
	}
	window.SendMessage(&message);
	snooze(sPause);
}

static void
post_modifiers(BMessenger& window, uint32 oldModifiers, uint32 modifiers)
{
	BMessage message(B_MODIFIERS_CHANGED);
	message.AddInt64("when", system_time());
	message.AddInt32("be:old_modifiers", oldModifiers);
	message.AddInt32("modifiers", modifiers);
	window.SendMessage(&message);
	snooze(sPause);
}

int
main(int argc, char** argv)
{
	if (argc != 4 && argc != 5) {
		fprintf(stderr, "usage: keyinject TEAM TITLE-PART TEXT [MS]\n");
		return 2;
	}
	if (argc == 5)
		sPause = atoi(argv[4]) * 1000LL;
	BApplication app("application/x-vnd.haiku-pi-keyinject");
	BMessenger target(NULL, (team_id)atoi(argv[1]));
	BMessenger window;
	for (int32 i = 0; i < 64 && !window.IsValid(); i++) {
		BMessage get(B_GET_PROPERTY), reply;
		get.AddSpecifier("Title");
		get.AddSpecifier("Window", i);
		const char* title;
		if (target.SendMessage(&get, &reply) != B_OK || reply.FindString("result", &title) != B_OK)
			break;
		if (strstr(title, argv[2]) == NULL)
			continue;
		BMessage getMessenger(B_GET_PROPERTY), messengerReply;
		getMessenger.AddSpecifier("Messenger");
		getMessenger.AddSpecifier("Window", i);
		if (target.SendMessage(&getMessenger, &messengerReply) == B_OK)
			messengerReply.FindMessenger("result", &window);
		printf("keyinject: window %" B_PRId32 " \"%s\"\n", i, title);
	}
	if (!window.IsValid()) {
		fprintf(stderr, "keyinject: no window \"%s\" in team %s\n", argv[2], argv[1]);
		return 1;
	}
	// to the window's preferred handler, as input_server sends: BWindow hands a key to its focus view
	BMessenger::Private(window).SetTo(BMessenger::Private(window).Team(),
		BMessenger::Private(window).Port(), B_PREFERRED_TOKEN);

	const uint32 shift = B_SHIFT_KEY | B_LEFT_SHIFT_KEY;
	for (const char* c = argv[3]; *c != '\0'; c++) {
		int32 key = key_code(*c);
		if (key < 0) {
			fprintf(stderr, "keyinject: no key for '%c'\n", *c);
			continue;
		}
		bool shifted = isupper(*c) || *c == '!';
		uint32 modifiers = shifted ? shift : 0;
		if (shifted) {
			post_key(window, B_UNMAPPED_KEY_DOWN, kLeftShift, shift, 0);
			post_modifiers(window, 0, shift);
		}
		post_key(window, B_KEY_DOWN, key, modifiers, *c);
		post_key(window, B_KEY_UP, key, modifiers, *c);
		if (shifted) {
			post_key(window, B_UNMAPPED_KEY_UP, kLeftShift, 0, 0);
			post_modifiers(window, shift, 0);
		}
	}
	printf("keyinject: typed %zu characters\n", strlen(argv[3]));
	return 0;
}
