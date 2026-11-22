#!/bin/sh
# run.sh TREE [OUT] — BUrl on the Linux host (MP3, docs/design/mediaplayer-url-crash.md): TREE's
# src/kits/support/Url.cpp, compiled with the build headers and linked ahead of the main tree's host
# libbe_build.so (which has BString), into
#   urlrace N THREADS   THREADS threads read one fresh BUrl at once, N rounds (stock Url.cpp: heap abort)
#   urldump             fields after parses, copies, setter chains and self-aliasing calls (diff two trees)
#   urltest             TREE's src/tests/kits/support/UrlTest.cpp with a small CppUnit shim (IDNTest fails
#                       on the host: no ICU)
# then runs urlrace 200000 x 1/2/3 threads and urltest. OUT: build directory (default /tmp/host-burl-<tree>).
set -eu
tree=$(cd "${1:?usage: run.sh TREE [OUT]}" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${2:-/tmp/host-burl-$(basename "$tree")}
lib=$root/sources/haiku/generated.arm64/objects/linux/lib
mkdir -p "$out"
H=$tree/headers
CF="-O2 -g -Wno-multichar -include $H/build/BeOSBuildCompatibility.h -I$here/shim -I$H/build -I$H/build/os \
 -I$H/build/os/support -I$H/build/os/app -I$H/build/os/storage -I$H/build/os/interface -I$H/build/os/kernel \
 -I$H/build/private/kernel -I$H/build/host/linux -I$H/build/private/shared -I$H/build/private/support"
g++ $CF -c -o "$out/Url.o" "$tree/src/kits/support/Url.cpp"
for t in urlrace urldump; do
	g++ $CF -o "$out/$t" "$here/$t.cpp" "$out/Url.o" -L"$lib" -lbe_build -lroot_build -lpthread
done
g++ $CF -o "$out/urltest" "$tree/src/tests/kits/support/UrlTest.cpp" "$out/Url.o" -L"$lib" -lbe_build -lroot_build
export LD_LIBRARY_PATH=$lib
for th in 1 2 3; do
	"$out/urlrace" 200000 $th 2>&1 | tail -n 1 || true
done
"$out/urltest" | tail -n 1 || true
"$out/urldump" > "$out/urldump.txt"
echo "run.sh: field dump in $out/urldump.txt"
