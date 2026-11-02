/* dbgtarget-cxx.cpp — a C++ target for Haiku's Debugger, built once with -gdwarf-4 and once with -gdwarf-5
 * (tools/pi-tests/dwarf5.sh compares the Debugger's command line output of the two builds): optimised code
 * (-O2: address range lists, location lists, inlining), a namespace, a class, a template, and a callback
 * that libstdc++ calls (std::thread: execute_native_thread_routine in libstdc++.so), so that a backtrace
 * from leaf() crosses a libstdc++ frame. Prints "dbgtarget-cxx: <sum> <count>". */
#include <stdio.h>

#include <algorithm>
#include <string>
#include <thread>
#include <vector>

namespace dbg {

int gLeafCalls;

template<typename T>
struct Accumulator {
	T	sum;
	int	count;

	Accumulator() : sum(0), count(0) {}

	__attribute__((noinline)) void Add(T value)
	{
		sum += value;
		count++;
	}
};

__attribute__((noinline)) int
leaf(int value, const std::string& label)
{
	int scaled = value * 3 + (int)label.size();
	gLeafCalls++;
	asm volatile("" : : "r"(scaled) : "memory");
	return scaled;
}

__attribute__((noinline)) long
worker(const std::vector<int>& values)
{
	Accumulator<long> accumulator;
	std::string label("item");
	for (int value : values) {
		if (value % 7 == 0)
			label += "!";
		accumulator.Add(leaf(value, label));
	}
	return accumulator.sum * 100 + accumulator.count;
}

}	// namespace dbg


int
main()
{
	std::vector<int> values;
	for (int i = 0; i < 10; i++)
		values.push_back((i * 37) % 11);
	std::sort(values.begin(), values.end(),
		[](int a, int b) { return a > b; });

	long result = 0;
	std::thread thread([&values, &result]() { result = dbg::worker(values); });
	thread.join();

	printf("dbgtarget-cxx: %ld %d\n", result, dbg::gLeafCalls);
	return 0;
}
