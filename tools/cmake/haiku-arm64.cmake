# CMake toolchain file: Haiku arm64 (aarch64-unknown-haiku) on the Linux host, with the jam-built cross
# compiler and the sysroot from scripts/haiku-sysroot.sh — the CMake twin of tools/meson/haiku-arm64.cross.
# Ports built with it install with
#   -DCMAKE_INSTALL_PREFIX=/boot/system/non-packaged  and  DESTDIR=<sysroot>
# (scripts/cross-port.sh does), so later ports find earlier ones through pkg-config and CMake packages.

get_filename_component(HAIKU_PI_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(HAIKU_PI_CROSS "${HAIKU_PI_ROOT}/sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-")
set(HAIKU_PI_SYSROOT "${HAIKU_PI_ROOT}/artifacts/sysroot-arm64")

set(CMAKE_SYSTEM_NAME Haiku)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER "${HAIKU_PI_CROSS}gcc")
set(CMAKE_CXX_COMPILER "${HAIKU_PI_CROSS}g++")
set(CMAKE_AR "${HAIKU_PI_CROSS}ar" CACHE FILEPATH "")
set(CMAKE_RANLIB "${HAIKU_PI_CROSS}ranlib" CACHE FILEPATH "")
set(CMAKE_STRIP "${HAIKU_PI_CROSS}strip" CACHE FILEPATH "")
set(CMAKE_SYSROOT "${HAIKU_PI_SYSROOT}")

# headers and libraries only from the sysroot (the system's and the non-packaged ports'), programs
# from the host
set(CMAKE_FIND_ROOT_PATH "${HAIKU_PI_SYSROOT}/boot/system/non-packaged" "${HAIKU_PI_SYSROOT}/boot/system")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_LIBRARY_PATH "/develop/lib" "/lib")
set(CMAKE_INCLUDE_PATH "/develop/headers")

set(ENV{PKG_CONFIG_SYSROOT_DIR} "")
set(ENV{PKG_CONFIG_LIBDIR}
	"${HAIKU_PI_SYSROOT}/boot/system/non-packaged/develop/lib/pkgconfig:${HAIKU_PI_SYSROOT}/boot/system/develop/lib/pkgconfig")
