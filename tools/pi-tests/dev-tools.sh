#!/bin/sh
# dev-tools.sh — check the developer tool packages of scripts/build-dev-tools.sh (H18 part 1,
# docs/design/dev-tools.md) natively: versions; then, when a C compiler is installed, the same small
# projects built with make, CMake + Ninja and Meson (and so with the packaged as/ld), a pure-Python
# project installed with pip (setuptools backend, offline) and a Cython extension built by pip
# through meson-python (the path a native `pip install numpy` takes).
#
#   sh dev-tools.sh            on the Pi (ssh): lines on stdout
#   as a UserBootscript        (scripts/qemu-virt.sh image, /boot/home/config/settings/boot/):
#                              lines on the serial console, after a 20 s wait
#
# Lines "DEV <check> PASS|FAIL <detail>", "DEV end <passed>/<total>". Work directory /tmp/dev-tools
# (recreated); the pip installs go to /boot/system/non-packaged and are removed again at the end.
# (Haiku has no /dev/stdout: the lines go to file descriptor 3)
if [ -t 1 ] || [ -n "$SSH_CONNECTION" ]; then
	exec 3>&1
else
	exec 3> /dev/dprintf
	sleep 20
fi
say() { echo "DEV $*" >&3; }
pass=0 total=0
check() {	# name command... — PASS/FAIL by exit status, with the output's last line
	name="$1"; shift
	total=$((total + 1))
	if "$@" > /tmp/dev-tools.log 2>&1; then
		pass=$((pass + 1)); say "$name PASS $(tail -n 1 /tmp/dev-tools.log)"
	else
		say "$name FAIL $(tail -n 3 /tmp/dev-tools.log | tr '\n' '|')"
	fi
}
w=/tmp/dev-tools
rm -rf $w; mkdir -p $w; cd $w || exit 1

# versions (and that each program starts: libraries and symbols resolve)
check make make --version
check ninja ninja --version
check cmake cmake --version
check ctest ctest --version
check cpack cpack --version
check pkg-config pkg-config --version
check meson meson --version
check pip python3.14 -m pip --version
check setuptools python3.14 -c 'import setuptools; print(setuptools.__version__)'
check wheel python3.14 -m wheel version
check cython cython --version
check mesonpy python3.14 -c 'import mesonpy, pyproject_metadata; print("meson-python", mesonpy.__version__)'
check as as --version
check ld ld --version
check objdump objdump --version
# pkgconf's search path is Haiku's (find_paths): the .pc files of the _devel packages
check pkg-config-libpkgconf pkg-config --modversion libpkgconf
check cmake-script sh -c 'printf "message(STATUS \"cmake -P on \${CMAKE_HOST_SYSTEM_NAME} \${CMAKE_HOST_SYSTEM_PROCESSOR}\")\n" > t.cmake && cmake -P t.cmake'
# as + ld + objdump on their own
check as-ld-objdump sh -c 'printf ".globl _start\n_start:\n\tmov x0, #42\n\tret\n" > t.s && as -o t.o t.s && ld -o t.elf -e _start t.o && objdump -d t.elf | grep -c "mov\s*x0, #0x2a"'

if command -v gcc > /dev/null; then
	say "gcc $(gcc -dumpfullversion) as=$(gcc -print-prog-name=as) ld=$(gcc -print-prog-name=ld)"
	mkdir -p src
	printf '#include <stdio.h>\nint main(void) { printf("hello %%s\\n", BUILT_WITH); return 0; }\n' > src/hello.c
	printf '#include <iostream>\n#include <vector>\nint main() { std::vector<int> v{1, 2, 3}; int s = 0;\n\tfor (int x : v) s += x; std::cout << "c++ sum " << s << std::endl; }\n' > src/sum.cpp
	# make
	printf 'all: hello\nhello: src/hello.c\n\t$(CC) -O2 -DBUILT_WITH=\\"make\\" -o $@ $<\n' > Makefile
	check make-build sh -c 'make && ./hello'
	# CMake + Ninja
	printf 'cmake_minimum_required(VERSION 3.20)\nproject(t C CXX)\nadd_executable(hello src/hello.c)\ntarget_compile_definitions(hello PRIVATE BUILT_WITH="cmake")\nadd_executable(sum src/sum.cpp)\n' > CMakeLists.txt
	check cmake-ninja sh -c 'cmake -G Ninja -S . -B build-cmake && ninja -C build-cmake && ./build-cmake/hello && ./build-cmake/sum'
	# Meson (+ Ninja)
	printf "project('t', 'c', 'cpp')\nexecutable('hello', 'src/hello.c', c_args: '-DBUILT_WITH=\"meson\"')\nexecutable('sum', 'src/sum.cpp')\n" > meson.build
	check meson-ninja sh -c 'meson setup build-meson && meson compile -C build-meson && ./build-meson/hello && ./build-meson/sum'
fi

# pip: a pure-Python project with the setuptools backend, offline (no index, no isolation)
mkdir -p pure/devtools_pure
printf '[build-system]\nrequires = ["setuptools"]\nbuild-backend = "setuptools.build_meta"\n[project]\nname = "devtools-pure"\nversion = "1.0"\n' > pure/pyproject.toml
printf 'def answer():\n    return 42\n' > pure/devtools_pure/__init__.py
check pip-install-pure sh -c 'python3.14 -m pip install --no-index --no-build-isolation ./pure && cd / && python3.14 -c "import devtools_pure; print(devtools_pure.answer(), devtools_pure.__file__)"'

# pip + meson-python + Cython + meson + ninja + gcc: a compiled extension module
if command -v gcc > /dev/null; then
	mkdir -p cyext
	printf '[build-system]\nrequires = ["meson-python", "cython"]\nbuild-backend = "mesonpy"\n[project]\nname = "devtools-cyext"\nversion = "1.0"\n' > cyext/pyproject.toml
	printf "project('devtools-cyext', 'c', 'cython')\npy = import('python').find_installation(pure: false)\npy.extension_module('devtools_cyext', 'devtools_cyext.pyx', install: true)\n" > cyext/meson.build
	printf 'def fib(int n):\n    cdef long a = 0, b = 1\n    for _ in range(n):\n        a, b = b, a + b\n    return a\n' > cyext/devtools_cyext.pyx
	check pip-install-cython sh -c 'python3.14 -m pip install --no-index --no-build-isolation ./cyext && cd / && python3.14 -c "import devtools_cyext; print(devtools_cyext.fib(90), devtools_cyext.__file__)"'
fi
python3.14 -m pip uninstall -y -q devtools-pure devtools-cyext > /dev/null 2>&1
say "end $pass/$total"
