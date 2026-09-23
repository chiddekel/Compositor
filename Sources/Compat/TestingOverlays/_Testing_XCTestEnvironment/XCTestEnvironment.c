// Xcode's test runner starts every test process with XCTestConfigurationFilePath set, and upstream code keys
// test-only behaviour off it (ToolDefaults.swift: tool settings are neither read from nor written to UserDefaults
// under test, so one test's toggle cannot leak into the next test or the next run). `swift test` on Linux sets no
// such variable, so this sets it before main — the same process environment the upstream tests assume. Linked
// only into the test targets.
#include <stdlib.h>

__attribute__((constructor)) static void compositor_xctest_environment(void) {
    setenv("XCTestConfigurationFilePath", "/dev/null", 0);
}
