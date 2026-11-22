#pragma once
#include <cppunit/TestFixture.h>
#define CPPUNIT_TEST_SUITE(X) public: static void RunAll() { typedef X Fixture;
#define CPPUNIT_TEST(m) { Fixture t; gCurrentTest = #m; t.setUp(); t.m(); t.tearDown(); printf("ran %s\n", #m); }
#define CPPUNIT_TEST_SUITE_END() } private:
#define CPPUNIT_ASSERT(c) do { gChecks++; if (!(c)) SHIM_FAIL(#c); } while (0)
#define CPPUNIT_ASSERT_MESSAGE(m, c) do { gChecks++; if (!(c)) SHIM_FAIL(m); } while (0)
#define CPPUNIT_ASSERT_EQUAL(a, b) do { gChecks++; if (!((a) == (b))) SHIM_FAIL(#a " == " #b); } while (0)
#define CPPUNIT_ASSERT_EQUAL_MESSAGE(m, a, b) do { gChecks++; if (!((a) == (b))) SHIM_FAIL(m); } while (0)
#define CPPUNIT_TEST_SUITE_NAMED_REGISTRATION(X, n) \
	int gFailures, gChecks; const char* gCurrentTest; \
	status_t BUrl::IDNAToUnicode() { return B_ERROR; } \
	status_t BUrl::IDNAToAscii() { return B_ERROR; } \
	int main() { X::RunAll(); printf("UrlTest: %d checks, %d failures\n", gChecks, gFailures); return gFailures != 0; }
