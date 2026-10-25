/*
 * mimeapps.cpp — the applications Haiku's MIME database lists for a file type: the preferred one and the
 * supporting ones (the Tracker's "Open with" menu), for checking that a package's application registered
 * its supported types.
 *
 *   mimeapps TYPE...      e.g. mimeapps image/jpeg image/png
 *   mimeapps --launch SIGNATURE FILE...   launch the application with the files as the Tracker's
 *                         "Open with" does (BRoster::Launch with a B_REFS_RECEIVED message)
 *
 * Output: "MIMEAPPS <type>: preferred <signature>; supporting <n>: <signature> ..."
 *
 * Build (cross):
 *   sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-g++ \
 *     --sysroot=artifacts/sysroot-arm64 -O2 -o mimeapps tools/haiku-tests/mimeapps.cpp -lbe
 */
#include <Entry.h>
#include <Message.h>
#include <Mime.h>
#include <Roster.h>
#include <String.h>

#include <stdio.h>
#include <string.h>

int
main(int argc, char** argv)
{
	if (argc >= 3 && strcmp(argv[1], "--launch") == 0) {
		BMessage refs(B_REFS_RECEIVED);
		for (int i = 3; i < argc; i++) {
			entry_ref ref;
			if (get_ref_for_path(argv[i], &ref) == B_OK)
				refs.AddRef("refs", &ref);
		}
		team_id team;
		status_t status = be_roster->Launch(argv[2], &refs, &team);
		printf("MIMEAPPS launch %s: %s, team %d\n", argv[2], strerror(status), (int)team);
		return status == B_OK ? 0 : 1;
	}
	for (int i = 1; i < argc; i++) {
		BMimeType type(argv[i]);
		char preferred[B_MIME_TYPE_LENGTH] = "";
		type.GetPreferredApp(preferred);
		BMessage apps;
		BString list;
		int32 count = 0;
		if (type.GetSupportingApps(&apps) == B_OK) {
			const char* signature;
			for (int32 j = 0; apps.FindString("applications", j, &signature) == B_OK; j++) {
				list << " " << signature;
				count++;
			}
		}
		printf("MIMEAPPS %s: preferred %s; supporting %d:%s\n", argv[i], preferred[0] ? preferred : "-",
			(int)count, list.String());
	}
	return 0;
}
