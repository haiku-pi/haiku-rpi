#pragma once
#include <stdio.h>
namespace CppUnit { class TestFixture { public: virtual ~TestFixture() {} virtual void setUp() {} virtual void tearDown() {} }; }
extern int gFailures, gChecks;
extern const char* gCurrentTest;
#define SHIM_FAIL(what) do { gFailures++; printf("FAIL %s line %d: %s\n", gCurrentTest, __LINE__, what); } while (0)
