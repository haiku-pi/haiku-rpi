#!/bin/sh
# native-gcc.sh — check the native GCC package (scripts/build-native-gcc.sh, docs/design/native-gcc.md) on
# Haiku: versions and built-in paths, then small programs compiled, linked and run: C, C++ (iostream,
# exceptions, threads, C++20/23 library), the Haiku API, LTO, OpenMP, a precompiled header, gcov, Fortran
# (when gcc_fortran is installed), and a CMake project (make, and Ninja when installed).
#
#   sh native-gcc.sh           on the Pi (ssh): lines on stdout
#   as a UserBootscript        (scripts/qemu-virt.sh image, /boot/home/config/settings/boot/):
#                              lines on the serial console, after a 20 s wait
#
# Lines "NGCC <check> PASS|FAIL <detail>", "NGCC end <passed>/<total>". Work directory /tmp/native-gcc.
# (Haiku has no /dev/stdout: the lines go to file descriptor 3)
if [ -t 1 ] || [ -n "$SSH_CONNECTION" ]; then
	exec 3>&1
else
	exec 3> /dev/dprintf
	sleep 20
fi
say() { echo "NGCC $*" >&3; }
pass=0 total=0
check() {	# name command... — PASS/FAIL by exit status, with the output's last line
	name="$1"; shift
	total=$((total + 1))
	if "$@" > /tmp/native-gcc.log 2>&1; then
		pass=$((pass + 1)); say "$name PASS $(tail -n 1 /tmp/native-gcc.log)"
	else
		say "$name FAIL $(tail -n 4 /tmp/native-gcc.log | tr '\n' '|')"
	fi
}
w=/tmp/native-gcc
rm -rf $w; mkdir -p $w; cd $w || exit 1

say "packages: $(ls /boot/system/packages | grep -E '^(gcc|binutils|make|cmake|ninja|haiku_devel)' | tr '\n' ' ')"
check gcc-version sh -c 'gcc --version | head -n 1'
check gxx-version sh -c 'g++ --version | head -n 1'
check cc-cpp sh -c 'cc --version | head -n 1 && cpp --version | head -n 1 && c++ --version | head -n 1'
check dumpversion sh -c 'test "$(gcc -dumpfullversion)" = 16.2.0 && gcc -dumpfullversion'
check prog-as sh -c 'gcc -print-prog-name=as; test -x "$(gcc -print-prog-name=as)" || command -v as'
check prog-ld sh -c 'gcc -print-prog-name=ld; test -x "$(gcc -print-prog-name=ld)" || command -v ld'
check search-dirs sh -c 'gcc -print-search-dirs | grep "^libraries:" | tr ":" "\n" | grep -q "^/boot/system/develop/lib/\$" && echo "libraries: .../boot/system/develop/lib/"'
check include-dirs sh -c 'echo | gcc -E -Wp,-v - 2>&1 | grep -q "^ /boot/system/develop/headers/posix\$" && echo | g++ -x c++ -E -Wp,-v - 2>&1 | grep "include/c++\$"'
check no-sysroot sh -c 'test "$(gcc -print-sysroot)" = "" && echo "sysroot: none"'
check configured sh -c 'gcc -v 2>&1 | grep "^Configured with" | cut -c 1-120'

