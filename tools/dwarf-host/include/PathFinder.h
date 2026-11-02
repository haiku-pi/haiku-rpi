/* PathFinder.h — host stand-in for Haiku's BPathFinder (the DWARF reader's lookup of separate debug
 * info files in the system's develop directories): finds nothing. */
#ifndef DWARF_HOST_PATH_FINDER_H
#define DWARF_HOST_PATH_FINDER_H

#include <FindDirectory.h>
#include <Path.h>

class BPathFinder {
public:
	BPathFinder(const char*) {}
	status_t FindPath(path_base_directory, const char*, uint32, BPath&) { return B_ENTRY_NOT_FOUND; }
};

#endif
