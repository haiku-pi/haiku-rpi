/*
 * launcher.cpp — PhotoCraft's Haiku launcher (apps/PhotoCraft/PhotoCraft in the photocraft package): what the
 * Deskbar and the Tracker start. The Tracker hands documents to an application as a B_REFS_RECEIVED
 * message (Open with, a double click, a drop on the icon), and PhotoCraft — a Rust program on winit — has
 * no BApplication to receive one (the Wayland server makes one later, for its windows) and takes its
 * documents as arguments. This BApplication collects the documents (refs and arguments), starts
 * bin/PhotoCraft beside it with their paths, and quits; each launch starts its own (B_MULTIPLE_LAUNCH).
 *
 * Build (cross, by scripts/build-photocraft.sh, step package):
 *   aarch64-unknown-haiku-g++ -O2 -o PhotoCraft tools/photocraft-package/launcher.cpp -lbe
 */
#include <Alert.h>
#include <Application.h>
#include <Entry.h>
#include <Path.h>
#include <Roster.h>
#include <String.h>

#include <stdio.h>
#include <string.h>

#include <vector>

extern char** environ;

static const char* kSignature = "application/x-vnd.storyteller-photocraft";


class Launcher : public BApplication {
public:
	Launcher()
		:
		BApplication(kSignature)
	{
	}

	virtual void ArgvReceived(int32 argc, char** argv)
	{
		for (int32 i = 1; i < argc; i++)
			fArgs.push_back(BString(argv[i]));
	}

	virtual void RefsReceived(BMessage* message)
	{
		entry_ref ref;
		for (int32 i = 0; message->FindRef("refs", i, &ref) == B_OK; i++) {
			BPath path(&ref);
			if (path.InitCheck() == B_OK)
				fArgs.push_back(BString(path.Path()));
		}
	}

	virtual void ReadyToRun()
	{
		app_info info;
		BPath program;
		status_t status = GetAppInfo(&info);
		if (status == B_OK)
			status = program.SetTo(&info.ref);
		if (status == B_OK)
			status = program.GetParent(&program);
		if (status == B_OK)
			status = program.Append("bin/PhotoCraft");

		std::vector<const char*> argv;
		argv.push_back(program.Path());
		for (size_t i = 0; i < fArgs.size(); i++)
			argv.push_back(fArgs[i].String());
		argv.push_back(NULL);

		thread_id thread = status == B_OK
			? load_image(argv.size() - 1, argv.data(), (const char**)environ) : status;
		if (thread >= 0)
			resume_thread(thread);
		else {
			BString text;
			text.SetToFormat("PhotoCraft could not be started (%s): %s", program.Path(),
				strerror(thread));
			fprintf(stderr, "%s\n", text.String());
			(new BAlert("PhotoCraft", text.String(), "OK", NULL, NULL, B_WIDTH_AS_USUAL,
				B_STOP_ALERT))->Go();
		}
		Quit();
	}

private:
	std::vector<BString>	fArgs;
};


int
main()
{
	Launcher launcher;
	launcher.Run();
	return 0;
}
