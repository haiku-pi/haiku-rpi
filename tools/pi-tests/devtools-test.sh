#!/bin/sh
# devtools-test.sh — a UserBootscript for the development image (jam -sHAIKU_PI_DEV=1): do the
# cross-built arm64 build packages work natively? gcc and g++ build and run a program, make runs a
# makefile, python3 runs. Serial console lines: "DEV ".
sleep 15
out=/dev/dprintf
say() { echo "DEV $*" > $out; }
cd /tmp || exit 1
# The cross-built python3.10 package has libpython3.10.so.1.0 in develop/lib only
# and computes its prefix from the package's renamed directory (python3.10_bootstrap-...)
export LIBRARY_PATH="$LIBRARY_PATH:/boot/system/develop/lib"
export PYTHONHOME=/boot/system
# its missing compression modules (scripts/build-python-modules.sh)
export PYTHONPATH=/boot/system/non-packaged/lib/python3.10/lib-dynload
say "gcc: $(gcc --version 2>&1 | head -n 1)"
printf '#include <stdio.h>\nint main(void) { printf("hello from gcc on Haiku arm64\\n"); return 0; }\n' > hello.c
gcc -O2 -o hello hello.c > $out 2>&1; say "gcc-exit $?"
say "run: $(./hello 2>&1)"
printf '#include <iostream>\n#include <vector>\nint main() { std::vector<int> v{1,2,3}; int s = 0; for (int x : v) s += x; std::cout << "g++ sum " << s << std::endl; }\n' > hello.cpp
g++ -O2 -std=c++17 -o hellopp hello.cpp > $out 2>&1; say "g++-exit $?"
say "run: $(./hellopp 2>&1)"
printf 'all: made\nmade:\n\techo made > made\n' > Makefile
make > $out 2>&1; say "make-exit $? made: $(cat made 2>&1)"
say "python: $(python3 -c 'import sys; print(sys.version.split()[0], 6*7)' 2>&1)"
say "haikuporter: $(haikuporter --help 2>&1 | head -n 1)"
say end