printf '#include <stdio.h>\nint main(void) { printf("hello c %%ld\\n", __STDC_VERSION__); return 0; }\n' > hello.c
check c-hello sh -c 'gcc -O2 -Wall -o hello hello.c && ./hello'
cat > cxx.cpp <<'EOF'
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <format>
#include <map>
static int f(int x) { if (x > 2) throw std::runtime_error("boom " + std::to_string(x)); return x; }
int main() {
	std::vector<int> v{1, 2, 3};
	int sum = 0;
	std::thread t([&] { for (int x : v) sum += x; });
	t.join();
	std::string caught;
	try { f(3); } catch (const std::exception& e) { caught = e.what(); }
	std::map<std::string, int> m{{"a", 1}};
	std::cout << std::format("c++ {} sum {} caught '{}' map {}", __cplusplus, sum, caught, m["a"]) << std::endl;
	return sum == 6 && caught == "boom 3" ? 0 : 1;
}
EOF
check cxx-runtime sh -c 'g++ -O2 -Wall -o cxx cxx.cpp && ./cxx'
printf '#include <print>\nint main() { std::println("c++23 println {}", 42); }\n' > print.cpp
check cxx23-print sh -c 'g++ -std=c++23 -O2 -o print print.cpp && ./print'
cat > be.cpp <<'EOF'
#include <String.h>
#include <OS.h>
#include <FindDirectory.h>
#include <Path.h>
#include <stdio.h>
int main() {
	BString s("haiku api");
	s << " " << 42;
	BPath p;
	find_directory(B_SYSTEM_DIRECTORY, &p);
	system_info info;
	get_system_info(&info);
	printf("%s %s cpus %u\n", s.String(), p.Path(), (unsigned)info.cpu_count);
	return 0;
}
EOF
check haiku-api sh -c 'g++ -O2 -o be be.cpp -lbe && ./be'
printf 'int sq(int x);\nint main(void) { return sq(7) == 49 ? 0 : 1; }\n' > lto1.c
printf 'int sq(int x) { return x * x; }\n' > lto2.c
check lto sh -c 'gcc -O2 -flto -c lto1.c lto2.c && gcc -O2 -flto -o lto lto1.o lto2.o && ./lto && echo "lto ok"'
printf '#include <omp.h>\n#include <stdio.h>\nint main(void) { int n = 0;\n#pragma omp parallel reduction(+:n)\nn += 1;\nprintf("openmp threads %%d\\n", n); return n > 0 ? 0 : 1; }\n' > omp.c
check openmp sh -c 'gcc -fopenmp -O2 -o omp omp.c && ./omp'
printf '#include <vector>\n#include <string>\n#include <iostream>\n' > pch.h
printf 'int main() { std::vector<std::string> v{"pch"}; std::cout << v[0] << " ok" << std::endl; }\n' > pch.cpp
check pch sh -c 'g++ -O2 -x c++-header -o pch.h.gch pch.h && g++ -O2 -include pch.h -Winvalid-pch -H -o pchuse pch.cpp 2>&1 | grep -q "^! .*pch.h.gch" && ./pchuse'
# (compiled separately: a one-step compile and link names the notes file cov-hello.gcno)
check gcov sh -c 'gcc --coverage -c hello.c && gcc --coverage -o cov hello.o && ./cov > /dev/null && gcov hello.c | grep "Lines executed"'
check static-libgcc sh -c 'g++ -static-libgcc -O2 -o cxx-s cxx.cpp && ./cxx-s'

if command -v gfortran > /dev/null; then
	cat > hello.f90 <<'EOF'
program hello
  implicit none
  integer :: i
  real(8) :: s
  s = 0
  do i = 1, 10
    s = s + sqrt(real(i, 8))
  end do
  print '(a, f0.6)', 'fortran sum ', s
end program hello
EOF
	check fortran sh -c 'gfortran -O2 -o hellof hello.f90 && ./hellof'
	# Haiku's cc1 spec passes -Wno-multichar to f951 too, which warns about it (known, harmless)
	check fortran-warnings sh -c 'gfortran -c -o hellow.o hello.f90 2>&1 | grep -v "Wno-multichar" | grep . && exit 1; echo "only the -Wno-multichar note"'
	printf 'subroutine addone(x) bind(c)\n  use iso_c_binding\n  integer(c_int) :: x\n  x = x + 1\nend subroutine\n' > addone.f90
	printf '#include <stdio.h>\nvoid addone(int *);\nint main(void) { int x = 41; addone(&x); printf("c calls fortran %%d\\n", x); return x == 42 ? 0 : 1; }\n' > callf.c
	check fortran-c sh -c 'gfortran -c addone.f90 && gcc -o callf callf.c addone.o -lgfortran && ./callf'
fi

if command -v cmake > /dev/null && command -v make > /dev/null; then
	mkdir -p proj/src
	printf 'cmake_minimum_required(VERSION 3.20)\nproject(t C CXX)\nset(CMAKE_CXX_STANDARD 20)\nadd_library(sq STATIC src/sq.c)\nadd_executable(app src/app.cpp)\ntarget_link_libraries(app sq)\n' > proj/CMakeLists.txt
	printf 'int sq(int x) { return x * x; }\n' > proj/src/sq.c
	printf '#include <iostream>\nextern "C" int sq(int);\nint main() { std::cout << "cmake app " << sq(6) << std::endl; return sq(6) == 36 ? 0 : 1; }\n' > proj/src/app.cpp
	check cmake-make sh -c 'cmake -S proj -B build-make && make -C build-make && ./build-make/app && grep "^CMAKE_CXX_COMPILER:" build-make/CMakeCache.txt'
	if command -v ninja > /dev/null; then
		check cmake-ninja sh -c 'cmake -G Ninja -S proj -B build-ninja && ninja -C build-ninja && ./build-ninja/app'
	fi
fi
say "end $pass/$total"
