/*
 * cxxrt.cpp — checks of the C++ runtime (libstdc++, libgcc_s) as a program sees it, for a rebuilt
 * gcc_syslibs (scripts/build-gcc-syslibs.sh: GNU hash, -Bsymbolic-functions):
 *   - exceptions thrown inside libstdc++ (vector::at, stoi) caught by the program
 *   - std::current_exception / rethrow_exception / uncaught_exceptions agree with the program's
 *     catch blocks (one set of exception globals, whichever copy of libsupc++ serves the program)
 *   - a replaced operator new/delete is used by libstdc++'s own code (ostringstream growth)
 *   - iostreams, locale, std::string, std::thread, std::function, dynamic_cast across libstdc++ types
 * Prints "cxxrt: ok" or "cxxrt: FAIL <what>" and exits 0 / 1.
 */
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <functional>
#include <iostream>
#include <locale>
#include <new>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

static std::atomic<long> sNews{0};

void* operator new(std::size_t size)
{
	sNews++;
	if (void* p = std::malloc(size ? size : 1))
		return p;
	throw std::bad_alloc();
}

void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }

static int sFailures = 0;

static void check(bool ok, const char* what)
{
	if (!ok) {
		std::printf("cxxrt: FAIL %s\n", what);
		sFailures++;
	}
}

struct Guard {
	int* seen;
	~Guard() { *seen = std::uncaught_exceptions(); }
};

int main()
{
	// thrown in libstdc++, caught here
	try {
		std::vector<int> v(3);
		(void)v.at(7);
		check(false, "vector::at did not throw");
	} catch (const std::out_of_range&) {
	}
	try {
		(void)std::stoi("not a number");
		check(false, "stoi did not throw");
	} catch (const std::invalid_argument& e) {
		check(std::string(e.what()) == "stoi", "invalid_argument::what");
	}

	// exception_ptr (libstdc++) must see the program's catch
	std::exception_ptr saved;
	try {
		throw std::runtime_error("kept");
	} catch (...) {
		saved = std::current_exception();
	}
	check(saved != nullptr, "current_exception is null inside catch");
	try {
		std::rethrow_exception(saved);
	} catch (const std::runtime_error& e) {
		check(std::string(e.what()) == "kept", "rethrown what");
	}
	int seen = -1;
	try {
		Guard g{&seen};
		throw 42;
	} catch (int) {
	}
	check(seen == 1, "uncaught_exceptions during unwinding");
	check(std::uncaught_exceptions() == 0, "uncaught_exceptions after catch");

	// nested exceptions (std::nested_exception captures the current exception in libstdc++)
	try {
		try {
			throw std::length_error("inner");
		} catch (...) {
			std::throw_with_nested(std::logic_error("outer"));
		}
	} catch (const std::logic_error& e) {
		bool inner = false;
		try {
			std::rethrow_if_nested(e);
		} catch (const std::length_error&) {
			inner = true;
		}
		check(inner, "nested exception lost");
	}

	// libstdc++'s own allocations go through the program's operator new
	long before = sNews;
	{
		std::ostringstream out;
		for (int i = 0; i < 1000; i++)
			out << "growing the buffer inside libstdc++ " << i << '\n';
		check(out.str().size() > 30000, "ostringstream size");
	}
	check(sNews - before > 5, "libstdc++ did not use the replaced operator new");

	// locale, iostreams, threads, dynamic_cast
	std::ostringstream num;
	num.imbue(std::locale::classic());
	num << 1234567.5;
	check(num.str() == "1.23457e+06", "number formatting");
	std::atomic<int> sum{0};
	std::vector<std::thread> threads;
	for (int i = 0; i < 4; i++)
		threads.emplace_back([&sum, i] {
			try {
				throw i;
			} catch (int n) {
				sum += n;
			}
		});
	for (auto& t : threads)
		t.join();
	check(sum == 6, "exceptions in threads");
	std::function<int(int)> twice = [](int x) { return 2 * x; };
	check(twice(21) == 42, "std::function");
	std::exception* base = new std::range_error("r");
	check(dynamic_cast<std::runtime_error*>(base) != nullptr, "dynamic_cast");
	delete base;
	std::cout << "cxxrt: iostream " << std::string(3, 'x') << std::endl;

	std::printf(sFailures ? "cxxrt: FAIL (%d)\n" : "cxxrt: ok\n", sFailures);
	return sFailures ? 1 : 0;
}
