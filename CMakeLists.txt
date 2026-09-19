# CMakeLists.txt — builds the C/C++ side of the Compositor C ABI seam (ENG-1).
#
# Scope: the thin C++ shim (shim/) and the C/C++ unit tests (tests/). The Swift
# core (Sources/CompositorCore) is built by SwiftPM (`swift build` under the
# Freedesktop Swift runtime extension), not by this file. The tests link
# against the C reference implementation (tests/ref), which mirrors the Swift
# @_cdecl export so they run without a Swift toolchain on the build host.
#
# ENG-2 (composition root: CMake drives Qt/MOC + links the Swift static lib) is
# a follow-up; this file is the minimal foundation for the shim + tests.
#
# Build:
#   cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure

cmake_minimum_required(VERSION 3.16)
project(CompositorCoreShim LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Header-only ABI contract, consumed by the shim and tests.
add_library(CompositorCoreAbi INTERFACE)
target_include_directories(CompositorCoreAbi INTERFACE ${CMAKE_SOURCE_DIR}/include)

# Thin C++ wrapper over the C ABI.
add_library(CompositorCoreShim STATIC shim/CompositorCoreShim.cpp)
target_link_libraries(CompositorCoreShim PUBLIC CompositorCoreAbi)

# C reference implementation — TEST STAND-IN for the Swift @_cdecl export.
# Never linked into production; only the test executable consumes it.
add_library(CompositorCoreRef STATIC tests/ref/compositor_composite_over.c)
target_link_libraries(CompositorCoreRef PUBLIC CompositorCoreAbi)

enable_testing()
add_executable(test_composite_over tests/test_composite_over.cpp)
target_link_libraries(test_composite_over PRIVATE CompositorCoreShim CompositorCoreRef)
add_test(NAME CompositorCore.Abi COMMAND test_composite_over)